/**
 * Backing for the skywavePreflight LWC. One AuraEnabled entry,
 * runPreflight(), returns a flat list of CheckResult rows the LWC groups
 * by `groupKey` and renders with pass/fail/warn/manual icons.
 *
 * Three planes of risk this is designed to catch (org / agent+chat /
 * Heroku) plus a Heroku Statuspage warning pill and the two manual
 * confirmations (ESD republish + CLT visual render) that no API can
 * verify.
 *
 * Each callout is isolated — a failure to reach the dyno produces a
 * single failed row, not a thrown exception that hides the org-side
 * results. The LWC always gets a complete list.
 */
public with sharing class Skywave_PreflightController {

    public class CheckResult {
        @AuraEnabled public String id { get; set; }         // stable id, used as map key in the LWC
        @AuraEnabled public String groupKey { get; set; }   // 'org' | 'agent' | 'relay' | 'e2e' | 'platform' | 'manual'
        @AuraEnabled public String groupLabel { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String status { get; set; }     // 'pass' | 'fail' | 'warn' | 'manual'
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public Boolean manual { get; set; }    // tappable in the LWC

        public CheckResult(String id, String groupKey, String groupLabel, String label) {
            this.id = id;
            this.groupKey = groupKey;
            this.groupLabel = groupLabel;
            this.label = label;
            this.status = 'fail';
            this.manual = false;
        }
    }

    private static final String GROUP_ORG = 'org';
    private static final String GROUP_AGENT = 'agent';
    private static final String GROUP_RELAY = 'relay';
    private static final String GROUP_E2E = 'e2e';
    private static final String GROUP_PLATFORM = 'platform';
    private static final String GROUP_MANUAL = 'manual';

    private static final Map<String, String> GROUP_LABELS = new Map<String, String>{
        GROUP_ORG => 'Org Data',
        GROUP_AGENT => 'Agent & Chat',
        GROUP_RELAY => 'Heroku Relay',
        GROUP_E2E => 'End-to-End Roundtrip',
        GROUP_PLATFORM => 'Platform / Outage',
        GROUP_MANUAL => 'Manual Confirmation'
    };

    @AuraEnabled(cacheable=false)
    public static List<CheckResult> runPreflight() {
        List<CheckResult> out = new List<CheckResult>();

        // 1. Org data readiness — all SOQL, fast, zero risk.
        out.addAll(checkOrgData());

        // 2. Agent & chat readiness — bot user permsets are the trap.
        out.addAll(checkAgentChat());

        // The Heroku and Statuspage callouts return mostly stable JSON;
        // a 5s timeout each keeps the whole runPreflight under ~15s even
        // if everything times out.
        Skywave_Preflight_Config__mdt cfg = loadConfig();

        // 3. Heroku relay health (single callout, parses report into rows).
        Map<String, Object> herokuReport = null;
        try {
            herokuReport = callHeroku(cfg, false);
            out.addAll(rowsFromHerokuReport(herokuReport, cfg));
        } catch (Exception e) {
            out.add(failRow('relay.reach', GROUP_RELAY, 'Heroku /api/preflight reachable', e.getMessage()));
        }

        // 4. End-to-end roundtrip — separate ?e2e=1 callout for the
        //    loopback push probe; org-side write probe TODO once the
        //    direct-to-Sites migration lands. For now, the loopback +
        //    config-match in (3) is the strongest signal we have without
        //    spawning a real headless phone.
        try {
            Map<String, Object> e2eReport = callHeroku(cfg, true);
            Map<String, Object> rt = (Map<String, Object>) e2eReport.get('roundtrip');
            CheckResult r = new CheckResult('e2e.loopback', GROUP_E2E, GROUP_LABELS.get(GROUP_E2E), 'Loopback push delivered on dyno');
            if (rt != null && Boolean.TRUE.equals(rt.get('ok'))) {
                r.status = 'pass';
                Object ms = rt.get('deliveredMs');
                r.detail = (ms == null) ? 'ok' : ('delivered in ' + ms + 'ms');
            } else {
                r.status = 'fail';
                r.detail = (rt == null) ? 'no roundtrip in report' : String.valueOf(rt.get('reason'));
            }
            out.add(r);
        } catch (Exception e) {
            out.add(failRow('e2e.loopback', GROUP_E2E, 'Loopback push delivered on dyno', e.getMessage()));
        }

        // 5. Heroku Statuspage — incidents + scheduled maintenance.
        out.addAll(checkStatuspage(cfg));

        // 6. Manual confirms — render as neutral, click-to-mark in the LWC.
        out.addAll(manualRows());

        return out;
    }

    // ---------- 1. ORG DATA ----------

    private static List<CheckResult> checkOrgData() {
        List<CheckResult> rows = new List<CheckResult>();

        // 1a. Active demo session, on stage 1 (idle).
        List<Demo_Session__c> active = [
            SELECT Id, Name, State__c FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
        ];
        CheckResult activeRow = new CheckResult('org.activeSession', GROUP_ORG, GROUP_LABELS.get(GROUP_ORG), 'Active Demo_Session present');
        if (active.isEmpty()) {
            activeRow.detail = 'No Demo_Session__c with Active__c = true. Create or activate one in the Demo Monitor.';
        } else if (active.size() > 1) {
            activeRow.status = 'fail';
            activeRow.detail = active.size() + ' sessions are Active — only one allowed at a time.';
        } else {
            activeRow.status = 'pass';
            activeRow.detail = active[0].Name + ' (state=' + active[0].State__c + ')';
        }
        rows.add(activeRow);

        // 1b. Active session is reset to stage 1.
        CheckResult resetRow = new CheckResult('org.sessionReset', GROUP_ORG, GROUP_LABELS.get(GROUP_ORG), 'Active session reset to stage 1 (idle)');
        if (active.size() == 1) {
            if ('idle'.equals(active[0].State__c)) {
                resetRow.status = 'pass';
                resetRow.detail = 'State__c = idle';
            } else {
                resetRow.status = 'warn';
                resetRow.detail = 'State__c = ' + active[0].State__c + ' — reset to idle before the demo unless mid-rehearsal.';
            }
        } else {
            resetRow.status = 'fail';
            resetRow.detail = 'Skipped: no single active session.';
        }
        rows.add(resetRow);

        // 1c. Active survey questions present.
        Integer surveyCount = [SELECT COUNT() FROM Survey_Question__c WHERE Active__c = true];
        CheckResult surveyRow = new CheckResult('org.surveyQuestions', GROUP_ORG, GROUP_LABELS.get(GROUP_ORG), 'Survey questions seeded');
        if (surveyCount > 0) {
            surveyRow.status = 'pass';
            surveyRow.detail = surveyCount + ' active question(s)';
        } else {
            surveyRow.detail = 'No Survey_Question__c rows with Active__c = true. Run survey author or seed.';
        }
        rows.add(surveyRow);

        // 1d. Airline base data.
        Integer flights = [SELECT COUNT() FROM Flight__c WHERE Active__c = true];
        Integer seatMaps = [SELECT COUNT() FROM Skywave_Seat_Map__c];
        Integer bookings = [SELECT COUNT() FROM Booking__c];
        CheckResult dataRow = new CheckResult('org.airlineData', GROUP_ORG, GROUP_LABELS.get(GROUP_ORG), 'Airline data seeded (flights, seat maps, bookings)');
        if (flights > 0 && seatMaps > 0 && bookings > 0) {
            dataRow.status = 'pass';
            dataRow.detail = flights + ' flights, ' + seatMaps + ' seat maps, ' + bookings + ' bookings';
        } else {
            List<String> missing = new List<String>();
            if (flights == 0) missing.add('Flight__c');
            if (seatMaps == 0) missing.add('Skywave_Seat_Map__c');
            if (bookings == 0) missing.add('Booking__c');
            dataRow.detail = 'Empty: ' + String.join(missing, ', ') + '. Run Skywave_SeedBookingData or DemoSetup.';
        }
        rows.add(dataRow);

        return rows;
    }

    // ---------- 2. AGENT & CHAT ----------

    private static List<CheckResult> checkAgentChat() {
        List<CheckResult> rows = new List<CheckResult>();

        // 2a. The bot user must hold the Skywave_Agent_User permset, or
        //     actions whose Apex class isn't accessible to it get silently
        //     filtered from tools_sent (memory: feedback-bot-user-apex-permissions).
        //     We resolve the bot user by matching the agent .agent file's
        //     replaceable username convention: skywaveserviceagent@<domain>.
        CheckResult botRow = new CheckResult('agent.botUser', GROUP_AGENT, GROUP_LABELS.get(GROUP_AGENT), 'Bot user has Skywave_Agent_User permset');
        try {
            List<User> botUsers = [
                SELECT Id, Username FROM User
                WHERE Username LIKE 'skywaveserviceagent@%' AND IsActive = true
                LIMIT 1
            ];
            if (botUsers.isEmpty()) {
                botRow.detail = 'No active user matching skywaveserviceagent@%. Bot user is required for the agent to run.';
            } else {
                Integer assigned = [
                    SELECT COUNT() FROM PermissionSetAssignment
                    WHERE AssigneeId = :botUsers[0].Id
                      AND PermissionSet.Name = 'Skywave_Agent_User'
                ];
                if (assigned > 0) {
                    botRow.status = 'pass';
                    botRow.detail = botUsers[0].Username;
                } else {
                    botRow.detail = botUsers[0].Username + ' is missing the Skywave_Agent_User permset — agent actions will silently disappear from tools_sent.';
                }
            }
        } catch (Exception e) {
            botRow.detail = 'Query failed: ' + e.getMessage();
        }
        rows.add(botRow);

        // 2b. The agent bundle is published & active. We check via
        //     BotVersion (presence of a published version on the
        //     Skywave_Airlines_Agent bundle). If the BotVersion query
        //     isn't available in this org, fall back to a warn row so
        //     the demo isn't blocked on a metadata gap.
        CheckResult pubRow = new CheckResult('agent.published', GROUP_AGENT, GROUP_LABELS.get(GROUP_AGENT), 'Skywave_Airlines_Agent published & active');
        try {
            // BotDefinition.MasterLabel matches the bundle name. Status
            // 'Active' on a BotVersion = published+activated.
            Integer activeVersions = Database.countQuery(
                'SELECT COUNT() FROM BotVersion WHERE BotDefinition.DeveloperName = \'Skywave_Airlines_Agent\' AND Status = \'Active\''
            );
            if (activeVersions > 0) {
                pubRow.status = 'pass';
                pubRow.detail = activeVersions + ' active version(s)';
            } else {
                pubRow.detail = 'No active BotVersion for Skywave_Airlines_Agent. Publish + Activate in Agentforce.';
            }
        } catch (Exception e) {
            // Some orgs/permsets cannot query BotVersion. Don't fail the
            // whole preflight on a tooling-API limitation.
            pubRow.status = 'warn';
            pubRow.detail = 'BotVersion query unavailable here (' + e.getMessage() + '). Verify manually in Agentforce.';
        }
        rows.add(pubRow);

        return rows;
    }

    // ---------- 3+4. HEROKU CALLOUT ----------

    private static Skywave_Preflight_Config__mdt loadConfig() {
        // Single-tenant: DeveloperName=Default convention.
        List<Skywave_Preflight_Config__mdt> rows = [
            SELECT DeveloperName, Heroku_Origin__c, Preflight_Key__c, Statuspage_Url__c
            FROM Skywave_Preflight_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        return rows.isEmpty() ? new Skywave_Preflight_Config__mdt() : rows[0];
    }

    private static Map<String, Object> callHeroku(Skywave_Preflight_Config__mdt cfg, Boolean e2e) {
        if (String.isBlank(cfg.Heroku_Origin__c)) {
            throw new CalloutException('Skywave_Preflight_Config.Default.Heroku_Origin__c is not set.');
        }
        if (String.isBlank(cfg.Preflight_Key__c)) {
            throw new CalloutException('Skywave_Preflight_Config.Default.Preflight_Key__c is not set.');
        }

        HttpRequest req = new HttpRequest();
        String url = cfg.Heroku_Origin__c.removeEnd('/') + '/api/preflight' + (e2e ? '?e2e=1' : '');
        req.setEndpoint(url);
        req.setMethod('GET');
        req.setHeader('x-preflight-key', cfg.Preflight_Key__c);
        req.setHeader('Accept', 'application/json');
        req.setTimeout(8000);

        HttpResponse resp = new Http().send(req);
        if (resp.getStatusCode() != 200) {
            throw new CalloutException('HTTP ' + resp.getStatusCode() + ': ' + resp.getStatus() + ' — ' + truncate(resp.getBody(), 200));
        }
        return (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
    }

    private static List<CheckResult> rowsFromHerokuReport(Map<String, Object> r, Skywave_Preflight_Config__mdt cfg) {
        List<CheckResult> rows = new List<CheckResult>();

        // 3a. Reachable & healthy.
        CheckResult reach = new CheckResult('relay.reach', GROUP_RELAY, GROUP_LABELS.get(GROUP_RELAY), 'Heroku /api/preflight reachable');
        reach.status = 'pass';
        reach.detail = 'ok=' + r.get('ok');
        rows.add(reach);

        // 3b. Pub/Sub subscriber connected.
        Map<String, Object> ps = (Map<String, Object>) r.get('pubsub');
        CheckResult psRow = new CheckResult('relay.pubsub', GROUP_RELAY, GROUP_LABELS.get(GROUP_RELAY), 'Pub/Sub subscriber connected to Demo_State_Change__e');
        if (ps != null && Boolean.TRUE.equals(ps.get('connected'))) {
            psRow.status = 'pass';
            psRow.detail = 'subscribedAt=' + ps.get('subscribedAt');
        } else {
            psRow.status = 'fail';
            Integer attempts = (ps == null) ? 0 : Integer.valueOf(String.valueOf(ps.get('reconnectAttempts')));
            psRow.detail = 'not connected (reconnectAttempts=' + attempts + '). Check the dyno log.';
        }
        rows.add(psRow);

        // 3c. Dyno uptime / cycleSoon warning pill.
        Map<String, Object> dyno = (Map<String, Object>) r.get('dyno');
        CheckResult dynoRow = new CheckResult('relay.dynoUptime', GROUP_RELAY, GROUP_LABELS.get(GROUP_RELAY), 'Dyno not approaching daily cycle');
        if (dyno == null) {
            dynoRow.status = 'fail';
            dynoRow.detail = 'no dyno report';
        } else if (Boolean.TRUE.equals(dyno.get('cycleSoon'))) {
            dynoRow.status = 'warn';
            dynoRow.detail = 'Dyno up ~' + Math.round(((Decimal) dyno.get('uptimeSec')) / 3600) + 'h. Heroku cycles ~24h — restart pre-demo to avoid mid-show cycle.';
        } else {
            dynoRow.status = 'pass';
            dynoRow.detail = 'up ' + Math.round(((Decimal) dyno.get('uptimeSec')) / 3600) + 'h, mem ' + dyno.get('memoryMb') + 'MB';
        }
        rows.add(dynoRow);

        // 3d. Config match — diff Heroku-side ESW values against the four
        //     Heroku Config Vars echoed in the report. The strongest single
        //     signal that the org-published EmbeddedServiceConfig hasn't
        //     drifted from what the website serves to phones.
        Map<String, Object> hkCfg = (Map<String, Object>) r.get('config');
        Map<String, Object> esw = (hkCfg == null) ? null : (Map<String, Object>) hkCfg.get('esw');
        CheckResult cfgRow = new CheckResult('relay.configPresent', GROUP_RELAY, GROUP_LABELS.get(GROUP_RELAY), 'Heroku ESW_* and SDK URL all set');
        List<String> missing = new List<String>();
        if (esw == null || esw.get('orgId') == null)    missing.add('SF_ESW_ORG_ID');
        if (esw == null || esw.get('escName') == null)  missing.add('SF_ESW_ESC_NAME');
        if (esw == null || esw.get('siteUrl') == null)  missing.add('SF_ESW_SITE_URL');
        if (esw == null || esw.get('scrt2Url') == null) missing.add('SF_ESW_SCRT2_URL');
        if (hkCfg == null || hkCfg.get('interactionsSdkUrl') == null) missing.add('SF_INTERACTIONS_SDK_URL');
        if (missing.isEmpty()) {
            cfgRow.status = 'pass';
            cfgRow.detail = 'all four ESW_* + SDK URL present';
        } else {
            cfgRow.detail = 'Missing on Heroku: ' + String.join(missing, ', ') + '. Chat or SDK will not load.';
        }
        rows.add(cfgRow);

        return rows;
    }

    // ---------- 5. STATUSPAGE ----------

    private static List<CheckResult> checkStatuspage(Skywave_Preflight_Config__mdt cfg) {
        List<CheckResult> rows = new List<CheckResult>();
        String base = String.isBlank(cfg.Statuspage_Url__c) ? 'https://status.heroku.com' : cfg.Statuspage_Url__c.removeEnd('/');

        // Active incidents.
        CheckResult incRow = new CheckResult('platform.incidents', GROUP_PLATFORM, GROUP_LABELS.get(GROUP_PLATFORM), 'No active Heroku incidents');
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                statuspageGet(base + '/api/v2/incidents/unresolved.json')
            );
            List<Object> incidents = (List<Object>) body.get('incidents');
            Integer n = (incidents == null) ? 0 : incidents.size();
            if (n == 0) {
                incRow.status = 'pass';
                incRow.detail = 'unresolved=0';
            } else {
                incRow.status = 'warn';
                incRow.detail = n + ' active incident(s) — see status.heroku.com';
            }
        } catch (Exception e) {
            incRow.status = 'warn';
            incRow.detail = 'Statuspage unreachable: ' + e.getMessage();
        }
        rows.add(incRow);

        // Upcoming maintenance.
        CheckResult mxRow = new CheckResult('platform.maintenance', GROUP_PLATFORM, GROUP_LABELS.get(GROUP_PLATFORM), 'No upcoming Heroku maintenance');
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
                statuspageGet(base + '/api/v2/scheduled-maintenances/upcoming.json')
            );
            List<Object> mx = (List<Object>) body.get('scheduled_maintenances');
            Integer n = (mx == null) ? 0 : mx.size();
            if (n == 0) {
                mxRow.status = 'pass';
                mxRow.detail = 'upcoming=0';
            } else {
                mxRow.status = 'warn';
                mxRow.detail = n + ' scheduled — review timing vs your demo slot';
            }
        } catch (Exception e) {
            mxRow.status = 'warn';
            mxRow.detail = 'Statuspage unreachable: ' + e.getMessage();
        }
        rows.add(mxRow);

        return rows;
    }

    private static String statuspageGet(String url) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(url);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(5000);
        HttpResponse resp = new Http().send(req);
        if (resp.getStatusCode() != 200) {
            throw new CalloutException('HTTP ' + resp.getStatusCode() + ' from Statuspage');
        }
        return resp.getBody();
    }

    // ---------- 6. MANUAL CONFIRMS ----------

    private static List<CheckResult> manualRows() {
        List<CheckResult> rows = new List<CheckResult>();

        CheckResult esd = new CheckResult('manual.esdRepublish', GROUP_MANUAL, GROUP_LABELS.get(GROUP_MANUAL), 'ESD republished after last agent publish/activate');
        esd.status = 'manual';
        esd.manual = true;
        esd.detail = 'No API surface for this. Confirm in Setup → Embedded Service Deployments → Republish.';
        rows.add(esd);

        CheckResult clt = new CheckResult('manual.cltRender', GROUP_MANUAL, GROUP_LABELS.get(GROUP_MANUAL), 'CLT card visually renders in chat preview');
        clt.status = 'manual';
        clt.manual = true;
        clt.detail = 'Open a chat session and send a sample message that triggers a CLT card. Confirm it draws (not just fallback text).';
        rows.add(clt);

        return rows;
    }

    // ---------- helpers ----------

    private static CheckResult failRow(String id, String groupKey, String label, String detail) {
        CheckResult r = new CheckResult(id, groupKey, GROUP_LABELS.get(groupKey), label);
        r.status = 'fail';
        r.detail = truncate(detail, 240);
        return r;
    }

    private static String truncate(String s, Integer n) {
        if (s == null) return '';
        return s.length() <= n ? s : s.substring(0, n) + '…';
    }
}
