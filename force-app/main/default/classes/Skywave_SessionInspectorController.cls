/**
 * Apex backing for the skywaveSessionInspector LWC.
 *
 * Given a session id (the SDO External_ID__c on
 * SDO_Analytics_AIAgentSession_v2__c — i.e. the same value that surfaces
 * as ssot__Id__c on the AiAgentSession DMO), returns the full graph of
 * related observability records — session, participants, interactions,
 * messages, steps, moments, moment-interactions, tags and tag associations
 * — with every field on each object, so a presenter can eyeball exactly
 * what was seeded/ingested for one conversation.
 *
 * Describe-driven: it returns ALL custom (__c) fields per object so the UI
 * never has to be updated when the SDO schema changes.
 */
public with sharing class Skywave_SessionInspectorController {

    // One object's worth of related rows + the field order to render.
    public class ObjectGroup {
        @AuraEnabled public String objectApiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Integer recordCount { get; set; }
        @AuraEnabled public List<String> fields { get; set; }       // field api names, ordered
        @AuraEnabled public List<String> fieldLabels { get; set; }  // matching labels
        @AuraEnabled public List<Map<String, Object>> records { get; set; }
    }

    public class SessionGraph {
        @AuraEnabled public String sessionId { get; set; }
        @AuraEnabled public Boolean found { get; set; }
        @AuraEnabled public List<ObjectGroup> groups { get; set; }
    }

    // The SDO objects that make up a session graph, with the field that ties
    // each back to the session (or, for steps, to the interaction).
    private static final List<String> SESSION_OBJECTS = new List<String>{
        'SDO_Analytics_AIAgentSession_v2__c',
        'SDO_Analytics_AIAgentSessionParticipa_v2__c',
        'SDO_Analytics_AiAgentInteraction_v2__c',
        'SDO_Analytics_AIAgentInteractionMessa_v2__c',
        'SDO_Analytics_AIAgentMoment_v2__c',
        'SDO_Analytics_AIAgentMomentInteractio_v2__c'
    };

    /**
     * Returns the full related graph for one session id.
     */
    @AuraEnabled(cacheable=false)
    public static SessionGraph getSessionGraph(String sessionId) {
        SessionGraph g = new SessionGraph();
        g.sessionId = sessionId;
        g.groups = new List<ObjectGroup>();
        if (String.isBlank(sessionId)) {
            g.found = false;
            return g;
        }
        String sid = sessionId.trim();

        // 1. Session itself (keyed by External_ID__c).
        ObjectGroup sessionGroup = queryGroup(
            'SDO_Analytics_AIAgentSession_v2__c',
            'External_ID__c = :sid', new Map<String, Object>{ 'sid' => sid });
        g.found = sessionGroup.recordCount > 0;
        g.groups.add(sessionGroup);

        // 2. Direct children keyed by AI_Agent_Session__c.
        g.groups.add(queryGroup('SDO_Analytics_AIAgentSessionParticipa_v2__c',
            'AI_Agent_Session__c = :sid', new Map<String, Object>{ 'sid' => sid }));
        ObjectGroup interactions = queryGroup('SDO_Analytics_AiAgentInteraction_v2__c',
            'AI_Agent_Session__c = :sid', new Map<String, Object>{ 'sid' => sid });
        g.groups.add(interactions);
        g.groups.add(queryGroup('SDO_Analytics_AIAgentInteractionMessa_v2__c',
            'AI_Agent_Session__c = :sid', new Map<String, Object>{ 'sid' => sid }));
        g.groups.add(queryGroup('SDO_Analytics_AIAgentMoment_v2__c',
            'AI_Agent_Session__c = :sid', new Map<String, Object>{ 'sid' => sid }));

        // 3. Steps are keyed by interaction, not session — gather the
        //    interaction External_IDs first.
        Set<String> interactionIds = new Set<String>();
        for (Map<String, Object> rec : interactions.records) {
            Object v = rec.get('External_ID__c');
            if (v != null) interactionIds.add(String.valueOf(v));
        }
        g.groups.add(queryGroup('SDO_Analytics_AIAgentInteractionStep_v2__c',
            'AI_Agent_Interaction__c IN :interactionIds',
            new Map<String, Object>{ 'interactionIds' => interactionIds }));

        // 4. Moment-interactions keyed by the moment External_IDs.
        Set<String> momentIds = new Set<String>();
        for (ObjectGroup grp : g.groups) {
            if (grp.objectApiName == 'SDO_Analytics_AIAgentMoment_v2__c') {
                for (Map<String, Object> rec : grp.records) {
                    Object v = rec.get('External_ID__c');
                    if (v != null) momentIds.add(String.valueOf(v));
                }
            }
        }
        g.groups.add(queryGroup('SDO_Analytics_AIAgentMomentInteractio_v2__c',
            'AI_Agent_Moment_Id__c IN :momentIds',
            new Map<String, Object>{ 'momentIds' => momentIds }));

        return g;
    }

    /**
     * Query every custom field of an object for the given filter and pack
     * the rows into a render-ready ObjectGroup.
     */
    private static ObjectGroup queryGroup(String objectApiName, String whereClause, Map<String, Object> binds) {
        ObjectGroup grp = new ObjectGroup();
        grp.objectApiName = objectApiName;
        grp.fields = new List<String>();
        grp.fieldLabels = new List<String>();
        grp.records = new List<Map<String, Object>>();

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            grp.label = objectApiName;
            grp.recordCount = 0;
            return grp;
        }
        Schema.DescribeSObjectResult dsr = sot.getDescribe();
        grp.label = dsr.getLabel();

        // Ordered, accessible custom fields + Id/Name.
        Map<String, Schema.SObjectField> fieldMap = dsr.fields.getMap();
        List<String> queryFields = new List<String>{ 'Id' };
        Map<String, String> labelByApi = new Map<String, String>();
        for (String fname : fieldMap.keySet()) {
            Schema.DescribeFieldResult fdr = fieldMap.get(fname).getDescribe();
            if (!fdr.isAccessible()) continue;
            String api = fdr.getName();
            if (api == 'Id') { labelByApi.put('Id', 'Record Id'); continue; }
            // Show custom fields + the standard Name.
            if (api.endsWith('__c') || api == 'Name') {
                queryFields.add(api);
                labelByApi.put(api, fdr.getLabel());
            }
        }

        // Stable display order: External_ID first, then the rest alphabetical.
        List<String> displayFields = new List<String>();
        if (labelByApi.containsKey('External_ID__c')) displayFields.add('External_ID__c');
        if (labelByApi.containsKey('Name')) displayFields.add('Name');
        List<String> rest = new List<String>(labelByApi.keySet());
        rest.sort();
        for (String f : rest) {
            if (f != 'External_ID__c' && f != 'Name' && f != 'Id') displayFields.add(f);
        }
        for (String f : displayFields) {
            grp.fields.add(f);
            grp.fieldLabels.add(labelByApi.get(f));
        }

        String soql = 'SELECT ' + String.join(queryFields, ', ')
            + ' FROM ' + objectApiName + ' WHERE ' + whereClause
            + ' ORDER BY CreatedDate ASC LIMIT 500';
        List<SObject> rows = Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE);

        for (SObject row : rows) {
            Map<String, Object> flat = new Map<String, Object>();
            flat.put('Id', row.get('Id'));
            for (String f : displayFields) {
                Object val = row.get(f);
                flat.put(f, val == null ? '' : String.valueOf(val));
            }
            grp.records.add(flat);
        }
        grp.recordCount = grp.records.size();
        return grp;
    }
}
