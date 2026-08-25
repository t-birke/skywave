@IsTest
private class Skywave_RestUtil_Test {

    @TestSetup
    static void seed() {
        insert new Demo_Session__c(State__c='idle', Active__c=true, Started__c=System.now());
    }

    @IsTest
    static void getActiveDemoSessionId_returnsActive() {
        Id id = Skywave_RestUtil.getActiveDemoSessionId();
        System.assertNotEquals(null, id, 'Active demo session should exist');
    }

    @IsTest
    static void parseBody_handlesEmpty() {
        RestContext.request = new RestRequest();
        Map<String, Object> m = Skywave_RestUtil.parseBody();
        System.assertEquals(0, m.size());
    }

    @IsTest
    static void parseBody_parsesJson() {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf('{"a":1,"b":"x"}');
        Map<String, Object> m = Skywave_RestUtil.parseBody();
        System.assertEquals(1, m.get('a'));
        System.assertEquals('x', m.get('b'));
    }

    @IsTest
    static void publishEvent_doesNotThrow() {
        Id demoSessionId = Skywave_RestUtil.getActiveDemoSessionId();
        Test.startTest();
        Skywave_RestUtil.publishEvent('session_started', 'sess-1', demoSessionId, new Map<String, Object>{'ua'=>'test'});
        Test.stopTest();
    }

    @IsTest
    static void getDemoSessionId_usesSuppliedDs() {
        // A second (inactive) session — a valid `ds` must resolve to it directly,
        // not to the seeded active one.
        Demo_Session__c other = new Demo_Session__c(State__c='idle', Started__c=System.now());
        insert other;
        Id resolved = Skywave_RestUtil.getDemoSessionId(String.valueOf(other.Id));
        System.assertEquals(other.Id, resolved, 'A valid ds must be used directly');
    }

    @IsTest
    static void getActiveDemoSessionId_prefersConfiguredFallback() {
        // A curated (inactive) session pinned via config must win over the
        // newest-active session — the single-user walk-up guarantee.
        Demo_Session__c pinned = new Demo_Session__c(State__c='agent_seat_pass', Started__c=System.now());
        insert pinned;
        Skywave_DemoConfig.testFallbackId = pinned.Id;
        System.assertEquals(pinned.Id, Skywave_RestUtil.getActiveDemoSessionId(),
            'configured fallback session must be preferred over newest-active');
        System.assertEquals(pinned.Id, Skywave_RestUtil.getDemoSessionId(null),
            'no ds → configured fallback');
    }

    @IsTest
    static void getActiveDemoSessionId_stalePinFallsBackToActive() {
        // A configured id whose record no longer exists must degrade to newest-active.
        Demo_Session__c gone = new Demo_Session__c(State__c='idle', Started__c=System.now());
        insert gone;
        Id staleId = gone.Id;
        delete gone;
        Skywave_DemoConfig.testFallbackId = staleId;
        Id resolved = Skywave_RestUtil.getActiveDemoSessionId();
        System.assertNotEquals(null, resolved, 'must fall back to the seeded active session');
        System.assertNotEquals(staleId, resolved, 'stale pin must not be returned');
    }

    @IsTest
    static void demoConfig_cmdtReadDoesNotThrow() {
        // Exercises the live CMDT read path (value depends on org config).
        Skywave_DemoConfig.testFallbackId = null;
        Skywave_DemoConfig.fallbackDemoSessionId();
    }

    @IsTest
    static void getDemoSessionId_fallsBackWhenBlankOrGarbage() {
        Id active = Skywave_RestUtil.getActiveDemoSessionId();
        System.assertEquals(active, Skywave_RestUtil.getDemoSessionId(null), 'blank ds → active fallback');
        System.assertEquals(active, Skywave_RestUtil.getDemoSessionId(''), 'empty ds → active fallback');
        System.assertEquals(active, Skywave_RestUtil.getDemoSessionId('not-an-id'), 'garbage ds → active fallback');
        // A well-formed Id of the WRONG sobject type must also fall back.
        System.assertEquals(active, Skywave_RestUtil.getDemoSessionId(UserInfo.getUserId()), 'wrong-type id → active fallback');
    }
}
