// Skywave Interactive consumer site.
//
// Flow:
//   1. Consent screen.
//   2. On Accept, init Salesforce Interactions SDK (best-effort).
//   3. Read SDK anonymous cookie ID, POST /api/session/start.
//   4. Open WS, render the screen the org's current stage tells us to.
//
// Stage → screen mapping:
//   scan / waiting / idle / null         → "you're in" waiting card
//   survey                                 → survey questions, one per screen
//   thanks                                 → "thanks, hold tight" card
//   anything else (agent, profile, race…)  → waiting card with the stage shown
//
// The presenter advances stage via the monitor LWC; phones follow via WS.

const CONSENT_KEY = 'skywave.consent.v1';
const root = document.getElementById('root');

// Stages on which the Agentforce chat button should be visible. Other
// stages (consent / survey / waiting) keep it hidden via utilAPI.
const AGENT_STAGES = new Set(['agent_book', 'agent_seat_fail', 'agent_seat_pass']);

let config = { interactionsSdkUrl: null, esw: null };
let sdkReady = false;
let eswReady = false;        // bootstrap loaded + onEmbeddedMessagingReady fired
let eswButtonVisible = false; // tracks utilAPI.show/hideChatButton state

async function loadConfig() {
    try {
        const res = await fetch('/api/config');
        config = await res.json();
    } catch (e) { console.warn('config fetch failed', e); }
}

// Load the ECv2 (Enhanced Messaging for Web v2) chat snippet. Idempotent —
// safe to call multiple times. Wires the deviceId as a hidden prechat
// parameter (`Session_ID`) and immediately hides the chat button until a
// later stage flip reveals it.
//
// Requires the four ESW values from /api/config (driven by Heroku Config Vars
// SF_ESW_*). If any is missing we silently skip — the consumer site still
// works, just without chat.
async function loadEswSnippet(deviceId) {
    if (eswReady) return true;
    const esw = config.esw || {};
    if (!esw.orgId || !esw.escName || !esw.siteUrl || !esw.scrt2Url) {
        console.warn('[esw] config incomplete; skipping chat snippet load', esw);
        return false;
    }

    // The bootstrap script defines window.embeddedservice_bootstrap and
    // installs onEmbeddedMessagingReady before we need it.
    await new Promise((resolve) => {
        const s = document.createElement('script');
        s.src = `${esw.siteUrl}/assets/js/bootstrap.min.js`;
        s.async = true;
        s.onload = () => resolve();
        s.onerror = () => { console.warn('[esw] bootstrap.min.js failed to load'); resolve(); };
        document.head.appendChild(s);
    });

    if (!window.embeddedservice_bootstrap) {
        console.warn('[esw] embeddedservice_bootstrap is undefined after script load');
        return false;
    }

    // setHiddenPrechatFields and utilAPI.hideChatButton are only available
    // after the snippet finishes booting and dispatches onEmbeddedMessagingReady.
    const ready = new Promise((resolve) => {
        let settled = false;
        const onReady = () => {
            if (settled) return;
            settled = true;
            try {
                if (deviceId) {
                    window.embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({
                        Session_ID: { value: deviceId }
                    });
                    console.log('[esw] Session_ID prechat field set:', deviceId);
                }
            } catch (e) { console.warn('[esw] setHiddenPrechatFields failed', e); }
            try {
                window.embeddedservice_bootstrap.utilAPI.hideChatButton();
                eswButtonVisible = false;
            } catch (e) { console.warn('[esw] hideChatButton failed', e); }
            resolve();
        };
        window.addEventListener('onEmbeddedMessagingReady', onReady, { once: true });
        // Defensive timeout: if Ready never fires, resolve so we don't hang.
        setTimeout(() => { if (!settled) { settled = true; console.warn('[esw] ready timeout'); resolve(); } }, 8000);
    });

    try {
        window.embeddedservice_bootstrap.settings.language = 'en_US';
        window.embeddedservice_bootstrap.init(
            esw.orgId, esw.escName, esw.siteUrl, { scrt2URL: esw.scrt2Url }
        );
    } catch (e) {
        console.warn('[esw] init failed', e);
        return false;
    }

    await ready;
    eswReady = true;
    return true;
}

// Toggle the chat button based on whether the current stage is one of the
// agent stages. Idempotent — safe to call on every render().
function syncEswButtonVisibility() {
    if (!eswReady || !window.embeddedservice_bootstrap?.utilAPI) return;
    const shouldShow = AGENT_STAGES.has(state.stage);
    if (shouldShow && !eswButtonVisible) {
        try {
            window.embeddedservice_bootstrap.utilAPI.showChatButton();
            eswButtonVisible = true;
        } catch (e) { console.warn('[esw] showChatButton failed', e); }
    } else if (!shouldShow && eswButtonVisible) {
        try {
            window.embeddedservice_bootstrap.utilAPI.hideChatButton();
            eswButtonVisible = false;
        } catch (e) { console.warn('[esw] hideChatButton failed', e); }
    }
}

async function loadInteractionsSdk() {
    if (!config.interactionsSdkUrl || sdkReady) return sdkReady;
    await new Promise((resolve) => {
        const s = document.createElement('script');
        s.src = config.interactionsSdkUrl;
        s.async = true;
        s.onload = () => resolve();
        s.onerror = () => { console.warn('SDK script failed to load'); resolve(); };
        document.head.appendChild(s);
    });
    if (!window.SalesforceInteractions) {
        console.warn('SDK script loaded but SalesforceInteractions is undefined');
        return false;
    }
    // The script also runs the sitemap which calls SalesforceInteractions.init().
    // updateConsents() and sendEvent() silently no-op if called before init's
    // promise resolves — wait for it explicitly before continuing.
    try {
        if (window.SalesforceInteractions.ready) {
            await window.SalesforceInteractions.ready;
        } else if (typeof window.SalesforceInteractions.init === 'function') {
            // Older SDK versions: poll for getAnonymousId() returning a value
            // as a proxy for "init has resolved."
            for (let i = 0; i < 50 && !window.SalesforceInteractions.getAnonymousId?.(); i++) {
                await new Promise((r) => setTimeout(r, 50));
            }
        }
    } catch (e) { console.warn('SDK init wait failed', e); }
    sdkReady = true;
    return true;
}

let state = {
    sessionId: null,
    demoSessionId: null,
    stage: null,
    ws: null,
    wsConnected: false,
    survey: null,        // { questions: [...] } — fetched once on Accept
    surveyIndex: 0,      // which question we're showing
    answeredKeys: new Set() // questionKeys we've already answered (idempotency)
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

// Mirror the current screen onto document.body so the Interactions SDK
// sitemap's isMatch callbacks can pick up the active page-type. URL
// doesn't change between SPA screens, so dataset is the only stable signal.
function setBodyStage(stage) {
    if (typeof document !== 'undefined' && document.body) {
        document.body.dataset.stage = stage;
    }
}

// Single render function — picks a screen based on state.stage. Called
// after every stage change from the WS handler, after consent, and
// after each survey answer (to advance to the next question).
function render() {
    root.innerHTML = '';
    const stage = state.stage;

    if (stage === 'survey' && state.surveyIndex < (state.survey?.questions?.length ?? 0)) {
        setBodyStage('survey');
        renderSurveyQuestion();
    } else if (stage === 'survey') {
        setBodyStage('survey');
        renderThanks();
    } else if (stage === 'thanks') {
        setBodyStage('thanks');
        renderThanks();
    } else {
        setBodyStage(stage || 'waiting');
        renderWaiting();
    }

    // After dataset.stage is set, ask the SDK to re-evaluate which sitemap
    // pageType matches. The SDK normally only re-runs isMatch on URL change,
    // and our SPA never changes URLs.
    try {
        if (sdkReady && window.SalesforceInteractions?.reinit) {
            window.SalesforceInteractions.reinit();
        }
    } catch (e) { /* older SDK without reinit; ignore */ }

    // Reveal/hide the Agentforce chat button based on the current stage.
    syncEswButtonVisibility();
}

// ── Consent ────────────────────────────────────────────────────────────────

function renderConsent() {
    setBodyStage('consent');
    root.innerHTML = '';
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

    // The SDK's accepted status literal is "Opt In" (with a space) —
    // that's what the c360a runtime expects, and it's what
    // SalesforceInteractions.ConsentStatus.OptIn resolves to. The "OptIn"
    // (no space) form gets rejected with "Unrecognized consent status".
    // Confirmed empirically against the c360a SDK in May 2026.
    //
    // Provider must match the sitemap declaration (none, since we removed
    // it from the sitemap) so the consent record is unambiguous.
    try {
        if (window.SalesforceInteractions) {
            const SI = window.SalesforceInteractions;
            const consents = [{
                purpose:  SI.ConsentPurpose?.Tracking ?? 'Tracking',
                provider: 'Skywave Interactive',
                status:   SI.ConsentStatus?.OptIn ?? 'Opt In'
            }];
            await Promise.resolve(SI.updateConsents(consents));
            console.log('[skywave] consent applied:', consents);
        }
    } catch (e) {
        console.warn('SDK consent failed', e);
    }

    const sdkId = (() => {
        try { return window.SalesforceInteractions?.getAnonymousId?.() || null; }
        catch (_) { return null; }
    })();

    // Fire a partyIdentification event keyed on the anonymous deviceId. This
    // creates a PartyIdentification DMO row that Identity Resolution can
    // match against once a CRM-side Contact lands with the same deviceId
    // mirrored into Contact.AnonymousId__c (Phase 4).
    try {
        if (window.SalesforceInteractions && sdkId) {
            window.SalesforceInteractions.sendEvent({
                user: { attributes: {
                    eventType: 'partyIdentification',
                    IDName:    'AnonymousId',
                    IDType:    'CookieId',
                    userId:    sdkId
                }}
            });
        }
    } catch (e) {
        console.warn('partyIdentification sendEvent failed', e);
    }

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
        await loadSurveySchema();   // best-effort prefetch — used when stage flips to survey
        // Pre-load + hide the Agentforce chat snippet now so it's warm by the
        // time the presenter advances the demo to an agent stage. The
        // deviceId is the same one that travels via the partyIdentification
        // event above; it lands on MessagingSession via the hidden Session_ID
        // prechat parameter.
        loadEswSnippet(sdkId).catch((e) => console.warn('[esw] snippet load failed', e));
        render();
    } catch (e) {
        console.error('session/start failed', e);
        renderError(e.message);
    }
}

function renderError(message) {
    root.innerHTML = '';
    root.append(
        el('div', { class: 'card center' },
            el('h1', {}, 'Something went wrong'),
            el('p', {}, message),
            el('button', { class: 'btn', onclick: renderConsent }, 'Try again')
        )
    );
}

// ── WS ─────────────────────────────────────────────────────────────────────

function connectWs(wsUrl) {
    const ws = new WebSocket(wsUrl);
    state.ws = ws;
    ws.addEventListener('open',  () => { state.wsConnected = true;  render(); });
    ws.addEventListener('close', () => { state.wsConnected = false; render(); });
    ws.addEventListener('message', (m) => {
        try {
            const msg = JSON.parse(m.data);
            if (msg.type === 'stage_changed') {
                const previous = state.stage;
                state.stage = msg.newState || state.stage;
                if (previous !== state.stage) {
                    // Reset survey position when (re)entering the survey stage
                    if (state.stage === 'survey') state.surveyIndex = 0;
                    render();
                }
            }
        } catch (e) { console.error(e); }
    });
}

// ── Survey ─────────────────────────────────────────────────────────────────

async function loadSurveySchema() {
    try {
        const res = await fetch('/api/survey/schema');
        if (!res.ok) throw new Error(`schema HTTP ${res.status}`);
        state.survey = await res.json();
    } catch (e) {
        console.warn('loadSurveySchema failed', e);
    }
}

function renderSurveyQuestion() {
    const q = state.survey?.questions?.[state.surveyIndex];
    if (!q) {
        renderThanks();
        return;
    }
    const total = state.survey.questions.length;
    const num = state.surveyIndex + 1;
    root.append(
        el('div', { class: 'survey-screen' },
            el('div', { class: 'survey-progress' },
                el('span', {}, `Question ${num} of ${total}`)
            ),
            el('h1', { class: 'survey-question' }, q.text),
            el('div', { class: 'survey-options' },
                ...q.options.map((opt) =>
                    el('button',
                        {
                            class: 'survey-option',
                            'data-question-key': q.key,
                            'data-answer-key': opt.key,
                            'data-question-text': q.text,
                            'data-answer-text': opt.text,
                            onclick: handleAnswer
                        },
                        opt.imageUrl
                            ? el('img', { class: 'survey-option-img', src: opt.imageUrl, alt: opt.text })
                            : el('div', { class: 'survey-option-img placeholder' }),
                        el('span', { class: 'survey-option-label' }, opt.text)
                    )
                )
            )
        )
    );
}

async function handleAnswer(event) {
    const t = event.currentTarget;
    const questionKey = t.dataset.questionKey;
    const answerKey   = t.dataset.answerKey;
    const questionText = t.dataset.questionText;
    const answerText   = t.dataset.answerText;

    // Idempotency: if we re-render the same question (e.g. due to a stage
    // re-broadcast) we don't want to fire two userProfiling events.
    const dedupeKey = `${questionKey}:${state.surveyIndex}`;
    if (state.answeredKeys.has(dedupeKey)) return;
    state.answeredKeys.add(dedupeKey);

    // Visual: lock the row in.
    Array.from(root.querySelectorAll('.survey-option')).forEach((b) => {
        b.disabled = true;
        if (b === t) b.classList.add('selected');
    });

    // Path A — persistence + agent grounding via Interactions SDK.
    try {
        if (window.SalesforceInteractions) {
            window.SalesforceInteractions.sendEvent({
                interaction: {
                    name: 'userProfiling',
                    eventType: 'userProfiling',
                    attributes: {
                        question:    questionText,
                        questionKey: questionKey,
                        answer:      answerText,
                        answerKey:   answerKey
                    }
                }
            });
        }
    } catch (e) {
        console.warn('userProfiling sendEvent failed', e);
    }

    // Path B — live monitor tile via Apex relay.
    try {
        await fetch('/api/survey/answer', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                sessionId:    state.sessionId,
                questionKey,
                answerKey,
                questionText,
                answerText
            })
        });
    } catch (e) {
        console.warn('survey/answer relay failed', e);
    }

    // Advance to next question after a short visual confirmation.
    setTimeout(() => {
        state.surveyIndex += 1;
        render();
    }, 350);
}

// ── Waiting / thanks ───────────────────────────────────────────────────────

function renderWaiting() {
    const stagePill = el('span',
        { class: state.wsConnected ? 'stage-pill' : 'stage-pill disconnected' },
        state.wsConnected ? (state.stage || '…') : 'reconnecting…'
    );
    root.append(
        el('div', { class: 'center' },
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

function renderThanks() {
    root.append(
        el('div', { class: 'center' },
            el('div', { class: 'brand' }, 'Skywave'),
            el('div', { class: 'brand-sub' }, 'Interactive'),
            el('div', { class: 'card' },
                el('h1', {}, 'Thanks!'),
                el('p', {}, 'Your preferences are recorded. Hold tight — we’ll guide you to the next step.')
            )
        )
    );
}

// ── Entry ──────────────────────────────────────────────────────────────────

(async () => {
    await loadConfig();
    renderConsent();
})();
