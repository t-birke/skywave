/**
 * REST endpoint backing the Heroku /api/website/airports flow.
 *
 *   GET /services/apexrest/skywave/website/airports
 *
 * Returns the static airport network (IATA + city + name). Used by the
 * website's hero search-card autocomplete so visitors can filter by
 * either airport code or city name without having to memorise IATAs.
 *
 * Read-only, no identity required (the same way deals/destinations are
 * public on any airline site). Cached on the Heroku side for the
 * lifetime of the dyno — the network is static, no need to round-trip
 * for every keystroke.
 */
@RestResource(urlMapping='/skywave/website/airports')
global with sharing class Skywave_WebsiteAirports {

    @HttpGet
    global static void get() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        List<Map<String, Object>> airports = new List<Map<String, Object>>();
        for (Skywave_Airports.Airport a : Skywave_Airports.ALL) {
            airports.add(new Map<String, Object>{
                'code' => a.code,
                'city' => a.city,
                'name' => a.name
            });
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'airports' => airports
        }));
    }
}
