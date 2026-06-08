/**
 * Single source of truth for "user uploaded an avatar". Both the chat
 * profile-form (Skywave_SaveProfile, runs as the ESW guest) and the
 * website profile form (Skywave_WebsiteSaveProfile, runs as the
 * Heroku JWT-bearer integration user) call into here. The on-disk
 * artifacts — ContentVersion, ContentDistribution, the public CDN URL
 * stamped on Contact.ContactCardPicture__c — are identical regardless
 * of where the bytes came from.
 *
 * What the chat path still does *differently*: it can't write
 * Contact.ContactCardPicture__c as the guest user, so it routes the
 * stamp through Skywave_Contact_Update__e + the System Mode trigger.
 * That divergence stays in Skywave_SaveProfile; this class just owns
 * the bytes-to-public-URL pipeline. The website path calls
 * stampOnContact() directly.
 *
 * runs `with sharing` on purpose — both callers are already running
 * with sharing, and Contact write is gated by the caller's profile.
 */
public with sharing class Skywave_AvatarPipeline {

    public static final String AVATAR_TITLE = 'profile_from_signup_demo';

    /**
     * Decode a base64 (possibly with `data:image/...;base64,` prefix)
     * payload and insert a ContentVersion. Returns the inserted Id.
     * Caller is responsible for catching any DML exception.
     */
    public static Id processAvatarBase64(String avatarBase64, String avatarFileName) {
        if (String.isBlank(avatarBase64)) {
            throw new IllegalArgumentException('avatarBase64 is blank');
        }
        String b64 = avatarBase64;
        Integer commaAt = b64.indexOf(',');
        if (commaAt >= 0) b64 = b64.substring(commaAt + 1);

        ContentVersion cv = new ContentVersion();
        cv.VersionData = EncodingUtil.base64Decode(b64);
        cv.Title = AVATAR_TITLE;
        cv.ContentLocation = 'S';
        cv.PathOnClient = String.isBlank(avatarFileName) ? 'avatar.jpg' : avatarFileName;
        insert cv;
        return cv.Id;
    }

    /**
     * Mint a public ContentDistribution for the given ContentVersion and
     * return the raw-bytes ContentDownloadUrl (what `<img src>` needs).
     * Returns null on failure (caller can fall back to the Shepherd path
     * if it has one).
     *
     * PreferencesAllowOriginalDownload MUST be true — that's what
     * populates ContentDownloadUrl. Without it only DistributionPublicUrl
     * gets set, which serves an HTML preview page that fails in <img>.
     */
    public static String mintPublicUrl(Id contentVersionId) {
        if (contentVersionId == null) return null;
        try {
            ContentDistribution cd = new ContentDistribution(
                Name = 'skywave_avatar_' + contentVersionId,
                ContentVersionId = contentVersionId,
                PreferencesAllowViewInBrowser = true,
                PreferencesAllowOriginalDownload = true,
                PreferencesNotifyOnVisit = false,
                PreferencesPasswordRequired = false
            );
            insert cd;

            // ContentDownloadUrl is populated post-insert; re-query.
            List<ContentDistribution> rows = [
                SELECT ContentDownloadUrl FROM ContentDistribution
                WHERE Id = :cd.Id LIMIT 1
            ];
            if (rows.isEmpty()) return null;
            return rows[0].ContentDownloadUrl;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Skywave_AvatarPipeline.mintPublicUrl failed: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Direct Contact stamp: clear prior profile_from_signup_demo files,
     * set ContactCardPicture__c to the new public URL. ONLY callable by
     * users who can write Contact (e.g. the website path's JWT user).
     * The chat path can't use this because the ESW guest can't write
     * ContactCardPicture__c — see Skywave_SaveProfile for that route.
     */
    public static void stampOnContact(Id contactId, String publicUrl) {
        if (contactId == null || String.isBlank(publicUrl)) return;
        deletePriorAvatars(contactId);
        update new Contact(Id = contactId, ContactCardPicture__c = publicUrl);
    }

    /**
     * Clean up prior avatar attachments for a Contact so we don't pile
     * up ContentDocuments. Same recipe both call paths used inline
     * before extraction — kept here so both share the cleanup.
     */
    public static void deletePriorAvatars(Id contactId) {
        if (contactId == null) return;
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId FROM ContentDocumentLink
            WHERE LinkedEntityId = :contactId
        ]) docIds.add(cdl.ContentDocumentId);
        if (docIds.isEmpty()) return;

        List<ContentDocument> stale = [
            SELECT Id FROM ContentDocument
            WHERE Title = :AVATAR_TITLE AND Id IN :docIds
        ];
        if (!stale.isEmpty()) delete stale;
    }
}
