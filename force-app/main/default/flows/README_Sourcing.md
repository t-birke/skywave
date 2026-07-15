# Skywave Sourcing — Mock Flow Orchestration

A **mock** Flow Orchestration (`processType = Orchestrator`) that showcases a complex,
generally-applicable strategic-purchasing / sourcing process: sourcing a category of
goods or services for next season across the airline's whole route network. Every step
calls a **stub subflow** so the orchestration runs end-to-end without any external
procurement systems.

It exists to demonstrate the moving parts of Flow Orchestrator — multiple stages, data
threaded stage-to-stage, a **decision that forks the path**, and an entry-condition gate —
**and in particular the two AI hand-offs**:

- a subprocess that **hands over to a prompt template** (RFP drafting), and
- a subprocess that **hands over to an Agentforce agent** (supplier negotiation).

**The decision:** after bids are scored, a top-level `<decisions>` element (`Bid_Quality_Gate`)
checks the leading bid's score. If it clears the award threshold (≥ 75) the pipeline proceeds
to negotiate → award → contract; otherwise it routes to a terminal **"Sourcing Cancelled"**
stage that records why and recommends re-scoping the RFP.

> These are mock/demo flows. They are deployed **Active** on `si` and driven entirely by
> **stub subflows** that return deterministic placeholder data rather than touching real
> procurement systems. Nothing is tied to any specific spend category — supply the
> category in the RFP/spec content when you adapt it.

## How it launches

The orchestration is **record-triggered** on the mock `Sourcing_Request__c` object
(`recordTriggerType = Create`, `triggerType = RecordAfterSave`). Creating a
`Sourcing_Request__c` record kicks off the pipeline, and `$Record` becomes the context
record threaded into every step.

> **Human steps are simulated.** The two review points (release the RFP; approve the award)
> ship as background "approval-sim" stubs so the orchestration runs green end-to-end without
> a work-item assignee. The real `stepInteractive` screen flows are kept in the repo — see
> [Simulated human steps](#simulated-human-steps--interactive-step-blocker) below.

```bash
# launch a run
sf data create record -s Sourcing_Request__c -o si \
  -v "Season__c='Winter 2026/27' Category__c='General Goods & Services' Status__c='New'"
```

The `Season__c` field feeds every step; `Category__c` keeps the request generic (free text).

## The pipeline

| Stage | Step | Kind | Subflow | Notes |
|-------|------|------|---------|-------|
| 1. Plan & Draft | Build Demand Forecast | background | `Skywave_Sourcing_Demand_Forecast` | Rolls the season's operating schedule into estimated demand units per category/route. |
| 1. Plan & Draft | Draft RFP | background | `Skywave_Sourcing_Draft_RFP` | **→ hands to prompt template** `Skywave_Sourcing_RFP_Draft` (`generatePromptResponse`) to write the RFP narrative. |
| 2. Issue RFP | Review & Release RFP *(simulated)* | background | `Skywave_Sourcing_Issue_RFP_Sim` | Stands in for the Category Manager releasing the RFP → `out_ReleaseDecision='Released'`. |
| 3. Evaluate | Score Supplier Bids | background | `Skywave_Sourcing_Evaluate_Bids` | Weighted matrix (price / quality / sustainability / service level); emits `out_LeadingScore`. |
| — | **`Bid_Quality_Gate` decision** | *decision* | — | `out_LeadingScore ≥ 75` → Stage 4; else → Stage X (cancel). |
| 4. Negotiate | Agent Negotiation | background | `Skywave_Sourcing_Negotiate_Supplier` | **→ hands to Agentforce agent** `Skywave_Airlines_Agent` (`generateAiAgentResponse`) to negotiate pricing & rebate tiers. |
| 5. Award & Contract | Procurement Director Approval *(simulated)* | background | `Skywave_Sourcing_Award_Approval_Sim` | Stands in for the Director approving the award → `out_ApprovalDecision='Approved'`. |
| 5. Award & Contract | Generate Contract & POs | background | `Skywave_Sourcing_Finalize_Contract` | **Entry condition:** only runs when the approval decision = `Approved`. |
| X. Sourcing Cancelled | Record Cancellation & Re-scope Advice | background | `Skywave_Sourcing_Cancel` | Terminal stage reached only via the decision's default (no qualified bid). |

Data flows through the orchestration via each step's outputs, referenced downstream as
`Step_<Name>.Outputs.<var>` (e.g. the leading supplier from the evaluation step feeds
both the negotiation and the award steps).

Both branches are verified end-to-end on `si`: the demo default (mock leading score 87.4)
completes award → contract; forcing the score below 75 completes via the cancellation stage
with negotiate/award/contract correctly skipped.

## Simulated human steps & interactive-step blocker

The two review points are modelled as **background** stubs rather than real `stepInteractive`
work items:

- `Skywave_Sourcing_Issue_RFP_Sim` → returns `out_ReleaseDecision='Released'`
- `Skywave_Sourcing_Award_Approval_Sim` → returns `out_ApprovalDecision='Approved'`
  (which satisfies the finalize step's entry-condition gate).

**Why:** on this SDO a `stepInteractive` step fails at *runtime* with
`FLOW_ELEMENT_ERROR|Invalid Resource reference|FlowOrchestratedStage` the instant the stage
is entered — for **every** assignee reference tried (`$User.Id`, `$Record.OwnerId`, a formula
returning an active System Admin's Id); a literal `<stringValue>` user Id is even rejected at
*deploy* for a confirmed-active admin. Isolation confirmed it is assignee-specific: swapping
the identical step to `stepBackground` (no assignee) runs clean to completion, so the
decision / async prompt / data refs / rendering metadata are all fine. Root cause unconfirmed
(record-triggered orchestrations run as the **Automated Process** user; the org's only working
interactive orchestrations are managed packages, so there's no local known-good custom shape
to copy).

The **real interactive screen flows are retained** in the repo —
`Skywave_Sourcing_Issue_RFP` and `Skywave_Sourcing_Award_Approval` — to swap back in once the
assignee encoding is sorted (next lead: build one interactive step in Flow Builder on `si`,
retrieve it, and diff the assignee XML).

## The two hand-off mechanisms (how Flow "hands over")

Both are ordinary Flow **action calls** placed inside a stub subflow, which the
orchestration then invokes as a stage step:

```xml
<!-- Hand over to a PROMPT TEMPLATE (in Skywave_Sourcing_Draft_RFP) -->
<actionCalls>
    <actionType>generatePromptResponse</actionType>
    <actionName>Skywave_Sourcing_RFP_Draft</actionName>
    <storeOutputAutomatically>true</storeOutputAutomatically>
    <inputParameters><name>Input:Season</name> ... </inputParameters>
    <!-- output: <action>.promptResponse -->
</actionCalls>

<!-- Hand over to an AGENTFORCE AGENT (in Skywave_Sourcing_Negotiate_Supplier) -->
<actionCalls>
    <actionType>generateAiAgentResponse</actionType>
    <actionName>Skywave_Airlines_Agent</actionName>
    <storeOutputAutomatically>true</storeOutputAutomatically>
    <inputParameters><name>userMessage</name> ... </inputParameters>
    <!-- output: <action>.agentResponse -->
</actionCalls>
```

Each subflow wraps its AI call with a fault path that falls back to mock text, so the
orchestration still completes if the agent/template isn't available in the org.

## Components

- **Orchestration:** `Skywave_Sourcing`
- **Stub subflows (in the active pipeline):** `Skywave_Sourcing_Demand_Forecast`,
  `Skywave_Sourcing_Draft_RFP`, `Skywave_Sourcing_Issue_RFP_Sim`,
  `Skywave_Sourcing_Evaluate_Bids`, `Skywave_Sourcing_Negotiate_Supplier`,
  `Skywave_Sourcing_Award_Approval_Sim`, `Skywave_Sourcing_Finalize_Contract`,
  `Skywave_Sourcing_Cancel`
- **Retained (not wired in — the real interactive screen flows):**
  `Skywave_Sourcing_Issue_RFP`, `Skywave_Sourcing_Award_Approval`
- **Prompt template:** `Skywave_Sourcing_RFP_Draft` (`force-app/main/default/genAiPromptTemplates/`).
  Must be **Published** with a top-level `<activeVersionIdentifier>` pointing at the active
  version — a Draft template exposes *no* invocable action, which leaves the Draft-RFP
  subflow `InvalidDraft` ("invalid reference to `…promptResponse`").
- **Trigger object:** `Sourcing_Request__c` (mock; AutoNumber `SRC-{0000}`) with fields
  `Season__c`, `Category__c`, `Status__c`. Full access granted on the
  `Skywave_Demo_Admin` permission set.

The agent hand-off reuses the existing `Skywave_Airlines_Agent` already in the org.

## Deploy

Deployed and **activated** on `si`. Deploy order matters: the object + prompt template
must land before the subflows (which reference the template), and the subflows before the
orchestration (which references them).

```bash
# 1. trigger object + fields, and the permission-set grants
sf project deploy start \
  --source-dir force-app/main/default/objects/Sourcing_Request__c \
  --source-dir force-app/main/default/permissionsets/Skywave_Demo_Admin.permissionset-meta.xml \
  -o si

# 2. prompt template (Published) — registers the generatePromptResponse action
sf project deploy start -m GenAiPromptTemplate:Skywave_Sourcing_RFP_Draft -o si

# 3. the stub subflows in the active pipeline (Active)
sf project deploy start \
  -m Flow:Skywave_Sourcing_Demand_Forecast \
  -m Flow:Skywave_Sourcing_Draft_RFP \
  -m Flow:Skywave_Sourcing_Issue_RFP_Sim \
  -m Flow:Skywave_Sourcing_Evaluate_Bids \
  -m Flow:Skywave_Sourcing_Negotiate_Supplier \
  -m Flow:Skywave_Sourcing_Award_Approval_Sim \
  -m Flow:Skywave_Sourcing_Finalize_Contract \
  -m Flow:Skywave_Sourcing_Cancel \
  -o si

# 4. the orchestration itself (Active)
sf project deploy start -m Flow:Skywave_Sourcing -o si
```

Then create a `Sourcing_Request__c` record (see **How it launches**) to start a run, and
watch it complete via `FlowOrchestrationInstance` / `FlowOrchestrationStepInstance` (or in
**Setup → Automation → Flows**). Because all steps are background, a run completes on its own
with no work items to action.

```bash
# confirm the most recent run and its step statuses
sf data query -o si -q "SELECT Id, Status, CurrentStage FROM FlowOrchestrationInstance ORDER BY CreatedDate DESC LIMIT 1"
```
