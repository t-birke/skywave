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

            List<Booking_Segment__c> segments = new List<Booking_Segment__c>();
            Integer order = 1;
            for (Skywave_Itinerary.Leg leg : itin.legs) {
                segments.add(new Booking_Segment__c(
                    Booking__c = booking.Id,
                    Flight__c = leg.flight.Id,
                    Travel_Date__c = leg.departure.date(),
                    Departure_DateTime__c = leg.departure,
                    Arrival_DateTime__c = leg.arrival,
                    Segment_Order__c = order,
                    Segment_Status__c = 'Scheduled',
                    Seat_Number__c = assignSeat(seatPref)
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

    private static String assignSeat(String preference) {
        // Quick deterministic assignment, mirrors Skywave_AckProfileForm.
        Integer row = 10 + Math.mod(Math.abs(Crypto.getRandomInteger()), 25);
        String letter;
        if (preference == 'Window') letter = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'A' : 'F';
        else if (preference == 'Aisle') letter = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'C' : 'D';
        else letter = String.fromCharArray(new List<Integer>{ 65 + Math.mod(Math.abs(Crypto.getRandomInteger()), 6) });
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
