/**
 * POST /services/apexrest/skywave/presenter/provision
 *
 * Self-service presenter onboarding. Called by the Heroku relay (running as the
 * JWT-bearer admin) when a colleague requests a demo account at
 * https://<dyno>/request-access. The relay validates the @salesforce.com domain
 * and rate-limits; this class re-validates (defense in depth) and does the work.
 *
 * What it does:
 *   1. Guards the email domain — only @salesforce.com may provision (403 else).
 *   2. Creates a System Administrator User. Admin is required by design: the
 *      presenter drives the entire demo (advances stages, owns Demo_Session__c
 *      rows, runs the monitors). Each admin user consumes a Salesforce license.
 *   3. Assigns the Skywave_Presenter permission-set group — the single bundle
 *      carrying every grant needed to run the demo (see the PSG description).
 *   4. Emails a set-password link via System.resetPassword, DEFERRED to a
 *      Queueable — resetPassword can't run in the same transaction that created
 *      the user, so it fires after this transaction commits.
 *
 * Username = email local-part on the skywave.demo domain, per product decision:
 *   jane.doe@salesforce.com  ->  jane.doe@skywave.demo
 * salesforce.com local-parts are unique per person, so this collides only when
 * the same colleague re-requests — in which case we just re-send their login
 * email (the page doubles as "resend my credentials").
 *
 * PREREQUISITE (org-level, not code): Setup -> Deliverability -> "Access to
 * Send Email" must be "All email", or resetPassword's email is silently
 * dropped. Fresh SDOs often default to "System email only".
 *
 * Body:     { "email": "...", "firstName": "...", "lastName": "..." }
 * Response: { "status": "created" | "resent" | "invalid_domain" | "error",
 *             "username": "...", "message": "..." }
 */
@RestResource(urlMapping='/skywave/presenter/provision')
global without sharing class Skywave_PresenterProvision {

    @TestVisible private static final String ALLOWED_DOMAIN   = 'salesforce.com';
    @TestVisible private static final String USERNAME_SUFFIX  = '@skywave.demo';
    @TestVisible private static final String PROFILE_NAME     = 'System Administrator';
    @TestVisible private static final String PSG_DEVNAME      = 'Skywave_Presenter';

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Map<String, Object> body = Skywave_RestUtil.parseBody();
        String email     = normalizeEmail(String.valueOf(body.get('email')));
        String firstName = blankToNull(String.valueOf(body.get('firstName')));
        String lastName  = blankToNull(String.valueOf(body.get('lastName')));

        if (!isSalesforceEmail(email)) {
            reply(res, 403, 'invalid_domain', null,
                'Only @salesforce.com email addresses can request a demo account.');
            return;
        }

        String handle   = email.substringBefore('@');
        String username = handle + USERNAME_SUFFIX;
        // Names are best-effort — the form collects them, but derive sane
        // fallbacks so a missing value never blocks the required User fields.
        if (String.isBlank(lastName))  lastName  = defaultLastName(handle);
        if (String.isBlank(firstName)) firstName = 'Skywave';

        // Idempotent: an existing presenter account just gets its credentials
        // re-sent. Match on the DERIVED username only — never on Email. The
        // username is a pure function of the (unique) salesforce.com local-part,
        // so it already catches every same-person re-request; matching on Email
        // would additionally collide with any infra user that reuses a corp
        // address as a placeholder (e.g. the relay/website/admin users all carry
        // one operator's email), wrongly resetting THAT user's password instead
        // of creating the presenter account.
        List<User> existing = [
            SELECT Id FROM User
            WHERE Username = :username
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            System.enqueueJob(new ResetPasswordJob(existing[0].Id));
            reply(res, 200, 'resent', username,
                'That account already exists — we have re-sent your login email.');
            return;
        }

        try {
            Id userId = provision(username, email, firstName, lastName);
            System.enqueueJob(new ResetPasswordJob(userId));
            reply(res, 200, 'created', username,
                'Account created — check your inbox for a set-password link.');
        } catch (Exception e) {
            reply(res, 500, 'error', username, friendlyError(e));
        }
    }

    /** Insert the User + assign the presenter PSG. Both are setup-object DML,
     *  so no Mixed-DML barrier applies. Returns the new user Id. */
    private static Id provision(String username, String email, String firstName, String lastName) {
        Id profileId = [SELECT Id FROM Profile WHERE Name = :PROFILE_NAME LIMIT 1].Id;

        User u = new User(
            Username          = username,
            Email             = email,
            FirstName         = firstName,
            LastName          = lastName,
            Alias             = deriveAlias(handleOf(username)),
            ProfileId         = profileId,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            LanguageLocaleKey = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            IsActive          = true
        );
        // Suppress the standard welcome email — we send the set-password link
        // ourselves (deferred) so new and re-requested accounts get the same
        // email, and so it works even when the welcome template is unset.
        Database.DMLOptions dlo = new Database.DMLOptions();
        dlo.EmailHeader.triggerUserEmail = false;
        u.setOptions(dlo);
        insert u;

        PermissionSetGroup psg = [
            SELECT Id FROM PermissionSetGroup WHERE DeveloperName = :PSG_DEVNAME LIMIT 1
        ];
        insert new PermissionSetAssignment(
            AssigneeId = u.Id,
            PermissionSetGroupId = psg.Id
        );
        return u.Id;
    }

    /**
     * Deferred set-password email. resetPassword cannot target a user created
     * in the same transaction, so provisioning enqueues this to run after the
     * commit. Skipped in test context (resetPassword is not callable there).
     */
    public class ResetPasswordJob implements Queueable {
        private final Id userId;
        public ResetPasswordJob(Id userId) { this.userId = userId; }
        public void execute(QueueableContext ctx) {
            if (Test.isRunningTest()) return;
            // true => email the user a temporary password + change-password link.
            System.resetPassword(userId, true);
        }
    }

    // ---- helpers -----------------------------------------------------------

    private static String normalizeEmail(String raw) {
        return (raw == null) ? '' : raw.trim().toLowerCase();
    }

    private static String blankToNull(String s) {
        return String.isBlank(s) || s == 'null' ? null : s.trim();
    }

    /** True only when the domain is EXACTLY salesforce.com (not a sub/lookalike). */
    @TestVisible
    private static Boolean isSalesforceEmail(String email) {
        if (String.isBlank(email) || email.countMatches('@') != 1) return false;
        return email.substringAfterLast('@') == ALLOWED_DOMAIN;
    }

    private static String handleOf(String username) {
        return username.substringBefore('@');
    }

    /** Alias: alphanumerics of the handle, capped at 8 chars (Alias max). */
    private static String deriveAlias(String handle) {
        String cleaned = handle.replaceAll('[^a-zA-Z0-9]', '');
        if (String.isBlank(cleaned)) cleaned = 'skywave';
        return cleaned.length() > 8 ? cleaned.substring(0, 8) : cleaned;
    }

    /** Fallback LastName from the handle (e.g. "jane.doe" -> "Doe"). */
    private static String defaultLastName(String handle) {
        String tail = handle.contains('.') ? handle.substringAfterLast('.') : handle;
        tail = tail.replaceAll('[^a-zA-Z0-9]', '');
        if (String.isBlank(tail)) return 'Presenter';
        return tail.substring(0, 1).toUpperCase() + (tail.length() > 1 ? tail.substring(1) : '');
    }

    private static String friendlyError(Exception e) {
        String msg = e.getMessage();
        if (msg != null && msg.containsIgnoreCase('LICENSE')) {
            return 'No Salesforce licenses are available on this org right now.';
        }
        return 'Could not create the account — please contact the demo owner.';
    }

    private static void reply(RestResponse res, Integer status, String state, String username, String message) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'status'   => state,
            'username' => username,
            'message'  => message
        }));
    }
}
