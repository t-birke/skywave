/**
 * @AuraEnabled imperative target for the Skywave Profile Form LWC.
 *
 * Why @AuraEnabled (not @RestResource): the LWC runs inside the embedded
 * chat iframe, which is a Lightning runtime — it can call Apex directly
 * with a session token, no CORS plumbing needed. Electra uses REST because
 * Electra's UI is a vanilla web app outside Salesforce; Skywave's profile
 * form lives in a CLT renderer, so this is the lighter-weight path.
 *
 * Updates the existing anonymous Contact (created at survey time) with the
 * visitor's real first/last/email/phone. If a base64 avatar is supplied,
 * decodes it to a ContentVersion + ContentDocumentLink linked to the
 * Contact and stamps Contact.Avatar_URL__c with the Shepherd download path.
 *
 * Mirrors TB_createProfile_endpoint.cls pattern from Electra (deletes prior
 * 'profile_from_signup_demo' image to keep things tidy if re-uploaded).
 *
 * Light validation: trims, requires names >= 2 chars and email contains '@'.
 *
 * Runs `without sharing` so the messaging end user (which is what the LWC
 * runs as) can update the Contact regardless of sharing rules.
 */
public without sharing class Skywave_SaveProfile {

    private static final String AVATAR_TITLE = 'profile_from_signup_demo';

    public class Result {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String contactId;
        @AuraEnabled public String avatarUrl;
    }

    @AuraEnabled
    public static Result saveProfile(
        String contactId,
        String firstName,
        String lastName,
        String email,
        String phone,
        String avatarBase64,
        String avatarFileName
    ) {
        Result r = new Result();
        r.success = false;

        String fn = firstName == null ? '' : firstName.trim();
        String ln = lastName == null ? '' : lastName.trim();
        String em = email == null ? '' : email.trim();
        String ph = phone == null ? '' : phone.trim();

        if (String.isBlank(contactId)) {
            r.message = 'Contact Id is required.';
            return r;
        }
        if (fn.length() < 2) {
            r.message = 'First name must be at least 2 characters.';
            return r;
        }
        if (ln.length() < 2) {
            r.message = 'Last name must be at least 2 characters.';
            return r;
        }
        if (!em.contains('@')) {
            r.message = 'Email must contain @.';
            return r;
        }

        try {
            Contact c = new Contact(
                Id = contactId,
                FirstName = fn,
                LastName = ln,
                Email = em,
                Phone = ph
            );
            update c;
            r.contactId = contactId;
        } catch (Exception e) {
            r.message = 'Profile update failed: ' + e.getMessage();
            return r;
        }

        // Optional avatar upload — same recipe as TB_createProfile_endpoint.cls.
        if (String.isNotBlank(avatarBase64)) {
            // Avatar upload pipeline — guest-user-safe.
            //
            // The chat-iframe LWC runs as the ESW site guest user (per memory
            // `reference-ecv2-clt-runtime-context`). That user can:
            //   - INSERT ContentVersion  ✓ (file storage is permissive)
            //   - INSERT ContentDocumentLink against Contact  ✗ (guest can't
            //     see Contact records → platform rejects)
            //   - UPDATE Contact.ContactCardPicture__c  ✗ (no FLS row for the
            //     custom field on the guest profile → write silently fails)
            //
            // The fix: do the file upload here (stage 1, succeeds), then
            // publish a Skywave_Contact_Update__e with the Shepherd URL —
            // the existing trigger runs in System Mode and stamps the
            // Contact field for us (stage 2, succeeds). The CDL insert is
            // skipped entirely; it's purely decorative for the Files
            // related list and we don't need it for the demo.

            String b64 = avatarBase64;
            Integer commaAt = b64.indexOf(',');
            if (commaAt >= 0) {
                // Strip "data:image/png;base64," style prefix.
                b64 = b64.substring(commaAt + 1);
            }

            try {
                deletePriorAvatars(contactId);

                ContentVersion cv = new ContentVersion();
                cv.VersionData = EncodingUtil.base64Decode(b64);
                cv.Title = AVATAR_TITLE;
                cv.ContentLocation = 'S';
                cv.PathOnClient = String.isBlank(avatarFileName) ? 'avatar.png' : avatarFileName;
                insert cv;

                Id contentDocId = [
                    SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1
                ].ContentDocumentId;

                String shepherdUrl = '/sfc/servlet.shepherd/document/download/' + contentDocId;
                r.avatarUrl = shepherdUrl;

                // Look up the visitor's deviceId so the trigger can route
                // the update to the right Contact via Session_Id__c.
                List<Contact> cs = [
                    SELECT Session_Id__c, Demo_Session__c
                    FROM Contact WHERE Id = :contactId LIMIT 1
                ];
                if (cs.isEmpty() || String.isBlank(cs[0].Session_Id__c)) {
                    System.debug(LoggingLevel.WARN,
                        'Skywave_SaveProfile: contact ' + contactId +
                        ' has no Session_Id__c; cannot route avatar PE');
                } else {
                    EventBus.publish(new Skywave_Contact_Update__e(
                        Update_Type__c     = 'avatar',
                        Device_Id__c       = cs[0].Session_Id__c,
                        Demo_Session_Id__c = cs[0].Demo_Session__c,
                        Avatar_Url__c      = shepherdUrl
                    ));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Skywave_SaveProfile avatar error: ' +
                    e.getMessage() + '\n' + e.getStackTraceString());
                r.message = 'Profile saved, avatar upload failed: ' + e.getMessage();
                r.success = true;
                return r;
            }
        }

        r.success = true;
        if (String.isBlank(r.message)) {
            r.message = 'Profile saved.';
        }
        publishProfileCreatedEvent(contactId, fn, ln, r.avatarUrl);
        return r;
    }

    /**
     * Live monitor: replace the cookie-id bubble with the visitor's name +
     * avatar as soon as the profile form is submitted. Best-effort.
     */
    private static void publishProfileCreatedEvent(String contactId, String firstName, String lastName, String avatarUrl) {
        try {
            List<Contact> cs = [
                SELECT Session_Id__c, Demo_Session__c
                FROM Contact WHERE Id = :contactId LIMIT 1
            ];
            if (cs.isEmpty() || String.isBlank(cs[0].Session_Id__c)) return;
            if (cs[0].Demo_Session__c == null) return;  // PE field is required

            Map<String, Object> payload = new Map<String, Object>{
                'firstName' => firstName,
                'lastName'  => lastName
            };
            if (String.isNotBlank(avatarUrl)) payload.put('avatarUrl', avatarUrl);

            Skywave_RestUtil.publishEvent(
                'profile_created',
                cs[0].Session_Id__c,
                cs[0].Demo_Session__c,
                payload
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'profile_created publish skipped: ' + e.getMessage());
        }
    }

    private static void deletePriorAvatars(Id contactId) {
        // ContentDocumentLink can't be used in semi-joins, so do it in two steps.
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :contactId
        ]) {
            docIds.add(cdl.ContentDocumentId);
        }
        if (docIds.isEmpty()) return;

        List<ContentDocument> stale = [
            SELECT Id FROM ContentDocument
            WHERE Title = :AVATAR_TITLE AND Id IN :docIds
        ];
        if (!stale.isEmpty()) {
            delete stale;
        }
    }
}
