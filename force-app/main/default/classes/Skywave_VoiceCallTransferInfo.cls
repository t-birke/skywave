public with sharing class Skywave_VoiceCallTransferInfo {

    @AuraEnabled(cacheable=true)
    public static Datetime getTransferDateTime(Id voiceCallId) {
        if (voiceCallId == null) {
            return null;
        }
        List<AgentWork> works = [
            SELECT CloseDateTime
            FROM AgentWork
            WHERE WorkItemId = :voiceCallId
              AND BotId != null
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        return works.isEmpty() ? null : works[0].CloseDateTime;
    }
}