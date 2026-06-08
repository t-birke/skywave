/**
 * REST endpoint backing the Heroku /api/website/avatar/:cvId proxy.
 *
 *   GET /services/apexrest/skywave/website/avatar?cvId=<ContentVersionId>
 *      &deviceId=<sealed-deviceId-from-proof-cookie>
 *
 * Why Apex REST and not the direct sobjects/VersionData REST endpoint:
 * the chat-iframe LWC inserts the ContentVersion as the ESW site guest,
 * which leaves the row with no sharing path to any non-guest user. Even
 * with ContentVersion read on the Skywave_Heroku_Website permset the
 * platform returns 404 for the website JWT user. Apex `without sharing`
 * sidesteps that — we re-verify ownership manually by checking that the
 * cvId equals Contact.ContactCardPicture__c for the deviceId-resolved
 * Contact, then return the bytes base64-encoded for the Heroku proxy
 * to decode and stream.
 *
 * Returns:
 *   200 + { contentType, base64 } on success
 *   404 + { error: 'not_found' } if the cvId doesn't match the visitor's
 *        own avatar (defense in depth — the Heroku layer already does
 *        this check, but never trust the client)
 *   400 + { error: 'invalid_input' } if cvId/deviceId are missing/malformed
 */
@RestResource(urlMapping='/skywave/website/avatar')
global without sharing class Skywave_WebsiteAvatar {

    @HttpGet
    global static void get() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        String cvId = req.params.get('cvId');
        String deviceId = req.params.get('deviceId');
        if (String.isBlank(cvId) || String.isBlank(deviceId)) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf('{"error":"invalid_input"}');
            return;
        }

        // Verify ownership: this device's Contact must currently point at
        // exactly this ContentVersion.
        String shepherdPath = '/sfc/servlet.shepherd/version/download/' + cvId;
        List<Contact> cs = [
            SELECT Id FROM Contact
            WHERE Session_Id__c = :deviceId
              AND ContactCardPicture__c = :shepherdPath
            LIMIT 1
        ];
        if (cs.isEmpty()) {
            res.statusCode = 404;
            res.responseBody = Blob.valueOf('{"error":"not_found"}');
            return;
        }

        List<ContentVersion> cvs = [
            SELECT VersionData, FileExtension, FileType
            FROM ContentVersion
            WHERE Id = :cvId
            LIMIT 1
        ];
        if (cvs.isEmpty() || cvs[0].VersionData == null) {
            res.statusCode = 404;
            res.responseBody = Blob.valueOf('{"error":"not_found"}');
            return;
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'contentType' => mimeFor(cvs[0].FileExtension, cvs[0].FileType),
            'base64'      => EncodingUtil.base64Encode(cvs[0].VersionData)
        }));
    }

    private static String mimeFor(String ext, String fileType) {
        String e = (ext == null ? '' : ext.toLowerCase());
        if (e == 'png')  return 'image/png';
        if (e == 'jpg' || e == 'jpeg') return 'image/jpeg';
        if (e == 'gif')  return 'image/gif';
        if (e == 'webp') return 'image/webp';
        if (e == 'svg')  return 'image/svg+xml';
        // FileType is the platform's high-level enum (PNG/JPG/etc); fall back.
        if (fileType != null) {
            String t = fileType.toLowerCase();
            if (t == 'png')  return 'image/png';
            if (t == 'jpg' || t == 'jpeg') return 'image/jpeg';
        }
        return 'application/octet-stream';
    }
}
