/**
 * Backfill observability access for EXISTING self-service presenter accounts.
 *
 * Self-provisioned presenters (created via /request-access before the
 * Skywave_PresenterProvision observability change) were assigned only the
 * Skywave_Presenter PSG + globe — they lacked the permsets/PSGs that make the
 * Agentforce observability dashboards and scorers visible. The SDO admin had
 * those; presenters didn't. This grants presenters the same observability
 * bundle so they reach dashboard + scorer parity.
 *
 * Cohort = ACTIVE users holding the Skywave_Presenter PSG. That PSG is the
 * precise selector: the original SDO admins don't hold it, and neither do the
 * seeded persona users (SDO-Sales/Service/etc.), so we touch only real
 * self-provisioned presenters.
 *
 * Idempotent: only missing grants are inserted, so it's safe to re-run.
 * Best-effort: a tier absent from this org, or a PSL a user can't hold, is
 * skipped (allOrNone=false) — it never blocks the grants that CAN be made.
 *
 * Run:  sf apex run --target-org si --file scripts/apex/backfillPresenterObservability.apex
 */

// Keep this list in lock-step with OPTIONAL_PERMSETS / OPTIONAL_PSGS in
// Skywave_PresenterProvision.cls (minus the always-in-repo Skywave_Globe_App,
// which existing presenters already have).
Set<String> permsetNames = new Set<String>{
    'SDO_Agentforce_Analytics',           // SDO_Analytics_* objects -> Observability Demo app
    'SDO_Data_Cloud_Default_Data_Space',  // Data Cloud data-space access
    'AgentforceInteractionExplorer',      // Access Agentforce Optimization (Observe & Optimize)
    'AgentforceScorerActivation'          // Activate Agentforce Scorer (Beta)
};
Set<String> psgNames = new Set<String>{
    'xDO_DataCloud_Base_PSG',             // Data Cloud User -> STDM behind the dashboards
    'SDO_Analytics_Base_Permissions'      // CRM Analytics viewing
};

// --- Cohort: active presenters (hold the Skywave_Presenter PSG) -------------
Set<Id> cohort = new Set<Id>();
for (PermissionSetAssignment a : [
        SELECT AssigneeId FROM PermissionSetAssignment
        WHERE PermissionSetGroup.DeveloperName = 'Skywave_Presenter'
          AND Assignee.IsActive = true]) {
    cohort.add(a.AssigneeId);
}

// --- Resolve the grants that actually exist in THIS org ---------------------
Map<Id, String> psById = new Map<Id, String>();
for (PermissionSet ps : [SELECT Id, Name FROM PermissionSet WHERE Name IN :permsetNames]) {
    psById.put(ps.Id, ps.Name);
}
Map<Id, String> psgById = new Map<Id, String>();
for (PermissionSetGroup g : [SELECT Id, DeveloperName FROM PermissionSetGroup WHERE DeveloperName IN :psgNames]) {
    psgById.put(g.Id, g.DeveloperName);
}

// --- What each cohort user already has (so we never double-assign) ----------
// A PSG assignment sets PermissionSetGroupId (+ an aggregate PermissionSetId we
// ignore); a permset assignment sets PermissionSetId with a null group.
Set<String> have = new Set<String>();
for (PermissionSetAssignment a : [
        SELECT AssigneeId, PermissionSetId, PermissionSetGroupId
        FROM PermissionSetAssignment
        WHERE AssigneeId IN :cohort
          AND (PermissionSetId IN :psById.keySet() OR PermissionSetGroupId IN :psgById.keySet())]) {
    if (a.PermissionSetGroupId != null) have.add(a.AssigneeId + '|G' + a.PermissionSetGroupId);
    else                                have.add(a.AssigneeId + '|P' + a.PermissionSetId);
}

// --- Build the missing assignments ------------------------------------------
List<PermissionSetAssignment> toInsert = new List<PermissionSetAssignment>();
for (Id uid : cohort) {
    for (Id psId : psById.keySet()) {
        if (!have.contains(uid + '|P' + psId)) {
            toInsert.add(new PermissionSetAssignment(AssigneeId = uid, PermissionSetId = psId));
        }
    }
    for (Id gId : psgById.keySet()) {
        if (!have.contains(uid + '|G' + gId)) {
            toInsert.add(new PermissionSetAssignment(AssigneeId = uid, PermissionSetGroupId = gId));
        }
    }
}

Database.SaveResult[] results = Database.insert(toInsert, false);
Integer ok = 0, fail = 0;
for (Integer i = 0; i < results.size(); i++) {
    if (results[i].isSuccess()) {
        ok++;
    } else {
        fail++;
        System.debug(LoggingLevel.WARN, 'BACKFILL skip: ' + toInsert[i] + ' -> ' + results[i].getErrors());
    }
}
System.debug(LoggingLevel.INFO,
    'BACKFILL cohort=' + cohort.size()
    + ' permsetsInOrg=' + psById.size() + ' psgsInOrg=' + psgById.size()
    + ' attempted=' + toInsert.size() + ' granted=' + ok + ' skipped=' + fail);
