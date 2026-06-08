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
 * The website skips the chat path's Pending → Confirmed two-step (no
 * payment-widget animation here — clicking Book is the payment cue).
 *
 * This endpoint is a thin shim: validation + JSON shaping only. All
 * domain logic lives in Skywave_BookingEngine.
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
        String travelDateStr = String.valueOf(body.get('travelDate'));
        String fareClassInput = String.valueOf(body.get('fareClass'));
        Object checkedBagsObj = body.get('checkedBags');
        String seatPref = String.valueOf(body.get('seatPreference'));

        if (String.isBlank(contactId)) { errorOut(res, 400, 'missing_contactId'); return; }
        if (String.isBlank(flightKey)) { errorOut(res, 400, 'missing_flightKey'); return; }
        if (String.isBlank(travelDateStr)) { errorOut(res, 400, 'missing_travelDate'); return; }

        Date travelDate;
        try { travelDate = Date.valueOf(travelDateStr); }
        catch (Exception e) { errorOut(res, 400, 'invalid_travelDate'); return; }
        if (travelDate < Date.today()) { errorOut(res, 400, 'date_in_past'); return; }

        Integer checkedBags = 0;
        if (checkedBagsObj instanceof Integer) checkedBags = (Integer) checkedBagsObj;
        else if (checkedBagsObj instanceof Decimal) checkedBags = ((Decimal) checkedBagsObj).intValue();

        Skywave_BookingEngine.CreateRequest engineReq = new Skywave_BookingEngine.CreateRequest();
        engineReq.contactId = contactId;
        engineReq.flightKey = flightKey;
        engineReq.travelDate = travelDate;
        engineReq.fareClass = fareClassInput;
        engineReq.checkedBags = checkedBags;
        engineReq.seatPreference = seatPref;
        // Website skips Pending — clicking Book IS the payment cue.
        engineReq.initialStatus = 'Confirmed';
        engineReq.initialPaymentStatus = 'Paid';

        Skywave_BookingEngine.CreateResult r = Skywave_BookingEngine.createBooking(engineReq);
        if (!r.success) {
            Integer status = (r.errorCode == 'contact_not_found' || r.errorCode == 'flight_not_found')
                ? 404 : (r.errorCode == 'create_failed' ? 500 : 400);
            res.statusCode = status;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'error' => r.errorCode, 'message' => r.errorMessage
            }));
            return;
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'ok' => true,
            'bookingCode' => r.bookingCode,
            'totalCharged' => r.totalDisplay,
            'segments' => r.segmentCount
        }));
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
