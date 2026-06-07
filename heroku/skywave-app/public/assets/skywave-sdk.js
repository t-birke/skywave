// Shared loader for the Salesforce Interactions Web SDK.
//
// One responsibility: load the SDK script, wait for init() to settle,
// and resolve the deviceId (= getAnonymousId()).
//
// Both the phone-demo flow (site.js) and the customer area
// (skywave-account.js) share the same SDK instance — calling load()
// multiple times is safe; the underlying script only loads once.
//
// The SDK script URL comes from /api/config (Heroku Config Var
// SF_INTERACTIONS_SDK_URL). If unset, load() resolves to null and the
// caller falls back to "no deviceId" — Heroku then mints a synthetic
// UUID at session/init time (Tracking_Status__c=synthetic).

let loadPromise = null;
let resolvedConfig = null;

async function fetchConfig() {
    if (resolvedConfig) return resolvedConfig;
    try {
        const r = await fetch('/api/config');
        resolvedConfig = await r.json();
    } catch (_) {
        resolvedConfig = {};
    }
    return resolvedConfig;
}

export async function loadSdk() {
    if (loadPromise) return loadPromise;
    loadPromise = (async () => {
        const config = await fetchConfig();
        if (!config.interactionsSdkUrl) {
            return { sdk: null, deviceId: null, source: 'no-sdk-url' };
        }

        // Skip script tag insertion if already loaded by another caller
        // (e.g. site.js loaded it earlier on the phone-demo path).
        if (!window.SalesforceInteractions) {
            await new Promise((resolve) => {
                const s = document.createElement('script');
                s.src = config.interactionsSdkUrl;
                s.async = true;
                s.onload = () => resolve();
                s.onerror = () => {
                    console.warn('[skywave-sdk] script failed to load:', config.interactionsSdkUrl);
                    resolve();
                };
                document.head.appendChild(s);
            });
        }

        if (!window.SalesforceInteractions) {
            return { sdk: null, deviceId: null, source: 'sdk-load-failed' };
        }

        // Wait for init to settle. Newer SDKs expose `ready` (promise);
        // older ones don't, so poll getAnonymousId() as a proxy.
        try {
            if (window.SalesforceInteractions.ready) {
                await window.SalesforceInteractions.ready;
            } else {
                for (let i = 0; i < 60 && !window.SalesforceInteractions.getAnonymousId?.(); i++) {
                    await new Promise((r) => setTimeout(r, 50));
                }
            }
        } catch (e) {
            console.warn('[skywave-sdk] init wait failed', e);
        }

        const id = (() => {
            try { return window.SalesforceInteractions.getAnonymousId?.() || null; }
            catch (_) { return null; }
        })();

        return {
            sdk: window.SalesforceInteractions,
            deviceId: id && /^[A-Za-z0-9_-]{8,64}$/.test(id) ? id : null,
            source: id ? 'websdk' : 'sdk-no-id'
        };
    })();
    return loadPromise;
}
