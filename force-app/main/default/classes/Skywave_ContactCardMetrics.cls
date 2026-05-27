/**
 * Read-only @AuraEnabled facade for the Skywave-forked Modern Contact Card.
 *
 * Computes the two metrics that aren't available as formula fields on
 * Contact: total spend (sum of Confirmed booking totals) and next trip
 * (earliest future segment departure across Confirmed bookings).
 *
 * cacheable=true so navigating between Contacts mid-demo stays snappy.
 */
public with sharing class Skywave_ContactCardMetrics {

    public class Metrics {
        @AuraEnabled public String totalSpend; // formatted, e.g. "$3,420"
        @AuraEnabled public String nextTrip;   // formatted, e.g. "11 Sep 2026"
    }

    @AuraEnabled(cacheable=true)
    public static Metrics getMetrics(Id contactId) {
        Metrics m = new Metrics();
        m.totalSpend = '';
        m.nextTrip = '';
        if (contactId == null) return m;

        Decimal sum = 0;
        Set<Id> bookingIds = new Set<Id>();
        for (AggregateResult ar : [
            SELECT SUM(Total_Amount__c) total
            FROM Booking__c
            WHERE Contact__c = :contactId
              AND Status__c = 'Confirmed'
              AND Payment_Status__c = 'Paid'
        ]) {
            Object t = ar.get('total');
            if (t != null) sum = (Decimal) t;
        }
        if (sum > 0) {
            // Round-and-comma format. JS-side Number.toLocaleString
            // would be nicer but the string travels well-enough.
            m.totalSpend = '$' + formatThousands(sum);
        }

        for (Booking_Segment__c seg : [
            SELECT Departure_DateTime__c
            FROM Booking_Segment__c
            WHERE Booking__r.Contact__c = :contactId
              AND Booking__r.Status__c = 'Confirmed'
              AND Departure_DateTime__c > :System.now()
            ORDER BY Departure_DateTime__c ASC
            LIMIT 1
        ]) {
            m.nextTrip = seg.Departure_DateTime__c.format('d MMM yyyy');
        }

        return m;
    }

    private static String formatThousands(Decimal value) {
        // Round to whole dollars for the metric tile.
        Long whole = value.longValue();
        String s = String.valueOf(whole);
        // Add commas every 3 digits from the right.
        Integer len = s.length();
        if (len <= 3) return s;
        String out = '';
        Integer offset = Math.mod(len, 3);
        if (offset > 0) {
            out = s.substring(0, offset);
        }
        for (Integer i = offset; i < len; i += 3) {
            if (out.length() > 0) out += ',';
            out += s.substring(i, i + 3);
        }
        return out;
    }
}
