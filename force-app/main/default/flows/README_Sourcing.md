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
| 2. Issue RFP | Review & Release RFP *(simulated)* | background | `Skywave_Sourcing_Issue_RFP_Sim` | Releases the RFP and **seeds the supplier panel's bids** — creates example `Supplier_Bid__c` records against the request (the one place demo supplier names live). |
| 3. Evaluate | Score Supplier Bids | background | `Skywave_Sourcing_Evaluate_Bids` | **Data-driven**: reads the request's `Supplier_Bid__c` rows, computes each bid's `Weighted_Total__c` from its component scores × the request's configurable weights, ranks, flags the winning `Is_Leading_Bid__c`, writes back. Emits the leader + score. **Built out (~20 nodes) as a Flow Builder teaching canvas** — see below. |
| — | **`Bid_Quality_Gate` decision** | *decision* | — | `out_LeadingScore > 0` (Evaluate returned a qualifying leader) → Stage 4; else → Stage X (cancel). The qualifying *threshold* itself is `Sourcing_Request__c.Qualifying_Threshold__c`, applied inside Evaluate. |
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

## The data model (what makes it versatile)

The evaluation is **data-driven** — nothing about suppliers, scores, or weights is hardcoded
in the flow logic:

- **`Supplier_Bid__c`** (child of `Sourcing_Request__c`, master-detail): one row per bid.
  `Supplier_Name__c`, `Unit_Price__c`, four buyer-assigned component scores
  (`Price_Score__c`, `Quality_Score__c`, `Sustainability_Score__c`, `Service_Level_Score__c`,
  each 0–100), plus two fields the flow writes: `Weighted_Total__c` and `Is_Leading_Bid__c`.
- **`Sourcing_Request__c`** gains configurable evaluation settings: `Weight_Price__c` (40),
  `Weight_Quality__c` (25), `Weight_Sustainability__c` (20), `Weight_Service_Level__c` (15),
  and `Qualifying_Threshold__c` (75). Change these per request and the outcome changes — no
  flow edit. (The flow normalizes by the weights' sum, so they need not total 100.)

In the demo, the RFP-release step (`Skywave_Sourcing_Issue_RFP_Sim`) seeds four example bids
so there's something to evaluate; in a real deployment those rows would be created by
suppliers/buyers. That seed step is the only place example supplier names appear.

## `Skywave_Sourcing_Evaluate_Bids` — the Flow Builder teaching canvas

Built out (~20 elements, multiple happy/error paths) so it can be opened in Flow Builder to
walk an audience through the element palette — while being a genuine, reusable evaluation.
Inputs: `inp_RequestId` (+ `inp_Season`); outputs: `out_LeadingSupplier`, `out_LeadingScore`,
`out_Shortlist`.

Canvas walkthrough (start → end):

1. **Get Records** `Get_Request` — the `Sourcing_Request__c` (for its weights + threshold).
   **Fault path** → `Handle_Query_Fault`.
2. **Decision** `Was_Request_Found` — *Not Found* → `Handle_No_Request`; else continue.
3. **Get Records** `Get_Bids` — all `Supplier_Bid__c` for the request. **Fault path** →
   `Handle_Query_Fault`.
4. **Assignment** `Init_Evaluation` — reset counters + shortlist.
5. **Loop** `Loop_Bids` over the bids:
   - **Assignment** `Score_This_Bid` — computes the weighted total for *this* bid via formula
     `fx_WeightedTotal` (component scores × the request's weights ÷ weight-sum), writes it onto
     the loop record, appends to the shortlist, adds the record to a collection to bulk-update.
   - **Decision** `Check_New_Max` — *Higher Score* → `Capture_Leader` (remember supplier, id,
     score); *Not Higher* → loop. Both return to the loop.
6. After the loop, **Decision** `Had_Any_Bids` — *No Bids* → `Handle_No_Bids`; else continue.
7. **Update Records** `Update_All_Bids` — bulk-writes every bid's `Weighted_Total__c` (from the
   collection). **Fault path** → `Handle_Update_Fault`.
8. **Decision** `Is_Leader_Qualified` — leader's max score vs. formula `fx_Threshold`
   (the request's `Qualifying_Threshold__c`). *Qualified* → set qualified outputs →
   **Update Records** `Mark_Leading_Bid` (sets `Is_Leading_Bid__c` on the winner);
   *Below Threshold* → set "none qualified" outputs (`out_LeadingScore = 0`).
9. **Update Records** `Update_Request_Status`. **Fault path** → `Handle_Update_Fault`.
10. **Assignment** `Finalize_Success`.

Elements on show: **three Get/Update data elements plus a bulk update and a targeted update**,
**three independent fault paths**, a **Loop**, **four Decisions** (found / new-max / any-bids /
qualified), a not-found and a no-bids branch, formula resources, an sObject collection, and
`{!$Flow.FaultMessage}` — all in service of real logic, not filler.

## Simulated human steps & interactive-step blocker

The two review points are modelled as **background** stubs rather than real `stepInteractive`
work items:

- `Skywave_Sourcing_Issue_RFP_Sim` → returns `out_ReleaseDecision='Released'`
- `Skywave_Sourcing_Award_Approval_Sim` → returns `out_ApprovalDecision='Approved'`
  (which satisfies the finalize step's entry-condition gate).

**Why (confirmed root cause):** this SDO **lacks the Flow-Orchestration runtime license**, so
interactive steps can't be created. Any `stepInteractive` fails at *runtime* the instant its
stage is entered — `FLOW_ELEMENT_ERROR|Invalid Resource reference|FlowOrchestratedStage`, with
**zero** `FlowOrchestrationStepInstance` rows and the instance `Status=Error`,
`CurrentStage=null`. It fails identically for every assignee tried (`$User.Id`,
`$Record.OwnerId`, a formula → active System Admin Id, and a public **Group**) and regardless
of position (even as the *first* step, before any async pause), while every `stepBackground`
step runs clean — so the assignee, ordering, data refs, and rendering metadata are all fine.

The smoking gun: the `ManageOrchestrationRuns` / `ReassignOrchestrationWorkItems` user
permissions are held by **no** permission set or profile in the org, and deploying either onto
`Skywave_Demo_Admin` is rejected with *"The user license doesn't allow the permission:
ManageOrchestrationRuns."* Interactive steps need those perms to write the work item; without
the entitlement the runtime aborts at stage entry. The only working interactive orchestrations
here are managed packages (which ship their own licensing). **Not fixable from source** — it
needs the Flow Orchestration license provisioned on the org.

The **real interactive screen flows are retained** in the repo —
`Skywave_Sourcing_Issue_RFP`, `Skywave_Sourcing_Award_Approval`, and
`Skywave_Sourcing_Demand_Planning` — and will work as-is once the license is present; just swap
the `_Sim` background actions back to the `stepInteractive` versions.

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
- **Trigger object:** `Sourcing_Request__c` (AutoNumber `SRC-{0000}`) with `Season__c`,
  `Category__c`, `Status__c`, the four `Weight_*__c` fields, and `Qualifying_Threshold__c`.
- **Bid object:** `Supplier_Bid__c` (AutoNumber `BID-{0000}`, master-detail child) with
  `Supplier_Name__c`, `Unit_Price__c`, the four component score fields, `Weighted_Total__c`,
  and `Is_Leading_Bid__c`. Full access for both objects is granted on the `Skywave_Demo_Admin`
  permission set (add new fields to `scripts/regen-demo-admin-fls.py`'s `OUR_OBJECTS` and
  re-run if you extend them).

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
