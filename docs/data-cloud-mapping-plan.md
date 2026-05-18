# Data Cloud DLO → DMO Mapping Plan

Source authority: `~/dev/claude-skills/sf-interactions-sdk/references/`
(`event-catalog.md`, `identity-and-resolution.md`, `sdk-to-schema-mapping.md`).

This doc lists every Web Connector event we send and where it maps. It exists to make every mapping decision **explicit** before we execute, so we can catch deviations from the standard pattern at review time, not at debug time.

## Principle

**Use standard DMOs wherever a standard exists.** Custom DMOs only for the one case the SDK explicitly says is custom — `userProfiling`. Reasons:

1. Pre-built IR rule templates target the standard DMOs by name.
2. Real-Time Data Graphs ship with `Individual`-rooted node templates that read the standard contact-point and party-identification DMOs.
3. The CRM connector's standard mappings land on the same DMOs from the CRM side — that symmetry is what lets IR exact-match across browser and CRM.
4. Standard DMOs survive Data Cloud version bumps. Custom ones we own forever.

The one custom DMO we need is `Survey_Response_DMO` — there is no standard DMO for "user took a survey and answered with key/text pairs."

## DLO topology — one Behavioral_Events DLO for ALL Engagement types

After data streams ran, `si` has these DLOs from the Web Connector:

| DLO | Category | Source events | PK |
|---|---|---|---|
| `skywave_app_Behavioral_Events_*__dll` | Engagement | `consentLog`, `userProfiling`, `catalog` (combined) | `eventId` |
| `skywave_app_contactPointEmail_*__dll` | Profile | `contactPointEmail` only | `deviceId` |
| `skywave_app_identity_*__dll` | Profile | `identity` only | `deviceId` |
| `skywave_app_partyIdentification_*__dll` | Profile | `partyIdentification` only | `deviceId` |

The Web Connector folds all Engagement event types into one wide
`Behavioral_Events` DLO with prefixed columns (`userProfiling_attributesAnswerKey`,
`consentLog_provider`, `catalog_id`, etc.). Profile events each get
their own DLO. This is Salesforce's standard pattern and matches how
the CRM connector ships its DMOs.

Mapping consequence: **the one Engagement DLO maps to THREE DMOs via
three eventType-filtered mappings.** The four Profile DLOs each map
to one DMO 1-to-1, no filtering.

## Event-by-event mapping

### 1. `consentLog` (Engagement)
- **Source DLO**: `skywave_app_Behavioral_Events_*__dll`, **filtered to `eventType='consentLog'`**.
- **Target DMO**: `ConsentLog__dlm` (Salesforce-standard).
- **Why standard**: Consent ledger is a regulated artifact; Data Cloud ships a dedicated DMO for it that activations and audit reports already understand.
- **Field-level mapping**:

  | DLO field | DMO field | Notes |
  |---|---|---|
  | `eventId` | `Id__c` | Primary key both sides |
  | `dateTime` | `EventDateTime__c` | Consent timestamp |
  | `deviceId` | `DeviceId__c` | Anonymous identifier |
  | `sessionId` | `SessionId__c` | Browser session |
  | `consentLog_provider` | `Provider__c` | `'Skywave Interactive'` |
  | `consentLog_purpose` | `Purpose__c` | `'Tracking'` |
  | `consentLog_status` | `Status__c` | `'Opt In'` (with space) |

### 2. `userProfiling` (Engagement, **CUSTOM DMO**)
- **Source DLO**: `skywave_app_Behavioral_Events_*__dll`, **filtered to `eventType='userProfiling'`**.
- **Target DMO**: **`Survey_Response__dlm`** (custom — we create it).
- **Why custom**: There is no standard DMO for "answered survey question X with answer Y." We need this DMO so the agent's RTDG can grab the survey answers as a related dimension off the unified Individual.
- **DMO field schema**:

  | DMO field | Type | Source field | Notes |
  |---|---|---|---|
  | `Id__c` | Text | `eventId` | Primary key |
  | `EventDateTime__c` | DateTime | `dateTime` | When tapped |
  | `DeviceId__c` | Text | `deviceId` | Join key to `Individual` |
  | `SessionId__c` | Text | `sessionId` | Demo session correlation |
  | `QuestionKey__c` | Text | `userProfiling_attributesQuestionKey` | Stable key, e.g. `fav_destination` |
  | `QuestionText__c` | Text | `userProfiling_attributesQuestion` | Full text — agent reads verbatim |
  | `AnswerKey__c` | Text | `userProfiling_attributesAnswerKey` | Stable key, e.g. `tyo` |
  | `AnswerText__c` | Text | `userProfiling_attributesAnswer` | Full text — agent reads verbatim |

  Adding `__dlm` is the standard suffix; the create call we make uses `Survey_Response` as the developer name.

### 3. `catalog` (Engagement)
- **Source DLO**: `skywave_app_Behavioral_Events_*__dll`, **filtered to `eventType='catalog'`**.
- **Target DMO**: `EngagementInteraction__dlm` (Salesforce-standard).
- **Why standard**: Browse/view tracking is exactly what `EngagementInteraction` exists for. The agent and downstream personalization features expect catalog views to land here.
- **Field-level mapping**:

  | DLO field | DMO field | Notes |
  |---|---|---|
  | `eventId` | `Id__c` | Primary key |
  | `dateTime` | `EventDateTime__c` | When viewed |
  | `deviceId` | `DeviceId__c` | Anonymous identifier |
  | `sessionId` | `SessionId__c` | Browser session |
  | `catalog_id` | `EngagementId__c` | The thing viewed (e.g. `amenity:lounge`) |
  | `catalog_type` | `EngagementType__c` | The noun (e.g. `Amenity`) |
  | `catalog_interactionName` | `InteractionName__c` | e.g. `View Catalog Object` |
  | `catalog_sourceUrl` | `SourceUrl__c` | URL where viewed |
  | `catalog_sourcePageType` | `PageType__c` | Sitemap-resolved page type |

### 4. `contactPointEmail` (Profile, IR-substrate)
- **Source DLO**: `skywave_app_contactPointEmail_*__dll` (1:1, no filter).
- **Target DMO**: **`ContactPointEmail__dlm`** (Salesforce-standard, IR exact-match target A).
- **Why standard**: This DMO **must** be standard. The IR ruleset's "match on email" rule reads `ContactPointEmail__dlm.EmailAddress__c` exactly. The CRM connector also lands Contact emails into this same standard DMO. Custom would break IR.
- **Field-level mapping**:

  | DLO field | DMO field | Notes |
  |---|---|---|
  | `deviceId` | `Id__c` | Primary key (we use deviceId per SDK convention) |
  | `eventId` | `EventId__c` | |
  | `dateTime` | `EventDateTime__c` | When captured |
  | `email` | `EmailAddress__c` | **The IR exact-match field** |
  | `sessionId` | `SessionId__c` | |

### 5. `contactPointPhone` (Profile, IR-substrate)
- **Source DLO**: not yet created — we don't fire `contactPointPhone` in v1.
- **Target DMO**: **`ContactPointPhone__dlm`** (Salesforce-standard).
- **Why standard**: Same reason as email — IR rules match against the standard DMO.
- **Note for v1**: We don't fire `contactPointPhone` yet (profile form doesn't capture phone). Mapping is documented now so we don't have to revisit when phone is added in v2.
- **Field-level mapping**:

  | DLO field | DMO field |
  |---|---|
  | `deviceId` | `Id__c` |
  | `eventId` | `EventId__c` |
  | `dateTime` | `EventDateTime__c` |
  | `phoneNumber` | `TelephoneNumber__c` |
  | `sessionId` | `SessionId__c` |

### 6. `partyIdentification` (Profile, IR-substrate)
- **Source DLO**: `skywave_app_partyIdentification_*__dll` (1:1, no filter).
- **Target DMO**: **`PartyIdentification__dlm`** (Salesforce-standard, IR exact-match target B).
- **Why standard**: This DMO is the join-key table for IR. The CRM connector lands `Contact.Id` into it from the CRM side; we land the same value from the browser side via the SDK. Exact-match on `PartyIdentificationId__c` (which holds the `userId` value) is what merges browser and CRM Individuals.
- **Field-level mapping**:

  | DLO field | DMO field | Notes |
  |---|---|---|
  | `deviceId` | `Id__c` | Primary key |
  | `eventId` | `EventId__c` | |
  | `dateTime` | `EventDateTime__c` | |
  | `IDName` | `PartyIdentificationName__c` | We always send `'SkywaveContactId'` |
  | `IDType` | `PartyIdentificationType__c` | We always send `'CRM'` |
  | `userId` | `PartyIdentificationId__c` | **The IR exact-match field** — Contact.Id |
  | `sessionId` | `SessionId__c` | |

### 7. `identity` (Profile, the "isAnonymous flip")
- **Source DLO**: `skywave_app_identity_*__dll` (1:1, no filter).
- **Target DMO**: **`Individual__dlm`** (Salesforce-standard).
- **Why standard**: `Individual` is the root DMO of the entire Customer Data Model. The IR ruleset publishes the Unified Individual to this same DMO. The CRM connector lands `Contact` rows here too. The Real-Time Data Graph's root node is `Individual`. Custom would isolate us from everything Data Cloud ships.
- **Note**: The `identity` event populates `Individual` only. It does **not** populate `ContactPointEmail`, `ContactPointPhone`, or `PartyIdentification` — even though the SDK lets you put email/phone fields on the identity event. The four-event burst (this + the three contact-point/party events) is what the docs call the IR-friendly pattern.
- **Field-level mapping**:

  | DLO field | DMO field | Notes |
  |---|---|---|
  | `deviceId` | `Id__c` | Primary key on browser side; CRM side uses ContactId |
  | `eventId` | `EventId__c` | |
  | `dateTime` | `EventDateTime__c` | |
  | `isAnonymous` | `IsAnonymous__c` | String `'0'` / `'1'` |
  | `firstName` | `FirstName__c` | |
  | `lastName` | `LastName__c` | |
  | `email` | (skip) | Email goes through `contactPointEmail` event/DMO. Map here too only if you want a denormalized copy. v1 = skip. |
  | `phoneNumber` | (skip) | Same reasoning as email. v1 = skip. |
  | address fields | (skip) | Address goes through `contactPointAddress`. v1 = skip — we don't capture address. |
  | `sessionId` | `SessionId__c` | |

## Identity Resolution ruleset (post-mapping)

After all 7 mappings are in place, the IR ruleset:

- **Match rules** (both must be exact for RTDG):
  - Rule A — exact match `ContactPointEmail__dlm.EmailAddress__c`
  - Rule B — exact match `PartyIdentification__dlm.PartyIdentificationId__c`
- **Reconciliation rules**:
  - Most-recent-wins on `Individual` first/last name
  - Most-recent-wins on `ContactPointEmail.EmailAddress__c`

Either match rule alone is enough to merge a browser-side Individual into the CRM Contact-derived Unified Individual. Both is robust.

## Real-Time Data Graph (post-IR)

Root: `Unified Individual`. Related dimensions:

- `Survey_Response__dlm` (browser-side, our custom DMO) — gives the agent the survey answers
- `EngagementInteraction__dlm` (browser-side) — gives the agent the browse/catalog history
- `ContactPointEmail__dlm`, `ContactPointPhone__dlm` (mixed CRM+browser) — for context/personalization
- `Contact` (CRM-side, via the standard CRM DMO chain) — name, mileage tier, etc.
- `Reservation__c` / `Flight__c` (CRM-side) — the agent will need these for stage 3 booking

## Order of operations

1. **You finish creating data streams + DLOs in the Web Connector UI.** Six DLOs land: `<connector>_consentLog`, `<connector>_userProfiling`, `<connector>_catalog`, `<connector>_contactPointEmail`, `<connector>_partyIdentification`, `<connector>_identity`.
2. **Confirm standard DMOs exist on `si`.** The list above assumes `ConsentLog__dlm`, `EngagementInteraction__dlm`, `ContactPointEmail__dlm`, `ContactPointPhone__dlm`, `PartyIdentification__dlm`, `Individual__dlm` are present. They should be — they ship with Data Cloud. We verify before we map.
3. **Create `Survey_Response__dlm` custom DMO.** Only one custom DMO in this whole plan.
4. **Create the 7 DLO → DMO mappings** as listed.
5. **Create the IR ruleset** with the two exact-match rules above. Mark it as a real-time ruleset.
6. **Create the Real-Time Data Graph** rooted on Unified Individual, joining the related DMOs.
7. **Verify** with a test session: tap survey on the consumer site, then query the data graph for that deviceId. We expect to see the survey answers. After Phase 4 (profile creation), we expect the unified individual to also pull in the matching CRM Contact.

## Things this plan does NOT do

- We do **not** create custom DMOs for `consentLog`, `catalog`, `contactPointEmail`, `contactPointPhone`, `partyIdentification`, `identity`. All mapped to standards.
- We do **not** put email or phone fields from the `identity` event into the contact-point DMOs. The SDK's design says contact-point DMOs are populated by their own dedicated events.
- We do **not** include any e-commerce events (`cart`, `cartItem`, `order`, `orderItem`). They're not in our schema.
- We do **not** include `contactPointAddress` or `contactPointPhone` mappings as v1 active mappings — we don't fire these yet. Their target DMOs are noted for future reference.

## What I want you to verify before I execute

1. The seven target DMOs in the table — do all the standard ones exist on `si`? You can check Setup → Data Cloud → Data Model.
2. The custom `Survey_Response__dlm` shape — those four custom field names (`QuestionKey`, `QuestionText`, `AnswerKey`, `AnswerText`) plus the four standard infra fields. Anything you want named differently?
3. The IR ruleset choice — exact-match on `ContactPointEmail.EmailAddress__c` AND `PartyIdentification.PartyIdentificationId__c`. Either-or, not both-required.
4. Standard DMO field names — Salesforce standard DMOs have specific field names like `EmailAddress__c`, `PartyIdentificationId__c`. I've used what the docs say but the actual `si` DMOs might have slightly different names. We verify with a `d360_dmo_get` call before mapping.
