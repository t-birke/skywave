/**
 * REST endpoint backing the Heroku /api/website/profile (PUT/PATCH).
 *
 *   POST /services/apexrest/skywave/website/profile/save
 *     { "contactId": "003...", "firstName": "...", "lastName": "...",
 *       "email": "...", "phone": "..." }
 *
 * Mirrors Skywave_UpdateContact.cls (the chat-agent path) — same field
 * set, same validation, sets Profile_Completed__c=true on success so the
 * "form already filled" hardening works cross-channel.
 *
 * Avatar upload is NOT handled here; the chat-iframe LWC handles avatars
 * separately because it has the bytes already (canvas crop) and routes
 * them through the PE pattern. The website edit page only edits text;
 * the avatar (if any) was uploaded during chat or is null.
 *
 * Returns: { "ok": true, "contactId": "..." }
 *           or { "error": "<code>" }
 */
@RestResource(urlMapping='/skywave/website/profile/save')
global with sharing class Skywave_WebsiteSaveProfile {

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
        String firstName = trim(body.get('firstName'));
        String lastName  = trim(body.get('lastName'));
        String email     = trim(body.get('email'));
        String phone     = trim(body.get('phone'));

        if (String.isBlank(contactId))   { errorOut(res, 400, 'missing_contactId'); return; }
        if (firstName.length() < 2)      { errorOut(res, 400, 'invalid_firstName'); return; }
        if (lastName.length()  < 2)      { errorOut(res, 400, 'invalid_lastName');  return; }
        if (!email.contains('@'))        { errorOut(res, 400, 'invalid_email');     return; }

        try {
            Contact c = new Contact(
                Id = contactId,
                FirstName = firstName,
                LastName = lastName,
                Email = email,
                Profile_Completed__c = true
            );
            if (String.isNotBlank(phone)) c.Phone = phone;
            update c;

            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'ok' => true,
                'contactId' => contactId
            }));
        } catch (Exception e) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'error' => 'save_failed',
                'message' => e.getMessage()
            }));
        }
    }

    private static String trim(Object v) {
        if (v == null) return '';
        return String.valueOf(v).trim();
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
