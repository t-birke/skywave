// skywave-session.js — establishes the website's hardened session context.
//
// Lifecycle:
//   1. Wait briefly for the WebSDK to attach window.SalesforceInteractions.
//   2. Read its anonymousId (this is the deviceId Data Cloud already knows
//      about — preserve it). If the SDK is absent / blocked, send no
//      deviceId and let the server mint a synthetic UUID.
//   3. POST /api/website/session/init. Server responds with { contactId,
//      profile, ... } and Set-Cookie: skywave_proof (httpOnly, server-bound).
//   4. Cache the resolved profile in memory under window.skywaveSession for
//      the page modules (profile, bookings, etc.) to read.
//
// Subsequent pages use the proof cookie automatically — they don't need to
// re-read the WebSDK Id, the Heroku side is now the source of truth for
// identity. The WebSDK cookie continues serving Data Cloud event streaming.
//
// On any error (network down, SF down, blocked by privacy mode), we degrade
// to "anonymous browsing" — pages that need identity render a "sign-in
// required" affordance instead of crashing.

const SDK_WAIT_MS = 2000;

async function waitForSdk(maxMs = SDK_WAIT_MS) {
    if (window.SalesforceInteractions?.getAnonymousId) {
        return window.SalesforceInteractions;
    }
    return new Promise(resolve => {
        let elapsed = 0;
        const step = 100;
        const t = setInterval(() => {
            if (window.SalesforceInteractions?.getAnonymousId) {
                clearInterval(t);
                resolve(window.SalesforceInteractions);
                return;
            }
            elapsed += step;
            if (elapsed >= maxMs) {
                clearInterval(t);
                resolve(null);
            }
        }, step);
    });
}

function readSdkDeviceId() {
    try {
        const sdk = window.SalesforceInteractions;
        const id = sdk?.getAnonymousId?.();
        return id && /^[A-Za-z0-9_-]{8,64}$/.test(id) ? id : null;
    } catch (_) {
        return null;
    }
}

let sessionPromise = null;

export function initSession({ optedOut = false } = {}) {
    if (sessionPromise) return sessionPromise;
    sessionPromise = (async () => {
        await waitForSdk();
        const deviceId = readSdkDeviceId();
        const body = {};
        if (deviceId) body.deviceId = deviceId;
        if (optedOut) body.optedOut = true;
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
