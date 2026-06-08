// skywave-session.js — establishes the website's hardened session context.
//
// Lifecycle (split-by-purpose; no shadow tracking, no pre-consent mint):
//   1. Page load: skywave-customer.js calls initSession() → reads /me
//      via proof cookie. If the cookie isn't there yet (no consent yet),
//      /me 401s and we degrade to "anonymous". If the cookie IS there
//      (returning visitor, or visitor who already consented this
//      session), we get back the Contact profile for the nav.
//   2. Consent moment: site.js calls /api/website/session/init directly
//      with the SDK's deviceId. That's the ONE place the proof cookie
//      gets minted and a Contact gets created/upgraded. Once that's
//      done, subsequent /me reads (refresh, profile_created WS push,
//      etc.) succeed.
//   3. Profile created via chat: WS pushes 'client_action profile_created'
//      from the Heroku relay → site.js calls initSession({force:true})
//      → re-reads /me → updates nav identity in place.
//
// On any error (proof cookie absent, server down, SDK absent) we
// degrade to "anonymous browsing" — pages that need identity render a
// friendly affordance instead of crashing.

import { loadSdk } from './skywave-sdk.js';

let sessionPromise = null;

export function initSession({ force = false } = {}) {
    if (sessionPromise && !force) return sessionPromise;
    sessionPromise = (async () => {
        // Load the SDK in the background — keeps the same persisted
        // deviceId fresh for the chat-side prechat flow. We don't pass
        // it to /me; the proof cookie is already the identity carrier.
        loadSdk().catch((e) => console.warn('[skywave-session] SDK load failed', e));
        const res = await fetch('/api/website/me', {
            method: 'GET',
            credentials: 'same-origin'
        });
        if (res.status === 401) {
            // No (or invalid) proof cookie — visitor hasn't consented
            // on this device yet. That's a normal state, not an error.
            window.skywaveSession = null;
            return null;
        }
        if (!res.ok) {
            throw new Error(`/me failed: HTTP ${res.status}`);
        }
        const data = await res.json();
        console.log('[skywave] /me resolved contactId=' + data.contactId +
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
