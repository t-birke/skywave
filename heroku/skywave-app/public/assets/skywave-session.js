// skywave-session.js — establishes the website's hardened session context.
//
// Lifecycle:
//   1. Load the Salesforce Interactions Web SDK (shared loader, see
//      skywave-sdk.js). Wait for SDK init to settle and resolve the
//      anonymous deviceId. This is the deviceId Data Cloud already
//      knows about — preserve it across the website + chat surfaces.
//   2. POST /api/website/session/init with the resolved deviceId (or
//      empty body if SDK is unavailable / blocked). Server responds
//      with { contactId, profile, ... } and Set-Cookie: skywave_proof
//      (httpOnly, server-bound).
//   3. Cache the resolved profile under window.skywaveSession for
//      page modules to read.
//
// Subsequent API calls use the proof cookie automatically — they don't
// re-read the WebSDK Id, the Heroku side is now the source of truth
// for identity. The WebSDK cookie keeps serving Data Cloud event
// streaming.
//
// On any error (SDK absent, network down, SF down) we degrade to
// "anonymous browsing" — pages that need identity render a friendly
// affordance instead of crashing.

import { loadSdk } from './skywave-sdk.js';

let sessionPromise = null;

export function initSession({ optedOut = false, force = false } = {}) {
    if (sessionPromise && !force) return sessionPromise;
    sessionPromise = (async () => {
        const { deviceId, source } = await loadSdk();
        const body = {};
        if (deviceId) body.deviceId = deviceId;
        if (optedOut) body.optedOut = true;
        // Stamp the source on console for visibility — useful when the
        // demo is being debugged. Server logs the same outcome via the
        // Tracking_Status__c stamp.
        console.log('[skywave] session/init source=' + source +
            (deviceId ? ' deviceId=' + deviceId.slice(0, 6) + '…' : ' (no deviceId)'));
        const res = await fetch('/api/website/session/init', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        if (!res.ok) {
            throw new Error(`session/init failed: HTTP ${res.status}`);
        }
        const data = await res.json();
        console.log('[skywave] session/init resolved contactId=' + data.contactId +
            ' tracking=' + data.trackingStatus);
        window.skywaveSession = data;
        return data;
    })();
    return sessionPromise;
}

export function getSession() {
    return window.skywaveSession || null;
}

// Convenience: same-origin authed fetch helper. The proof cookie rides
// automatically on credentials: 'same-origin' for both reads (GET) and
// state-changing requests (POST/PATCH/DELETE).
export async function api(method, path, body) {
    const opts = {
        method,
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' }
    };
    if (body !== undefined) opts.body = JSON.stringify(body);
    const res = await fetch(`/api/website${path}`, opts);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
        const err = new Error(data.error || `HTTP ${res.status}`);
        err.status = res.status;
        err.body = data;
        throw err;
    }
    return data;
}
