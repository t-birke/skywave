# Web Connector Sitemap — Skywave Interactive

The sitemap declares **consent** at SDK init and **types pages** so post-demo analytics can segment by stage. It deliberately does NOT contain declarative click listeners — those events fire from `heroku/skywave-app/public/assets/site.js`.

## File to upload

`docs/web-connector-sitemap.js`

## Steps in `si`

1. Open the connector → **Sitemap** tab.
2. Upload `docs/web-connector-sitemap.js`.
3. Save. The Web Connector will begin serving the new sitemap on the next page load (CDN-cached, ~1 minute propagation).

## What this sitemap does

- `SalesforceInteractions.init({ cookieDomain: ... })`
  - **No consent declaration** — the consent screen in `site.js` calls `updateConsents({status: 'OptIn'})` when the user actually clicks Accept. Until then the SDK queues and drops events, which is correct.
  - **Cookie domain**: literal Heroku app host (`skywave-app-bb0e8666933b.herokuapp.com`). Single-host setup; cookies don't need to span subdomains.
- `SalesforceInteractions.initSitemap({ global, pageTypes, pageTypeDefault })`
  - **`pageTypes`**: 8 named page types matching `document.body.dataset.stage`. The consumer site sets that attribute whenever its SPA state advances (see `setStage()` in `site.js`).
  - **`pageTypeDefault: { name: 'other' }`**: catch-all so unmatched pages don't throw.

## What this sitemap does NOT do (and why)

| Anti-pattern from electra | Why it's gone here |
|---|---|
| `setLoggingLevel('trace')` at top | (Kept for now — verbose logs are too useful during active development to demote. **Switch to `'warn'` before any public rehearsal.**) |
| `OnException` listener phoning home to a Heroku endpoint | Fine for one-off debug; not a starting-point default. |
| Declarative click listeners (`actionMappingClicks`) | All event firing happens in `site.js` where the data is at hand. Declarative listeners hide intent across files. |
| `isAnonymous: 0` (number) | Schema treats it as a string — must be `'0'` or `'1'`. |
| `status: 'Opt In'` (with space) | Valid statuses are exact strings: `'OptIn'`, `'OptOut'`, `'NotSet'`. The space-version is silently ignored by the SDK. |
| Half-set/dead config (empty `pageTypeMapping`, commented-out functions) | Clean room. If we don't need it, it's not in the file. |

## How to verify after upload

1. Reload the Heroku consumer site in a browser.
2. Open DevTools → Network → filter `c360a`. You should see a request to the SDK script and one or more requests to `*.c360a.salesforce.com/*` carrying `events`.
3. Open DevTools → Application → Cookies. Look for an `_sfid_*` cookie scoped to `skywave-app-bb0e8666933b.herokuapp.com`. That's the SDK's `deviceId`.
4. In DevTools console: `document.body.dataset.stage` should match the current screen (e.g. `'consent'` on the Accept screen, `'waiting'` after).
5. After tapping Accept, DevTools console: `SalesforceInteractions.getAnonymousId()` returns a UUID-shaped string. That's what the consumer site passes as `sessionId` to `/api/session/start`.

## When to update

Edit this sitemap when:
- We add a new SPA stage (e.g. `survey-debrief`) — add a matching `pageTypes` entry.
- We move the Heroku app to a custom domain — update `cookieDomain`.
- **Pre-rehearsal cleanup:** demote `setLoggingLevel('trace')` to `'warn'` or `'error'` to keep the audience's projector quiet (and to avoid "what's that orange noise" questions during the demo).

Do **not** edit it for:
- New `userProfiling` events — they fire from `site.js`.
- New survey questions — those are content, served by `/skywave/survey/schema`.
- Click handlers — keep them in `site.js`.

## Source-of-truth

`docs/web-connector-sitemap.js` is the canonical. The Web Connector preserves it verbatim on save; if you ever export it back from the editor and the file diverges, treat the repo version as the source unless we know there was a one-off Setup-UI edit.
