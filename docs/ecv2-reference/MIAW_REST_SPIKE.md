# MIAW REST custom-client spike — findings

**Branch:** `custom-chat-client`
**Date:** 2026-06-10
**Why:** ECv2 fails on iOS Safari (every iPhone) with "too many HTTP redirects".
Root cause is the cross-site guest-session cookie: the Heroku host page
(`*.herokuapp.com`) iframes the chat from the Salesforce site
(`*.my.site.com`). Both are public-suffix domains, so the `my.site.com`
guest cookie is third-party to the top frame and iOS ITP drops it →
`/ESADeployment/login?ec=302` redirect loop. No new domain is available
(demo must stay transferable to any installer), and a shared parent domain
or `customDomain` both require a registered domain we can't ship. The
escape hatch is a **custom chat client on the MIAW scrt2 REST API**: the
auth token comes back in the response **body**, lives in first-party
localStorage on the Heroku origin, so there is nothing for ITP to block and
nothing to redirect.

This doc records the live-verified API contract so the build doesn't
re-derive it.

## Live-verified facts (against `si` / `trailsignup-fb3f5426f87c5d`)

- orgId (18): `00Dg8000006I9hJEAS` — **but the SSE header and the token
  encode the 15-char form `00Dg8000006I9hJ`** (see SSE below).
- esDeveloperName: `Skywave_MIAW` (the `EmbeddedServiceConfig` dev name).
- scrt2 base: `https://trailsignup-fb3f5426f87c5d.my.salesforce-scrt.com`
- API base path: `/iamessage/v1` (NOT v2 for a **Web** deployment — see note).

### Endpoints (all confirmed working headlessly via curl)

| Step | Call |
|------|------|
| Config (proves published + scrt2) | `GET  /embeddedservice/v1/embedded-service-config?orgId=<18>&esConfigName=Skywave_MIAW&language=en_US` |
| **Access token (unauth)** | `POST /iamessage/v1/authorization/unauthenticated/accessToken` |
| Create conversation | `POST /iamessage/v1/conversation` |
| Send message | `POST /iamessage/v1/conversation/<convId>/message` |
| Receive (stream) | `GET  /eventrouter/v1/sse`  (header `X-Org-Id: <15-char>`) |
| Backfill entries | `GET  /iamessage/v1/queries/conversation/<convId>/entries` |
| Typing/receipts | `POST /iamessage/v1/conversation/<convId>/entry` |
| Resume | `POST /iamessage/v1/continuityAccessToken` |
| End | `DELETE /iamessage/v1/conversation/<convId>` |

### Exact payloads (schemas are STRICT — extra props 400)

**accessToken** — params are `developerName` (NOT `esDeveloperName`) and
`capabilitiesVersion` from an enum (`238,240,246,248,252,254,258,258.1,260`),
NO `platform`:
```json
POST /iamessage/v1/authorization/unauthenticated/accessToken
{ "orgId": "00Dg8000006I9hJEAS", "developerName": "Skywave_MIAW", "capabilitiesVersion": "260" }
→ 200 { "accessToken": "<JWT ~1862 chars>", "lastEventId": <n>, "context": {} }
```
> The **v2** path `/iamessage/api/v2/.../access-token` returns
> `BAD_REQUEST: "Set the esDeveloperName to a deploymentType that's set to
> api"` — that endpoint is for a dedicated **Custom Client ("api")**
> deployment. Our deployment is **Web**, so we use the **v1** path the
> official Web client uses. (We could alternatively create a separate
> `api`-type deployment; not needed.)

**create conversation** — client generates the conversationId (UUID); do
NOT send `esDeveloperName` (400):
```json
POST /iamessage/v1/conversation
Authorization: Bearer <JWT>
{ "conversationId": "<uuid>", "routingAttributes": { "Session_ID": "<deviceId>" } }
→ 201 { "conversationId": "...", "participants": [...] }
```

**send message** — `messageType` + `id` are TOP-LEVEL (not nested under a
`message` key); no `esDeveloperName`:
```json
POST /iamessage/v1/conversation/<convId>/message
Authorization: Bearer <JWT>
{ "messageType": "StaticContentMessage", "id": "<uuid>",
  "staticContent": { "formatType": "Text", "text": "..." },
  "isNewMessagingSession": false }
→ 200 {}
```

**SSE** — `Accept: text/event-stream`, `Authorization: Bearer <JWT>`, and
`X-Org-Id` must be the **15-char** org id or you get
`"OrgId in the header and token must match"`. Events arrive as
`event:<TYPE>\ndata:<json>`; each carries
`conversationEntry.entryPayload` (a **stringified** JSON — double-parse).
Event types seen: `CONVERSATION_MESSAGE`, `CONVERSATION_STREAMING_TOKEN`,
`CONVERSATION_TYPING_STARTED/STOPPED_INDICATOR`,
`CONVERSATION_PROGRESS_INDICATOR`, `ping`.

## Identity / booking resolution (the part that bit us)

The agent resolves identity in `Skywave_ResolveSession` by matching
`Contact.Skywave_Conversation_Id__c` to the chat's **internal**
`MessagingSession.ConversationId` — NOT the client-generated UUID, and NOT
the `routingAttributes.Session_ID` directly. Today the Heroku app stamps
that join via its chat-start POST (PE → trigger). A custom client keeps the
SAME mechanism: on `CONVERSATION_*` start, POST deviceId + the internal
ConvId to the existing Apex endpoint so the Contact is stamped **before**
the agent's first reasoning turn (`resolve_session` runs once, at the
router). If no Contact matches, the resolver falls back to the
`Skywave_Demo_Seed__c=true` contact.

**Gotcha that cost time (not an architecture issue):** `get_bookings` is
called with `deliverHistoricBookings=false`, so bookings whose last segment
already arrived are filtered out → agent says "no bookings" and never emits
a seatmap. Use a **future-dated** booking when testing (e.g. find via
`SELECT ... FROM Booking_Segment__c WHERE Travel_Date__c >= TODAY`).

## CLT (seatmap) traverses the REST API fully renderable ✅

The make-or-break question. A `present_seat_map` result arrived over SSE as
a `CONVERSATION_MESSAGE` whose `abstractMessage.staticContent` is:
```json
{ "formatType": "ExperienceType",
  "message": "Here's the seat map — pick a seat and confirm.",
  "values": [{
    "valueType": "ExperienceTypeValue",
    "type": "copilotActionOutput/present_seat_map_<id>",
    "value": { "seatMapData": { "seatMapJSON": "{...rows[].seats[], currentSeat, fareClass, flightNumber, bookingCode, bookingSegmentId...}" } }
  }] }
```
The complete `seatMapJSON` — the exact structure
`c/skywaveSeatMapRenderer` consumes today — arrives intact. The platform
does NOT hand out an opaque reference; the raw action output is in the
message entry. **A custom client renders the seatmap directly** from
`values[].value`. Generalises to all our CLTs: a `formatType:"ExperienceType"`
message carries `values[]` keyed by `type: copilotActionOutput/<action>`.

Seat-confirm: the LWC calls `@AuraEnabled Skywave_ChangeSeat.confirmSeatChange`,
which runs as the ESW guest user today. The custom client instead routes
the confirm through the existing Heroku→Apex path (already built).

## Raw assets
The verbatim Salesforce assets (`init.min.js` loader, `init.min.css`,
`embedded-messaging-styling.min.css`, `iframe-shell.html`, the 3.3MB
`home_view` bundle) are Salesforce **"Company Confidential"** and are
**gitignored** — this repo is planned to go public. Only our DERIVED notes
are committed: this doc, `ECV2_LOOK_AND_FEEL.md`, and
`raw-assets/keyframes-decoded.css` (extracted values). Re-pull the raw
assets locally with the curl commands in `ECV2_LOOK_AND_FEEL.md` when you
need them.
