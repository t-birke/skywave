#!/usr/bin/env node
/**
 * refreshDataStreams.mjs
 *
 * Triggers a "Refresh Now" on the Data Cloud data streams that feed the
 * Agentforce observability dashboards, after Skywave_ObservabilitySeeder has
 * rewritten the SDO_Analytics_* tables.
 *
 * WHY A BROWSER IS INVOLVED
 * The Connect endpoint that runs a stream import —
 *   POST /services/data/v66.0/ssot/data-streams/{id}/actions/run
 * — rejects bare sf-CLI / JWT tokens for SalesforceDotCom-type streams:
 *   "Connector type SalesforceDotCom is not allowed to run in non-interactive
 *    mode" (the scope is only granted to interactive web sessions). This is the
 *    same wall Skywave_DataStreamRunner.cls documents, and why `sf apex run`
 *    can't do it. So we frontdoor-auth a real browser session (exactly like
 *    scripts/publishEmbeddedServiceDeployment.mjs), capture that INTERACTIVE
 *    session cookie, and call the run endpoint with it.
 *
 * Stream set (queried live, never hardcoded — single source of truth is the org):
 *   - SDO_Analytics_%_Home   (the 11 STDM/optimization streams)
 *   - SDO_AFO_%_Home         (the Bot extra stream)
 *   - BotDefinition_Home, BotVersion_Home  (so the deployed agent joins
 *     ssot__Bot__dlm — required for Optimization Insights / Sessions & Intents)
 *
 * Usage:
 *   node scripts/refreshDataStreams.mjs --target-org si
 *   node scripts/refreshDataStreams.mjs --target-org si --bot-only   # just the Bot streams
 *
 * Env:
 *   SF_HEADED=1   run the browser visibly (debugging)
 *
 * FALLBACK if this fails: run from the Developer Console (browser Execute
 * Anonymous, which has the interactive scope):
 *   Skywave_DataStreamRunner.refreshSdoAnalyticsStreams();
 *   Skywave_DataStreamRunner.refreshBotStreams();
 */
import { spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';
import { chromium } from 'playwright';

const API = 'v66.0';

const { values } = parseArgs({
    options: {
        'target-org': { type: 'string' },
        'bot-only': { type: 'boolean', default: false },
    },
});
const targetOrg = values['target-org'];
const botOnly = values['bot-only'];

function sf(args) {
    const a = [...args];
    if (targetOrg) a.push('--target-org', targetOrg);
    const r = spawnSync('sf', a, { encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`sf ${a.join(' ')} failed:\n${r.stderr}`);
    const clean = [...r.stdout].filter(c => {
        const code = c.charCodeAt(0);
        return code === 9 || code === 10 || code >= 32;
    }).join('');
    return JSON.parse(clean);
}

async function main() {
    console.log('→ Resolving org…');
    const org = sf(['org', 'display', '--json']).result;
    const { instanceUrl } = org;
    // Newer sf CLI redacts accessToken from `org display`; fetch it from the
    // supported command (--no-prompt skips its interactive security warning).
    const accessToken = sf(['org', 'auth', 'show-access-token', '--no-prompt', '--json']).result.accessToken;

    console.log('→ Querying observability data streams…');
    const where = botOnly
        ? `Name IN ('BotDefinition_Home','BotVersion_Home')`
        : `(Name LIKE 'SDO_Analytics_%_Home' OR Name LIKE 'SDO_AFO_%_Home' OR Name IN ('BotDefinition_Home','BotVersion_Home'))`;
    const streams = sf(['data', 'query', '--json', '-q',
        `SELECT Id, Name FROM DataStream WHERE ${where} ORDER BY Name`]).result.records || [];
    if (!streams.length) {
        console.error('No matching data streams found. Has the observability metadata + data-kit been deployed/instantiated?');
        process.exit(1);
    }
    console.log(`  ${streams.length} stream(s): ${streams.map(s => s.Name).join(', ')}`);

    // Bridge the API access token into an INTERACTIVE web session via frontdoor.
    const frontdoorUrl =
        `${instanceUrl}/secur/frontdoor.jsp?sid=${encodeURIComponent(accessToken)}&retURL=%2F`;
    const headless = process.env.SF_HEADED !== '1';
    console.log(`→ Launching Chromium (headless=${headless})…`);
    const browser = await chromium.launch({ headless });
    const context = await browser.newContext();
    const page = await context.newPage();

    const results = [];
    try {
        console.log('→ Authenticating via frontdoor (interactive session)…');
        await page.goto(frontdoorUrl, { waitUntil: 'domcontentloaded', timeout: 60_000 });
        await page.waitForTimeout(5_000); // let the redirect chain settle

        // Grab the interactive session id from the cookie jar. frontdoor sets
        // 'sid' on the *.my.salesforce.com domain — that's the web session that
        // carries the scope the run endpoint demands.
        const cookies = await context.cookies();
        const host = new URL(instanceUrl).host;
        const sidCookie =
            cookies.find(c => c.name === 'sid' && host.endsWith(c.domain.replace(/^\./, ''))) ||
            cookies.find(c => c.name === 'sid');
        if (!sidCookie) throw new Error('Could not capture an interactive sid cookie after frontdoor auth.');
        const interactiveSid = sidCookie.value;

        // Fire the run action per stream from inside the browser context, so
        // the request carries the interactive session (and same-origin cookies).
        for (const s of streams) {
            const url = `${instanceUrl}/services/data/${API}/ssot/data-streams/${s.Id}/actions/run`;
            const res = await page.evaluate(async ({ url, sid }) => {
                try {
                    const r = await fetch(url, {
                        method: 'POST',
                        headers: { 'Authorization': `Bearer ${sid}`, 'Content-Type': 'application/json' },
                        body: '{}',
                    });
                    const text = await r.text();
                    return { status: r.status, body: text.slice(0, 200) };
                } catch (e) {
                    return { status: -1, body: String(e) };
                }
            }, { url, sid: interactiveSid });
            const good = res.status >= 200 && res.status < 300;
            results.push({ name: s.Name, ...res, good });
            console.log(`  ${good ? '✓' : '✗'} ${s.Name} → ${res.status}${good ? '' : ': ' + res.body}`);
        }
    } finally {
        await browser.close();
    }

    const failed = results.filter(r => !r.good);
    console.log(`\n${results.length - failed.length}/${results.length} streams refreshed.`);
    if (failed.length) {
        console.error('\nSome streams did not refresh. If the error mentions "non-interactive mode",');
        console.error('run the Apex fallback from the Developer Console (browser Execute Anonymous):');
        console.error('  Skywave_DataStreamRunner.refreshSdoAnalyticsStreams();');
        console.error('  Skywave_DataStreamRunner.refreshBotStreams();');
        process.exit(1);
    }
    console.log('✓ Done. DMO rows populate within a few minutes of a successful refresh.');
}

main().catch(err => {
    console.error('FAILED:', err.message);
    process.exit(1);
});
