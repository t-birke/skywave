/**
 * REST endpoint backing the Heroku /api/website/bookings/create flow.
 *
 *   POST /services/apexrest/skywave/website/bookings/create
 *     { "contactId": "003...", "flightKey": "SW1200" or "SW3001+SW4017",
 *       "travelDate": "2026-08-15", "fareClass": "Business",
 *       "checkedBags": 1, "seatPreference": "Aisle" }
 *
 * Returns: { "ok": true, "bookingCode": "QLG6JJ", "totalCharged": "$3655.00",
 *            "segments": 1 }
 *
 * The website skips the chat path's two-step Pending → Confirmed
 * flow because there's no payment-widget animation here — clicking
 * "Book this flight" on the site is itself the payment cue. Inserts
 * Booking__c + Booking_Segment__c with Status=Confirmed and
 * Payment_Status=Paid in a single transaction. Mirrors the engine
 * inside Skywave_AckProfileForm so booking shape stays identical
 * between the chat path and the website path.
 *
 * Identity: contactId comes from the body — but the Heroku relay
 * resolves it from the proof cookie BEFORE forwarding, so the body
 * value is already authenticated. The endpoint additionally verifies
 * the Contact exists.
 */
@RestResource(urlMapping='/skywave/website/bookings/create')
global with sharing class Skywave_WebsiteCreateBooking {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Map<String, Object> body;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString());
        } catch (Exception e) {
            errorOut(res, 400, 'invalid_json'); return;
        }

        String contactId = String.valueOf(body.get('contactId'));
        String flightKey = String.valueOf(body.get('flightKey'));
        String travelDate = String.valueOf(body.get('travelDate'));
        String fareClassInput = String.valueOf(body.get('fareClass'));
        Object checkedBagsObj = body.get('checkedBags');
        String seatPref = String.valueOf(body.get('seatPreference'));

        if (String.isBlank(contactId)) { errorOut(res, 400, 'missing_contactId'); return; }
        if (String.isBlank(flightKey)) { errorOut(res, 400, 'missing_flightKey'); return; }
        if (String.isBlank(travelDate)) { errorOut(res, 400, 'missing_travelDate'); return; }

        Date travelDateParsed;
        try { travelDateParsed = Date.valueOf(travelDate); }
        catch (Exception e) { errorOut(res, 400, 'invalid_travelDate'); return; }
        if (travelDateParsed < Date.today()) { errorOut(res, 400, 'date_in_past'); return; }

        String canonicalFareClass = Skywave_FareClass.normalizeOrDefault(fareClassInput);
        Integer checkedBags = 0;
        if (checkedBagsObj instanceof Integer) checkedBags = (Integer) checkedBagsObj;
        else if (checkedBagsObj instanceof Decimal) checkedBags = ((Decimal) checkedBagsObj).intValue();

        try {
            // Verify Contact exists. We don't re-check ownership here because
            // the Heroku relay already resolved this contactId from the proof
            // cookie before forwarding — see website-routes.js.
            List<Contact> contacts = [SELECT Id FROM Contact WHERE Id = :contactId LIMIT 1];
            if (contacts.isEmpty()) { errorOut(res, 404, 'contact_not_found'); return; }

            // Resolve flight key (Flight__c Id, single flight number, or
            // compound connection key "A+B"). Same Itinerary helper the chat
            // path uses, so segment shape is identical.
            Skywave_Itinerary.Resolved itin =
                Skywave_Itinerary.resolve(flightKey.trim(), canonicalFareClass, travelDateParsed);
            if (itin.legs.isEmpty()) { errorOut(res, 404, 'flight_not_found'); return; }

            Decimal totalAmount = itin.totalPrice();
            String confirmationCode = generateConfirmationCode();

            Booking__c booking = new Booking__c(
                Contact__c = contactId,
                Confirmation_Code__c = confirmationCode,
                Status__c = 'Confirmed',           // website skips the Pending stage
                Payment_Status__c = 'Paid',
                Fare_Class__c = canonicalFareClass,
                Total_Amount__c = totalAmount,
                Checked_Bags__c = checkedBags,
                Booking_Date__c = Date.today()
            );
            insert booking;

            // Resolve per-leg seatmaps so auto-assigned seats land in rows
            // and letters that actually exist for the booked fare class.
            // Falls back to a generic seat if a seatmap can't be resolved.
            Map<Id, ClassZone> zoneByFlightId = resolveZones(itin, canonicalFareClass);

            List<Booking_Segment__c> segments = new List<Booking_Segment__c>();
            Integer order = 1;
            for (Skywave_Itinerary.Leg leg : itin.legs) {
                ClassZone zone = zoneByFlightId.get(leg.flight.Id);
                segments.add(new Booking_Segment__c(
                    Booking__c = booking.Id,
                    Flight__c = leg.flight.Id,
                    Travel_Date__c = leg.departure.date(),
                    Departure_DateTime__c = leg.departure,
                    Arrival_DateTime__c = leg.arrival,
                    Segment_Order__c = order,
                    Segment_Status__c = 'Scheduled',
                    Seat_Number__c = assignSeat(zone, seatPref)
                ));
                order++;
            }
            insert segments;

            // Live monitor: same flight_booked publish as the chat path so
            // the demo's monitor map can light up the route regardless of
            // which surface created the booking.
            publishBookedEvent(contactId, itin, confirmationCode);

            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'ok' => true,
                'bookingCode' => confirmationCode,
                'totalCharged' => '$' + totalAmount.setScale(2).toPlainString(),
                'segments' => segments.size()
            }));
        } catch (Exception e) {
            System.debug('Skywave_WebsiteCreateBooking error: ' + e.getMessage() +
                '\n' + e.getStackTraceString());
            res.statusCode = 500;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'error' => 'create_failed', 'message' => e.getMessage()
            }));
        }
    }

    private static String generateConfirmationCode() {
        // 6-char alphanumeric, mirrors Skywave_AckProfileForm.
        String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        String code = '';
        for (Integer i = 0; i < 6; i++) {
            Integer idx = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            code += chars.substring(idx, idx + 1);
        }
        return code;
    }

    /**
     * Per-class seat zone read from Skywave_Seat_Map__c.Layout_Json__c.
     * rowStart/rowEnd are inclusive; letters lists every seat letter that
     * exists in this class's abreast string (skipping 'I' per IATA, with
     * empty slots between groups representing aisles).
     */
    private class ClassZone {
        Integer rowStart;
        Integer rowEnd;
        List<String> letters;
        // Aisle letters are the last seat of every-but-last group + first
        // seat of every-but-first group. Window letters are the first seat
        // of the first group + last seat of the last group.
        Set<String> aisleLetters;
        Set<String> windowLetters;
    }

    private static Map<Id, ClassZone> resolveZones(
        Skywave_Itinerary.Resolved itin, String canonicalFareClass
    ) {
        Map<Id, ClassZone> out = new Map<Id, ClassZone>();
        // Collect leg Flight ids and re-query Aircraft__c + Aircraft_Type__c
        // — Skywave_Itinerary's FLIGHT_FIELDS doesn't include Aircraft__c,
        // and accessing it on the Itinerary's Flight rows throws.
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

        // Fan zones back out per leg.
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

    /**
     * Find the band that matches the canonical fare class, then derive
     * its row range + letter list from the abreast string. Returns null
     * if the JSON has no matching band (e.g. Premium Economy on an
     * aircraft that doesn't offer it — caller falls back gracefully).
     */
    private static ClassZone parseZone(String layoutJson, String fareClass) {
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
                        // First letter of any group except the first → aisle.
                        // Last letter of any group except the last  → aisle.
                        Boolean isFirstInGroup = (i == 0);
                        Boolean isLastInGroup  = (i == g - 1);
                        if (gi > 0 && isFirstInGroup) z.aisleLetters.add(letter);
                        if (gi < groups.size() - 1 && isLastInGroup) z.aisleLetters.add(letter);
                        // Outermost letters of outermost groups are windows.
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

    /**
     * Pick a seat from the class zone honoring the visitor's preference.
     * Falls back to a generic 10-30/A-F seat when no zone is resolved
     * (orphan flight or a fare class that doesn't exist on the aircraft).
     */
    private static String assignSeat(ClassZone zone, String preference) {
        if (zone == null) {
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
        String letter = options[Math.mod(Math.abs(Crypto.getRandomInteger()), options.size())];
        return row + letter;
    }

    private static void publishBookedEvent(String contactId, Skywave_Itinerary.Resolved itin, String code) {
        try {
            List<Contact> cs = [SELECT Session_Id__c, Demo_Session__c FROM Contact WHERE Id = :contactId LIMIT 1];
            if (cs.isEmpty() || String.isBlank(cs[0].Session_Id__c) || cs[0].Demo_Session__c == null) return;
            Map<String, Object> p = new Map<String, Object>{
                'bookingCode' => code,
                'origin' => itin.legs[0].flight.Origin__c,
                'destination' => itin.legs[itin.legs.size() - 1].flight.Destination__c,
                'segments' => itin.legs.size()
            };
            Skywave_RestUtil.publishEvent('flight_booked', cs[0].Session_Id__c, cs[0].Demo_Session__c, p);
        } catch (Exception e) {
            System.debug('flight_booked publish skipped: ' + e.getMessage());
        }
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
