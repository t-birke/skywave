/**
 * REST endpoint backing the Heroku /api/website/session/init flow.
 *
 *   POST /services/apexrest/skywave/website/resolve
 *     { "deviceId": "<webSdk-or-synthetic>",
 *       "trackingStatus": "websdk" | "synthetic" | "opted_out" }
 *
 * Returns:
 *   { "contactId": "003...", "trackingStatus": "websdk",
 *     "firstName": "...", "lastName": "...", "email": "...",
 *     "phone": "...", "homeAirport": "...", "profileCompleted": true|false,
 *     "membershipTier": "Gold", "loyaltyPoints": 12500,
 *     "avatarUrl": "..." }
 *
 * Resolution rule: keyed on Contact.Session_Id__c = deviceId. If absent,
 * mints a placeholder Contact (LastName = deviceId, Session_Id__c = deviceId,
 * Tracking_Status__c = trackingStatus) so every downstream call has a
 * persistent record to write against. Mirrors the cookie-less hardening
 * branch in Skywave_ResolveSession (which keys on Skywave_Conversation_Id__c
 * for the chat agent path).
 *
 * The Heroku relay calls this with the integration user's JWT-bearer token
 * — runs `with sharing` because the integration user has full Contact CRUD.
 */
@RestResource(urlMapping='/skywave/website/resolve')
global with sharing class Skywave_WebsiteResolveSession {

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

        String deviceId = String.valueOf(body.get('deviceId'));
        String trackingStatus = String.valueOf(body.get('trackingStatus'));

        if (String.isBlank(deviceId)) {
            errorOut(res, 400, 'missing_deviceId');
            return;
        }
        // Defensive: only allow our three values. Default to 'synthetic' on
        // anything unexpected — it's the safer assumption (Data Cloud filters
        // to websdk explicitly, so a misclassified record is silently skipped
        // rather than wrongly counted).
        Set<String> allowed = new Set<String>{ 'websdk', 'synthetic', 'opted_out' };
        if (!allowed.contains(trackingStatus)) {
            trackingStatus = 'synthetic';
        }

        List<Contact> existing = [
            SELECT Id, FirstName, LastName, Email, Phone,
                   Home_Airport__c, Profile_Completed__c,
                   Membership_Tier__c, Loyalty_Points__c, Member_Number__c,
                   ContactCardPicture__c, Tracking_Status__c
            FROM Contact
            WHERE Session_Id__c = :deviceId
            LIMIT 1
        ];

        Contact c;
        if (existing.isEmpty()) {
            c = new Contact(
                LastName = deviceId,
                Session_Id__c = deviceId,
                Tracking_Status__c = trackingStatus
            );
            insert c;
        } else {
            c = existing[0];
            // Only stamp Tracking_Status__c if not already set, so we don't
            // overwrite an opted_out flag with a later websdk call. opted_out
            // is sticky once set.
            if (String.isBlank(c.Tracking_Status__c)) {
                c.Tracking_Status__c = trackingStatus;
                update c;
            }
        }

        Map<String, Object> out = new Map<String, Object>{
            'contactId'        => c.Id,
            'trackingStatus'   => c.Tracking_Status__c,
            'firstName'        => c.FirstName,
            'lastName'         => c.LastName,
            'email'            => c.Email,
            'phone'            => c.Phone,
            'homeAirport'      => c.Home_Airport__c,
            'profileCompleted' => c.Profile_Completed__c == true,
            'membershipTier'   => c.Membership_Tier__c,
            'loyaltyPoints'    => c.Loyalty_Points__c,
            'memberNumber'     => c.Member_Number__c,
            'avatarUrl'        => c.ContactCardPicture__c
        };
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(out));
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
