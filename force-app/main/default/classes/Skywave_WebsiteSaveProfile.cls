/**
 * REST endpoint backing the Heroku /api/website/profile (PUT/PATCH).
 *
 *   POST /services/apexrest/skywave/website/profile/save
 *     { "contactId": "003...", "firstName": "...", "lastName": "...",
 *       "email": "...", "phone": "...",
 *       "avatarBase64": "data:image/jpeg;base64,...",  // optional
 *       "avatarFileName": "tom.jpg" }                  // optional
 *
 * Mirrors Skywave_UpdateContact.cls (the chat-agent path) for the text
 * fields, and shares the avatar bytes-to-public-URL pipeline with
 * Skywave_SaveProfile (the chat-iframe LWC path) via
 * Skywave_AvatarPipeline. The website path runs as the JWT-bearer
 * Skywave_Heroku_Website user, which has full Contact write — so unlike
 * the chat path, this class can stamp Contact.ContactCardPicture__c
 * directly without routing through the PE-trigger workaround.
 *
 * Two modes:
 *
 *   - Full save: firstName + lastName + email all present. Validates,
 *     writes text fields, sets Profile_Completed__c=true, optionally
 *     processes avatar.
 *
 *   - Avatar-only: text fields blank/missing AND avatarBase64 present.
 *     For the nav greeting "click avatar to swap photo" flow. Writes
 *     just the avatar URL; doesn't touch text fields or
 *     Profile_Completed__c.
 *
 * Returns: { "ok": true, "contactId": "...", "avatarUrl": "..." }
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

        String contactId      = String.valueOf(body.get('contactId'));
        String firstName      = trim(body.get('firstName'));
        String lastName       = trim(body.get('lastName'));
        String email          = trim(body.get('email'));
        String phone          = trim(body.get('phone'));
        String avatarBase64   = trim(body.get('avatarBase64'));
        String avatarFileName = trim(body.get('avatarFileName'));

        if (String.isBlank(contactId)) { errorOut(res, 400, 'missing_contactId'); return; }

        // Full save vs avatar-only. Full save = any text field present;
        // avatar-only = all text fields blank but avatar present. Mixing
        // (one text field + avatar) is invalid — likely a client bug.
        Boolean hasAnyText = String.isNotBlank(firstName)
            || String.isNotBlank(lastName) || String.isNotBlank(email);
        Boolean hasAvatar = String.isNotBlank(avatarBase64);

        if (!hasAnyText && !hasAvatar) {
            errorOut(res, 400, 'empty_payload');
            return;
        }

        try {
            Map<String, Object> out = new Map<String, Object>{
                'ok' => true,
                'contactId' => contactId
            };

            String avatarUrl = null;
            if (hasAvatar) {
                Id cvId = Skywave_AvatarPipeline.processAvatarBase64(avatarBase64, avatarFileName);
                String publicUrl = Skywave_AvatarPipeline.mintPublicUrl(cvId);
                if (String.isNotBlank(publicUrl)) {
                    Skywave_AvatarPipeline.stampOnContact(contactId, publicUrl);
                    out.put('avatarUrl', publicUrl);
                    avatarUrl = publicUrl;
                } else {
                    out.put('avatarWarning',
                        'Avatar saved but ContentDistribution mint failed; <img> may not load.');
                }
            }

            if (hasAnyText) {
                if (firstName.length() < 2) { errorOut(res, 400, 'invalid_firstName'); return; }
                if (lastName.length()  < 2) { errorOut(res, 400, 'invalid_lastName');  return; }
                if (!email.contains('@'))   { errorOut(res, 400, 'invalid_email');     return; }

                Contact c = new Contact(
                    Id = contactId,
                    FirstName = firstName,
                    LastName = lastName,
                    Email = email,
                    Profile_Completed__c = true
                );
                if (String.isNotBlank(phone)) c.Phone = phone;
                update c;
            }

            // Fire the same monitor + WS-targeted publishes the chat path
            // does (Skywave_SaveProfile.publishProfileCreatedEvent). The
            // website surface deserves the same demo-monitor bubble swap
            // and the same nav-refresh push for any other tabs the visitor
            // has open. Best-effort — never block the save on a publish.
            if (hasAnyText) {
                Skywave_SaveProfile.publishProfileCreatedExternal(
                    contactId, firstName, lastName, avatarUrl);
            } else if (hasAvatar) {
                // Avatar-only update: still push a profile_created so the
                // monitor picks up the new picture and any other tabs
                // refresh /me. Names are read from the existing Contact
                // by the helper.
                Skywave_SaveProfile.publishProfileCreatedExternal(
                    contactId, null, null, avatarUrl);
            }

            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(out));
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
