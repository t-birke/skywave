/**
 * Triggers Data Cloud "Refresh Now" from Apex.
 *
 * Why this exists: the public Connect REST endpoint for running a
 * data stream import — POST /services/data/v66.0/ssot/data-streams/{id}/actions/run
 * — rejects bare sf-CLI session tokens with
 *   "Connector type SalesforceDotCom is not allowed to run in non-interactive mode"
 * because SalesforceDotCom-type streams require an OAuth scope only granted
 * to interactive web sessions. Apex callouts using UserInfo.getSessionId()
 * inherit the full running-user scope including that one, so this works
 * where curl + JWT do not.
 *
 * Used to refresh the eleven SDO_Analytics_*_Home streams after the
 * Skywave_ObservabilitySeeder rewrites the SDO_Analytics QBrix tables.
 *
 * Run:
 *   Skywave_DataStreamRunner.refreshSdoAnalyticsStreams();
 *
 * Setup requirement: add the org's My Domain URL to the org's Remote
 * Site Settings (Setup -> Remote Site Settings), or the callout fails
 * with "Unauthorized endpoint". One-time per org.
 */
public with sharing class Skywave_DataStreamRunner {

    /** Triggers a Refresh Now on every SDO_Analytics_*_Home stream. */
    public static List<String> refreshSdoAnalyticsStreams() {
        List<DataStream> streams = [
            SELECT Id, Name FROM DataStream WHERE Name LIKE 'SDO_Analytics_%_Home'
        ];
        List<String> results = new List<String>();
        for (DataStream ds : streams) {
            results.add(ds.Name + ': ' + runOne(ds.Id));
        }
        return results;
    }

    /**
     * Triggers a Refresh Now on the Bot streams (BotDefinition_Home,
     * BotVersion_Home). These feed the ssot__Bot__dlm DMO from real
     * BotDefinition records — required for a synthetic agent's sessions to
     * surface in Optimization Insights / Sessions & Intents (the views join
     * on ssot__Bot__dlm.DeveloperName = the session's agent api name).
     * Run after deploying a new agent whose name must appear in Bot__dlm.
     */
    public static List<String> refreshBotStreams() {
        List<DataStream> streams = [
            SELECT Id, Name FROM DataStream
            WHERE Name = 'BotDefinition_Home' OR Name = 'BotVersion_Home'
        ];
        List<String> results = new List<String>();
        for (DataStream ds : streams) {
            results.add(ds.Name + ': ' + runOne(ds.Id));
        }
        return results;
    }

    /** Triggers a single stream by Id. Returns the HTTP status code as text. */
    public static String runOne(Id dataStreamId) {
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
        Http h = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(orgUrl + '/services/data/v66.0/ssot/data-streams/'
            + dataStreamId + '/actions/run');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setBody('{}');
        try {
            HttpResponse res = h.send(req);
            return res.getStatusCode() + ': ' + res.getBody().abbreviate(120);
        } catch (Exception e) {
            return 'EX: ' + e.getMessage();
        }
    }
}
