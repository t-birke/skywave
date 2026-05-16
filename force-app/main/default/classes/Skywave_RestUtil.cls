/**
 * Shared helpers for Skywave Interactive public REST endpoints.
 *
 * Why this exists: every endpoint needs (a) the active Demo_Session__c id
 * (b) JSON body parsing (c) a consistent error envelope. Centralizing keeps
 * each endpoint short and lets us evolve the envelope in one place.
 */
public without sharing class Skywave_RestUtil {

    /**
     * Returns the Id of the singleton Active Demo_Session__c, or null if none.
     * Single-tenant by design (see SKYWAVE_INTERACTIVE_DESIGN.md §13a).
     */
    public static Id getActiveDemoSessionId() {
        List<Demo_Session__c> active = [
            SELECT Id FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        return active.isEmpty() ? null : active[0].Id;
    }

    /**
     * Parses the current REST request body as JSON into a Map.
     * Returns an empty map if body is null/empty.
     */
    public static Map<String, Object> parseBody() {
        Blob body = RestContext.request.requestBody;
        if (body == null || body.size() == 0) {
            return new Map<String, Object>();
        }
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(body.toString());
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    /**
     * Publish a Demo_Event__e on the data-plane channel.
     * payload is JSON-serialized to Payload_Json__c.
     */
    public static void publishEvent(String type, String sessionId, Id demoSessionId, Map<String, Object> payload) {
        Demo_Event__e e = new Demo_Event__e(
            Type__c = type,
            Session_Id__c = sessionId,
            Demo_Session_Id__c = demoSessionId,
            Payload_Json__c = (payload == null) ? '{}' : JSON.serialize(payload)
        );
        EventBus.publish(e);
    }
}
