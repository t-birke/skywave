trigger Demo_Session_Trigger on Demo_Session__c (after update) {
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
