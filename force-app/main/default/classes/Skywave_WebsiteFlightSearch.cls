/**
 * REST endpoint backing the Heroku /api/website/flights/search flow.
 *
 *   POST /services/apexrest/skywave/website/flights/search
 *     { "origin": "SEA", "destination": "JFK", "date": "2026-08-15" }
 *
 * Returns a multi-option, multi-fare-class result so the website can
 * render a results grid (each row a flight, each column a fare class)
 * without re-searching when the visitor toggles fare class.
 *
 * Reuses the engine inside Skywave_FlightSearch by calling its private
 * SOQL through a small inline query (the existing class is invocable-
 * shaped and only returns one fare class at a time). We don't refactor
 * the chat path here — the agent action stays single-fare for backward
 * compat. The website's grid comes from this dedicated endpoint.
 */
@RestResource(urlMapping='/skywave/website/flights/search')
global with sharing class Skywave_WebsiteFlightSearch {

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

        String origin = upper(body.get('origin'));
        String destination = upper(body.get('destination'));
        String dateStr = String.valueOf(body.get('date'));

        if (origin == null || origin.length() != 3) { errorOut(res, 400, 'invalid_origin'); return; }
        if (destination == null || destination.length() != 3) { errorOut(res, 400, 'invalid_destination'); return; }
        if (origin == destination) { errorOut(res, 400, 'same_origin_destination'); return; }
        Date travelDate;
        try { travelDate = Date.valueOf(dateStr); }
        catch (Exception e) { errorOut(res, 400, 'invalid_date'); return; }
        if (travelDate < Date.today()) { errorOut(res, 400, 'date_in_past'); return; }

        try {
            List<Map<String, Object>> options = new List<Map<String, Object>>();
            options.addAll(directFlights(origin, destination, travelDate));

            // Through-hub connection (origin -> JFK -> destination) when
            // there are no direct flights AND neither leg of the journey
            // is itself JFK — same rule as Skywave_FlightSearch.
            if (options.isEmpty() && origin != Skywave_Itinerary.HUB && destination != Skywave_Itinerary.HUB) {
                Map<String, Object> conn = connectionFlight(origin, destination, travelDate);
                if (conn != null) options.add(conn);
            }

            res.statusCode = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
                'origin' => origin,
                'destination' => destination,
                'date' => dateStr,
                'options' => options
            }));
        } catch (Exception e) {
            System.debug('Skywave_WebsiteFlightSearch error: ' + e.getMessage() +
                '\n' + e.getStackTraceString());
            errorOut(res, 500, 'search_failed');
        }
    }

    private static List<Map<String, Object>> directFlights(String origin, String destination, Date travelDate) {
        String dayOfWeek = getDayOfWeekField(travelDate);
        String soql = 'SELECT Id, Flight_Number__c, Origin__c, Destination__c, ' +
            'Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c, Duration_Minutes__c, Aircraft_Type__c, ' +
            'Base_Price_Economy__c, Base_Price_Premium_Economy__c, Base_Price_Business__c, Base_Price_First__c ' +
            'FROM Flight__c WHERE Active__c = true AND Origin__c = :origin AND Destination__c = :destination ' +
            'AND ' + dayOfWeek + ' = true ORDER BY Scheduled_Departure_Time__c LIMIT 12';
        List<Flight__c> flights = Database.query(soql);
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Flight__c f : flights) out.add(toOption(f, travelDate));
        return out;
    }

    private static Map<String, Object> connectionFlight(String origin, String destination, Date travelDate) {
        Skywave_Itinerary.Resolved conn =
            Skywave_Itinerary.findConnection(origin, destination, null, travelDate);
        if (conn == null || !conn.isConnection) return null;
        Skywave_Itinerary.Leg first = conn.legs[0];
        Skywave_Itinerary.Leg last = conn.legs[conn.legs.size() - 1];

        // For connections, sum each fare class across legs so the four
        // price slots reflect the same total flight key.
        Decimal econ = sumPrice(conn, 'Base_Price_Economy__c');
        Decimal prem = sumPrice(conn, 'Base_Price_Premium_Economy__c');
        Decimal biz  = sumPrice(conn, 'Base_Price_Business__c');
        Decimal frst = sumPrice(conn, 'Base_Price_First__c');

        return new Map<String, Object>{
            'flightKey'      => conn.compoundKey(),
            'flightNumbers'  => flightNumberList(conn),
            'origin'         => first.flight.Origin__c,
            'destination'    => last.flight.Destination__c,
            'departure'      => formatTime(first.departure),
            'arrival'        => formatTime(last.arrival),
            'departureIso'   => first.departure.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'arrivalIso'     => last.arrival.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'durationMinutes' => conn.totalDurationMinutes(),
            'duration'       => formatDuration(conn.totalDurationMinutes()),
            'stops'          => conn.legs.size() - 1,
            'stopVia'        => first.flight.Destination__c,
            'aircraft'       => first.flight.Aircraft_Type__c,
            'fares'          => fareMap(econ, prem, biz, frst)
        };
    }

    private static Decimal sumPrice(Skywave_Itinerary.Resolved conn, String fieldName) {
        Decimal total = 0;
        for (Skywave_Itinerary.Leg leg : conn.legs) {
            Decimal v = (Decimal) leg.flight.get(fieldName);
            if (v == null) return null; // missing on any leg → fare unavailable
            total += v;
        }
        return total;
    }
    private static List<String> flightNumberList(Skywave_Itinerary.Resolved conn) {
        List<String> ns = new List<String>();
        for (Skywave_Itinerary.Leg leg : conn.legs) ns.add(leg.flight.Flight_Number__c);
        return ns;
    }

    private static Map<String, Object> toOption(Flight__c f, Date travelDate) {
        DateTime dep = DateTime.newInstance(travelDate, f.Scheduled_Departure_Time__c);
        DateTime arr = DateTime.newInstance(travelDate, f.Scheduled_Arrival_Time__c);
        if (f.Scheduled_Arrival_Time__c < f.Scheduled_Departure_Time__c) arr = arr.addDays(1);

        return new Map<String, Object>{
            'flightKey'       => f.Flight_Number__c, // for direct, key == flight number
            'flightNumbers'   => new List<String>{ f.Flight_Number__c },
            'origin'          => f.Origin__c,
            'destination'     => f.Destination__c,
            'departure'       => formatTime(dep),
            'arrival'         => formatTime(arr),
            'departureIso'    => dep.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'arrivalIso'      => arr.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'durationMinutes' => f.Duration_Minutes__c != null ? Integer.valueOf(f.Duration_Minutes__c) : 0,
            'duration'        => formatDuration(f.Duration_Minutes__c),
            'stops'           => 0,
            'stopVia'         => null,
            'aircraft'        => f.Aircraft_Type__c,
            'fares'           => fareMap(f.Base_Price_Economy__c, f.Base_Price_Premium_Economy__c,
                                          f.Base_Price_Business__c, f.Base_Price_First__c)
        };
    }

    private static Map<String, Object> fareMap(Decimal econ, Decimal prem, Decimal biz, Decimal frst) {
        return new Map<String, Object>{
            'Economy'         => priceObj(econ),
            'Premium Economy' => priceObj(prem),
            'Business'        => priceObj(biz),
            'First'           => priceObj(frst)
        };
    }

    private static Map<String, Object> priceObj(Decimal d) {
        if (d == null) return null;
        return new Map<String, Object>{
            'amount' => d,
            'display' => '$' + d.setScale(2).toPlainString()
        };
    }

    private static String formatTime(DateTime dt) {
        if (dt == null) return '';
        return dt.format('h:mm a');
    }
    private static String formatDuration(Decimal minutes) {
        if (minutes == null) return '';
        Integer total = Integer.valueOf(minutes);
        return (total / 60) + 'h ' + Math.mod(total, 60) + 'm';
    }
    private static String getDayOfWeekField(Date travelDate) {
        DateTime dt = DateTime.newInstance(travelDate, Time.newInstance(0, 0, 0, 0));
        return 'Operates_' + dt.format('EEEE') + '__c';
    }
    private static String upper(Object o) {
        if (o == null) return null;
        return String.valueOf(o).trim().toUpperCase();
    }
    private static void errorOut(RestResponse res, Integer status, String code) {
        res.statusCode = status;
        res.responseBody = Blob.valueOf('{"error":"' + code + '"}');
    }
}
