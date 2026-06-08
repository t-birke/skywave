/**
 * REST endpoint backing /api/website/session/abandon.
 *
 *   POST /services/apexrest/skywave/website/abandon
 *     { "contactId": "003...",
 *       "reason": "user-closed" | "survey-q3" | "post-survey" | ...,
 *       "partialAnswers": { "<questionKey>": { ... } }   // optional
 *     }
 *
 * Stamps Contact.Skywave_Abandoned_At__c + Skywave_Abandon_Reason__c. If
 * partialAnswers is non-empty AND Skywave_Survey_Json__c is currently
 * blank (i.e. visitor never finished the survey), persists the partial
 * map together with a "Visitor abandoned after Q<n>: ..." summary so the
 * agent has *some* signal to ground on if the visitor later starts a chat.
 *
 * Idempotent: if Skywave_Survey_Json__c is already populated (visitor
 * finished the survey before closing), we don't overwrite it — we only
 * stamp the abandon timestamp / reason. That way late close-after-finish
 * isn't destructive.
 *
 * Runs `with sharing` — the Heroku JWT user has Contact CRUD via the
 * Skywave_Heroku_Website permset; this is the same trust boundary the
 * other website-* endpoints use.
 */
@RestResource(urlMapping='/skywave/website/abandon')
global with sharing class Skywave_WebsiteAbandon {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Map<String, Object> body;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString());
        } catch (Exception e) {
            errorOut(res, 400, 'invalid_json');
            return;
        }

        String contactId = String.valueOf(body.get('contactId'));
        String reason    = String.valueOf(body.get('reason'));
        Object partialAnswersObj = body.get('partialAnswers');

        if (String.isBlank(contactId)) {
            errorOut(res, 400, 'missing_contactId');
            return;
        }
        // Defensive: cap reason length to the field's 40 char limit.
        if (String.isBlank(reason)) {
            reason = 'unknown';
        } else if (reason.length() > 40) {
            reason = reason.substring(0, 40);
        }

        List<Contact> existing = [
            SELECT Id, Skywave_Survey_Json__c
            FROM Contact WHERE Id = :contactId LIMIT 1
        ];
        if (existing.isEmpty()) {
            errorOut(res, 404, 'contact_not_found');
            return;
        }
        Contact c = existing[0];
        c.Skywave_Abandoned_At__c    = Datetime.now();
        c.Skywave_Abandon_Reason__c  = reason;

        // Only persist partial answers if the visitor never finished the
        // survey (Skywave_Survey_Json__c blank). A non-empty existing
        // value means they already have a complete survey — don't downgrade.
        Boolean savedPartial = false;
        if (String.isBlank(c.Skywave_Survey_Json__c)
            && partialAnswersObj instanceof Map<String, Object>) {
            Map<String, Object> partial = (Map<String, Object>) partialAnswersObj;
            if (!partial.isEmpty()) {
                List<String> phrases = new List<String>();
                for (String k : partial.keySet()) {
                    Object v = partial.get(k);
                    if (v instanceof Map<String, Object>) {
                        Map<String, Object> a = (Map<String, Object>) v;
                        Object qt = a.get('questionText');
                        Object at = a.get('answerText');
                        if (qt != null && at != null) {
                            phrases.add(String.valueOf(qt) + ' -> ' + String.valueOf(at));
                        }
                    }
                }
                c.Skywave_Survey_Json__c = JSON.serialize(partial);
                if (!phrases.isEmpty()) {
                    c.Skywave_Survey_Summary__c =
                        'The visitor abandoned the survey. Partial answers: '
                        + String.join(phrases, '; ') + '.';
                }
                savedPartial = true;
            }
        }

        update c;

        Map<String, Object> out = new Map<String, Object>{
            'ok'              => true,
            'contactId'       => c.Id,
            'reason'          => reason,
            'partialPersisted' => savedPartial
        };
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(out));
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
