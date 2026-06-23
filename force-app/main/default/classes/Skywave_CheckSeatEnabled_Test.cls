/**
 * Covers the multi-tenant (visitor-scoped) seat gate: the check reads the
 * VISITOR'S own Demo_Session__c.State__c, with a global-active fallback.
 */
@IsTest
private class Skywave_CheckSeatEnabled_Test {

    private static Skywave_CheckSeatEnabled.Input input(String contactId) {
        Skywave_CheckSeatEnabled.Input i = new Skywave_CheckSeatEnabled.Input();
        i.contactId = contactId;
        return i;
    }

    private static Boolean run(String contactId) {
        List<Skywave_CheckSeatEnabled.Output> outs =
            Skywave_CheckSeatEnabled.check(new List<Skywave_CheckSeatEnabled.Input>{ input(contactId) });
        return outs[0].enabled;
    }

    @IsTest
    static void enabled_whenVisitorsOwnSessionAtSeatPass() {
        Demo_Session__c ds = new Demo_Session__c(State__c='agent_seat_pass', Started__c=System.now());
        insert ds;
        Contact c = new Contact(LastName='V1', Demo_Session__c=ds.Id);
        insert c;
        System.assertEquals(true, run(c.Id), 'visitor session at agent_seat_pass → enabled');
    }

    @IsTest
    static void disabled_whenVisitorsOwnSessionNotAtSeatPass() {
        Demo_Session__c ds = new Demo_Session__c(State__c='survey', Started__c=System.now());
        insert ds;
        Contact c = new Contact(LastName='V2', Demo_Session__c=ds.Id);
        insert c;
        System.assertEquals(false, run(c.Id), 'visitor session not at agent_seat_pass → disabled');
    }

    @IsTest
    static void fallsBackToGlobalActive_whenNoContact() {
        // A different presenter's session is the global active one, at seat_pass.
        insert new Demo_Session__c(State__c='agent_seat_pass', Active__c=true, Started__c=System.now());
        // Sentinel / blank / malformed all hit the global-active fallback.
        System.assertEquals(true, run('003000000000000'), 'sentinel → global active fallback');
        System.assertEquals(true, run(''), 'blank → global active fallback');
        System.assertEquals(true, run('not-an-id'), 'garbage → global active fallback');
    }

    @IsTest
    static void contactWithoutSession_fallsBackToGlobalActive() {
        insert new Demo_Session__c(State__c='survey', Active__c=true, Started__c=System.now());
        Contact c = new Contact(LastName='V3'); // no Demo_Session__c
        insert c;
        System.assertEquals(false, run(c.Id), 'no visitor session + global active not at seat_pass → disabled');
    }
}
