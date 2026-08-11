/**
 * Router action for the Skywave Rental Car Agent.
 *
 * The rental agent runs in the SAME messaging session as the airlines
 * agent, so it resolves the visitor's identity independently using the
 * exact same logic (delegates to Skywave_ResolveSession so the deviceId /
 * conversationId / demo-seed resolution never drifts between the two
 * agents). It then finds the visitor's most relevant UPCOMING flight
 * booking to:
 *
 *   1. GATE the rental offer — the car option only appears once the
 *      visitor has a booked flight (hasFlightBooking).
 *   2. DEFAULT the pickup location (the flight's destination) and pickup
 *      date (the arrival date) so the offer card is pre-filled.
 *   3. LINK the Vehicle_Booking__c back to that flight Booking__c via its
 *      confirmation code.
 *
 * When the orchestrator (airlines) agent hands off, it can pass the same
 * three facts via a variable assignment; this action is the fallback /
 * self-resolve path so the rental agent also works standalone.
 */
public with sharing class Skywave_ResolveRentalContext {

    public class Input {
        @InvocableVariable(label='Messaging Platform Key (verified session)' required=false)
        public String sessionKey;

        @InvocableVariable(label='Conversation Id' required=false)
        public String conversationId;

        @InvocableVariable(label='Testing Session (studio fallback)' required=false)
        public String testingSession;
    }

    public class Output {
        @InvocableVariable(label='Resolved Contact Id')
        public String contactId;

        @InvocableVariable(label='Has a flight booking')
        public Boolean hasFlightBooking;

        @InvocableVariable(label='Flight booking confirmation code')
        public String flightBookingCode;

        @InvocableVariable(label='Destination IATA')
        public String destinationCode;

        @InvocableVariable(label='Destination city')
        public String destinationCity;

        @InvocableVariable(label='Pickup date (YYYY-MM-DD)')
        public String pickupDate;

        @InvocableVariable(label='Natural-language trip summary for agent reasoning')
        public String summary;

        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='error message')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Skywave: Resolve rental context'
        description='Resolves the visitor Contact (same logic as the airlines agent) and their upcoming flight destination + arrival date, so the rental agent can gate the car offer on a booked flight and pre-fill the pickup location/date.'
        category='Skywave'
    )
    public static List<Output> resolve(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(resolveOne(req));
        return outs;
    }

    private static Output resolveOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.hasFlightBooking = false;
        out.flightBookingCode = '';
        out.destinationCode = '';
        out.destinationCity = '';
        out.pickupDate = '';
        out.summary = '';

        try {
            // 1) Resolve identity via the shared airlines resolver — one
            //    implementation of the deviceId/conversationId/seed logic.
            Skywave_ResolveSession.Input rsIn = new Skywave_ResolveSession.Input();
            rsIn.sessionKey = req.sessionKey;
            rsIn.conversationId = req.conversationId;
            rsIn.testingSession = req.testingSession;
            List<Skywave_ResolveSession.Output> rsOuts =
                Skywave_ResolveSession.resolve(new List<Skywave_ResolveSession.Input>{ rsIn });
            Skywave_ResolveSession.Output rs = rsOuts.isEmpty() ? null : rsOuts[0];

            if (rs == null || String.isBlank(rs.contactId)) {
                out.success = true; // resolved cleanly, just no contact/booking
                out.summary = 'No Skywave profile resolved for this visitor yet.';
                return out;
            }
            out.contactId = rs.contactId;

            // 2) Find the visitor's most relevant upcoming flight booking:
            //    latest-created Confirmed/Pending booking whose final segment
            //    hasn't departed yet. That segment's destination + arrival
            //    become the rental pickup location + date.
            List<Booking__c> bookings = [
                SELECT Id, Confirmation_Code__c, CreatedDate
                FROM Booking__c
                WHERE Contact__c = :rs.contactId
                  AND Status__c IN ('Confirmed', 'Pending Confirmation')
                ORDER BY CreatedDate DESC
            ];
            if (bookings.isEmpty()) {
                out.success = true;
                out.summary = 'The visitor has no flight booking yet, so a rental car cannot be offered.';
                return out;
            }

            Set<Id> bookingIds = (new Map<Id, Booking__c>(bookings)).keySet();
            // Last (final-destination) segment per booking, by order.
            Map<Id, Booking_Segment__c> lastSegByBooking = new Map<Id, Booking_Segment__c>();
            for (Booking_Segment__c seg : [
                SELECT Id, Booking__c, Segment_Order__c, Arrival_DateTime__c,
                       Flight__r.Destination__c
                FROM Booking_Segment__c
                WHERE Booking__c IN :bookingIds
                ORDER BY Segment_Order__c ASC NULLS LAST, Departure_DateTime__c ASC NULLS LAST
            ]) {
                // Overwrite so the highest Segment_Order__c (final leg) wins.
                lastSegByBooking.put(seg.Booking__c, seg);
            }

            // Pick the first booking (newest) that still has a future arrival.
            DateTime nowDt = System.now();
            for (Booking__c bk : bookings) {
                Booking_Segment__c lastSeg = lastSegByBooking.get(bk.Id);
                if (lastSeg == null) continue;
                if (lastSeg.Arrival_DateTime__c != null && lastSeg.Arrival_DateTime__c < nowDt) {
                    continue; // already flown
                }
                out.hasFlightBooking = true;
                out.flightBookingCode = bk.Confirmation_Code__c;
                out.destinationCode = lastSeg.Flight__r != null ? lastSeg.Flight__r.Destination__c : '';
                out.destinationCity = cityFor(out.destinationCode);
                if (lastSeg.Arrival_DateTime__c != null) {
                    out.pickupDate = String.valueOf(lastSeg.Arrival_DateTime__c.date());
                }
                break;
            }

            if (out.hasFlightBooking) {
                out.summary = 'The visitor is flying to ' + out.destinationCity
                    + ' (' + out.destinationCode + ')'
                    + (String.isNotBlank(out.pickupDate) ? ', arriving ' + out.pickupDate : '')
                    + ' on booking ' + out.flightBookingCode
                    + '. Offer a rental car at the destination with pick-up on the arrival date.';
            } else {
                out.summary = 'The visitor only has past flights, so a rental car cannot be offered.';
            }
            out.success = true;
        } catch (Exception e) {
            out.errorMessage = 'Resolve rental context failed: ' + e.getMessage();
            System.debug('Skywave_ResolveRentalContext error: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
        return out;
    }

    // Reuse the canonical airport catalogue for the code → city label.
    private static String cityFor(String code) {
        if (String.isBlank(code)) return '';
        for (Skywave_Airports.Airport a : Skywave_Airports.ALL) {
            if (a.code == code) return a.city;
        }
        return code;
    }
}
