/**
 * Apex backing for the skywaveDemoMonitor LWC.
 * One method: getActiveDemoSession() returns the singleton active run
 * plus a fresh count of Contacts created during it.
 */
public with sharing class Skywave_DemoMonitorController {

    public class ActiveDemoSession {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String state { get; set; }
        @AuraEnabled public Integer contactCount { get; set; }
    }

    @AuraEnabled(cacheable=false)
    public static ActiveDemoSession getActiveDemoSession() {
        List<Demo_Session__c> rows = [
            SELECT Id, Name, State__c FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        if (rows.isEmpty()) return null;

        Demo_Session__c d = rows[0];
        Integer cnt = [SELECT COUNT() FROM Contact WHERE Demo_Session__c = :d.Id];

        ActiveDemoSession out = new ActiveDemoSession();
        out.id = d.Id;
        out.name = d.Name;
        out.state = d.State__c;
        out.contactCount = cnt;
        return out;
    }
}
