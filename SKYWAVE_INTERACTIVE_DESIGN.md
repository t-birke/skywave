# Skywave Interactive — Design Document

> Status: **DRAFT v0.2** — for alignment before any implementation work.
> Reference predecessor: *Electra Interactive* (~2 years old).
> This doc lays out the demo, the architecture, the components, the data flow,
> the open questions, and the build sequence. Nothing is built yet.
>
> Changelog v0.1 → v0.2: stage 7 redesigned as a **Claude-Code-driven headless
> extension** (new §6 + new skill in §3); org target locked to **SDO** (not
> scratch); audience size scoped to 20 for v1 with 500-seat scaling notes
> (new §13 "Scale roadmap"); distributable installer punted to parking lot
> (§15) — v1 builds into the author's SDO directly, no installer; **single-
> tenant by design** (new §13a — drop electra's cohort/multi-presenter
> scaffolding when porting); org aliases pinned (new §13b — `si` target,
> `e` reference); **identity stitching** done in Apex via
> `Contact.Session_Id__c` + SOQL-into-DC, no live-path Identity
> Resolution (new §5b); `Audience_Session__c` replaced by
> **`Demo_Session__c`** (one row per presenter run, holds `State__c`
> picklist); **survey/race data are Data-Cloud-only** (no
> `Survey_Response__c` / `Race_Score__c` CRM objects — see §4b);
> survey questions/options *do* live in CRM as `Survey_Question__c` +
> `Survey_Answer_Option__c` with image URLs, edited via a new
> `skywaveSurveyAuthor` LWC.

---

## 1. What is this demo?

**Skywave Interactive** is a live, audience-driven demo that turns a roomful
of phones into participants in a Salesforce + Agentforce + Data Cloud story.
The audience scans a QR code, fills in a short survey, talks to an AI agent
that books them a flight using their preferences, creates a profile, talks
to the agent again to change a seat (which fails the first time, then works
after a live agent extension), then plays a phone-shaking trolley race whose
winner is revealed in Slack via Agentforce + Tableau.

The fictitious airline is **Skywave**. Existing assets in this repo
(`force-app/`, `Skywave_Airlines_Agent`, the airline branding/persona work)
are the foundation; we extend them, do **not** rebuild them.

---

## 2. The user journey (10 stages)

Each stage corresponds to (a) a screen on the audience phone, (b) what's
happening server-side, and (c) what the presenter shows on the projector.

| # | Stage | Phone shows | Server / Org reacts | Projector shows |
|---|-------|-------------|----------------------|------------------|
| 1 | **Scan** | Camera scans QR from projector | Heroku mints `sessionId`, opens WS to phone; Apex publishes `Demo_Event__e (type=session_started)` | Live QR code (LWC) + counter of joined sessions |
| 2 | **Survey** | 4–6 questions about travel preferences (favorite destinations, cabin class, business vs leisure, frequency, etc.) | Each answer POSTs → Apex REST → DLO in Data Cloud + raw row in standard object | Live "answers coming in" tile (counts per option) |
| 3 | **Agent: book a flight** | MIAW chat (or custom chat UI) embedded in site | Agent reads the **Real-Time Data Graph** keyed on `sessionId`, sees declared preferences, suggests a flight; books it via existing `Skywave_BookFlight` Apex action | Agent transcript + the data graph being read (data graph viewer) |
| 4 | **Create profile** | Form: name, email, photo upload | Apex REST creates `Contact` + uploads avatar to ContentVersion; links session → contact via Data Cloud Identity Resolution | Avatar grid lighting up as profiles created |
| 5 | **Reveal C360** | Phone goes idle; presenter takes over | — | Pick one audience profile, open Contact in org → show full C360: declared prefs, browsing events, booking, computed affinities, mileage tier |
| 6 | **Agent: change seat (FAIL)** | Audience asks agent "change my seat to a window seat" | Agent has no `seat_selection` subagent yet — gracefully replies "I can't do that yet" | Agent transcript showing the gap |
| 7 | **Live: extend the agent (Claude-driven, headless)** | Phone idle | A bespoke **Claude skill** (`skywave-extend-agent`) drives the whole loop on stage: inspects the org, edits the `.agent` file, deploys, generates tests, runs tests, redeploys. Audience sees Claude Code working live. | Claude Code terminal on the projector — narrating each step (org check → diff → deploy → test gen → test run → publish) |
| 8 | **Agent: change seat (PASS)** | Audience retries the same prompt | Now succeeds — `Skywave_ChangeSeat` Apex updates `Reservation_Segment__c` | Agent transcript + before/after seat map |
| 9 | **Trolley race** | Full-screen trolley with shake-to-go-faster | Phone reads `devicemotion`, throttles to e.g. 10Hz, POSTs intensity → Apex REST → (a) `Demo_Event__e (type=race_tick)`, (b) Kinesis → Redshift → DC zero-copy | Live race: avatars on trolleys, leaderboard, speed bars |
| 10 | **Slack reveal** | Phone shows winner | Presenter pivots to Slack | Agentforce in Slack: `@Skywave-Analytics who won?` → rich response + embedded Tableau viz of speed-by-tier, prefs-by-winner, etc. |

**Why this order works:** each stage demonstrates a different Salesforce
capability without naming it on the slide — survey = ingestion, stage 3 =
real-time data graph + agent grounding, stage 5 = C360, stage 6–8 =
**headless platform extensibility via Claude Code** (this is the "aha":
the platform extends itself from a terminal while the audience watches),
stage 9 = ingest at scale + Data Cloud + Kinesis zero-copy, stage 10 =
Agentforce-in-Slack + Tableau.

---

## 3. Architecture (components)

```
┌─────────────────────────────────────────────────────────────────────┐
│                          AUDIENCE PHONES                             │
│   Static consumer site (Heroku/Cloudflare) — HTML/JS                 │
│   Mirrors `e2 electra interactive demo` pattern, modernized          │
│   - QR scan → /session/start → opens WS to relay                     │
│   - Survey → POST /api/survey                                        │
│   - Agent chat (MIAW iframe pinned to Skywave_Airlines_Agent)        │
│   - Profile form → POST /api/profile                                 │
│   - Trolley race → devicemotion → POST /api/race-tick                │
│   - Listens to WS for stage transitions (no manual "check state")    │
└──────────────┬──────────────────────────────────────────────────────┘
               │  HTTPS + WSS
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│             HEROKU `skywave-app`  (single Node app)                  │
│   - Serves static consumer site (`/`, `/assets/*`)                   │
│   - WebSocket fan-out at `/ws/:sessionId`                            │
│   - Subscribes to org Pub/Sub API for `Demo_State_Change__e`         │
│   - JWT-bearer auth into `si` (Connected App + cert)                 │
└──────────────┬──────────────────────────────────────────────────────┘
               │  Pub/Sub API (gRPC)
               │
               │
               │  Phones' Apex calls go via existing CORS-anywhere ──┐
               │  proxy (Tom's existing instance, not part of this  │
               │  project). Salesforce Sites CSP/CORS for guest-     │
               │  callable Apex is unreliable; the proxy strips it.  │
               │                                                     │
               ▼                                                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       SALESFORCE ORG                                 │
│   - Skywave_Airlines_Agent (.agent bundle, already built)            │
│   - Contact / Flight__c / Reservation__c / Reservation_Segment__c    │
│   - NEW: Survey_Response__c, Audience_Session__c, Race_Score__c      │
│   - Apex REST endpoints (CommunitiesLanding-style guest-callable)    │
│   - Platform Events: Demo_State_Change__e (control plane),          │
│     Demo_Event__e (data plane: session_started/survey_answer/        │
│     profile_created/race_tick types)                                 │
│   - Monitor LWC (`skywaveDemoMonitor`) on internal Lightning page    │
│     subscribes via empApi — for the projector                        │
│   - QR-code LWC (`skywaveQrCode`) — generates session-bound QR       │
│   - Slack app: Agentforce in Slack + Tableau cards                   │
│   - Data Cloud:                                                      │
│       * Real-Time Data Graph (sessionId → survey answers + events)   │
│       * Identity Resolution (sessionId → Contact post-profile)       │
│       * DLO from Kinesis/Redshift zero-copy for race telemetry       │
└──────────────┬──────────────────────────────────────────────────────┘
               │  zero-copy share                  ▲
               ▼                                   │
┌─────────────────────────────────────────────────────────────────────┐
│                AWS Kinesis → Redshift  (existing pattern)            │
│   Persistence layer for analytics signal store. Keep electra's       │
│   pattern: dual-write race ticks (PE for live, Kinesis for history). │
└─────────────────────────────────────────────────────────────────────┘
```

### Components — what's new vs reused

| Component | Source | Status |
|-----------|--------|--------|
| Skywave consumer site (HTML/JS) | port from `~/dev/e2 electra interactive demo` | **new build, electra as reference** |
| Heroku `skywave-app` (static site + WS relay + JWT into `si`) | new — single Node app | **new build** |
| CORS-anywhere proxy | **reuse Tom's existing instance**, same one electra uses; not deployed by this project | reuse |
| Apex REST endpoints (`/survey`, `/profile`, `/race-tick`, `/session`) | port from `electra-interactive-sfmetadata` (`TB_*_endpoint.cls`) | **port + adapt** |
| Skywave agent + subagents | this repo (`Skywave_Airlines_Agent`) | **exists, extend** (ship a "stripped" baseline without `seat_selection`; stage 7 skill re-adds it live) |
| `skywave-extend-agent` Claude skill | new — drives stage 7 headlessly on the projector | **new build** (see §6) |
| Monitor LWC | port from `tbDemoMonitor`/`tbDemoMonitorAI` | **port + reskin** |
| QR-code LWC | new (small) | **new build** |
| Data Cloud RT data graph | new in this org | **new build** |
| Kinesis → Redshift → DC zero-copy | reuse electra AWS infra (if still alive) | **reuse / re-point** |
| Slack + Agentforce + Tableau | new wiring | **new build** |

---

## 4. Data model

### Existing in this repo (extend, don't replace)
- `Contact` (with `Loyalty_Points__c`, `Member_Number__c`, `Membership_Tier__c`, `Membership_Start_Date__c`)
  - **NEW field**: `Session_Id__c` (Text, External Id, indexed) — populated when the profile is created in stage 4. The per-phone UUID, used as the join key for live SOQL into Data Cloud (see §5b).
  - **NEW field**: `Demo_Session__c` (Lookup → `Demo_Session__c`) — populated by the same profile-creation Apex from the active demo run. Drives "show me the audience from tonight" filter views and audience-size history.
- `Flight__c` (full schedule + pricing)
- `Reservation__c` (Confirmation_Code__c, Status__c, Fare_Class__c, …)
- `Reservation_Segment__c` (used for seat assignment)

### New custom objects (proposed)

- `Demo_Session__c` — **one row per demo run, not per phone.** This is
  the presenter-side anchor for an entire audience event. It lets us:
  - filter Contacts to "the audience currently in the room" (and
    later "the audience from event X") via a lookup on `Contact`
  - keep a long-running history of how often the demo was shown and
    how big each audience was (count of related Contacts per
    `Demo_Session__c`)
  - hold the **current demo state** as a picklist that the WS relay
    and monitor LWC observe, so changing one record advances the
    whole room

  Fields:
  - `Name` (auto-number, e.g. `DEMO-{0000}` — also doubles as a
    human-readable label for the run)
  - `Started__c` (datetime), `Ended__c` (datetime, nullable)
  - `Audience_Size__c` (formula: `COUNT(Contacts__r)` or roll-up summary)
  - `State__c` (picklist: `idle`, `scan`, `survey`, `agent_book`,
    `profile`, `c360`, `agent_seat_fail`, `agent_seat_pass`, `race`,
    `slack`, `done`) — single-row-of-truth for "where is the demo
    right now?"
  - `Notes__c` (long text, optional — venue, audience type, anything
    the presenter wants to log post-demo)

  Behavior:
  - Exactly **one** `Demo_Session__c` is `Active` at a time (singleton
    pattern enforced via a unique `Active__c=true` checkbox + a
    validation rule, or simply by convention).
  - The Apex profile-creation endpoint stamps the active
    `Demo_Session__c` ID onto every new `Contact.Demo_Session__c`.
  - The presenter (or stage-7 skill) advances `State__c`; a trigger
    publishes `Demo_State_Change__e` so phones get pushed via the
    WS relay (§5).
  - **Per-phone session is still a thing** but it's `sessionId` (a
    UUID, lives only in DLO rows + on `Contact.Session_Id__c`); we do
    *not* materialize one record per phone in CRM. The `Demo_Session__c`
    is the presenter's run; `sessionId` is the audience member's seat
    number within it.

- **Survey responses and race scores are NOT Salesforce custom objects.**
  This is high-volume, low-individual-record-value, behavioral data.
  It belongs in Data Cloud, not in CRM. See §4b for what they become
  there.

### Survey content authoring (this part DOES live in Salesforce)

The *answers* live in Data Cloud (above). The *questions and answer
options* — which the presenter wants to edit between runs without
redeploying the consumer site — live in CRM as two new objects:

- `Survey_Question__c`
  - `Name` (auto-number or readable label)
  - `Question_Text__c` (text)
  - `Question_Key__c` (text, unique — what the consumer site uses to
    identify the question, e.g. `fav_destination`)
  - `Order__c` (number, for sequencing on the site)
  - `Active__c` (checkbox — only active questions render)
  - `Question_Type__c` (picklist, optional — `single_choice`,
    `multi_choice`, future-proofing)
- `Survey_Answer_Option__c` (master-detail child of `Survey_Question__c`)
  - `Option_Text__c` (text)
  - `Option_Key__c` (text — what gets sent as the `answer` value)
  - `Image_Url__c` (URL — image rendered next to the option on the
    site)
  - `Order__c` (number)
  - `Active__c` (checkbox)

A small public Apex REST endpoint `/services/apexrest/skywave/survey/schema`
returns the active questions + options as JSON for the consumer site to
render. The site reads this once per session at survey start.

### Survey authoring tool (a real deliverable)

The presenter wants to manage questions + their answers + image URLs
**on a single screen**. Two viable shapes:

- **(a)** A custom **Lightning App Builder page** with a record-flexipage
  for `Survey_Question__c` + a related list of `Survey_Answer_Option__c`
  + inline editing. Cheap; functional; not pretty.
- **(b)** A custom **LWC** (`skywaveSurveyAuthor`) on a Lightning tab
  that lists all active questions and lets you edit them and their
  options inline, including dragging order, uploading/changing images.
  More work but exactly what was asked for.

Recommend **(b)**. We're building this anyway and it's a presenter-side
tool we'll touch frequently. Its shape:
- Left pane: list of `Survey_Question__c` (sortable by `Order__c`)
- Right pane (when one question selected): question text, key, type,
  active toggle; below it a list of `Survey_Answer_Option__c` rows
  (text, key, image preview from URL, order, active, delete) with an
  "add option" row; "save all" button at the bottom
- Use lightning-record-edit-form / lightning-input for fields, plain
  `@wire`/imperative Apex for the list/save, no fancy framework

Phase 2 deliverable. Not Phase 1.

---

## 4b. Data Cloud objects (what `Survey_Response__c` and `Race_Score__c` become)

Both behavioral streams skip CRM and ingest directly into Data Cloud.

### Survey responses

The two transports look similar but do **completely different jobs**.
Don't conflate them.

- **Path A — Salesforce Interactions SDK → Data Cloud** *(the
  persistence + grounding path).* Consumer site fires
  `SalesforceInteractions.sendEvent({ interaction: { name:
  'userProfiling', eventType: 'userProfiling', attributes: {
  question_key, answer_key, session_id, demo_session_id }}})` on every
  answer tap. Same pattern electra uses (`script.js:1075`-ish). This
  is the **only** path that persists data and the **only** path that
  feeds the Real-Time Data Graph the agent grounds on. No custom
  ingestion; the SDK feeds DC's Engagement DLO out-of-the-box.
- **Path B — public Apex REST → Platform Event → monitor LWC**
  *(ephemeral live-display path, no persistence).* Consumer site
  also POSTs to `/services/apexrest/skywave/survey/answer`. The
  Apex handler does exactly one thing: publishes a `Demo_Event__e`
  Platform Event with `type = "survey_answer"` and `payload_json =
  {question_key, answer_key}` (see §4 for the two-channel design).
  The monitor LWC subscribes via empApi
  and updates its "live answer tile" (counts per option) in real
  time. **Nothing is written to Salesforce or to Data Cloud on this
  path.** It exists purely so the projector reflects the room
  immediately, without waiting for the SDK → DC → DLO pipe (which
  has its own latency).

Why both: SDK alone gives correct persistence but isn't reliably
sub-second; Platform Event gives the projector a snappy live tile but
isn't durable. Together they give the projector a smooth show *and*
the agent a populated data graph.

- **DLO** (in Data Cloud, fed by Path A only): the standard
  Engagement / Interactions DLO — exact name TBD when we wire DC, but
  it's whatever DC creates for `userProfiling` events. We don't define
  a custom `survey_response_dlo`.
- **Platform Event** (Path B only): `Demo_Event__e` carrying
  `type="survey_answer"`, see §4.

### Race telemetry
- Apex `/services/apexrest/skywave/race/tick` publishes
  `Demo_Event__e` with `type="race_tick"` (live monitor) **and**
  writes the row to AWS Kinesis
  → Redshift → DC zero-copy DLO `race_telemetry_dlo`. (Already in §3
  and §7. Mentioned here for completeness — same skip-CRM principle.)

### DMOs
- `Audience_Profile_DMO` unifying the survey DLO + the race DLO + (post
  profile) the standard `Contact` DMO via `session_id`.
- The Real-Time Data Graph the agent grounds on (§2 stage 3) is built
  on this DMO.
- Platform Events — **two channels only**, separated by *consumer*, not
  by message type. Mirrors electra's `demo_event__e` /
  `general_message__e` shape. No storage, ephemeral.

  - `Demo_State_Change__e` *(control plane)*
    - Payload: `{new_state, demo_session_id, target_session_id?}`
    - Published by: trigger on `Demo_Session__c.State__c` change
      (plus the stage-7 Claude skill if it wants to advance state)
    - Consumed by: (a) Heroku WS relay → fans out to phones,
      (b) monitor LWC → updates its "current stage" indicator
    - Volume: ~10–20 events per demo run

  - `Demo_Event__e` *(data plane — devices → monitor)*
    - Payload: `{type, session_id, demo_session_id, payload_json}`
    - `type` values used today:
      - `session_started` → `{user_agent}`
      - `survey_answer` → `{question_key, answer_key}`
      - `profile_created` → `{contact_id, display_name, avatar_url}`
      - `race_tick` → `{intensity, t}`
    - Published by: each public Apex REST endpoint, fire-and-forget
    - Consumed by: monitor LWC only (JS switches on `type` to update
      the right tile)
    - Volume: dominated by `race_tick` — ~200 events/sec at 20 phones,
      ~5000/sec at 500 phones (see §13 Scale roadmap)
    - The WS relay does **not** subscribe to this — phones don't care
      what other phones did

  Why two and not five: fewer subscriptions to manage, fewer permissions
  to wire, simpler relay, simpler monitor LWC. New `type` values can be
  added to `Demo_Event__e` without a metadata change.

### Data Cloud (high level — full detail in §4b)
- **DLOs**: standard Interactions/Engagement DLO populated by the
  Salesforce Interactions SDK (survey answers); `race_telemetry_dlo`
  from Kinesis → Redshift zero-copy
- **DMO**: `Audience_Profile_DMO` joining survey + race + Contact
- **Real-Time Data Graph** keyed on `sessionId` for the agent to ground on
- **No Identity Resolution in the live path.** DC IR runs on a schedule
  and the lag is incompatible with a live demo. Linking pre-profile
  anonymous data to a Contact is done by us, in Apex, on profile
  creation — see §5b. IR can still run for *post-demo* analytics
  consistency if useful, but nothing on the demo path waits for it.

---

## 5. State management — killing the manual "check state" button

In electra, the phone polled a state endpoint and the user had to tap
"Continue" once the presenter advanced the stage. In Skywave we replace this
with a **WebSocket pushed from the org**, fronted by the Heroku relay:

1. Phone scans QR → `POST /session/start` returns `{sessionId, wsUrl}`.
2. Phone opens WS to `wss://relay.skywave.../session/{sessionId}`.
3. Relay subscribes to org Pub/Sub API for `Demo_State_Change__e`.
4. Presenter advances the demo by editing the active `Demo_Session__c`
   record's `State__c` picklist. A `Demo_Session__c` trigger publishes
   `Demo_State_Change__e` with `{newStage, demoSessionId, sessionId|"*"}`.
5. Relay fans out the event over WS → phone transitions UI immediately, no
   tap.

`sessionId="*"` = broadcast to everybody (default, since the demo is
single-tenant and we want the whole room moving together). Per-phone
addressing exists for future use (e.g. nudging a stuck phone).

**Why a relay and not just empApi from the phone:** anonymous phones can't
authenticate to org Pub/Sub directly. The relay holds one trusted
connection and fans out anonymously. Same pattern is used for race ticks in
reverse (phones → relay → org).

**Monitor LWC** uses empApi directly (it's inside the org), so it doesn't
need the relay.

---

## 5b. Anonymous-to-known identity stitching (Skywave's IR)

Standard Data Cloud Identity Resolution lag (minutes-to-hours scheduled
runs) is **incompatible with a live demo**. We solve identity stitching
ourselves using the same pattern electra established:

1. **`sessionId` is minted at QR scan** (§5) and travels with every
   anonymous signal: survey answers, agent chat events, browsing
   events, race ticks. All those rows carry `sessionId` as a field
   in their DLO.
2. **At profile creation (stage 4)**, the public Apex REST endpoint
   takes `sessionId` as a parameter and writes it onto
   `Contact.Session_Id__c`.
3. **For live reads** (e.g. the C360 reveal in stage 5, or the agent
   grounding in stage 3 reading prior context after profile
   creation), Apex queries Data Cloud directly via SOQL using
   `sessionId` as the join key. No reliance on DC's scheduled IR
   job — the link is hard-wired the moment the Contact row exists.
4. **For post-demo / analytics** (stage 10's Slack reveal,
   long-term reporting), the standard DC Identity Resolution rule
   can run on its own schedule to produce a tidy unified profile.
   Nothing on the demo path waits for it.

This means stage 5's "full rich C360" reveal is **instant after profile
creation** — no awkward "give it a minute" pause on stage.

**Why:** demo time budget. We cannot stage a demo around a scheduled job.

---

## 6. The Agentforce arc (stages 6–8) — the "aha" moment

The whole demo points at this beat. The point is **not** "watch the
presenter swap a file." The point is: **Salesforce can be extended
end-to-end, headlessly, from a terminal — including writing tests for what
you just built.** We prove that by having Claude Code do it live, on the
projector, while the audience watches.

### Stage-by-stage mechanics

- **Pre-demo state.** A "stripped" version of `Skywave_Airlines_Agent.agent`
  is published in the SDO with the `seat_selection` subagent removed
  from the `start_agent` router and from the `.agent` file. The
  `Skywave_ChangeSeat.cls` Apex action **stays** in the org — that's
  fine, the agent just doesn't know it exists.
- **Stage 6 — fail.** Audience asks "change my seat to a window seat".
  Router's fallback path replies cleanly ("I can't help with seat
  changes yet"). Audience sees the gap.
- **Stage 7 — live extension via Claude Code.** Presenter switches the
  projector to a Claude Code terminal session and types one prompt
  (e.g. `/skywave-extend-agent add seat selection`). The skill drives
  the next ~2 minutes autonomously, narrating as it goes. **The audience
  is watching the platform extend itself.**
- **Stage 8 — pass.** Same audience prompt as stage 6. Agent now routes
  to the new `seat_selection` subagent → calls `Skywave_ChangeSeat` →
  updates `Reservation_Segment__c`. Before/after seat map on the
  projector.

### The `skywave-extend-agent` Claude skill (stage 7 spec)

This is its own deliverable. The skill is a `.skill` file installed in the
demo machine's `~/.claude/skills/` (or shipped in this repo and symlinked).
On invocation, it executes — and narrates — these phases:

1. **Inspect the org.** Run `sf org display`, `sf data query` to confirm
   `Skywave_ChangeSeat` Apex class exists, list current subagents in the
   bot, query `Reservation_Segment__c` to show a current passenger and
   their seat. Audience sees "this is what the org has today."
2. **Diff the agent.** Read the current `.agent` file, identify the
   missing pieces (no `seat_selection` subagent in `start_agent`
   router, no `change_seat` action wiring). Print the planned diff
   to the screen.
3. **Edit the `.agent` file.** Add the `seat_selection` subagent block
   + the router transition + the action wiring to
   `Skywave_ChangeSeat`. Real `Edit` tool calls — visible.
4. **Deploy.** `sf project deploy start --source-dir
   force-app/main/default/aiAuthoringBundles/Skywave_Airlines_Agent`
   then `sf agent publish authoring-bundle` then `sf agent activate`.
   Stream the output to the projector.
5. **Generate tests.** Use the `testing-agentforce` skill (already
   installed) to scaffold an `AiEvaluationDefinition` test spec with
   3–5 cases: "change my seat to window", "I want a seat with extra
   legroom", "swap me to 14F", plus one negative ("I don't have a
   flight in 72 hours" — should refuse).
6. **Run tests.** `sf agent test run --spec ... --wait`. Stream the
   live results. Audience watches green ticks appear.
7. **Confirm.** Brief summary on screen: "agent extended in N seconds,
   X tests passing, ready."

Total stage 7 runtime target: **90–120 seconds**. This is the demo's
peak — every second after that loses the room.

### Skill construction notes

- The skill file declares its own tool whitelist (`Read`, `Edit`,
  `Bash` for `sf` only, plus `Skill` to chain into
  `testing-agentforce`).
- Idempotent: if `seat_selection` is *already* in the file (e.g. the
  presenter forgot to reset between rehearsals), the skill detects this,
  prints "already extended — resetting", checks out the stripped baseline
  via `git`, then proceeds. Means we never freeze on stage.
- Reset between audiences: a sibling skill or `scripts/reset-agent.sh`
  reverts to the stripped baseline.
- The Apex action (`Skywave_ChangeSeat.cls`) is **not** part of what the
  skill writes. It's pre-deployed. Otherwise stage 7 sprawls into Apex
  authoring, and we lose the focus on agent extensibility.

### Why this is better than the v0.1 plan

- Demonstrates **Agentforce + Claude Code + the SDK + headless deploy +
  test generation** in one beat instead of just a file swap.
- Reproducible: zero presenter typing means no live typos.
- Reusable artifact: the `skywave-extend-agent` skill is itself a takeaway
  — partners and SEs can adapt the pattern.

### Risks specific to stage 7

- **Network**. Live `sf` calls hit the SDO over the conference Wi-Fi.
  Mitigation: hotspot fallback; local cache of the deploy zip if
  Salesforce CLI supports it.
- **Agent publish latency**. `sf agent publish authoring-bundle` is not
  fast. Pre-rehearse and time it; if > 60s in this org, consider doing
  the deploy in parallel with the test generation.
- **A bug in the skill itself**. Lock the skill version in git, never
  edit on demo day, run the rehearsal end-to-end the morning of.

---

## 7. The trolley race (stage 9)

- Phone listens to `devicemotion`, computes a windowed energy metric
  (sum of `|accel|² - g²` over a 200ms window), throttles to ~10Hz.
- Each tick → `POST /api/race-tick` (stateless, idempotent on
  `sessionId+t`).
- Apex REST endpoint:
  - publishes `Demo_Event__e (type=race_tick)` (immediate, for live monitor LWC)
  - puts row on Kinesis stream (deferred analytics path)
- Monitor LWC integrates ticks into per-session position, renders
  trolley sprites moving across screen. Same physics electra used for
  cars; reuse `tbLapList` ideas.
- Race ends after fixed duration (e.g. 60s); winner = highest cumulative
  intensity (or first to cross a finish line — TBD).

**Open question (Q2):** speed cap / smoothing — last time, faster phones
with newer accelerometers won by hardware advantage. Worth normalizing per
device or capping per-tick contribution? Not blocking for v1.

---

## 8. Slack reveal (stage 10)

- Skywave-Analytics agent (sibling to the customer-service agent, or same
  agent gated by channel) deployed to Slack via Agentforce-in-Slack.
- Presenter asks `@Skywave-Analytics who won the race?`
- Agent runs an Apex/Flow action that queries `Race_Score__c` joined with
  `Audience_Session__c` and `Contact`, returns a rich Slack message with:
  - Winner avatar + display name
  - Embedded Tableau viz card (top-N speed, intensity by tier, etc.)
- **Open question (Q3):** is the Slack workspace already wired to this
  org, or is that part of orgInit? Probably manual on demo day — flag
  separately.

---

## 9. Build sequence

Recommended phased build. Each phase ends with something demoable.

### Phase 0 — alignment (this doc)
Get sign-off on the architecture and the stage-by-stage flow.

### Phase 1 — foundations & state machine
- New object: `Demo_Session__c` (presenter-side run record with `State__c`
  picklist). **No** `Survey_Response__c` or `Race_Score__c` — those
  live in Data Cloud only (§4b).
- Two new fields on `Contact`: `Session_Id__c` (External Id text) and
  `Demo_Session__c` (lookup)
- Platform Events (two channels): `Demo_State_Change__e` (control plane), `Demo_Event__e` (data plane, with `type` discriminator) — see §4 platform-event subsection
- Trigger on `Demo_Session__c.State__c` change → publishes `Demo_State_Change__e`
- Apex REST stubs: `/session/start`, `/survey/answer`, `/profile`,
  `/race/tick` (`/session/start` and `/profile` resolve and stamp the
  active `Demo_Session__c`; `/survey/answer` and `/race/tick` are
  signed-off stubs that just 200-OK; real bodies in Phases 2 / 6)
- Heroku `skywave-app` (one Node app):
  - Serves static consumer site
  - WS endpoint at `/ws/:sessionId` (session lifecycle + stage broadcasting)
  - JWT-bearer auth into `si` via fresh Connected App `Skywave_Heroku_Relay` (self-signed cert; private key as Heroku config var)
  - Subscribes to Pub/Sub API for `Demo_State_Change__e` only
- Skeleton consumer site (scan + WS connect + "next stage" event listener); points all Apex POSTs through Tom's existing CORS-anywhere instance
- Smoke test: presenter changes `Demo_Session__c.State__c` from `idle`
  to `survey` in the org UI, all phones flip
- **Demoable:** a phone scans the QR, gets pushed to a placeholder screen.

### Phase 1.5 — monitor stage advancer (picked up at start of Phase 2)
- Add a stage-button strip to `skywaveDemoMonitor` LWC: one button per
  `Demo_Session__c.State__c` value, current value highlighted, click
  fires Apex to update `State__c` on the active row. The trigger then
  publishes `Demo_State_Change__e` and both monitor and phones see
  the change via their existing subscriptions.
- New Apex method `Skywave_DemoMonitorController.advanceState(String newState)`.
- Removes the need for the presenter to leave the monitor mid-demo.

### Phase 2 — survey content + dual-path delivery + Data Cloud grounding
- New CRM objects: `Survey_Question__c` + master-detail `Survey_Answer_Option__c`
  (with `Image_Url__c`); seed with 4–6 questions
- Authoring tool: `skywaveSurveyAuthor` LWC on a Lightning tab —
  question list + inline edit of options + image URL preview + reorder
  (§4 "Survey authoring tool")
- Public Apex `/survey/schema` returns active questions + options as JSON
- Consumer site survey UI: fetches schema, renders questions with images,
  on tap fires **both paths**:
  - **Path A** — `SalesforceInteractions.sendEvent({...userProfiling})`
    (persistence + DC grounding, per electra `script.js:1075`)
  - **Path B** — POST to `/survey/answer` (live monitor display only)
- Apex `/survey/answer` publishes `Demo_Event__e` with `type="survey_answer"` (no DML, no DC ingestion in this path)
- Monitor LWC subscribes to `Demo_Event__e` via empApi and renders
  the live "answers coming in" tile per question (filters on
  `type="survey_answer"`)
- DC wiring: confirm Interactions SDK `userProfiling` events are
  flowing into the Engagement DLO; build `Audience_Profile_DMO`
  joining it with Contact via `session_id`; build the Real-Time
  Data Graph the agent grounds on
- Validate: query DG as the agent would, see survey answers populated
- **Demoable:** phone takes the survey (with images); the projector's
  monitor tile updates live as each answer is tapped (Path B); presenter
  pulls up the data graph and shows the same answers persisted there
  (Path A); presenter edits a question in `skywaveSurveyAuthor` and
  the change shows up on the next phone to start.

### Phase 3 — agent grounding via session
- Modify `Skywave_Airlines_Agent` to accept a `sessionId` linked variable
  (parallel to `ContactId`)
- Pre-flight resolver action that hydrates session context from the data
  graph (favorite destinations, cabin preference)
- Tweak flight-search prompt to weight on those preferences
- **Demoable:** phone takes survey → opens chat → agent already knows
  the user's preferences without being told.

### Phase 4 — profile + C360 reveal
- Profile form, photo upload, Contact creation
- Add `Contact.Session_Id__c` (Text, External Id) — populated by the
  profile-creation Apex with the `sessionId` from the request payload
- Apex helper that, given a `sessionId`, runs SOQL into Data Cloud DLOs
  to pull declared prefs, browsing events, prior agent turns — for the
  C360 reveal screen and for anything else that needs to stitch
  anonymous → known on the live path (see §5b)
- Wire avatar URL into monitor LWC's grid
- **Demoable:** all prior phone steps + presenter pulls one Contact and
  shows full C360 instantly (no IR-job wait).

### Phase 5 — agentforce extensibility via Claude skill (stages 6–8)
- Confirm `Skywave_ChangeSeat` works end-to-end against `Reservation_Segment__c` from a current-state agent invocation
- Author the **stripped baseline** of `Skywave_Airlines_Agent.agent` (no `seat_selection`) and tag it in git
- Author the **`skywave-extend-agent` Claude skill** per §6:
  - Phase 1: inspect (`sf org display`, queries)
  - Phase 2: diff
  - Phase 3: `Edit` the `.agent` file
  - Phase 4: deploy + publish + activate
  - Phase 5: chain into `testing-agentforce` skill to scaffold test spec
  - Phase 6: `sf agent test run`
  - Phase 7: summary
- Author `scripts/reset-agent.sh` for between-audience resets
- Idempotency check (already-extended detection + git reset)
- Rehearse 5×, time it, fix anything > 120s
- **Demoable:** the whole "fail → Claude on the projector → succeed" flow under 2 minutes.

### Phase 6 — trolley race
- `devicemotion` capture on phone, throttling, transmission
- Race tick endpoint, dual-write (PE + Kinesis)
- Monitor LWC race renderer
- Confirm Kinesis→Redshift→DC zero-copy still flows
- **Demoable:** 5–10 phones racing on the projector.

### Phase 7 — Slack & Tableau
- Skywave-Analytics agent deploy to Slack
- Tableau viz embeds for race outcome
- **Demoable:** end-to-end run-through.

### Phase 8 — polish & rehearsal
- QR rotation if reusing the same scratch org across audiences
- Failure-mode drills (one phone drops, one survey row malformed, agent
  publish fails mid-demo, etc.)
- Run-of-show script for presenter
- Static fallback for any stage that breaks live

---

## 10. Open questions (collected)

| # | Question | Default if you don't pick |
|---|----------|----------------------------|
| Q1 | Stage 7 mechanics | **DECIDED 2026-05-15:** Claude skill `skywave-extend-agent` driving inspect → edit → deploy → generate tests → run tests. See §6. |
| Q2 | Race-shake normalization across device types? | None for v1 — accept hardware variance |
| Q3 | Is Slack already wired to this org or is it pre-demo manual? | Pre-demo manual; document only |
| Q4 | Org type | **DECIDED 2026-05-15:** SDO (Professional Edition base) — preinstalled assets, not a fresh scratch. `orgInit.sh` needs to be revisited; some of its scratch-only assumptions won't hold against an SDO. |
| Q5 | Identity Resolution timing | **DECIDED 2026-05-15:** No IR in the live path. `sessionId` is the join key throughout. Profile-creation Apex writes `sessionId` onto `Contact.Session_Id__c`; live reads SOQL-into-DC keyed on `sessionId`; DC IR runs only for post-demo analytics. See §5b. |
| Q6 | Audience size | **DECIDED 2026-05-15:** v1 = 20 phones. Scale roadmap target = 500 phones (parity with electra). See §13 — Agentforce invocation rate limits are the suspected bottleneck. |
| Q7 | Brand assets / avatar set for unprofiled sessions — reuse electra's, or use the nanobanana-output we already have? | Use Skywave nanobanana avatars (already in repo) |
| Q8 | Multi-language? Existing agent is `en_US` only. | English-only for v1 |

---

## 11. What this doc deliberately does NOT cover (yet)

- Exact Apex endpoint signatures and payloads — define in Phase 1.
- Exact Data Cloud DLO/DMO field maps — define in Phase 2.
- The QR-rotation/cleanup story for back-to-back demos — Phase 8.
- Tableau dashboard specifics — Phase 7.
- Precise WebSocket message schema — Phase 1.
- Exact `skywave-extend-agent` skill prompt + tool whitelist — define alongside Phase 5.
- The `setup-sdo.sh` adapter for SDO instead of scratch — Phase 1.

---

## 12. Sign-off checklist (before any code is written)

- [ ] User journey (section 2) matches your mental model
- [ ] Architecture (section 3) makes sense, especially LWC monitor + Heroku relay split
- [ ] Data model (section 4) is the right shape (or call out additions)
- [ ] State-machine via WS (section 5) is the right way to kill the manual button
- [ ] Stage 6–8 mechanics (section 6) — Claude-skill-driven flow (NEW v0.2)
- [ ] Scale roadmap (section 13) — 20 now, 500 later
- [ ] Build sequence (section 9) phasing is acceptable
- [ ] Open questions (section 10) — answer the ones you care about now,
      defer the rest

---

## 13. Scale roadmap — 20 → 500 phones

v1 ships for **~20 simultaneous audience members**. Target for "parity
with electra" is **500**. Electra hits 500 today because nothing in its
hot path is agentic; Skywave's hot path *is* agentic, so we need to find
the bottleneck early and design escape hatches.

### Likely bottlenecks (in order of suspicion)

1. **Agentforce per-org invocation rate limits.** Stage 3 (booking) and
   stages 6/8 (seat change) are agent-mediated. If 500 people hit the
   chat in the same minute, we may exceed per-tenant LLM call limits.
   This is the **#1 risk to scaling** and the reason 500 isn't free.
   Mitigations to validate:
   - **Stagger waves**: presenter advances stages in batches of ~50
     phones via the WS relay. The server-pushed state machine in §5
     already supports this — just send `Demo_State_Change__e` to subsets
     of `sessionId`s.
   - **Pre-warm conversations**: open the MIAW session as soon as the
     phone reaches the survey screen, not when they tap "talk to
     agent." Spreads load.
   - **Cap concurrency at the relay**: if N agent sessions are in
     flight, queue new starts. Phone shows a "connecting…" UI.
   - **Headroom check with Salesforce**: confirm published rate limits
     for the org's edition — SDO Professional may be more restrictive
     than scratch with debug entitlements.
2. **Race tick endpoint throughput.** 500 phones × ~10Hz = 5000 req/s
   at peak. Apex REST + Platform Events can be made to handle this
   but it's not free:
   - Server-side throttle to ~2Hz per session before publishing PE.
   - Batch ticks at the relay (the relay can pre-aggregate before
     POSTing to Apex, since v1 already requires the relay).
   - Kinesis side scales fine — no concern.
3. **WebSocket fan-out.** 500 idle WS connections is trivial for a
   single dyno. 500 concurrent stage transitions is also fine. Not
   expected to be a bottleneck.
4. **DLO ingestion lag.** Data Cloud ingestion can lag minutes
   under load. For the live stage 3 grounding (agent reads survey
   answers), DC ingest must be fast enough. If it isn't:
   - Fallback path: agent reads from `Survey_Response__c` directly
     for stage 3 (skip the data graph), and Data Cloud is only
     used for the *post-demo* analytics story in stage 10.
5. **MIAW concurrent sessions.** Confirm the org's messaging session
   ceiling — typically high but worth a check.

### What goes on the v2 roadmap (not v1)

- Wave/cohort scheduling UI in the monitor LWC.
- Server-side throttling on race ticks.
- Pre-warmed agent session pool.
- Synthetic load tests (e.g. headless puppeteer fleet) to validate
  capacity numbers *before* a 500-person event.
- Documentation of the actual limits encountered, so future
  Skywave-style demos know the edges.

**Action for v1**: while building stage 3 and the race endpoint,
**measure** per-request latency under a small synthetic load (say 50
concurrent fake phones) so we have real numbers to extrapolate from
before committing to a 500-seat event.

---

## 13a. Single-tenant by design (vs. electra)

Electra Interactive is multi-tenant: cohorts, presenter scoping, demo
settings, and monitor partitioning exist so two presenters can run two
demos against the same org at the same time without colliding. **Skywave
Interactive does not need any of that.** There is exactly one presenter
running one demo at a time against `si`. Concretely:

- **No cohort model.** No "demo cohort" object, no presenter-id field on
  events, no monitor filter dropdown. The monitor LWC simply shows
  *everything currently active*.
- **No multi-presenter contention guards.** Stage transitions
  (`Demo_State_Change__e`) broadcast to all sessions on `si`; that's
  correct, not a bug.
- **Soft-reset between back-to-back audiences** (§14) replaces what
  electra solves with cohort isolation — wipe the audience tables,
  re-strip the agent, start fresh.
- **Demo Settings — maybe.** Electra's `tbDemoSettingsBare` LWC is
  worth keeping the spirit of (one place to flip presenter-side knobs:
  race duration, base agent variant, debug overlays). Port the *idea*,
  drop the multi-tenant scaffolding around it. Decide in Phase 1 once
  we know what knobs we actually need.

**How to apply:** when porting electra components, strip out
cohort/tenant fields and any "scope to my session" filters before
deploying. If you find yourself adding a "presenter" or "cohort"
column to a new object — stop, you don't need it.

---

## 13b. Org aliases — `si` (target) and `e` (reference)

Two `sf` aliases matter for this project:

| Alias | Role | Org | Notes |
|-------|------|-----|-------|
| `si`  | **Target org for Skywave Interactive** | `trailsignup-fb3f5426f87c5d.my.salesforce.com` (SDO, PE-based) | Default org for this project. All `sf` commands run against `si` unless explicitly overridden. |
| `e`   | **Reference org — Electra Interactive** | `electra-interactive.my.salesforce.com` (`tbirke@dc.auto`) | Read-only inspiration. When porting an electra component (LWC, Apex endpoint, Platform Event, …), use `--target-org e` to retrieve and inspect the live working version, then adapt for `si`. |

**How to apply:**
- New deploys/queries against the SDO: omit `--target-org` (default is `si`) or pass `--target-org si` to be explicit.
- Looking up "how did electra solve X?": prefer querying `e` over reading the
  `~/dev/electra-interactive-sfmetadata` snapshot — the live org is more
  current. Use the snapshot only if you need the file form (e.g. for
  diffing or porting).
- Never deploy *to* `e`. It's reference-only.

---

## 14. SDO-specific considerations (for **our** demo machine, v1)

The org target is a **Salesforce Demo Org (SDO)** based on Professional
Edition with assets preinstalled — not a Developer/scratch org. For v1
we are building **into your SDO**, by hand-driven `sf project deploy`
calls as we go. We are explicitly **not** trying to make this
installable for other people in v1 (see §15 Parking Lot).

What we still need to nail down for our own SDO during Phase 1:

- **Edition limits sanity check**: PE has stricter limits than DE on
  some objects, custom fields, API calls. Confirm before we lean on:
  - Custom object count headroom (we add ~3 new objects).
  - Platform Event allocation (we publish a lot during the race).
  - Data Cloud entitlement on the SDO — is the RT data graph + DLO
    ingestion in scope of this org's license?
- **Soft-reset between audiences**: scratch was disposable; SDO is not.
  We need a small Apex/script that:
  - Deletes prior `Audience_Session__c`, `Survey_Response__c`,
    `Race_Score__c` rows.
  - Reverts the `.agent` to the stripped baseline (via
    `scripts/reset-agent.sh`).
  - Optionally deletes test Contacts created during the demo (or
    keeps them if we want a growing C360 demo over time).
- **Auth on the demo machine**: confirm `sf` is logged in with an alias
  the stage-7 skill can rely on, and that the auth lives on disk so
  stage 7 doesn't trigger an OAuth web flow on stage.
- **Heroku app auth into `si`**: fresh Connected App
  `Skywave_Heroku_Relay` on `si`, JWT-bearer flow, self-signed cert.
  Public cert deployed via the Connected App metadata; private key
  sits as a Heroku config var on `skywave-app`. Cert lives in
  `.secrets/` locally (already gitignored by repo convention) and
  is NOT committed.
- **CORS proxy reuse**: phones POST to Apex through Tom's existing
  CORS-anywhere instance at
  `https://abc-proxy-2552551e6d2c.herokuapp.com/` (same one electra
  uses, defined as `proxy` in electra `script.js:4`). Goes into the
  consumer site as `CORS_PROXY_URL`. Once `skywave-app` is deployed,
  confirm whether the proxy's allowed-origin list needs the new
  Heroku URL added.

---

## 15. Parking lot (deferred decisions / future work)

Things we explicitly are **not** designing now. Each one waits until the
demo itself is stable end-to-end.

- **Distributable installer for other SDOs.** Eventual goal: someone
  receives a fresh SDO and can install Skywave Interactive into it.
  Open question: is that best as a shell script (like the current
  `orgInit.sh`) or as a Claude skill that walks the user through the
  setup interactively? Probably a skill, given the number of external
  dependencies (Heroku app, AWS Kinesis/Redshift, Slack workspace,
  Tableau, Data Cloud activation, MIAW, …) — too many moving parts for
  a one-shot script. Decide once the demo is locked.
- **Wave/cohort scheduling UI** in the monitor LWC (for 500-phone
  scale, see §13).
- **Server-side throttling** on race ticks (see §13).
- **Pre-warmed agent session pool** (see §13).
- **Synthetic load tests** to validate scale before a 500-person event
  (see §13).
- **QR rotation strategy** for back-to-back audiences in the same org
  (Phase 8).
- **Multi-language agent** (current `en_US` only, see Q8).
- **Per-device shake normalization** for the trolley race (see Q2).
- **Enable GitHub Push Protection** (Settings → Code security → Secret
  scanning) **before flipping the repo to public.** While the repo is
  private and clean, `.gitignore` + the `SECRETS.md` discipline are
  enough. See `SECRETS.md` for the full secrets policy.
- **Optional local pre-commit hook** to scan staged files for common
  key markers (`-----BEGIN`, `AKIA*`, etc.) — adds an offline guard
  layer; not needed yet.

---

## 16. Backlog (lighter than parking lot — UX polish, P2 features)

The parking lot above is for "deferred until demo is stable." This
backlog is for "we shipped v1 of X but want a slicker v2 someday."
Add items as they come up. Don't pre-prioritize.

- **`skywaveSurveyAuthor` LWC drag-and-drop reorder.** v1 ships with
  up/down arrow buttons on each question and option. Drag-and-drop
  is slicker on desktop but brittler on touch and adds ~50 LOC; not
  worth it until the authoring tool gets daily use.
