/**
 * REST endpoints backing booking management on the website.
 *
 *   POST /services/apexrest/skywave/website/bookings/manage/cancel
 *     { "contactId": "003...", "bookingCode": "QLG6JJ" }
 *
 *   POST /services/apexrest/skywave/website/bookings/manage/seat
 *     { "contactId": "003...", "bookingCode": "QLG6JJ",
 *       "segmentOrder": 1, "newSeat": "12C" }
 *
 * Thin shim: route dispatch + JSON shaping. All domain logic lives in
 * Skywave_BookingEngine, which is the single source of truth shared
 * with the chat agent's path.
 */
@RestResource(urlMapping='/skywave/website/bookings/manage/*')
global with sharing class Skywave_WebsiteManageBooking {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

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

        if (action == 'cancel') {
            Skywave_BookingEngine.CancelResult r =
                Skywave_BookingEngine.cancelBooking(contactId, bookingCode);
            respondCancel(res, r);
        } else if (action == 'seat') {
            Object segOrderObj = body.get('segmentOrder');
            String newSeat = String.valueOf(body.get('newSeat'));
            if (segOrderObj == null) { errorOut(res, 400, 'missing_segmentOrder'); return; }
            Decimal segOrder;
            try { segOrder = Decimal.valueOf(String.valueOf(segOrderObj)); }
            catch (Exception e) { errorOut(res, 400, 'invalid_segmentOrder'); return; }
            Skywave_BookingEngine.SeatChangeResult r =
                Skywave_BookingEngine.changeSeat(contactId, bookingCode, segOrder, newSeat);
            respondSeat(res, r);
        } else {
            errorOut(res, 400, 'unknown_action');
        }
    }

    private static void respondCancel(RestResponse res, Skywave_BookingEngine.CancelResult r) {
        if (!r.success) {
            res.statusCode = (r.errorCode == 'booking_not_found') ? 404 : 400;
            res.responseBody = Blob.valueOf('{"error":"' + r.errorCode + '"}');
            return;
        }
        res.statusCode = 200;
        Map<String, Object> out = new Map<String, Object>{
            'ok' => true,
            'bookingCode' => r.bookingCode,
            'refund' => r.refundDisplay
        };
        if (r.alreadyCancelled == true) out.put('message', 'Already cancelled.');
        res.responseBody = Blob.valueOf(JSON.serialize(out));
    }

    private static void respondSeat(RestResponse res, Skywave_BookingEngine.SeatChangeResult r) {
        if (!r.success) {
            Integer status = 400;
            if (r.errorCode == 'booking_not_found' || r.errorCode == 'segment_not_found') status = 404;
            res.statusCode = status;
            res.responseBody = Blob.valueOf('{"error":"' + r.errorCode + '"}');
            return;
        }
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'ok' => true,
            'bookingCode' => r.bookingCode,
            'segmentOrder' => r.segmentOrder,
            'oldSeat' => r.oldSeat,
            'newSeat' => r.newSeat
        }));
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
