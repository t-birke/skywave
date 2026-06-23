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
        @AuraEnabled public Boolean active { get; set; }
    }

    @AuraEnabled(cacheable=false)
    public static ActiveDemoSession getActiveDemoSession() {
        // Multi-tenant: the presenter only ever sees their OWN active session.
        List<Demo_Session__c> rows = [
            SELECT Id, Name, State__c, Customer__c, Demo_Date__c
            FROM Demo_Session__c
            WHERE Active__c = true AND OwnerId = :UserInfo.getUserId()
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        if (rows.isEmpty()) return null;
        return toWrapper(rows[0]);
    }

    @AuraEnabled(cacheable=true)
    public static List<ActiveDemoSession> searchSessions(String term) {
        // Multi-tenant: a presenter can only browse / select sessions they own.
        Id me = UserInfo.getUserId();
        String trimmed = (term == null) ? '' : term.trim();
        List<Demo_Session__c> rows;
        if (trimmed == '') {
            rows = [
                SELECT Id, Name, State__c, Customer__c, Demo_Date__c
                FROM Demo_Session__c
                WHERE OwnerId = :me
                ORDER BY Started__c DESC NULLS LAST
                LIMIT 5
            ];
        } else {
            String pattern = '%' + trimmed + '%';
            rows = [
                SELECT Id, Name, State__c, Customer__c, Demo_Date__c
                FROM Demo_Session__c
                WHERE OwnerId = :me AND (Customer__c LIKE :pattern OR Name LIKE :pattern)
                ORDER BY Started__c DESC NULLS LAST
                LIMIT 5
            ];
        }
        List<ActiveDemoSession> out = new List<ActiveDemoSession>();
        for (Demo_Session__c d : rows) out.add(toWrapperSkipCount(d));
        return out;
    }

    /**
     * Demo Home: the caller's own sessions (active first, then newest), with
     * the `active` flag set. Non-cacheable so the list refreshes immediately
     * after createSession / setActive (an imperative call to the cacheable
     * searchSessions would return a stale client cache after a mutation).
     */
    @AuraEnabled(cacheable=false)
    public static List<ActiveDemoSession> listMySessions() {
        List<ActiveDemoSession> out = new List<ActiveDemoSession>();
        for (Demo_Session__c d : [
            SELECT Id, Name, State__c, Customer__c, Demo_Date__c, Active__c
            FROM Demo_Session__c
            WHERE OwnerId = :UserInfo.getUserId()
            ORDER BY Active__c DESC, Started__c DESC NULLS LAST
            LIMIT 25
        ]) {
            ActiveDemoSession w = toWrapperSkipCount(d);
            w.active = d.Active__c;
            out.add(w);
        }
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
        Id me = UserInfo.getUserId();
        Demo_Session__c chosen = [
            SELECT Id, Name, State__c, Customer__c, Demo_Date__c, Active__c, OwnerId
            FROM Demo_Session__c WHERE Id = :sessionId LIMIT 1
        ];
        // Ownership guard — a presenter can only activate a session they own.
        if (chosen.OwnerId != me) {
            throw new AuraHandledException('You can only activate a demo session you own.');
        }
        // Multi-tenant: deactivate any OTHER active session THIS presenter owns,
        // then activate the chosen one — same transaction, so the committed
        // state holds exactly one active row per owner. Demo_Session_Trigger
        // keeps Active_Owner_Key__c in sync; its uniqueness makes a stray
        // double-active impossible to commit.
        List<Demo_Session__c> currentlyActive = [
            SELECT Id FROM Demo_Session__c
            WHERE Active__c = true AND OwnerId = :me AND Id != :sessionId
        ];
        for (Demo_Session__c d : currentlyActive) d.Active__c = false;
        if (!currentlyActive.isEmpty()) update currentlyActive;

        if (!chosen.Active__c) {
            chosen.Active__c = true;
            update chosen;
        }
        return toWrapper(chosen);
    }

    /**
     * Demo Home empty-state action: create a Demo_Session__c owned by the
     * caller (OwnerId defaults to the running user). When activate=true it is
     * immediately made the caller's active session via setActive.
     */
    @AuraEnabled
    public static ActiveDemoSession createSession(String customer, Boolean activateNow) {
        Demo_Session__c d = new Demo_Session__c(
            Customer__c = String.isBlank(customer) ? null : customer.trim(),
            State__c = 'idle',
            Started__c = System.now()
        );
        insert d;   // OwnerId = running user; Active__c stays false until activated
        if (activateNow == true) {
            return setActive(d.Id);
        }
        Demo_Session__c created = [
            SELECT Id, Name, State__c, Customer__c, Demo_Date__c
            FROM Demo_Session__c WHERE Id = :d.Id LIMIT 1
        ];
        return toWrapperSkipCount(created);
    }

    /**
     * Returns a flat map of "<questionKey>:<optionKey>" -> imageUrl for all
     * active questions/options. Monitor LWC calls this once on mount to
     * resolve survey_answer events to the correct thumbnail without
     * inflating the Platform Event payload.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getOptionImageMap() {
        Map<String, String> out = new Map<String, String>();
        for (Survey_Answer_Option__c o : [
            SELECT Image_Url__c, Option_Key__c, Survey_Question__r.Question_Key__c
            FROM Survey_Answer_Option__c
            WHERE Active__c = true
              AND Survey_Question__r.Active__c = true
              AND Image_Url__c != null
        ]) {
            out.put(o.Survey_Question__r.Question_Key__c + ':' + o.Option_Key__c, o.Image_Url__c);
        }
        return out;
    }

    /**
     * IATA -> {lat, lon} for every airport in the Skywave network. Monitor
     * LWC fetches once at mount so it can plot bubbles + draw routes without
     * carrying coordinates in every Demo_Event__e payload.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Map<String, Double>> getAirportGeo() {
        Map<String, Map<String, Double>> out = new Map<String, Map<String, Double>>();
        for (Skywave_Airports.Airport a : Skywave_Airports.ALL) {
            out.put(a.code, new Map<String, Double>{ 'lat' => a.lat, 'lon' => a.lon });
        }
        return out;
    }

    /**
     * The Heroku consumer-site origin (with trailing slash) the monitor encodes
     * into its QR code. Read from the single CMD source of truth so it follows
     * the provisioned dyno without a code change. Empty string if unset.
     */
    @AuraEnabled(cacheable=true)
    public static String getHerokuOrigin() {
        String origin = Skywave_HerokuConfig.originUrl();
        return String.isBlank(origin) ? '' : origin + '/';
    }

    @AuraEnabled
    public static String advanceState(Id sessionId, String newState) {
        // Ownership guard — presenters only drive their own sessions.
        Demo_Session__c existing = [
            SELECT OwnerId FROM Demo_Session__c WHERE Id = :sessionId LIMIT 1
        ];
        if (existing.OwnerId != UserInfo.getUserId()) {
            throw new AuraHandledException('You can only advance a demo session you own.');
        }
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
