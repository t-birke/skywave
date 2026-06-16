public with sharing class SDO_Analytics_SyntheticSessionSearch {

    @AuraEnabled
    public static String findSessionByExternalId(String externalId) {
        if (String.isBlank(externalId)) {
            throw new AuraHandledException('Please enter a UUID to search');
        }

        try {
            List<SDO_Analytics_AIAgentSession_v2__c> sessions = [
                SELECT Id, Name, External_ID__c
                FROM SDO_Analytics_AIAgentSession_v2__c
                WHERE External_ID__c = :externalId
                LIMIT 1
            ];

            if (sessions.isEmpty()) {
                throw new AuraHandledException('No session found with UUID: ' + externalId);
            }

            return sessions[0].Id;

        } catch (QueryException e) {
            throw new AuraHandledException('Error searching for session: ' + e.getMessage());
        }
    }
}
