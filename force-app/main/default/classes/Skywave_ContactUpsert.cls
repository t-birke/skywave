/**
 * POST /services/apexrest/skywave/contact/upsert
 *
 * Public anonymous endpoint exposed via the `skywave_api` Force.com Site,
 * called from the consumer site at two moments:
 *
 *   1. Survey-complete (the "thanks" screen renders):
 *        { "type": "survey_complete", "deviceId": "...",
 *          "demoSessionId": "...", "responsesJson": "{...}",
 *          "summary": "..." }
 *
 *   2. Chat-start (onEmbeddedMessagingConversationStarted):
 *        { "type": "chat_start", "deviceId": "...",
 *          "demoSessionId": "...", "conversationId": "..." }
 *
 * Publishes a Skywave_Contact_Update__e Platform Event. The trigger on
 * that PE upserts the Contact in System Mode (the Sites Guest user
 * doesn't need Contact perms — this is intentional defense in depth).
 *
 * Idempotent: each call only writes the fields supplied by its `type`.
 * Order doesn't matter; the first call creates the Contact, later
 * calls update it.
 *
 * Response 202: { "ok": true }
 * Response 400: { "error": "missing_<field>" | "invalid_type" }
 */
@RestResource(urlMapping='/skywave/contact/upsert')
global without sharing class Skywave_ContactUpsert {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        res.addHeader('Access-Control-Allow-Origin', '*');

        Map<String, Object> body = Skywave_RestUtil.parseBody();
        String updateType    = String.valueOf(body.get('type'));
        String deviceId      = String.valueOf(body.get('deviceId'));
        String demoSessionId = String.valueOf(body.get('demoSessionId'));

        if (String.isBlank(deviceId)) {
            errorOut(res, 400, 'missing_deviceId');
            return;
        }
        if (updateType != 'survey_complete' && updateType != 'chat_start') {
            errorOut(res, 400, 'invalid_type');
            return;
        }

        Skywave_Contact_Update__e ev = new Skywave_Contact_Update__e(
            Update_Type__c     = updateType,
            Device_Id__c       = deviceId,
            Demo_Session_Id__c = demoSessionId
        );

        if (updateType == 'survey_complete') {
            String responsesJson = String.valueOf(body.get('responsesJson'));
            String summary       = String.valueOf(body.get('summary'));
            if (String.isBlank(responsesJson)) {
                errorOut(res, 400, 'missing_responsesJson');
                return;
            }
            ev.Survey_Json__c    = responsesJson;
            ev.Survey_Summary__c = summary;
        } else {
            String conversationId = String.valueOf(body.get('conversationId'));
            if (String.isBlank(conversationId)) {
                errorOut(res, 400, 'missing_conversationId');
                return;
            }
            ev.Conversation_Id__c = conversationId;
        }

        Database.SaveResult result = EventBus.publish(ev);
        if (!result.isSuccess()) {
            errorOut(res, 500, 'publish_failed');
            return;
        }

        res.statusCode = 202;
        res.responseBody = Blob.valueOf('{"ok":true}');
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
