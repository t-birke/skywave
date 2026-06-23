/**
 * End-to-end multi-tenancy: two presenters (A = running user, B = another
 * user) run simultaneously and stay isolated — coexisting active sessions,
 * owner-scoped monitor, ownership-guarded activation, and a per-visitor seat
 * gate. B's session is owned via an existing user id (no fragile user
 * creation / license draw).
 */
@IsTest
private class Skywave_MultiTenant_Test {

    @IsTest
    static void crossOwnerIsolation() {
        // Presenter B = some other active user in the org.
        Id otherUserId = [
            SELECT Id FROM User
            WHERE IsActive = true AND Id != :UserInfo.getUserId() AND Profile.Name != null
            ORDER BY CreatedDate
            LIMIT 1
        ].Id;

        // B's active session (owned by B), parked at agent_seat_pass.
        Demo_Session__c bSession = new Demo_Session__c(
            State__c = 'agent_seat_pass', Started__c = System.now(),
            OwnerId = otherUserId, Active__c = true, Customer__c = 'B audience'
        );
        insert bSession;

        // A (running user) creates + activates their own, parked at idle.
        Skywave_DemoMonitorController.ActiveDemoSession aSession =
            Skywave_DemoMonitorController.createSession('A audience', true);

        // Both active at once — the unique Active_Owner_Key__c is per-owner.
        System.assertEquals(2,
            [SELECT COUNT() FROM Demo_Session__c WHERE Active__c = true],
            'each owner keeps their own active session simultaneously');

        // A's monitor sees ONLY A's sessions.
        for (Skywave_DemoMonitorController.ActiveDemoSession m : Skywave_DemoMonitorController.listMySessions()) {
            System.assertNotEquals(bSession.Id, (Id) m.id, 'A must not see B\'s session');
        }
        System.assertEquals(aSession.id, Skywave_DemoMonitorController.getActiveDemoSession().id,
            'A\'s active resolves to A\'s own session, not the global newest');

        // Ownership guard: A cannot activate a session it doesn't own.
        Boolean threw = false;
        try { Skywave_DemoMonitorController.setActive(bSession.Id); }
        catch (Exception e) { threw = true; }
        System.assert(threw, 'A must not be able to activate B\'s session');

        // Per-visitor seat gate: a visitor on B's (agent_seat_pass) session has
        // seat-change enabled; a visitor on A's (idle) session does not — proving
        // A advancing/standing has no effect on B's visitors and vice-versa.
        Contact bVisitor = new Contact(LastName = 'BV', Demo_Session__c = bSession.Id);
        Contact aVisitor = new Contact(LastName = 'AV', Demo_Session__c = (Id) aSession.id);
        insert new List<Contact>{ bVisitor, aVisitor };

        System.assertEquals(true, seatEnabledFor(bVisitor.Id),
            'B visitor on agent_seat_pass session → seat enabled');
        System.assertEquals(false, seatEnabledFor(aVisitor.Id),
            'A visitor on idle session → seat NOT enabled (gate is per-presenter)');
    }

    private static Boolean seatEnabledFor(Id contactId) {
        Skywave_CheckSeatEnabled.Input i = new Skywave_CheckSeatEnabled.Input();
        i.contactId = contactId;
        return Skywave_CheckSeatEnabled.check(
            new List<Skywave_CheckSeatEnabled.Input>{ i })[0].enabled;
    }
}
