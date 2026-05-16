/**
 * POST /services/apexrest/skywave/survey/answer
 *
 * Phase 1 stub. Phase 2 wires this to the consumer site's tap handlers.
 * Body: { "sessionId": "...", "questionKey": "...", "answerKey": "..." }
 *
 * NO DML, NO Data Cloud write. This endpoint exists ONLY to publish a
 * Demo_Event__e for the live monitor tile (see SKYWAVE_INTERACTIVE_DESIGN.md
 * §4b Path B). Persistence + agent grounding flow through the Salesforce
 * Interactions SDK on Path A.
 */
@RestResource(urlMapping='/skywave/survey/answer')
global without sharing class Skywave_SurveyAnswer {
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
        String sessionId = String.valueOf(body.get('sessionId'));
        String questionKey = String.valueOf(body.get('questionKey'));
        String answerKey = String.valueOf(body.get('answerKey'));

        Skywave_RestUtil.publishEvent(
            'survey_answer',
            sessionId,
            demoSessionId,
            new Map<String, Object>{
                'questionKey' => questionKey,
                'answerKey' => answerKey
            }
        );

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"ok":true}');
    }
}
