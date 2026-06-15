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

> **Status (2026-06-15):** DEPLOYED + active in the **`sitest`** Multi-Framework
> sandbox. Data reads/writes run on the official UI API GraphQL + `@salesforce/sdk-data`
> path (works in-org natively); only live CometD streaming still uses a custom
> Vite proxy. `si` is still gated (no Multi-Framework yet). See §6.

## 0. TL;DR — run it locally right now

Local `npm run dev` is the fastest iteration loop (and how to drive it against
the deployed sandbox). Use `SKYWAVE_ORG=sitest` for the Multi-Framework org:

```bash
cd force-app/main/default/uiBundles/SkywaveGlobe
npm install          # first time only
# SKYWAVE_ORG=sitest npm run dev   # ← against the Multi-Framework sandbox
npm run dev          # Vite dev server → http://localhost:5173
```

You need the `si` org authed (`sf org display --target-org si` must return a
token). On `npm run dev` you should see:

```
[skywave] CometD proxy → https://trailsignup-....my.salesforce.com (token NNN chars)
```

Then open http://localhost:5173. The globe spins; if a demo session is live (or
you publish events / use Replay), visitors appear. Override the org with
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
| **Live data over CometD, not empApi** | `lightning/empApi` is LWC-only. The UIBundle data SDK has **no streaming**. CometD (the Streaming API empApi wraps) works from any browser JS. |
| **Reads/writes via UI API GraphQL + Data SDK** | `@salesforce/sdk-data` (`createDataSDK().graphql()` for reads, `.fetch()` PATCH `/ui-api/records/{id}` for writes) — the supported path, works in-org natively and in dev through the `salesforce({orgAlias})` plugin's `/services/data` proxy. Replaced the old custom `/sf-query`+`/sf-data` SOQL proxies. |
| **Live still uses a custom `/cometd` proxy** | The official plugin proxies only graphql/ui-api/connect/chatter/apexrest — NOT streaming. So `useDemoFeed` keeps a thin Vite `/cometd` proxy (Bearer injected; token from `sf org auth show-access-token`, NOT `sf org display` which redacts it). |
| **Replay from records, not the event buffer** | CometD **cannot replay** `Demo_Event__e` (HighVolume PE — replay is a Pub/Sub-gRPC feature only; verified: `replay -2` and specific-replayId both return zero). So replay reconstructs a Demo_Event-shaped timeline from persisted Contact/Booking records and time-lapses it through the same reducer. |

---

## 2. Architecture at a glance

```
                    ┌─────────────────────────────── LOCAL (npm run dev) ───┐
  si org            │  Vite dev server (localhost:5173)                     │
  ┌──────────┐      │   ├─ serves the built React app                       │
  │ Platform │      │   ├─ /cometd   → proxy → org  (Bearer injected)       │
  │ Events   │──────┼──▶│   └─ /services/data → official plugin → org GQL  │
  │ (CometD) │ live │   │                                                    │
  └──────────┘      │   ▼                                                    │
  ┌──────────┐      │  React app                                            │
  │ Contact, │      │   ├─ useDemoFeed   (LIVE: CometD subscribe)           │
  │ Booking, │ GQL  │   ├─ useReplay     (REPLAY: GraphQL → timeline → ticks)│
  │ Flight   │◀─────┼───┤        both feed →                                │
  └──────────┘      │   ├─ visitorReducer (shared fold → Visitor[])         │
                    │   └─ HoloGlobe (react-three-fiber scene)              │
                    └────────────────────────────────────────────────────────┘
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
| `useDemoFeed.ts` | **LIVE.** CometD client (`cometd` npm). Handshake → subscribe `Demo_Event__e` + `Demo_State_Change__e` → fold via reducer. Exposes `{ visitors, stage, status }`. |
| `cometdReplay.ts` | Salesforce CometD replay extension (`ext.replay` map) — registered on the client; we subscribe with replay `-1` (new only). |
| `useReplay.ts` | **REPLAY.** Fetches the timeline, plays it through the reducer at a steady tick (spread over ~8s so 1000s of events auto-throttle). Exposes `{ phase, visitors, progress, total }`. |
| `graphql.ts` | **UI API GraphQL helpers** — `queryEdges()` (run a uiapi query, return `edges[].node`), `v()` (unwrap `{ value }`), `sinceIso()`, `updateRecord()` (write via Data SDK `fetch` PATCH `/ui-api/records/{id}`). The data-access seam. |
| `replayData.ts` | **GraphQL → timeline.** Queries Contact (+geo, +`ContactCardPicture__c` avatar, +`Skywave_Survey_Json__c`) and Booking_Segment→Flight via `queryEdges`; emits ordered `Demo_Event__e`-shaped entries by `CreatedDate`. |
| `surveyImages.ts` | Loads the `Survey_Answer_Option__c` image map once (`<questionKey>:<answerKey>` → `Image_Url__c`) for the answer thumbnails. |
| `airports.ts` | `AIRPORTS`: IATA → {city, lat, lon} for the 29-airport network. **Mirrors `Skywave_Airports.ALL` (Apex)** — keep in sync if the network changes. |

### UI (`pages/`, `components/`)
| File | Role |
|---|---|
| `pages/Home.tsx` | Top-level: chooses LIVE vs REPLAY, renders `<HoloGlobe>`, the HUD (status dot, stage, visitor count, **LIVE/6H/24H/7D/30D** preset buttons, replay progress bar), loads the option-image map. **Seeds the displayed stage from `Demo_Session__c.State__c`** (one `fetchActiveSession` read, shared with the seat toggle) so the status shows in-org even before/without live CometD; a live `Demo_State_Change__e` event overrides it. |
| `components/VisitorPanel.tsx` | The click-detail panel: avatar, name, route/seat, survey-answer thumbnails. Rendered inside the scene (anchored to the avatar) by `HoloGlobe`, so it tracks globe rotation. |

### Config
| File | Role |
|---|---|
| `vite.config.ts` | **The local bridge.** `salesforce({ orgAlias })` plugin proxies `/services/data` (GraphQL/SDK) — auth-correct. `resolveOrg()` (token from `sf org auth show-access-token`, NOT `sf org display`) + the `/cometd` proxy remain ONLY for live streaming. Serve-only, never `build`. `SKYWAVE_ORG` overrides the alias. |
| `ui-bundle.json`, `*.uibundle-meta.xml` | UIBundle metadata (label, routing). |

---

## 4. How live data flows (LIVE mode)

1. `useDemoFeed` creates a `CometD` client pointed at `window.location.origin/cometd/60.0/`.
2. **Critical:** `cometd.unregisterTransport('websocket')` — cometd defaults to
   WebSocket, which Salesforce doesn't speak and the Vite proxy doesn't tunnel;
   without this the handshake hangs silently. We force **long-polling**.
3. Handshake → subscribe to `Demo_Event__e` (per-visitor firehose) +
   `Demo_State_Change__e` (presenter stage).
4. Each event payload → `applyPlatformEvent()` → `setVisitors(snapshot(...))`.
5. `toMarkers/toArcs` shape it; `HoloGlobe` renders.

The events themselves are published by Apex during a real demo (see
ARCHITECTURE.md §3b' — `Skywave_SaveProfile`, `Skywave_AckProfileForm`,
`Skywave_ChangeSeat`, the Contact-Update trigger).

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

**DONE — deployed to `sitest` (Multi-Framework sandbox, 2026-06-15):**
- `sf project deploy start --source-dir force-app/main/default/uiBundles --target-org sitest`
  succeeded; UIBundle "Skywave Globe" is active. (`dist/` is the deploy payload —
  gitignored but NOT forceignored, so `npm run build` before each deploy.)
- **Data path migrated to UI API GraphQL + Data SDK** — works in-org natively,
  no custom REST proxy. Verified end-to-end against `sitest`.
- **Token fix:** read the dev token from `sf org auth show-access-token`, never
  `sf org display` (which redacts it → 401s). Only matters for the `/cometd`
  proxy now.

**STILL TO DO:**
1. **App Launcher access.** A deployed UIBundle gets **no `AppMenuItem`** on its
   own — it's not launchable from the org UI yet (App Launcher shows nothing;
   `/lightning/app/SkywaveGlobe` 404s → falls back to default app). Needs a
   CustomTab/CustomApplication pointing at the bundle, or the right bundle URL.
   **Resolve this before any in-org demo.**
2. **Live (CometD) in the deployed bundle.** Reads/writes work in-org via the
   SDK, but live streaming used the local Vite `/cometd` proxy, which doesn't
   exist in the deployed app. Open: does a raw `cometd` handshake to same-origin
   `/cometd` inherit the runtime session? If it 401s, fall back to extending the
   Heroku relay with a `/ws/monitor` channel (subscribes to `Demo_Event__e`).
   (Replay + seat toggle already work in-org — they're on the SDK path.)
   **Until this lands, in-org the HUD shows no live visitors and the live stage
   stays `idle`** — so use a REPLAY preset to populate the globe, and note the
   **stage is now seeded from `Demo_Session__c.State__c` on load** (so the
   upper-left status reflects the real demo stage even without CometD; a live
   `Demo_State_Change__e` overrides it once streaming works).
3. **`si` (the demo org)** doesn't have Multi-Framework yet. When its gate opens:
   Setup → Quick Find "Salesforce Multi-Framework" → Enable Domain (⚠️
   irreversible; `si` is demo-critical) → disable My Domain "Require first-party
   cookies" → build + deploy as above.

---

## 7. Gotchas (hard-won — don't relearn these)

- **cometd default transport is WebSocket** → `ws://localhost/...` hangs before
  handshake. Must `unregisterTransport('websocket')`. (in `useDemoFeed.ts`)
- **HighVolume PEs don't replay over CometD.** Only live `-1` works. Replay is
  from records. (the whole reason `replayData.ts` exists)
- **`EventBus.publish` can fail silently** — `success=false` but `sf apex run`
  says "Executed successfully". `Demo_Event__e` requires `Demo_Session_Id__c`.
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
  it as a bearer token → `INVALID_AUTH_HEADER` / CometD `403`. Get the real
  token (112 chars, has `!`) from `sf org auth show-access-token --json` (parse
  `result` from the first `{` — the human form prints a confirmation banner).
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
  `SKYWAVE_ORG=sitest npm run dev`; the plugin (with `orgAlias`) is the proxy.

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
