#!/usr/bin/env node
/**
 * publishEmbeddedServiceDeployment.mjs
 *
 * Clicks the Publish button on a Salesforce Embedded Service Deployment
 * headlessly. Salesforce doesn't expose a public API for this action
 * (confirmed internally — see PLATFORM_FEEDBACK.md #10), so we drive a
 * real browser via Playwright Chromium.
 *
 * Usage:
 *     node scripts/publishEmbeddedServiceDeployment.mjs \
 *          --target-org skywave-scratch \
 *          --deployment-name Skywave_MIAW_Deployment
 *
 * Prereqs:
 *     npm install playwright
 *     npx playwright install chromium
 *
 * Environment:
 *     If --target-org is omitted, uses sf config's target-org.
 *     SF_HEADED=1 runs the browser visibly (useful for debugging).
 */
import { spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';
import { chromium } from 'playwright';

const { values } = parseArgs({
    options: {
        'target-org': { type: 'string' },
        'deployment-name': { type: 'string' },
    },
});

const targetOrg = values['target-org'];
const deploymentName = values['deployment-name'] || 'Skywave_MIAW_Deployment';

function sf(args) {
    const r = spawnSync('sf', args, { encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`sf ${args.join(' ')} failed:\n${r.stderr}`);
    // Strip control chars the CLI sometimes emits
    const clean = [...r.stdout].filter(c => {
        const code = c.charCodeAt(0);
        return code === 9 || code === 10 || code >= 32;
    }).join('');
    return JSON.parse(clean);
}

function sfQueryId(query, useTooling = false) {
    const args = ['data', 'query', '--json', '-q', query];
    if (targetOrg) args.push('--target-org', targetOrg);
    if (useTooling) args.push('--use-tooling-api');
    const r = sf(args);
    const recs = r.result?.records ?? [];
    return recs[0]?.Id;
}

function deriveHosts(instanceUrl) {
    const host = new URL(instanceUrl).host;
    const setupHost = host
        .replace('.my.salesforce.com', '.my.salesforce-setup.com')
        .replace('.my.pc-rnd.salesforce.com', '.my.pc-rnd.salesforce-setup.com')
        .replace('.sandbox.my.salesforce.com', '.sandbox.my.salesforce-setup.com');
    return { host, setupHost };
}

async function main() {
    console.log(`→ Resolving org…`);
    const orgArgs = ['org', 'display', '--json'];
    if (targetOrg) orgArgs.push('--target-org', targetOrg);
    const org = sf(orgArgs).result;
    const { accessToken, instanceUrl } = org;
    const { setupHost } = deriveHosts(instanceUrl);

    console.log(`→ Finding EmbeddedServiceConfig "${deploymentName}"…`);
    const escId = sfQueryId(
        `SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='${deploymentName}'`,
        true
    );
    if (!escId) {
        console.error(`No ESC found for DeveloperName='${deploymentName}'`);
        process.exit(1);
    }
    console.log(`  ESC Id: ${escId}`);

    const setupUrl = `https://${setupHost}/lightning/setup/EmbeddedServiceDeployments/${escId}/view`;
    const frontdoorUrl =
        `${instanceUrl}/secur/frontdoor.jsp?sid=${encodeURIComponent(accessToken)}` +
        `&retURL=${encodeURIComponent(`/lightning/setup/EmbeddedServiceDeployments/${escId}/view`)}`;

    const headless = process.env.SF_HEADED !== '1';
    console.log(`→ Launching Chromium (headless=${headless})…`);
    const browser = await chromium.launch({ headless });
    const context = await browser.newContext();
    const page = await context.newPage();

    try {
        console.log(`→ Authenticating via frontdoor…`);
        await page.goto(frontdoorUrl, { waitUntil: 'domcontentloaded', timeout: 60_000 });
        // Frontdoor redirects through contentDoor → lightning.force.com. Give
        // it a moment to settle rather than waiting for networkidle (which
        // never fires since Lightning keeps streaming connections open).
        await page.waitForTimeout(5_000);

        console.log(`→ Navigating to ESD page…`);
        await page.goto(setupUrl, { waitUntil: 'domcontentloaded', timeout: 60_000 });
        await page.waitForTimeout(3_000);

        console.log(`→ Waiting for Publish button to render…`);
        // Salesforce's Lightning Publish button is typically a lightning-button
        // web component. Try multiple locators — some Lightning buttons don't
        // register a standard ARIA "button" role.
        const candidates = [
            page.getByRole('button', { name: /^Publish$/ }),
            page.locator('button:has-text("Publish")').filter({ hasNotText: 'Publish Preview' }),
            page.locator('button[title="Publish"]'),
            page.locator('lightning-button button:has-text("Publish")'),
        ];
        let publishButton = null;
        for (const c of candidates) {
            try {
                await c.first().waitFor({ state: 'visible', timeout: 30_000 });
                publishButton = c.first();
                console.log(`  → matched locator`);
                break;
            } catch {}
        }
        if (!publishButton) {
            console.error(`  current URL: ${page.url()}`);
            console.error(`  page title: ${await page.title()}`);
            await page.screenshot({ path: '/tmp/sf-publish-fail.png', fullPage: true });
            throw new Error(`Could not find Publish button — see /tmp/sf-publish-fail.png`);
        }

        console.log(`→ Clicking Publish…`);
        await publishButton.click();

        // A toast or banner typically confirms. Look for "Publish" success indicators.
        const toast = page.locator('.slds-notify--toast, .toastMessage, [data-aura-class*="forceActionsText"]').first();
        try {
            await toast.waitFor({ state: 'visible', timeout: 30_000 });
            const text = await toast.textContent();
            console.log(`✓ Toast: ${text?.trim().slice(0, 200)}`);
        } catch {
            console.log(`✓ Publish click submitted (no toast seen — Salesforce often processes silently).`);
        }

        // Small settle window for scrt2 state to propagate.
        await page.waitForTimeout(3_000);
    } finally {
        await browser.close();
    }
    console.log(`✓ Done.`);
}

main().catch(err => {
    console.error('FAILED:', err.message);
    process.exit(1);
});
