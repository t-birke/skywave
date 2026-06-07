/**
 * REST endpoints backing booking management on the website.
 *
 *   POST /services/apexrest/skywave/website/bookings/cancel
 *     { "contactId": "003...", "bookingCode": "QLG6JJ" }
 *
 *   POST /services/apexrest/skywave/website/bookings/seat
 *     { "contactId": "003...", "bookingCode": "QLG6JJ",
 *       "segmentOrder": 1, "newSeat": "12C" }
 *
 * Both calls re-verify ownership: the Booking__c must belong to the
 * caller's contactId, otherwise 404. The Heroku relay resolves the
 * contactId from the proof cookie before forwarding, so the body is
 * already authenticated; the ownership check here is defense-in-depth.
 *
 * Cancellation flips Status__c → 'Cancelled' (also nulls out
 * Payment_Status__c → 'Refunded' for demo realism). Seat change writes
 * Booking_Segment__c.Seat_Number__c. Both publish a Demo_Event__e so
 * the live monitor can react.
 *
 * Name changes are NOT here — name lives on Contact, so the website
 * routes them through the existing PUT /skywave/website/profile/save.
 */
@RestResource(urlMapping='/skywave/website/bookings/manage/*')
global with sharing class Skywave_WebsiteManageBooking {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        // Sub-action selected by the trailing path segment:
        //   /skywave/website/bookings/manage/cancel  -> cancelBooking
        //   /skywave/website/bookings/manage/seat    -> changeSeat
        String uri = RestContext.request.requestURI;
        String action = uri.substring(uri.lastIndexOf('/') + 1);

        Map<String, Object> body;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString());
        } catch (Exception e) {
            errorOut(res, 400, 'invalid_json'); return;
        }

        String contactId = String.valueOf(body.get('contactId'));
        String bookingCode = String.valueOf(body.get('bookingCode'));
        if (String.isBlank(contactId)) { errorOut(res, 400, 'missing_contactId'); return; }
        if (String.isBlank(bookingCode)) { errorOut(res, 400, 'missing_bookingCode'); return; }

        // Ownership check + booking fetch in one query.
        List<Booking__c> bookings = [
            SELECT Id, Confirmation_Code__c, Contact__c, Status__c, Payment_Status__c, Total_Amount__c,
                   Contact__r.Session_Id__c, Contact__r.Demo_Session__c
            FROM Booking__c
            WHERE Confirmation_Code__c = :bookingCode AND Contact__c = :contactId
            LIMIT 1
        ];
        if (bookings.isEmpty()) { errorOut(res, 404, 'booking_not_found'); return; }
        Booking__c booking = bookings[0];

        if (action == 'cancel') {
            cancelBooking(res, booking);
        } else if (action == 'seat') {
            changeSeat(res, booking, body);
        } else {
            errorOut(res, 400, 'unknown_action');
        }
    }

    private static void cancelBooking(RestResponse res, Booking__c booking) {
        if (booking.Status__c == 'Cancelled') {
            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'ok' => true, 'message' => 'Already cancelled.', 'bookingCode' => booking.Confirmation_Code__c
            }));
            return;
        }
        booking.Status__c = 'Cancelled';
        booking.Payment_Status__c = 'Refunded';
        update booking;

        publishEvent('booking_cancelled', booking, new Map<String, Object>{
            'bookingCode' => booking.Confirmation_Code__c,
            'refund' => booking.Total_Amount__c != null
                ? '$' + booking.Total_Amount__c.setScale(2).toPlainString() : null
        });

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'ok' => true,
            'bookingCode' => booking.Confirmation_Code__c,
            'refund' => booking.Total_Amount__c != null
                ? '$' + booking.Total_Amount__c.setScale(2).toPlainString() : null
        }));
    }

    private static void changeSeat(RestResponse res, Booking__c booking, Map<String, Object> body) {
        Object segOrderObj = body.get('segmentOrder');
        String newSeat = String.valueOf(body.get('newSeat'));
        if (segOrderObj == null) { errorOut(res, 400, 'missing_segmentOrder'); return; }
        if (String.isBlank(newSeat)) { errorOut(res, 400, 'missing_newSeat'); return; }
        if (!isValidSeatFormat(newSeat)) { errorOut(res, 400, 'invalid_seat_format'); return; }
        if (booking.Status__c != 'Confirmed') { errorOut(res, 400, 'booking_not_confirmed'); return; }

        Decimal segOrder;
        try { segOrder = Decimal.valueOf(String.valueOf(segOrderObj)); }
        catch (Exception e) { errorOut(res, 400, 'invalid_segmentOrder'); return; }

        List<Booking_Segment__c> segs = [
            SELECT Id, Seat_Number__c, Segment_Order__c, Flight__r.Flight_Number__c
            FROM Booking_Segment__c
            WHERE Booking__c = :booking.Id AND Segment_Order__c = :segOrder
            LIMIT 1
        ];
        if (segs.isEmpty()) { errorOut(res, 404, 'segment_not_found'); return; }
        Booking_Segment__c seg = segs[0];
        String oldSeat = seg.Seat_Number__c;
        seg.Seat_Number__c = newSeat.toUpperCase();
        update seg;

        publishEvent('seat_changed', booking, new Map<String, Object>{
            'bookingCode' => booking.Confirmation_Code__c,
            'flightNumber' => seg.Flight__r.Flight_Number__c,
            'seat' => seg.Seat_Number__c,
            'oldSeat' => oldSeat
        });

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'ok' => true,
            'bookingCode' => booking.Confirmation_Code__c,
            'segmentOrder' => seg.Segment_Order__c,
            'oldSeat' => oldSeat,
            'newSeat' => seg.Seat_Number__c
        }));
    }

    private static Boolean isValidSeatFormat(String seat) {
        Pattern p = Pattern.compile('^\\d{1,2}[A-Z]$');
        return p.matcher(seat.toUpperCase()).matches();
    }

    private static void publishEvent(String type, Booking__c booking, Map<String, Object> payload) {
        try {
            String deviceId = booking.Contact__r != null ? booking.Contact__r.Session_Id__c : null;
            Id demoSessionId = booking.Contact__r != null ? booking.Contact__r.Demo_Session__c : null;
            if (String.isBlank(deviceId) || demoSessionId == null) return;
            Skywave_RestUtil.publishEvent(type, deviceId, demoSessionId, payload);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, type + ' publish skipped: ' + e.getMessage());
        }
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
