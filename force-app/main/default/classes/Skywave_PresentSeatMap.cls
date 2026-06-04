/**
 * Invocable that returns a renderable Skywave_SeatMapData payload.
 *
 * The goldilocks seat_selection subagent calls this ONCE, after it has
 * narrowed the visitor to a single booking segment (the 4-case funnel in
 * the .agent file). Pre-fills with the segment's booking code, flight
 * number, current seat, and a COSMETIC seat grid: most seats open, a few
 * deterministically "taken" (seeded off the segment Id so the same segment
 * always shows the same layout). Only the visitor's own seat change is
 * persisted later — via Skywave_ChangeSeat.confirmSeatChange, called
 * imperatively from the renderer LWC.
 *
 * No DML — pure read + serialize. Mirrors Skywave_PresentPaymentForm.
 */
public with sharing class Skywave_PresentSeatMap {

    // Cabin layout for the cosmetic grid: rows 10-25, seats A-F (3-3).
    private static final Integer FIRST_ROW = 10;
    private static final Integer LAST_ROW = 25;
    private static final List<String> SEAT_LETTERS = new List<String>{ 'A', 'B', 'C', 'D', 'E', 'F' };

    public class Input {
        @InvocableVariable(label='Booking Code' required=true
            description='Confirmation code of the booking the visitor wants to change a seat on (from active_bookings).')
        public String bookingCode;

        @InvocableVariable(label='Flight Number' required=false
            description='Flight number of the specific segment, when the booking has more than one flight. Leave blank if the booking has a single flight.')
        public String flightNumber;
    }

    public class Output {
        @InvocableVariable(label='Seat Map Data')
        public Skywave_SeatMapData seatMapData;

        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;
    }

    @InvocableMethod(
        label='Skywave: Present seat map'
        description='Returns the SkywaveSeatMap renderable DTO so the goldilocks agent can show the seatmap card for a single resolved booking segment.'
        category='Skywave'
    )
    public static List<Output> present(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(presentOne(req));
        return outs;
    }

    private static Output presentOne(Input req) {
        Output out = new Output();
        out.success = false;

        if (String.isBlank(req.bookingCode)) {
            out.message = 'Booking code is required.';
            out.seatMapData = new Skywave_SeatMapData('{}');
            return out;
        }

        // Resolve the segment Apex-side from the booking code (+ optional
        // flight number) so Salesforce Ids never enter the planner's context.
        // The output still carries bookingSegmentId for the LWC to pass to
        // Skywave_ChangeSeat.confirmSeatChange.
        List<Booking_Segment__c> segs = [
            SELECT Id, Seat_Number__c,
                   Booking__r.Confirmation_Code__c,
                   Flight__r.Flight_Number__c, Flight__r.Aircraft_Type__c,
                   Flight__r.Origin__c, Flight__r.Destination__c
            FROM Booking_Segment__c
            WHERE Booking__r.Confirmation_Code__c = :req.bookingCode
            ORDER BY Segment_Order__c, Departure_DateTime__c
        ];
        if (segs.isEmpty()) {
            out.message = 'No booking found for code ' + req.bookingCode + '.';
            out.seatMapData = new Skywave_SeatMapData('{}');
            return out;
        }

        // Narrow to the requested flight when the booking has several segments.
        Booking_Segment__c seg = segs[0];
        if (String.isNotBlank(req.flightNumber)) {
            for (Booking_Segment__c s : segs) {
                if (s.Flight__r != null && req.flightNumber.equalsIgnoreCase(s.Flight__r.Flight_Number__c)) {
                    seg = s;
                    break;
                }
            }
        }
        String currentSeat = seg.Seat_Number__c;

        Map<String, Object> state = new Map<String, Object>{
            'bookingSegmentId' => seg.Id,
            'bookingCode' => seg.Booking__r.Confirmation_Code__c,
            'flightNumber' => seg.Flight__r.Flight_Number__c,
            'aircraftType' => seg.Flight__r.Aircraft_Type__c,
            'origin' => seg.Flight__r.Origin__c,
            'destination' => seg.Flight__r.Destination__c,
            'currentSeat' => currentSeat,
            'rows' => buildRows(seg.Id, currentSeat)
        };

        out.seatMapData = new Skywave_SeatMapData(JSON.serialize(state));
        out.success = true;
        out.message = 'Seat map ready';
        return out;
    }

    /**
     * Cosmetic seat grid. Occupancy is deterministic from the segment Id so
     * the same booking always renders the same map (stable across re-opens).
     * The visitor's current seat is always shown as "current" (selectable to
     * keep, or pick another). No real cross-booking inventory is consulted —
     * this is demo decoration; only the visitor's own change is persisted.
     */
    private static List<Map<String, Object>> buildRows(Id segmentId, String currentSeat) {
        Integer seed = Math.abs(String.valueOf(segmentId).hashCode());
        List<Map<String, Object>> rows = new List<Map<String, Object>>();

        for (Integer row = FIRST_ROW; row <= LAST_ROW; row++) {
            List<Map<String, Object>> seats = new List<Map<String, Object>>();
            for (Integer i = 0; i < SEAT_LETTERS.size(); i++) {
                String code = row + SEAT_LETTERS[i];
                Boolean isCurrent = (currentSeat != null && code == currentSeat.toUpperCase());
                // Deterministic pseudo-occupancy: ~1 in 4 seats taken, but
                // never the visitor's current seat.
                Boolean taken = !isCurrent && Math.mod(seed + (row * 7) + (i * 13), 4) == 0;
                seats.add(new Map<String, Object>{
                    'code' => code,
                    'status' => isCurrent ? 'current' : (taken ? 'taken' : 'available')
                });
            }
            rows.add(new Map<String, Object>{
                'row' => row,
                'seats' => seats
            });
        }
        return rows;
    }
}
