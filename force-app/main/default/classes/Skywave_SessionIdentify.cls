/**
 * POST /services/apexrest/skywave/session/identify
 *
 * Public REST endpoint exposed via the `skywave_api` Force.com Site,
 * called by the consumer site directly (not through Heroku) on the
 * snippet's `onEmbeddedMessagingConversationStarted` event.
 *
 * Publishes a Skywave_Identify_Session__e Platform Event. A trigger on
 * that event runs in System Mode and stamps MessagingSession.Session_ID__c
 * — that decoupling is what lets the Sites guest user (which can't edit
 * MessagingSession because of the Sites license) drive this feature.
 *
 * Body: { "conversationId": "0dwg8...", "sessionId": "<deviceId>" }
 * Response 202: { "ok": true }   (fire-and-forget; the trigger handles
 *                                  the actual write asynchronously)
 * Response 400: { "error": "missing_conversationId" | "missing_sessionId" }
 *
 * Workaround for the ECv2 platform gap where custom hidden prechat
 * parameters don't propagate to the routing-flow input variable. See
 * SKYWAVE_INTERACTIVE_DESIGN.md § 16 backlog.
 */
@RestResource(urlMapping='/skywave/session/identify')
global without sharing class Skywave_SessionIdentify {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        res.addHeader('Access-Control-Allow-Origin', '*');

        Map<String, Object> body = Skywave_RestUtil.parseBody();
        String conversationId = String.valueOf(body.get('conversationId'));
        String sessionId      = String.valueOf(body.get('sessionId'));

        if (String.isBlank(conversationId)) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf('{"error":"missing_conversationId"}');
            return;
        }
        if (String.isBlank(sessionId)) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf('{"error":"missing_sessionId"}');
            return;
        }

        Skywave_Identify_Session__e ev = new Skywave_Identify_Session__e(
            Conversation_Id__c = conversationId,
            Session_Id__c      = sessionId
        );
        Database.SaveResult result = EventBus.publish(ev);

        if (!result.isSuccess()) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('{"error":"publish_failed"}');
            return;
        }

        res.statusCode = 202;
        res.responseBody = Blob.valueOf('{"ok":true}');
    }
}
