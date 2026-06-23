/**
 * POST /services/apexrest/skywave/race/tick
 *
 * Phase 1 stub. Phase 6 fully wires this with Kinesis dual-write.
 * Body: { "sessionId": "...", "intensity": 1.23, "t": 1234567890 }
 *
 * Phase 1 only publishes the Demo_Event__e. Phase 6 adds AWS Kinesis
 * forwarding for the persistence path (Kinesis -> Redshift -> DC zero-copy).
 */
@RestResource(urlMapping='/skywave/race/tick')
global without sharing class Skywave_RaceTick {
    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Map<String, Object> body = Skywave_RestUtil.parseBody();
        // Multi-tenant: route this event to the presenter's session via the
        // `ds` tenant key, falling back to the global active session.
        Id demoSessionId = Skywave_RestUtil.getDemoSessionId(String.valueOf(body.get('ds')));
        if (demoSessionId == null) {
            res.statusCode = 503;
            res.responseBody = Blob.valueOf('{"error":"no_active_demo_session"}');
            return;
        }

        String sessionId = String.valueOf(body.get('sessionId'));
        Object intensity = body.get('intensity');
        Object t = body.get('t');

        Skywave_RestUtil.publishEvent(
            'race_tick',
            sessionId,
            demoSessionId,
            new Map<String, Object>{
                'intensity' => intensity,
                't' => t
            }
        );

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"ok":true}');
    }
}
