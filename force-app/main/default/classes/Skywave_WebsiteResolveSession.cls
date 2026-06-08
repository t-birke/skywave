/**
 * REST endpoint backing the Heroku /api/website/session/init AND
 * /api/website/session/peek flows.
 *
 *   POST /services/apexrest/skywave/website/resolve
 *     { "deviceId": "<webSdk-or-synthetic>",
 *       "trackingStatus": "websdk" | "synthetic" | "opted_out",
 *       "mintIfMissing": true|false  (default true) }
 *
 * Returns:
 *   { "contactExists": true|false,
 *     "contactId": "003..." | null, "trackingStatus": "websdk",
 *     "firstName": "...", "lastName": "...", "email": "...",
 *     "phone": "...", "homeAirport": "...", "profileCompleted": true|false,
 *     "surveyCompleted": true|false,
 *     "membershipTier": "Gold", "loyaltyPoints": 12500,
 *     "avatarUrl": "..." }
 *
 * Resolution rule: keyed on Contact.Session_Id__c = deviceId. If absent and
 * mintIfMissing=true, mints a placeholder Contact (LastName = deviceId,
 * Session_Id__c = deviceId, Tracking_Status__c = trackingStatus) so every
 * downstream call has a persistent record to write against. If
 * mintIfMissing=false (peek path), returns contactExists=false with all
 * profile fields null — the caller is just asking "have we seen this
 * deviceId before?" Mirrors the cookie-less hardening branch in
 * Skywave_ResolveSession (which keys on Skywave_Conversation_Id__c for
 * the chat agent path).
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
        Boolean mintIfMissing = body.get('mintIfMissing') == null
            ? true
            : Boolean.valueOf(body.get('mintIfMissing'));

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
                   Skywave_Survey_Json__c, Demo_Session__c,
                   Membership_Tier__c, Loyalty_Points__c, Member_Number__c,
                   ContactCardPicture__c, Tracking_Status__c
            FROM Contact
            WHERE Session_Id__c = :deviceId
            LIMIT 1
        ];

        Contact c;
        Boolean contactExists;
        if (existing.isEmpty()) {
            if (!mintIfMissing) {
                // Peek path: tell the caller this deviceId is unknown; do
                // not insert a placeholder. Caller can decide whether to
                // call again with mintIfMissing=true (e.g. on consent).
                Map<String, Object> peekOut = new Map<String, Object>{
                    'contactExists'    => false,
                    'contactId'        => null,
                    'trackingStatus'   => null,
                    'firstName'        => null,
                    'lastName'         => null,
                    'email'            => null,
                    'phone'            => null,
                    'homeAirport'      => null,
                    'profileCompleted' => false,
                    'surveyCompleted'  => false,
                    'membershipTier'   => null,
                    'loyaltyPoints'    => null,
                    'memberNumber'     => null,
                    'avatarUrl'        => null
                };
                res.statusCode = 200;
                res.responseBody = Blob.valueOf(JSON.serialize(peekOut));
                return;
            }
            // Stamp the active Demo_Session__c so downstream PE publishes
            // (Skywave_SaveProfile.publishProfileCreatedEvent → both the
            // monitor Demo_Event__e and the targeted Demo_State_Change__e
            // for client_action=profile_created) have a non-null required
            // Demo_Session_Id__c to use. Without it, both publishes bail
            // and the website never gets the WS push to refresh /me.
            Id activeDemoSessionId = null;
            List<Demo_Session__c> activeRows = [
                SELECT Id FROM Demo_Session__c
                WHERE Active__c = true
                ORDER BY LastModifiedDate DESC
                LIMIT 1
            ];
            if (!activeRows.isEmpty()) activeDemoSessionId = activeRows[0].Id;

            c = new Contact(
                LastName = deviceId,
                Session_Id__c = deviceId,
                Tracking_Status__c = trackingStatus,
                Demo_Session__c = activeDemoSessionId
            );
            insert c;
            contactExists = true;
        } else {
            c = existing[0];
            contactExists = true;
            Boolean dirty = false;
            // Only stamp Tracking_Status__c if not already set, so we don't
            // overwrite an opted_out flag with a later websdk call. opted_out
            // is sticky once set.
            if (String.isBlank(c.Tracking_Status__c)) {
                c.Tracking_Status__c = trackingStatus;
                dirty = true;
            }
            // Backfill Demo_Session__c on legacy website Contacts that were
            // minted before we started stamping it. Without this, the
            // profile_created publishes (monitor + WS push) bail out.
            if (c.Demo_Session__c == null) {
                List<Demo_Session__c> activeRows = [
                    SELECT Id FROM Demo_Session__c
                    WHERE Active__c = true
                    ORDER BY LastModifiedDate DESC
                    LIMIT 1
                ];
                if (!activeRows.isEmpty()) {
                    c.Demo_Session__c = activeRows[0].Id;
                    dirty = true;
                }
            }
            if (dirty) update c;
        }

        Map<String, Object> out = new Map<String, Object>{
            'contactExists'    => contactExists,
            'contactId'        => c.Id,
            'trackingStatus'   => c.Tracking_Status__c,
            'firstName'        => c.FirstName,
            'lastName'         => c.LastName,
            'email'             => c.Email,
            'phone'             => c.Phone,
            'homeAirport'      => c.Home_Airport__c,
            'profileCompleted' => c.Profile_Completed__c == true,
            'surveyCompleted'  => String.isNotBlank(c.Skywave_Survey_Json__c),
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
