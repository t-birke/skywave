trigger Demo_Session_Trigger on Demo_Session__c (before insert, before update, after insert, after update) {
    // ── before insert/update: maintain the multi-tenancy Active guard ─────
    // Active_Owner_Key__c mirrors OwnerId while Active__c=true and is blank
    // otherwise. Because that field is Unique, this is what structurally caps
    // a presenter to ONE active Demo_Session__c at a time: a second active row
    // for the same owner collides on the key and fails with DUPLICATE_VALUE.
    // Doing it here (not just in the controller) means the guard holds no
    // matter how Active__c gets set — Demo Home, the record page, or a data load.
    if (Trigger.isBefore) {
        for (Demo_Session__c rec : Trigger.new) {
            // OwnerId carries the running-user default before this trigger
            // fires; coalesce defensively for explicit-owner inserts.
            Id ownerId = (rec.OwnerId != null) ? rec.OwnerId : UserInfo.getUserId();
            rec.Active_Owner_Key__c = (rec.Active__c == true) ? String.valueOf(ownerId) : null;
        }
        return;
    }

    // ── after insert: create the per-Demo_Session anonymous Account ───────
    // Each demo run gets its own Account that anonymous Contacts (created
    // by Skywave_ContactUpsert as visitors complete the survey) hang off.
    // Lets the post-demo cleanup script delete a single Account and have
    // its Contacts go with it, and gives a tidy "audience tonight" view.
    if (Trigger.isInsert) {
        List<Account> toInsert = new List<Account>();
        for (Demo_Session__c rec : Trigger.new) {
            toInsert.add(new Account(
                Name = 'Skywave Demo - ' + rec.Name,
                Skywave_Demo_Session__c = rec.Id
            ));
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        return;
    }

    // ── after update: existing State__c → Demo_State_Change__e fan-out ────
    List<Demo_State_Change__e> events = new List<Demo_State_Change__e>();
    for (Demo_Session__c rec : Trigger.new) {
        Demo_Session__c old = Trigger.oldMap.get(rec.Id);
        if (rec.State__c != old.State__c) {
            events.add(new Demo_State_Change__e(
                New_State__c = rec.State__c,
                Demo_Session_Id__c = rec.Id,
                Target_Session_Id__c = null
            ));
        }
    }
    if (!events.isEmpty()) {
        EventBus.publish(events);
    }
}
