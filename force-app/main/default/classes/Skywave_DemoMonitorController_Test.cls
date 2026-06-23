/**
 * Covers the multi-tenant behaviour of Skywave_DemoMonitorController:
 * owner-scoped create/select/activate and the unique Active_Owner_Key__c guard.
 * Cross-owner isolation (two presenters) is exercised in
 * Skywave_MultiTenant_Test.
 */
@IsTest
private class Skywave_DemoMonitorController_Test {

    @IsTest
    static void createSession_activate_makesItTheOwnersActive() {
        Test.startTest();
        Skywave_DemoMonitorController.ActiveDemoSession created =
            Skywave_DemoMonitorController.createSession('Acme Tonight', true);
        Test.stopTest();

        System.assertNotEquals(null, created, 'createSession should return a wrapper');
        Skywave_DemoMonitorController.ActiveDemoSession active =
            Skywave_DemoMonitorController.getActiveDemoSession();
        System.assertNotEquals(null, active, 'an active session should now exist for the owner');
        System.assertEquals(created.id, active.id, 'the created session should be the active one');
    }

    @IsTest
    static void setActive_switchesAndDeactivatesPrior() {
        Skywave_DemoMonitorController.ActiveDemoSession first =
            Skywave_DemoMonitorController.createSession('First', true);
        Skywave_DemoMonitorController.ActiveDemoSession second =
            Skywave_DemoMonitorController.createSession('Second', false);

        Test.startTest();
        Skywave_DemoMonitorController.setActive((Id) second.id);
        Test.stopTest();

        Map<Id, Demo_Session__c> rows = new Map<Id, Demo_Session__c>([
            SELECT Id, Active__c, Active_Owner_Key__c FROM Demo_Session__c
        ]);
        System.assertEquals(false, rows.get((Id) first.id).Active__c, 'prior active must be cleared');
        System.assertEquals(true,  rows.get((Id) second.id).Active__c, 'chosen must be active');
        System.assertEquals(null,  rows.get((Id) first.id).Active_Owner_Key__c, 'cleared row key must be blank');
        System.assertEquals(String.valueOf(UserInfo.getUserId()),
            rows.get((Id) second.id).Active_Owner_Key__c, 'active row key must equal OwnerId');
    }

    @IsTest
    static void searchSessions_returnsOnlyOwn() {
        Skywave_DemoMonitorController.createSession('Mine A', false);
        Skywave_DemoMonitorController.createSession('Mine B', false);
        List<Skywave_DemoMonitorController.ActiveDemoSession> rows =
            Skywave_DemoMonitorController.searchSessions('');
        System.assert(!rows.isEmpty(), 'owner should see their own sessions');
    }

    @IsTest
    static void advanceState_updatesOwnedSession() {
        Skywave_DemoMonitorController.ActiveDemoSession s =
            Skywave_DemoMonitorController.createSession('Adv', true);
        Test.startTest();
        String newState = Skywave_DemoMonitorController.advanceState((Id) s.id, 'survey');
        Test.stopTest();
        System.assertEquals('survey', newState);
        System.assertEquals('survey',
            [SELECT State__c FROM Demo_Session__c WHERE Id = :(Id) s.id].State__c);
    }

    @IsTest
    static void uniqueKey_blocksSecondActiveForSameOwner() {
        // One active session for this owner.
        insert new Demo_Session__c(State__c='idle', Active__c=true, Started__c=System.now());
        // A direct second Active=true insert for the same owner must collide on
        // the unique Active_Owner_Key__c (maintained by Demo_Session_Trigger).
        Boolean threw = false;
        try {
            insert new Demo_Session__c(State__c='idle', Active__c=true, Started__c=System.now());
        } catch (DmlException e) {
            threw = true;
            System.assert(
                e.getMessage().containsIgnoreCase('DUPLICATE_VALUE')
                || e.getDmlType(0) == StatusCode.DUPLICATE_VALUE,
                'expected DUPLICATE_VALUE, got: ' + e.getMessage());
        }
        System.assert(threw, 'second active session for the same owner must be rejected');
    }
}
