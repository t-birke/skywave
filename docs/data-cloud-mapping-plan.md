# Data Cloud DLO → DMO Mapping Plan

Source authority: `~/dev/claude-skills/sf-interactions-sdk/references/`
(`event-catalog.md`, `identity-and-resolution.md`, `sdk-to-schema-mapping.md`).

This doc is the **executable** mapping plan, with all DMO names verified against `si` and all field names verified against actual DMO schemas pulled at write-time. Each mapping below is what we will submit to the Data Cloud Connect API.

## Principle

**Use standard DMOs wherever a standard exists.** Custom DMOs only for the one case the SDK explicitly says is custom — `userProfiling`. Reasons:

1. Pre-built IR rule templates target the standard DMOs by name.
2. Real-Time Data Graphs ship with `Individual`-rooted node templates that read the standard contact-point and party-identification DMOs.
3. The CRM connector's standard mappings land on the same DMOs from the CRM side — that symmetry is what lets IR exact-match across browser and CRM.
4. Standard DMOs survive Data Cloud version bumps. Custom ones we own forever.

The one custom DMO we need is `Survey_Response_DMO` — there is no standard DMO for "user took a survey and answered with key/text pairs."

## DLO topology — verified on `si` 2026-05-18

| DLO | Category | Source events | PK |
|---|---|---|---|
| `skywave_app_Behavioral_Events_F0A96086__dll` | Engagement | `consentLog`, `userProfiling`, `catalog` (combined, prefixed columns) | `eventId` |
| `skywave_app_contactPointEmail_D4D3D1DA__dll` | Profile | `contactPointEmail` only | `deviceId` |
| `skywave_app_identity_8D2D3E28__dll` | Profile | `identity` only | `deviceId` |
| `skywave_app_partyIdentification_920CD48D__dll` | Profile | `partyIdentification` only | `deviceId` |

The Engagement DLO is wide — all event types share columns, namespaced (`userProfiling_attributesAnswerKey`, `consentLog_provider`, `catalog_id`). Profile DLOs each have their own. Mapping consequence: the single Engagement DLO maps to **THREE** DMOs via three eventType-filtered mappings.

## Target DMOs — verified on `si` 2026-05-18

| Event | Target DMO | Status |
|---|---|---|
| `consentLog` | `ssot__PrivacyConsentLog__dlm` | ✓ standard, exists |
| `userProfiling` | `Survey_Response__dlm` | custom — to create |
| `catalog` | `ssot__ProductBrowseEngagement__dlm` | ✓ standard, exists |
| `contactPointEmail` | `ssot__ContactPointEmail__dlm` | ✓ standard, exists |
| `partyIdentification` | `ssot__PartyIdentification__dlm` | ✓ standard, exists |
| `identity` | `ssot__Individual__dlm` | ✓ standard, exists |

### Note on standard-DMO fit

- **`ssot__PrivacyConsentLog__dlm`** has 19 fields, mostly Id-references to other consent DMOs (`ssot__ConsentActionId__c`, `ssot__PrivacyConsentStatusId__c`, `ssot__ContactPointId__c`). It does **not** have plain `Provider/Purpose/Status` text fields. The mapping here is therefore **skinny** — we land the consent event but most fields stay empty until we wire the related-DMOs chain. v1 acceptance: a row exists per consent event, queryable, sufficient for audit.
  - **Important caveat:** `PrivacyConsentLog` is the **audit history**, not the canonical source of truth for "is this contact currently opted in for purpose X?" That source-of-truth DMO is `ssot__ContactPointConsent__dlm`. The SDK can't populate it directly because `consentLog` events are anonymous (keyed on `deviceId` only, no email yet at consent time). Materializing ContactPointConsent requires a Data Cloud transform that joins each PrivacyConsentLog row with the same-deviceId ContactPointEmail row (which only lands once the user creates a profile). **Deferred to backlog** — only needed for production marketing/activation use cases; v1 binary opt-in is fine with the audit log alone. Full chain analysis in `~/dev/claude-skills/sf-interactions-sdk/recipes/consent.md` § "The Consent DMO Chain"; backlog entry in SKYWAVE_INTERACTIVE_DESIGN.md §16.
- **`ssot__ProductBrowseEngagement__dlm`** has 106 fields, heavily e-commerce flavored (`ssot__ProductId__c`, `ssot__ProductSKU__c`, `ssot__ShoppingCartId__c`). Our `catalog` event uses generic ids like `amenity:lounge`, not products. We map to the **page-level fields** (`ssot__PageId__c`, `ssot__WebpageType__c`, `ssot__PageURL__c`) and leave the product-specific ones empty. Loose semantic fit, but it's the canonical "user viewed something" DMO and pre-built IR / segment templates target it. Better than inventing a custom DMO that nothing else can read.

## Mapping 1: Behavioral_Events → ssot__PrivacyConsentLog__dlm (filtered eventType=consentLog)

| DLO field | DMO field | Notes |
|---|---|---|
| `eventId` | `ssot__Id__c` | Primary key |
| `dateTime` | `ssot__PrivacyConsentActivityDttm__c` | When consent changed |
| `dateTime` | `ssot__CreatedDate__c` | duplicate is OK; both are standard timestamps |
| `deviceId` | `ssot__ExternalRecordId__c` | The browser-side identifier we have |
| `consentLog_provider` | `ssot__ExternalSourceId__c` | "Skywave Interactive" |

Mapping filter: `eventType = 'consentLog'`.

Other fields on the DMO are Id-references to a consent-action / status / category model we don't have wired (Phase 2.5 candidate). They stay empty.

## Mapping 2: Behavioral_Events → Survey_Response__dlm (CUSTOM — to be created, filtered eventType=userProfiling)

### Custom DMO definition

```json
{
  "name": "Survey_Response__dlm",
  "label": "Survey Response",
  "category": "ENGAGEMENT",
  "fields": [
    { "name": "Id__c",            "type": "Text",     "isPrimaryKey": true,  "label": "Survey Response Id" },
    { "name": "EventDateTime__c", "type": "DateTime",                        "label": "Event Date Time" },
    { "name": "DeviceId__c",      "type": "Text",                            "label": "Device Id" },
    { "name": "SessionId__c",     "type": "Text",                            "label": "Session Id" },
    { "name": "QuestionKey__c",   "type": "Text",                            "label": "Question Key" },
    { "name": "QuestionText__c",  "type": "Text",                            "label": "Question Text" },
    { "name": "AnswerKey__c",     "type": "Text",                            "label": "Answer Key" },
    { "name": "AnswerText__c",    "type": "Text",                            "label": "Answer Text" }
  ]
}
```

(The Connect API may auto-prefix `ssot__` or accept whatever we give it; we'll know once we POST. Using bare names in this plan; the create call uses what the API accepts.)

### Field mapping

| DLO field | DMO field |
|---|---|
| `eventId` | `Id__c` |
| `dateTime` | `EventDateTime__c` |
| `deviceId` | `DeviceId__c` |
| `sessionId` | `SessionId__c` |
| `userProfiling_attributesQuestionKey` | `QuestionKey__c` |
| `userProfiling_attributesQuestion` | `QuestionText__c` |
| `userProfiling_attributesAnswerKey` | `AnswerKey__c` |
| `userProfiling_attributesAnswer` | `AnswerText__c` |

Filter: `eventType = 'userProfiling'`.

## Mapping 3: Behavioral_Events → ssot__ProductBrowseEngagement__dlm (filtered eventType=catalog)

| DLO field | DMO field | Notes |
|---|---|---|
| `eventId` | `ssot__Id__c` | Primary key |
| `dateTime` | `ssot__EngagementDateTm__c` | When viewed |
| `dateTime` | `ssot__CreatedDate__c` | Standard timestamp |
| `deviceId` | `ssot__WebCookieId__c` | The anonymous browser id |
| `sessionId` | `ssot__SessionId__c` | Browser session |
| `catalog_id` | `ssot__PageId__c` | e.g. `amenity:lounge` |
| `catalog_type` | `ssot__WebpageType__c` | e.g. `Amenity` |
| `catalog_interactionName` | `ssot__Name__c` | e.g. `View Catalog Object` |
| `catalog_sourceUrl` | `ssot__PageURL__c` | URL where viewed |
| `catalog_sourceUrlReferrer` | `ssot__ReferrerURL__c` | Referrer |
| `catalog_sourcePageType` | `ssot__PageName__c` | Sitemap-resolved page type |

Filter: `eventType = 'catalog'`.

We do NOT map to `ssot__ProductId__c`, `ssot__ProductSKU__c`, etc. — we have no product semantics to put there.

## Mapping 4: contactPointEmail DLO → ssot__ContactPointEmail__dlm (1:1, no filter)

| DLO field | DMO field |
|---|---|
| `deviceId` | `ssot__Id__c` |
| `dateTime` | `ssot__CreatedDate__c` |
| `dateTime` | `ssot__ProfileFirstCreatedDate__c` |
| `email` | `ssot__EmailAddress__c` |
| `eventId` | `ssot__CreationEventId__c` |

`ssot__EmailAddress__c` is the **IR exact-match target A.**

## Mapping 5: partyIdentification DLO → ssot__PartyIdentification__dlm (1:1, no filter)

| DLO field | DMO field | Notes |
|---|---|---|
| `deviceId` | `ssot__Id__c` | Primary key |
| `dateTime` | `ssot__CreatedDate__c` | When captured |
| `IDName` | `ssot__Name__c` | We send `'SkywaveContactId'` |
| `userId` | `ssot__IdentificationNumber__c` | **The IR exact-match target B** — Contact.Id |
| `IDType` | `ssot__PartyIdentificationTypeId__c` | We send `'CRM'` |
| `eventId` | `ssot__CreationEventId__c` | |

`ssot__IdentificationNumber__c` is the field that holds the actual ID value (not `ssot__Name__c`). The CRM connector mapping on the CRM side must mirror this.

## Mapping 6: identity DLO → ssot__Individual__dlm (1:1, no filter)

| DLO field | DMO field | Notes |
|---|---|---|
| `deviceId` | `ssot__Id__c` | Primary key (browser-side); the CRM connector lands its own Individuals with Contact.Id |
| `dateTime` | `ssot__CreatedDate__c` | |
| `firstName` | `ssot__FirstName__c` | |
| `lastName` | `ssot__LastName__c` | |
| `isAnonymous` | `ssot__IsAnonymous__c` | string `'0'` / `'1'` |
| `eventId` | `ssot__CreationEventId__c` | |

We **skip** mapping `email`, `phoneNumber`, `addressLine1..4` from the identity DLO into the corresponding individual fields — those are populated via the dedicated contact-point events. Per SDK skill `references/identity-and-resolution.md`.

## Identity Resolution ruleset (post-mapping)

After all 6 mappings are in place, IR ruleset:

- **Match rules** (both must be exact for RTDG eligibility):
  - Rule A — exact match `ssot__ContactPointEmail__dlm.ssot__EmailAddress__c`
  - Rule B — exact match `ssot__PartyIdentification__dlm.ssot__IdentificationNumber__c`
- **Reconciliation rules**:
  - Most-recent-wins on `ssot__Individual__dlm.ssot__FirstName__c` / `ssot__LastName__c`

Either match alone is enough to merge a browser-side Individual into the CRM Contact-derived Unified Individual. Both is robust.

## Real-Time Data Graph (post-IR)

Root: Unified Individual. Related dimensions:
- `Survey_Response__dlm` — survey answers (custom)
- `ssot__ProductBrowseEngagement__dlm` — browse history (catalog events)
- `ssot__ContactPointEmail__dlm` — email contact point
- `ssot__PartyIdentification__dlm` — userId join

Plus the CRM-side related DMOs that the CRM connector will land (Contact, Reservation, Flight) once we wire the CRM connector's `partyIdentification` mapping symmetrically.

## Order of execution

1. **Verify standard DMOs exist** — done. ✓
2. **Create `Survey_Response__dlm`** custom DMO.
3. **Create the 6 mappings** in the order listed above. Easier ones first (Profile DLOs 1:1) so we catch any API-shape surprises before tackling the 3-way Engagement split.
4. **Verify** — fire one survey answer from the consumer site, query `Survey_Response__dlm` for that deviceId, confirm we see the row.
5. **IR ruleset** — separate work item once mappings are stable.
6. **Real-Time Data Graph** — separate work item once IR ruleset is published.

## What this plan does NOT do

- Does not create custom DMOs for `consentLog`, `catalog`, `contactPointEmail`, `partyIdentification`, `identity`.
- Does not denormalize email/phone/address from the `identity` event into the contact-point DMOs (those have their own events).
- Does not create the e-commerce-flavored mappings on `ssot__ProductBrowseEngagement__dlm` (no product IDs in our catalog events).
- Does not configure the CRM connector's `partyIdentification` mapping — that's a separate prerequisite for IR to actually merge browser ↔ CRM rows. We document it as a follow-up.
