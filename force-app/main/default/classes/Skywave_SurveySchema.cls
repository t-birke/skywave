/**
 * GET /services/apexrest/skywave/survey/schema
 *
 * Phase 1 stub returns an empty array. Phase 2 reads active
 * Survey_Question__c + Survey_Answer_Option__c rows and returns:
 *   [{ "key": "...", "text": "...", "options": [{ "key", "text", "imageUrl" }] }]
 *
 * Stub now so the URL exists, guest profile + CSP/CORS are pre-cleared.
 */
@RestResource(urlMapping='/skywave/survey/schema')
global without sharing class Skywave_SurveySchema {
    @HttpGet
    global static void get() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');
        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"questions":[]}');
    }
}
