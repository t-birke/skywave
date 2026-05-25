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
            try {
                deletePriorAvatars(contactId);

                String b64 = avatarBase64;
                Integer commaAt = b64.indexOf(',');
                if (commaAt >= 0) {
                    // Strip "data:image/png;base64," style prefix.
                    b64 = b64.substring(commaAt + 1);
                }

                ContentVersion cv = new ContentVersion();
                cv.VersionData = EncodingUtil.base64Decode(b64);
                cv.Title = AVATAR_TITLE;
                cv.ContentLocation = 'S';
                cv.PathOnClient = String.isBlank(avatarFileName) ? 'avatar.png' : avatarFileName;
                insert cv;

                Id contentDocId = [
                    SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1
                ].ContentDocumentId;

                ContentDocumentLink cdl = new ContentDocumentLink();
                cdl.ContentDocumentId = contentDocId;
                cdl.LinkedEntityId = contactId;
                cdl.ShareType = 'V';
                cdl.Visibility = 'AllUsers';
                insert cdl;

                r.avatarUrl = '/sfc/servlet.shepherd/document/download/' + contentDocId;
            } catch (Exception e) {
                // Don't fail the whole save just because the picture didn't take.
                r.message = 'Profile saved, avatar upload failed: ' + e.getMessage();
                r.success = true;
                return r;
            }
        }

        r.success = true;
        if (String.isBlank(r.message)) {
            r.message = 'Profile saved.';
        }
        return r;
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
