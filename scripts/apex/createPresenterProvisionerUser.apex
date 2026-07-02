/**
 * createPresenterProvisionerUser.apex — provision the dedicated admin the Heroku
 * skywave-app authenticates as (JWT bearer) when a colleague self-provisions a
 * presenter account at /request-access (Skywave_PresenterProvision).
 *
 * WHY A DEDICATED ADMIN (not the normal relay user)
 * The relay's normal subject (SF_USERNAME = skywave.heroku.relay) holds a
 * Salesforce Integration license, which can NEVER be granted "Manage Users" —
 * so it cannot create Users or reset passwords. Creating presenter accounts
 * therefore needs a full-license System Administrator subject. This user is it;
 * the Heroku config var SF_PROVISION_USERNAME points at it, and only the
 * /api/onboard path authenticates as it (see sf-auth.js multi-subject).
 *
 * System Administrator profile gives it everything the provisioning needs
 * natively: Manage Users, Reset User Passwords, Assign Permission Sets, and
 * access to every Apex class (so no per-class grant is required). The
 * Skywave_Heroku_Website permset is assigned solely to AUTHORIZE it on the
 * Skywave_Heroku_Relay connected app — that permset already carries the
 * connected-app SetupEntityAccess association, so JWT-bearer works with the
 * same private key as the relay user, no extra UI step.
 *
 * IDEMPOTENT: reuses the user if it exists and only adds the missing permset.
 * Portable: resolves profile/permset by NAME. No password (JWT needs none;
 * welcome email suppressed).
 *
 * After running: set Heroku config var SF_PROVISION_USERNAME to BOT_USERNAME.
 */
String BOT_USERNAME = 'skywave.provisioner@skywave-interactive.demo';
String BOT_EMAIL    = 'tbirke+skywave_provisioner@salesforce.com';

Id profileId = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1].Id;

// Skywave_Heroku_Website authorizes the connected app for JWT-bearer.
List<String> wantNames = new List<String>{ 'Skywave_Heroku_Website' };
Map<String, Id> psByName = new Map<String, Id>();
for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN :wantNames]) {
    psByName.put(p.Name, p.Id);
}

List<User> existing = [SELECT Id FROM User WHERE Username = :BOT_USERNAME LIMIT 1];
Id userId;
if (existing.isEmpty()) {
    User u = new User(
        Username          = BOT_USERNAME,
        FirstName         = 'Skywave',
        LastName          = 'Provisioner',
        Email             = BOT_EMAIL,
        Alias             = 'swprov',
        ProfileId         = profileId,
        TimeZoneSidKey    = 'America/Los_Angeles',
        LocaleSidKey      = 'en_US',
        LanguageLocaleKey = 'en_US',
        EmailEncodingKey  = 'UTF-8',
        IsActive          = true
    );
    Database.DMLOptions dlo = new Database.DMLOptions();
    dlo.EmailHeader.triggerUserEmail = false;   // no welcome email; JWT needs no password
    u.setOptions(dlo);
    insert u;
    userId = u.Id;
} else {
    userId = existing[0].Id;
}

Set<Id> have = new Set<Id>();
for (PermissionSetAssignment a : [
        SELECT PermissionSetId FROM PermissionSetAssignment
        WHERE AssigneeId = :userId AND PermissionSetId IN :psByName.values()]) {
    have.add(a.PermissionSetId);
}
List<PermissionSetAssignment> toAdd = new List<PermissionSetAssignment>();
for (String n : wantNames) {
    Id psId = psByName.get(n);
    if (psId != null && !have.contains(psId)) {
        toAdd.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = psId));
    }
}
if (!toAdd.isEmpty()) insert toAdd;

List<String> missing = new List<String>();
for (String n : wantNames) if (!psByName.containsKey(n)) missing.add(n);

System.debug(LoggingLevel.ERROR, '>>> presenter provisioner user: ' + BOT_USERNAME
    + ' id=' + userId + ' | permsets added=' + toAdd.size()
    + ' | permsets not found=' + missing);
