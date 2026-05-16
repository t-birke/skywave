/**
 * Apex backing for the skywaveDemoMonitor LWC.
 */
public with sharing class Skywave_DemoMonitorController {

    public class ActiveDemoSession {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String state { get; set; }
        @AuraEnabled public String customer { get; set; }
        @AuraEnabled public Date demoDate { get; set; }
        @AuraEnabled public Integer contactCount { get; set; }
    }

    @AuraEnabled(cacheable=false)
    public static ActiveDemoSession getActiveDemoSession() {
        List<Demo_Session__c> rows = [
            SELECT Id, Name, State__c, Customer__c, Demo_Date__c
            FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        if (rows.isEmpty()) return null;
        return toWrapper(rows[0]);
    }

    @AuraEnabled(cacheable=true)
    public static List<ActiveDemoSession> searchSessions(String term) {
        String trimmed = (term == null) ? '' : term.trim();
        List<Demo_Session__c> rows;
        if (trimmed == '') {
            rows = [
                SELECT Id, Name, State__c, Customer__c, Demo_Date__c
                FROM Demo_Session__c
                ORDER BY Started__c DESC NULLS LAST
                LIMIT 5
            ];
        } else {
            String pattern = '%' + trimmed + '%';
            rows = [
                SELECT Id, Name, State__c, Customer__c, Demo_Date__c
                FROM Demo_Session__c
                WHERE Customer__c LIKE :pattern OR Name LIKE :pattern
                ORDER BY Started__c DESC NULLS LAST
                LIMIT 5
            ];
        }
        List<ActiveDemoSession> out = new List<ActiveDemoSession>();
        for (Demo_Session__c d : rows) out.add(toWrapperSkipCount(d));
        return out;
    }

    private static ActiveDemoSession toWrapperSkipCount(Demo_Session__c d) {
        ActiveDemoSession w = new ActiveDemoSession();
        w.id = d.Id;
        w.name = d.Name;
        w.state = d.State__c;
        w.customer = d.Customer__c;
        w.demoDate = d.Demo_Date__c;
        w.contactCount = 0;
        return w;
    }

    @AuraEnabled
    public static ActiveDemoSession setActive(Id sessionId) {
        // Single-tenant: clear Active__c on whatever else has it, then set on the chosen row.
        List<Demo_Session__c> currentlyActive = [
            SELECT Id FROM Demo_Session__c WHERE Active__c = true AND Id != :sessionId
        ];
        for (Demo_Session__c d : currentlyActive) d.Active__c = false;
        if (!currentlyActive.isEmpty()) update currentlyActive;

        Demo_Session__c chosen = [
            SELECT Id, Name, State__c, Customer__c, Demo_Date__c, Active__c
            FROM Demo_Session__c WHERE Id = :sessionId LIMIT 1
        ];
        if (!chosen.Active__c) {
            chosen.Active__c = true;
            update chosen;
        }
        return toWrapper(chosen);
    }

    @AuraEnabled
    public static String advanceState(Id sessionId, String newState) {
        Demo_Session__c d = new Demo_Session__c(Id = sessionId, State__c = newState);
        update d;
        // The trigger publishes Demo_State_Change__e — empApi subscribers
        // (monitor LWC, Heroku relay) pick it up.
        return newState;
    }

    private static ActiveDemoSession toWrapper(Demo_Session__c d) {
        Integer cnt = [SELECT COUNT() FROM Contact WHERE Demo_Session__c = :d.Id];
        ActiveDemoSession out = new ActiveDemoSession();
        out.id = d.Id;
        out.name = d.Name;
        out.state = d.State__c;
        out.customer = d.Customer__c;
        out.demoDate = d.Demo_Date__c;
        out.contactCount = cnt;
        return out;
    }
}
