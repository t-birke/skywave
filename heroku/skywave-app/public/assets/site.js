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
let warmingBubbleEl = null;  // ECv2 pre-warm loading bubble (FAB look-alike)
let warmSafetyTimer = null;  // reveal-anyway net if the welcome event never fires
let chatRevealing = false;   // guards the minimize→reveal handoff
let eswButtonCreated = false; // onEmbeddedMessagingButtonCreated fired — launchChat() usable
let eswIdentityReady = false; // identity token set — verified session ready for launchChat()
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

// POST survey_complete / chat_start upserts through the hardened, proof-gated
// Heroku surface (/api/website/contact/upsert). The server stamps the Contact
// with the sealed proof-cookie deviceId — NOT any client-supplied id — so the
// survey identity can't drift from the chat/booking identity (which is the
// same proof-cookie deviceId, carried as the chat identity-token `sub`).
// Same-origin with credentials so the proof cookie rides along. Fire-and-forget;
// a Platform Event trigger does the actual Contact upsert in System Mode.
function postContactUpsert(payload) {
    fetch('/api/website/contact/upsert', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    }).then((r) => {
        console.log(`[skywave] /api/website/contact/upsert (${payload.type}) ${r.status}`);
    }).catch((err) => {
        console.warn(`[skywave] /api/website/contact/upsert (${payload.type}) failed`, err);
    });
}

// Boot the chat client. Two transports, selected by config.chatClient
// (Heroku CHAT_CLIENT env, default 'miaw'):
//   - 'ecv2' → the official Embedded Service for Web v2 widget. Works only
//     when the chat site and this consumer site share a registrable domain
//     (chat.skywave.flights + app.skywave.flights), so the guest session
//     cookie is first-party and iOS ITP doesn't drop it (no redirect loop).
//   - 'miaw' → the custom scrt2 REST client (miaw-client/miaw-ui), which
//     sidesteps the cookie loop WITHOUT a shared domain. The portable
//     fallback for installs that can't own a custom domain.
// Both transports share the FAB-visibility logic (syncEswButtonVisibility)
// and the same chat_start identity stamp (deviceId -> Contact via the upsert
// trigger). The name + signature (loadEswSnippet) are unchanged so both call
// sites keep working.
async function loadEswSnippet(deviceId) {
    // Idempotency guard — checked SYNCHRONOUSLY before any async work. Two
    // call sites (session-start and resume) can fire near-simultaneously;
    // without the up-front guard both slip past during the await gap and
    // double-mount (two FABs / two bootstrap injects).
    if (eswReady || miawUi) return true;
    return ((config.chatClient || 'miaw') === 'ecv2')
        ? loadEcv2Snippet(deviceId)
        : loadMiawClient(deviceId);
}

// --- 'ecv2' transport: official Embedded Service for Web v2 widget. -------
// Loads bootstrap.min.js from the published chat site (esw.siteUrl — set via
// SF_ESW_SITE_URL, which becomes chat.skywave.flights at cutover), passes the
// deviceId as the Session_ID hidden prechat field, and POSTs chat_start so the
// existing Contact-upsert trigger resolves the conversation to the visitor's
// Contact (custom hidden params don't reach the routing flow in ECv2). Button
// visibility is CSS-driven (body[data-esw-visible]) — ECv2's hideChatButton
// APIs are platform-broken. See docs/ecv2-reference/.
async function loadEcv2Snippet(deviceId) {
    const esw = config.esw || {};
    if (!esw.orgId || !esw.escName || !esw.siteUrl || !esw.scrt2Url) {
        console.warn('[esw] config incomplete; skipping ECv2 snippet', esw);
        return false;
    }
    eswReady = true;  // claim the slot before any await (prevents double inject)

    await new Promise((resolve) => {
        const s = document.createElement('script');
        s.src = `${esw.siteUrl}/assets/js/bootstrap.min.js`;
        s.async = true;
        s.onload = () => resolve();
        s.onerror = () => { console.warn('[esw] bootstrap.min.js failed to load'); resolve(); };
        document.head.appendChild(s);
    });

    if (!window.embeddedservice_bootstrap) {
        console.warn('[esw] embeddedservice_bootstrap undefined after script load');
        eswReady = false;
        return false;
    }

    // Set the Session_ID hidden prechat field on two lifecycle events — ECv2
    // intermittently fails to pick the field up at conversation start. The
    // value is a bare string, NOT { value: '...' } (runtime rejects wrapped).
    const setSessionPrechat = (eventName) => {
        try {
            if (deviceId) {
                window.embeddedservice_bootstrap.prechatAPI.setHiddenPrechatFields({ Session_ID: deviceId });
                console.log(`[esw] Session_ID prechat set on ${eventName}:`, deviceId);
            }
        } catch (e) { console.warn(`[esw] setHiddenPrechatFields failed on ${eventName}`, e); }
    };
    window.addEventListener('onEmbeddedMessagingReady', () => setSessionPrechat('Ready'), { once: true });

    // --- User Verification (PRIMARY identity path) -------------------------
    // Present a signed identity token (JWT, sub=deviceId) so the session is
    // verified as `v2/iamessage/AUTH/Skywave_Identity/uid:<deviceId>` instead
    // of an UNAUTH guest with a random uid. Skywave_ResolveSession then resolves
    // the visitor's Contact by Session_Id__c=deviceId DETERMINISTICALLY (no
    // dependency on the conversationId stamp race / demo-seed fallback). The JWT
    // is minted by the Heroku service (/api/website/chat-identity-token, proof-
    // gated, sub = the proof-cookie deviceId), verified against the org Keyset
    // `Skywave_Identity_Keyset`. The channel runs authMode=Auth, so this is
    // REQUIRED: without a token the conversation can't start. setIdentityToken
    // must be called AFTER onEmbeddedMessagingReady; re-call on token expiry.
    const setEcv2IdentityToken = async (reason) => {
        try {
            const r = await fetch('/api/website/chat-identity-token', { credentials: 'same-origin' });
            if (!r.ok) { console.warn(`[esw] identity-token fetch ${r.status} (${reason})`); return; }
            const data = await r.json();
            if (!data || !data.configured || !data.customerIdentityToken) {
                console.warn(`[esw] identity token not configured — session stays UNAUTH (${reason})`);
                return;
            }
            window.embeddedservice_bootstrap.userVerificationAPI.setIdentityToken({
                identityTokenType: 'JWT',
                identityToken: data.customerIdentityToken
            });
            console.log(`[esw] identity token set (${reason})`);
            // Session is verified. Pre-warm the conversation hidden so the
            // agent's welcome is ready before the visitor opens the chat — but
            // launchChat() isn't usable until onEmbeddedMessagingButtonCreated
            // fires, so gate on BOTH (maybePreWarm). Only the initial Ready.
            if (reason === 'Ready') { eswIdentityReady = true; maybePreWarm(); }
        } catch (e) { console.warn(`[esw] setIdentityToken failed (${reason})`, e); }
    };
    window.addEventListener('onEmbeddedMessagingReady', () => setEcv2IdentityToken('Ready'), { once: true });
    window.addEventListener('onEmbeddedMessagingIdentityTokenExpired', () => setEcv2IdentityToken('Expired'));
    // utilAPI.launchChat()/minimizeChat() throw "API not available before
    // onEmbeddedMessagingButtonCreated event is fired" until the FAB exists.
    // That event fires AFTER onEmbeddedMessagingReady — gate the pre-warm on it
    // (either it or the identity token can land first; maybePreWarm needs both).
    window.addEventListener('onEmbeddedMessagingButtonCreated', () => { eswButtonCreated = true; maybePreWarm(); }, { once: true });

    // WORKAROUND: ECv2 doesn't propagate custom hidden prechat params to the
    // session-handler flow (they drop between scrt2 and the routing flow). So
    // on conversation start we POST deviceId + conversationId to the public
    // upsert endpoint; the trigger stamps the Contact so Skywave_ResolveSession
    // matches. Drop this listener once the platform gap closes.
    window.addEventListener('onEmbeddedMessagingConversationStarted', (e) => {
        setSessionPrechat('ConversationStarted');
        // A conversation now exists — leave the reload breadcrumb (see
        // hasResumableConversation) so a refresh reveals the FAB immediately
        // instead of gating on a welcome that resume won't re-send.
        markConversationStarted();
        const conversationId = e?.detail?.conversationId;
        if (!conversationId || !deviceId) {
            console.warn('[esw] no conversationId/deviceId on ConversationStarted; skipping identify');
            return;
        }
        const csPayload = { type: 'chat_start', deviceId, demoSessionId: state.demoSessionId, conversationId };
        if (state.geo) {
            if (state.geo.city)        csPayload.geoCity    = state.geo.city;
            if (state.geo.region)      csPayload.geoRegion  = state.geo.region;
            if (state.geo.country)     csPayload.geoCountry = state.geo.country;
            if (state.geo.lat != null) csPayload.geoLat     = state.geo.lat;
            if (state.geo.lon != null) csPayload.geoLon     = state.geo.lon;
        }
        postContactUpsert(csPayload);
    }, { once: true });

    // Conversation ended → drop the resume breadcrumb so the NEXT visit pre-
    // warms a FRESH conversation (with a real welcome) instead of revealing the
    // FAB for a conversation that's over. Two host events cover it — both taken
    // from the served ECv2 home_view bundle's own event catalog (there is NO
    // "onEmbeddedMessagingConversationEnded"; that was a bad guess):
    //   • onEmbeddedMessagingEndSession — the chat header's "End Conversation"
    //     menu action. In a User-Verified chat (authMode=Auth, our case) that
    //     button calls util.endSession(), which fires this.
    //   • onEmbeddedMessagingConversationClosed — the conversation was closed
    //     (agent-ended / auto-closed).
    // Clearing is idempotent and safe: after an explicit end we WANT a fresh
    // start next load, and worst case a still-resumable conversation just gets a
    // (hidden) fresh pre-warm. The marker TTL is the final backstop. NB: this is
    // distinct from onEmbeddedMessagingWindowClosed/WindowMinimized (panel UI
    // only) — we must not clear the marker on those.
    const clearMarkerOnEnd = (evt) => {
        clearConversationMarker();
        console.log(`[esw] ${evt} — cleared resume marker`);
    };
    window.addEventListener('onEmbeddedMessagingEndSession', () => clearMarkerOnEnd('EndSession'));
    window.addEventListener('onEmbeddedMessagingConversationClosed', () => clearMarkerOnEnd('ConversationClosed'));

    try {
        window.embeddedservice_bootstrap.settings.language = 'en_US';
        // Do NOT set hideChatButtonOnLoad. When this code was first written the
        // setting was Salesforce-broken (ignored), so the FAB showed by default
        // and our CSS (body[data-esw-visible]) did the hiding. The platform has
        // since FIXED it: hideChatButtonOnLoad=true now genuinely collapses the
        // FAB iframe to 0x0 ("initial"), and our CSS can't un-collapse a button
        // the platform is holding hidden. So leave it unset — the FAB renders
        // and our CSS hides #embedded-messaging until the visitor is eligible
        // (consented && modal closed). Verified live on app.skywave.flights:
        // with it set, the iframe stayed 0x0 even with data-esw-visible="1".
        window.embeddedservice_bootstrap.init(
            esw.orgId, esw.escName, esw.siteUrl, { scrt2URL: esw.scrt2Url }
        );
    } catch (e) {
        console.warn('[esw] init failed', e);
        eswReady = false;
        return false;
    }

    // Mount is async; the call-site syncs ran before the platform button
    // existed. Re-sync now so an already-eligible visitor sees the FAB.
    syncEswButtonVisibility();
    return true;
}

// --- 'miaw' transport: custom scrt2 REST client (portable fallback). ------
// Why custom: the official ECv2 client dies on iOS Safari in a redirect loop
// — its session cookie is set on *.my.site.com but the host page is a
// different registrable domain, so the cookie is third-party and iOS ITP
// drops it. This client talks to the scrt2 REST API directly: the auth JWT
// lives in first-party localStorage on THIS origin, nothing for ITP to block.
// See docs/ecv2-reference/. Identity: it generates its own conversation UUID
// and fires the SAME chat_start POST as the ECv2 path; the Contact-update
// trigger resolves that UUID to the internal MessagingSession.ConversationId
// so Skywave_ResolveSession matches.
async function loadMiawClient(deviceId) {
    const esw = config.esw || {};
    // scrt2Url + orgId + escName are what the REST client needs (no siteUrl).
    // escName is the EmbeddedServiceConfig dev name.
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
            title: 'Skywave Airlines Agent',

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
    const eligible = state.consented && !modalOpen;
    // ECv2 pre-warm: once we've kicked off the hidden warm-up, keep the real
    // FAB hidden and show the loading bubble in its place until the agent's
    // welcome lands. `gateOnWelcome` is only ever true on the ECv2 path (the
    // miaw transport never sets chatPreWarmed), so the miaw fallback keeps its
    // original "show whenever eligible" behaviour.
    const gateOnWelcome = state.chatPreWarmed && !state.chatWelcomeReady;
    const showRealFab = eligible && !gateOnWelcome;
    document.body.dataset.eswVisible = showRealFab ? '1' : '0';
    if (warmingBubbleEl) {
        warmingBubbleEl.dataset.on = (eligible && gateOnWelcome) ? '1' : '0';
    }
    // Drive the actual client root (explicit value — CSS default is none).
    // While the panel is open we keep it visible regardless of stage (the
    // FAB hides itself when open); otherwise show only when eligible.
    if (miawUi && miawUi.root) {
        miawUi.root.style.display = (showRealFab || miawUi.open) ? 'block' : 'none';
    }
}

// Create the FAB-look-alike loading bubble once. It mirrors the ECv2 FAB
// (fixed bottom-right, 56px, radius 20px, #1A1B1E, the bubble glyph) with a
// spinner ring, so the swap to the real FAB is visually seamless. Non-
// interactive — purely a "chat is preparing" affordance.
const ESW_BUBBLE_GLYPH = 'M10 1.25C14.8325 1.25 18.75 5.16751 18.75 10C18.75 11.3951 18.4213 12.7154 17.8389 13.8877L18.7217 17.5137C18.8042 17.8528 18.7038 18.2103 18.457 18.457C18.2103 18.7038 17.8528 18.8042 17.5137 18.7217L13.8877 17.8389C12.7154 18.4213 11.3951 18.75 10 18.75C5.16751 18.75 1.25 14.8325 1.25 10C1.25 5.16751 5.16751 1.25 10 1.25ZM10 3.25C6.27208 3.25 3.25 6.27208 3.25 10C3.25 13.7279 6.27208 16.75 10 16.75C11.1896 16.75 12.3049 16.4434 13.2734 15.9053L13.3574 15.8633C13.5573 15.7757 13.7814 15.7556 13.9951 15.8076L16.3896 16.3896L15.8076 13.9951C15.7482 13.7508 15.7832 13.4932 15.9053 13.2734C16.4434 12.3049 16.75 11.1896 16.75 10C16.75 6.27208 13.7279 3.25 10 3.25Z';
function ensureWarmingBubble() {
    if (warmingBubbleEl) return warmingBubbleEl;
    if (typeof document === 'undefined' || !document.body) return null;
    const el = document.createElement('div');
    el.id = 'skywave-chat-warming';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-label', 'Preparing chat…');
    el.dataset.on = '0';
    el.innerHTML =
        '<span class="swc-spinner" aria-hidden="true"></span>' +
        '<svg class="swc-glyph" viewBox="0 0 20 20" aria-hidden="true">' +
        '<path fill="currentColor" d="' + ESW_BUBBLE_GLYPH + '"/></svg>';
    document.body.appendChild(el);
    warmingBubbleEl = el;
    return el;
}

// ── Reload-resume detection ─────────────────────────────────────────────────
// ECv2 persists an in-flight conversation across page reloads (its continuity
// token lives in web storage). On reload it SILENTLY RESUMES the prior
// conversation — history is re-rendered but NO new welcome message is sent, so
// the pre-warm's welcome gate (onEmbeddedMessagingFirstBotMessageSent) never
// fires and we'd sit on the loading bubble until the 90s safety net. ECv2
// exposes no event for "you just resumed an existing conversation", so we leave
// our own breadcrumb: a timestamped localStorage marker written when a
// conversation first starts. On a later load a *fresh* marker means "resume,
// don't gate" → reveal the FAB immediately. TTL-bounded so a stale marker (the
// conversation actually expired) can't suppress the pre-warm forever, and
// cleared when the conversation ends.
const CONV_MARKER_KEY = 'sw_chat_conv_v1';
// Match the ECv2 conversation timeout (2h): past that the conversation is no
// longer resumable, so a marker older than this is stale — let it expire and
// pre-warm a FRESH conversation instead of revealing the FAB for a dead one.
// The marker is refreshed on every conversation start / resume, so within an
// active session (reloads) it never goes stale; 2h only bounds a truly idle gap.
const CONV_MARKER_TTL_MS = 2 * 60 * 60 * 1000;  // 2h — the ECv2 conversation timeout
function markConversationStarted() {
    try { localStorage.setItem(CONV_MARKER_KEY, String(Date.now())); } catch (_) { /* storage disabled */ }
}
function clearConversationMarker() {
    try { localStorage.removeItem(CONV_MARKER_KEY); } catch (_) { /* storage disabled */ }
}
function hasResumableConversation() {
    try {
        const ts = parseInt(localStorage.getItem(CONV_MARKER_KEY) || '', 10);
        if (!Number.isFinite(ts)) return false;
        if (Date.now() - ts > CONV_MARKER_TTL_MS) { clearConversationMarker(); return false; }
        return true;
    } catch (_) { return false; }
}

// Start the ECv2 conversation in the background (hidden) so the agent's
// welcome message is already waiting by the time the visitor opens the chat.
// Fired once, after the session is verified (setIdentityToken). launchChat()
// always maximizes, but our CSS keeps #embedded-messaging hidden (data-esw-
// visible="0") throughout the warm-up, so nothing flashes; the loading bubble
// shows in its place. onWelcomeReady() does the reveal.
// Pre-warm only once BOTH gates are met: the FAB is created (launchChat()
// usable) AND the identity token is set (authMode=Auth needs a verified
// session to start the conversation). Either event can fire first.
function maybePreWarm() {
    if (!(eswButtonCreated && eswIdentityReady)) return;
    // Reload case: a conversation already exists for this browser. ECv2 resumes
    // it (with history) the moment the visitor opens the FAB and sends NO new
    // welcome — so there's nothing to gate on. Reveal the real FAB immediately
    // instead of pre-warming (which would just launch→resume the same
    // conversation and then wait out the full 90s safety net for a welcome that
    // never comes).
    if (hasResumableConversation()) {
        markConversationStarted();         // refresh the TTL for the next reload
        state.chatWelcomeReady = true;     // gateOnWelcome=false → real FAB shows now
        syncEswButtonVisibility();
        console.log('[esw] resumable conversation detected — revealing FAB (no pre-warm)');
        return;
    }
    preWarmChat();
}

function preWarmChat() {
    if (state.chatPreWarmed) return;
    const boot = window.embeddedservice_bootstrap;
    if (!boot || !boot.utilAPI || typeof boot.utilAPI.launchChat !== 'function') return;
    state.chatPreWarmed = true;
    ensureWarmingBubble();
    syncEswButtonVisibility();   // show the loading bubble, keep the real FAB hidden
    // Reveal the real FAB the instant the agent's first (welcome) message
    // lands. This ECv2 event isn't in the published listener list but is
    // dispatched to the host (verified live) — it's the only signal that fires
    // exactly at welcome time (ConversationStarted fires ~40s too early).
    window.addEventListener('onEmbeddedMessagingFirstBotMessageSent', onWelcomeReady, { once: true });
    // Safety net: never leave the chat permanently hidden if that event never
    // fires (agent failure / platform event-name change) — reveal after 90s.
    warmSafetyTimer = setTimeout(() => {
        console.warn('[esw] FirstBotMessageSent not seen in 90s — revealing FAB anyway');
        onWelcomeReady();
    }, 90000);
    console.log('[esw] pre-warming conversation (hidden)…');
    // launchChat() MAXIMIZES the window; on mobile the maximized ECv2 window is
    // a full-screen overlay that locks background scroll — so even though our
    // CSS hides the widget, the page would be frozen for the whole cold-start
    // wait. Collapse it back to the FAB IMMEDIATELY: the conversation keeps
    // warming in the background (the welcome still lands on a minimized window)
    // and the page stays interactive behind the loading bubble. Wrap so neither
    // a sync throw nor an async rejection goes unhandled.
    Promise.resolve()
        .then(() => boot.utilAPI.launchChat())
        .then(() => {
            // Non-fatal: if the collapse fails the page may stay locked until
            // welcome, but the warm-up itself is unaffected.
            Promise.resolve()
                .then(() => boot.utilAPI.minimizeChat())
                .catch((e) => console.warn('[esw] pre-warm minimize failed', e));
        })
        .catch((e) => {
            console.warn('[esw] launchChat pre-warm failed — revealing FAB', e);
            onWelcomeReady();
        });
}

// Welcome landed (or safety timeout / failure): collapse the hidden window to
// the FAB, then reveal it — revealing only after it's minimized so the visitor
// never sees the full window flash open.
function onWelcomeReady() {
    if (state.chatWelcomeReady || chatRevealing) return;
    chatRevealing = true;
    if (warmSafetyTimer) { clearTimeout(warmSafetyTimer); warmSafetyTimer = null; }
    // Remember that a conversation now exists so a page RELOAD reveals the FAB
    // immediately (resume sends no fresh welcome to gate on). Belt-and-
    // suspenders — it's normally already set on onEmbeddedMessagingConversationStarted.
    markConversationStarted();
    const reveal = () => {
        if (state.chatWelcomeReady) return;
        state.chatWelcomeReady = true;
        syncEswButtonVisibility();   // reveals the (now-minimized) FAB, hides the loading bubble
        console.log('[esw] welcome ready — chat revealed');
    };
    // The window was already collapsed to the FAB during pre-warm, so it's safe
    // to reveal right away. Fire minimizeChat() once more (no-op if already
    // minimized) to cover the launch-failure path landing here un-minimized,
    // and reveal on confirmation or a short fallback.
    window.addEventListener('onEmbeddedMessagingWindowMinimized', reveal, { once: true });
    Promise.resolve()
        .then(() => window.embeddedservice_bootstrap.utilAPI.minimizeChat())
        .catch(() => { /* reveal still fires via the fallback below */ });
    setTimeout(reveal, 400);         // window is already minimized in the normal path
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

// Multi-tenant tenant key: the presenter's QR encodes ...?ds=<Demo_Session Id>.
// We read it once and seed state.demoSessionId so every call this phone makes
// (session/init, session/start, survey/answer) is scoped to that presenter's
// session. session/start later echoes the server-resolved id back into
// state.demoSessionId (same value when ds was valid; the global-active fallback
// otherwise).
const DS_PARAM = (() => {
    try { return new URLSearchParams(window.location.search).get('ds') || null; }
    catch (e) { return null; }
})();

let state = {
    sessionId: null,
    demoSessionId: DS_PARAM,
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
    // ECv2 pre-warm (loading-bubble → real-FAB swap). We start the conversation
    // hidden as soon as the session is verified so the agent's ~cold-start
    // welcome is already waiting; a FAB-look-alike spinner covers the gap.
    //   chatPreWarmed   — the hidden launchChat warm-up has been kicked off.
    //   chatWelcomeReady — the agent's first (welcome) message has landed
    //                      (onEmbeddedMessagingFirstBotMessageSent); real FAB revealed.
    chatPreWarmed: false,
    chatWelcomeReady: false,
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
            body: JSON.stringify({ deviceId: sdkId || undefined, ds: state.demoSessionId || undefined })
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
        const startBody = { userAgent: navigator.userAgent, sessionId: sdkId, ds: state.demoSessionId || undefined };
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
                ds:           state.demoSessionId || undefined,
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
    // Identity comes from the proof cookie server-side (see postContactUpsert),
    // NOT the WebSDK id — so survey data lands on the SAME Contact the chat and
    // booking resolve. No sdkId gate: a consented visitor always has a proof
    // cookie by survey-complete time, even if the WebSDK never loaded.
    const payload = {
        type: 'survey_complete',
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
            body: JSON.stringify({ deviceId: sdkId || undefined, ds: state.demoSessionId || undefined })
        });
        state.sessionReady = true;
    } catch (e) {
        console.warn('[skywave] resume session/init failed', e);
    }

    try {
        const startBody = { userAgent: navigator.userAgent, sessionId: sdkId, ds: state.demoSessionId || undefined };
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
            body: JSON.stringify({ deviceId: sdkId || undefined, ds: state.demoSessionId || undefined })
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
        // A verified proof cookie means this device already consented in a
        // prior session. The resume path skips the consent screen (where the
        // fresh path sets this), so set it explicitly here — otherwise the chat
        // FAB gate (state.consented && !modalOpen) never opens for a returning
        // visitor and the launch button stays hidden no matter the stage.
        state.consented = true;
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
