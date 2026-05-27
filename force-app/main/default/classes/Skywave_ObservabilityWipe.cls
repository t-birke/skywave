/**
 * Top-level Batchable that wipes the SDO_Agentforce_Observability QBrix
 * custom-object tables in dependency order.
 *
 * Lifted out of Skywave_ObservabilitySeeder because Apex requires
 * Database.Batchable to be a top-level class. Chains across all 11
 * tables; finish() re-executes itself with the next object until
 * the list is exhausted (~5 minutes elapsed for the full ~50K rows).
 *
 * Run:
 *   Database.executeBatch(new Skywave_ObservabilityWipe(), 2000);
 */
public with sharing class Skywave_ObservabilityWipe
        implements Database.Batchable<SObject>, Database.Stateful {

    // Children first; matches Skywave_ObservabilitySeeder.WipeJob's old order.
    private final List<String> objectsToWipe = new List<String>{
        'SDO_Analytics_AIAgentMomentInteractio_v2__c',
        'SDO_Analytics_AIAgentMoment_v2__c',
        'SDO_Analytics_AIAgentTagAssociation_v2__c',
        'SDO_Analytics_AIAgentTagDefinitionAss_v2__c',
        'SDO_Analytics_AIAgentTag_v2__c',
        'SDO_Analytics_AIAgentTagDefinition_v2__c',
        'SDO_Analytics_AIAgentInteractionStep_v2__c',
        'SDO_Analytics_AIAgentInteractionMessa_v2__c',
        'SDO_Analytics_AiAgentInteraction_v2__c',
        'SDO_Analytics_AIAgentSessionParticipa_v2__c',
        'SDO_Analytics_AIAgentSession_v2__c'
    };
    private Integer cursor = 0;

    public Database.QueryLocator start(Database.BatchableContext bc) {
        String obj = objectsToWipe[cursor];
        return Database.getQueryLocator('SELECT Id FROM ' + obj);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        if (!scope.isEmpty()) {
            Database.delete(scope, false);
        }
    }

    public void finish(Database.BatchableContext bc) {
        cursor++;
        if (cursor < objectsToWipe.size()) {
            // Chain into the next table.
            Database.executeBatch(this, 2000);
        } else {
            System.debug('Skywave_ObservabilityWipe: complete');
        }
    }
}
