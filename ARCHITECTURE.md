# Skywave Interactive — Architecture (as built)

> **Scope.** This describes what is *actually built and deployed today*, the
> cross-system data flows, and the moving parts that don't live in git.
> It deliberately does **not** restate what the code already shows (class
> bodies, field lists, the agent topic graph) — read the source for that.
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

---

## 2. Repository map

| Path | What it holds |
|------|---------------|
| `force-app/main/default/` | All Salesforce metadata (the bulk of the system) |
| ├ `aiAuthoringBundles/` | The two `.agent` files — chat + voice agents |
| ├ `classes/` | ~50 Apex classes: agent actions, REST endpoints, controllers, seeders |
| ├ `triggers/` | 4 triggers (Demo_Session, Contact-update PE, phone-digits, VoiceCall resolve) |
| ├ `lwc/` | Chat/voice cards (CLT renderers), demo monitor, survey author, contact card |
| ├ `objects/` | Custom objects + the Platform Events + custom fields on Contact/VoiceCall |
| `heroku/skywave-app/` | Node app: static consumer site + WebSocket state relay |
| `scripts/` | Org-setup, agent deploy/republish, ESD publish (Playwright), seeders |
| `scripts/apex/` | Anonymous-Apex seeders (route network, booking data, observability) |
| `docs/` | Data Cloud mapping, web-connector schema, demo walkthrough |
| `config/`, `orgInit.sh`, `sfdx-project.json` | Scratch/SDO bootstrap |
| `secrets/`, `.secrets/`, `.env` | Credentials — all gitignored (see SECRETS.md) |

---

## 3. Data flows (the parts no single file reveals)

### 3a. Anonymous visitor → known Contact (web)

This is the spine of the demo. A phone is anonymous until the survey, then a
`Contact` is stitched together across several async hops:

```
Consumer site (site.js)
  │  1. loadGeo(): ipinfo.io  ──▶ {city, region, country, lat, lon}   (§3d)
  │  2. survey answers collected locally
  │  3. on survey complete: POST /skywave/contact/upsert
  ▼      (deviceId = Interactions SDK anonymous id)
Skywave_ContactUpsert  (guest-callable Apex REST, Force.com Site)
  │  publishes ──▶ Skywave_Contact_Update__e   (Platform Event)
  ▼
Skywave_Contact_Update_Trigger  (runs in System Mode — guest user has no Contact perms)
  │  • upsert Contact by Session_Id__c = deviceId
  │  • survey_complete → store survey JSON + summary; stamp geo;
  │      derive Home_Airport__c via Skywave_Airports.nearest()  (§3d)
  │  • chat_start    → resolve conversation UUID → SF Conversation Id
  │  • publish Demo_Event__e(survey_complete) so the monitor dots the bubble
  ▼
Contact in CRM  (Session_Id__c, Skywave_Conversation_Id__c, survey, geo, airport)
  ▲
  │  agent reads it at conversation start:
Skywave_ResolveSession  (agent action, keyed on @MessagingSession.ConversationId)
     → returns survey summary + home-airport hint into the agent's reasoning
```

Key non-obvious points (each is a memory entry):
- The **guest user** that runs the REST endpoint can't touch Contact — that's
  *why* the write goes through a Platform Event into a System-Mode trigger.
- `chat_start` sends a snippet-generated UUID; the trigger resolves it to the
  Salesforce `Conversation` Id so the agent's linked variable can match.
- The agent's `@AuraEnabled` calls inside the chat iframe run as the **ESW
  site guest user**, not the messaging end user — see memory
  `reference-ecv2-clt-runtime-context`.

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
                                with continent silhouettes, route polylines,
                                and absolutely-positioned avatar bubbles)
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

### 3c. Chat booking pipeline (agent)

The `Skywave_Airlines_Agent` runs a deterministic booking ladder. The flow and
the actions are in the `.agent` file; the load-bearing facts:
- **Search → select → profile → payment → confirm**, gated by a
  `booking_step` variable. The Booking__c is inserted at the *profile* gate
  (`Skywave_AckProfileForm`), not at confirm — see memory.
- **Connecting flights**: Skywave is a JFK hub. `Skywave_Itinerary` resolves a
  single OR compound flight key (`SW3001+SW4017`); when a direct O&D search is
  empty, `Skywave_FlightSearch` returns one through-JFK connection as a
  compound key that threads unchanged through the card → BookFlight →
  per-leg `Booking_Segment__c` rows.
- **CLT cards**: action outputs render as Lightning Web Components (flight
  results, profile form, payment picker, seat map). The card posts a literal
  chat phrase (e.g. `Book flight <key>`, `Payment completed`) back as the cue
  for the next deterministic step.

### 3d. IP geolocation → home airport (web)

`ipinfo.io` token served from `/api/config` (env var, see SECRETS.md) →
`site.js loadGeo()` resolves `lat/lon/city` → sent on `survey_complete` →
trigger stamps `Contact.Geo_*` and derives `Home_Airport__c` via
`Skywave_Airports.nearest()` (haversine over all 29 network airports) →
`ResolveSession` injects "use <airport> as the default origin" into the survey
summary the booking subagent reads. Coordinates also feed the demo-monitor
globe. Silent no-op if the token is unset.

### 3e. Voice channel

`Skywave_Voice_Agent` is a separate telephony agent (NativeVoice / Service
Cloud Voice). A `VoiceCall` before-insert trigger (`Skywave_VoiceCallResolve`)
matches the caller's phone to a Contact by trailing-9-digits and stamps caller
name fields for a personalized greeting. Escalation is single-hop to a queue
via routing flow. Setup specifics live in the `voice-agent-demo` skill and
memory `skywave-voice-agent`.

### 3f. Observability

Agentforce session traces land in Data Cloud STDM DMOs; `AgentforceOptimize‑
Service` + the `observing-agentforce` skill query them. `Skywave_Observability‑
Seeder` can synthesize sessions for a populated dashboard. Enum vocabulary
matters — see memory `skywave-stdm-synthetic-enum-vocabulary`.

---

## 4. Moving parts that are NOT in git

These bite hardest because nothing in the repo shows they exist or that they
must be redone. Treat this as the operational checklist.

| Thing | Where | When you must touch it |
|-------|-------|------------------------|
| **ESD republish** | Setup UI / `scripts/publishEmbeddedServiceDeployment.mjs` | **After every agent publish/activate**, or chat CLT cards silently degrade to plain text. Demo-critical. (memory) |
| `AGENT_USER` env var | shell, inline before `sf` agent commands | deploy AND publish fail without it (`sfdx-project.json` replaceWithEnv). (memory) |
| Queue routing config | org data | General Voice queue repointed to `skywave_routing` (LeastActive) or transfers drop. Not in metadata. (memory) |
| Agentforce Voice PSTN toggles 6 + 7 | Setup → Agentforce Voice Setup | "Connect Related Voice Calls" + "Record Voice Calls" — empty transcript without them. |
| Heroku Config Vars | `skywave-app` dyno | `IPINFO_TOKEN`, `SF_ESW_*`, JWT key, etc. See `.env.example` + SECRETS.md. |
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
