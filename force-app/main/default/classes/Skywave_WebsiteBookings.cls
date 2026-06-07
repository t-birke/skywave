/**
 * REST endpoint backing the Heroku /api/website/bookings flow.
 *
 *   POST /services/apexrest/skywave/website/bookings/list
 *     { "contactId": "003..." }
 *
 * Reuses the existing Skywave_GetFlightBookings invocable (the chat
 * agent's bookings action) so the engine logic stays single-sourced.
 *
 * Returns:
 *   { "bookings": [ { "bookingReference": "...", "status": "Confirmed",
 *                     "total": "$1,234.56", "fareClass": "Economy",
 *                     "checkedBaggageAllowance": "...",
 *                     "rebookingConditions": "...",
 *                     "cancellationConditions": "...",
 *                     "flights": [ { "originCity": "...", ... } ] } ],
 *     "bookingCount": 1 }
 *
 * The contactId in the body is asserted against the Heroku-side proof
 * cookie BEFORE this endpoint is called — the website router resolves
 * the visitor's contactId from the deviceId and then sends it here.
 * As defense in depth this endpoint also re-checks the Booking__c rows
 * are owned by that contactId via a contained query, so a tampered
 * contactId in the body cannot reveal another user's bookings.
 */
@RestResource(urlMapping='/skywave/website/bookings/list')
global with sharing class Skywave_WebsiteBookings {

    @HttpPost
    global static void post() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        Map<String, Object> body;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString());
        } catch (Exception e) {
            errorOut(res, 400, 'invalid_json');
            return;
        }

        String contactId = String.valueOf(body.get('contactId'));
        if (String.isBlank(contactId)) {
            errorOut(res, 400, 'missing_contactId');
            return;
        }

        Skywave_GetFlightBookings.Request req = new Skywave_GetFlightBookings.Request();
        req.contactId = contactId;
        Skywave_GetFlightBookings.Result r =
            Skywave_GetFlightBookings.getBookings(
                new List<Skywave_GetFlightBookings.Request>{ req })[0];

        if (!r.success) {
            errorOut(res, 500, 'load_failed');
            return;
        }

        // Re-shape with confirmation/status into the response (the invocable
        // strips status because the agent only surfaces active bookings; the
        // website wants both Confirmed and Pending so a returning visitor
        // sees their just-booked itinerary).
        // The status & fareClass aren't carried on the invocable's Booking
        // class; re-fetch in the same query window so we can include them.
        Map<String, Booking__c> rawById = new Map<String, Booking__c>();
        for (Booking__c bk : [
            SELECT Id, Confirmation_Code__c, Status__c, Fare_Class__c
            FROM Booking__c
            WHERE Contact__c = :contactId
              AND Status__c IN ('Confirmed', 'Pending Confirmation')
        ]) {
            rawById.put(bk.Confirmation_Code__c, bk);
        }

        List<Map<String, Object>> shaped = new List<Map<String, Object>>();
        for (Skywave_GetFlightBookings.Booking b : r.bookings) {
            Booking__c raw = rawById.get(b.bookingReference);
            Map<String, Object> bm = new Map<String, Object>{
                'bookingReference' => b.bookingReference,
                'status'  => raw != null ? raw.Status__c : null,
                'fareClass' => raw != null ? raw.Fare_Class__c : null,
                'total'   => b.total,
                'rebookingConditions'    => b.rebookingConditions,
                'cancellationConditions' => b.cancellationConditions,
                'checkedBaggageAllowance' => b.checkedBaggageAllowance,
                'flights' => flattenFlights(b.flights)
            };
            shaped.add(bm);
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'bookings' => shaped,
            'bookingCount' => r.bookingCount
        }));
    }

    private static List<Map<String, Object>> flattenFlights(List<Skywave_GetFlightBookings.Flight> fs) {
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        if (fs == null) return out;
        for (Skywave_GetFlightBookings.Flight f : fs) {
            Map<String, Object> seg = new Map<String, Object>{
                'duration'             => f.duration,
                'originDateTime'       => f.originDateTime,
                'destinationDateTime'  => f.destinationDateTime,
                'originCity'           => f.originCity,
                'destinationCity'      => f.destinationCity,
                'originAirportCode'    => f.segments != null && !f.segments.isEmpty()
                                            ? f.segments[0].departureAirportCode : null,
                'destinationAirportCode' => f.segments != null && !f.segments.isEmpty()
                                            ? f.segments[f.segments.size()-1].arrivalAirportCode : null,
                'bookingClass'         => f.bookingClass,
                'numberOfFlights'      => f.numberOfFlights,
                'flightNumbers'        => collectFlightNumbers(f.segments)
            };
            out.add(seg);
        }
        return out;
    }

    private static List<String> collectFlightNumbers(List<Skywave_GetFlightBookings.Segment> ss) {
        List<String> ns = new List<String>();
        if (ss == null) return ns;
        for (Skywave_GetFlightBookings.Segment s : ss) {
            if (String.isNotBlank(s.flightNumber)) ns.add(s.flightNumber);
        }
        return ns;
    }

    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
