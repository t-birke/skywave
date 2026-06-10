/**
 * Read-only @AuraEnabled facade for the skywaveItineraryCard LWC.
 *
 * Returns every Confirmed Booking__c for a Contact, with each booking's
 * segment chain hydrated. The LWC renders one collapsible card per
 * booking (most recent expanded by default) modelled on the Lufthansa
 * itinerary mockup the user picked: header with route/date/duration +
 * fare-class badge, expandable section with segment list + a "Your
 * fare" sidecar (rebooking conditions, refundability, baggage).
 *
 * Why not lightning__recordPage with relatedListSingle: we want the
 * itinerary card visually styled (Skywave navy/teal palette, big route
 * timestamps, fare-class badge) — Lightning's stock related-list pane
 * doesn't get there.
 *
 * cacheable=true so @wire keeps the page snappy when the presenter
 * navigates between Contacts mid-demo.
 */
public with sharing class Skywave_ContactItinerary {

    public class BookingDTO {
        @AuraEnabled public String bookingId;
        @AuraEnabled public String confirmationCode;
        @AuraEnabled public String fareClass;
        @AuraEnabled public String status;
        @AuraEnabled public String paymentStatus;
        @AuraEnabled public String paymentMethod;
        @AuraEnabled public String totalAmount; // formatted
        @AuraEnabled public Integer checkedBags;
        @AuraEnabled public DateTime bookingDate;

        // Itinerary header (computed from segments[0..N])
        @AuraEnabled public String routeLabel; // "Berlin to San Francisco"
        @AuraEnabled public String travelDateLabel; // "Friday, 11 September 2026"
        @AuraEnabled public String departureTime; // "12:50"
        @AuraEnabled public String arrivalTime; // "19:00"
        @AuraEnabled public String originCode; // BER
        @AuraEnabled public String destinationCode; // SFO
        @AuraEnabled public String totalDurationLabel; // "15h 10m"
        @AuraEnabled public String stopsLabel; // "2h 20m MUC" or "Non-stop"

        @AuraEnabled public List<SegmentDTO> segments = new List<SegmentDTO>();

        // Fare card chips (computed from fareClass)
        @AuraEnabled public String rebookingConditions;
        @AuraEnabled public String refundability;
        @AuraEnabled public String checkedBaggageAllowance;
        @AuraEnabled public String onboardCatering;

        // True iff every segment has already arrived. The LWC splits
        // its rendering on this flag — Upcoming on top (cancel button
        // shown), Past below (history only, no cancel).
        @AuraEnabled public Boolean isPast = false;
    }

    public class SegmentDTO {
        @AuraEnabled public String segmentId;
        @AuraEnabled public Integer segmentOrder;
        @AuraEnabled public String segmentDurationLabel;
        @AuraEnabled public String departureTime;
        @AuraEnabled public String arrivalTime;
        @AuraEnabled public String departureCity;
        @AuraEnabled public String departureCode;
        @AuraEnabled public String arrivalCity;
        @AuraEnabled public String arrivalCode;
        @AuraEnabled public String flightNumber;
        @AuraEnabled public String aircraftType;
        @AuraEnabled public String seatNumber;
        @AuraEnabled public String layoverLabel; // " 2h 20m" — populated on segments AFTER segment 0
    }

    // cacheable=true is required by @wire. After cancelBooking() the LWC
    // calls refreshApex() on the wired result, which invalidates the
    // cache and re-fetches — that's the standard read+mutate pattern.
    @AuraEnabled(cacheable=true)
    public static List<BookingDTO> getBookings(Id contactId) {
        if (contactId == null) return new List<BookingDTO>();

        // Query bookings + segments in two passes (segment-by-booking
        // grouping in Apex is simpler than wrestling with the relationship
        // sub-select naming).
        List<Booking__c> bookings = [
            SELECT Id, Confirmation_Code__c, Fare_Class__c, Status__c,
                   Payment_Status__c, Payment_Method__c, Total_Amount__c,
                   Checked_Bags__c, Booking_Date__c
            FROM Booking__c
            WHERE Contact__c = :contactId
              AND Status__c = 'Confirmed'
            ORDER BY CreatedDate DESC
        ];
        if (bookings.isEmpty()) return new List<BookingDTO>();

        Set<Id> bookingIds = (new Map<Id, Booking__c>(bookings)).keySet();

        Map<Id, List<Booking_Segment__c>> segsByBooking = new Map<Id, List<Booking_Segment__c>>();
        for (Booking_Segment__c seg : [
            SELECT Id, Booking__c, Segment_Order__c, Travel_Date__c,
                   Departure_DateTime__c, Arrival_DateTime__c, Seat_Number__c,
                   Flight__r.Flight_Number__c, Flight__r.Origin__c,
                   Flight__r.Destination__c, Flight__r.Aircraft_Type__c,
                   Flight__r.Duration_Minutes__c
            FROM Booking_Segment__c
            WHERE Booking__c IN :bookingIds
            ORDER BY Booking__c, Segment_Order__c ASC NULLS LAST
        ]) {
            if (!segsByBooking.containsKey(seg.Booking__c)) {
                segsByBooking.put(seg.Booking__c, new List<Booking_Segment__c>());
            }
            segsByBooking.get(seg.Booking__c).add(seg);
        }

        List<BookingDTO> out = new List<BookingDTO>();
        for (Booking__c b : bookings) {
            List<Booking_Segment__c> segs = segsByBooking.get(b.Id);
            if (segs == null) segs = new List<Booking_Segment__c>();
            out.add(buildBookingDTO(b, segs));
        }
        return out;
    }

    private static BookingDTO buildBookingDTO(Booking__c b, List<Booking_Segment__c> segs) {
        BookingDTO d = new BookingDTO();
        d.bookingId = b.Id;
        d.confirmationCode = b.Confirmation_Code__c;
        d.fareClass = b.Fare_Class__c;
        d.status = b.Status__c;
        d.paymentStatus = b.Payment_Status__c;
        d.paymentMethod = b.Payment_Method__c;
        d.totalAmount = b.Total_Amount__c == null
            ? '$0.00'
            : '$' + b.Total_Amount__c.setScale(2).toPlainString();
        d.checkedBags = b.Checked_Bags__c == null ? 0 : Integer.valueOf(b.Checked_Bags__c);
        d.bookingDate = b.Booking_Date__c;
        d.isPast = Skywave_BookingDateGate.isBookingPast(segs);

        // Fare-class chips. Mirrors Skywave_BookFlight#buildBookingResponse
        // for consistency with what the chat card showed during booking.
        applyFareChips(d);

        // Segment hydration.
        List<SegmentDTO> segDTOs = new List<SegmentDTO>();
        DateTime previousArrival = null;
        for (Booking_Segment__c seg : segs) {
            SegmentDTO s = new SegmentDTO();
            s.segmentId = seg.Id;
            s.segmentOrder = seg.Segment_Order__c == null ? null : Integer.valueOf(seg.Segment_Order__c);
            s.departureTime = formatHm(seg.Departure_DateTime__c);
            s.arrivalTime = formatHm(seg.Arrival_DateTime__c);
            s.seatNumber = seg.Seat_Number__c;

            if (seg.Flight__r != null) {
                s.flightNumber = seg.Flight__r.Flight_Number__c;
                s.aircraftType = seg.Flight__r.Aircraft_Type__c;
                s.departureCode = seg.Flight__r.Origin__c;
                s.arrivalCode = seg.Flight__r.Destination__c;
                s.departureCity = airportCity(seg.Flight__r.Origin__c);
                s.arrivalCity = airportCity(seg.Flight__r.Destination__c);
                s.segmentDurationLabel = formatDuration(seg.Flight__r.Duration_Minutes__c);
            }

            if (previousArrival != null && seg.Departure_DateTime__c != null) {
                Long deltaMin = (seg.Departure_DateTime__c.getTime() - previousArrival.getTime()) / 1000 / 60;
                if (deltaMin > 0) {
                    s.layoverLabel = formatDuration(deltaMin);
                }
            }
            previousArrival = seg.Arrival_DateTime__c;

            segDTOs.add(s);
        }
        d.segments = segDTOs;

        // Header summary from first + last segment.
        if (!segDTOs.isEmpty()) {
            SegmentDTO first = segDTOs[0];
            SegmentDTO last = segDTOs[segDTOs.size() - 1];

            d.departureTime = first.departureTime;
            d.arrivalTime = last.arrivalTime;
            d.originCode = first.departureCode;
            d.destinationCode = last.arrivalCode;
            d.routeLabel = (first.departureCity == null ? first.departureCode : first.departureCity) +
                ' to ' + (last.arrivalCity == null ? last.arrivalCode : last.arrivalCity);

            if (segs[0].Departure_DateTime__c != null) {
                d.travelDateLabel = segs[0].Departure_DateTime__c.format('EEEE, d MMMM yyyy');
            }

            // Total duration = first dep -> last arr (covers layovers)
            DateTime firstDep = segs[0].Departure_DateTime__c;
            DateTime lastArr = segs[segs.size() - 1].Arrival_DateTime__c;
            if (firstDep != null && lastArr != null) {
                Long totalMin = (lastArr.getTime() - firstDep.getTime()) / 1000 / 60;
                d.totalDurationLabel = formatDuration(totalMin);
            }

            if (segDTOs.size() == 1) {
                d.stopsLabel = 'Non-stop';
            } else {
                // "1 stop in MUC 2h 20m"
                SegmentDTO stop = segDTOs[1];
                String layover = stop.layoverLabel == null ? '' : ' ' + stop.layoverLabel;
                Integer numStops = segDTOs.size() - 1;
                d.stopsLabel = numStops + ' stop' + (numStops == 1 ? '' : 's') +
                    (stop.departureCode == null ? '' : ' in ' + stop.departureCode) + layover;
            }
        }

        return d;
    }

    private static void applyFareChips(BookingDTO d) {
        String fc = d.fareClass == null ? 'Economy' : d.fareClass;
        if (fc == 'Economy') {
            d.rebookingConditions = 'Change fee $99, plus fare difference';
            d.refundability = 'Cancellation fee $99';
            d.checkedBaggageAllowance = '1 bag (50lbs)';
            d.onboardCatering = 'Refreshment';
        } else if (fc == 'Premium Economy') {
            d.rebookingConditions = 'No change fee, plus fare difference';
            d.refundability = 'Cancellation fee $99';
            d.checkedBaggageAllowance = '2 bags (50lbs each)';
            d.onboardCatering = 'Refreshment, Meal';
        } else if (fc == 'Business') {
            d.rebookingConditions = 'No change fee, plus fare difference';
            d.refundability = 'Fully refundable';
            d.checkedBaggageAllowance = '2 bags (70lbs each)';
            d.onboardCatering = 'Refreshment, Meal';
        } else { // First
            d.rebookingConditions = 'No change fee, plus fare difference';
            d.refundability = 'Fully refundable';
            d.checkedBaggageAllowance = '3 bags (70lbs each)';
            d.onboardCatering = 'Refreshment, Meal, Premium dining';
        }
    }

    private static String formatHm(DateTime dt) {
        return dt == null ? '' : dt.format('HH:mm');
    }

    private static String formatDuration(Object minutesObj) {
        if (minutesObj == null) return '';
        Long m;
        if (minutesObj instanceof Decimal) {
            m = ((Decimal) minutesObj).longValue();
        } else if (minutesObj instanceof Integer) {
            m = (Long) (Integer) minutesObj;
        } else if (minutesObj instanceof Long) {
            m = (Long) minutesObj;
        } else {
            return '';
        }
        Long h = m / 60;
        Long min = Math.mod(m, 60);
        return h + 'h ' + min + 'm';
    }

    private static String airportCity(String code) {
        if (code == null) return null;
        Map<String, String> cities = new Map<String, String>{
            'ATL' => 'Atlanta', 'DFW' => 'Dallas', 'DEN' => 'Denver',
            'ORD' => 'Chicago', 'LAX' => 'Los Angeles', 'JFK' => 'New York',
            'LAS' => 'Las Vegas', 'MCO' => 'Orlando', 'MIA' => 'Miami',
            'SEA' => 'Seattle', 'PHX' => 'Phoenix', 'IAH' => 'Houston',
            'BOS' => 'Boston', 'SFO' => 'San Francisco', 'EWR' => 'Newark',
            'LHR' => 'London', 'HND' => 'Tokyo', 'SYD' => 'Sydney',
            'BER' => 'Berlin', 'MUC' => 'Munich'
        };
        return cities.containsKey(code) ? cities.get(code) : code;
    }

    /**
     * Soft-cancel a booking from the Contact-page LWC. Wraps
     * Skywave_BookingEngine.cancelBooking so the chat path, the website
     * path, and the LWC all share the same engine — including the
     * booking_cancelled monitor event publish.
     *
     * Caller passes the Contact Id (LWC's @api recordId) and the booking's
     * confirmation code. Engine re-checks ownership (confirmation code
     * must belong to the contactId) before mutating, so a tampered
     * recordId can't cancel someone else's row.
     *
     * Result is a thin LWC-friendly map. Throws AuraHandledException on
     * unexpected engine failure so the LWC's catch block can surface
     * .getMessage() to the user.
     */
    @AuraEnabled
    public static Map<String, Object> cancelBooking(Id contactId, String confirmationCode) {
        if (contactId == null) {
            throw new AuraHandledException('Contact Id is required.');
        }
        if (String.isBlank(confirmationCode)) {
            throw new AuraHandledException('Confirmation code is required.');
        }
        Skywave_BookingEngine.CancelResult r =
            Skywave_BookingEngine.cancelBooking(contactId, confirmationCode);
        if (!r.success) {
            // Bubble the engine's error code as a user-readable message.
            // The LWC catches AuraHandledException and shows it inline.
            String msg;
            if (r.errorCode == 'booking_not_found') msg = 'Booking not found for this contact.';
            else if (r.errorCode == 'cancel_failed') msg = 'Cancel failed: ' + r.errorMessage;
            else msg = r.errorCode == null ? 'Cancel failed.' : r.errorCode;
            throw new AuraHandledException(msg);
        }
        return new Map<String, Object>{
            'success'          => true,
            'bookingId'        => r.bookingId,
            'bookingCode'      => r.bookingCode,
            'alreadyCancelled' => r.alreadyCancelled,
            'refundDisplay'    => r.refundDisplay
        };
    }
}
