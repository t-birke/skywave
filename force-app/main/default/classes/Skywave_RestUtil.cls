/**
 * Shared helpers for Skywave Interactive public REST endpoints.
 *
 * Why this exists: every endpoint needs (a) the active Demo_Session__c id
 * (b) JSON body parsing (c) a consistent error envelope. Centralizing keeps
 * each endpoint short and lets us evolve the envelope in one place.
 */
public without sharing class Skywave_RestUtil {

    /**
     * Returns the Demo_Session__c Id a request falls back to when it carries no
     * `ds` tenant key (legacy QR / direct visit / single-tenant install), or
     * null if none resolves.
     *
     * Resolution order:
     *   1. The configured walk-up fallback
     *      (Skywave_Preflight_Config.Default.Fallback_Demo_Session_Id__c), when
     *      set AND the record still exists. Most presenters run a single-user
     *      demo and just hit app.skywave.flights with no `ds`; pinning that
     *      case to a curated session (e.g. one kept at agent_seat_pass) makes
     *      the walk-up experience reliable instead of resolving to whichever
     *      session started most recently across ALL presenters.
     *   2. Otherwise the most-recently-started active session (the legacy
     *      behavior) — so fresh installs / single-tenant orgs that never
     *      configure a fallback are unaffected.
     */
    public static Id getActiveDemoSessionId() {
        Id pinned = Skywave_DemoConfig.fallbackDemoSessionId();
        if (pinned != null) {
            List<Demo_Session__c> cfg = [
                SELECT Id FROM Demo_Session__c WHERE Id = :pinned LIMIT 1
            ];
            if (!cfg.isEmpty()) return cfg[0].Id;
            // Configured id no longer exists (reseed / delete) — fall through.
        }
        List<Demo_Session__c> active = [
            SELECT Id FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        return active.isEmpty() ? null : active[0].Id;
    }

    /**
     * Multi-tenant resolver: returns the Demo_Session__c the caller is scoped
     * to. The consumer site carries the tenant key as `ds` (the Demo_Session
     * Id) on every request — stamped into the QR the presenter shows. A valid
     * `ds` is used directly; otherwise we fall back to the global
     * most-recent-active session, so legacy QRs / direct visits and
     * single-tenant installs keep working.
     */
    public static Id getDemoSessionId(String suppliedDs) {
        if (String.isNotBlank(suppliedDs)) {
            try {
                Id dsId = Id.valueOf(suppliedDs);
                if (dsId.getSObjectType() == Demo_Session__c.SObjectType) {
                    List<Demo_Session__c> rows = [
                        SELECT Id FROM Demo_Session__c WHERE Id = :dsId LIMIT 1
                    ];
                    if (!rows.isEmpty()) return rows[0].Id;
                }
            } catch (Exception e) {
                // Malformed id — fall through to the active-session fallback.
            }
        }
        return getActiveDemoSessionId();
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
