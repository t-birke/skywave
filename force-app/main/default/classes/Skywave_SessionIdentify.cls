/**
 * POST /services/apexrest/skywave/session/identify
 *
 * **WORKAROUND ENDPOINT.** Stamps the visitor's Skywave deviceId onto
 * `MessagingSession.Session_ID__c` so the agent's `linked` variable can
 * read it. This should ideally happen via the ECv2 prechat path
 * (setHiddenPrechatFields → channel customParameters → routing-flow
 * input → Update Records), but as of May 2026 the platform doesn't pass
 * custom prechat parameters into routing flow inputs in ECv2. See
 * SKYWAVE_INTERACTIVE_DESIGN.md § 16 backlog "Replace Session_ID
 * JS-side write with the standard ECv2 prechat path" for the removal
 * plan once the platform gap closes.
 *
 * The consumer site calls this on the snippet's
 * `onEmbeddedMessagingConversationStarted` event.
 *
 * Body: { "conversationId": "0dwg8...", "sessionId": "<deviceId>" }
 * Response 200: { "ok": true, "messagingSessionId": "0Mw..." }
 * Response 404: { "error": "no_messaging_session" }
 * Response 400: { "error": "missing_conversationId" | "missing_sessionId" }
 */
@RestResource(urlMapping='/skywave/session/identify')
global without sharing class Skywave_SessionIdentify {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

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

        // The MessagingSession record is sometimes not yet visible to the
        // running user the moment the conversation is created (the platform
        // creates the record but read-visibility takes a beat). The JS
        // posts immediately on onEmbeddedMessagingConversationStarted, so
        // we may race the platform's commit — retry briefly before giving
        // up. Apex doesn't have setTimeout, so we burn a CPU-bound delay
        // via Datetime polling. Three attempts at ~500ms each = 1.5s max.
        MessagingSession ms = null;
        for (Integer attempt = 0; attempt < 3; attempt++) {
            List<MessagingSession> sessions = [
                SELECT Id, Session_ID__c
                FROM MessagingSession
                WHERE ConversationId = :conversationId
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!sessions.isEmpty()) {
                ms = sessions[0];
                break;
            }
            if (attempt < 2) {
                Long start = System.currentTimeMillis();
                while (System.currentTimeMillis() - start < 500) { /* spin */ }
            }
        }
        if (ms == null) {
            res.statusCode = 404;
            res.responseBody = Blob.valueOf('{"error":"no_messaging_session"}');
            return;
        }

        if (ms.Session_ID__c != sessionId) {
            ms.Session_ID__c = sessionId;
            update ms;
        }

        Map<String, Object> out = new Map<String, Object>{
            'ok' => true,
            'messagingSessionId' => ms.Id
        };
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(out));
    }
}
