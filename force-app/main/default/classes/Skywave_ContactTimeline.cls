/**
 * Read-only @AuraEnabled feed for the skywaveEngagementTimeline LWC.
 *
 * Merges the Contact's interactions into a single chronological list:
 *   - Survey responses (parsed from Contact.Skywave_Survey_Json__c)
 *   - Booking events (created, paid, confirmed)
 *
 * Designed to read like a Data Cloud "Engagement events" feed even
 * though Skywave's Data Cloud streams aren't wired yet (Phase 4.5).
 * The data already exists in CRM; this class just shapes it.
 */
public with sharing class Skywave_ContactTimeline {

    public class Event {
        @AuraEnabled public String key;
        @AuraEnabled public DateTime occurredAt;
        @AuraEnabled public String occurredAtLabel; // "May 26 · 09:51"
        @AuraEnabled public String channel; // 'survey', 'booking'
        @AuraEnabled public String icon;    // emoji glyph
        @AuraEnabled public String title;
        @AuraEnabled public String detail;
        @AuraEnabled public String accent;  // 'navy'|'teal'|'amber' for chip styling
    }

    @AuraEnabled(cacheable=true)
    public static List<Event> getEvents(Id contactId) {
        List<Event> out = new List<Event>();
        if (contactId == null) return out;

        // Survey responses — parse the JSON map on Contact.
        try {
            Contact c = [
                SELECT Id, CreatedDate, Skywave_Survey_Json__c, Skywave_Survey_Summary__c
                FROM Contact WHERE Id = :contactId LIMIT 1
            ];
            if (String.isNotBlank(c.Skywave_Survey_Json__c)) {
                addSurveyEvents(out, c);
            }
        } catch (Exception e) {
            // ignore — timeline is still useful without the survey events
        }

        // Booking events — one per Booking + a "paid" event when payment landed.
        for (Booking__c b : [
            SELECT Id, CreatedDate, Confirmation_Code__c, Fare_Class__c,
                   Status__c, Payment_Status__c, Payment_Method__c,
                   Total_Amount__c, LastModifiedDate
            FROM Booking__c
            WHERE Contact__c = :contactId
            ORDER BY CreatedDate DESC
        ]) {
            Event created = new Event();
            created.key = b.Id + ':created';
            created.occurredAt = b.CreatedDate;
            created.occurredAtLabel = formatStamp(b.CreatedDate);
            created.channel = 'booking';
            created.icon = '🎫';
            created.title = 'Booking ' + b.Confirmation_Code__c + ' reserved';
            created.detail = b.Fare_Class__c + ' · ' + (b.Total_Amount__c == null
                ? '—'
                : '$' + b.Total_Amount__c.setScale(2).toPlainString());
            created.accent = 'navy';
            out.add(created);

            if (b.Payment_Status__c == 'Paid' && b.LastModifiedDate != b.CreatedDate) {
                Event paid = new Event();
                paid.key = b.Id + ':paid';
                paid.occurredAt = b.LastModifiedDate;
                paid.occurredAtLabel = formatStamp(b.LastModifiedDate);
                paid.channel = 'booking';
                paid.icon = '✓';
                paid.title = 'Payment confirmed for ' + b.Confirmation_Code__c;
                paid.detail = (b.Payment_Method__c == null ? 'Card' : b.Payment_Method__c) +
                    ' · ' + (b.Total_Amount__c == null ? '—' : '$' + b.Total_Amount__c.setScale(2).toPlainString());
                paid.accent = 'teal';
                out.add(paid);
            }
        }

        // Seat-change events — a Booking_Segment__c whose seat was changed after
        // booking shows LastModifiedDate later than CreatedDate. (Seats set at
        // booking time, if any, leave the two equal.) Surfaced as its own
        // engagement event so a live seat change appears on the timeline.
        addSeatChangeEvents(out, contactId);

        // Sort newest-first.
        out.sort(new EventComparator());
        return out;
    }

    private static void addSeatChangeEvents(List<Event> out, Id contactId) {
        try {
            for (Booking_Segment__c seg : [
                SELECT Id, Seat_Number__c, CreatedDate, LastModifiedDate,
                       Booking__r.Confirmation_Code__c, Flight__r.Flight_Number__c
                FROM Booking_Segment__c
                WHERE Booking__r.Contact__c = :contactId
                  AND Seat_Number__c != null
            ]) {
                // SOQL can't compare two fields, so filter in Apex: a seat set
                // at booking time leaves the two stamps equal; a later change
                // bumps LastModifiedDate.
                if (seg.LastModifiedDate == seg.CreatedDate) continue;

                Event e = new Event();
                e.key = seg.Id + ':seat';
                e.occurredAt = seg.LastModifiedDate;
                e.occurredAtLabel = formatStamp(seg.LastModifiedDate);
                e.channel = 'booking';
                e.icon = '💺';
                String flightNo = seg.Flight__r == null ? '' : seg.Flight__r.Flight_Number__c;
                String code = seg.Booking__r == null ? '' : seg.Booking__r.Confirmation_Code__c;
                e.title = 'Seat changed to ' + seg.Seat_Number__c;
                e.detail = 'Flight ' + flightNo + (String.isBlank(code) ? '' : ' · ' + code);
                e.accent = 'teal';
                out.add(e);
            }
        } catch (Exception ex) {
            // FLS or query issue — timeline is still useful without seat events.
        }
    }

    private static void addSurveyEvents(List<Event> out, Contact c) {
        try {
            Object parsed = JSON.deserializeUntyped(c.Skywave_Survey_Json__c);
            if (!(parsed instanceof Map<String, Object>)) return;
            Map<String, Object> responses = (Map<String, Object>) parsed;

            for (String questionKey : responses.keySet()) {
                Object value = responses.get(questionKey);
                if (!(value instanceof Map<String, Object>)) continue;
                Map<String, Object> entry = (Map<String, Object>) value;

                Event e = new Event();
                e.key = 'survey:' + questionKey;
                e.occurredAt = c.CreatedDate; // best approximation — we don't store per-answer timestamps
                e.occurredAtLabel = formatStamp(c.CreatedDate);
                e.channel = 'survey';
                e.icon = '✦';
                String questionText = (String) entry.get('questionText');
                String answerText = (String) entry.get('answerText');
                e.title = questionText == null ? 'Survey response' : questionText;
                e.detail = answerText == null ? '' : answerText;
                e.accent = 'amber';
                out.add(e);
            }
        } catch (Exception ex) {
            // bad JSON — skip survey events entirely
        }
    }

    private static String formatStamp(DateTime dt) {
        return dt == null ? '' : dt.format('MMM d · HH:mm');
    }

    private class EventComparator implements Comparator<Event> {
        public Integer compare(Event a, Event b) {
            if (a.occurredAt == null && b.occurredAt == null) return 0;
            if (a.occurredAt == null) return 1;
            if (b.occurredAt == null) return -1;
            return b.occurredAt.getTime() > a.occurredAt.getTime() ? 1 : -1;
        }
    }
}
