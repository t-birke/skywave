#!/usr/bin/env node
/**
 * refreshDataStreams.mjs
 *
 * Triggers a "Refresh Now" on the Data Cloud data streams that feed the
 * Agentforce observability dashboards, after Skywave_ObservabilitySeeder has
 * rewritten the SDO_Analytics_* tables.
 *
 * WHY A BROWSER IS INVOLVED (and why we CLICK, not call the API)
 * The Connect endpoint POST /ssot/data-streams/{id}/actions/run rejects ALL
 * token-based callers for SalesforceDotCom-type streams — even a frontdoor-bridged
 * session — with "Connector type SalesforceDotCom is not allowed to run in
 * non-interactive mode". A bearer-header fetch is always "non-interactive"; only a
 * genuine in-page Lightning action carries the scope. So we do exactly what the
 * canonical QBrix (qx QbrixDataCloud.refresh_data_stream) does: open each DataStream
 * record page and CLICK Refresh Now → Full Refresh → Refresh Now. (This supersedes
 * the earlier API-call approach, which always 400'd on these streams.)
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

    // Bridge the API token into an INTERACTIVE web session via frontdoor, then
    // drive the Lightning UI per stream — Refresh Now → Full Refresh → Refresh Now —
    // exactly like the qx QbrixDataCloud.refresh_data_stream keyword. The Lightning
    // record page lives on the *.lightning.force.com origin; frontdoor's retURL
    // bounces us there with a live session.
    const lightningHost = new URL(instanceUrl).host
        .replace('.my.salesforce.com', '.lightning.force.com')
        .replace('.my.pc-rnd.salesforce.com', '.lightning.pc-rnd.force.com')
        .replace('.sandbox.my.salesforce.com', '.sandbox.lightning.force.com');
    const recordPath = (id) => `/lightning/r/DataStream/${id}/view`;
    const frontdoorUrl =
        `${instanceUrl}/secur/frontdoor.jsp?sid=${encodeURIComponent(accessToken)}` +
        `&retURL=${encodeURIComponent(recordPath(streams[0].Id))}`;

    const headless = process.env.SF_HEADED !== '1';
    console.log(`→ Launching Chromium (headless=${headless})…`);
    const browser = await chromium.launch({ headless });
    const context = await browser.newContext();
    const page = await context.newPage();

    const results = [];
    try {
        console.log('→ Authenticating via frontdoor (interactive session)…');
        await page.goto(frontdoorUrl, { waitUntil: 'domcontentloaded', timeout: 60_000 });
        await page.waitForTimeout(8_000); // let the redirect chain + Lightning boot settle

        for (const s of streams) {
            let good = false, detail = '';
            try {
                await page.goto(`https://${lightningHost}${recordPath(s.Id)}`,
                    { waitUntil: 'domcontentloaded', timeout: 60_000 });
                await page.waitForTimeout(4_000); // Lightning record page render

                // 1) the "Refresh Now" header action (a forceActionLink anchor)
                const refreshAction = page.locator(
                    "a.forceActionLink:has-text('Refresh Now'), button:has-text('Refresh Now')").first();
                await refreshAction.waitFor({ state: 'visible', timeout: 20_000 });
                await refreshAction.click();
                await page.waitForTimeout(1_500);

                // 2) choose "Full Refresh" in the dialog (radio/option)
                const fullRefresh = page.locator(
                    "span:has-text('Full Refresh'), label:has-text('Full Refresh')").first();
                if (await fullRefresh.count()) { await fullRefresh.click(); await page.waitForTimeout(800); }

                // 3) confirm with the dialog's "Refresh Now" button
                const confirm = page.locator(
                    ".modal-container button:has-text('Refresh Now'), .slds-modal button:has-text('Refresh Now'), button:has-text('Refresh Now')").last();
                await confirm.click({ timeout: 10_000 });
                await page.waitForTimeout(2_500);
                good = true;
            } catch (e) {
                detail = (e.message || String(e)).split('\n')[0].slice(0, 160);
            }
            results.push({ name: s.Name, good, detail });
            console.log(`  ${good ? '✓' : '✗'} ${s.Name}${good ? ' — Full Refresh triggered' : ': ' + detail}`);
        }
    } finally {
        if (process.env.SF_KEEP_SCREENSHOT) await page.screenshot({ path: '/tmp/sf-refresh-streams.png', fullPage: true }).catch(() => {});
        await browser.close();
    }

    const failed = results.filter(r => !r.good);
    console.log(`\n${results.length - failed.length}/${results.length} streams refreshed.`);
    if (failed.length) {
        console.error('\nSome streams did not refresh via the UI. Fallback — Developer Console (browser');
        console.error('Execute Anonymous, which has the interactive scope):');
        console.error('  Skywave_DataStreamRunner.refreshSdoAnalyticsStreams();');
        console.error('  Skywave_DataStreamRunner.refreshBotStreams();');
        console.error('Or Setup → Data Cloud → Data Streams → each → Refresh Now → Full Refresh.');
        process.exit(1);
    }
    console.log('✓ Done. DMO rows populate within a few minutes of a successful Full Refresh.');
}

main().catch(err => {
    console.error('FAILED:', err.message);
    process.exit(1);
});
