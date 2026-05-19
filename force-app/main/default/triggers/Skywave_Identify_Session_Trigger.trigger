/**
 * Receives Skywave_Identify_Session__e events published by the Sites
 * guest user (Skywave_SessionIdentify Apex REST endpoint, called from the
 * consumer site's onEmbeddedMessagingConversationStarted handler).
 *
 * Runs in System Mode (the Apex platform default for triggers on
 * Platform Events) — no FLS or sharing constraints, no integration-user
 * licensing concerns. Looks up the MessagingSession by ConversationId
 * and stamps Session_ID__c.
 *
 * Idempotent: skip the update if the field is already populated to the
 * same value. The integration with the consumer site fires once per
 * conversation start, but defensive against duplicates.
 *
 * Race-safe: when the consumer site posts immediately after
 * onEmbeddedMessagingConversationStarted, the MessagingSession may not
 * yet be readable. The trigger doesn't retry; if the row isn't there, we
 * accept the loss for that conversation. (For tonight's smoke test the
 * 5s delay added on the JS side gives Salesforce enough time to commit
 * and propagate. If we observe drops, switch to a queueable retry.)
 */
trigger Skywave_Identify_Session_Trigger on Skywave_Identify_Session__e (after insert) {
    Set<String> conversationIds = new Set<String>();
    Map<String, String> sessionIdByConversation = new Map<String, String>();
    for (Skywave_Identify_Session__e ev : Trigger.new) {
        if (String.isBlank(ev.Conversation_Id__c) || String.isBlank(ev.Session_Id__c)) continue;
        conversationIds.add(ev.Conversation_Id__c);
        sessionIdByConversation.put(ev.Conversation_Id__c, ev.Session_Id__c);
    }
    if (conversationIds.isEmpty()) return;

    List<MessagingSession> toUpdate = new List<MessagingSession>();
    for (MessagingSession ms : [
        SELECT Id, ConversationId, Session_ID__c
        FROM MessagingSession
        WHERE ConversationId IN :conversationIds
    ]) {
        String desired = sessionIdByConversation.get(ms.ConversationId);
        if (ms.Session_ID__c != desired) {
            ms.Session_ID__c = desired;
            toUpdate.add(ms);
        }
    }
    if (!toUpdate.isEmpty()) {
        update toUpdate;
    }
}
