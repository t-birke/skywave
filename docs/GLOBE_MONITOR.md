# Skywave Globe Demo Monitor — Deep Dive

> **Fresh-session quickstart:** this doc is written so a new session can pick up
> with zero prior context. Read §0 first, then §6 (Monday plan) if you're
> resuming on/after the release update.

The **globe monitor** is a spinning 3D Earth that plots live demo visitors as
glowing avatars, draws their booked flight routes as great-circle arcs, and
supports an N-hour time-lapse "replay". It is the successor to the 2D
`skywaveWorldMap` / `skywaveDemoMonitor` LWCs (ARCHITECTURE.md §3b'), rebuilt
as a **React app** using Salesforce's new **Multi-Framework / UIBundle**
capability (open beta).

- **Location:** `force-app/main/default/uiBundles/SkywaveGlobe/`
- **Lives on branch:** `custom-chat-client` (merged from `globe-uibundle` 2026-06-12)
- **Origin:** ported from the `~/dev/centCom` dashboard's `HoloGlobe`
  (react-three-fiber), reskinned from "services" to "Skywave visitors".

---

> **Status (2026-06-16):** DEPLOYED + active on **`si`** (production) — the real
> target. (Also exercised in a `sitest` sandbox during dev, but prod is the only
> deployment target.) Installed by **`install.sh` Tier 4** (`--with-globe`/`--all`).
> Data reads/writes
> run on UI API GraphQL + `@salesforce/sdk-data` (same-origin, in-org native).
> **Live feed = Heroku relay `/ws/monitor` WebSocket** (Pub/Sub runs server-side;
> browser-direct CometD/Pub/Sub is impossible — see §6), verified end-to-end on
> `si`. **Prerequisite:** the Multi-Framework UIBundle app domain
> (`*.salesforce.app`) must be enabled in Setup before deploying. See §6.

## 0. TL;DR — run it locally right now

Local `npm run dev` is the fastest iteration loop. It proxies `/services/data`
to whichever org is authed (default `si`); override with `SKYWAVE_ORG=<alias>`:

```bash
cd force-app/main/default/uiBundles/SkywaveGlobe
npm install          # first time only
# SKYWAVE_ORG=<alias> npm run dev   # ← point at a different authed org
npm run dev          # Vite dev server → http://localhost:5173 (uses si)
```

You need the target org authed (`sf org display --target-org <alias>` must
return a token) — the `salesforce({orgAlias})` plugin uses it to proxy
`/services/data` (GraphQL reads/writes) for the dev server.

Then open http://localhost:5173. The globe spins; if a demo session is live (or
you publish events / use Replay), visitors appear. The LIVE feed is the same
relay `wss://…/ws/monitor` WebSocket used in-org (no proxy); point dev at a
different relay via `VITE_RELAY_WS_URL`. Override the org with
`SKYWAVE_ORG=<alias> npm run dev`.

**Seeing nothing?** That's expected with no live activity. Click a replay preset
(**6H / 24H / 7D / 30D**) in the top-left HUD to replay that window from records
(deterministic — always shows data if any exists). Pick a window wide enough to
reach your data: between live runs the newest demo records can be **days old**,
so 24H may come back empty while 7D/30D fill the globe. Or publish a synthetic
visitor — see §5.

---

## 1. Why this exists / the big decisions

| Decision | Why |
|---|---|
| **React UIBundle, not an LWC** | Shows off Salesforce Multi-Framework; the centCom globe is react-three-fiber and ports near-verbatim vs. a full vanilla-Three.js LWC rewrite. |
| **Live data via the Heroku relay WebSocket, not browser CometD/Pub/Sub** | `lightning/empApi` is LWC-only and the UIBundle SDK has no streaming. Browser-direct CometD 403s (the bundle is on `*.salesforce.app`, a different domain than the `*.my.salesforce.com` session cookie) and Pub/Sub `Subscribe` is bidi (gRPC-Web can't). So Pub/Sub runs **server-side in the relay**, which fans `Demo_Event__e` out on an isolated `/ws/monitor` WebSocket the globe connects to. See §6. |
| **Reads/writes via UI API GraphQL + Data SDK** | `@salesforce/sdk-data` (`createDataSDK().graphql()` for reads, `.fetch()` PATCH `/ui-api/records/{id}` for writes) — the supported path, works in-org natively and in dev through the `salesforce({orgAlias})` plugin's `/services/data` proxy. Replaced the old custom `/sf-query`+`/sf-data` SOQL proxies. |
| **`wss://` needs its own CspTrustedSite** | The bundle domain enforces `connect-src`, and CSP treats `wss://` as a distinct scheme from `https://` — so the existing `https://…herokuapp.com` grant doesn't cover the WebSocket. `cspTrustedSites/Skywave_Globe_Relay_Wss` grants the `wss://` origin. |
| **Replay from records, not the event buffer** | CometD/Pub/Sub **cannot replay** `Demo_Event__e` (HighVolume PE — only new events deliver; replay is durable-Pub/Sub only, verified `replay -2`/specific-replayId both return zero). So replay reconstructs a Demo_Event-shaped timeline from persisted Contact/Booking records and time-lapses it through the same reducer. |

---

## 2. Architecture at a glance

```
  si org                                          React app (in-org OR npm run dev)
  ┌────────────┐   Pub/Sub    ┌───────────────┐    ┌──────────────────────────────┐
  │ Demo_Event │──gRPC(bidi)─▶│ Heroku relay  │    │ useDemoFeed (LIVE)            │
  │ __e (HVPE) │  server-side │ pubsub-monitor│    │   ▲ wss://relay/ws/monitor    │
  └────────────┘              │     ▼         │    │   │ (isolated; no proxy)      │
                              │ /ws/monitor ──┼───▶│   └───────────────┐           │
  ┌────────────┐              └───────────────┘    │ useReplay (REPLAY)│           │
  │ Contact,   │   UI API GraphQL (same-origin)    │   GraphQL→timeline│           │
  │ Booking,   │◀──────────────────────────────────┤        both feed ─▼           │
  │ Flight     │  /services/data (in-org native;   │ visitorReducer (shared fold)  │
  └────────────┘   dev via salesforce() plugin)    │   └─ HoloGlobe (r3f scene)    │
                                                    └──────────────────────────────┘
  Phones are on a SEPARATE relay track (Demo_State_Change__e → /ws/<sessionId>);
  they never see the Demo_Event__e firehose.
```

**The key seam:** both LIVE and REPLAY produce `Demo_Event__e`-shaped payloads
that flow through the **same** `visitorReducer.applyPlatformEvent()`. They can't
visually drift because they share that fold. LIVE stamps wall-clock time + a
30-min TTL; REPLAY stamps record `CreatedDate` + no TTL (everyone stays shown).

---

## 3. File-by-file map

All paths under `force-app/main/default/uiBundles/SkywaveGlobe/src/`.

### Globe scene (`globe/`)
| File | Role |
|---|---|
| `HoloGlobe.tsx` | The `<Canvas>` + scene. Earth sphere (canvas texture), grid, atmosphere shader, radar sweep, airports, markers, arcs, camera auto-orbit, and the avatar-anchored detail panel. **Entry point for the 3D view.** |
| `GlobeMarker.tsx` | One visitor: glowing avatar (or status dot fallback), status ring, ping for selected, name label, hover tooltip. Handles **backside occlusion** of the HTML overlays in `useFrame` (CSS can't depth-test WebGL). |
| `GlobeArc.tsx` | One flight path: great-circle polyline (glow underlay + animated dashed line) + route-name label at the apex. |
| `GlobeAirports.tsx` | Static network: small dots + faint IATA labels for every airport in `AIRPORTS`. |
| `arcGeometry.ts` | **Single source of truth for arc curves.** Great-circle slerp + sine altitude arch (`radius = base + peak·sin(πt)`, so it never dips below the surface). Apex height tunable in km (`APEX_PER_RADIAN_KM`, `MAX_APEX_KM` ≈ 320km). `arcPoints()` renders the line; `arcPointAt(...,0.5)` places the avatar on the arc. |
| `data/geo.ts` | `latLngToVector3` / `latLngToArray` + the canvas Earth texture (continents from `ne_110m_land.json`). |
| `data/ne_110m_land.json` | Natural Earth 110m land geometry (continent silhouettes). |
| `shaders/atmosphere.ts` | Fresnel atmosphere glsl. |
| `types.ts` | `GlobeMarker`, `GlobeArcData`, `MarkerStatus` — the domain-neutral contract the scene consumes. |

### Data layer (`data/`)
| File | Role |
|---|---|
| `visitors.ts` | The **`Visitor` model** + `toMarkers()` / `toArcs()` — maps visitors to globe marker/arc shapes. Owns placement (avatar rides the arc midpoint for booked, geo location otherwise), status→color, route→IATA label. |
| `visitorReducer.ts` | **Shared fold.** `applyPlatformEvent(map, payload, stampTime)` handles `session_started` / `survey_complete` / `survey_answer` / `flight_booked` / `seat_changed` / `profile_created`. `snapshot(map, now, ttl)` → `Visitor[]`. Used by both live + replay. |
| `useDemoFeed.ts` | **LIVE.** WebSocket client to the Heroku relay's `/ws/monitor`. Handles `{type:'demo_event', payload}` (folded via the reducer) + `{type:'stage_changed', newState}`, with reconnect/backoff. URL from `VITE_RELAY_WS_URL` (defaults to the prod relay). Exposes `{ visitors, stage, status }`. `[globe-feed]` console logs; `VERBOSE` adds per-event detail. |
| `useReplay.ts` | **REPLAY.** Fetches the timeline, plays it through the reducer at a steady tick (spread over ~8s so 1000s of events auto-throttle). Exposes `{ phase, visitors, progress, total }`. |
| `graphql.ts` | **UI API GraphQL helpers** — `queryEdges()` (run a uiapi query, return `edges[].node`), `v()` (unwrap `{ value }`), `sinceIso()`, `updateRecord()` (write via Data SDK `fetch` PATCH `/ui-api/records/{id}`). The data-access seam. |
| `replayData.ts` | **GraphQL → timeline.** Queries Contact (+geo, +`ContactCardPicture__c` avatar, +`Skywave_Survey_Json__c`) and Booking_Segment→Flight via `queryEdges`; emits ordered `Demo_Event__e`-shaped entries by `CreatedDate`. |
| `surveyImages.ts` | Loads the `Survey_Answer_Option__c` image map once (`<questionKey>:<answerKey>` → `Image_Url__c`) for the answer thumbnails. |
| `airports.ts` | `AIRPORTS`: IATA → {city, lat, lon} for the 29-airport network. **Mirrors `Skywave_Airports.ALL` (Apex)** — keep in sync if the network changes. |

### UI (`pages/`, `components/`)
| File | Role |
|---|---|
| `pages/Home.tsx` | Top-level: chooses LIVE vs REPLAY, renders `<HoloGlobe>`, the HUD (status dot, stage, visitor count, **LIVE/6H/24H/7D/30D** preset buttons, replay progress bar), the **join-QR overlay**, and the inconspicuous seat-toggle dot; loads the option-image map. **Seeds the displayed stage from `Demo_Session__c.State__c`** (one `fetchActiveSession` read, shared with the seat toggle + the QR scope) so the status shows before the first live event; a relay `stage_changed` event overrides it. |
| `components/VisitorPanel.tsx` | The click-detail panel: avatar, name, route/seat, survey-answer thumbnails. Rendered inside the scene (anchored to the avatar) by `HoloGlobe`, so it tracks globe rotation. |
| `components/QrJoinOverlay.tsx` | The **join QR** — bottom-right corner card that **enlarges** to a centred ~75vh on click and **hides** to an inconspicuous "QR" pill via the ×. Dynamic: encodes `<consumer-site>/?ds=<activeSessionId>` (scoped to the presenter's session), re-rendered when the active session changes. The 3D port of the QR card on the 2D `skywaveDemoMonitor` LWC; renders via `qrcode.react`'s `QRCodeCanvas`. |
| `lib/consumerSite.ts` | Resolves the consumer-site origin the QR points phones at. Derives it from the build-time `VITE_RELAY_WS_URL` (same Heroku app serves the site + the relay WS) by swapping `wss:`→`https:` and dropping the path; `VITE_CONSUMER_SITE_URL` overrides (e.g. a custom domain). `joinUrl(sessionId)` builds the full `…/?ds=<id>` target. |

### Config
| File | Role |
|---|---|
| `vite.config.ts` | **The local bridge.** `salesforce({ orgAlias })` plugin proxies `/services/data` (GraphQL/SDK) — auth-correct, `SKYWAVE_ORG` overrides the alias. No `/cometd` proxy anymore — the live feed is the relay's absolute `wss://` URL, which works the same in dev and in-org. |
| `ui-bundle.json`, `*.uibundle-meta.xml` | UIBundle metadata (label, routing). |

---

## 4. How live data flows (LIVE mode)

Browser-direct streaming is impossible here (see §6), so the chain is:

1. Apex publishes `Demo_Event__e` during a real demo (see ARCHITECTURE.md §3b' —
   `Skywave_SaveProfile`, `Skywave_AckProfileForm`, `Skywave_ChangeSeat`, the
   Contact-Update trigger). HighVolume PE, `PublishImmediately`.
2. The **Heroku relay** subscribes to `Demo_Event__e` over Pub/Sub gRPC
   (server-side — `pubsub-monitor.js`, isolated from the consumer phones) and
   broadcasts each event as `{type:'demo_event', payload}` to `/ws/monitor`.
3. `useDemoFeed` holds a WebSocket to `wss://<relay>/ws/monitor`, parses each
   message, and runs the payload through `applyPlatformEvent()` →
   `setVisitors(snapshot(...))`. `stage_changed` messages update the HUD stage.
4. `toMarkers/toArcs` shape it; `HoloGlobe` renders.

Stage also seeds from `Demo_Session__c.State__c` on load (same-origin GraphQL),
so the HUD shows the real stage before the first live event arrives.

## 4b. How replay works (REPLAY mode)

1. Click a preset (e.g. 24H) → `useReplay({ hours: 24, nowMs })`.
2. `fetchReplayTimeline()` runs two UI API GraphQL queries (via `queryEdges`):
   - Contacts in window → `session_started` (geo) + `profile_created`
     (name/avatar from `ContactCardPicture__c`) + `survey_answer` (parsed from
     `Skywave_Survey_Json__c`).
   - Booking_Segments → `flight_booked` (origin→dest IATA from `Flight__r`) +
     `seat_changed`.
3. Entries sorted by `CreatedDate`, then played through the reducer a few per
   tick so it fills in as a smooth time-lapse.

---

## 5. Testing / publishing synthetic events

`Demo_Event__e` **requires `Demo_Session_Id__c`** — `EventBus.publish` silently
returns `success=false` without it, yet `sf apex run` still prints "Executed
successfully". Always include it. Example (`/tmp/pub.apex`, then
`sf apex run --target-org si --file /tmp/pub.apex`):

```apex
Demo_Session__c d = [SELECT Id FROM Demo_Session__c WHERE Active__c = true
                     ORDER BY Started__c DESC NULLS LAST LIMIT 1];
Id dsid = d.Id;
String sid = 'test-' + String.valueOf(Datetime.now().getTime());
Skywave_RestUtil.publishEvent('session_started', sid, dsid,
    new Map<String,Object>{'lat'=>40.0,'lon'=>-83.0,'city'=>'Columbus'});
Skywave_RestUtil.publishEvent('profile_created', sid, dsid,
    new Map<String,Object>{'firstName'=>'Test','lastName'=>'User',
                           'avatarUrl'=>'https://i.pravatar.cc/80?u=test'});
Skywave_RestUtil.publishEvent('survey_answer', sid, dsid,
    new Map<String,Object>{'questionKey'=>'trip_type','answerKey'=>'beach','answerText'=>'Beach & sun'});
Skywave_RestUtil.publishEvent('flight_booked', sid, dsid,
    new Map<String,Object>{'isConnection'=>false,
        'legs'=>new List<Object>{ new Map<String,Object>{'from'=>'LAX','to'=>'JFK'} }});
```

LIVE has a subscribe-then-publish race (replay `-1` = new events only) and
React StrictMode double-mounts the client in dev — so for **deterministic**
verification prefer **REPLAY** (click 24H), which reads persisted records.

---

## 6. In-org status & remaining work

**DONE — deployed to prod (`si`):**
- **`si`** (production demo org, 2026-06-16, deploy `0Afg8000006L2pmCAC`, 93/93
  components). The real deployment target is **prod only**; the globe is not part
  of `install.sh`. (A `sitest` sandbox was used during dev, 2026-06-15, but isn't
  a deployment target.) **Requires the Multi-Framework UIBundle app domain
  (`*.salesforce.app`) enabled in Setup first.**
  The bundle is **org-portable** — `dist/` uses origin-relative `/services/data/…`
  for reads/writes; the only absolute URL is the relay `wss://…/ws/monitor`
  (build-overridable via `VITE_RELAY_WS_URL`), which is org-independent. Nothing
  points at a specific Salesforce org. (`dist/` is the deploy payload — gitignored
  but NOT forceignored, so `npm run build` before each deploy.)
- **Launch wiring solved.** A deployed UIBundle gets no `AppMenuItem` on its
  own. Fix = a **CustomApplication** with `<uiBundle>c__SkywaveGlobe</uiBundle>`
  (NOT a CustomTab — it rejects `<uiBundle>`; needs `sourceApiVersion` 67.0+) +
  a dedicated **`Skywave_Globe_App` permset** for App Launcher visibility.
  **The permset must be assigned to the running user** (`sf org assign permset
  --name Skywave_Globe_App`) — assignment is org-side, it does NOT ride the
  deploy. Until assigned, `AppMenuItem.IsAccessible=false` and the app is hidden.
- **Data path: UI API GraphQL + Data SDK** — works in-org natively, no custom
  REST proxy. Verified end-to-end against both orgs.
- **Live feed: Pub/Sub → Heroku relay → `/ws/monitor` WebSocket.** Browser-direct
  streaming is a DEAD END (proven against `si`, 2026-06-16): an in-org CometD
  handshake to `…--c.my.salesforce.app/cometd/60.0/` returns `failureReason:
  401::Request requires authentication` → `403::Handshake denied`, because the
  session `sid` cookie is scoped to `*.my.salesforce.com` and the bundle runs on
  `*.salesforce.app` (different registrable domain — the browser never sends it,
  and the bundle gateway injects auth only for the UI-API/GraphQL allowlist, not
  `/cometd`). Pub/Sub-direct is also impossible: `Subscribe` is bidirectional
  streaming, which gRPC-Web can't do from a browser. So Pub/Sub runs SERVER-side
  in the Heroku relay (`heroku/skywave-app/src/pubsub-monitor.js`, a subscriber
  ISOLATED from the consumer phones) and fans the `Demo_Event__e` firehose out
  over an isolated `/ws/monitor` WebSocket. `useDemoFeed` opens
  `wss://<relay>/ws/monitor` (overridable via `VITE_RELAY_WS_URL`) and folds each
  event through the same reducer.
- **CSP: the `wss://` relay origin needs its OWN CspTrustedSite.** The bundle
  domain enforces `connect-src`. An existing `skywave_heroku` trusted site
  already allowed `https://skywave-app-…herokuapp.com`, but **CSP treats `wss://`
  as a distinct scheme from `https://`** — the WebSocket was refused
  (`Connecting to 'wss://…' violates… connect-src`) until we added a separate
  `wss://` entry: `cspTrustedSites/Skywave_Globe_Relay_Wss` (endpoint
  `wss://skywave-app-…herokuapp.com`, `isApplicableToConnectSrc=true`). Deployed
  to `si` 2026-06-16.
- **Live feed VERIFIED end-to-end in production (`si`, 2026-06-16).** Published a
  `Demo_Event__e` (SaveResult OK) → it flowed Pub/Sub → relay → `/ws/monitor` →
  the deployed globe and the marker appeared, confirmed in `[globe-feed]` logs
  (`WebSocket OPEN` → `event applied: session_started … changed: true`). Per-event
  debug logging is OFF by default (`VERBOSE` in `useDemoFeed.ts`); connection-level
  logs still print.

**STILL TO DO / VERIFY:**
1. **Watch a REAL end-user-device event land** (vs. the synthetic test publish).
   The transport is proven; what's unwatched is an actual visitor on the demo
   path producing a marker. Gotcha for any manual test: `EventBus.publish` can
   report success while the `SaveResult` failed (missing required
   `Demo_Session_Id__c`) — always check the SaveResult.
2. **The relay is now a globe dependency.** If the Heroku dyno is down, the live
   feed is down — fall back to REPLAY presets (same-origin GraphQL, no relay).
   The stage still seeds from `Demo_Session__c.State__c` on load regardless.

---

## 7. Gotchas (hard-won — don't relearn these)

- **The Multi-Framework app domain must be enabled in Setup first.** A UIBundle
  serves from `*.salesforce.app`; until that domain is enabled on the org (Setup
  → the Digital Experiences / Multi-Framework app-domain setting), the deploy can
  succeed but the app won't load. This is a one-time, org-side **prerequisite**
  that does NOT ride the metadata deploy — enable it before deploying the bundle.
  (`install.sh` Tier 4 marks this as a gate; the globe ships to prod `si` only.)
- **Browser-direct streaming is impossible from a UIBundle — don't try.** In-org
  CometD to `…--c.my.salesforce.app/cometd/` → `403::Handshake denied`
  (`401::Request requires authentication`): the bundle is on `*.salesforce.app`,
  a different registrable domain than the `*.my.salesforce.com` session cookie,
  so the browser never sends `sid`, and the bundle gateway injects auth only for
  the UI-API/GraphQL allowlist, not `/cometd`. Pub/Sub `Subscribe` is *bidi*
  streaming, which gRPC-Web can't do. → run Pub/Sub server-side (relay) and push
  over WebSocket. (My Domain "Require first-party cookies" being OFF does NOT
  rescue CometD — the domain mismatch is the killer.)
- **`wss://` is a separate CSP scheme from `https://`.** A `https://host`
  CspTrustedSite does NOT authorize `wss://host` — the WebSocket gets refused by
  `connect-src`. Add a dedicated `wss://` trusted site (`isApplicableToConnectSrc`).
- **HighVolume PEs don't replay over CometD/Pub/Sub.** Only new events deliver.
  Replay is from records. (the whole reason `replayData.ts` exists)
- **`EventBus.publish` can fail silently** — `success=false` but `sf apex run`
  says "Executed successfully". `Demo_Event__e` requires `Demo_Session_Id__c`.
  Check the `Database.SaveResult`.
- **FLS truncates SOQL describe.** `Geo_City__c`/`Geo_Country__c` 404'd in CLI
  SOQL until granted on `Skywave_Demo_Admin` (every custom field needs full
  access there). Don't trust a describe to tell you a field doesn't exist —
  grep the codebase.
- **`<Html>` overlays can't depth-test WebGL.** Avatars/labels/panel bleed
  through the globe's back side; we hide them in `useFrame` when
  `facing <= 0.08`. Flight arcs are real 3D `Line` geometry, so they're fine.
- **Avatar is persisted on `Contact.ContactCardPicture__c`** (Url, public CDN
  via `Skywave_AvatarPipeline`) — that's what replay reads.
- **Don't `git stash pop` on the wrong branch.** The bundle source only exists
  on `globe-uibundle`/`custom-chat-client`; a stash taken there won't apply
  elsewhere.
- **`sf org display --json` REDACTS `accessToken`** → returns the literal
  `"[REDACTED] Use 'sf org auth show-access-token' to view"` (~54 chars). Using
  it as a bearer token → `INVALID_AUTH_HEADER`. Get the real token (112 chars,
  has `!`) from `sf org auth show-access-token --json` under `result.accessToken`
  (the human form prints a confirmation banner). (Now only relevant for ad-hoc
  CLI/token tests; the bundle itself holds no token.)
- **UI API GraphQL:** `Id` is leaf type `ID!` → select it **bare** (`Id`), not
  `Id { value }` (else `SubselectionNotAllowed`). Scalars come back as
  `{ value }`; records as `edges[].node`. Can't filter `where` on a
  parent-relationship field → filter client-side. CreatedDate range:
  `{ CreatedDate: { gte: { value: "<iso>" } } }`.
- **GraphQL is read-only; writes need the SDK `fetch`.** Update records via
  `PATCH /services/data/vXX/ui-api/records/{id}` through `createDataSDK().fetch`
  (adds CSRF — a raw `fetch` 401s; raw `/sobjects` PATCH isn't on the official
  proxy allowlist → 404). See `graphql.ts` `updateRecord()`.
- **Official `sf ui-bundle dev` defers to the in-Vite plugin.** It detects the
  `salesforce()` plugin and skips its standalone proxy — so just
  `SKYWAVE_ORG=<alias> npm run dev`; the plugin (with `orgAlias`) is the proxy.

---

## 8. Tuning knobs

| Want to change | Where |
|---|---|
| Arc apex height | `arcGeometry.ts` → `APEX_PER_RADIAN_KM` (190), `MAX_APEX_KM` (320) |
| Marker colors (status) | `GlobeMarker.tsx` → `STATUS_COLORS` |
| Replay duration | `useReplay.ts` → `TARGET_DURATION_MS` (8000) |
| Replay presets | `pages/Home.tsx` → `PRESETS` |
| Visitor stale-out (live) | `visitorReducer.ts` → `SESSION_TTL_MS` (30 min) |
| Airport network | `data/airports.ts` (mirror `Skywave_Airports.cls`) |
| Backside-hide threshold | `GlobeMarker.tsx` / `HoloGlobe.tsx` → `facing <= 0.08` |
| Target org for local dev | `SKYWAVE_ORG` env var (default `si`) |
