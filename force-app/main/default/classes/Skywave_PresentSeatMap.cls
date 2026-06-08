/**
 * Invocable that returns a renderable Skywave_SeatMapData payload.
 *
 * The chat seat_selection subagent calls this ONCE, after it has
 * narrowed the visitor to a single booking segment. Returns a seat
 * grid limited to the rows of the visitor's BOOKED FARE CLASS (the
 * full cabin would be too tall for the chat iframe).
 *
 * Backed by Skywave_Seat_Map__c (Layout_Json__c → class bands +
 * abreast string), the same source the website's seatmap uses, so
 * the rows + letters always match the real aircraft. Falls back to
 * a generic 10-25 / A-F grid only if the aircraft has no seatmap
 * record — primarily a safety net.
 *
 * No DML — pure read + serialize. Mirrors Skywave_PresentPaymentForm.
 */
public with sharing class Skywave_PresentSeatMap {

    // Fallback grid when the aircraft has no Skywave_Seat_Map__c record.
    private static final Integer FALLBACK_FIRST_ROW = 10;
    private static final Integer FALLBACK_LAST_ROW  = 25;
    private static final List<String> FALLBACK_LETTERS = new List<String>{ 'A','B','C','D','E','F' };

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
        description='Returns the SkywaveSeatMap renderable DTO so the chat agent can show the seatmap card for a single resolved booking segment, scoped to the booked fare class.'
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

        // Pull all segments + booking + aircraft refs for this booking code.
        List<Booking_Segment__c> segs = [
            SELECT Id, Seat_Number__c, Segment_Order__c,
                   Booking__r.Confirmation_Code__c, Booking__r.Fare_Class__c,
                   Flight__c, Flight__r.Flight_Number__c, Flight__r.Aircraft_Type__c,
                   Flight__r.Aircraft__c, Flight__r.Origin__c, Flight__r.Destination__c
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
        String fareClass = seg.Booking__r.Fare_Class__c;

        // Resolve the aircraft's class zone via the shared booking engine
        // (same Layout_Json__c reading the website uses). Returns null if
        // no zone is found — falls back to the legacy generic grid.
        Skywave_BookingEngine.ClassZone zone = resolveZoneForFlight(seg.Flight__c, fareClass);

        // Occupancy: real other-passenger seats on this flight + travel
        // date, EXCLUDING the visitor's own segment.
        Set<String> occupiedSeats = loadOccupancy(seg);

        Map<String, Object> state = new Map<String, Object>{
            'bookingSegmentId' => seg.Id,
            'bookingCode' => seg.Booking__r.Confirmation_Code__c,
            'flightNumber' => seg.Flight__r.Flight_Number__c,
            'aircraftType' => seg.Flight__r.Aircraft_Type__c,
            'origin' => seg.Flight__r.Origin__c,
            'destination' => seg.Flight__r.Destination__c,
            'currentSeat' => currentSeat,
            'fareClass' => fareClass,
            'rows' => (zone != null)
                ? buildRowsFromZone(zone, currentSeat, occupiedSeats)
                : buildFallbackRows(seg.Id, currentSeat)
        };

        out.seatMapData = new Skywave_SeatMapData(JSON.serialize(state));
        out.success = true;
        out.message = 'Seat map ready';
        return out;
    }

    /** Resolve the booked class's zone (rowStart, rowEnd, letters) via
     *  Asset → Product2 → Skywave_Seat_Map__c. Mirrors the website's path. */
    private static Skywave_BookingEngine.ClassZone resolveZoneForFlight(Id flightId, String fareClass) {
        if (flightId == null || String.isBlank(fareClass)) return null;
        List<Flight__c> flights = [
            SELECT Id, Aircraft__c, Aircraft_Type__c FROM Flight__c WHERE Id = :flightId LIMIT 1
        ];
        if (flights.isEmpty()) return null;
        Flight__c f = flights[0];

        Id productId;
        if (f.Aircraft__c != null) {
            List<Asset> a = [SELECT Product2Id FROM Asset WHERE Id = :f.Aircraft__c LIMIT 1];
            if (!a.isEmpty()) productId = a[0].Product2Id;
        }
        if (productId == null && String.isNotBlank(f.Aircraft_Type__c)) {
            List<Product2> p = [SELECT Id FROM Product2 WHERE Name = :f.Aircraft_Type__c LIMIT 1];
            if (!p.isEmpty()) productId = p[0].Id;
        }
        if (productId == null) return null;

        List<Skywave_Seat_Map__c> sms = [
            SELECT Layout_Json__c FROM Skywave_Seat_Map__c
            WHERE Aircraft_Type__c = :productId LIMIT 1
        ];
        if (sms.isEmpty()) return null;
        return Skywave_BookingEngine.parseZone(sms[0].Layout_Json__c,
            Skywave_FareClass.normalizeOrDefault(fareClass));
    }

    /** Cross-passenger occupancy: anyone else booked on the same flight +
     *  travel date who already has a seat. Returns codes uppercased. */
    private static Set<String> loadOccupancy(Booking_Segment__c seg) {
        Set<String> out = new Set<String>();
        if (seg.Flight__c == null) return out;
        // Travel date + flight uniquely identifies a flight instance —
        // multiple travel dates share the same Flight__c.
        Date travelDate = null;
        for (Booking_Segment__c s : [
            SELECT Travel_Date__c FROM Booking_Segment__c WHERE Id = :seg.Id LIMIT 1
        ]) {
            travelDate = s.Travel_Date__c;
        }
        if (travelDate == null) return out;
        for (Booking_Segment__c o : [
            SELECT Seat_Number__c
            FROM Booking_Segment__c
            WHERE Flight__c = :seg.Flight__c
              AND Travel_Date__c = :travelDate
              AND Id != :seg.Id
              AND Booking__r.Status__c IN ('Confirmed', 'Pending Confirmation')
        ]) {
            if (String.isNotBlank(o.Seat_Number__c)) out.add(o.Seat_Number__c.toUpperCase());
        }
        return out;
    }

    /** Per-class seat grid sized to the booked class zone. Aisles are
     *  represented by skipping a column between groups (the LWC iterates
     *  letters in order, so any gap shows as visual whitespace). */
    private static List<Map<String, Object>> buildRowsFromZone(
        Skywave_BookingEngine.ClassZone zone, String currentSeat, Set<String> occupied
    ) {
        String upperCurrent = (currentSeat == null) ? '' : currentSeat.toUpperCase();
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Integer row = zone.rowStart; row <= zone.rowEnd; row++) {
            List<Map<String, Object>> seats = new List<Map<String, Object>>();
            for (String letter : zone.letters) {
                String code = String.valueOf(row) + letter;
                Boolean isCurrent = (code == upperCurrent);
                Boolean taken = !isCurrent && occupied.contains(code);
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

    /** Generic fallback grid for aircraft with no Skywave_Seat_Map__c. */
    private static List<Map<String, Object>> buildFallbackRows(Id segmentId, String currentSeat) {
        Integer seed = Math.abs(String.valueOf(segmentId).hashCode());
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Integer row = FALLBACK_FIRST_ROW; row <= FALLBACK_LAST_ROW; row++) {
            List<Map<String, Object>> seats = new List<Map<String, Object>>();
            for (Integer i = 0; i < FALLBACK_LETTERS.size(); i++) {
                String code = row + FALLBACK_LETTERS[i];
                Boolean isCurrent = (currentSeat != null && code == currentSeat.toUpperCase());
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
