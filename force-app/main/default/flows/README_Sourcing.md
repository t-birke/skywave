# Skywave Sourcing — Mock Flow Orchestration

A **mock** Flow Orchestration (`processType = Orchestrator`) that showcases a complex,
generally-applicable strategic-purchasing / sourcing process: sourcing a category of
goods or services for next season across the airline's whole route network. Every step
calls a **stub subflow** so the orchestration runs end-to-end without any external
procurement systems.

It exists to demonstrate the moving parts of Flow Orchestrator — background vs.
interactive steps, data threaded stage-to-stage, an entry condition gate — **and in
particular the two AI hand-offs**:

- a subprocess that **hands over to a prompt template** (RFP drafting), and
- a subprocess that **hands over to an Agentforce agent** (supplier negotiation).

> These are mock/demo flows. They are deployed **Active** on `si` and driven entirely by
> **stub subflows** that return deterministic placeholder data rather than touching real
> procurement systems. Nothing is tied to any specific spend category — supply the
> category in the RFP/spec content when you adapt it.

## How it launches

The orchestration is **record-triggered** on the mock `Sourcing_Request__c` object
(`recordTriggerType = Create`, `triggerType = RecordAfterSave`). Creating a
`Sourcing_Request__c` record kicks off the pipeline, and `$Record` becomes the context
record threaded into every step — including the two **interactive** steps, which *require*
a context record (each maps `ActionInput__RecordId` → `$Record.Id`; without it the
orchestration fails activation with *"A context record is required for interactive steps"*).

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
| 2. Issue RFP | Review & Release RFP | **interactive** | `Skywave_Sourcing_Issue_RFP` | Category Manager reviews the AI-drafted RFP and releases it to the supplier panel. |
| 3. Evaluate | Score Supplier Bids | background | `Skywave_Sourcing_Evaluate_Bids` | Weighted matrix (price / quality / sustainability / service level). |
| 4. Negotiate | Agent Negotiation | background | `Skywave_Sourcing_Negotiate_Supplier` | **→ hands to Agentforce agent** `Skywave_Airlines_Agent` (`generateAiAgentResponse`) to negotiate pricing & rebate tiers. |
| 5. Award & Contract | Procurement Director Approval | **interactive** | `Skywave_Sourcing_Award_Approval` | Human approve/reject on the negotiated terms. |
| 5. Award & Contract | Generate Contract & POs | background | `Skywave_Sourcing_Finalize_Contract` | **Entry condition:** only runs when the approval decision = `Approved`. |

Data flows through the orchestration via each step's outputs, referenced downstream as
`Step_<Name>.Outputs.<var>` (e.g. the leading supplier from the evaluation step feeds
both the negotiation and the award steps).

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
- **Stub subflows:** `Skywave_Sourcing_Demand_Forecast`, `Skywave_Sourcing_Draft_RFP`,
  `Skywave_Sourcing_Issue_RFP`, `Skywave_Sourcing_Evaluate_Bids`,
  `Skywave_Sourcing_Negotiate_Supplier`, `Skywave_Sourcing_Award_Approval`,
  `Skywave_Sourcing_Finalize_Contract`
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

# 3. the seven stub subflows (Active)
sf project deploy start \
  -m Flow:Skywave_Sourcing_Demand_Forecast \
  -m Flow:Skywave_Sourcing_Draft_RFP \
  -m Flow:Skywave_Sourcing_Issue_RFP \
  -m Flow:Skywave_Sourcing_Evaluate_Bids \
  -m Flow:Skywave_Sourcing_Negotiate_Supplier \
  -m Flow:Skywave_Sourcing_Award_Approval \
  -m Flow:Skywave_Sourcing_Finalize_Contract \
  -o si

# 4. the orchestration itself (Active)
sf project deploy start -m Flow:Skywave_Sourcing -o si
```

Then create a `Sourcing_Request__c` record (see **How it launches**) to start a run, and
watch it in **Setup → Automation → Automations / Flows** or via the assigned work items in
the running user's list view.
