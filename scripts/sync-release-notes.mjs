#!/usr/bin/env node
/**
 * sync-release-notes.mjs
 *
 * Generates grouped release notes from the commits since the previous git tag
 * and upserts them into Release_Note__c (by the Version__c external id) so the
 * Demo Home changelog panel shows them. Driven by the `release-notes` GitHub
 * Action on each published GitHub Release; can also be run locally.
 *
 * Env:
 *   RELEASE_TAG            tag of the release, e.g. v1.3.0 (required)
 *   RELEASE_NAME           GitHub Release title (optional)
 *   RELEASE_URL            GitHub Release html_url (optional)
 *   RELEASE_PUBLISHED_AT   ISO8601 publish time (optional; defaults to now)
 *   TARGET_ORG             sf org alias to write to (default: ci)
 *   SF_API_VERSION         REST API version (default: 62.0)
 *   DRY_RUN=1              print the computed record instead of upserting
 *
 * Upsert transport: `sf api request rest` PATCH to
 *   /sobjects/Release_Note__c/Version__c/<version>
 * (REST upsert-by-external-id — JSON body, so multiline notes need no CSV escaping).
 */
import { execFileSync } from 'node:child_process';

const tag = process.env.RELEASE_TAG;
if (!tag) {
    console.error('RELEASE_TAG is required (e.g. v1.3.0)');
    process.exit(1);
}
const version = tag.replace(/^v/, '');
const title = process.env.RELEASE_NAME || '';
const url = process.env.RELEASE_URL || '';
const publishedAt = process.env.RELEASE_PUBLISHED_AT || new Date().toISOString();
const targetOrg = process.env.TARGET_ORG || 'ci';
const apiVersion = process.env.SF_API_VERSION || '62.0';
const dryRun = process.env.DRY_RUN === '1';

function git(args) {
    // stderr ignored: the prevTag/range probes are expected to fail on the
    // first release; we catch and fall back, so the noise is just cosmetic.
    return execFileSync('git', args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] }).trim();
}

// Previous tag = the most recent tag reachable from this tag's parent. Empty on
// the very first release (then we summarise the whole history).
let prevTag = '';
try { prevTag = git(['describe', '--tags', '--abbrev=0', `${tag}^`]); } catch { /* first release */ }

const range = prevTag ? `${prevTag}..${tag}` : tag;
let subjects = [];
try {
    subjects = git(['log', range, '--no-merges', '--pretty=%s']).split('\n').filter(Boolean);
} catch {
    subjects = git(['log', '--no-merges', '--pretty=%s']).split('\n').filter(Boolean);
}

// Group by conventional-commit type; everything else falls under "Other".
const GROUPS = [
    ['feat', 'Features'],
    ['fix', 'Fixes'],
    ['perf', 'Performance'],
    ['refactor', 'Refactors'],
    ['revert', 'Reverts'],
    ['docs', 'Docs'],
];
const NOISE = new Set(['chore', 'ci', 'build', 'test', 'style']);
const buckets = new Map(GROUPS.map(([k]) => [k, []]));
const other = [];
const re = /^(\w+)(?:\([^)]*\))?(!)?:\s*(.+)$/;
for (const s of subjects) {
    const m = s.match(re);
    if (m && buckets.has(m[1])) buckets.get(m[1]).push(m[3]);
    else if (m && NOISE.has(m[1])) { /* drop housekeeping commits */ }
    else other.push(m ? m[3] : s);
}

const lines = [];
for (const [k, label] of GROUPS) {
    const items = buckets.get(k);
    if (items.length) {
        lines.push(`${label}`);
        for (const it of items) lines.push(`  • ${it}`);
        lines.push('');
    }
}
if (other.length) {
    lines.push('Other');
    for (const it of other) lines.push(`  • ${it}`);
    lines.push('');
}
let notes = lines.join('\n').trim();
if (!notes) notes = 'No notable changes.';
if (prevTag) notes += `\n\nChanges since ${prevTag}.`;

const record = {
    Release_Date__c: publishedAt,
    Title__c: title.slice(0, 255),
    Notes__c: notes.slice(0, 32000),
    GitHub_Url__c: url
};

console.log(`Release ${version} — ${subjects.length} commit(s) in ${range}`);
if (dryRun) {
    console.log('--- DRY RUN: Release_Note__c upsert payload ---');
    console.log('Version__c =', version);
    console.log(JSON.stringify(record, null, 2));
    process.exit(0);
}

const path = `/services/data/v${apiVersion}/sobjects/Release_Note__c/Version__c/${encodeURIComponent(version)}`;
execFileSync('sf', [
    'api', 'request', 'rest', path,
    '--method', 'PATCH',
    '--header', 'Content-Type: application/json',
    '--body', JSON.stringify(record),
    '--target-org', targetOrg
], { stdio: 'inherit' });
console.log(`Upserted Release_Note__c Version__c=${version}.`);
