/**
 * Voice-agent seat context resolver.
 *
 * Given the caller's Contact (resolved from VoiceCall.Contact__c by the
 * inbound phone-number-search subflow), returns everything the voice agent
 * needs to make a concise, personalised seat-change offer WITHOUT reading
 * long lists aloud:
 *   - the caller's first name and their declared window/aisle preference
 *     (lifted from the survey summary on the Contact),
 *   - their bookings, each with its single segment's current seat,
 *
 * The seat map is cosmetic, so the agent invents sensible seat codes for the
 * offer; only the chosen seat is persisted, via Skywave_ChangeSeat.
 *
 * Read-only. Returns a compact JSON envelope the agent reasons over.
 */
public with sharing class Skywave_GetSeatContext {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true
            description='The caller Contact, from VoiceCall.Contact__c.')
        public String contactId;
    }

    public class Output {
        @InvocableVariable(label='success') public Boolean success;
        @InvocableVariable(label='message') public String message;
        @InvocableVariable(label='first name'
            description='Caller first name for a personal greeting.')
        public String firstName;
        @InvocableVariable(label='seat preference'
            description='Declared seat preference (Window / Aisle / null) parsed from the survey.')
        public String seatPreference;
        @InvocableVariable(label='booking count'
            description='Number of active bookings (0 / 1 / N).')
        public Integer bookingCount;
        @InvocableVariable(label='bookings JSON'
            description='Compact JSON list of bookings: code, flightNumber, route, travelDate, currentSeat, segmentId.')
        public String bookingsJson;
    }

    @InvocableMethod(
        label='Skywave: Get seat context (voice)'
        description='Returns the caller name, seat preference, and bookings (with current seat per segment) for the voice seat-change flow.'
        category='Skywave'
    )
    public static List<Output> getContext(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(one(req));
        return outs;
    }

    private static Output one(Input req) {
        Output o = new Output();
        o.success = false;
        o.bookingCount = 0;
        o.bookingsJson = '[]';

        if (String.isBlank(req.contactId)) {
            o.message = 'Caller contact id is required.';
            return o;
        }

        try {
            Contact c = [
                SELECT Id, FirstName, Skywave_Survey_Summary__c
                FROM Contact WHERE Id = :req.contactId LIMIT 1
            ];
            o.firstName = c.FirstName;
            o.seatPreference = parseSeatPreference(c.Skywave_Survey_Summary__c);

            List<Map<String, Object>> bookings = new List<Map<String, Object>>();
            for (Booking__c b : [
                SELECT Id, Confirmation_Code__c,
                       (SELECT Id, Seat_Number__c, Flight__r.Flight_Number__c,
                               Flight__r.Origin__c, Flight__r.Destination__c, Travel_Date__c
                        FROM Booking_Segments__r
                        ORDER BY Segment_Order__c, Departure_DateTime__c)
                FROM Booking__c
                WHERE Contact__c = :req.contactId
                  AND Status__c IN ('Confirmed', 'Pending Confirmation')
                ORDER BY CreatedDate DESC
            ]) {
                for (Booking_Segment__c seg : b.Booking_Segments__r) {
                    bookings.add(new Map<String, Object>{
                        'code' => b.Confirmation_Code__c,
                        'segmentId' => seg.Id,
                        'flightNumber' => seg.Flight__r != null ? seg.Flight__r.Flight_Number__c : null,
                        'route' => (seg.Flight__r != null)
                            ? seg.Flight__r.Origin__c + '-' + seg.Flight__r.Destination__c : null,
                        'travelDate' => seg.Travel_Date__c,
                        'currentSeat' => seg.Seat_Number__c
                    });
                }
            }
            o.bookingCount = bookings.size();
            o.bookingsJson = JSON.serialize(bookings);
            o.success = true;
            o.message = 'ok';
        } catch (Exception e) {
            o.message = 'Error loading seat context: ' + e.getMessage();
            System.debug('GetSeatContext error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        return o;
    }

    /** Lift "Window"/"Aisle" out of the survey summary's "Window or aisle? -> X" answer. */
    private static String parseSeatPreference(String summary) {
        if (String.isBlank(summary)) return null;
        String lower = summary.toLowerCase();
        // Scope to the seat question so an earlier answer can't be mistaken for it.
        Integer q = lower.indexOf('window or aisle?');
        String scope = q >= 0 ? lower.substring(q) : lower;
        Integer arrow = scope.indexOf('->');
        String answer = arrow >= 0
            ? scope.substring(arrow + 2, Math.min(scope.length(), arrow + 20))
            : scope;
        if (answer.contains('window')) return 'Window';
        if (answer.contains('aisle')) return 'Aisle';
        if (answer.contains('middle')) return 'Middle';
        return null;
    }
}
