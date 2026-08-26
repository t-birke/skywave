"""
STDM Ingestion-API source definitions (Path 5) for the Skywave hero sessions.

For each STDM object the generator emits, this declares:
  * object   — the IngestApi schema object name (== the generator CSV name)
  * pk       — primary key field
  * cols     — CSV columns (== DLO schema field names)
  * datetimes — which cols are DateTime-typed
  * category — DLO category; MUST equal the target DMO's category or the mapping 400s
  * dmo      — the canonical ssot__AiAgent*__dlm this DLO maps to
  * map      — [(dloField, ssot__Target__c)] DLO->DMO field pairs

Copied verbatim from the proven pronto reference implementation
(~/dev/pronto/observability/spec/stdm_schema.py). The field maps carry pronto's
hard-won corrections (TelemetryTraceId/SpanId, ParticipantAttributeText,
PrevStepId, dropped AgentId, omitted Boolean IsActive). Categories + target
field api names are consistent across STDM orgs; re-verify in a new org with
GET /ssot/metadata?entityType=DataModelObject&entityName=<dmo> if a mapping 400s.

Every object maps Id -> ssot__Id__c AND ExternalSourceId -> ssot__ExternalSourceId__c
(the latter is the Analytics-tab render gate).
"""

DT_TEXT, DT_DATETIME = "Text", "DateTime"


def _fields(cols, datetimes):
    return [(c, DT_DATETIME if c in datetimes else DT_TEXT) for c in cols]


CATEGORY = {
    "AiAgentSession": "Profile",
    "AiAgentSessionParticipant": "Engagement",
    "AiAgentInteraction": "Engagement",
    "AiAgentInteractionMessage": "Engagement",
    "AiAgentInteractionStep": "Profile",
    "AiAgentMoment": "Engagement",
    "AiAgentMomentInteraction": "Engagement",
    "AiAgentTagDefinition": "Related",
    "AiAgentTagDefinitionAssociation": "Related",
    "AiAgentTag": "Related",
    "AiAgentTagAssociation": "Engagement",
}
EVENT_TIME = {   # only for Engagement-category objects
    "AiAgentSessionParticipant": "StartTimestamp",
    "AiAgentInteraction": "StartTimestamp",
    "AiAgentInteractionMessage": "MessageSentTimestamp",
    "AiAgentMoment": "StartTimestamp",
    "AiAgentMomentInteraction": "StartTimestamp",
    "AiAgentTagAssociation": "CreatedDate",
}

# Short stream-name bases (the materialized stream name "<base>_<event>_<hash>"
# overflows the platform limit for long object names). Connection name (==
# sourceName) stays the full object name; only the stream base is shortened.
STREAM_BASE = {
    "AiAgentSession": "Skywave_Hero_Session",
    "AiAgentSessionParticipant": "Skywave_Hero_SessPart",
    "AiAgentInteraction": "Skywave_Hero_Interaction",
    "AiAgentInteractionMessage": "Skywave_Hero_IntMsg",
    "AiAgentInteractionStep": "Skywave_Hero_IntStep",
    "AiAgentMoment": "Skywave_Hero_Moment",
    "AiAgentMomentInteraction": "Skywave_Hero_MomInt",
    "AiAgentTagDefinition": "Skywave_Hero_TagDef",
    "AiAgentTagDefinitionAssociation": "Skywave_Hero_TagDefAssoc",
    "AiAgentTag": "Skywave_Hero_Tag",
    "AiAgentTagAssociation": "Skywave_Hero_TagAssoc",
}

OBJECTS = [
    {
        "object": "AiAgentSession",
        "pk": "Id",
        "cols": ["Id", "AiAgentChannelType", "AiAgentSessionEndType", "StartTimestamp",
                 "EndTimestamp", "IndividualId", "PreviousSessionId", "SessionOwnerObject",
                 "VariableText", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["StartTimestamp", "EndTimestamp"],
        "dmo": "ssot__AiAgentSession__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentChannelType", "ssot__AiAgentChannelType__c"),
            ("AiAgentSessionEndType", "ssot__AiAgentSessionEndType__c"),
            ("StartTimestamp", "ssot__StartTimestamp__c"),
            ("EndTimestamp", "ssot__EndTimestamp__c"),
            ("IndividualId", "ssot__IndividualId__c"),
            ("PreviousSessionId", "ssot__PreviousSessionId__c"),
            ("SessionOwnerObject", "ssot__SessionOwnerObject__c"),
            ("VariableText", "ssot__VariableText__c"),
        ],
    },
    {
        "object": "AiAgentSessionParticipant",
        "pk": "Id",
        "cols": ["Id", "AiAgentSessionId", "AiAgentApiName", "AiAgentVersionApiName",
                 "AiAgentTemplateApiName", "AiAgentType", "AiAgentSessionParticipantRole",
                 "ParticipantId", "ParticipantObject", "ParticipantAttributes",
                 "StartTimestamp", "EndTimestamp", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["StartTimestamp", "EndTimestamp"],
        "dmo": "ssot__AiAgentSessionParticipant__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentSessionId", "ssot__AiAgentSessionId__c"),
            ("AiAgentApiName", "ssot__AiAgentApiName__c"),
            ("AiAgentVersionApiName", "ssot__AiAgentVersionApiName__c"),
            ("AiAgentTemplateApiName", "ssot__AiAgentTemplateApiName__c"),
            ("AiAgentType", "ssot__AiAgentType__c"),
            ("AiAgentSessionParticipantRole", "ssot__AiAgentSessionParticipantRole__c"),
            ("ParticipantId", "ssot__ParticipantId__c"),
            ("ParticipantObject", "ssot__ParticipantObject__c"),
            ("ParticipantAttributes", "ssot__ParticipantAttributeText__c"),
            ("StartTimestamp", "ssot__StartTimestamp__c"),
            ("EndTimestamp", "ssot__EndTimestamp__c"),
        ],
    },
    {
        "object": "AiAgentInteraction",
        "pk": "Id",
        "cols": ["Id", "AiAgentSessionId", "TopicApiName", "AiAgentInteractionType",
                 "SessionOwnerId", "SessionOwnerObject", "StartTimestamp", "EndTimestamp",
                 "TraceId", "SpandId", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["StartTimestamp", "EndTimestamp"],
        "dmo": "ssot__AiAgentInteraction__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentSessionId", "ssot__AiAgentSessionId__c"),
            ("TopicApiName", "ssot__TopicApiName__c"),
            ("AiAgentInteractionType", "ssot__AiAgentInteractionType__c"),
            ("SessionOwnerId", "ssot__SessionOwnerId__c"),
            ("SessionOwnerObject", "ssot__SessionOwnerObject__c"),
            ("StartTimestamp", "ssot__StartTimestamp__c"),
            ("EndTimestamp", "ssot__EndTimestamp__c"),
            ("TraceId", "ssot__TelemetryTraceId__c"),
            ("SpandId", "ssot__TelemetryTraceSpanId__c"),
        ],
    },
    {
        "object": "AiAgentInteractionMessage",
        "pk": "Id",
        "cols": ["Id", "AiAgentSessionId", "AiAgentInteractionId", "AiAgentSessionParticipantId",
                 "AiAgentInteractionMessageType", "AiAgentInteractionMsgContentType",
                 "ContentText", "MessageSentTimestamp", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["MessageSentTimestamp"],
        "dmo": "ssot__AiAgentInteractionMessage__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentSessionId", "ssot__AiAgentSessionId__c"),
            ("AiAgentInteractionId", "ssot__AiAgentInteractionId__c"),
            ("AiAgentSessionParticipantId", "ssot__AiAgentSessionParticipantId__c"),
            ("AiAgentInteractionMessageType", "ssot__AiAgentInteractionMessageType__c"),
            ("AiAgentInteractionMsgContentType", "ssot__AiAgentInteractionMsgContentType__c"),
            ("ContentText", "ssot__ContentText__c"),
            ("MessageSentTimestamp", "ssot__MessageSentTimestamp__c"),
        ],
    },
    {
        "object": "AiAgentInteractionStep",
        "pk": "id",
        "cols": ["id", "aiAgentInteractionId", "AiAgentInteractionStepType", "name",
                 "inputValueText", "outputValueText", "startTimestamp", "endTimestamp",
                 "prevStepId", "errorMessageText", "attributeText", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["startTimestamp", "endTimestamp"],
        "dmo": "ssot__AiAgentInteractionStep__dlm",
        "map": [
            ("id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("aiAgentInteractionId", "ssot__AiAgentInteractionId__c"),
            ("AiAgentInteractionStepType", "ssot__AiAgentInteractionStepType__c"),
            ("name", "ssot__Name__c"),
            ("inputValueText", "ssot__InputValueText__c"),
            ("outputValueText", "ssot__OutputValueText__c"),
            ("startTimestamp", "ssot__StartTimestamp__c"),
            ("endTimestamp", "ssot__EndTimestamp__c"),
            ("prevStepId", "ssot__PrevStepId__c"),
            ("errorMessageText", "ssot__ErrorMessageText__c"),
            ("attributeText", "ssot__AttributeText__c"),
        ],
    },
    {
        "object": "AiAgentMoment",
        "pk": "Id",
        "cols": ["Id", "AiAgentSessionId", "AiAgentApiName", "AiAgentVersionApiName",
                 "RequestSummaryText", "ResponseSummaryText", "StartTimestamp",
                 "EndTimestamp", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["StartTimestamp", "EndTimestamp"],
        "dmo": "ssot__AiAgentMoment__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentSessionId", "ssot__AiAgentSessionId__c"),
            ("AiAgentApiName", "ssot__AiAgentApiName__c"),
            ("AiAgentVersionApiName", "ssot__AiAgentVersionApiName__c"),
            ("RequestSummaryText", "ssot__RequestSummaryText__c"),
            ("ResponseSummaryText", "ssot__ResponseSummaryText__c"),
            ("StartTimestamp", "ssot__StartTimestamp__c"),
            ("EndTimestamp", "ssot__EndTimestamp__c"),
        ],
    },
    {
        "object": "AiAgentMomentInteraction",
        "pk": "Id",
        "cols": ["Id", "AiAgentMomentId", "AiAgentInteractionId", "StartTimestamp",
                 "DataSourceId", "ExternalSourceId"],
        "datetimes": ["StartTimestamp"],
        "dmo": "ssot__AiAgentMomentInteraction__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentMomentId", "ssot__AiAgentMomentId__c"),
            ("AiAgentInteractionId", "ssot__AiAgentInteractionId__c"),
            ("StartTimestamp", "ssot__StartTimestamp__c"),
        ],
    },
    {
        "object": "AiAgentTagDefinition",
        "pk": "Id",
        "cols": ["Id", "Name", "DeveloperName", "DataType", "SourceType", "Status",
                 "Description", "CreatedDate", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["CreatedDate"],
        "dmo": "ssot__AiAgentTagDefinition__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("Name", "ssot__Name__c"),
            ("DeveloperName", "ssot__DeveloperName__c"),
            ("DataType", "ssot__DataType__c"),
            ("SourceType", "ssot__SourceType__c"),
            ("Status", "ssot__Status__c"),
            ("Description", "ssot__Description__c"),
            ("CreatedDate", "ssot__CreatedDate__c"),
        ],
    },
    {
        "object": "AiAgentTagDefinitionAssociation",
        "pk": "Id",
        "cols": ["Id", "AiAgentApiName", "AiAgentTagDefinitionId", "IsActive",
                 "CreatedDate", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["CreatedDate"],
        "dmo": "ssot__AiAgentTagDefinitionAssociation__dlm",
        # IsActive omitted — ssot__IsActive__c is Boolean, IngestApi carries Text
        # (type mismatch 400s the mapping); not needed to render.
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentApiName", "ssot__AiAgentApiName__c"),
            ("AiAgentTagDefinitionId", "ssot__AiAgentTagDefinitionId__c"),
            ("CreatedDate", "ssot__CreatedDate__c"),
        ],
    },
    {
        "object": "AiAgentTag",
        "pk": "Id",
        "cols": ["Id", "AiAgentTagDefinitionId", "Value", "Description", "IsActive",
                 "CreatedDate", "DataSourceId", "ExternalSourceId"],
        "datetimes": ["CreatedDate"],
        "dmo": "ssot__AiAgentTag__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentTagDefinitionId", "ssot__AiAgentTagDefinitionId__c"),
            ("Value", "ssot__Value__c"),
            ("Description", "ssot__Description__c"),
            ("CreatedDate", "ssot__CreatedDate__c"),
        ],
    },
    {
        "object": "AiAgentTagAssociation",
        "pk": "Id",
        # ValueText + SourceType mirror the real analyzer output: the Optimization/
        # Analytics KPIs (Engagement/Success/etc.) read the denormalized ValueText__c
        # (score value: "0".."5", "true"/"false") and SourceType__c='PROMPT_TEMPLATE',
        # NOT the joined tag-row value. Without them the associations are invisible
        # to those metrics (they only saw the ~real analyzer-scored sessions).
        "cols": ["Id", "AiAgentSessionId", "AiAgentMomentId", "AiAgentTagId",
                 "AiAgentTagDefinitionAssociationId", "AssociationReasonText", "ValueText",
                 "SourceType", "AiAgentSessionStartTimestamp", "CreatedDate", "DataSourceId",
                 "ExternalSourceId"],
        "datetimes": ["AiAgentSessionStartTimestamp", "CreatedDate"],
        "dmo": "ssot__AiAgentTagAssociation__dlm",
        "map": [
            ("Id", "ssot__Id__c"),
            ("ExternalSourceId", "ssot__ExternalSourceId__c"),
            ("AiAgentSessionId", "ssot__AiAgentSessionId__c"),
            ("AiAgentMomentId", "ssot__AiAgentMomentId__c"),
            ("AiAgentTagId", "ssot__AiAgentTagId__c"),
            ("AiAgentTagDefinitionAssociationId", "ssot__AiAgentTagDefinitionAssociationId__c"),
            ("AssociationReasonText", "ssot__AssociationReasonText__c"),
            ("ValueText", "ValueText__c"),
            ("SourceType", "SourceType__c"),
            ("AiAgentSessionStartTimestamp", "AiAgentSessionStartTimestamp__c"),
            ("CreatedDate", "ssot__CreatedDate__c"),
        ],
    },
]


def schema_fields(o):
    return _fields(o["cols"], o["datetimes"])
