/**
 * Config accessors for demo-session resolution, reading the shared
 * Skywave_Preflight_Config__mdt.Default record (same CMDT Skywave_HerokuConfig
 * reads). Kept separate from Skywave_HerokuConfig so origin config and
 * demo-session config stay cohesive.
 */
public with sharing class Skywave_DemoConfig {

    // Test seam: CMDT rows can't be inserted in unit tests, so tests set this
    // to exercise the "configured fallback" branch. Honored only under test.
    @TestVisible private static Id testFallbackId;

    /**
     * The curated walk-up fallback Demo_Session Id
     * (Skywave_Preflight_Config.Default.Fallback_Demo_Session_Id__c), or null
     * when unset/blank/malformed. Used by Skywave_RestUtil.getActiveDemoSessionId()
     * so a request with no `ds` tenant key (single-user demo hitting the site
     * directly) resolves to a reliable, presenter-curated session instead of
     * whichever session started most recently across ALL presenters.
     *
     * Returns the Id only if it is well-formed and of the Demo_Session__c type;
     * the CALLER is responsible for confirming the record still exists (so a
     * stale config silently degrades to the newest-active fallback rather than
     * resolving to a deleted id).
     */
    public static Id fallbackDemoSessionId() {
        if (Test.isRunningTest() && testFallbackId != null) return testFallbackId;

        List<Skywave_Preflight_Config__mdt> rows = [
            SELECT Fallback_Demo_Session_Id__c
            FROM Skywave_Preflight_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        if (rows.isEmpty() || String.isBlank(rows[0].Fallback_Demo_Session_Id__c)) return null;
        try {
            Id dsId = Id.valueOf(rows[0].Fallback_Demo_Session_Id__c.trim());
            return dsId.getSObjectType() == Demo_Session__c.SObjectType ? dsId : null;
        } catch (Exception e) {
            // Malformed value (e.g. an un-substituted install placeholder) — treat as unset.
            return null;
        }
    }
}
