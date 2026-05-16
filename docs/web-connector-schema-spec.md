# Web Connector Schema — Skywave Interactive on `si`

**Target editor:** Setup → Data Cloud Setup → Web & Mobile App Connectors → *Skywave Interactive* → Schema tab.

**Source of truth:** the canonical schema is
[`https://cdn.c360a.salesforce.com/cdp/schemas/260/web-connector-schema.json`](https://cdn.c360a.salesforce.com/cdp/schemas/260/web-connector-schema.json)
(referenced as v260 in the SDK docs). Match field names exactly — they're case-sensitive.

**House rule for this project:** schema is **append-only** after upload. Get it right the first time. If you see a misnamed field after publishing, the only fix is dropping the connector and rebuilding everything downstream.

**Cross-reference:** see `~/dev/claude-skills/sf-interactions-sdk/` for the SDK skill that explains why each event matters.

---

## Events to include

Six events out of electra's twelve. Skipping the e-commerce events because Skywave doesn't sell merchandise on the website (flight booking happens through the Agentforce agent, not the cart/checkout flow).

| Event | Category | Status | Why |
|---|---|---|---|
| `consentLog` | Engagement | **keep** | GDPR audit ledger, fired by `updateConsents()` after Accept |
| `userProfiling` | Engagement | **keep + extend** | Survey answers; main signal feeding the agent's RTDG grounding |
| `catalog` | Engagement | **keep** | Generic browse tracking — help, amenity, destination, flight pages |
| `contactPointEmail` | Profile | **keep** | IR exact-match key A on email — required for RTDG |
| `partyIdentification` | Profile | **keep** | IR exact-match key B on Contact.Id — required for RTDG |
| `identity` | Profile | **keep** | Flips SDK to known + writes Identity DMO |

| Event | Status | Why |
|---|---|---|
| `cart`, `cartItem` | **drop** | No on-site cart |
| `order`, `orderItem` | **drop** | No on-site checkout (booking goes via agent) |
| `contactPointAddress` | **drop for v1** | Profile form doesn't capture address. Add later if needed — schema is append-only so adding a new event later is safe. |
| `contactPointPhone` | **drop for v1** | Same — profile doesn't capture phone. Add later. |

Two ways to handle the drops in the editor:

- **Preferred**: just don't add them. The Web Connector lets you select which event types to include in the schema; only check the six above.
- **If the editor forces all stock events on you**: leave the unused ones with their default (auto-generated) field set. Just never fire them. The schema in the editor describes what *can* arrive; what actually arrives is up to the SDK calls.

---

## Field-level spec

### Common auto-set fields (every event)

These are populated by the SDK; you don't set them in `sendEvent`. They show up automatically in every event row.

| Field | Type | Required |
|---|---|---|
| `category` | Text | yes |
| `dateTime` | DateTime | yes |
| `deviceId` | Text | yes (primary key on Profile events) |
| `eventId` | Text | yes (primary key on Engagement events) |
| `eventType` | Text | yes |
| `sessionId` | Text | yes |
| `interactionName` | Text | required on Engagement events |
| `pageView` | Number | optional |
| `sourceChannel` | Text | optional |
| `sourceLocale` | Text | optional |
| `sourcePageType` | Text | optional |
| `sourceUrl` | Text | optional |
| `sourceUrlReferrer` | Text | optional |

### `consentLog`

All standard fields, no customizations.

| Field | Type | Required |
|---|---|---|
| common auto fields | … | … |
| `provider` | Text | optional |
| `purpose` | Text | optional |
| `status` | Text | yes |

### `userProfiling` *(EXTENDED — this is the only event we customize)*

The keys-and-text decision: store both the human-readable strings (for agent grounding) **and** the stable join keys (for monitor lookups + analytics).

| Field | Type | Required | Notes |
|---|---|---|---|
| common auto fields | … | … | |
| `attributesQuestion` | Text | yes | Full question text — agent reads this verbatim |
| `attributesQuestionKey` | Text | yes | **NEW** — stable key, e.g. `fav_destination`. For joins back to `Survey_Question__c` |
| `attributesAnswer` | Text | yes | Full answer text — agent reads this verbatim |
| `attributesAnswerKey` | Text | yes | **NEW** — stable key, e.g. `tyo`. For joins back to `Survey_Answer_Option__c` |

Field-name convention: SDK turns `interaction.attributes.foo` into `attributesFoo` schema fields automatically. So in code you'll write:

```js
SalesforceInteractions.sendEvent({
  interaction: {
    name: 'userProfiling',
    eventType: 'userProfiling',
    attributes: {
      question:    'Where would you fly?',
      questionKey: 'fav_destination',
      answer:      'Tokyo',
      answerKey:   'tyo'
    }
  }
});
```

…and the schema editor needs four fields named `attributesQuestion`, `attributesQuestionKey`, `attributesAnswer`, `attributesAnswerKey`, all Text, all required.

### `catalog`

Stock fields. We use this for any "user looked at thing X" event.

| Field | Type | Required |
|---|---|---|
| common auto fields | … | … |
| `id` | Text | yes |
| `type` | Text | yes |

The `category` field is auto-set ("Engagement"); we use the `id` field for our typed identifier (`amenity:lounge`, `flight:SW-100`, `destination:nrt`, `help:baggage-policy`) and `type` for the noun (`Amenity`, `Flight`, `Destination`, `Help`).

### `contactPointEmail`

| Field | Type | Required |
|---|---|---|
| common auto fields | … | … |
| `email` | Text | yes |

### `partyIdentification`

| Field | Type | Required |
|---|---|---|
| common auto fields | … | … |
| `IDName` | Text | yes |
| `IDType` | Text | yes |
| `userId` | Text | yes |

For Skywave, every `partyIdentification` event will use:
- `IDName = 'SkywaveContactId'`
- `IDType = 'CRM'`
- `userId = <the Contact.Id we just created>`

The CRM connector mapping on `si` must populate the *same* `IDName` value into the CRM-side `PartyIdentification` DMO so IR's exact-match rule can pair them. We'll handle that mapping when we get to step 8.

### `identity`

| Field | Type | Required |
|---|---|---|
| common auto fields | … | … |
| `firstName` | Text | optional |
| `lastName` | Text | optional |
| `email` | Text | optional |
| `phoneNumber` | Text | optional |
| `addressLine1`–`addressLine4` | Text | optional |
| `city`, `country`, `postalCode`, `stateProvince` | Text | optional |
| `isAnonymous` | Text | yes — **string `'0'` or `'1'`**, not boolean |

Even though `email` and `phoneNumber` exist on this event, **firing `identity` alone does not populate `ContactPointEmail` or `ContactPointPhone`.** It populates the Identity DMO only. The contact-point events are separate `sendEvent` calls. (See SDK skill `references/identity-and-resolution.md`.)

For Skywave we use `addressLine1`–`addressLine4` only as the documented escape hatch if we ever need to pack extra session metadata in without a schema bump. **Not used in v1.**

---

## How to upload

The schema editor is **upload-only** — there is no field-by-field UI. The complete JSON to upload lives at:

```
docs/web-connector-schema-skywave.json
```

It was generated by `scripts/build_web_connector_schema.py` from:
- the canonical SDK schema v260 (`https://cdn.c360a.salesforce.com/cdp/schemas/260/web-connector-schema.json`) for the five stock events we keep
- a hand-authored `userProfiling` definition modeled on electra's, extended with the two new key fields

Steps in `si`:

1. Open the connector you created → **Schema** tab.
2. **Upload** `docs/web-connector-schema-skywave.json`.
3. Verify the editor preview shows six events: `consentLog`, `userProfiling`, `catalog`, `contactPointEmail`, `partyIdentification`, `identity`.
4. Verify `userProfiling` shows the four custom Text fields (`attributesQuestion`, `attributesQuestionKey`, `attributesAnswer`, `attributesAnswerKey`).
5. **Publish.**

If the editor refuses the upload with a validation error, paste the error here and we'll fix the JSON.

If you ever need to regenerate the schema (e.g., after the canonical v260 bumps to v270), run:

```bash
curl -fsSL https://cdn.c360a.salesforce.com/cdp/schemas/260/web-connector-schema.json -o /tmp/web-connector-schema.json
python3 scripts/build_web_connector_schema.py
```

(Bump the version number when Salesforce ships a new one. The build script is committed.)

**After publishing**, the Web Connector will show its own JSON export under the same Schema tab. Save that export as `docs/web-connector-schema-published.json` so we have a record of exactly what landed in `si` (the Web Connector may renormalize field order, add `availabilityStatus` metadata, etc.).

---

## Verification before moving to sitemap

After you publish:

- [ ] All six events appear in the editor's event list
- [ ] Tapping `userProfiling` shows four custom fields plus the standard ones
- [ ] No e-commerce events (`cart`, `cartItem`, `order`, `orderItem`) included
- [ ] Schema is in **Published** state (not Draft)

Once those four are green, we move to the sitemap.
