/**
 * createRefreshAutomationUser.apex — provision the dedicated CI user that the
 * refresh-observability GitHub Action authenticates as (JWT bearer).
 *
 * WHY A DEDICATED USER (not the relay integration user or the human admin)
 * The daily dashboard refresh drives the DataStream Lightning UI via a browser
 * (SalesforceDotCom streams reject every non-interactive caller). That subject
 * user must therefore be BOTH:
 *   1. full-license + UI-capable + Data-Cloud-enabled (open DataStream pages,
 *      click Full Refresh), and
 *   2. JWT-authorized on the Skywave_Heroku_Relay connected app.
 * The relay integration user is API-Only (Salesforce Integration license) → no
 * UI. The admin has (1) but not (2). This script creates a purpose-built user
 * that has both, keeping CI credentials off the human admin.
 *
 * Standard User profile is chosen because it is full-license, UI-capable, AND
 * already an authorized entity on the Relay connected app; the Skywave_Heroku_Website
 * permset is also assigned as the documented, redeploy-safe app-authorization
 * mechanism (belt and suspenders). Data Cloud UI access comes from CDPAdmin +
 * xDO_DataCloud_Base_PSG + SDO_Data_Cloud_Default_Data_Space; the observability
 * app/tabs from SDO_Agentforce_Analytics.
 *
 * IDEMPOTENT: reuses the user if it already exists and only adds missing permsets.
 * Portable: resolves profile/permsets by NAME (no org-specific IDs), so it works
 * on a rebuilt SDO. No password is set — JWT bearer needs none; the welcome email
 * is suppressed.
 *
 * After running: set the GitHub Actions secret SF_USERNAME to BOT_USERNAME below.
 */
String BOT_USERNAME = 'skywave.refresh.bot@skywave-interactive.demo';
String BOT_EMAIL    = 'tbirke+skywave_refresh_bot@salesforce.com';

Id profileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;

List<String> wantNames = new List<String>{
    'CDPAdmin', 'xDO_DataCloud_Base_PSG', 'SDO_Data_Cloud_Default_Data_Space',
    'SDO_Agentforce_Analytics', 'Skywave_Heroku_Website'
};
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
        LastName          = 'Refresh Bot',
        Email             = BOT_EMAIL,
        Alias             = 'swrfbot',
        ProfileId         = profileId,
        TimeZoneSidKey    = 'Australia/Sydney',
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

System.debug(LoggingLevel.ERROR, '>>> refresh automation user: ' + BOT_USERNAME
    + ' id=' + userId + ' | permsets added=' + toAdd.size()
    + ' | permsets not found=' + missing);
