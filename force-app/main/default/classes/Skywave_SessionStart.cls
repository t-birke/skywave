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
    private static final String WS_BASE_URL = 'wss://skywave-app.herokuapp.com/ws';

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Id demoSessionId = Skywave_RestUtil.getActiveDemoSessionId();
        if (demoSessionId == null) {
            res.statusCode = 503;
            res.responseBody = Blob.valueOf('{"error":"no_active_demo_session"}');
            return;
        }

        Map<String, Object> body = Skywave_RestUtil.parseBody();
        String userAgent = String.valueOf(body.get('userAgent'));
        // Mint a UUID-shaped session id. Apex doesn't have UUID natively;
        // a Crypto-based pseudo-UUID is good enough for our scale.
        String sessionId = newSessionId();

        Skywave_RestUtil.publishEvent(
            'session_started',
            sessionId,
            demoSessionId,
            new Map<String, Object>{ 'userAgent' => userAgent }
        );

        Map<String, Object> response = new Map<String, Object>{
            'sessionId' => sessionId,
            'demoSessionId' => demoSessionId,
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
