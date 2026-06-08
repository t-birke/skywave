/**
 * Single source of truth for booking creation, cancellation, and seat
 * change. Modality wrappers (chat invocables, website REST endpoints,
 * LWC @AuraEnabled methods) are thin shims that translate their
 * inputs/outputs into this contract.
 *
 * Why this exists: bugs in seat-zone logic, confirmation-code generation,
 * and event publishing previously had to be fixed in two places (chat
 * path + website path). One implementation here, two callers — bugs are
 * fixed once.
 *
 * Public surface:
 *   - createBooking(CreateRequest)   -> CreateResult
 *   - cancelBooking(String contactId, String bookingCode) -> CancelResult
 *   - changeSeat(String contactId, String bookingCode,
 *                Decimal segmentOrder, String newSeat) -> SeatChangeResult
 *   - changeSeatBySegmentId(String segmentId, String newSeat) -> SeatChangeResult
 *     (chat-LWC path; resolves bookingCode + order from the segment)
 *   - autoSeat(Id flightId, String fareClass, String preference) -> String
 *
 * Runs `with sharing` so it respects record sharing where relevant.
 * Guest-user paths that need to bypass sharing wrap the engine call in
 * a `without sharing` shim of their own (see Skywave_ChangeSeat).
 */
public inherited sharing class Skywave_BookingEngine {
    // `inherited sharing` — runs with the caller's sharing context.
    // Website paths call from a `with sharing` REST class (integration
    // user has full Contact/Booking access, so sharing is permissive
    // anyway). Chat-LWC path calls from Skywave_ChangeSeat's
    // `without sharing` GuestSeatWriter shim so the ESW guest user can
    // see the segment to update its seat. Defaulting to `with sharing`
    // here would silently filter the guest's segment lookup → produces
    // a confusing `segment_not_found` instead of the real seat-change.

    // ---------- public DTOs --------------------------------------------

    public class CreateRequest {
        public String contactId;
        public String flightKey;          // Flight Id, flight number, or "A+B"
        public Date travelDate;
        public String fareClass;          // canonical (will be normalised)
        public Integer checkedBags;
        public String seatPreference;     // 'Window' | 'Aisle' | null
        public String initialStatus;      // 'Confirmed' (website) or 'Pending Confirmation' (chat)
        public String initialPaymentStatus; // 'Paid' or 'Unpaid'
    }

    public class CreateResult {
        public Boolean success;
        public String errorCode;          // machine-readable
        public String errorMessage;       // human-friendly
        public Id bookingId;
        public String bookingCode;
        public Decimal totalAmount;
        public String totalDisplay;       // "$1,234.00"
        public Integer segmentCount;
    }

    public class CancelResult {
        public Boolean success;
        public String errorCode;
        public String errorMessage;
        public Id bookingId;
        public String bookingCode;
        public Decimal refundAmount;
        public String refundDisplay;
        public Boolean alreadyCancelled;
    }

    public class SeatChangeResult {
        public Boolean success;
        public String errorCode;
        public String errorMessage;
        public Id bookingId;
        public String bookingCode;
        public String flightNumber;
        public Decimal segmentOrder;
        public String oldSeat;
        public String newSeat;
    }

    // ---------- create -------------------------------------------------

    public static CreateResult createBooking(CreateRequest req) {
        CreateResult r = new CreateResult();
        r.success = false;

        if (String.isBlank(req.contactId))   { r.errorCode = 'missing_contactId'; return r; }
        if (String.isBlank(req.flightKey))   { r.errorCode = 'missing_flightKey'; return r; }
        if (req.travelDate == null)          { r.errorCode = 'missing_travelDate'; return r; }

        String canonicalFareClass = Skywave_FareClass.normalizeOrDefault(req.fareClass);
        Integer checkedBags = (req.checkedBags == null) ? 0 : req.checkedBags;
        String initialStatus = String.isBlank(req.initialStatus)
            ? 'Pending Confirmation' : req.initialStatus;
        String initialPaymentStatus = String.isBlank(req.initialPaymentStatus)
            ? 'Unpaid' : req.initialPaymentStatus;

        try {
            // Verify Contact (defense in depth — modalities should already
            // have authenticated the contactId).
            List<Contact> cs = [SELECT Id FROM Contact WHERE Id = :req.contactId LIMIT 1];
            if (cs.isEmpty()) {
                r.errorCode = 'contact_not_found';
                r.errorMessage = 'Contact not found.';
                return r;
            }

            Skywave_Itinerary.Resolved itin =
                Skywave_Itinerary.resolve(req.flightKey.trim(), canonicalFareClass, req.travelDate);
            if (itin.legs.isEmpty()) {
                r.errorCode = 'flight_not_found';
                r.errorMessage = 'No flight found for: ' + req.flightKey;
                return r;
            }

            Decimal totalAmount = itin.totalPrice();
            String confirmationCode = generateConfirmationCode();

            Booking__c booking = new Booking__c(
                Contact__c = req.contactId,
                Confirmation_Code__c = confirmationCode,
                Status__c = initialStatus,
                Payment_Status__c = initialPaymentStatus,
                Fare_Class__c = canonicalFareClass,
                Total_Amount__c = totalAmount,
                Checked_Bags__c = checkedBags,
                Booking_Date__c = Date.today()
            );
            insert booking;

            // Per-leg seat zones, used to keep auto-assigned seats inside
            // the booked fare class's row range and abreast.
            Map<Id, ClassZone> zoneByFlight = resolveZones(itin, canonicalFareClass);

            List<Booking_Segment__c> segments = new List<Booking_Segment__c>();
            Integer order = 1;
            for (Skywave_Itinerary.Leg leg : itin.legs) {
                ClassZone zone = zoneByFlight.get(leg.flight.Id);
                segments.add(new Booking_Segment__c(
                    Booking__c = booking.Id,
                    Flight__c = leg.flight.Id,
                    Travel_Date__c = leg.departure.date(),
                    Departure_DateTime__c = leg.departure,
                    Arrival_DateTime__c = leg.arrival,
                    Segment_Order__c = order,
                    Segment_Status__c = 'Scheduled',
                    Seat_Number__c = pickSeat(zone, req.seatPreference)
                ));
                order++;
            }
            insert segments;

            publishFlightBookedEvent(req.contactId, itin, confirmationCode);

            r.success = true;
            r.bookingId = booking.Id;
            r.bookingCode = confirmationCode;
            r.totalAmount = totalAmount;
            r.totalDisplay = '$' + totalAmount.setScale(2).toPlainString();
            r.segmentCount = segments.size();
        } catch (Exception e) {
            r.errorCode = 'create_failed';
            r.errorMessage = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'BookingEngine.createBooking: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
        return r;
    }

    // ---------- cancel -------------------------------------------------

    public static CancelResult cancelBooking(String contactId, String bookingCode) {
        CancelResult r = new CancelResult();
        r.success = false;
        if (String.isBlank(contactId))   { r.errorCode = 'missing_contactId'; return r; }
        if (String.isBlank(bookingCode)) { r.errorCode = 'missing_bookingCode'; return r; }

        List<Booking__c> bookings = [
            SELECT Id, Confirmation_Code__c, Contact__c, Status__c, Payment_Status__c, Total_Amount__c,
                   Contact__r.Session_Id__c, Contact__r.Demo_Session__c
            FROM Booking__c
            WHERE Confirmation_Code__c = :bookingCode AND Contact__c = :contactId
            LIMIT 1
        ];
        if (bookings.isEmpty()) { r.errorCode = 'booking_not_found'; return r; }
        Booking__c b = bookings[0];

        r.bookingId = b.Id;
        r.bookingCode = b.Confirmation_Code__c;
        r.refundAmount = b.Total_Amount__c;
        r.refundDisplay = b.Total_Amount__c != null
            ? '$' + b.Total_Amount__c.setScale(2).toPlainString() : null;

        if (b.Status__c == 'Cancelled') {
            r.success = true;
            r.alreadyCancelled = true;
            return r;
        }

        try {
            b.Status__c = 'Cancelled';
            b.Payment_Status__c = 'Refunded';
            update b;

            publishMonitorEvent('booking_cancelled', b, new Map<String, Object>{
                'bookingCode' => b.Confirmation_Code__c,
                'refund' => r.refundDisplay
            });
            r.success = true;
        } catch (Exception e) {
            r.errorCode = 'cancel_failed';
            r.errorMessage = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'BookingEngine.cancelBooking: ' + e.getMessage());
        }
        return r;
    }

    // ---------- change seat (by booking code + segment order) ----------

    public static SeatChangeResult changeSeat(
        String contactId, String bookingCode, Decimal segmentOrder, String newSeat
    ) {
        SeatChangeResult r = new SeatChangeResult();
        r.success = false;
        if (String.isBlank(contactId))   { r.errorCode = 'missing_contactId'; return r; }
        if (String.isBlank(bookingCode)) { r.errorCode = 'missing_bookingCode'; return r; }
        if (segmentOrder == null)        { r.errorCode = 'missing_segmentOrder'; return r; }
        if (String.isBlank(newSeat))     { r.errorCode = 'missing_newSeat'; return r; }
        if (!isValidSeatFormat(newSeat)) { r.errorCode = 'invalid_seat_format'; return r; }

        // Verify ownership + not cancelled in one query.
        List<Booking__c> bookings = [
            SELECT Id, Confirmation_Code__c, Status__c,
                   Contact__r.Session_Id__c, Contact__r.Demo_Session__c
            FROM Booking__c
            WHERE Confirmation_Code__c = :bookingCode AND Contact__c = :contactId
            LIMIT 1
        ];
        if (bookings.isEmpty()) { r.errorCode = 'booking_not_found'; return r; }
        Booking__c b = bookings[0];
        if (b.Status__c != 'Confirmed' && b.Status__c != 'Pending Confirmation') {
            r.errorCode = 'booking_not_confirmed';
            return r;
        }

        List<Booking_Segment__c> segs = [
            SELECT Id, Seat_Number__c, Segment_Order__c, Flight__r.Flight_Number__c
            FROM Booking_Segment__c
            WHERE Booking__c = :b.Id AND Segment_Order__c = :segmentOrder
            LIMIT 1
        ];
        if (segs.isEmpty()) { r.errorCode = 'segment_not_found'; return r; }
        return updateSeatRow(segs[0], newSeat, b);
    }

    // ---------- change seat (by segment Id) — chat LWC path ------------

    public static SeatChangeResult changeSeatBySegmentId(String segmentId, String newSeat) {
        SeatChangeResult r = new SeatChangeResult();
        r.success = false;
        if (String.isBlank(segmentId)) { r.errorCode = 'missing_segmentId'; return r; }
        if (String.isBlank(newSeat))   { r.errorCode = 'missing_newSeat'; return r; }
        if (!isValidSeatFormat(newSeat)) { r.errorCode = 'invalid_seat_format'; return r; }

        List<Booking_Segment__c> segs = [
            SELECT Id, Seat_Number__c, Segment_Order__c,
                   Booking__r.Id, Booking__r.Confirmation_Code__c, Booking__r.Status__c,
                   Booking__r.Contact__r.Session_Id__c,
                   Booking__r.Contact__r.Demo_Session__c,
                   Flight__r.Flight_Number__c
            FROM Booking_Segment__c
            WHERE Id = :segmentId
            LIMIT 1
        ];
        if (segs.isEmpty()) { r.errorCode = 'segment_not_found'; return r; }
        Booking_Segment__c seg = segs[0];

        // Synthesize a thin Booking shell carrying the fields updateSeatRow
        // needs (id + code + monitor identifiers). We don't re-query the
        // booking — saves a SOQL on the chat-LWC path.
        Booking__c bookingShell = new Booking__c(
            Id = seg.Booking__r.Id,
            Confirmation_Code__c = seg.Booking__r.Confirmation_Code__c,
            Status__c = seg.Booking__r.Status__c
        );
        // Contact relationship can't be set on an in-memory SObject directly;
        // pull it through a wrapper carried separately in publish.
        return updateSeatRowChatPath(seg, newSeat, bookingShell,
            seg.Booking__r.Contact__r != null ? seg.Booking__r.Contact__r.Session_Id__c : null,
            seg.Booking__r.Contact__r != null ? seg.Booking__r.Contact__r.Demo_Session__c : null);
    }

    // ---------- public auto-seat helper --------------------------------

    /**
     * Compute a sensible auto-assigned seat for a single-leg booking.
     * Used by the chat path's text-mode booking (where Skywave_AckProfileForm
     * resolved an itinerary outside of createBooking).
     */
    public static String autoSeat(Id flightId, String fareClass, String preference) {
        if (flightId == null) return pickSeat(null, preference);
        // Re-resolve the zone for this single flight by faking a one-leg
        // resolved itinerary.
        Map<Id, Flight__c> fmap = new Map<Id, Flight__c>([
            SELECT Id, Aircraft__c, Aircraft_Type__c FROM Flight__c WHERE Id = :flightId LIMIT 1
        ]);
        if (fmap.isEmpty()) return pickSeat(null, preference);
        ClassZone zone = resolveZoneForFlight(fmap.values()[0],
            Skywave_FareClass.normalizeOrDefault(fareClass));
        return pickSeat(zone, preference);
    }

    // ===================================================================
    // PRIVATE — single implementation of every duplicated bit.
    // ===================================================================

    private static SeatChangeResult updateSeatRow(Booking_Segment__c seg, String newSeat, Booking__c b) {
        SeatChangeResult r = new SeatChangeResult();
        try {
            r.oldSeat = seg.Seat_Number__c;
            seg.Seat_Number__c = newSeat.toUpperCase();
            update seg;

            r.success = true;
            r.bookingId = b.Id;
            r.bookingCode = b.Confirmation_Code__c;
            r.flightNumber = seg.Flight__r != null ? seg.Flight__r.Flight_Number__c : null;
            r.segmentOrder = seg.Segment_Order__c;
            r.newSeat = seg.Seat_Number__c;

            publishMonitorEvent('seat_changed', b, new Map<String, Object>{
                'bookingCode' => b.Confirmation_Code__c,
                'flightNumber' => r.flightNumber,
                'seat' => r.newSeat,
                'oldSeat' => r.oldSeat
            });
        } catch (Exception e) {
            r.errorCode = 'seat_change_failed';
            r.errorMessage = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'BookingEngine.updateSeatRow: ' + e.getMessage());
        }
        return r;
    }

    /**
     * Chat-LWC variant: the segment-Id path doesn't get the full Booking
     * with its Contact relationship through a single SOQL, so monitor
     * identifiers are passed in directly rather than via Booking__r.Contact__r.
     */
    private static SeatChangeResult updateSeatRowChatPath(
        Booking_Segment__c seg, String newSeat, Booking__c bookingShell,
        String deviceId, Id demoSessionId
    ) {
        SeatChangeResult r = new SeatChangeResult();
        try {
            r.oldSeat = seg.Seat_Number__c;
            seg.Seat_Number__c = newSeat.toUpperCase();
            update seg;

            r.success = true;
            r.bookingId = bookingShell.Id;
            r.bookingCode = bookingShell.Confirmation_Code__c;
            r.flightNumber = seg.Flight__r != null ? seg.Flight__r.Flight_Number__c : null;
            r.segmentOrder = seg.Segment_Order__c;
            r.newSeat = seg.Seat_Number__c;

            publishMonitorEventDirect('seat_changed', deviceId, demoSessionId, new Map<String, Object>{
                'bookingCode' => bookingShell.Confirmation_Code__c,
                'flightNumber' => r.flightNumber,
                'seat' => r.newSeat,
                'oldSeat' => r.oldSeat
            });
        } catch (Exception e) {
            r.errorCode = 'seat_change_failed';
            r.errorMessage = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'BookingEngine.updateSeatRowChatPath: ' + e.getMessage());
        }
        return r;
    }

    // ---------- seat zone resolution + picker --------------------------

    public class ClassZone {
        public Integer rowStart;
        public Integer rowEnd;
        public List<String> letters;
        public Set<String> aisleLetters;
        public Set<String> windowLetters;
    }

    public static Map<Id, ClassZone> resolveZones(
        Skywave_Itinerary.Resolved itin, String canonicalFareClass
    ) {
        Map<Id, ClassZone> out = new Map<Id, ClassZone>();
        Set<Id> flightIds = new Set<Id>();
        for (Skywave_Itinerary.Leg leg : itin.legs) flightIds.add(leg.flight.Id);
        Map<Id, Flight__c> flightById = new Map<Id, Flight__c>([
            SELECT Id, Aircraft__c, Aircraft_Type__c FROM Flight__c WHERE Id IN :flightIds
        ]);

        Set<Id> assetIds = new Set<Id>();
        Set<String> typeTexts = new Set<String>();
        for (Flight__c f : flightById.values()) {
            if (f.Aircraft__c != null) assetIds.add(f.Aircraft__c);
            else if (String.isNotBlank(f.Aircraft_Type__c)) typeTexts.add(f.Aircraft_Type__c);
        }
        Map<Id, Id> productByAsset = new Map<Id, Id>();
        if (!assetIds.isEmpty()) {
            for (Asset a : [SELECT Id, Product2Id FROM Asset WHERE Id IN :assetIds]) {
                if (a.Product2Id != null) productByAsset.put(a.Id, a.Product2Id);
            }
        }
        Map<String, Id> productByName = new Map<String, Id>();
        if (!typeTexts.isEmpty()) {
            for (Product2 p : [SELECT Id, Name FROM Product2 WHERE Name IN :typeTexts]) {
                productByName.put(p.Name, p.Id);
            }
        }
        Set<Id> productIds = new Set<Id>(productByAsset.values());
        productIds.addAll(productByName.values());
        if (productIds.isEmpty()) return out;

        Map<Id, ClassZone> zoneByProduct = new Map<Id, ClassZone>();
        for (Skywave_Seat_Map__c sm : [
            SELECT Aircraft_Type__c, Layout_Json__c
            FROM Skywave_Seat_Map__c
            WHERE Aircraft_Type__c IN :productIds
        ]) {
            ClassZone z = parseZone(sm.Layout_Json__c, canonicalFareClass);
            if (z != null) zoneByProduct.put(sm.Aircraft_Type__c, z);
        }

        for (Skywave_Itinerary.Leg leg : itin.legs) {
            Flight__c f = flightById.get(leg.flight.Id);
            if (f == null) continue;
            Id pid = (f.Aircraft__c != null)
                ? productByAsset.get(f.Aircraft__c)
                : productByName.get(f.Aircraft_Type__c);
            if (pid != null && zoneByProduct.containsKey(pid)) {
                out.put(leg.flight.Id, zoneByProduct.get(pid));
            }
        }
        return out;
    }

    private static ClassZone resolveZoneForFlight(Flight__c f, String fareClass) {
        Id productId = null;
        if (f.Aircraft__c != null) {
            List<Asset> a = [SELECT Id, Product2Id FROM Asset WHERE Id = :f.Aircraft__c LIMIT 1];
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
        return parseZone(sms[0].Layout_Json__c, fareClass);
    }

    public static ClassZone parseZone(String layoutJson, String fareClass) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(layoutJson);
            List<Object> classes = (List<Object>) root.get('classes');
            for (Object c : classes) {
                Map<String, Object> cm = (Map<String, Object>) c;
                if (String.valueOf(cm.get('name')) != fareClass) continue;
                List<Object> rows = (List<Object>) cm.get('rows');
                Integer rowStart = ((Decimal) rows[0]).intValue();
                Integer rowEnd   = ((Decimal) rows[rows.size() - 1]).intValue();
                String abreast = String.valueOf(cm.get('abreast'));
                ClassZone z = new ClassZone();
                z.rowStart = rowStart;
                z.rowEnd = rowEnd;
                z.letters = new List<String>();
                z.aisleLetters = new Set<String>();
                z.windowLetters = new Set<String>();
                String[] groups = abreast.split('-');
                String[] alphabet = new String[]{ 'A','B','C','D','E','F','G','H','J','K','L','M' };
                Integer idx = 0;
                Integer gi = 0;
                for (String gs : groups) {
                    Integer g = Integer.valueOf(gs);
                    for (Integer i = 0; i < g; i++) {
                        String letter = alphabet[idx++];
                        z.letters.add(letter);
                        Boolean isFirstInGroup = (i == 0);
                        Boolean isLastInGroup  = (i == g - 1);
                        if (gi > 0 && isFirstInGroup) z.aisleLetters.add(letter);
                        if (gi < groups.size() - 1 && isLastInGroup) z.aisleLetters.add(letter);
                        if (gi == 0 && isFirstInGroup) z.windowLetters.add(letter);
                        if (gi == groups.size() - 1 && isLastInGroup) z.windowLetters.add(letter);
                    }
                    gi++;
                }
                return z;
            }
        } catch (Exception e) {
            System.debug('parseZone error: ' + e.getMessage());
        }
        return null;
    }

    private static String pickSeat(ClassZone zone, String preference) {
        if (zone == null) {
            // Fallback for orphan flights / fare classes missing from the
            // layout. Generic 10-30 / aisle.
            Integer row = 10 + Math.mod(Math.abs(Crypto.getRandomInteger()), 20);
            return row + 'C';
        }
        Integer span = zone.rowEnd - zone.rowStart + 1;
        Integer row = zone.rowStart + Math.mod(Math.abs(Crypto.getRandomInteger()), span);

        Set<String> pool;
        if (preference == 'Window' && !zone.windowLetters.isEmpty()) pool = zone.windowLetters;
        else if (preference == 'Aisle' && !zone.aisleLetters.isEmpty()) pool = zone.aisleLetters;
        else pool = new Set<String>(zone.letters);

        List<String> options = new List<String>(pool);
        return row + options[Math.mod(Math.abs(Crypto.getRandomInteger()), options.size())];
    }

    // ---------- confirmation code -------------------------------------

    private static String generateConfirmationCode() {
        String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        String code = '';
        for (Integer i = 0; i < 6; i++) {
            Integer idx = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            code += chars.substring(idx, idx + 1);
        }
        return code;
    }

    // ---------- monitor event publish ---------------------------------

    /**
     * Per-leg flight_booked event with the rich payload the demo monitor
     * consumes (legs array, isConnection, connectionAirport). Best-effort.
     */
    private static void publishFlightBookedEvent(
        Id contactId, Skywave_Itinerary.Resolved itin, String bookingCode
    ) {
        try {
            List<Contact> cs = [
                SELECT Session_Id__c, Demo_Session__c FROM Contact WHERE Id = :contactId LIMIT 1
            ];
            if (cs.isEmpty() || String.isBlank(cs[0].Session_Id__c)) return;
            if (cs[0].Demo_Session__c == null) return;

            List<Map<String, String>> legs = new List<Map<String, String>>();
            for (Skywave_Itinerary.Leg leg : itin.legs) {
                legs.add(new Map<String, String>{
                    'from' => leg.flight.Origin__c,
                    'to'   => leg.flight.Destination__c,
                    'flightNumber' => leg.flight.Flight_Number__c
                });
            }
            Map<String, Object> payload = new Map<String, Object>{
                'legs' => legs,
                'bookingCode' => bookingCode,
                'isConnection' => itin.isConnection
            };
            if (itin.isConnection) {
                payload.put('connectionAirport', itin.legs[0].flight.Destination__c);
            }
            Skywave_RestUtil.publishEvent(
                'flight_booked', cs[0].Session_Id__c, cs[0].Demo_Session__c, payload);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'flight_booked publish skipped: ' + e.getMessage());
        }
    }

    private static void publishMonitorEvent(
        String eventType, Booking__c b, Map<String, Object> payload
    ) {
        try {
            String deviceId = b.Contact__r != null ? b.Contact__r.Session_Id__c : null;
            Id demoSessionId = b.Contact__r != null ? b.Contact__r.Demo_Session__c : null;
            publishMonitorEventDirect(eventType, deviceId, demoSessionId, payload);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, eventType + ' publish skipped: ' + e.getMessage());
        }
    }

    private static void publishMonitorEventDirect(
        String eventType, String deviceId, Id demoSessionId, Map<String, Object> payload
    ) {
        if (String.isBlank(deviceId) || demoSessionId == null) return;
        try {
            Skywave_RestUtil.publishEvent(eventType, deviceId, demoSessionId, payload);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, eventType + ' publish skipped: ' + e.getMessage());
        }
    }

    // ---------- helpers -----------------------------------------------

    private static Boolean isValidSeatFormat(String seat) {
        if (String.isBlank(seat)) return false;
        Pattern p = Pattern.compile('^\\d{1,2}[A-Z]$');
        return p.matcher(seat.toUpperCase()).matches();
    }
}
