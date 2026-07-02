/**
 * Covers the self-service presenter provisioning endpoint:
 *   - @salesforce.com domain gate (accepts salesforce.com, rejects lookalikes)
 *   - happy path: User created with handle@skywave.demo username + admin
 *     profile + Skywave_Presenter PSG assigned
 *   - idempotent re-request returns "resent" without creating a second user
 *
 * The Queueable's System.resetPassword is a no-op under test (guarded by
 * Test.isRunningTest) — resetPassword is not callable in test context.
 */
@IsTest
private class Skywave_PresenterProvision_Test {

    private static Map<String, Object> invoke(String jsonBody) {
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(jsonBody);
        RestContext.response = new RestResponse();
        Skywave_PresenterProvision.post();
        return (Map<String, Object>) JSON.deserializeUntyped(
            RestContext.response.responseBody.toString());
    }

    @IsTest
    static void rejectsNonSalesforceDomain() {
        // Exact-domain check: lookalikes and subdomains must fail.
        System.assert(!Skywave_PresenterProvision.isSalesforceEmail('x@salesforce.com.evil.com'));
        System.assert(!Skywave_PresenterProvision.isSalesforceEmail('x@evilsalesforce.com'));
        System.assert(!Skywave_PresenterProvision.isSalesforceEmail('x@example.com'));
        System.assert(Skywave_PresenterProvision.isSalesforceEmail('x@salesforce.com'));

        Test.startTest();
        Map<String, Object> out = invoke('{"email":"someone@example.com","firstName":"A","lastName":"B"}');
        Test.stopTest();

        System.assertEquals('invalid_domain', out.get('status'));
        System.assertEquals(403, RestContext.response.statusCode);
    }

    @IsTest
    static void createsPresenterAndReRequestResends() {
        // PSG assignment needs the group calculated in test context.
        Id psgId = [SELECT Id FROM PermissionSetGroup WHERE DeveloperName = 'Skywave_Presenter' LIMIT 1].Id;
        Test.calculatePermissionSetGroup(psgId);

        Test.startTest();
        Map<String, Object> created = invoke(
            '{"email":"Jane.Doe@salesforce.com","firstName":"Jane","lastName":"Doe"}');
        // Second, identical request → resend, no new user.
        Map<String, Object> resent = invoke(
            '{"email":"jane.doe@salesforce.com","firstName":"Jane","lastName":"Doe"}');
        Test.stopTest();

        System.assertEquals('created', created.get('status'), created.get('message'));
        System.assertEquals('jane.doe@skywave.demo', created.get('username'),
            'username = lowercased email local-part on skywave.demo');
        System.assertEquals('resent', resent.get('status'));

        List<User> users = [
            SELECT Id, ProfileId, IsActive FROM User WHERE Username = 'jane.doe@skywave.demo'];
        System.assertEquals(1, users.size(), 'exactly one user, not duplicated on re-request');
        System.assertEquals(true, users[0].IsActive);

        System.assertEquals(1, [
            SELECT COUNT() FROM PermissionSetAssignment
            WHERE AssigneeId = :users[0].Id AND PermissionSetGroupId = :psgId
        ], 'presenter PSG assigned exactly once');
    }
}
