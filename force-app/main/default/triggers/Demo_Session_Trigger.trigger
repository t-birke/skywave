trigger Demo_Session_Trigger on Demo_Session__c (after insert, after update) {
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
