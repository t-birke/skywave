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

## 0. TL;DR — run it locally right now

The in-org deploy is **gated** until the Multi-Framework feature opens (see §6).
Until then — and as the fastest iteration loop regardless — run it locally:

```bash
cd force-app/main/default/uiBundles/SkywaveGlobe
npm install          # first time only
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

**Seeing nothing?** That's expected with no live activity. Click **24H** in the
top-left HUD to replay the last 24h from records (deterministic — always shows
data if any exists). Or publish a synthetic visitor — see §5.

---

## 1. Why this exists / the big decisions

| Decision | Why |
|---|---|
| **React UIBundle, not an LWC** | Shows off Salesforce Multi-Framework; the centCom globe is react-three-fiber and ports near-verbatim vs. a full vanilla-Three.js LWC rewrite. |
| **Live data over CometD, not empApi** | `lightning/empApi` is LWC-only. The UIBundle data SDK has **no streaming**. CometD (the Streaming API empApi wraps) works from any browser JS. |
| **Local Vite proxy injects the token** | The bundle can't deploy in-org yet (feature gate). Locally, the browser talks same-origin to `localhost`; Vite forwards `/cometd` + `/sf-query` to the org with a `Bearer` token injected server-side. No CORS, no cookies, no org deploy. |
| **Replay from records, not the event buffer** | CometD **cannot replay** `Demo_Event__e` (HighVolume PE — replay is a Pub/Sub-gRPC feature only; verified: `replay -2` and specific-replayId both return zero). So replay reconstructs a Demo_Event-shaped timeline from persisted Contact/Booking records and time-lapses it through the same reducer. |

---

## 2. Architecture at a glance

```
                    ┌─────────────────────────────── LOCAL (npm run dev) ───┐
  si org            │  Vite dev server (localhost:5173)                     │
  ┌──────────┐      │   ├─ serves the built React app                       │
  │ Platform │      │   ├─ /cometd   → proxy → org  (Bearer injected)       │
  │ Events   │──────┼──▶│   └─ /sf-query → proxy → org REST query (Bearer)  │
  │ (CometD) │ live │   │                                                    │
  └──────────┘      │   ▼                                                    │
  ┌──────────┐      │  React app                                            │
  │ Contact, │      │   ├─ useDemoFeed   (LIVE: CometD subscribe)           │
  │ Booking, │ SOQL │   ├─ useReplay     (REPLAY: SOQL → timeline → ticks)  │
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
| `replayData.ts` | **SOQL → timeline.** Queries Contact (+geo, +`ContactCardPicture__c` avatar, +`Skywave_Survey_Json__c`) and Booking_Segment→Flight; emits ordered `Demo_Event__e`-shaped entries by `CreatedDate`. Via the `/sf-query` proxy. |
| `surveyImages.ts` | Loads the `Survey_Answer_Option__c` image map once (`<questionKey>:<answerKey>` → `Image_Url__c`) for the answer thumbnails. |
| `airports.ts` | `AIRPORTS`: IATA → {city, lat, lon} for the 29-airport network. **Mirrors `Skywave_Airports.ALL` (Apex)** — keep in sync if the network changes. |

### UI (`pages/`, `components/`)
| File | Role |
|---|---|
| `pages/Home.tsx` | Top-level: chooses LIVE vs REPLAY, renders `<HoloGlobe>`, the HUD (status dot, stage, visitor count, **LIVE/1H/3H/6H/24H** preset buttons, replay progress bar), loads the option-image map. |
| `components/VisitorPanel.tsx` | The click-detail panel: avatar, name, route/seat, survey-answer thumbnails. Rendered inside the scene (anchored to the avatar) by `HoloGlobe`, so it tracks globe rotation. |

### Config
| File | Role |
|---|---|
| `vite.config.ts` | **The local bridge.** `resolveOrg()` shells `sf org display` for a token (only on `command === 'serve'`, never `build`). Defines the `/cometd` and `/sf-query` proxies with `Bearer` injection + cookie rewrite. `SKYWAVE_ORG` env overrides the alias. |
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
2. `fetchReplayTimeline()` runs two SOQL queries via `/sf-query`:
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

## 6. Monday plan — deploying in-org (was BLOCKED on the feature gate)

The bundle is valid metadata and builds, but **`UIBundle` can't deploy** until
the Multi-Framework feature is enabled. It's **double-gated**:

1. **Org preference** `UIBundleSettings.webAppOptIn = true` — **already done**
   (deployed to `si`; see `force-app/main/default/settings/UIBundle.settings-meta.xml`).
2. **Setup-UI feature gate** "React Development with Salesforce Multi-Framework
   (Beta)" — opens with the **Sunday release update**. Until it's on, deploy
   fails with *"Agentforce Vibe for MultiFramework feature gate is disabled"*.

**Monday checklist:**
1. In `si`: Setup → Quick Find "Salesforce Multi-Framework" → **Enable Domain**
   → Enable. Then Setup → My Domain → Routing and Policies → **disable "Require
   first-party use of Salesforce cookies"** (needed by the feature).
   ⚠️ Enabling the app domain is **irreversible** — `si` is demo-critical, so
   confirm before flipping.
2. Build + deploy:
   ```bash
   cd force-app/main/default/uiBundles/SkywaveGlobe && npm install && npm run build && cd -
   sf project deploy start --source-dir force-app/main/default/uiBundles --target-org si
   ```
   (`dist/` is the deploy payload — it's gitignored but NOT forceignored, so it
   must be freshly built before deploy.)
3. Launch from the **App Launcher** (search "SkywaveGlobe").
4. **In-org data path:** the local Vite `/cometd` + `/sf-query` proxies won't
   exist in-org. Two open items to resolve:
   - **Live:** re-test whether a raw `cometd` handshake to same-origin `/cometd`
     inherits the runtime's authenticated session (the question the local proxy
     sidestepped). If it 401s, fall back to extending the Heroku relay with a
     `/ws/monitor` channel (single connection, subscribes to `Demo_Event__e`).
   - **Replay:** swap `replayData.ts` + `surveyImages.ts` from `/sf-query` to the
     UIBundle GraphQL SDK (`@salesforce/sdk-data`). The reducer/player/HUD are
     transport-agnostic — only the fetch calls change.

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
