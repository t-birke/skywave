/**
 * REST endpoint backing the Heroku /api/website/seatmap flow.
 *
 *   POST /services/apexrest/skywave/website/seatmap
 *     { "contactId": "003...", "bookingCode": "QLG6JJ", "segmentOrder": 1 }
 *
 * Returns the seat layout for the aircraft serving this segment plus
 * the seats already taken by other passengers on the same flight +
 * travel date.
 *
 *   { "ok": true,
 *     "aircraftType": "Boeing 777-300ER",
 *     "wide": true,                    -- true if the abreast string has 2+ aisles
 *     "totalRows": 40,
 *     "fareClass": "Business",         -- the booking's fare, used to scope the picker
 *     "currentSeat": "12C",
 *     "layout": { ...Layout_Json__c... },
 *     "occupied": ["12A","14F","20D"]  -- excludes currentSeat
 *   }
 *
 * Identity: caller's contactId is from the proof cookie (relay-resolved
 * before this is invoked). Ownership re-verified by joining
 * Booking_Segment__c on Booking__r.Contact__c.
 */
@RestResource(urlMapping='/skywave/website/seatmap')
global with sharing class Skywave_WebsiteSeatMap {

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
        String bookingCode = String.valueOf(body.get('bookingCode'));
        Object segOrderObj = body.get('segmentOrder');
        if (String.isBlank(contactId)) { errorOut(res, 400, 'missing_contactId'); return; }
        if (String.isBlank(bookingCode)) { errorOut(res, 400, 'missing_bookingCode'); return; }
        if (segOrderObj == null) { errorOut(res, 400, 'missing_segmentOrder'); return; }
        Decimal segOrder;
        try { segOrder = Decimal.valueOf(String.valueOf(segOrderObj)); }
        catch (Exception e) { errorOut(res, 400, 'invalid_segmentOrder'); return; }

        // Resolve segment + ownership in one query.
        List<Booking_Segment__c> segs = [
            SELECT Id, Seat_Number__c, Travel_Date__c,
                   Booking__r.Fare_Class__c,
                   Flight__c, Flight__r.Aircraft__c
            FROM Booking_Segment__c
            WHERE Booking__r.Confirmation_Code__c = :bookingCode
              AND Booking__r.Contact__c = :contactId
              AND Segment_Order__c = :segOrder
            LIMIT 1
        ];
        if (segs.isEmpty()) { errorOut(res, 404, 'segment_not_found'); return; }
        Booking_Segment__c seg = segs[0];

        // Resolve the seat-map record via Asset → Product2 (aircraft type).
        Id aircraftAssetId = seg.Flight__r.Aircraft__c;
        if (aircraftAssetId == null) { errorOut(res, 404, 'aircraft_not_set'); return; }
        Asset aircraft = [
            SELECT Id, Product2Id, Product2.Name FROM Asset WHERE Id = :aircraftAssetId LIMIT 1
        ];
        if (aircraft == null || aircraft.Product2Id == null) {
            errorOut(res, 404, 'aircraft_type_unknown'); return;
        }

        List<Skywave_Seat_Map__c> seatmaps = [
            SELECT Id, Total_Rows__c, Layout_Json__c
            FROM Skywave_Seat_Map__c
            WHERE Aircraft_Type__c = :aircraft.Product2Id
            LIMIT 1
        ];
        if (seatmaps.isEmpty()) { errorOut(res, 404, 'seatmap_not_found'); return; }
        Skywave_Seat_Map__c seatmap = seatmaps[0];

        // Occupancy: every seat already taken on this flight + travel date,
        // excluding the caller's own segment.
        List<Booking_Segment__c> otherSegs = [
            SELECT Seat_Number__c
            FROM Booking_Segment__c
            WHERE Flight__c = :seg.Flight__c
              AND Travel_Date__c = :seg.Travel_Date__c
              AND Id != :seg.Id
              AND Booking__r.Status__c IN ('Confirmed', 'Pending Confirmation')
        ];
        Set<String> occupied = new Set<String>();
        for (Booking_Segment__c o : otherSegs) {
            if (String.isNotBlank(o.Seat_Number__c)) occupied.add(o.Seat_Number__c.toUpperCase());
        }

        Boolean wide = isWideBody(seatmap.Layout_Json__c);

        // Layout JSON is opaque text. We forward it untouched and let the
        // front-end render — see skywave-seatmap.js. If the JSON ever grows
        // private fields the FE shouldn't see, filter here.
        Map<String, Object> layout;
        try {
            layout = (Map<String, Object>) JSON.deserializeUntyped(seatmap.Layout_Json__c);
        } catch (Exception e) {
            layout = new Map<String, Object>{ 'classes' => new List<Object>() };
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'ok' => true,
            'aircraftType' => aircraft.Product2.Name,
            'wide' => wide,
            'totalRows' => seatmap.Total_Rows__c,
            'fareClass' => seg.Booking__r.Fare_Class__c,
            'currentSeat' => seg.Seat_Number__c,
            'layout' => layout,
            'occupied' => new List<String>(occupied)
        }));
    }

    /**
     * Wide-body if any class layout has 2+ aisles, i.e. its abreast string
     * has 3+ groups (e.g. "3-3-3" → 2 aisles, "2-2-2" → 2 aisles, "1-2-1"
     * → 2 aisles). Narrow body has one group (3-3) or two ("2-2").
     */
    private static Boolean isWideBody(String layoutJson) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(layoutJson);
            List<Object> classes = (List<Object>) root.get('classes');
            for (Object c : classes) {
                Map<String, Object> cm = (Map<String, Object>) c;
                String abreast = String.valueOf(cm.get('abreast'));
                if (String.isNotBlank(abreast) && abreast.split('-').size() >= 3) return true;
            }
        } catch (Exception e) {}
        return false;
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
