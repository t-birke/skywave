public with sharing class SDO_Analytics_QuickAccessSession {

    @AuraEnabled(cacheable=true)
    public static String getAgentApiName(String externalId) {
        if (String.isBlank(externalId)) {
            return null;
        }

        try {
            // Query participant record to get AI Agent API Name
            List<SDO_Analytics_AIAgentSessionParticipa_v2__c> participants = [
                SELECT Id, AI_Agent_Api_Name__c
                FROM SDO_Analytics_AIAgentSessionParticipa_v2__c
                WHERE AI_Agent_Session__c = :externalId
                LIMIT 1
            ];

            if (!participants.isEmpty() && participants[0].AI_Agent_Api_Name__c != null) {
                return participants[0].AI_Agent_Api_Name__c;
            }

            return null;

        } catch (Exception e) {
            System.debug('Error retrieving Agent API Name: ' + e.getMessage());
            return null;
        }
    }
}
