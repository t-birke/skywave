# Skywave Airlines — Agentforce Observability synthetic dataset

A full, referentially-intact synthetic dataset for the
`SDO_Agentforce_Observability` QBrix, branded for **Skywave Airlines**
(airline industry). 400 sessions that render in Agentforce Studio →
Analytics and Optimization → Insights, telling a deliberate story: the
agent handles most intents well, but **seat-change requests consistently
fail** (very low quality) — visible in Quality-by-Intent, while there is
deliberately **no "seat change" subagent** (the failure surfaces by intent,
not topic).

## What's in the bundle

`data/` — one CSV per object, prefixed with load order (01 → 11):

| # | Object | Rows |
|---|--------|------|
| 01 | `SDO_Analytics_AIAgentTagDefinition_v2__c` | 2 |
| 02 | `SDO_Analytics_AIAgentTagDefinitionAss_v2__c` | 2 |
| 03 | `SDO_Analytics_AIAgentTag_v2__c` | 21 |
| 04 | `SDO_Analytics_AIAgentSession_v2__c` | 400 |
| 05 | `SDO_Analytics_AIAgentSessionParticipa_v2__c` | 800 |
| 06 | `SDO_Analytics_AiAgentInteraction_v2__c` | 1,644 |
| 07 | `SDO_Analytics_AIAgentInteractionMessa_v2__c` | 2,488 |
| 08 | `SDO_Analytics_AIAgentInteractionStep_v2__c` | 1,866 |
| 09 | `SDO_Analytics_AIAgentMoment_v2__c` | 622 |
| 10 | `SDO_Analytics_AIAgentMomentInteractio_v2__c` | 1,244 |
| 11 | `SDO_Analytics_AIAgentTagAssociation_v2__c` | 1,244 |

Every row carries `Demo_Identifier__c = 'SKYWAVE_PHASE_4_5'` so it's easy to
target (or wipe) without touching other data.

## Referential integrity — how it's preserved

**All cross-object links are text-UUID foreign keys, not Salesforce record
Ids.** Each row has an `External_ID__c` (a UUID), and children reference
parents by that UUID (`AI_Agent_Session__c`, `AI_Agent_Interaction__c`,
`AI_Agent_Moment_Id__c`, `AI_Agent_Tag_Id__c`,
`AI_Agent_Tag_Definition_Association_Id__c`, etc.). Because the keys are
self-contained UUIDs, the graph resolves identically in any org — no Id
remapping needed.

Validated: **0 dangling references** across all 13 FK relationships within
these CSVs. Load in the numbered order and integrity holds.

> Do NOT use `sf data import tree` — these are not real lookup
> relationships, so tree import won't wire them. Load the CSVs per object
> (Bulk API / Data Loader) in the 01→11 order.

## ⚠️ Two org-specific fields to remap (only these)

Everything is portable EXCEPT two fields that hold real record Ids from the
source org. Before/after import, replace them with values valid in the
target org:

1. **`Participant__c`** on `05_...SessionParticipa` (800 rows):
   - AGENT role → a `GenAiPlannerDefinition` Id (source: `16jg…`). Set to
     the target org's planner Id for the agent (query
     `SELECT Id FROM GenAiPlannerDefinition WHERE DeveloperName LIKE '<Agent>_v%'`).
   - USER role → a `MessagingEndUser` Id (source: `0PAg…`). Set to real
     `MessagingEndUser` Ids in the target org (rotate across several).
   - `Participant_Object__c` (`GenAiPlannerDefinition` / `MessagingEndUser`)
     is correct as-is.
2. **`Session_Owner__c`** on `06_...Interaction` (the `0PAg…` MessagingEndUser
   Id) — same remap as the USER participant, or blank it.

These two fields drive the **Analytics** identity/aggregation. If left as
the source Ids they simply won't resolve in the target org (sessions may not
count in Analytics) — the Optimization/Insights story still renders.

## Hard requirements for the data to RENDER (learned the hard way)

These are baked into the dataset already, but worth stating so they survive
any regeneration:

1. **`ssot__Bot__dlm` join** — Optimization Insights + Sessions & Intents
   join sessions to `ssot__Bot__dlm` on `DeveloperName` = the agent api
   name. That DMO is fed from real `BotDefinition` records via
   `BotDefinition_Home`, so a **deployed + activated agent named
   `Skywave_Airlines_Agent`** must exist (or rename throughout to the
   target agent). No Bot row → no Optimization/Sessions rendering.
2. **`Participant__c` populated** (see remap above) — else Analytics drops
   the session.
3. **Literal `NOT_SET` sentinel** on optional session fields
   (`Individual__c`, `Session_Owner_Object__c`, `Variable__c`,
   `Previous_Session_Id__c`) — empty/null blocks rendering. (Already set.)
4. **`Quality_Score` (1-5) tag associated per moment** — drives all quality
   charts; the analyzer does NOT score synthetic data, so it's pre-baked.
5. STDM enums already correct: message `Input`/`Output`, content
   `text/plain`, interaction `TURN` (+ one `SESSION_END` per session), step
   `TOPIC_STEP`/`LLM_STEP`/`ACTION_STEP`.

## Import sequence

```
1. Load data/01 … data/11 in order (Bulk API / Data Loader), upsert on
   External_ID__c (or insert into empty objects).
2. Remap the two org-specific fields above.
3. Ensure an agent named Skywave_Airlines_Agent is deployed + activated;
   refresh BotDefinition_Home.
4. Full Refresh each SDO_Analytics_*_Home data stream (Setup → Data Cloud →
   Data Streams). SalesforceDotCom streams refresh only from a browser /
   Dev Console, not CLI.
5. Agentforce Studio → Optimization → Insights, filter Agent =
   Skywave Airlines Agent, Date Range = 90 days.
```

## The story (what the dashboard shows)

- 5 subagents: `flight_management`, `mileage_account`, `case_management`,
  `name_change`, `off_topic`. **No seat-change subagent.**
- Quality-by-Intent: seat intents at the bottom (Seat Assignment ~1.4,
  Seat Upgrade ~1.5, Seat Change ~1.5 = Very Low); other intents High
  (4.4–4.7).
- Quality-by-Subagent: `flight_management` reads Medium (it carries the
  seat failures) → drill into intents to find the culprit.
- Realistic timing: agent latency 2–4s; user think-time between turns
  15–300s (right-skewed).

Generated by `Skywave_ObservabilitySeeder` (Apex) in the
is_interactive_skywave project. Full re-theming methodology is in the
`agentforce-observability-data` skill → `references/rebrand-seeder-playbook.md`.
