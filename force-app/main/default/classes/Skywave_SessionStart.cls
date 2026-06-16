/**
 * POST /services/apexrest/skywave/session/start
 *
 * Mints a per-phone sessionId, stamps it with the active Demo_Session__c,
 * publishes a Demo_Event__e (type=session_started), and returns the
 * sessionId + the Heroku skywave-app WS URL to the consumer site.
 *
 * Body (optional): { "userAgent": "..." }
 * Response: { "sessionId": "...", "demoSessionId": "...", "wsUrl": "..." }
 */
@RestResource(urlMapping='/skywave/session/start')
global without sharing class Skywave_SessionStart {

    // The Heroku relay origin is the single source of truth in
    // Skywave_Preflight_Config.Default.Heroku_Origin_Url__c (set by install.sh
    // once the dyno is provisioned). We derive the WS base from it so there's
    // no hardcoded host to repoint. Falls back to a sane shape if unset.
    @TestVisible
    private static String wsBaseUrl() {
        String origin = Skywave_HerokuConfig.originUrl();      // https://host (no trailing /)
        if (String.isBlank(origin)) return null;
        // https://host -> wss://host/ws
        return origin.replaceFirst('^https?://', 'wss://') + '/ws';
    }

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        // Read the active session and current state in one query — phones
        // need both to bootstrap their UI without waiting for the next PE.
        List<Demo_Session__c> active = [
            SELECT Id, State__c FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        if (active.isEmpty()) {
            res.statusCode = 503;
            res.responseBody = Blob.valueOf('{"error":"no_active_demo_session"}');
            return;
        }
        Id demoSessionId = active[0].Id;
        String currentState = active[0].State__c;

        Map<String, Object> body = Skywave_RestUtil.parseBody();
        String userAgent = String.valueOf(body.get('userAgent'));
        // Prefer the Salesforce Interactions SDK's anonymous cookie ID when
        // the consumer site provides it — that ID is what Data Cloud uses to
        // correlate events into the Engagement DLO, so using it as our
        // sessionId means one identifier flows through everything.
        // Fall back to a minted UUID if the SDK didn't load (no consent,
        // ad-blocker, etc.) so the demo never hard-blocks.
        String providedId = String.valueOf(body.get('sessionId'));
        String sessionId = (providedId != null && providedId.length() >= 8 && providedId.length() <= 64)
            ? providedId
            : newSessionId();

        // If the consumer site has already resolved IP geolocation, carry it
        // on the session_started event so the demo monitor can place the
        // visitor's bubble on the world map immediately — no need to wait
        // for survey_complete. Best-effort: missing values are simply not
        // included.
        Map<String, Object> startPayload = new Map<String, Object>{ 'userAgent' => userAgent };
        Decimal geoLat = toDecimal(body.get('geoLat'));
        Decimal geoLon = toDecimal(body.get('geoLon'));
        if (geoLat != null) startPayload.put('lat', geoLat);
        if (geoLon != null) startPayload.put('lon', geoLon);
        Object geoCity    = body.get('geoCity');
        Object geoRegion  = body.get('geoRegion');
        Object geoCountry = body.get('geoCountry');
        if (geoCity    != null) startPayload.put('city',    String.valueOf(geoCity));
        if (geoRegion  != null) startPayload.put('region',  String.valueOf(geoRegion));
        if (geoCountry != null) startPayload.put('country', String.valueOf(geoCountry));
        if (geoLat != null && geoLon != null) {
            String homeAirport = Skywave_Airports.nearest(geoLat, geoLon);
            if (homeAirport != null) startPayload.put('homeAirport', homeAirport);
        }

        Skywave_RestUtil.publishEvent(
            'session_started',
            sessionId,
            demoSessionId,
            startPayload
        );

        String wsBase = wsBaseUrl();
        Map<String, Object> response = new Map<String, Object>{
            'sessionId' => sessionId,
            'demoSessionId' => demoSessionId,
            'currentState' => currentState,
            'wsUrl' => (wsBase == null) ? null : wsBase + '/' + sessionId
        };
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(response));
    }

    private static Decimal toDecimal(Object v) {
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return Decimal.valueOf((Integer) v);
        if (v instanceof Double)  return Decimal.valueOf((Double) v);
        try { return Decimal.valueOf(String.valueOf(v)); }
        catch (Exception e) { return null; }
    }

    private static String newSessionId() {
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0,8) + '-' + hex.substring(8,12) + '-4' + hex.substring(13,16)
             + '-' + hex.substring(16,20) + '-' + hex.substring(20,32);
    }
}
