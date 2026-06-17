# Voice Agent Setup (Tier 6 / Chapter 9) — self-contained guide

This is the complete, repo-local guide for standing up Skywave's voice agent
(`Skywave_Voice_Agent`). **No external skill or tool is required** — every step is
here. `install.sh --with-voice` scripts everything that has an API — permsets, agent
publish/activate, **the channel routing binding (flow + queue + activate), and queue
membership**. Only three things genuinely have NO public API (verified field-by-field)
and remain manual: **Partner Telephony toggle, claiming the phone number + creating the
NativeVoice channel, and the two PSTN toggles**. install.sh prints a `[GATE]` at each
of those and points here.

| Step | Who does it |
|------|-------------|
| 6.1 NativeCCaaS permsets | scripted (install.sh) |
| 6.1 re-login + Partner Telephony toggle | **you (UI — toggle is read-only via API)** |
| 6.2 publish + activate the voice agent | scripted |
| 6.3 claim number + create NativeVoice channel | **you (UI — vendor-provisioned, no API)** |
| 6.4 bind channel routing (flow+queue) + activate + queue membership | scripted |
| 6.5 the two PSTN toggles | **you (UI — not in any writable settings object)** |
| 6.5 test call | you (a phone) |

> Why a doc and not more script: claiming a phone number, creating the NativeVoice
> channel, the two PSTN toggles, and binding Omni-Flow routing on the channel are all
> **UI-only** in Salesforce (confirmed — no metadata/REST path). The ORDER is
> load-bearing; doing a step early bricks a phone number permanently. Follow it exactly.

## What's already in the repo (deployed by Tiers 1 + 6.2)

You do **not** build these — they ship in `force-app/` and deploy automatically:

| Artifact | What it is |
|---|---|
| `aiAuthoringBundles/Skywave_Voice_Agent` | the telephony agent (published+activated by §6.2) |
| `flows/Skywave_Route_to_Voice_Agent` | **inbound** routing flow (Copilot → agent). No `isQueueVariable` (see gotcha). |
| `flows/Skywave_Route_Voice_to_Queue` | **escalation** flow (agent → human queue) |
| `flows/Skywave_VoiceCall_Set_Caller_Fields` | stamps caller name fields for the personalized greeting |
| `classes/Skywave_VoiceCallResolver` | VoiceCall trigger: matches caller phone → Contact (trailing 9 digits) |
| `queueRoutingConfigs/skywave_routing` | `LEAST_ACTIVE` routing config for the voice queue |

## Prerequisites

- The org must be a **Voice-enabled SDO/trial spun up 2026-02-21 or later** (older orgs
  lack the Communication Channels UI for NativeVoice). Verify the license exists:
  ```bash
  sf data query --target-org "$ORG_ALIAS" -q "SELECT Id FROM PermissionSet WHERE Name='ContactCenterAgentNativeCCaaS'"
  ```
  No row → the org isn't Voice-licensed; request a Voice SDO. Stop here.
- Tiers 1 complete (the agent's backing Apex + flows are deployed).
- A mobile phone to place the test call.

---

## Step 6.1 — Permsets + RE-LOGIN  *(install.sh scripts the permsets; the re-login is yours)*

`install.sh §6.1` assigns `ContactCenterAdminNativeCCaaS`, `…AgentNativeCCaaS`,
`…SupervisorNativeCCaaS` (+ the `SDO_Service_CCaaS` PSG if present). Then **you must**:

1. **Log OUT and back IN to the org.** The softphone provisions at session start, not at
   permset assignment — until you re-login the Communication Channels UI won't show the
   New Channel option.
2. Confirm **Partner Telephony** is on:
   ```bash
   SF_INSTANCE=$(sf org display --target-org "$ORG_ALIAS" --json | jq -r '.result.instanceUrl')
   SF_TOKEN=$(sf org auth show-access-token --target-org "$ORG_ALIAS" --no-prompt --json | jq -r '.result.accessToken')
   curl -s -H "Authorization: Bearer $SF_TOKEN" \
     "$SF_INSTANCE/services/data/v66.0/tooling/query/?q=SELECT+IsScvExternalTelephonyEnabled+FROM+ServiceCloudVoiceSettings" \
     | jq '.records[0].IsScvExternalTelephonyEnabled'
   ```
   If `false`: **Setup → Partner Telephony Setup → toggle ON "Turn on Voice with Partner
   Telephony"** (UI-only).

> ⚠️ Do NOT claim a phone number until BOTH the permsets are assigned AND you've
> re-logged-in AND Partner Telephony is on. A number claimed too early is **permanently
> stuck** — the channel-create fails with a generic "We couldn't create the voice
> channel. Try again later." and no amount of retrying rescues it. You'd have to claim a
> fresh number. This is the #1 voice-setup failure.

---

## Step 6.3 — Claim a number + create the NativeVoice channel  *(UI-only)*

> **Use Setup → Communication Channels — NOT Setup → Agentforce Voice Setup.**
> The Agentforce Voice Setup UI makes a `VirtualVoiceAgent` channel that DROPS calls in
> 1–2 s on SDO/trial orgs. Only the **Communication Channels** UI makes a working
> `NativeVoice` (`PstnVoice`) channel.

1. Setup → **Communication Channels** → **New Number**.
2. Country US/CA, Number Type **10-Digit Long Code**, pick **one** number → Next → Finish.
3. Wait for status **Live** (refresh; if stuck, open the number → **Refresh Number Status**).
4. **Save the number to your phone** for testing.
5. Numbers tab → your number → **Edit** → check "Set as default CLI for outgoing calls" → Save.
6. Communication Channels → **New Channel** → Start → **Voice** → Next.
7. **Phone Number** = the one you claimed. **Call Routing Type** = `Omni-Queue` (placeholder
   — changed to Omni-Flow in §6.4). **Queue** = any existing voice queue for now. → Next → Done.
8. Leave it Inactive for now. Confirm it exists:
   ```bash
   sf data query --target-org "$ORG_ALIAS" -q \
     "SELECT Id, DeveloperName, MessageType, MessagingPlatformKey, IsActive FROM MessagingChannel WHERE MessageType='PstnVoice' ORDER BY CreatedDate DESC"
   ```
   Expect a `MessageType=PstnVoice` row with your number in `MessagingPlatformKey`. Note its `Id`.

> If step 6/7 errors "We couldn't create the voice channel": the number was claimed before
> §6.1 finished. Confirm §6.1 (permsets + re-login + Partner Telephony), then claim a
> **fresh** number and channel it. The dead number stays in the org, harmless.

---

## Step 6.4 — PSTN toggles + bind routing to the agent  *(UI-only)*

### 6.4a — The two PSTN toggles (transcript + recording)

**Setup → Agentforce Voice Setup → PSTN tab.** Turn ON both (default OFF, no save button):

- **Connect Related Voice Calls** — preserves the agent's pre-transfer conversation so the
  human who picks up sees the full transcript.
- **Record Voice Calls with Agents** — records the customer↔agent conversation.

> Without these, transfer still works but the rep sees an **empty transcript** — and you
> CANNOT diagnose it by SOQL (the transcript is live conversation-service data, absent from
> `ConversationEntry`/`VoiceCallTranscript` even on a healthy call). The only proof is a
> real call (Step 6.5). Do NOT create a channel from this page — only flip these toggles.

### 6.4b — Bind the inbound flow + queue to the channel  *(SCRIPTED — install.sh §6.4)*

**You don't do this by hand** — `install.sh --with-voice` does it via the REST API
once the channel exists. (The skill called this "UI-only"; it isn't — verified that
`MessagingChannel.SessionHandlerId`/`FallbackQueueId`/`IsActive` are all API-writable,
PATCH→204.) §6.4 finds the PstnVoice channel, resolves the `Skywave_Route_to_Voice_Agent`
FlowDefinition + the `SDO_Service_Voice_Call` queue (by DeveloperName — Ids are
per-org), PATCHes the channel, activates it, and adds the admin to the queue.

> Note: there is no `Omni-Flow` value in the `RoutingType` picklist — the "Omni-Flow"
> binding the UI shows is simply `SessionHandlerId` pointing at the inbound flow's
> FlowDefinition (a working channel has `RoutingType=null` + `SessionHandlerId` set).

If you ever need to do it manually (e.g. the PATCH failed): Communication Channels →
your channel → Edit → Omni-Channel Routing → Routing Type `Omni-Flow`, Flow Definition
`Skywave_Route_to_Voice_Agent`, Fallback Queue your voice queue → Save → Activate.

Verify (scripted or manual):
```bash
sf data query --target-org "$ORG_ALIAS" -q \
  "SELECT Id, IsActive, FallbackQueueId, SessionHandlerId FROM MessagingChannel WHERE MessageType='PstnVoice' AND IsActive=true"
```
Expect `IsActive=true`, `FallbackQueueId` set, `SessionHandlerId` = the inbound flow's FlowDefinition.

The two voice routing flows (`Skywave_Route_to_Voice_Agent`, `Skywave_Route_Voice_to_Queue`)
carry the queue Id as a `%%SKYWAVE_VOICE_QUEUE_ID%%` placeholder that the Tier-1 deploy
substitutes with the org's real `SDO_Service_Voice_Call` queue Id (it's re-minted per
org — a hardcoded Id from another org would break escalation). The queue ships supporting
`VoiceCall` with `LEAST_ACTIVE` routing (`skywave_routing`), so no manual queue config.

---

## Step 6.5 — Test the call

1. Service Console → Omni-Channel widget (bottom-right) → set status **Available for Voice**.
2. **Call the number from your phone.** Expected: agent answers, converses, can transfer
   to a human; after a transfer the rep's VoiceCall page shows the full agent transcript
   (proves 6.4a). Capture evidence:
   ```bash
   sf data query --target-org "$ORG_ALIAS" -q \
     "SELECT Id, VendorType, CallDurationInSeconds, CallDisposition FROM VoiceCall ORDER BY CreatedDate DESC LIMIT 3"
   ```
   A good call: `VendorType=NativeVoice` (NOT VirtualVoiceAgent), duration > 30 s.

---

## Troubleshooting (symptom → cause)

| Symptom | Cause / fix |
|---|---|
| Communication Channels UI has no "New Channel" | §6.1 permsets not assigned, OR you didn't re-login. Re-login. |
| Only "Agentforce Voice Setup" visible, not Communication Channels | NativeCCaaS permsets missing on the channel-creating user. Re-do §6.1. |
| Channel is `VirtualVoiceAgent` | Wrong UI. Deactivate it, claim a fresh number from **Communication Channels**, channel that. |
| "We couldn't create the voice channel. Try again later." | Number claimed before §6.1 finished → permanently stuck. Claim a fresh number after §6.1. |
| Call rings then busy | Channel `IsActive=false`, or inbound flow shape bug. |
| Call drops 1–2 s after answer, VoiceCall created | Wrong-flavor (VirtualVoiceAgent) channel. Use NativeVoice. |
| Hold music, no agent | Inbound flow has `isQueueVariable` (hides it from the agent's Inbound Routing) OR queue has no members. The repo's `Skywave_Route_to_Voice_Agent` omits `isQueueVariable` by design — don't add it. |
| Agent answers but escalates immediately on every topic | Bot user missing the agent's Apex permset at publish (§6.2 assigns `Skywave_Agent_User --on-behalf-of`). Re-assign, deactivate, republish, reactivate. |
| Agent transfers but rep sees EMPTY transcript | The two PSTN toggles (6.4a) are off. Turn both ON. Not SOQL-diagnosable. |
| Greeting says "Hello, ," with blank name | `Skywave_VoiceCall_Set_Caller_Fields` flow didn't fire / no Contact matched the caller phone. |
| Agent speaks wrong language | A gated `default_locale` was set; the agent ships `en_US`. Keep it. |

## Provenance

The Skywave-specific recipe + gotchas above are distilled from the internal
`voice-agent-demo` skill so this repo stands alone. If you have that skill it adds
generic depth (failure-mode diagnostics, the Omni Supervisor "AI Agents" tab fix), but
nothing here requires it.
