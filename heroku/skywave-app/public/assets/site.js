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

import { renderWebsite } from './website.js';
import { startCustomer, refreshIdentity } from './skywave-customer.js';
import { MiawUI } from './miaw-ui.js';

// NOTE: we used to mirror "consent given" into localStorage under
// 'skywave.consent.v1'. That was shadow tracking — the WebSDK already
// persists consent state in its own cookie, and that's the source of
// truth. Boot now reads the SDK's consent state directly (see
// readSdkConsent below); localStorage is no longer touched.
//
// `root` is the modal content container — the demo flow renders INTO the
// modal that overlays the airline website. The website itself is the page.
const root = document.getElementById('modal-content');
const modalRoot = document.getElementById('modal-root');
const siteRoot = document.getElementById('site-root');

// Modal visibility:
//   - 'open'   : the modal is shown (consent / survey / thanks / waiting)
//   - 'hidden' : the modal is gone (agent stages → visitor uses chat icon)
//
// `userClosed` lets the visitor dismiss the modal at any time. We re-open it
// on the next stage transition, since each new stage has fresh content the
// visitor needs to see.
let userClosed = false;

function showModal() {
    if (!modalRoot) return;
    userClosed = false;
    modalRoot.dataset.state = 'open';
    modalRoot.setAttribute('aria-hidden', 'false');
    syncEswButtonVisibility();
}
function hideModal() {
    if (!modalRoot) return;
    modalRoot.dataset.state = 'hidden';
    modalRoot.setAttribute('aria-hidden', 'true');
    syncEswButtonVisibility();
}
function userCloseModal() {
    userClosed = true;
    hideModal();
    // Phase 2: if we're consented but mid-funnel, persist whatever
    // partial state we have so a re-open doesn't lose the visitor's
    // progress. Idempotent on the server side.
    maybeSendAbandon('user-closed');
}

// Wire backdrop + X button to close.
if (modalRoot) {
    modalRoot.addEventListener('click', (e) => {
        const t = e.target;
        if (t && t.closest && t.closest('[data-action="close-modal"]')) {
            userCloseModal();
        }
    });
}

// Signup mode: visitor landed on /signup or /join. Consent still required,
// but we drop the audience-demo flow (no Demo_Session start, no WS, no
// survey, no chat warm-up) and send them straight to the #profile customer-
// area to create an account. Detected from the pathname at boot — no query
// param so it survives reloads as a clean URL.
const SIGNUP_MODE = (() => {
    try {
        const p = (window.location.pathname || '').replace(/\/+$/, '');
        return p === '/signup' || p === '/join';
    } catch (_) { return false; }
})();

// Render the website backdrop once on boot. It never re-renders.
if (siteRoot) renderWebsite(siteRoot);

// Customer-area features (always-on identity + #profile / #bookings /
// #book hash routes). Boots in parallel with the phone-demo flow:
//   - kicks off /api/website/session/init in the background after the
//     WebSDK is ready, so the nav greeting can update reactively
//   - renders into the inline <section id="customer-area"> when a
//     customer hash route is active, hiding the .main promo content but
//     keeping hero + nav + footer visible
// Phone-demo modal is independent — runs in #modal-root above all this.
startCustomer();

// Canonical stage order. The visitor walks down this list at their own
// pace; the moderator's stage is a *ceiling*, not a teleport target.
// Stages must match the Demo_Session__c.State__c picklist values so the
// WS stage_changed payload can be looked up by name.
const STAGE_ORDER = [
    'idle',
    'scan',
    'survey',
    'thanks',          // post-survey waiting card; auto-set when survey ends
    'agent_book',
    'profile',
    'c360',
    'agent_seat_fail',
    'agent_seat_pass',
    'race',
    'slack',
    'done'
];

function stageIndex(stage) {
    const i = STAGE_ORDER.indexOf(stage);
    return i === -1 ? 0 : i;
}

// Stages on which the Agentforce chat button should be visible. Other
// stages (consent / survey / waiting) keep it hidden via utilAPI.
const AGENT_STAGES = new Set(['agent_book', 'agent_seat_fail', 'agent_seat_pass']);

let config = { interactionsSdkUrl: null, esw: null };
let sdkReady = false;
let eswReady = false;        // custom chat client mounted
let miawUi = null;           // MiawUI instance (custom chat client)

async function loadConfig() {
    try {
        const res = await fetch('/api/config');
        config = await res.json();
    } catch (e) { console.warn('config fetch failed', e); }
}

// Resolve the visitor's approximate location from their IP via ipinfo.io
// (token served from /api/config, see SECRETS.md). Best-effort: on any
// failure we leave state.geo null and the booking flow just won't have a
// pre-filled home airport. ipinfo returns loc as "lat,lon".
async function loadGeo() {
    const token = config?.ipinfoToken;
    if (!token) { console.log('[geo] no ipinfo token; skipping'); return; }
    try {
        const res = await fetch(`https://ipinfo.io/json?token=${token}`);
        const data = await res.json();
        let lat = null, lon = null;
        if (typeof data.loc === 'string' && data.loc.includes(',')) {
            const [la, lo] = data.loc.split(',');
            lat = parseFloat(la); lon = parseFloat(lo);
        }
        state.geo = {
            city: data.city || null,
            region: data.region || null,
            country: data.country || null,
            lat: Number.isFinite(lat) ? lat : null,
            lon: Number.isFinite(lon) ? lon : null
        };
        console.log('[geo] resolved:', state.geo);
    } catch (e) {
        console.warn('[geo] ipinfo lookup failed', e);
    }
}

// Load the ECv2 (Enhanced Messaging for Web v2) chat snippet. Idempotent —
// safe to call multiple times. Wires the deviceId as a hidden prechat
// parameter (`Session_ID`) and immediately hides the chat button until a
// later stage flip reveals it.
//
// POST to the public Skywave_ContactUpsert endpoint (anonymous, exposed
// via the skywave_api Force.com Site). Routed through the team's CORS
// proxy because Salesforce Sites' CORS handling for guest-callable
// Apex is unreliable. Fire-and-forget; a Platform Event trigger handles
// the actual Contact upsert in System Mode.
const CONTACT_UPSERT_URL =
    'https://abc-proxy-2552551e6d2c.herokuapp.com/' +
    'https://trailsignup-fb3f5426f87c5d.my.salesforce-sites.com/skywave/services/apexrest/skywave/contact/upsert';

// Persist the visitor's mid-funnel exit so a re-open or a follow-up
// chat still has signal to ground on. Idempotent server-side. Only
// fires when:
//   - the visitor has actually consented (otherwise we have no
//     Contact yet, and there's nothing to write to);
//   - the proof cookie has been minted (sessionReady);
//   - the funnel isn't already complete (post-survey + post-profile
//     means there's nothing partial to capture).
//
// Fires once per page load — `state.abandonSent` flips on first call
// so a rapid open/close/open sequence doesn't generate noise.
function maybeSendAbandon(reason) {
    if (state.abandonSent) return;
    if (!state.consented || !state.sessionReady) return;
    if (state.surveyComplete && state.profileAlreadyComplete) return;
    state.abandonSent = true;

    const partial = Object.keys(state.answers || {}).length > 0
        ? state.answers : undefined;
    const body = JSON.stringify({
        reason,
        partialAnswers: partial
    });
    // Use sendBeacon when available so the request survives the page
    // navigation that often follows a modal-close (visitor may then
    // refresh or leave the tab). Fall back to plain fetch otherwise.
    try {
        if (navigator.sendBeacon) {
            const blob = new Blob([body], { type: 'application/json' });
            const ok = navigator.sendBeacon('/api/website/session/abandon', blob);
            if (ok) return;
        }
    } catch (_) { /* fall through to fetch */ }
    fetch('/api/website/session/abandon', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body,
        keepalive: true
    }).catch((e) => console.warn('[skywave] abandon failed', e));
}

function postContactUpsert(payload) {
    fetch(CONTACT_UPSERT_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    }).then((r) => {
        console.log(`[skywave] /skywave/contact/upsert (${payload.type}) ${r.status}`);
    }).catch((err) => {
        console.warn(`[skywave] /skywave/contact/upsert (${payload.type}) failed`, err);
    });
}

// Boot the custom MIAW chat client (replaces the ECv2 embedded widget).
//
// Why custom: the official ECv2 client dies on iOS Safari in a redirect
// loop — its session cookie is set on *.my.site.com but the host page is
// *.herokuapp.com (different public-suffix domains), so the cookie is
// third-party and iOS ITP drops it. We can't share a registrable domain
// (the demo must stay transferable), so we talk to the scrt2 REST API
// directly: the auth JWT lives in first-party localStorage on THIS origin
// and there is nothing for ITP to block. See docs/ecv2-reference/.
//
// The function name + signature are kept (loadEswSnippet) so both call
// sites and the button-visibility logic keep working unchanged.
//
// Identity: the custom client generates its own conversation UUID, which
// the platform exposes as Conversation.ConversationIdentifier. We fire the
// SAME chat_start POST the ECv2 path used; the existing Contact-update
// trigger resolves that UUID to the internal MessagingSession.ConversationId
// and stamps the visitor's Contact so Skywave_ResolveSession matches. No
// new identity mechanism — verified against the org.
async function loadEswSnippet(deviceId) {
    // Idempotency guard — set SYNCHRONOUSLY before the async mount. There
    // are two call sites (session-start and resume); without flipping the
    // flag up front, both can slip past `if (eswReady)` during the await
    // gap and mount TWO MiawUI instances → two FABs, two message handlers,
    // every message rendered twice. Flip first; roll back only on failure.
    if (eswReady || miawUi) return true;
    const esw = config.esw || {};
    // siteUrl is the published LWR site; scrt2Url + orgId + escName are what
    // the REST client needs. escName is the EmbeddedServiceConfig dev name.
    if (!esw.orgId || !esw.escName || !esw.scrt2Url) {
        console.warn('[miaw] config incomplete; skipping chat client load', esw);
        return false;
    }
    eswReady = true;  // claim the slot before any await

    try {
        miawUi = new MiawUI({
            orgId: esw.orgId,
            developerName: esw.escName,
            scrt2Url: esw.scrt2Url,
            deviceId,
            title: 'Skywave Airlines',

            // Conversation opened: stamp identity via the existing trigger
            // path (carry IP geo too, exactly like the old ConversationStarted
            // handler) so the visitor's Contact is resolvable on turn 1.
            onConversationOpened: (conversationId) => {
                if (!conversationId || !deviceId) return;
                const csPayload = {
                    type: 'chat_start',
                    deviceId,
                    demoSessionId: state.demoSessionId,
                    conversationId
                };
                if (state.geo) {
                    if (state.geo.city)        csPayload.geoCity    = state.geo.city;
                    if (state.geo.region)      csPayload.geoRegion  = state.geo.region;
                    if (state.geo.country)     csPayload.geoCountry = state.geo.country;
                    if (state.geo.lat != null) csPayload.geoLat     = state.geo.lat;
                    if (state.geo.lon != null) csPayload.geoLon     = state.geo.lon;
                }
                postContactUpsert(csPayload);
            },

            // Card writes all go through the proof-cookie'd Heroku->Apex
            // path (ownership-checked server-side); the UI cues the agent
            // after each — ECv2-faithful (the LWCs did Apex + verify-cue).

            onSeatConfirm: async (sel) => {
                const res = await fetch('/api/website/bookings/seat-by-id', {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        bookingSegmentId: sel.bookingSegmentId,
                        newSeat: sel.newSeatNumber
                    })
                });
                if (!res.ok) throw new Error(`seat change ${res.status}`);
                return res.json();
            },

            // Demo Pay: charge the booking. Route keys on the code in the URL.
            onPay: async (sel) => {
                const res = await fetch(`/api/website/bookings/${encodeURIComponent(sel.bookingCode)}/pay`, {
                    method: 'POST',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({})
                });
                if (!res.ok) throw new Error(`payment ${res.status}`);
                return res.json();
            },

            // Profile save: reuse the existing PUT /profile route (handles
            // text fields + avatar base64 + the avatar->public-URL pipeline).
            onSaveProfile: async (data) => {
                const body = {
                    firstName: data.firstName, lastName: data.lastName,
                    email: data.email, phone: data.phone
                };
                if (data.avatarBase64) {
                    body.avatarBase64 = data.avatarBase64;
                    body.avatarFileName = data.avatarFileName;
                }
                const res = await fetch('/api/website/profile', {
                    method: 'PUT',
                    credentials: 'same-origin',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body)
                });
                if (!res.ok) throw new Error(`profile save ${res.status}`);
                return res.json();
            }
        });
        await miawUi.mount();
    } catch (e) {
        console.warn('[miaw] chat client init failed', e);
        // Roll back the claimed slot so a later call can retry cleanly.
        eswReady = false;
        miawUi = null;
        return false;
    }

    // CRITICAL: re-sync visibility now that the root EXISTS. loadEswSnippet is
    // called fire-and-forget and mount() is async, so the syncEswButtonVisibility
    // calls at the call sites (resumeSession/render) ran BEFORE miawUi.root
    // existed and were no-ops. Without this, a resumed (already-consented,
    // survey-done) visitor gets no FAB — intermittently, worse on slower iOS
    // where the mount loses the race against other sync calls.
    syncEswButtonVisibility();
    return true;
}

// Show/hide the custom chat client's launch button.
//
// We own the FAB now (it's part of MiawUI, not a platform iframe widget),
// so visibility is a direct style toggle — no more CSS data-attribute
// dance or fighting the platform-broken ECv2 hideChatButton API.
//
// Rule (unchanged): the button is visible whenever the visitor has
// consented AND the demo modal is not currently on screen. That covers:
//   - user X'd the modal mid-survey → chat available as fallback
//   - moderator is on an agent stage → modal is hidden, chat is the
//     entire interaction surface
//   - returning visitor whose effective stage drops the modal → chat
//     is reachable for help even outside the agent stages
// Pre-consent we keep it hidden — nothing for the agent to do without an
// identity, and the consent screen is the only thing to engage with.
function syncEswButtonVisibility() {
    if (typeof document === 'undefined' || !document.body) return;
    const modalOpen = modalRoot && modalRoot.dataset.state === 'open';
    const visible = state.consented && !modalOpen;
    document.body.dataset.eswVisible = visible ? '1' : '0';
    // Drive the actual client root (explicit value — CSS default is none).
    // While the panel is open we keep it visible regardless of stage (the
    // FAB hides itself when open); otherwise show only when eligible.
    if (miawUi && miawUi.root) {
        miawUi.root.style.display = (visible || miawUi.open) ? 'block' : 'none';
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
    // Visitor has gone through (or has previously consented via the
    // WebSDK) the consent screen. Drives chat-button eligibility (Phase
    // 5: chat button shows whenever consented && modal not on screen)
    // and the abandon endpoint (Phase 2: only fires post-consent).
    consented: false,
    // True once /api/website/session/init has run, so we have a proof
    // cookie + a Contact in the org. Triggered by the SDK-consent path
    // OR by Accept-consent. Don't fire abandon writes before this.
    sessionReady: false,
    // True once the visitor finished the survey OR we observed an
    // existing Contact with Skywave_Survey_Json__c populated (returning
    // visitor). Read from /session/peek on boot, set to true on
    // postSurveyComplete().
    surveyAlreadyComplete: false,
    profileAlreadyComplete: false,
    // Visitor's own progress through the stage list. Set initially to
    // 'idle' on consent, then advanced as they complete each step
    // (e.g. survey → thanks). Never advanced beyond moderatorStage.
    visitorStage: null,
    // Moderator's current stage — pushed via WS on every stage_changed
    // event. Acts as a ceiling: visitor can never see a stage past it.
    moderatorStage: null,
    ws: null,
    wsConnected: false,
    survey: null,        // { questions: [...] } — fetched once on Accept
    surveyIndex: 0,      // which question we're showing
    answeredKeys: new Set(), // questionKeys we've already answered (idempotency)
    answers: {},         // questionKey → { questionText, answerText, answerKey }
    surveyComplete: false, // true once we've POSTed the survey summary upstream
    geo: null            // { city, region, country, lat, lon } from ipinfo.io, or null
};

// Effective stage shown to the visitor.
//
// Up to and including the survey, the visitor walks the funnel at
// their own pace, capped by the moderator. Past `thanks` (i.e. once
// the visitor has finished the survey) the moderator drives the
// screen — there's nothing past survey the visitor can self-advance
// through, and the agent stages, profile, c360 etc. only make sense
// once the moderator is leading the room there.
//
// Scenarios:
//  • Late arrival (mod on agent_book, visitor just consented):
//    visitor walks idle → survey → thanks; once they hit thanks,
//    effectiveStage jumps to the moderator's stage (agent_book).
//  • Early finisher (mod on survey, visitor done):
//    visitor sits on thanks; moderator's still on survey, so
//    effectiveStage = thanks. When mod advances past thanks, visitor
//    follows.
function effectiveStage() {
    const v = state.visitorStage;
    const m = state.moderatorStage;
    if (!v && !m) return null;
    if (!v) return m;
    if (!m) return v;
    // Past thanks → moderator drives the screen.
    if (stageIndex(v) >= stageIndex('thanks')) return m;
    // Up to thanks → visitor walks at their own pace, capped by mod.
    return stageIndex(v) <= stageIndex(m) ? v : m;
}

// Whether to show the holding card. True when visitor has finished
// their self-driven prefix (reached `thanks`) but the moderator hasn't
// caught up yet. Past thanks the moderator drives, so the visitor can
// always see *something* once moderator is past thanks too.
function isWaitingForModerator() {
    const v = state.visitorStage;
    const m = state.moderatorStage;
    if (!v || !m) return false;
    return stageIndex(v) >= stageIndex('thanks')
        && stageIndex(m) < stageIndex('thanks');
}

// Advance the visitor's own stage forward (never back) to `target`.
// No-op if target is null/unknown or not later in STAGE_ORDER.
function advanceVisitorStage(target) {
    if (!target) return;
    if (stageIndex(target) <= stageIndex(state.visitorStage)) return;
    state.visitorStage = target;
}

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

// Single render function — picks a screen based on effectiveStage().
// Called after every stage change from the WS handler, after consent,
// and after each survey answer.
//
// The render fills the MODAL (#modal-content). The website (#site-root)
// renders once on boot and is never touched here. Stages decide whether the
// modal is visible at all:
//
//   agent_book / agent_seat_fail / agent_seat_pass  → modal HIDDEN, visitor
//                                                     uses chat icon on the
//                                                     airline page itself
//   everything else                                 → modal OPEN with the
//                                                     stage-appropriate
//                                                     content
function render() {
    root.innerHTML = '';

    const stage = effectiveStage();

    // Agent stages: hide the modal entirely. The visitor interacts with the
    // chat icon (made visible by syncEswButtonVisibility below) on the
    // airline website.
    if (AGENT_STAGES.has(stage)) {
        setBodyStage(stage);
        hideModal();
        try {
            if (sdkReady && window.SalesforceInteractions?.reinit) {
                window.SalesforceInteractions.reinit();
            }
        } catch (e) { /* ignore */ }
        syncEswButtonVisibility();
        return;
    }

    // Visitor has caught up to (or past) the moderator's ceiling: show
    // a holding screen until the moderator advances. Don't surface
    // visitor-side progress they can't act on.
    if (isWaitingForModerator()) {
        setBodyStage('waiting');
        renderHolding();
        if (!userClosed) showModal();
        try {
            if (sdkReady && window.SalesforceInteractions?.reinit) {
                window.SalesforceInteractions.reinit();
            }
        } catch (e) { /* ignore */ }
        syncEswButtonVisibility();
        return;
    }

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
    if (!userClosed) showModal();

    // After dataset.stage is set, ask the SDK to re-evaluate which sitemap
    // pageType matches. The SDK normally only re-runs isMatch on URL change,
    // and our SPA never changes URLs.
    try {
        if (sdkReady && window.SalesforceInteractions?.reinit) {
            window.SalesforceInteractions.reinit();
        }
    } catch (e) { /* older SDK without reinit; ignore */ }

    // Show/hide the chat BUTTON (not the panel) based on the current stage.
    // User taps the button themselves to open the panel — that's the
    // standard MIAW interaction pattern.
    syncEswButtonVisibility();
}

// ── Consent ────────────────────────────────────────────────────────────────

function renderConsent() {
    setBodyStage('consent');
    root.innerHTML = '';
    if (SIGNUP_MODE) {
        root.append(
            el('div', { class: 'center' },
                el('div', { class: 'brand' }, 'Skywave'),
                el('div', { class: 'brand-sub' }, 'Airlines'),
                el('div', { class: 'card' },
                    el('h1', {}, 'Create your SkyRewards profile'),
                    el('p', {},
                        'We’ll set you up with a member account. ',
                        'We only collect what you enter on the next screen plus a cookie to recognize you on return visits. ',
                        'All data is used for this account and may be retained for one follow-up; ',
                        'everything is deleted within 14 days. ',
                        'Any prices shown are fictitious.'
                    ),
                    el('button', { class: 'btn', onclick: handleConsent }, 'Accept and continue')
                )
            )
        );
        return;
    }
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
    state.consented = true;
    syncEswButtonVisibility();   // chat button now eligible to show

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

    // Mint the hardened-website proof cookie + Contact NOW (consent is
    // when we have permission to persist anything). Page load only peeked.
    // Best-effort: a failure here doesn't block the demo flow — the chat
    // path still works via its own PE-trigger Contact upsert.
    try {
        await fetch('/api/website/session/init', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ deviceId: sdkId || undefined })
        });
        state.sessionReady = true;
    } catch (e) {
        console.warn('[skywave] website/session/init failed (continuing)', e);
    }

    // Signup mode: dismiss the demo modal and hand off to the existing
    // #profile customer-area. We deliberately skip /api/session/start
    // (no Demo_Session row), WS connect, survey schema fetch, and the
    // ESW snippet — none of those are wanted on the standalone signup
    // surface. The proof cookie minted above is enough for #profile to
    // resolve identity via /api/website/me.
    if (SIGNUP_MODE) {
        hideModal();
        try { refreshIdentity(); } catch (_) { /* best-effort */ }
        if (location.hash !== '#profile') {
            location.hash = '#profile';
        } else {
            window.dispatchEvent(new HashChangeEvent('hashchange'));
        }
        return;
    }

    try {
        // Attach IP geolocation if we already have it (loadGeo runs in
        // parallel with consent; might be ready or not). If absent, the
        // session_started event still publishes — the monitor will get
        // geo on the later survey_complete event instead.
        const startBody = { userAgent: navigator.userAgent, sessionId: sdkId };
        if (state.geo) {
            if (state.geo.lat != null) startBody.geoLat = state.geo.lat;
            if (state.geo.lon != null) startBody.geoLon = state.geo.lon;
            if (state.geo.city)        startBody.geoCity = state.geo.city;
            if (state.geo.region)      startBody.geoRegion = state.geo.region;
            if (state.geo.country)     startBody.geoCountry = state.geo.country;
        }
        const res = await fetch('/api/session/start', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(startBody)
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
        state.sessionId = data.sessionId;
        state.demoSessionId = data.demoSessionId;
        // The visitor walks the funnel themselves. The moderator's
        // current state is the ceiling — it tells the visitor how far
        // they're allowed to walk, not where to teleport. Late arrivals
        // start at the survey (the first interactive screen) and move
        // forward at their own pace; anyone who runs ahead lands on a
        // holding card until the moderator catches up.
        //
        // Skipping idle/scan because consent itself is the implicit
        // "scan completed" signal — the visitor wouldn't be here
        // otherwise.
        state.moderatorStage = data.currentState || 'idle';
        state.visitorStage = stageIndex(state.moderatorStage) >= stageIndex('survey')
            ? 'survey'
            : state.moderatorStage;
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
    state.wsUrl = wsUrl;
    ws.addEventListener('open',  () => {
        state.wsConnected = true;
        state.wsReconnectDelay = 1000;   // reset backoff on success
        render();
    });
    ws.addEventListener('close', () => {
        state.wsConnected = false;
        render();
        // Auto-reconnect with exponential backoff, capped at 30s. Server
        // sends ping every 30s but the network can still drop the socket
        // (page suspend, VPN flip). Without this, late-arriving WS pushes
        // (e.g. profile_created from chat) get fanned out to a dead
        // connection and are silently lost.
        const delay = state.wsReconnectDelay || 1000;
        state.wsReconnectDelay = Math.min(delay * 2, 30000);
        setTimeout(() => {
            if (state.wsUrl) connectWs(state.wsUrl);
        }, delay);
    });
    ws.addEventListener('message', (m) => {
        try {
            const msg = JSON.parse(m.data);
            if (msg.type === 'stage_changed') {
                const previous = state.moderatorStage;
                state.moderatorStage = msg.newState || state.moderatorStage;
                if (previous !== state.moderatorStage) {
                    // Moderator advance can unblock a visitor who was
                    // parked on the holding screen; just re-render.
                    // visitorStage is owned entirely by visitor actions
                    // (survey completion etc.) and is never touched here.
                    // Stage transition wipes any prior 'visitor closed the
                    // modal' state — new content deserves to be seen.
                    userClosed = false;
                    render();
                }
                return;
            }
            if (msg.type === 'client_action') {
                // The org just told us to do something visitor-scoped (no
                // stage change). Today: profile_created — visitor finished
                // the chat profile flow, so fold the new identity into the
                // website surface in place (no reload needed; same proof
                // cookie + same Contact, just newly-enriched fields).
                if (msg.action === 'profile_created') {
                    state.profileAlreadyComplete = true;
                    refreshIdentity();
                }
                if (msg.action === 'chat_ready') {
                    // The Contact-update trigger has committed this device's
                    // ConvId stamp. Release the chat client's first message so
                    // the agent's turn-1 resolve_session matches this Contact
                    // (not the demo seed). Deterministic identity handshake.
                    miawUi?.markChatReady();
                }
                return;
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

    // Track the latest answer per question for the survey-complete upsert
    // POST that fires when the user finishes the last question.
    state.answers[questionKey] = { questionText, answerText, answerKey };

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
        // Survey just ended — visitor's earned stage moves up to
        // `thanks`. Past this, the moderator drives. Fire the
        // upsert here regardless of which screen is about to render
        // so a late-arriving visitor (moderator already past thanks)
        // still has their survey answers attached to the Contact
        // before the agent runs Skywave_ResolveSession.
        const total = state.survey?.questions?.length ?? 0;
        if (state.surveyIndex >= total) {
            advanceVisitorStage('thanks');
            postSurveyComplete();
        }
        render();
    }, 350);
}

// ── Waiting / thanks ───────────────────────────────────────────────────────

function renderWaiting() {
    const stagePill = el('span',
        { class: state.wsConnected ? 'stage-pill' : 'stage-pill disconnected' },
        state.wsConnected ? (effectiveStage() || '…') : 'reconnecting…'
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

// Holding card for visitors who finished their self-driven prefix
// (survey + thanks) but the moderator hasn't reached `thanks` yet.
// Plain "the demo will continue shortly" — deliberately not "you're
// ahead", we don't shame the eager.
function renderHolding() {
    root.append(
        el('div', { class: 'center' },
            el('div', { class: 'brand' }, 'Skywave'),
            el('div', { class: 'brand-sub' }, 'Interactive'),
            el('div', { class: 'card' },
                el('h1', {}, 'Stand by'),
                el('p', {}, 'The demo will continue shortly.')
            ),
            el('div', { class: 'session-info' },
                el('div', { class: 'session-info-label' }, 'Session'),
                el('div', { class: 'session-info-value' }, state.sessionId || '')
            )
        )
    );
}

// POST the survey summary + structured JSON to the public
// Skywave_ContactUpsert endpoint. The Platform Event trigger upserts
// the anonymous Contact in System Mode, which is what the agent
// reads via Skywave_ResolveSession.
//
// Decoupled from any specific render path: a late-arriving visitor
// whose effectiveStage skips straight from `survey` to `agent_book`
// (because the moderator is already past `thanks`) wouldn't otherwise
// land in renderThanks, and the agent would have no survey context.
// Always called once when the visitor finishes their last question.
function postSurveyComplete() {
    if (state.surveyComplete) return;
    if (Object.keys(state.answers).length === 0) return;
    state.surveyComplete = true;

    const phrases = [];
    for (const key of Object.keys(state.answers)) {
        const a = state.answers[key];
        phrases.push(`${a.questionText} -> ${a.answerText}`);
    }
    const summary = 'The visitor previously answered: ' + phrases.join('; ') + '.';
    const sdkId = (() => {
        try { return window.SalesforceInteractions?.getAnonymousId?.() || null; }
        catch (_) { return null; }
    })();
    if (!sdkId) return;
    const payload = {
        type: 'survey_complete',
        deviceId: sdkId,
        demoSessionId: state.demoSessionId,
        responsesJson: JSON.stringify(state.answers),
        summary
    };
    // Attach IP geolocation if we resolved it — lets the backend derive a
    // home airport and pre-fill the booking origin. Optional.
    if (state.geo) {
        if (state.geo.city)    payload.geoCity    = state.geo.city;
        if (state.geo.region)  payload.geoRegion  = state.geo.region;
        if (state.geo.country) payload.geoCountry = state.geo.country;
        if (state.geo.lat != null) payload.geoLat = state.geo.lat;
        if (state.geo.lon != null) payload.geoLon = state.geo.lon;
    }
    postContactUpsert(payload);
}

function renderThanks() {
    // Belt-and-suspenders: also fire from here in case the visitor
    // somehow lands on `thanks` without having gone through
    // handleAnswer (e.g. moderator force-rebroadcast). postSurveyComplete
    // is idempotent.
    postSurveyComplete();

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

// Has this visitor already consented on this device? We don't read the
// WebSDK's consent state directly — c360a doesn't expose a stable public
// API for that, and the persistence shape varies by SDK version. Instead
// we use a stronger signal we DO control: the proof cookie + peek
// response. Both conditions are only satisfiable if the visitor went
// through handleConsent() at least once on this device, which is when
// we mint the proof cookie + Contact pair. The WebSDK consent cookie
// will also be set in that flow (handleConsent calls updateConsents),
// but we don't have to read it back to know — our own state suffices.
//
// Returns true iff peek says the proof cookie verified AND has a
// Contact attached. (Phase 1: peek refreshes the cookie when valid.)
function previouslyConsented(peek) {
    return !!(peek && peek.contactExists);
}

// Resume path for an already-consented visitor: silently do everything
// handleConsent does for the post-Accept stretch (mint proof cookie via
// /session/init, /api/session/start, connect WS, prefetch survey, warm
// chat snippet) — but DON'T render the consent screen and DON'T flip
// state via a button click.
async function resumeSession({ sdkId, surveyAlreadyComplete }) {
    state.consented = true;
    state.surveyAlreadyComplete = !!surveyAlreadyComplete;
    syncEswButtonVisibility();

    // Hardened-website proof cookie + Contact (idempotent on existing
    // deviceId — Apex returns the same Contact, just refreshes cookie).
    try {
        await fetch('/api/website/session/init', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ deviceId: sdkId || undefined })
        });
        state.sessionReady = true;
    } catch (e) {
        console.warn('[skywave] resume session/init failed', e);
    }

    try {
        const startBody = { userAgent: navigator.userAgent, sessionId: sdkId };
        if (state.geo) {
            if (state.geo.lat != null) startBody.geoLat = state.geo.lat;
            if (state.geo.lon != null) startBody.geoLon = state.geo.lon;
            if (state.geo.city)        startBody.geoCity = state.geo.city;
            if (state.geo.region)      startBody.geoRegion = state.geo.region;
            if (state.geo.country)     startBody.geoCountry = state.geo.country;
        }
        const res = await fetch('/api/session/start', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(startBody)
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
        state.sessionId = data.sessionId;
        state.demoSessionId = data.demoSessionId;
        state.moderatorStage = data.currentState || 'idle';
        // Returning visitor who already finished the survey jumps
        // straight to whatever the moderator's at (or 'thanks' if mod
        // is still in early stages — handled by effectiveStage cap).
        if (state.surveyAlreadyComplete) {
            state.surveyComplete = true;
            advanceVisitorStage('thanks');
        } else {
            // Already consented but survey not done — drop them on the
            // survey screen, same as a late arrival on the consent path.
            state.visitorStage = stageIndex(state.moderatorStage) >= stageIndex('survey')
                ? 'survey' : state.moderatorStage;
        }
        connectWs(data.wsUrl);
        await loadSurveySchema();
        loadEswSnippet(sdkId).catch((e) => console.warn('[esw] snippet load failed', e));
        render();
    } catch (e) {
        console.error('[skywave] resume failed', e);
        renderError(e.message);
    }
}

(async () => {
    await loadConfig();
    // Kick off IP geolocation in the background — don't block the consent
    // screen on it. It just needs to be resolved by survey-complete.
    loadGeo();

    // Boot decision tree (no shadow tracking — read the WebSDK + Apex):
    //
    //   1. Load the SDK so we can read its persisted consent state and
    //      its anonymous deviceId in the same step.
    //   2. Peek at /api/website/session/peek to see whether this
    //      deviceId already has a Contact, and whether that Contact
    //      has Skywave_Survey_Json__c populated.
    //   3. Branch:
    //        - SDK reports Tracking=Opt In → resume silently. If the
    //          peek says surveyCompleted, jump to thanks (stage-driven
    //          render takes over). Otherwise drop into survey.
    //        - Otherwise → render the consent screen, business as
    //          usual (handleConsent will run init + start).
    //
    // If the SDK fails to load entirely we fall back to "always ask",
    // which is the safer path.
    await loadInteractionsSdk();
    const sdkId = (() => {
        try { return window.SalesforceInteractions?.getAnonymousId?.() || null; }
        catch (_) { return null; }
    })();

    let peek = null;
    try {
        const r = await fetch('/api/website/session/peek', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ deviceId: sdkId || undefined })
        });
        if (r.ok) peek = await r.json();
    } catch (e) {
        console.warn('[skywave] session/peek failed (continuing as anonymous)', e);
    }

    if (previouslyConsented(peek)) {
        console.log('[skywave] returning visitor: proof cookie verified, contactExists=true, ' +
            'surveyCompleted=' + !!peek?.surveyCompleted +
            ', profileCompleted=' + !!peek?.profileCompleted);
        state.profileAlreadyComplete = !!peek?.profileCompleted;
        // Signup mode: returning visitor with a valid proof cookie has
        // already consented on this device — skip both the consent gate
        // AND the demo resume. Drop the modal, kick the customer-area
        // identity refresh so the nav greeting populates, and route to
        // #profile.
        if (SIGNUP_MODE) {
            hideModal();
            state.consented = true;
            state.sessionReady = true;
            try { refreshIdentity(); } catch (_) { /* best-effort */ }
            if (location.hash !== '#profile') {
                location.hash = '#profile';
            } else {
                window.dispatchEvent(new HashChangeEvent('hashchange'));
            }
            return;
        }
        await resumeSession({
            sdkId,
            surveyAlreadyComplete: !!peek?.surveyCompleted
        });
        return;
    }

    // Fresh / not-yet-consented visitor: ask.
    renderConsent();
    showModal();
})();
