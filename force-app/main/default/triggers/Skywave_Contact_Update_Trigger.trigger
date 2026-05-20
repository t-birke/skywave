/**
 * Receives Skywave_Contact_Update__e events published by Skywave_ContactUpsert
 * (the public Sites endpoint). Runs in System Mode (Apex platform default for
 * Platform Event triggers) so it can do Contact upserts and Demo_Event__e
 * publishes that the Sites Guest user can't do directly.
 *
 * For each event:
 *   1. Upsert Contact by Session_Id__c = Device_Id__c
 *   2. Apply per-event-type fields (survey_complete: survey JSON+summary;
 *      chat_start: conversationId)
 *   3. Link Contact to the per-Demo_Session Account
 *   4. On survey_complete, publish a Demo_Event__e(type=survey_complete) so
 *      the monitor LWC can render a green dot on the visitor's bubble
 *
 * Bulk-safe: groups events by deviceId so duplicate-in-batch events fold
 * together. New Contacts are inserted as a single DML, then any further
 * field updates on the just-inserted row are batched as well.
 */
trigger Skywave_Contact_Update_Trigger on Skywave_Contact_Update__e (after insert) {
    if (Trigger.new.isEmpty()) return;

    // Resolve Account links per Demo_Session_Id__c. We hand-pick the latest
    // Account to keep this idempotent if multiple were ever created in a
    // race (shouldn't happen — Demo_Session_Trigger creates exactly one).
    Set<Id> demoSessionIds = new Set<Id>();
    for (Skywave_Contact_Update__e ev : Trigger.new) {
        if (String.isNotBlank(ev.Demo_Session_Id__c)) {
            try { demoSessionIds.add((Id) ev.Demo_Session_Id__c); } catch (Exception e) {}
        }
    }
    Map<Id, Id> accountIdByDemoSession = new Map<Id, Id>();
    if (!demoSessionIds.isEmpty()) {
        for (Account a : [
            SELECT Id, Skywave_Demo_Session__c
            FROM Account
            WHERE Skywave_Demo_Session__c IN :demoSessionIds
            ORDER BY CreatedDate DESC
        ]) {
            if (!accountIdByDemoSession.containsKey(a.Skywave_Demo_Session__c)) {
                accountIdByDemoSession.put(a.Skywave_Demo_Session__c, a.Id);
            }
        }
    }

    // Group events by deviceId so duplicates fold (last write wins per type).
    Map<String, List<Skywave_Contact_Update__e>> eventsByDeviceId = new Map<String, List<Skywave_Contact_Update__e>>();
    for (Skywave_Contact_Update__e ev : Trigger.new) {
        if (String.isBlank(ev.Device_Id__c)) continue;
        if (!eventsByDeviceId.containsKey(ev.Device_Id__c)) {
            eventsByDeviceId.put(ev.Device_Id__c, new List<Skywave_Contact_Update__e>());
        }
        eventsByDeviceId.get(ev.Device_Id__c).add(ev);
    }
    if (eventsByDeviceId.isEmpty()) return;

    // Find existing Contacts for these deviceIds.
    Map<String, Contact> existingByDeviceId = new Map<String, Contact>();
    for (Contact c : [
        SELECT Id, Session_Id__c, Skywave_Conversation_Id__c,
               Skywave_Survey_Json__c, Skywave_Survey_Summary__c,
               AccountId, Demo_Session__c
        FROM Contact
        WHERE Session_Id__c IN :eventsByDeviceId.keySet()
    ]) {
        existingByDeviceId.put(c.Session_Id__c, c);
    }

    // Apply each device's events to its (possibly new) Contact.
    List<Contact> toUpsert = new List<Contact>();
    List<Demo_Event__e> demoEventsToPublish = new List<Demo_Event__e>();
    for (String deviceId : eventsByDeviceId.keySet()) {
        Contact c = existingByDeviceId.get(deviceId);
        if (c == null) {
            c = new Contact(
                LastName     = deviceId,
                Session_Id__c = deviceId
            );
        }
        for (Skywave_Contact_Update__e ev : eventsByDeviceId.get(deviceId)) {
            if (String.isNotBlank(ev.Demo_Session_Id__c)) {
                Id dsId;
                try { dsId = (Id) ev.Demo_Session_Id__c; } catch (Exception e) {}
                if (dsId != null) {
                    if (c.Demo_Session__c == null) c.Demo_Session__c = dsId;
                    if (c.AccountId == null) {
                        Id acctId = accountIdByDemoSession.get(dsId);
                        if (acctId != null) c.AccountId = acctId;
                    }
                }
            }
            if (ev.Update_Type__c == 'survey_complete') {
                if (String.isNotBlank(ev.Survey_Json__c))    c.Skywave_Survey_Json__c    = ev.Survey_Json__c;
                if (String.isNotBlank(ev.Survey_Summary__c)) c.Skywave_Survey_Summary__c = ev.Survey_Summary__c;
                demoEventsToPublish.add(new Demo_Event__e(
                    Type__c           = 'survey_complete',
                    Session_Id__c     = deviceId,
                    Demo_Session_Id__c = ev.Demo_Session_Id__c,
                    Payload_Json__c   = ''
                ));
            } else if (ev.Update_Type__c == 'chat_start') {
                if (String.isNotBlank(ev.Conversation_Id__c)) {
                    c.Skywave_Conversation_Id__c = ev.Conversation_Id__c;
                }
            }
        }
        toUpsert.add(c);
    }

    if (!toUpsert.isEmpty()) {
        // External-id upsert keyed on Session_Id__c — handles brand-new
        // and existing Contacts in a single DML.
        upsert toUpsert Session_Id__c;
    }
    if (!demoEventsToPublish.isEmpty()) {
        EventBus.publish(demoEventsToPublish);
    }
}
