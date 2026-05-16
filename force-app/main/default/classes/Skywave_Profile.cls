/**
 * POST /services/apexrest/skywave/profile
 *
 * Phase 1 stub returns 501 Not Implemented. Phase 4 fully implements:
 *   - Body: { "sessionId", "firstName", "lastName", "email", "avatarBase64" }
 *   - Inserts Contact with Session_Id__c = sessionId, Demo_Session__c = active run
 *   - Uploads avatar as ContentVersion linked to the Contact
 *   - Publishes Demo_Event__e (type=profile_created)
 *
 * Stub now so the URL exists, the guest profile grants access, and the
 * site CSP/CORS lets the consumer site's POST through.
 */
@RestResource(urlMapping='/skywave/profile')
global without sharing class Skywave_Profile {
    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        res.statusCode = 501;
        res.responseBody = Blob.valueOf('{"error":"not_implemented","phase":4}');
    }
}
