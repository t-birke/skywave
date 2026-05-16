// Skywave Interactive consumer site — Phase 2 placeholder.
//
// Flow:
//   1. Consent screen.
//   2. On Accept, init Salesforce Interactions SDK (best-effort).
//   3. Read SDK anonymous cookie ID, POST to /api/session/start.
//   4. Open WS to skywave-app, render current stage, wait for stage_changed.
//
// Phase 2 keeps the survey UI a stub — that lands in step 6.

const CONSENT_KEY = 'skywave.consent.v1';
const root = document.getElementById('root');

let config = { interactionsSdkUrl: null };
let sdkReady = false;

async function loadConfig() {
    try {
        const res = await fetch('/api/config');
        config = await res.json();
    } catch (e) { console.warn('config fetch failed', e); }
}

function loadInteractionsSdk() {
    return new Promise((resolve) => {
        if (!config.interactionsSdkUrl || sdkReady) return resolve(sdkReady);
        const s = document.createElement('script');
        s.src = config.interactionsSdkUrl;
        s.async = true;
        s.onload = () => { sdkReady = !!window.SalesforceInteractions; resolve(sdkReady); };
        s.onerror = () => { console.warn('SDK failed to load'); resolve(false); };
        document.head.appendChild(s);
    });
}

const screens = {
    consent: renderConsent,
    waiting: renderWaiting
};

let state = {
    sessionId: null,
    demoSessionId: null,
    stage: null,
    ws: null,
    wsConnected: false
};

function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
        if (k === 'class') node.className = v;
        else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
        else node.setAttribute(k, v);
    }
    for (const c of children.flat()) {
        if (c == null) continue;
        node.append(c.nodeType ? c : document.createTextNode(String(c)));
    }
    return node;
}

function go(screen) {
    root.innerHTML = '';
    setStage(screen);
    screens[screen]();
}

// Mirror the current screen onto document.body so the Interactions SDK
// sitemap's isMatch callbacks (`document.body.dataset.stage === ...`)
// can pick up the active page-type. URL doesn't change between SPA
// screens, so dataset is the only stable signal.
function setStage(stage) {
    if (typeof document !== 'undefined' && document.body) {
        document.body.dataset.stage = stage;
    }
}

function renderConsent() {
    root.append(
        el('div', { class: 'center' },
            el('div', { class: 'brand' }, 'Skywave'),
            el('div', { class: 'brand-sub' }, 'Interactive'),
            el('div', { class: 'card' },
                el('h1', {}, 'Welcome aboard'),
                el('p', {},
                    'You’re about to participate in an interactive demo. ',
                    'During the demo we track how you interact with this website. ',
                    'You may also create a profile in a later step. ',
                    'All data is used only for this demo and one follow-up; ',
                    'everything is deleted within 14 days. ',
                    'Any prices shown are fictitious.'
                ),
                el('button', { class: 'btn', onclick: handleConsent }, 'Accept and continue')
            )
        )
    );
}

async function handleConsent() {
    try { localStorage.setItem(CONSENT_KEY, '1'); } catch (_) {}

    await loadInteractionsSdk();

    // Best-effort: tell the Interactions SDK the user opted in. If the SDK
    // hasn't loaded (no Web Connector configured yet on si), this no-ops.
    try {
        if (window.SalesforceInteractions) {
            window.SalesforceInteractions.updateConsents({
                purpose: window.SalesforceInteractions.ConsentPurpose.Tracking,
                provider: 'Skywave Interactive Demo',
                status: window.SalesforceInteractions.ConsentStatus.OptIn
            });
        }
    } catch (e) {
        console.warn('SDK consent failed', e);
    }

    // Prefer the SDK cookie ID as our session id when present; otherwise let
    // Apex mint one.
    const sdkId = (() => {
        try { return window.SalesforceInteractions?.getAnonymousId?.() || null; }
        catch (_) { return null; }
    })();

    try {
        const res = await fetch('/api/session/start', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ userAgent: navigator.userAgent, sessionId: sdkId })
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
        state.sessionId = data.sessionId;
        state.demoSessionId = data.demoSessionId;
        state.stage = data.currentState || 'idle';
        connectWs(data.wsUrl);
        go('waiting');
    } catch (e) {
        console.error('session/start failed', e);
        root.innerHTML = '';
        root.append(
            el('div', { class: 'card center' },
                el('h1', {}, 'Something went wrong'),
                el('p', {}, e.message),
                el('button', { class: 'btn', onclick: () => go('consent') }, 'Try again')
            )
        );
    }
}

function connectWs(wsUrl) {
    const ws = new WebSocket(wsUrl);
    state.ws = ws;
    ws.addEventListener('open', () => { state.wsConnected = true; renderStageIfWaiting(); });
    ws.addEventListener('close', () => { state.wsConnected = false; renderStageIfWaiting(); });
    ws.addEventListener('message', (m) => {
        try {
            const msg = JSON.parse(m.data);
            if (msg.type === 'stage_changed') {
                state.stage = msg.newState || state.stage;
                setStage(state.stage);
                renderStageIfWaiting();
            }
        } catch (e) { console.error(e); }
    });
}

function renderStageIfWaiting() {
    // Phase 2 step 6 will branch on state.stage to render the actual survey
    // UI etc. For now we always show the waiting card.
    if (root.querySelector('[data-screen="waiting"]')) renderWaiting();
}

function renderWaiting() {
    root.innerHTML = '';
    const stagePill = el('span',
        { class: state.wsConnected ? 'stage-pill' : 'stage-pill disconnected' },
        state.wsConnected ? (state.stage || '…') : 'reconnecting…'
    );
    root.append(
        el('div', { class: 'center', 'data-screen': 'waiting' },
            el('div', { class: 'brand' }, 'Skywave'),
            el('div', { class: 'brand-sub' }, 'Interactive'),
            el('div', { class: 'card' },
                el('h1', {}, 'You’re in'),
                el('p', {}, 'Stay on this screen. We’ll guide you through the experience together.'),
                el('div', { class: 'center' }, stagePill)
            ),
            el('div', { class: 'session-info' },
                el('div', { class: 'session-info-label' }, 'Session'),
                el('div', { class: 'session-info-value' }, state.sessionId || '')
            )
        )
    );
}

(async () => {
    await loadConfig();
    go('consent');
})();
