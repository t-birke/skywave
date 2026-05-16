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

    // TODO Phase 1: surface this via Custom Metadata so we can repoint without code change.
    private static final String WS_BASE_URL = 'wss://skywave-app-bb0e8666933b.herokuapp.com/ws';

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

        Skywave_RestUtil.publishEvent(
            'session_started',
            sessionId,
            demoSessionId,
            new Map<String, Object>{ 'userAgent' => userAgent }
        );

        Map<String, Object> response = new Map<String, Object>{
            'sessionId' => sessionId,
            'demoSessionId' => demoSessionId,
            'currentState' => currentState,
            'wsUrl' => WS_BASE_URL + '/' + sessionId
        };
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(response));
    }

    private static String newSessionId() {
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0,8) + '-' + hex.substring(8,12) + '-4' + hex.substring(13,16)
             + '-' + hex.substring(16,20) + '-' + hex.substring(20,32);
    }
}
