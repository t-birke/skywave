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
                Phone = ph,
                Profile_Completed__c = true
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
            // reference-ecv2-clt-runtime-context). Two non-obvious limits:
            //
            // 1. The guest can INSERT a ContentVersion, but cannot read back
            //    its parent ContentDocumentId in the same transaction — even
            //    via Database.queryWithBinds(... SYSTEM_MODE). The platform
            //    reassigns ownership of guest-uploaded files to a different
            //    user, and the resulting ContentDocument / link rows aren't
            //    visible in the guest's sharing scope. Net: any code that
            //    needs the docId crashes or silently sees null. WORKAROUND:
            //    use the /sfc/servlet.shepherd/version/download/<cvId>
            //    Shepherd URL (which references the ContentVersion directly,
            //    no docId lookup needed). It serves the file content the
            //    same way as /document/download/<docId>.
            //
            // 2. The guest cannot UPDATE Contact.ContactCardPicture__c
            //    directly — the write silently fails. WORKAROUND: publish a
            //    Skywave_Contact_Update__e (guests CAN publish PEs) and let
            //    the existing trigger run in System Mode and stamp the
            //    Contact field for us.
            //
            // Both workarounds combined give a fully guest-safe pipeline.
            // The legacy ContentDocumentLink insert is skipped — it was
            // decorative (Files related list on the Contact page in CRM)
            // and the guest can't insert one against a Contact anyway.

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

                // Version-download URL — see header comment for why we
                // can't resolve the document Id as the guest user.
                String shepherdUrl = '/sfc/servlet.shepherd/version/download/' + cv.Id;
                r.avatarUrl = shepherdUrl;

                // Route the Contact stamp through the System-Mode trigger
                // via a Skywave_Contact_Update__e. Look up the visitor's
                // deviceId from Contact (this query DOES work for the guest
                // — Contact reads are permitted, only writes to the custom
                // field aren't).
                List<Contact> cs = [
                    SELECT Session_Id__c, Demo_Session__c
                    FROM Contact WHERE Id = :contactId LIMIT 1
                ];
                if (!cs.isEmpty() && String.isNotBlank(cs[0].Session_Id__c)
                    && cs[0].Demo_Session__c != null) {
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
