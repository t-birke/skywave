# Skywave Interactive — Architecture (as built)

> **Scope.** This describes what is *actually built and deployed today*, the
> cross-system data flows, and the moving parts that don't live in git.
> It deliberately does **not** restate what the code already shows (class
> bodies, field lists, exact agent instructions/action contracts) — read the
> source for that. It *does* document the agent's topic graph **shape** and
> the non-obvious runtime mechanics behind it (see §3c), because those have
> repeatedly cost us re-investigation.
>
> **Sibling docs:**
> - `SKYWAVE_INTERACTIVE_DESIGN.md` — the *intent*: 10-stage demo vision,
>   user journey, build-sequence phases, things still "proposed".
> - `README.md` — how to spin up an org (`orgInit.sh`) and get started.
> - `docs/STYLE_GUIDE.md` — Skywave visual language (tokens, color, type) for
>   any new UI component.
> - `SECRETS.md` — every credential, where it lives, how to rotate it.
> - `MEMORY.md` (in `…/memory/`) — the **why/gotchas** ledger. Whenever this
>   doc says "see memory", the non-obvious reason is a one-line entry there.

---

## 1. The big picture

Skywave Interactive is a live-audience demo of an airline customer-service
Agentforce agent. Three runtime surfaces, one SDO org (alias `si`):

```
                          ┌─────────────────────────────────────────────┐
                          │  Salesforce SDO org  (alias: si)             │
   Audience phones        │                                              │
   ───────────────        │   • Skywave_Airlines_Agent  (chat, MIAW)     │
   consumer website ──────┼──▶• Skywave_Voice_Agent      (telephony)     │
   (Heroku)               │   • Custom objects, Apex actions, LWC cards  │
        │                 │   • Platform Events (state + contact + race) │
        │                 │   • Data Cloud STDM (observability)          │
        │                 └───────────────▲──────────────────────────────┘
        │  PE: Demo_State_Change__e        │ guest-callable Apex REST
        │  (Pub/Sub API)                   │ + JWT-bearer relay
        ▼                                  │
   ┌──────────────────────┐               │
   │ skywave-app (Heroku) │───────────────┘
   │  • static site       │
   │  • WS state relay    │──── WebSocket ──▶ every connected phone
   └──────────────────────┘
```

The **presenter** drives a `Demo_Session__c.State__c` field through 10 stages;
that change fans out over WebSocket to every audience phone in real time, and
each phone reveals the next screen. See `SKYWAVE_INTERACTIVE_DESIGN.md` §5 for
the stage list and the rationale (it replaced a manual "check state" button).

**Multi-tenancy.** Many presenters can run the demo at once, each isolated.
The tenant key is the `Demo_Session__c` Id, stamped into the presenter's QR as
`?ds=` and echoed as the `ds` body field on every REST call
(`Skywave_RestUtil.getDemoSessionId(ds)` resolves it). When `ds` is absent —
the common single-user case of hitting `app.skywave.flights` directly — it
falls back via `getActiveDemoSessionId()`: a configured walk-up session
(`Skywave_Preflight_Config.Default.Fallback_Demo_Session_Id__c`, read through
`Skywave_DemoConfig`) if one is pinned to a curated, reliable session (e.g. one
kept at `agent_seat_pass`), otherwise the global most-recent-active session
(legacy behavior; the default for fresh/single-tenant installs). The presenter link is the
record's standard `OwnerId`; `Demo_Session__c.Active_Owner_Key__c` (unique,
kept in sync with `OwnerId`+`Active__c` by `Demo_Session_Trigger`) makes
"one active session per owner" a database invariant — a second active row for
the same owner fails with `DUPLICATE_VALUE`. Created Contacts separate per
presenter via `Demo_Session__r.OwnerId`; both monitors filter to the
presenter's own active session; the live seat/capability gate is **per demo
session** — it reads `Demo_Session__c.State__c` (resolved via the chat visitor's
Contact), so each presenter's session has its own seat state.

---

## 2. Repository map

| Path | What it holds |
|------|---------------|
| `force-app/main/default/` | All Salesforce metadata (the bulk of the system) |
| ├ `aiAuthoringBundles/` | The `.agent` files — airlines chat, voice, the **rental-car sub-agent** (`Skywave_Rental_Agent`, §3c'''), and the **destination-expert connected sub-agent** (`Skywave_Destination_Expert`, §3c'''') |
| ├ `classes/` | ~50 Apex classes: agent actions, REST endpoints, controllers, seeders |
| ├ `triggers/` | 4 triggers (Demo_Session, Contact-update PE, phone-digits, VoiceCall resolve) |
| ├ `lwc/` | Chat/voice cards (CLT renderers), demo monitor, survey author, contact card |
| ├ `objects/` | Custom objects + the Platform Events + custom fields on Contact/VoiceCall |
| ├ `flows/` | **`Skywave_Sourcing`** — a mock Flow *Orchestration* (`processType=Orchestrator`) showcasing a complex sourcing/purchasing pipeline, plus its 7 stub subflows. Record-triggered on `Sourcing_Request__c`. Two AI hand-offs: a prompt-template step + an Agentforce-agent step. See §3h and `flows/README_Sourcing.md`. Standalone demo — not wired to the live audience flow. |
| ├ `genAiPromptTemplates/` | `Skywave_Sourcing_RFP_Draft` — the prompt template the sourcing orchestration hands over to (§3h) |
| ├ `uiBundles/SkywaveGlobe/` | **3D globe demo monitor** — React UIBundle (Salesforce Multi-Framework). Successor to the 2D `skywaveDemoMonitor`/`skywaveWorldMap` LWCs. See §3b'' and **`docs/GLOBE_MONITOR.md`**. Installed by **`install.sh` Tier 4** (`--with-globe`/`--all`); **any redeploy after a source change = `scripts/deploy-globe.sh`** (Tier 4 delegates to it — one source of truth). It's excluded from the Tier 1 blanket deploy (`.forceignore`), then built (relay + consumer origins baked in) + deployed with its app/permset/CSP. Needs the Multi-Framework app domain enabled in Setup first. Runs locally via `npm run dev`. |
| `heroku/skywave-app/` | Node app: static consumer site + WebSocket state relay |
| └ `public/assets/website.css/.js` | Skywave Airlines marketing-site backdrop (nav, hero, search, deals, footer). Visible to every audience phone behind the demo modal. Extensible target for future booking/account features. |
| └ `public/assets/site.css/.js` | The demo flow itself. Renders into a centered modal (`#modal-content`) overlaid on the website backdrop. Modal is hidden during agent stages so the chat icon takes over. Closable any time via X. |
| └ `public/assets/survey/*.jpg` | Survey-option thumbnails, generated by `scripts/gen-survey-images.sh` (Nano Banana Pro via Vertex AI) and self-hosted so we don't depend on a third-party CDN. `Survey_Answer_Option__c.Image_Url__c` in the org points at these. |
| `scripts/` | Org-setup, agent deploy/republish, ESD publish + data-stream refresh (Playwright), seeders |
| `scripts/apex/` | Anonymous-Apex seeders (route network, booking data, observability) |
| `scripts/datacloud/` | **Tier 5 customer-tracking runner** — replays the proven Web Connector → schema → sitemap → streams → custom `Survey_Response` DMO → custom DMO relationship → 6 DLO→DMO mappings → IR ruleset → `Skywave_Customers` RT data graph, 100% via the Core `/ssot/` API. `run_tracking.py` (idempotent orchestrator), `_auth.py` (sf-CLI/JWT bridge), `normalize_payloads.py` (live-si defs → clean canonical payloads, scrubbing the `Swv2` iteration artifact), `payloads/*.json` (the canonical POST bodies). (§3a''') |
| `install.sh` `--with-tracking` | Tier 5 — see `scripts/datacloud/` |
| `vendor/sdo-agentforce-observability/` | **Vendored QBrix-6 metadata** — the 12 `SDO_Analytics_*`/`SDO_AFO_Bot__c` objects, Apex/LWC, Lightning app, and the Data Cloud layer (data kit, stream templates, DMO field maps) that back the observability dashboards. Copied in so recipients don't install the internal QBrix. Separate package dir in `sfdx-project.json`; provenance + deliberate changes in its `ATTRIBUTION.md`. (§3f) |
| `.claude/skills/skywave-install/` | **Conductor skill** for `install.sh` — the only `.claude/` content that ships (see `.gitignore`). Drives the install section-by-section and handles the gates. |
| `docs/` | Data Cloud mapping, web-connector schema, demo walkthrough |
| `install.sh` | **Canonical tiered installer** (SDO target). Tier 1 core / `--with-observability` (2) / `--with-heroku` (3) / `--with-globe` (4) / `--with-tracking` (5) / `--with-voice` (6, Chapter 9) / `--all`; idempotent + `--resume`-able. Source of truth for every setup command; the skill conducts it. Supersedes the scratch-org `orgInit.sh`. |
| `config/`, `orgInit.sh`, `sfdx-project.json` | `orgInit.sh` = legacy scratch-org bootstrap (kept for reference); `install.sh` is the current SDO path |
| `secrets/`, `.secrets/`, `.env` | Credentials — all gitignored (see SECRETS.md) |

---

## 3. Data flows (the parts no single file reveals)

### 3a'. No-website chat: demo-seed Contact fallback

The chat agent is also embedded on a secondary Experience Cloud page that
doesn't run our consumer-site JS. That page can't pass a deviceId
prechat field, so neither rail of the agent's identity resolution
matches: `@MessagingEndUser.ContactId` is empty (no caller match) and
the consumer-site PE-trigger never fired (no `Skywave_Conversation_Id__c`
match either).

`Skywave_ResolveSession` handles this with a third resolution step:
when both lookups miss, it queries for the single Contact carrying
`Skywave_Demo_Seed__c=true` and uses that one as the agent's
`resolved_contact_id`. The seed Contact has a populated survey, a
non-null Home_Airport, completed profile fields and a backlog of
`Booking__c` rows — so the agent immediately sees "you have flights to
talk about" and the booking ladder skips the profile form (because
`Profile_Completed__c=true`, no risk of overwriting the seed's
identity). If no Contact in the org carries the flag, the resolver
falls through to the original placeholder-mint behavior.

To rotate which Contact serves as the seed: set the flag on the new
Contact, unset it on the old one. Exactly one row should carry true.

### 3a. Anonymous visitor → known Contact (web)

This is the spine of the demo. A phone is anonymous until the survey, then a
`Contact` is stitched together across several async hops.

**Boot-time identity, no shadow tracking.** Page load reads the WebSDK's
own consent state (`SalesforceInteractions.getConsents()`) and probes the
org via `POST /api/website/session/peek` (read-only — does NOT mint a
Contact). If the SDK reports `Tracking=Opt In` AND the peek says the
deviceId already has a Contact with `Skywave_Survey_Json__c` populated,
boot resumes silently into stage-driven render. If the SDK reports no
consent, the consent screen renders. Localstorage is never used to
gate the consent screen — the SDK is the source of truth, and shadowing
it caused the prior bug where consent re-asked on every reload.

The proof cookie + Contact mint **only** at consent time
(`/api/website/session/init`, called from `handleConsent`), or silently
on resume for an already-consented returning visitor. Drive-by visitors
who never consent do not produce CRM rows.

```
Consumer site (site.js)
  │  1. loadGeo(): ipinfo.io  ──▶ {city, region, country, lat, lon}   (§3d)
  │  2. survey answers collected locally
  │  3. on survey complete: POST /api/website/contact/upsert  (same-origin,
  ▼      proof-gated — the relay stamps deviceId = the sealed proof-cookie id,
  │      NEVER a client-supplied id → forwards to Skywave_ContactUpsert)
Skywave_ContactUpsert  (Apex REST; reached via the proof-gated relay route above,
  │                     or the guest Force.com Site for legacy/anonymous callers)
  │  publishes ──▶ Skywave_Contact_Update__e   (Platform Event)
  ▼
Skywave_Contact_Update_Trigger  (runs in System Mode — guest user has no Contact perms)
  │  • upsert Contact by Session_Id__c = deviceId  (= sealed proof-cookie id)
  │  • survey_complete → store survey JSON + summary; stamp geo;
  │      derive Home_Airport__c via Skywave_Airports.nearest()  (§3d)
  │  • chat_start    → resolve conversation UUID → SF Conversation Id
  │  • publish Demo_Event__e(survey_complete) so the monitor dots the bubble
  ▼
Contact in CRM  (Session_Id__c, Skywave_Conversation_Id__c, survey, geo, airport)
  ▲
  │  agent reads it at conversation start:
Skywave_ResolveSession  (agent action — PRIMARY: @MessagingEndUser.MessagingPlatformKey
     uid:<deviceId>; FALLBACK: @MessagingSession.ConversationId; then demo-seed)
     → returns resolved Contact id + survey summary + home-airport hint
```

Key non-obvious points (each is a memory entry):
- **One identity, server-sealed.** Every keyed/persisted identity is the SAME
  sealed proof-cookie deviceId, never a client-supplied id: `/api/session/start`
  uses the proof-cookie deviceId as the `sessionId` (so the survey bubble +
  `Demo_Event__e`s key on it), the survey/`chat_start` upsert goes through the
  proof-gated `/api/website/contact/upsert` (relay overrides `deviceId` with the
  cookie), the chat verification JWT `sub` is that deviceId, and the website
  profile/bookings resolve by it. This closes the split where a returning
  visitor's live WebSDK anonymous id diverged from the sealed proof-cookie id —
  the survey then landed under one id while the booked flight (and the survey the
  agent read) landed under another. The WebSDK id is used ONLY for the Data
  Cloud `partyIdentification` event (§3a''').
- **The join-QR origin MUST equal the CORS origin.** The QR encodes the PUBLIC
  origin — the custom domain when one fronts the dyno (globe: `VITE_CONSUMER_SITE_URL`;
  LWC monitor: `Skywave_Preflight_Config.Public_Site_Url__c` via
  `Skywave_HerokuConfig.publicSiteUrl()`) — which must match Heroku's
  `SKYWAVE_PUBLIC_ORIGIN` (the `strictSameOrigin` gate). If the QR points phones
  at a different origin (e.g. the raw Heroku host while the gate allows
  `app.skywave.flights`), every `/api/website/*` **POST** is 403'd (GET reads
  slip through with no `Origin` header), so `session/peek` fails, a returning
  visitor is misclassified as new, and the survey re-runs under a fresh identity.
- **Identity is verified, not raced.** With MIAW **User Verification** on the
  channel (`authMode=Auth` + Keyset `Skywave_Identity_Keyset`), the ECv2 widget
  presents a signed JWT (`sub=deviceId`, minted by the Heroku
  `/api/website/chat-identity-token` service) via `userVerificationAPI
  .setIdentityToken`. The platform stamps it as
  `v2/iamessage/AUTH/Skywave_Identity/uid:<deviceId>` on
  `MessagingEndUser.MessagingPlatformKey`, and `Skywave_ResolveSession` resolves
  `Contact.Session_Id__c = deviceId` deterministically — the same key the
  website uses. The `chat_start` conversationId stamp below is now only a
  FALLBACK (kept for unauth/anonymous edge cases).
- The **guest user** that runs the REST endpoint can't touch Contact — that's
  *why* the write goes through a Platform Event into a System-Mode trigger.
- `chat_start` sends a snippet-generated UUID; the trigger resolves it to the
  Salesforce `Conversation` Id so the agent's linked variable can match.
- The agent's `@AuraEnabled` calls inside the chat iframe run as the **ESW
  site guest user**, not the messaging end user — see memory
  `reference-ecv2-clt-runtime-context`.
- **Chat pre-warm (hide the agent cold-start).** Once the session is verified,
  `site.js` calls `utilAPI.launchChat()` **hidden** (CSS keeps `#embedded-messaging`
  collapsed) so the Agentforce welcome generates in the background; a FAB-look-alike
  loading bubble (`#skywave-chat-warming`) covers the wait. `launchChat()` **maximizes**
  the window, and on mobile that maximized window locks background scroll — so we
  `minimizeChat()` **immediately** after launch (not just before the reveal): the
  conversation keeps warming minimized (the welcome still lands) while the page stays
  interactive behind the bubble. The real FAB is revealed the instant the welcome
  lands, detected via the ECv2 `window` event **`onEmbeddedMessagingFirstBotMessageSent`**
  (undocumented but dispatched to the host; `onEmbeddedMessagingConversationStarted`
  fires ~40s too early). A 90s safety timeout reveals anyway if the event never fires.
  **Reload:** ECv2 resumes the prior conversation on refresh and sends **no** new
  welcome, so the welcome gate would hang to the safety net. `site.js` writes a
  TTL-bounded `localStorage` breadcrumb (`sw_chat_conv_v1`) when a conversation first
  starts (`onEmbeddedMessagingConversationStarted`) and clears it when the visitor
  ends the chat (`onEmbeddedMessagingEndSession` — the "End Conversation" menu action
  in our authMode=Auth chat — or `onEmbeddedMessagingConversationClosed`); a fresh
  breadcrumb on the next load means "resume → reveal the FAB immediately, skip the
  pre-warm." (Event names verified against the served `home_view` bundle's catalog —
  there is no `onEmbeddedMessagingConversationEnded`. See memory
  `skywave-ecv2-host-event-catalog`.)

### 3a'''. The tracking pipeline that powers §3a (Tier 5, `scripts/datacloud/`)

The anonymous→known flow above rests on a Data Cloud pipeline that is **built by
`install.sh --with-tracking`** (Tier 5) — fully via the Core `/ssot/` API, no UI.
The load-bearing id is the **WebSDK anonymous deviceId** (the `skywave_proof`
cookie's `websdk` value); every downstream artifact keys on it.

Chain: a **WebApp connector** (beacon on `cdn.c360a.salesforce.com`) ← schema of
6 events (`consentLog`, `catalog`, the **custom `userProfiling`** survey event,
`contactPointEmail`, `identity`, `partyIdentification`) ← **sitemap** (PUT-ing it
is what publishes the beacon; without it the beacon is 403 and the site collects
nothing) → 4 data streams/DLOs (1 engagement bundle + 3 profile) → 6 DLO→DMO
mappings → the **custom `Survey_Response__dlm` DMO** (survey answers) → a **custom
DMO relationship** `Survey_Response.SessionId__c → ssot__Individual__dlm.ssot__Id__c`
(load-bearing — the data graph can't attach Survey_Response under Individual
without it; deployed via the `FieldSrcTrgtRelationship` Metadata API because the
REST relationships endpoint 500s) → the **IR ruleset** "Skywave Unified Individual"
(two match rules: **email** exact-normalized, and **AnonymousId/CookieId** on the
deviceId) → the **`Skywave_Customers` REALTIME data graph** rooted on
`UnifiedIndividual__dlm`. Finally the beacon CDN url is set as the relay's
`SF_INTERACTIONS_SDK_URL`.

IR fuses the **anonymous web Individual** (deviceId) to the **CRM Contact** via the
**email** rule — which needs the standard CRM connector's
`Contact_Home`→`Individual`/`ContactPointEmail` mappings (part of DC setup, not
Tier 5). There is intentionally **no CRM-side `partyIdentification` mapping** —
that event is web-only and drives the cookie-id match.

The runner (`scripts/datacloud/run_tracking.py`) replays canonical payloads
captured from the proven `si` build and normalized (`normalize_payloads.py`) to
strip the `Swv2` unified-DMO iteration artifact (→ stock `UnifiedIndividual__dlm`)
and per-build hash suffixes. Every step is idempotent (detect + reuse). Ported
from the internal `build-data360-demo` skill; see memory `skywave-tracking-tier5`.

### 3a''. Chat transport: dual-path (custom MIAW client + official ECv2)

> Status: both transports live in the consumer site, selected at runtime by the
> `CHAT_CLIENT` Heroku env var (`GET /api/config` → `chatClient`), default
> `miaw`. `site.js` `loadEswSnippet()` is now a dispatcher → `loadMiawClient()`
> (the custom scrt2 REST client below) or `loadEcv2Snippet()` (the official
> ECv2 widget, restored from git history). ECv2 is the production endgame, now
> viable because the chat site and consumer site can share one registrable
> domain (`chat.skywave.flights` + `app.skywave.flights`) — the guest cookie
> becomes first-party, killing the iOS loop. Flip `CHAT_CLIENT=ecv2` only AFTER
> the custom-domain cutover (origin repoint to `app.skywave.flights` + WebSDK
> `cookieDomain` → `skywave.flights` + ESD republish); until then `miaw` is the
> portable default. Branch: `ecv2-restore`.
>
> **User Verification on ECv2 (`authMode=Auth`).** `Skywave_Channel` carries an
> `<embeddedConfig>` with `authMode=Auth` + Keyset `Skywave_Identity_Keyset`
> (`messagingAuthorizations`). `loadEcv2Snippet()` fetches a JWT from the Heroku
> `/api/website/chat-identity-token` service (`sub=deviceId`, proof-gated) and
> calls `userVerificationAPI.setIdentityToken({identityTokenType:'JWT', …})` on
> `onEmbeddedMessagingReady` (re-called on `onEmbeddedMessagingIdentityTokenExpired`).
> This is the deterministic identity path (§3a). **`authMode` is a single global
> flag on the channel** — it is fail-closed: a session with no valid token can't
> start, and the unauth `miaw` custom client cannot share this channel while it's
> set. Heroku must have `SF_MIAW_JWT_PRIVATE_KEY` (+ `_KID` matching the Keyset
> JWK, `_ISSUER` matching the auth config). Revert = drop `<embeddedConfig>` from
> the channel + redeploy (back to unauth, custom client usable again).

> **Custom ECv2 conversation-window header (`skywaveChatHeader` LWC).** The
> official ECv2 widget's header is replaced by a Skywave-branded LWC (target
> `lightningSnapin__MessagingHeader`), selected under the `Skywave_MIAW`
> deployment's **Customize UI Components** in Setup. It renders three phases:
> a branded loading state → a "how can I help you today?" greeting with four
> tappable sample utterances. The panel auto-collapses to the slim bar once the
> visitor sends a starter, and a header chevron toggle re-opens/hides it.
> Utterances are sent via `configuration.util.sendTextMessage(text)` (a Promise,
> **not** a `dispatchMessagingEvent`). End Session calls
> `configuration.util.endSession()` (verified users) else dispatches
> `CLOSE_CONVERSATION`.
>
> **Reveal gate.** The header target gets **no** first-bot-message event —
> confirmed against the platform source: `MESSAGING_EVENT.PARTICIPANT_JOINED` and
> `conversationStatus === "OPEN"` both fire at bot **join**, a beat before the
> welcome renders; the exact `onEmbeddedMessagingFirstBotMessageSent` is a
> **host-page** window event unreachable from inside the ESW iframe (LWS blocks a
> cross-iframe relay), and the only in-iframe component that sees message content
> is the separate `MessagingTextMessageBubble` target. So the loader reveals a
> short **settle (1 s)** after the bot goes live, opportunistically reveals if the
> host event ever reaches the iframe, and has a **20 s** safety-reveal so it never
> strands the visitor. Registration IS source-carried — the `Skywave_MIAW` ESD
> metadata holds an `<embeddedServiceCustomComponents>` block
> (`customComponent=skywaveChatHeader`, `customComponentType=MIAW_Header`), so a
> deploy picks it up. But the deployment must be **Published** (Setup → Skywave
> MIAW → Publish; *Save* on the component picker is not enough) for the ESW site
> to serve it — republish after any component code change, then hard-refresh
> (iframe assets are CDN-cached).

The official ECv2 embedded client dies on **iOS Safari** in a "too many HTTP
redirects" loop: its session cookie is set on `*.my.site.com` but the host
page is `*.herokuapp.com` — different public-suffix domains, so the cookie
is third-party and iOS ITP drops it. We can't share a registrable domain
(the demo must stay transferable to any installer), so we replace the widget
with a **custom chat client that talks to the scrt2 REST API directly**. The
auth JWT comes back in the response *body* and lives in first-party
`localStorage` on the Heroku origin — nothing for ITP to block, no redirect.

Moving parts (all in `heroku/skywave-app/public/assets/` unless noted):
- `miaw-client.js` — transport on `/iamessage/v1` against the **Web**
  deployment (`Skywave_MIAW`): unauth `accessToken` → `conversation` → SSE
  receive (via `fetch`+`ReadableStream`; `EventSource` can't set the required
  `Authorization`/`X-Org-Id` headers) → `message` → `DELETE`. The unauth token
  comes back in the response body → first-party `localStorage` (the iOS fix).
- `miaw-ui.js` + `miaw-ui.css` — pixel-exact ECv2 chrome (frame geometry
  from the served `init.min.css`, animation keyframes lifted verbatim,
  colors driven at runtime from the `embedded-service-config` `branding[]`).
  `_renderClt` routes each `formatType:"ExperienceType"` message to a card
  renderer by the action name in `values[].type`. The ECv2 affordances are
  recovered VERBATIM from the live `home_view` LWR bundle (re-pull via the
  steps in `ECV2_LOOK_AND_FEEL.md`; cached in
  `raw-assets/icons-and-affordances.json`): the FAB pill ("Ask Me Anything" +
  speech-bubble glyph), the header (bubble glyph + kebab→"End chat" menu +
  chevron-down minimize), the person+sparkle agent avatar left of inbound
  bubbles (cards are indented to the same 36px gutter so they line up with
  the bubbles), per-message sender/timestamp metadata ("…Agent · 5:12 PM" /
  "Sent · …"), centered system lines ("Switched to text", "<agent> joined",
  "Just now"), the launching state (just the word "Hello", large + pulsing,
  no icon), and the dual counter-rotating ring "Thinking" spinner
  (`spinClockwise`/`spinCounterClockwise`) — pinned bottom-left above the
  composer (ECv2's `position`ed `.spinner-container`, `left:0; z-index:50`),
  not inline, so it stays put on a short transcript. Icon path data was
  confirmed by rendering each glyph to PNG. The composer send button is the
  ECv2 `arrowup` glyph (encircled up-arrow) shown INSIDE the input pill only
  once there's text — NOT the voice waveform. Strings that are
  deployment-configured (button label, placeholder, header title) are NOT in
  the bundle — taken from the client screenshots. **Agent-ready gate:** the
  composer is disabled from chat-open until the agent's FIRST message (or CLT
  card) lands — during the join→welcome lag the bot isn't listening yet, so
  anything typed then is silently dropped on the platform. While gated the
  field reads "Agent is getting ready…" and the bottom-left spinner shows
  "Agent is getting ready"; `_releaseAgentGate()` (fired from the first inbound
  `message`/`clt`, or a 30s safety timeout) re-enables + focuses it.
- `miaw-seatmap.js` + `miaw-cards.js` — standalone ports of the four CLT
  renderer LWCs (seatmap, flight options, payment, profile form), rendering
  the action-output JSON that arrives over the wire. On reload the transcript
  is backfilled via `loadEntries()`, which dispatches each entry with
  `historical=true`; `_renderClt` passes `{done:true}` so replayed cards
  render in their final, non-interactive state (seat confirmed / payment
  completed / profile saved; flight Book disabled). We assume the action
  succeeded — the live action already ran, so a re-tap must not re-fire it.
- `miaw-cards.css` — **one shared stylesheet** for all four cards: design
  tokens + primitives (`.sw-card`, `.sw-btn`, `.sw-input`, `.sw-success`,
  `.sw-anim`, …) defined once. Replaces the per-LWC style duplication (each
  LWC had re-declared the same `--sw-*` palette under its own prefix).
- `site.js` `loadEswSnippet()` now boots `MiawUI` instead of the ECv2
  snippet (same name/signature; visibility logic unchanged).

> **Why the Web deployment and NOT the Custom Client (`api`) API?** Verified
> live: **CLTs only render on the Web/v1 path** — the agent returns them as
> `formatType:"ExperienceType"` carrying the full `seatMapJSON` our renderers
> consume. The custom-client `/api/v2` deployment **flattens every CLT to
> plain text** (CLT rendering is delegated to the Lightning runtime, which the
> raw API never invokes — the structured payload is absent from the response
> entirely). Since the CLT cards are the demo centerpiece, Web/v1 wins. The
> iOS fix is independent of the deployment type (it's the first-party token).

**Identity — deviceId via the `chat_ready` handshake.** On conversation open
the client POSTs `chat_start` (deviceId + the client conversation UUID) to
`Skywave_ContactUpsert` → PE → `Skywave_Contact_Update_Trigger`, which upserts
the Contact (keyed on `Session_Id__c = deviceId`) and stamps
`Skywave_Conversation_Id__c` (resolving the UUID to the internal
`Conversation.ConversationIdentifier`). **After committing that stamp**, the
trigger publishes a `Demo_State_Change__e(Client_Action__c='chat_ready',
Target_Session_Id__c=deviceId)`; the relay fans it to the client over WS, and
`MiawUI` **gates the visitor's first message** on it (4s safety timeout). This
guarantees the stamp lands *before* the agent's turn-1 `resolve_session` runs,
so it resolves THIS device's Contact instead of racing into the
`Skywave_Demo_Seed__c` fallback. The agent and website both resolve the same
deviceId-keyed Contact, so the seat/payment ownership checks pass.
`Skywave_ResolveSession` resolves by `Session_Id__c` (deviceId) first, then by
`Skywave_Conversation_Id__c`, then demo-seed, then mint.

> Dead ends ruled out (kept here so we don't revisit): (1) `routingAttributes`
> / hidden prechat never reach the session-handler flow — the platform doesn't
> hydrate the flow input (proven v1 & v2). (2) **MIAW User Verification**
> (authenticated token + `customerIdentityToken` sub=deviceId →
> `MessagingPlatformKey`) DOES unify identity cleanly and is the "proper"
> rail — but it requires the Custom Client (`api`) deployment, which flattens
> CLTs. Auth mode is a single shared channel flag, so verified-identity and
> CLT rendering are mutually exclusive on one channel. The keypair +
> `src/miaw-identity.js` + the Keyset are parked (gitignored key in
> `.secrets/`) in case CLT support reaches the API path (e.g. AXL).

CLT card actions run through the proof-cookie'd Heroku→Apex path, then the
UI cues the agent (the same verify-only cue the LWCs sent), but the writes
no longer run as the ESW guest user:
- **seatmap** → `POST /api/website/bookings/seat-by-id` →
  `…/manage/seatById` → `changeSeatBySegmentId` → cue `"seat change confirmed"`
- **payment** → `POST /api/website/bookings/:code/pay` → `…/manage/pay` →
  `Skywave_ProcessPayment` → cue `"Payment completed"`
- **profile** → `PUT /api/website/profile` (existing route) → cue `"Profile created"`
- **flight pick** → cue-only `"Book flight <n>"` (the agent drives the booking)

The two new `manage/*` Apex actions verify booking ownership against the
resolved contact before writing.

Reference assets + the recovered styling spec live in `docs/ecv2-reference/`.

### 3b. Presenter state → every phone (web, real time)

```
Presenter edits Demo_Session__c.State__c
  ▼
Demo_Session_Trigger → publishes Demo_State_Change__e
  ▼
skywave-app  pubsub-client.js  (Salesforce Pub/Sub API gRPC subscriber)
  ▼
ws-fanout.js  → broadcasts to all connected WebSocket clients
  ▼
site.js  advances each phone's effectiveStage (capped at moderator stage)
```

**Same channel, second purpose: targeted client actions.** The PE also
carries an optional `Client_Action__c` text tag (with `New_State__c`
left null and `Target_Session_Id__c` set to the visitor's deviceId).
`server.js` branches on it: a `client_action` payload routes to the
visitor's WS only, and the client refreshes nav identity in place
without a reload. Today's only consumer is `profile_created` (published
by `Skywave_SaveProfile.publishProfileCreatedEvent` after a chat-side
profile lands). For the *phone* path we reuse this PE rather than route
the `Demo_Event__e` firehose to phones — 99% of that traffic is
irrelevant to the visitor's device.

**Isolated third purpose: the globe monitor feed.** The relay ALSO runs a
*separate* Pub/Sub subscriber on `Demo_Event__e` (`pubsub-monitor.js`, its
own gRPC instance) and broadcasts each event to `/ws/monitor` sockets only
(`ws-fanout.js` keeps a `monitors` Set distinct from the per-session phone
`sockets` Map). The 3D globe UIBundle opens that WS because it can't stream
the PEs browser-side (see §3b''). Phones never subscribe to or receive
`Demo_Event__e`; the firehose flows Pub/Sub → `monitors` → `/ws/monitor`
exclusively.

### 3b'. Visitor activity → demo monitor (web, real time)

A second, *visitor-keyed* event channel feeds the live demo monitor (the
world map + bubbles seen by the presenter). One PE type, many event types
identified by `Type__c`:

```
Skywave_RestUtil.publishEvent(...) ─┐
                                    │
  survey_complete  ── Contact-Update trigger (geo + home airport)
  flight_booked    ── Skywave_AckProfileForm  (per-leg IATA pairs + connection)
  seat_changed     ── Skywave_ChangeSeat      (new seat + flight #)
  profile_created  ── Skywave_SaveProfile     (firstName, lastName, avatarUrl)
                                    │
                                    ▼
            Demo_Event__e  (Type__c, Session_Id__c (=deviceId),
                            Demo_Session_Id__c, Payload_Json__c)
                                    │
                                    ▼
          skywaveDemoMonitor LWC  (empApi subscriber + session state)
                                    │
                                    ▼
          skywaveWorldMap LWC  (presentational; equirectangular SVG map
                                with continent silhouettes — derived from
                                Natural Earth 110m world atlas land geometry,
                                projected and inlined as ./landPath.js — plus
                                route polylines and absolutely-positioned
                                avatar bubbles)
            • places/relocates the visitor's bubble on the world map
            • draws the route line on flight_booked
            • appends seat badge on seat_changed
            • swaps cookie-id for name+avatar on profile_created
```

All publishes are **best-effort and non-blocking** — a publish failure never
breaks the booking/seat/profile write. Airport coordinates for route lines
come from `Skywave_DemoMonitorController.getAirportGeo()` (one fetch on
mount), so the per-event payloads stay small. Bubble placement uses pure
lat/lon math (`x = lon + 180`, `y = 90 − lat`).

The `Skywave_Agent_User` permset grants `Demo_Event__e` Create (= publish
on a Platform Event) so the bot user's monitor publishes go through.

### 3b''. Visitor activity → 3D globe monitor (React UIBundle)

The **`SkywaveGlobe`** UIBundle (`force-app/main/default/uiBundles/SkywaveGlobe/`)
is the successor to the 2D `skywaveDemoMonitor`/`skywaveWorldMap` LWCs above —
a spinning 3D Earth that plots the same visitors as glowing avatars with
great-circle flight arcs, plus an N-hour time-lapse **replay**. It's built with
the new **Salesforce Multi-Framework / UIBundle** capability (React +
react-three-fiber + Vite), not LWC.

It consumes the **same** `Demo_Event__e` channel, but the transport differs by
necessity:

```
  Demo_Event__e ──┬─ LIVE ──▶ Heroku relay (Pub/Sub gRPC, server-side) ──▶
                  │            /ws/monitor WebSocket ──▶ globe.
                  │            NOT browser-direct: the bundle runs on
                  │            *.salesforce.app, a different domain than the
                  │            *.my.salesforce.com session cookie → in-org
                  │            CometD 403s; and Pub/Sub Subscribe is bidi, which
                  │            gRPC-Web can't do from a browser. So Pub/Sub runs
                  │            server-side in the relay (isolated from the
                  │            consumer phones) and fans out over WebSocket.
                  │
                  └─ REPLAY ─▶ NOT the event buffer. HighVolume PEs aren't
                               replayable over CometD, so replay reconstructs a
                               Demo_Event-shaped timeline from PERSISTED RECORDS
                               (Contact geo/avatar/survey-json + Booking→Segment
                               →Flight) ordered by CreatedDate, via same-origin
                               UI API GraphQL.
```

It also carries the operator affordances ported from the 2D monitor: an
inconspicuous **seat-capability toggle** (the corner dot that flips
`Demo_Session__c.State__c` live) and a **join-QR overlay**
(`components/QrJoinOverlay.tsx`) — a corner card that enlarges to centre on
click and hides to a "QR" pill, encoding `<consumer-site>/?ds=<activeSessionId>`
so phones join scoped to the presenter's session. The consumer-site origin is
derived from `VITE_RELAY_WS_URL` (same Heroku app serves the site + relay WS;
see `lib/consumerSite.ts`) unless `VITE_CONSUMER_SITE_URL` overrides it with a
custom domain. Beside the QR sits a **call-in overlay**
(`components/CallJoinOverlay.tsx`) — a phone-icon-only button that reveals the
Skywave voice-agent number on click, so the audience can *scan to join* or
*call to join*.

Both paths fold through one shared reducer (`visitorReducer.ts`) so live and
replay look identical. **Reads/writes** (replay, survey images, seat toggle)
use **UI API GraphQL + the `@salesforce/sdk-data` SDK** — the supported path
that works in-org natively and, in local dev, through the
`@salesforce/vite-plugin-ui-bundle` `salesforce({orgAlias})` proxy. Only the
**live CometD** stream keeps a thin custom Vite `/cometd` proxy (the official
plugin doesn't proxy streaming).

**Status:** **deployed + active on `si` (production demo org, 2026-06-16)**;
reads/writes verified in-org via GraphQL. (Also exercised in a `sitest` sandbox
during development, but prod is the only deployment target.) **Installed by
`install.sh` Tier 4** (`--with-globe`/`--all`): it's excluded from the Tier 1
blanket deploy via a `.forceignore` block (so Tier 1 never ships an unbuilt
bundle or an app that references a missing bundle), then Tier 4 builds it and
deploys the bundle + app + permset + CSP together (temporarily neutralizing that
`.forceignore` block, then restoring it). **Both the build+deploy mechanics live
in `scripts/deploy-globe.sh`** — Tier 4 delegates to it, and it's also the
standalone redeploy command for any source change. The build **bakes two
org-specific origins** into the JS: `VITE_RELAY_WS_URL` (live-feed relay) and
`VITE_CONSUMER_SITE_URL` (the join-QR origin — a custom domain like
`app.skywave.flights`, CORS-gated). A plain `npm run build` with no env silently
drops both (dead feed + 403'd QR), so **always redeploy via the script**, which
resolves the origins (explicit env → live Heroku → cached state → derive), caches
them to `.deploy-tmp/install-state.env`, and bakes them in. The App-Launcher tile icon is a
`Skywave_Globe_Icon` **ContentAsset** (`contentassets/`, a 128×128 PNG shipped as
a `.asset` content file) referenced by the app's `<brand><logo>`; it is *not*
in the `.forceignore` block, so Tier 1 already lands it — Tier 4 re-includes it
in the globe deploy set only to stay self-contained. **Prerequisite:** the Multi-Framework
UIBundle app domain (`*.salesforce.app`) must be **enabled in Setup** before the
bundle will serve (Tier 4 marks this as a gate). Launched via a
**CustomApplication** (`<uiBundle>c__SkywaveGlobe</uiBundle>`, API 67.0+) + the
**`Skywave_Globe_App` permset** — which Tier 4 assigns to the running user
(org-side; doesn't ride the deploy) or the app stays hidden.
The bundle is **org-portable**: `dist/` uses only origin-relative paths, so the
same build deploys to any org. The displayed stage is **seeded from
`Demo_Session__c.State__c` on load**; replay presets are **6H/24H/7D/30D**.
**Live CometD inherits the in-org session** — `/cometd/` is same-origin on the
`*.salesforce.app` bundle domain (proven: opaque-token handshake `successful`).
Remaining: confirm My Domain "Require first-party cookies" is OFF on `si`, and
watch one live `Demo_Event__e` land end-to-end. Full architecture, file map,
run steps, status, and gotchas are in **`docs/GLOBE_MONITOR.md`**.

### 3c''. Past-booking gate

Bookings are gated by a single rule in `Skywave_BookingDateGate.cls`: a
booking is *past* iff every segment has already arrived
(`MAX(Booking_Segment__c.Arrival_DateTime__c) < NOW`). Bookings with no
segments or all-null arrivals are NOT past — that protects Pending
Confirmation rows from disappearing on data gaps.

`Skywave_GetFlightBookings.Request.deliverHistoricBookings` (default
`false`) toggles whether the past bookings are included in the result.
The chat agent never sets this — past trips don't reach the agent's
`active_bookings` array, so it can't propose seat changes on flown
itineraries or pad "your bookings" with stale entries. The website's
`Skywave_WebsiteBookings` REST endpoint and the Contact-page LWC's
`Skywave_ContactItinerary.getBookings` both surface past bookings
(tagged `isPast=true` per row) so the UI can split into separate
"Upcoming" and "Past bookings" sections.

The Contact-page LWC `skywaveItineraryCard` adds a Cancel button on
upcoming cards that calls `Skywave_ContactItinerary.cancelBooking`
→ `Skywave_BookingEngine.cancelBooking` (soft-cancel, same path as
chat + website). After cancel, the LWC `refreshApex`-es the wired
result; the cancelled booking falls out of the list because
`Skywave_ContactItinerary` filters to `Status='Confirmed'`.

### 3c'. Booking engine — single source of truth (`Skywave_BookingEngine.cls`)

All booking mutations (create / cancel / seat-change) live in one class.
Modality wrappers translate their inputs/outputs into the engine's
contract:

| Modality | Wrapper | Calls |
|----------|---------|-------|
| Website  | `Skywave_WebsiteCreateBooking` (REST) | `createBooking(req)` |
| Website  | `Skywave_WebsiteManageBooking` (REST, `/cancel` and `/seat`) | `cancelBooking()`, `changeSeat()` |
| Chat     | `Skywave_AckProfileForm` (Invocable) | `createBooking()` with `initialStatus='Pending Confirmation'` |
| Chat LWC | `Skywave_ChangeSeat.confirmSeatChange` (`@AuraEnabled`, guest-safe `without sharing` shim) | `changeSeatBySegmentId()` |
| Chat agent action | `Skywave_ChangeSeat.changeSeat` (Invocable) | `changeSeatBySegmentId()` (after preference→seat resolution via `autoSeat()`) |

The engine owns: `assignSeat` (class-zone-aware), `resolveZones` /
`parseZone` (reading Skywave_Seat_Map__c.Layout_Json__c), confirmation-
code generation, `flight_booked` / `seat_changed` / `booking_cancelled`
event publishing. Chat-vs-website differences are passed in
(`initialStatus`, `initialPaymentStatus`) — chat goes Pending/Unpaid
because the payment-widget LWC flips it later; website goes
Confirmed/Paid because clicking Book is the payment cue.

### 3c. How the Skywave Airlines Agent works

`Skywave_Airlines_Agent` is an Agent Script (`.agent`) service agent on the
**graph runtime** (`additional_parameter__enable_graph_runtime: True`). The
full topic graph and action contracts are in the `.agent` file; this section
captures the runtime mechanics that the source does *not* make obvious — the
parts that have bitten us and must not be "cleaned up" without re-reading this.

**Hub-and-spoke topic graph.** `start_agent agent_router` is the entry node; it
routes by intent to spoke subagents and never answers directly:

| Spoke | Handles |
|-------|---------|
| `flight_booking` | Book a NEW flight (search → select → profile → payment → confirm) |
| `seat_selection` | Seat change on an existing booking (single- vs multi-segment) |
| `profile_management` | Edit the visitor's own Contact profile via the profile card |
| `flight_management` | **Stub** — managing existing bookings is not supported; declines + redirects |
| `off_topic` / `ambiguous_question` | Decline-and-redirect (also catches mileage/cases, which are not built) |

Escalation is **not** a spoke — the router calls `@utils.escalate`
(`escalate_to_human`) directly for a one-hop human handoff. There is no
mileage, case-management, or live booking-management capability; requests for
those route to `off_topic`, which declines honestly and offers a human.

**Central data load (router, once per session).** The router runs
`resolve_contact` + `resolve_session` (survey/identity) and `get_bookings`
exactly once, gated by sentinels (`active_booking_count == -1`,
`resolved_contact_id != "003000000000000"`). Every spoke then reads
`@variables.active_bookings` / `active_booking_count`; **no spoke re-fetches.**
A second `get_bookings` fires once post-confirm so a just-made booking shows up.

**Booking pipeline.** Search → select → profile → payment → confirm, gated by a
`booking_step` string. The Booking__c is inserted at the *profile* gate
(`Skywave_AckProfileForm`), not at confirm — see memory. **Airport resolution:**
both search paths run origin/destination through `Skywave_Airports.resolveCode`
first, so an IATA metro code (`NYC`, `LON`, `PAR`…) or a city name resolves to
the served airport (`NYC → JFK`) — the LLM naturally emits metro codes, and
`Flight__c` only stores specific airport codes. Metro/variant tokens live in the
`Skywave_Airport__mdt.Aliases__c` SSOT (no hardcoded list); unknown tokens pass
through so search stays the authoritative "do we fly there?" gate. The agent
grounds its own destination *suggestions* on the live network via the
`Skywave_GetNetwork` action (`get_network` in the booking subagent), sourced
from the same CMDT — so adding an airport surfaces it in suggestions with no
agent republish, and there's no memorised destination list in the prompt.
Connecting flights: Skywave is a JFK hub; `Skywave_Itinerary` resolves a single OR compound flight
key (`SW3001+SW4017`); when a direct O&D search is empty, `Skywave_FlightSearch`
returns one through-JFK connection as a compound key that threads unchanged
through the card → BookFlight → per-leg `Booking_Segment__c` rows. Action
outputs render as **CLT cards** (LWCs: flight results, profile form, payment
picker, seat map); each card posts a literal chat phrase (`Book flight <key>`,
`Profile created`, `Payment completed`) back as the cue for the next step.

#### The booking-step ladder — DO NOT dedup or refactor (trace-proven 2026-06-10)

`booking_step` is derived from completion flags (`flight_selected`,
`profile_collected`, `payment_processed`, `booking_confirmed`) by a 4-line
`if`-ladder that appears **twice**: once at the top of the router's
`reasoning.instructions`, once at the top of `flight_booking`'s. They look
redundant. **They are not** — they run at different moments, and both are
load-bearing:

- **Router copy** = *cross-turn re-entry.* The router runs at the **start of
  every turn** (it's the graph entry node — confirmed by traces showing the
  router palette built before every subagent palette). It recomputes
  `booking_step` from the persisted flags, then a transition-pin
  (`if booking_step in profile/payment/confirm: transition to flight_booking`)
  deterministically re-enters the booking subagent **without** an LLM routing
  call — so a mid-booking turn can't be mis-routed.
- **`flight_booking` copy** = *within-turn chaining.* A single turn runs
  **multiple reasoning iterations** (the post-action loop: action runs →
  `reasoning.instructions` re-resolves → LLM reasons again). The ladder sits at
  the **top** of that block, so on each re-resolution it re-derives the advanced
  step from the flag the just-run action set — letting one turn chain
  `book_flight → ack_profile_form → present_payment_form`.

Why neither the ladder logic nor its duplication can move (all three tried and
trace-disproven):

1. **`if @outputs.success → set booking_step` inside a `reasoning.actions` tool
   block** — invalid grammar. Tool blocks support only `with` and `set`; the
   `if` is silently ignored (zero writes in the trace). **`sf agent validate`
   passes it anyway** — a false positive. Don't trust validate for this.
2. **`after_reasoning` block** — runs **once at turn end**, NOT between
   post-action-loop iterations (trace: `booking_step` set at the final node,
   after both LLM iterations already ran). The asset-doc claim that
   `after_reasoning` "runs after each reasoning step" is **wrong for the graph
   runtime**. The advance lands too late to chain within the turn.
3. **Tying the advance to the action output generally** — same failure: only
   `reasoning.instructions` re-resolves between within-turn iterations, so the
   ladder *must* live there, at the top.

`abort_booking` / `reset_booking` clear `booking_step=""` with all flags false;
the ladder (evaluated so the lowest step wins last) then leaves it cleared. The
returning-visitor fast path (`profile_ever_collected` true) runs
`ack_profile_form` deterministically and skips the profile card.

### 3c'''. How the Skywave Rental Car Agent works (connected sub-agent)

`Skywave_Rental_Agent` is a **separate, standalone** Agent Script service agent
(its own `.agent` bundle, its own `AGENT_USER` replacement in `sfdx-project.json`)
designed to be reached as a **connected sub-agent** from the airlines agent via a
`@agent.` handoff — the orchestrator can transfer trip context in a variable
assignment. Because a handoff keeps the **same MIAW messaging session**, the
rental agent resolves the visitor's identity independently from its own `linked`
identity variables (`@MessagingEndUser.MessagingPlatformKey` / `ConversationId`),
so it also works standalone. **The airlines agent was intentionally left untouched**
— the proactive-offer-after-confirm wiring is deferred to a future edit; the
rental agent is built ready to accept the transfer.

**Gate: no car without a flight.** The router runs `Skywave_ResolveRentalContext`
once (sentinel `rental_context_resolved`). That action *delegates identity
resolution to `Skywave_ResolveSession`* (one implementation of the
deviceId/conversationId/demo-seed logic — no drift between the two agents), then
finds the visitor's most recent **upcoming** flight booking. Its final segment's
destination + arrival date become the rental pickup location + date, and its
confirmation code links the `Vehicle_Booking__c` back to the flight `Booking__c`.
If there is no upcoming flight, `has_flight_booking` is false and the router
transitions to the `no_flight_booking` spoke (explains a car is added to a trip).

**Simpler data than flights.** Rentals need no segments/seat-zones, so there is
one object — `Vehicle_Booking__c` (Contact lookup + `Flight_Booking__c` lookup to
`Booking__c`) — written by one SSOT, `Skywave_RentalEngine`, off the catalogue in
`Skywave_RentalCatalog` (three tiers: Economy $45 / Comfort $75 / Luxury $140 per
day). Rental confirmation codes are `RC`-prefixed to stay visually distinct from
flight codes.

**Rental pipeline** (its own step ladder, same dual-copy pattern as §3c — router
copy for cross-turn re-entry, subagent copy for within-turn chaining):
offer → reserve → payment → confirm, gated by `rental_step`.

| Step | Action | CLT card / cue |
|------|--------|----------------|
| offer | `Skywave_PresentRentalOffer` | **Rental Offer card** (`skywaveRentalOfferRenderer`): one duration slider (1–14 days) + 3 tier tiles, totals recompute live as the slider moves. Reserve posts `Rent <category> for <N> days`. |
| reserve | `Skywave_ReserveVehicle` | inserts Pending/Unpaid `Vehicle_Booking__c`; returns code + total |
| payment | `Skywave_PresentRentalPayment` | **Rental Payment card** (`skywaveRentalPaymentRenderer`, twin of the flight payment picker): Demo Pay calls `Skywave_ProcessRentalPayment` (`without sharing`) to flip Paid/Confirmed, posts `Rental payment completed` |
| confirm | `Skywave_ConfirmRental` | verify-only re-read (defence against forged cues), quotes the confirmed code |

No profile step: the rental option only appears after a flight is booked, so the
Contact profile is already complete. Guest-runtime Apex (`Skywave_ProcessRentalPayment`
+ the two renderer DTOs) is granted on `Skywave_Embedded_Messaging`; the agent-run
invocables + engine/catalogue on `Skywave_Agent_User`; full FLS on `Skywave_Demo_Admin`.

### 3c''''. Destination Expert (connected sub-agent — agent-to-agent)

`Skywave_Destination_Expert` is a **deliberately minimal, pure-LLM** Agent Script
service agent: given a destination city it returns **exactly three insider tips**
(one sight, one place to eat/drink, one local tip), then hands back. No Apex, no
Flows, no CLT cards — a single `start_agent` topic with reasoning instructions only.
It reads the city from the conversation; an optional `destination_city` var lets the
parent seed it.

**Wired into the Airlines agent** (`si`, Airlines v49) as a `connected_subagent`
(Agentforce multi-agent): a `connected_subagent Skywave_Destination_Expert` block
(`target: "agent://Skywave_Destination_Expert"`) + a router action
`go_to_Skywave_Destination_Expert: @utils.transition to @connected_subagent.Skywave_Destination_Expert`.
A connected sub-agent runs in a separate context and does **not** inherit the parent's
session-linked vars, so identity is passed via the block's `inputs:` (each bound
`= @variables.X` — an *unbound* input is a hard compile error); this is why the
Airlines agent gained `EndUserId` (`@MessagingSession.MessagingEndUserId`) and
`RoutableId` (`@MessagingSession.Id`).

> **A2A does not support CLTs today.** Agent-to-agent only relays text, so a connected
> sub-agent that renders CLT cards is broken over A2A. That's why the Destination Expert
> is pure-LLM (and works), and why the CLT-heavy Rental agent (§3c''') — though built to
> be a connected sub-agent — is **not** wired into the Airlines agent on `si`. Its
> connected-sub-agent route was removed from Airlines v49 to avoid a dead path.

Still open (behavioural): the **proactive** "want insider tips about &lt;destination&gt;?"
offer at the end of the booking flow. Today the hand-off fires when the visitor *asks*
for tips/recommendations about a city. Spec: `specs/Skywave_Destination_Expert-AgentSpec.md`
(authored on the golden_template branch).

### 3d. IP geolocation → home airport (web)

`ipinfo.io` token served from `/api/config` (env var, see SECRETS.md) →
`site.js loadGeo()` resolves `lat/lon/city` → sent on `survey_complete` →
trigger stamps `Contact.Geo_*` and derives `Home_Airport__c` via
`Skywave_Airports.nearest()` (haversine over all 30 network airports) →
`ResolveSession` injects "use <airport> as the default origin" into the survey
summary the booking subagent reads. Coordinates also feed the demo-monitor
globe. Silent no-op if the token is unset.

### 3e. Voice channel

`Skywave_Voice_Agent` is a separate telephony agent (NativeVoice / Service
Cloud Voice). A `VoiceCall` before-insert trigger (`Skywave_VoiceCallResolve`)
matches the caller's phone to a Contact by trailing-9-digits and stamps caller
name fields for a personalized greeting. Escalation is single-hop to a queue
via routing flow. **Full setup steps (the UI-only gates: permset re-login,
number + NativeVoice channel, PSTN toggles, Omni-Flow binding) are documented
self-contained in `docs/VOICE_SETUP.md`** — `install.sh --with-voice` scripts the
agent publish/permsets and points there for the manual gates.

### 3e'. Hardened website surface (`/api/website/*`)

A separate, cookie-identified API layer for the Skywave website (profile,
bookings, booking creation/management) with public-demo-grade hardening:

- **JWT identity**: `skywave.website@skywave-interactive.demo` user, scoped
  to the `Skywave_Heroku_Website` permset (Contact CRUD only). Pre-authorized
  on the existing `Skywave_Heroku_Relay` Connected App via UI permset assignment.
  The phone-demo `Skywave_Heroku_Relay_Integration` permset stays read-only.
- **Identity boundary**: visitor's WebSDK deviceId is sealed into a separate
  Heroku-minted `skywave_proof` cookie (HMAC-SHA256, httpOnly, SameSite=Strict).
  WebSDK cookie is left untouched so Data Cloud datagraph continuity is
  preserved. JS can read the WebSDK Id; only the server can mint or verify
  the proof. XSS exfiltrating the WebSDK Id can't act on it without the
  matching httpOnly proof. Endpoint identity is ALWAYS the proof's deviceId
  → `Skywave_WebsiteResolveSession.cls` looks up `Contact.Session_Id__c`,
  mints a placeholder Contact when absent.
- **Tracking provenance**: `Contact.Tracking_Status__c` = `websdk` |
  `synthetic` | `opted_out`. Stamped on first sight by ResolveSession.
  Data Cloud segments filter on `websdk` for datagraph-linked populations.
  `opted_out` is sticky once set.
- **Hardening stack** (in `src/api-middleware.js`): helmet (CSP + HSTS +
  X-Frame-Options), strict same-origin CORS, dual-bucket rate limit (60
  req/min IP + 30 req/min cookie), zod schema validation per route,
  single-line JSON audit log per request (cookie + IP + route + outcome).
- **Performance**: shared HTTPS keep-alive agent (`src/sf-api.js`) pools
  every SF call, eliminating ~100ms TCP+TLS per request after first. JWT
  cached 2h, refreshed silently. Cold-start total ~500-1000ms (JWT mint +
  first SF roundtrip); warm calls ~150-300ms (SF roundtrip dominates).
- **Smoke**: `/api/website/session/init` mints/refreshes proof + returns
  Contact profile; `/api/website/me` reads it back. Cross-origin → 403,
  tampered cookie → 401.
- **`/api/website/session/peek`** (read-only): boot-time identity probe
  — given a deviceId or proof cookie, returns `{contactExists,
  surveyCompleted, profileCompleted, profile?}`. Does NOT mint a
  Contact and does NOT Set-Cookie unless a valid proof is already
  present. Used by `site.js` boot to decide consent/survey/resume
  without shadow-tracking via localStorage.
- **`/api/website/session/abandon`** (proof-required): fired from
  `userCloseModal` when the visitor X's the demo modal mid-funnel
  post-consent. Stamps `Contact.Skywave_Abandoned_At__c` +
  `Skywave_Abandon_Reason__c`; if `Skywave_Survey_Json__c` is still
  blank, persists partial answers + a "Visitor abandoned after Q<n>"
  summary so a follow-up chat session has *some* signal to ground on.
  Idempotent — never overwrites a complete survey. Uses `sendBeacon`
  client-side so the request survives the page navigation.
- **Avatar pipeline (single source of truth)**: `Skywave_AvatarPipeline.cls`
  owns the bytes-to-public-URL flow (decode base64 → insert
  `ContentVersion` → mint `ContentDistribution` → return
  `ContentDownloadUrl`). Both `Skywave_SaveProfile` (chat-iframe LWC,
  runs as ESW guest) and `Skywave_WebsiteSaveProfile` (Heroku JWT user)
  call into it. Divergence: the chat path can't write
  `Contact.ContactCardPicture__c` directly (guest can't write the field),
  so it routes the stamp through `Skywave_Contact_Update__e` + the
  System-Mode trigger. The website path calls
  `Skywave_AvatarPipeline.stampOnContact()` directly. The website also
  has TWO upload surfaces: the `#profile` form (full edit) and the nav
  greeting avatar (click-to-swap photo only); both POST to
  `/api/website/profile`, which dispatches based on whether text fields
  are present (full save) or absent (avatar-only).
- **Avatar public URL**: visitor avatars are uploaded by the chat-iframe
  LWC (running as the ESW guest) — the resulting `ContentVersion` has no
  sharing path to non-guest users, so the public website couldn't load
  it via the Shepherd path or the REST `VersionData` endpoint. Instead,
  `Skywave_Contact_Update_Trigger` (System Mode) inserts a
  `ContentDistribution` per fresh avatar event in a bulk pre-pass, then
  stamps `Contact.ContactCardPicture__c` with the resulting
  `DistributionPublicUrl` (a CDN URL with an unguessable token). The
  Heroku site serves the URL straight from `/me` and `/session/init`
  responses — no proxy, no per-impression Apex call, no API limit
  consumption. Distributions are rotated when prior avatars are deleted
  via `Skywave_SaveProfile.deletePriorAvatars` (cascades CV→CD).
- **Read paths** (Phase 2): `GET /api/website/bookings` (re-resolves
  contactId from proof, then `Skywave_WebsiteBookings.cls` calls the same
  `Skywave_GetFlightBookings` invocable the chat agent uses — single
  source of truth for booking shape). `PUT /api/website/profile` writes
  via `Skywave_WebsiteSaveProfile.cls` (zod-validated). The customer
  area UI is **integrated directly into the airline website** (not a
  separate console): the existing nav grows a "My bookings" link and an
  identity slot that swaps "Sign in" for the visitor's name + tier when
  they have a profile. Hash routes `#bookings`, `#booking/:code`,
  `#profile`, `#book` render inline into a `<section id="customer-area">`
  between the hero and the deals grid; the deals/points content hides
  while a customer route is active so the page reads as "you're in your
  account" but the hero, nav, and footer all stay visible. Identity is
  always-on: `skywave-customer.js` calls `initSession()` on page load
  (after the WebSDK resolves the deviceId via the shared
  `skywave-sdk.js` loader) so the nav greeting reflects identity
  reactively. Phone-demo flow runs in the modal layer unchanged.
- **Standalone signup surface** (`/signup`, alias `/join`): same SPA shell
  as `/`, but `site.js` detects the pathname and skips the audience-demo
  flow entirely — no `/api/session/start`, no WS connect, no survey
  schema fetch, no ESW chat warm-up. The consent gate stays (with copy
  tailored to "create your SkyRewards profile") and on Accept we still
  mint the proof cookie via `/api/website/session/init`, then dismiss
  the modal and route to the existing `#profile` customer-area so the
  visitor lands on the profile-create form. Returning visitors with a
  valid proof cookie skip both the consent gate and the demo resume —
  the customer-area picks up identity from `/api/website/me` exactly
  like on the demo path. Lets us hand out a clean URL to people who
  want to self-serve a profile without sitting through the survey.
- **Booking creation** (Phase 3): hero search-card is wired to a real
  search via `Skywave_WebsiteFlightSearch.cls` (multi-fare-class — each
  flight returns Economy/Premium/Business/First prices in one
  response). Results render inline on `#book?origin=...&destination=...
  &date=...&fareClass=...` with per-card fare-class chips and a Book
  button. Booking goes through `Skywave_WebsiteCreateBooking.cls`,
  which inserts Booking__c + Booking_Segment__c marked Confirmed/Paid
  in one transaction (website skips the chat path's Pending/Unpaid
  intermediate state because there's no payment-widget animation —
  clicking Book is the payment cue). Same `Skywave_Itinerary` helper
  as the chat path, so segment shape and connection routing (JFK hub)
  are identical. Engine wart still applies (PAR→JFK→ROM gives a 40h
  itinerary), exposed when destination has no direct route.
- **Booking management** (Phase 4): per-booking actions on
  `#booking/:code` via `Skywave_WebsiteManageBooking.cls`. Cancel
  flips `Booking__c.Status__c='Cancelled'` + `Payment_Status__c=
  'Refunded'`; change seat updates `Booking_Segment__c.Seat_Number__c`
  by segment order. Both re-verify ownership server-side (Booking__c
  must belong to the proof-cookie's contactId, 404 otherwise — defense
  in depth on top of the relay's already-resolved contactId). Both
  publish a `Demo_Event__e` so the live monitor can react. Name change
  links to the existing profile-edit page since names live on Contact,
  not per-booking.
- **Hi-fi seatmap** (Phase 4 polish): per-aircraft stylized SVG renderer
  on the booking detail. `Flight__c.Aircraft__c → Asset → Product2 →
  Skywave_Seat_Map__c` resolves the layout JSON. Layout shape extended
  with `premium`/`exitRows`/`galleyAfter` per class band; Premium
  Economy added to the 777-300ER. `GET /api/website/bookings/:code/
  seatmap?segmentOrder=N` returns layout + occupancy (other passengers'
  seats on same flight + travel date). Renderer is pure SVG: stadium
  fuselage, narrow vs wide derived from abreast string (1 aisle vs 2),
  class-band tinting, only the booked-class rows interactive (other
  classes greyed for context), exit-row red bars, galley/lavatory
  strips. Tap → confirm bar → reuses the existing `/seat` POST.
  `Skywave_WebsiteBookings.cls` now surfaces seatNumber + segmentId
  per leg so the bookings list/detail can show "Seat 27D" pills.

### 3e''. Presenter self-provisioning surface (`/request-access`, `/api/onboard/*`)

Self-service account creation so any `@salesforce.com` colleague can spin up
their own presenter account — enabled by multi-tenancy (each new admin owns
their own isolated `Demo_Session__c`). Distinct from the consumer `/signup`
surface: that mints **Contacts** (audience identities); this mints Salesforce
**Users** (presenters). Four steps, front to back:

1. **Page** — `GET /request-access` serves `public/request-access.html`, a
   standalone branded page (self-contained inline CSS/JS, `noindex`) with a
   name + work-email form. Client-side `@salesforce.com` check is a UX hint
   only; the real gate is server-side.
2. **Domain gate** — `POST /api/onboard/request` (`src/onboard-routes.js`)
   re-checks the email is *exactly* `@salesforce.com` via `isSalesforceEmail`
   (rejects lookalikes like `foo@evilsalesforce.com` and subdomains). 403
   `invalid_domain` otherwise. Guards: helmet, strict same-origin CORS, audit
   log, the global IP rate limit, **plus** a dedicated `provisionLimit` (5 per
   10 min per IP — provisioning is expensive). zod-validated body.
3. **Provision** — the relay calls Apex REST `POST /skywave/presenter/provision`
   (`Skywave_PresenterProvision.cls`, `without sharing`). It re-validates the
   domain (defense in depth), derives the username by **stripping the handle
   and re-suffixing**: `jane.doe@salesforce.com → jane.doe@skywave.demo`
   (`USERNAME_SUFFIX`), inserts a **System Administrator** User (welcome email
   suppressed via `triggerUserEmail=false`), and assigns the
   **`Skywave_Presenter` permission-set group** in a single
   `PermissionSetAssignment` (one-assignment bundle = `Skywave_Demo_Admin`
   custom-field FLS + `Demo` Agentforce/Einstein access). It then best-effort
   assigns any **optional-tier permset that exists in the org** (currently
   `Skywave_Globe_App` — App Launcher visibility for the 3D globe monitor);
   these are kept OUT of the PSG because they're `.forceignore`d on installs
   without that tier, so a PSG referencing them would fail to deploy there —
   assigning them directly at provision time stays portable (skips silently
   where the tier is absent). Idempotency keys on the **derived username only** (never on
   Email — infra users reuse a placeholder corp address, which would false-match
   and reset the wrong user's password): a re-request re-sends the reset mail
   instead of erroring (`status: resent`).
4. **Credentials mail** — a `Queueable` (`ResetPasswordJob`) runs
   `System.resetPassword(userId, true)` in a *separate* transaction (can't
   reset a password for a user created in the same transaction), which emails
   the temp-password + change-password link to the `@salesforce.com` inbox.
   The `@salesforce.com` mailbox delivery *is* the identity proof — no cookie
   on this surface.

**Why a dedicated admin JWT subject.** Provisioning needs "Manage Users",
which a Salesforce **Integration** license (the normal relay user,
`SF_USERNAME`) can *never* hold. So `/api/onboard` authenticates as a separate
full-license System Administrator, `skywave.provisioner@skywave-interactive.demo`
(`SF_PROVISION_USERNAME`), created by
`scripts/apex/createPresenterProvisionerUser.apex`. The relay's JWT auth is now
**multi-subject**: `getSalesforceToken(subject)` (`src/sf-auth.js`) caches a
token per subject and `apexInvoke(..., { subject })` (`src/sf-api.js`) selects
it. Both subjects sign with the same private key and ride the same
`Skywave_Heroku_Relay` Connected App — the provisioner just carries the
`Skywave_Heroku_Website` permset that authorizes it on that app. If
`SF_PROVISION_USERNAME` is unset the route fails loud with 503 `not_configured`
(never silently falls back to the integration user, which would 403).

The `Skywave_Presenter` PSG is re-included from the blanket-ignored
`permissionsetgroups/` folder via a `.forceignore` negation, so it ships with
the Tier-1 deploy. `install.sh --with-heroku` creates the provisioner user and
sets `SF_PROVISION_USERNAME`.

### 3f. Observability

Agentforce session traces land in Data Cloud STDM DMOs; `AgentforceOptimize‑
Service` + the `observing-agentforce` skill query them. `Skywave_Observability‑
Seeder` can synthesize sessions for a populated dashboard. Enum vocabulary
matters — see memory `skywave-stdm-synthetic-enum-vocabulary`.

**Where the dashboards' metadata comes from.** The 12 `SDO_Analytics_*` /
`SDO_AFO_Bot__c` custom objects, their Apex/LWC, the `SDO_Agentforce_Observa‑
bility_Demo` Lightning app, and the whole Data Cloud layer (data kit, 12 stream
templates, 144 DMO field maps) originate from the internal QBrix
`QBrix-6-SDO-AgentforceAnalytics` (the demo was originally built against the
`Brix-4-SDO-AF-Observability-AEA-Data` orchestrator). To avoid making recipients
install the QBrix, that metadata is **vendored** into
`vendor/sdo-agentforce-observability/` (own package dir; see its `ATTRIBUTION.md`
for provenance and the two deliberate changes: the QBrix's `Admin.profile` patch
folded into the `SDO_Agentforce_Analytics` permset, and the internal "NextGen
Data Tool" data source replaced by our own seeder + `skywave-observability-
dataset/` CSVs).

**How it gets installed.** The vendored **CRM tier** (the `SDO_Analytics_*`
objects + their Apex/LWC/app/tabs/layouts/flexipages/permsets) is a **force-app
compile dependency** — `Skywave_ObservabilitySeeder`/`Skywave_ObservabilityWipe`
reference those objects via static `new …()` types — so it deploys in **Tier 1
(§1.3b)**, *before* the blanket force-app deploy, regardless of tier. (It's plain
custom objects, no Data Cloud needed.) `install.sh --with-observability` (Tier 2)
then: enable Data Cloud → deploy the **DC layer** (§2.2b — stream templates, DMO
field maps; §2.2's CRM tier is skipped when §1.3b already ran) → assign analytics
permsets + enable
Session Tracing → **wait for STDM provisioning** (async — often minutes, seen
~7 min on a fresh SDO, but allow longer; non-blocking; resume with
`--check-stdm` / `--resume`) → **instantiate the 3 data-kit bundles** (`SDO_AFO_
STDM`/`Optimization`/`Extra` — scripted via the SSOT REST API,
`scripts/datacloud/deploy_data_kit_bundles.sh` POSTing to `/ssot/data-kits/…` +
polling `BackgroundOperation` with the `.secrets/dc.env` client-credentials token;
no MCP, Setup → Data Kits UI fallback) → seed 400 branded sessions
(scoped wipe then `Skywave_ObservabilitySeeder.SeedJob(400)`) → **Full-Refresh the
streams** (`scripts/refreshDataStreams.mjs`: frontdoor-auth a browser session and
call the run endpoint — SalesforceDotCom streams reject non-interactive tokens,
the same wall `Skywave_DataStreamRunner` documents). The `.claude/skills/skywave-
install` skill conducts the gates; `install.sh` owns the scripted steps.

**Three high-fidelity "hero" sessions sit at the top of the list — pushed straight
into the DMOs (Path 5), NOT through the SObject seeder.** The ~400 SObject sessions
carry real TOPIC + ACTION step names (a real subagent topic + a per-bucket action —
`search_flights`, `change_seat`, etc., with an `Error_Message__c` on the seat action)
so they count toward **Engagement Rate** (a non-system topic was invoked) and **Success
Rate** (an interaction executed an action with no error; seat's action errors → failure,
on-story). But their *timings* are whole-second and can never be otherwise, because
**custom SObject `DateTime` fields truncate to whole seconds on save** (verified: writing
`…:56.789` persists as `…:56.000`). A real trace has *sub-second, random* step timings, so the
three drill-down "hero" sessions are written **natively into the STDM DMOs with true
millisecond precision via the Data Cloud Ingestion API** (`scripts/datacloud/hero_obs/`,
the "Path 5" of the `agentforce-observability-data` skill) — bypassing the SObject
layer entirely. They carry a distinct `ssot__DataSourceId__c` (`Skywave_Hero_*`) so
they coexist cleanly with the SObject (`Salesforce_Home`) and real (`AIPlatform`) rows.

Each hero replays a real `Skywave_Airlines_Agent` trace turn-by-turn with the genuine
step choreography — `VARIABLE_UPDATE_STEP` → `TOPIC_STEP` → `LLM_STEP` → `ACTION_STEP`
(the agent's **real** action names: `resolve_session`, `get_bookings`, `search_flights`,
`book_flight`, `present_profile_form`, `ack_profile_form`, `present_payment_form`,
`confirm_booking`, `check_seat_enabled`, `get_segment_count`, `present_seat_map`) →
`TRUST_GUARDRAILS_STEP` — with **real millisecond durations** sampled from a live
session (actions ~150–650 ms, LLM ~0.5–1.5 s, a deliberately hung ~18 s failed
`present_seat_map`, 15–35 s user think-time gaps) and populated `Error_Message__c`
on the failing steps. Timings are RNG-seeded (deterministic) and row Ids are stable,
so the daily re-push UPSERTs the same rows with today-relative timestamps rather than
duplicating. They are dated **day `-1`, hours apart** (18:40 / 16:20 / 14:05) so they
top the list; the SObject population is pushed to `-15..-2`. The three tell the
Chapter-6 story: **#1** a booking that *Completes* (Q5) then a seat change that fails
and is *Abandoned* (Q1); **#2** a clean booking that *Completes* (Q5); **#3** a seat
upgrade that fails and is *Escalated* (Q1).

The module: `dc_ingest.py` (client-credentials → CDP edge client), `stdm_schema.py`
(the 11-object DLO→DMO field-map spec), `hero_story.py` (the 3 scripted sessions +
generator), `seed_heroes.py` (`setup` = one-time source/stream/mapping stand-up;
`push` = generate + ingest the 3 heroes, run daily; `outcomes` = score EVERY
synthetic session for the Optimization KPIs, run daily; `verify`/`teardown`). Auth
reuses the `Skywave_Heroku_Relay` client-credentials + cdp scopes (`.secrets/dc.env`,
or `DC_*` env vars in CI). The daily `refresh-observability` workflow re-runs `push`
+ `outcomes` as its 3rd/4th steps (pure REST — no browser, unlike the SObject
Full-Refresh).

**Session Outcome / Deflection / Abandon / Escalation KPIs (Optimization).** These
are NOT driven by `ssot__AiAgentSessionEndType__c` alone — the Optimization *Session
Outcome* is derived from two platform-provisioned **Predefined** score tags,
`std_Deflection_Score_<agent>_V1` (Number 0–5) and `std_Abandonment_Score_<agent>_V1`
(TRUE/FALSE/Unsure): **Deflected** = deflection 4–5; **Abandoned** = abandonment TRUE
or deflection < 3; **Escalated** = the session has a `SESSION_END`-type interaction
step named **`CLOSED_TRANSFERRED`** (the session-end reason; NOT the end-type field,
NOT the `__human__` topic, NOT the `escalate_to_human` router tool — see below). The
analyzer
never scores synthetic data and the associations orphan whenever an SObject reseed
regenerates unified ids, so `seed_heroes.py outcomes` (re)creates **session-level**
score associations (null moment) for every synthetic session via the Ingestion API —
querying the live session ids fresh and deriving each session's scores from its
end-type. Target mix ≈ **60 % Deflected / 30 % Abandoned / 10 % Escalated**, tuned by
the SObject seeder's end-type distribution (`SEAT_ABANDON_PCT`, ~10 % `Escalated`).
Must re-run after any reseed/full-refresh (it's a workflow step + a reseed step).

🔑 **The KPIs read the association's own `ValueText__c` + `SourceType__c`, not the
joined tag-row value** — matching the real analyzer output (`ValueText__c` = the score
`"0".."5"` / `"true"/"false"`, `SourceType__c='PROMPT_TEMPLATE'`). Without them,
Engagement/Success only count the ~9 real analyzer-scored sessions (~0.6%). Both are on
the `AiAgentTagAssociation` ingestion schema + generator. **Reinstall gotcha:** those two
DLO→DMO field mappings must be added **manually in the Data Cloud UI** (the mapping is
create-only, can't be API-edited once it has dependents): `ValueText__c → ValueText__c`
and `SourceType__c → SourceType__c` on the `Skywave_Hero_TagAssoc_*` DLO →
`ssot__AiAgentTagAssociation__dlm`. **Escalation Rate** is driven by the semantic
model's `Escalation_Status_clc` calc (retrieved verbatim from
`Service_Agent_Analytics_SDM_e11` via the Tableau Semantics REST API
`/ssot/semantic/models/…`, and independently confirmed against Salesforce's shipped
SDM source + the `SessionEndReason` enum):

```
Escalation_Status = { FIXED session : MAX( IF
    ( [Interaction Step].[Ai_Agent_Interaction_Step_Type]='SESSION_END'
      OR DATEDIFF('HOUR', {FIXED session: MAX([Interaction].[End_Timestamp])}, NOW()) >= 24 )
    AND [Interaction Step].[Name]='CLOSED_TRANSFERRED' THEN TRUE ELSE FALSE END )}
Escalated Sessions = COUNTD(sessions where Escalation_Status);  Escalation Rate = Escalated / Unique Sessions
```

So a session counts as escalated iff it has an **interaction step with
`ssot__AiAgentInteractionStepType__c='SESSION_END'` and `ssot__Name__c='CLOSED_TRANSFERRED'`**
(the session-end reason). `CLOSED_TRANSFERRED`/`CLOSED_ACTION`/`CLOSED_USER_REQUEST` are
the three `SessionEndReason` closure codes; the optimization runtime maps
`ESCALATED → CLOSED_TRANSFERRED`. Setting the step type to `SESSION_END` satisfies the
OR-branch, so sessions <24 h old still count. This is **NOT** the end-type field, the
`__human__` topic, or the `escalate_to_human` router tool — those last two were A/B
red herrings (`Skywave_Voice_Agent` renders escalation with end-type `NOT_SET`; the
router's `escalate_to_human` is the runtime *cause*, `CLOSED_TRANSFERRED` is the
downstream *consequence* the SDM measures). So each escalated session's `SESSION_END`
interaction carries a `SESSION_END`-type `CLOSED_TRANSFERRED` closure step (SObject
seeder + `hero_story.py`; existing rows patched by
`scripts/apex/backfillEscalationClosureStep.apex`), and carries no deflection score (a
deflection 4-5 would reclassify it Deflected). The realistic `escalate_to_human`
router call + double-quote-JSON payloads are kept as trace fidelity, not KPI drivers.

**Assessments are pre-baked and realistic across all sessions.** The Optimization
analyzer never scores synthetic (`Salesforce_Home`) data, so the seeder writes the
assessment fields directly: **Session Outcome** (`AI_Agent_Session_End_Type__c` → STDM
`ssot__AiAgentSessionEndType__c`) uses the real enum — `Completed` for successful
intents, and for seat-change sessions ~65 % `Abandoned` / the rest `Escalated` (the
old lowercase `'resolved'` was stale and mapped to no recognised outcome); **Response
Quality Score** is the per-moment `Quality_Score` tag (booking intents 4–5, seat
intents 1–2); and **Quality Score Reasoning** (`Association_Reason__c`) is analyst-style
prose keyed to intent + score — no more canned `"Quality score N"`.

**Dates are a rolling window — they mostly self-freshen.** The seed data is *not*
stored as absolute dates. Every `SDO_Analytics_*` row carries a fixed relative
day-offset (`Start_Days__c`/`End_Days__c`/`Created_Days__c`/`Message_Sent_Days__c`,
`-15..-2` for the bulk population and `-1` for the three hero sessions) plus an
`HH:mm:ss` `*_Time__c` string, and the timestamp the
STDM DMOs actually read is a **`TODAY()`-relative formula** —
`Start_Timestamp__c = DATETIMEVALUE(TEXT(TODAY() + Start_Days__c) + " " + Start_Time__c)`.
So the whole dataset rolls forward on its own; N days after seeding it still reads
as "the last two weeks." **Two exceptions** are written as *stored* absolute
instants by `Skywave_ObservabilitySeeder` and therefore freeze at seed time:
`SDO_Analytics_AIAgentSession_v2__c.End_Timestamp__c` and
`…AIAgentSessionParticipa_v2__c.End_Timestamp__c` (both mapped to DMO
`EndTimestamp`). Left alone they drift behind their auto-freshened Start and yield
negative session durations. **To re-freshen a stale demo:** run
`scripts/apex/freshenObservabilityDates.apex` (idempotent — re-aligns each stored
`End_Timestamp` to its formula `Start_Timestamp` day; a no-op once aligned), then
**Full-Refresh the streams** (`scripts/refreshDataStreams.mjs`) so Data Cloud
re-ingests — the DMOs are a frozen snapshot, so *no* CRM date change (even the
self-freshening formulas) reaches the dashboards until the streams re-run.
**Automated daily:** `.github/workflows/refresh-observability.yml` runs both steps
in order on a GitHub-hosted runner — JWT-auth → the freshen Apex → `npm ci` +
`npx playwright install chromium` → the stream Full-Refresh. **The daily schedule
does not run in *this* repo:** the `sfdc-qbranch-emu` org enforces a GitHub IP
allow list that blocks GitHub-hosted runners (their egress IPs are dynamic), so a
scheduled run here 403s at `actions/checkout` (and `notify-failure` can't even file
its alert — it 403s too). The scheduled run therefore lives in a personal-account
**mirror, `t-birke/skywave-observability-refresh`** (cron 09:00 UTC), which has no
org allow list; the job only ever talks to Salesforce (JWT + Playwright), never the
source org's GitHub, so the allow list is irrelevant there. The three scripts + the
workflow are copied verbatim into the mirror — keep them in sync — and this repo's
copy is `workflow_dispatch`-only (usable manually from an allow-listed context, e.g.
a future self-hosted runner). The secrets (§SECRETS.md) are set on both repos. It has to run the *browser* flow because `SalesforceDotCom`
streams reject every non-interactive caller (Connect REST run endpoint *and*
scheduled Apex alike — the wall `Skywave_DataStreamRunner` documents), so there is
no headless/in-org path. **Its identity is deliberately its own** (not release-notes'):
the Playwright step bridges the JWT token into a Lightning session via `frontdoor.jsp`,
which requires a **`Web`-scoped** OAuth session — and the shared `Skywave_Heroku_Relay`
app grants only `Api`/`RefreshToken`/CDP (no `Web`) on purpose, so a relay JWT session
bounces straight to the login page. So the workflow authenticates as a **dedicated
JWT-bearer app `Skywave_CI_Refresh`** (adds `Web`; reuses the relay keypair, so no new
key material) as a **dedicated automation user `skywave.refresh.bot`** (Standard User +
the Data Cloud/analytics permsets to open `DataStream` pages & Full-Refresh, plus
`Skywave_Heroku_Website` to be pre-authorized on the app). The user + permsets are
provisioned by `scripts/apex/createRefreshAutomationUser.apex`; the app is
ConnectedApp metadata, but the permset↔app authorization is UI-only (done via an
Apex `SetupEntityAccess` insert). The freshen step's result is verified by
`scripts/ci/check_apex_result.py`, **not jq** — `sf apex run --json` embeds
NUL/control bytes in its debug log that strict JSON parsers reject and bash `$()`
corrupts, which would otherwise turn a successful run into a daily false failure. A
failed run files an `observability-refresh-failure` tracking issue (in whichever repo
ran it — normally the mirror).

### 3g. Preflight check (presenter pre-demo go/no-go)

The **Demo Home** tab in the *Skywave Demo Management* app (LWC `skywaveDemoHome`,
the app's landing tab — replaces the old standalone Preflight tab) is the
per-presenter control surface, split into two halves: the left half creates your
own `Demo_Session__c` and selects exactly one as active (owner-scoped); the right
half is the **changelog** (LWC `skywaveReleaseNotes` → `Skywave_ReleaseNotesController`
→ `Release_Note__c`), listing the most recent releases newest-first. Below both it
**embeds** the `skywavePreflight` LWC, so the same **Check Demo** button surfaces
silent-config-drift risks that `git status` cannot show. `Release_Note__c` rows are
written by the `release-notes` GitHub Action (`.github/workflows/release-notes.yml` →
`scripts/sync-release-notes.mjs`) on each published GitHub Release: it groups the
commits since the previous tag into notes and JWT-upserts them by `Version__c`
(secrets in SECRETS.md). That button drives a single Apex orchestrator
(`Skywave_PreflightController.runPreflight`) that fans out across three planes:

- **Org** — SOQL only: active Demo_Session present + reset to `idle`, survey
  questions seeded, Flight/Booking/Skywave_Seat_Map row counts non-zero.
- **Agent & chat** — bot user holds `Skywave_Agent_User` permset (the silent‑
  action‑filter trap), `Skywave_Airlines_Agent` BotVersion is Active.
- **Heroku relay** — one callout to `GET /api/preflight` on the dyno (new
  `heroku/skywave-app/src/preflight.js`), guarded by an `x-preflight-key`
  shared secret. The dyno self-reports: Pub/Sub subscriber connection state
  (new `getSubscriberStatus()` export from `pubsub-client.js`), four `ESW_*`
  + `SF_INTERACTIONS_SDK_URL` echo for org-side diff, `process.uptime()` plus
  a `cycleSoon` flag (Heroku exposes no per-dyno restart schedule — uptime
  ≈22h is the actionable signal to restart pre-demo). `?e2e=1` adds a
  loopback push probe that registers a synthetic socket in `ws-fanout` and
  verifies `fanOut` delivers.
- **Platform / outage** — Statuspage.io JSON (`status.heroku.com/api/v2/{in‑
  cidents/unresolved,scheduled-maintenances/upcoming}.json`) for active
  incidents and upcoming scheduled maintenance.
- **Manual confirms** — two click-to-mark rows for the things no API can
  verify: ESD republished since last agent publish/activate, and a CLT card
  visually rendering in the chat preview.

Config: `Skywave_Preflight_Config__mdt.Default` holds `Heroku_Origin_Url__c`,
`Preflight_Key__c` (must match Heroku `PREFLIGHT_KEY` config var), and
`Statuspage_Base_Url__c`. Two new remote site settings (`Skywave_Heroku_Relay`,
`Skywave_Heroku_Statuspage`) whitelist the callouts. The Default record's
`Preflight_Key__c` is set out-of-band (anonymous Apex via Metadata API), not
in source — the value never lands in git, only in `.secrets/preflight.key`
locally and as the `PREFLIGHT_KEY` Heroku config var.

**Heroku relay origin — one source of truth.** The dyno URL carries a per-install
Heroku hash (`skywave-app-<hash>.herokuapp.com`), so it can't be hardcoded. It
lives once in `Heroku_Origin_Url__c` and everything reads it through
`Skywave_HerokuConfig.originUrl()` — `Skywave_SessionStart` (derives the `wss`
URL), `skywaveDemoMonitor` (QR target, via `getHerokuOrigin`), and
`Skywave_PreflightController`. The CMD record + `Skywave_Heroku_Relay` remote
site carry a `%%SKYWAVE_HEROKU_ORIGIN%%` placeholder (sfdx-project.json
`replaceWithEnv`), which `install.sh` Tier 3 fills with the captured
`heroku apps:info` URL and redeploys (§3.2b). Security allowlists that can't read
a CMD — the globe `wss://` CspTrustedSite and the ESW iframe whitelist —
wildcard `*.herokuapp.com` instead. The globe UIBundle bakes its relay URL at
build via `VITE_RELAY_WS_URL` (no default; see its README).

### 3h. Sourcing orchestration (mock Flow Orchestrator demo)

A **standalone** demo — not part of the live audience flow — showing what a complex
strategic-purchasing process looks like as a Flow **Orchestration** (`processType =
Orchestrator`). Lives in `flows/`, documented in `flows/README_Sourcing.md`.

- **Launch:** record-triggered on the mock `Sourcing_Request__c` object
  (`recordTriggerType=Create`, `RecordAfterSave`). Creating a request starts a run;
  `$Record` is the context record threaded into every step.
- **Shape:** 6 stages / 8 steps, all `stepBackground`, with data threaded stage-to-stage
  (`Step_<Name>.Outputs.<var>`). A top-level **`<decisions>` element (`Bid_Quality_Gate`)**
  forks after bid evaluation: a qualifying leader (`out_LeadingScore > 0`) → negotiate →
  award → contract; otherwise → a terminal **"Sourcing Cancelled"** stage
  (`Skywave_Sourcing_Cancel`) that records the reason and recommends re-scoping the RFP. An
  entry-condition gate on the final contract step keeps it from running unless the approval
  decision = `Approved`. Both branches verified end-to-end (default threshold 75 → Meridian
  87.6 → award/contract Completed; per-request threshold 95 → none qualified → cancellation
  Completed).
- **Bid evaluation is data-driven (not mocked).** `Skywave_Sourcing_Evaluate_Bids` reads the
  request's **`Supplier_Bid__c`** rows (master-detail child, `BID-{0000}`), computes each
  bid's `Weighted_Total__c` from its four component scores (price/quality/sustainability/
  service, 0–100) against the request's **configurable** weight fields (`Weight_*__c`,
  default 40/25/20/15, normalized by their sum), ranks them, flags the single winning
  `Is_Leading_Bid__c` if it clears the request's `Qualifying_Threshold__c` (default 75), and
  bulk-writes results back. Nothing about suppliers/scores/weights is hardcoded. It is also
  the demo's **Flow Builder teaching canvas** (~20 elements: 3 data + bulk/targeted updates,
  three fault paths, a Loop, four Decisions, formula resources, an sObject collection). The
  example bids are seeded by the RFP-release step (`Skywave_Sourcing_Issue_RFP_Sim`) — the
  one place example supplier names live; real bids would come from suppliers. FLS for both
  objects is on `Skywave_Demo_Admin` (added to `regen-demo-admin-fls.py`).
- **Human steps are *simulated*.** The two review points (Category Manager releases the RFP;
  Procurement Director approves the award) are modelled as background "approval-sim" stubs
  (`Skywave_Sourcing_Issue_RFP_Sim` → `out_ReleaseDecision='Released'`;
  `Skywave_Sourcing_Award_Approval_Sim` → `out_ApprovalDecision='Approved'`) so the whole
  orchestration runs green without a work-item assignee. The real `stepInteractive` screen
  flows (`Skywave_Sourcing_Issue_RFP`, `_Award_Approval`) are kept in the repo to swap back
  in once assignment is sorted — see the assignee blocker below.
- **The two AI hand-offs** (the point of the demo): the *Draft RFP* step hands to a
  **prompt template** (`generatePromptResponse` → `Skywave_Sourcing_RFP_Draft`), and the
  *Negotiate* step hands to the existing **Agentforce agent** (`generateAiAgentResponse` →
  `Skywave_Airlines_Agent`). Each wraps its AI call in a fault path that falls back to mock
  text so the run completes even if the agent/template is unavailable.
- **Two gotchas that cost activation** (both now encoded in source): interactive steps
  *require a context record* — each maps `ActionInput__RecordId` → `$Record.Id`, else
  activation fails with *"A context record is required for interactive steps"*; and the
  prompt template must be **Published** with a top-level `<activeVersionIdentifier>` or it
  exposes no invocable action, leaving the Draft-RFP subflow `InvalidDraft`.
- **A third gotcha that costs *rendering* (not activation):** a hand-authored orchestration
  deploys and runs fine but opens in Flow Builder as **empty stage placeholders** unless it
  carries the builder metadata. Now in source: three top-level `<processMetadataValues>`
  (`CanvasMode=AUTO_LAYOUT_CANVAS`, `BuilderType`, `OriginBuilderType`) and, on every step, a
  `<stepSubtype>` (lowercase `t` — `BackgroundStep`/`InteractiveStep`) plus the builder
  boolean fields (`canAssigneeEdit`, `debugSimulateStep`, `entry`/`exitConditionLogic`,
  `runAsUser`, `shouldLock`). No CLI error surfaces — the flow just doesn't draw. Full
  write-up in the `sf-flow-orchestration` skill.
- **Confirmed blocker — `stepInteractive` is not licensed on this SDO (why the human steps
  are simulated).** Any interactive step fails at *runtime* with
  `FLOW_ELEMENT_ERROR|Invalid Resource reference|FlowOrchestratedStage` the instant its
  stage is entered — **zero** `FlowOrchestrationStepInstance` rows, `FlowOrchestrationInstance.Status=Error`,
  `CurrentStage=null`. It fails identically for **every** assignee (`$User.Id`,
  `$Record.OwnerId`, a formula → active System Admin Id, and a public **Group**) and
  regardless of position (even as the *first* step, synchronously, before any async pause),
  while every `stepBackground` step runs clean — so the assignee value, async ordering,
  data refs, and rendering metadata are all exonerated.
  **Root cause (confirmed):** the org lacks the Flow-Orchestration runtime *license*. The
  `ManageOrchestrationRuns` and `ReassignOrchestrationWorkItems` user permissions are held
  by **no** permission set or profile in the org, and deploying either onto `Skywave_Demo_Admin`
  is rejected with *"The user license doesn't allow the permission: ManageOrchestrationRuns"*.
  Interactive steps need those perms to write `FlowOrchestrationWorkItem`/`StepInstance`;
  without the entitlement the runtime can't materialise a work item and aborts at stage entry.
  This is why the only working interactive orchestrations here are managed packages
  (`CAB`=ApprovalWorkflow, `CMS_BasicApprovalRequest`=ManagedContentAuthoringWorkflow) — they
  ship their own packaged licensing. **Not fixable from source on this SDO**; needs the Flow
  Orchestration license provisioned on the org. Diagnosis matches an internal
  Flow-Orchestration swarm answer (missing *Access/Manage Orchestration* perms + Work Guide
  component are the classic zero-step-instance causes). Worked around by simulating the two
  human steps (above); the real `stepInteractive` screen flows are retained in the repo and
  will work as-is once the license is present.

---

## 4. Moving parts that are NOT in git

These bite hardest because nothing in the repo shows they exist or that they
must be redone. Treat this as the operational checklist.

| Thing | Where | When you must touch it |
|-------|-------|------------------------|
| **ESD republish** | Setup UI / `scripts/publishEmbeddedServiceDeployment.mjs` | **After every agent publish/activate**, or chat CLT cards silently degrade to plain text. Demo-critical. (memory) |
| `AGENT_USER` env var | shell, inline before `sf` agent commands | deploy AND publish fail without it (`sfdx-project.json` `replaceWithEnv` — fires for all 3 `.agent` bundles: chat, baseline, voice; their `default_agent_user` is the `skywaveserviceagent@example.com` placeholder that gets substituted). `install.sh` exports it. (memory) |
| Voice number + channel + PSTN toggles | Setup → Communication Channels + Agentforce Voice Setup | **Tier 6 (`--with-voice`) conducts these** — claim number + NativeVoice channel (after the NativeCCaaS permsets + re-login Tier 6 §6.1), and the 2 PSTN toggles ("Connect Related Voice Calls" + "Record Voice Calls" — empty transcript without them). UI-only, no API. Routing → `skywave_routing` queue (in metadata). |
| Heroku Config Vars | `skywave-app` dyno | `IPINFO_TOKEN`, `SF_ESW_*`, JWT key, etc. `install.sh` Tier 3 sets the derivable ones; secrets are manual. See `.env.example` + SECRETS.md. |
| Heroku relay origin | `Heroku_Origin_Url__c` CMD + remote site (`replaceWithEnv`); globe via `VITE_RELAY_WS_URL` | Single source of truth read via `Skywave_HerokuConfig`. `install.sh` §3.2b fills it from `heroku apps:info` post-provision. Globe must be rebuilt with the build flag. |
| `Skywave_Demo_Admin` FLS | permset (in git); regen via `scripts/regen-demo-admin-fls.py` | Every new custom field/object must get full FLS on this permset or the presenter hits phantom INVALID_FIELD. Add it to the script's `OUR_OBJECTS`/`STD_FIELDS`, run the script, deploy the permset. (default rule, memory) |
| Inactive BotVersions | org | Can't be deleted — every API path is dep-blocked. Failed iterations stay pinned. (memory) |

---

## 5. Org & tooling conventions

- **`sf`, not `sfdx`** (deprecated). Org aliases: `si` = target SDO (default),
  `e`/`electra` = reference org (read-only).
- `sf` CLI runs need `dangerouslyDisableSandbox: true` in this environment
  (sandbox blocks `~/.sf/` log writes). (memory)
- Commit + push after every completed step. (memory)
- The repo will go public — no secret material is ever committed (SECRETS.md).

---

*Keep this current as the system changes. If an entry here would just mirror
the code, delete it and let the code speak; if it captures a why or an
out-of-git fact, it belongs here (or as a `MEMORY.md` entry).*

*A pre-commit hook (`.githooks/pre-commit`, enabled via
`git config core.hooksPath .githooks`) prints a reminder whenever a commit
touches structural files but not this doc. It never blocks — it just nudges
you to check whether a flow, component, path, or moving part changed.*
