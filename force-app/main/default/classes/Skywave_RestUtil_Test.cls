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
}
