/**
 * Covers Skywave_Airports.resolveCode — the metro/city -> served-airport
 * resolver (Aliases__c SSOT) — plus its wiring into the two flight-search
 * entry points. Grounds on the deployed Skywave_Airport__mdt records (CMDT is
 * visible in test context), so no seed is required.
 */
@isTest
private class Skywave_Airports_Test {

    @isTest
    static void resolveCode_passesThroughServedAirportCode() {
        System.assertEquals('SFO', Skywave_Airports.resolveCode('SFO'), 'served code returns canonical');
        System.assertEquals('SFO', Skywave_Airports.resolveCode('sfo'), 'case-insensitive');
        System.assertEquals('SFO', Skywave_Airports.resolveCode('  sfo  '), 'trims + normalizes');
        System.assertEquals('JFK', Skywave_Airports.resolveCode('JFK'), 'hub code passthrough');
    }

    @isTest
    static void resolveCode_mapsMetroCodeToServedAirport() {
        // The reported defect: NYC is a valid IATA metro code but not a served
        // airport code — must resolve to the JFK hub.
        System.assertEquals('JFK', Skywave_Airports.resolveCode('NYC'), 'NYC metro -> JFK');
        System.assertEquals('JFK', Skywave_Airports.resolveCode('nyc'), 'metro case-insensitive');
        System.assertEquals('LHR', Skywave_Airports.resolveCode('LON'), 'LON -> LHR');
        System.assertEquals('CDG', Skywave_Airports.resolveCode('PAR'), 'PAR -> CDG');
    }

    @isTest
    static void resolveCode_mapsCityNameToServedAirport() {
        System.assertEquals('JFK', Skywave_Airports.resolveCode('New York'), 'city name -> JFK');
        System.assertEquals('JFK', Skywave_Airports.resolveCode('new york city'), 'multi-word variant -> JFK');
    }

    @isTest
    static void resolveCode_passesThroughUnknownAndBlank() {
        System.assertEquals('ZZZ', Skywave_Airports.resolveCode('zzz'), 'unknown passes through uppercased');
        System.assertEquals(null, Skywave_Airports.resolveCode(null), 'null in -> null out');
        System.assertEquals('', Skywave_Airports.resolveCode(''), 'blank in -> blank out');
    }

    @isTest
    static void flightSearch_acceptsMetroCodeWithoutError() {
        // Exercises the resolveCode wiring in Skywave_FlightSearch: a metro-code
        // destination must run cleanly (resolve + query + hub-connection
        // fallback) and return a well-formed response, regardless of seed data.
        Skywave_FlightSearch.FlightRequest req = new Skywave_FlightSearch.FlightRequest();
        req.origin = 'SFO';
        req.destination = 'NYC';
        req.departureDate = String.valueOf(Date.today().addDays(1));
        req.fareClass = 'Business';

        Test.startTest();
        List<Skywave_FlightSearch.FlightResponse> res =
            Skywave_FlightSearch.searchFlights(new List<Skywave_FlightSearch.FlightRequest>{ req });
        Test.stopTest();

        System.assertEquals(1, res.size(), 'one response per request');
        System.assertEquals(true, res[0].success, 'search runs without error');
        System.assertNotEquals(null, res[0].flightResult, 'always returns a renderable card payload');
    }

    @isTest
    static void websiteSearch_resolvesMetroCode() {
        // Exercises the resolveCode wiring in Skywave_WebsiteFlightSearch.
        Test.startTest();
        List<Object> options =
            Skywave_WebsiteFlightSearch.searchOptions('NYC', 'SFO', Date.today().addDays(1));
        Test.stopTest();
        System.assertNotEquals(null, options, 'returns a (possibly empty) option list without error');
    }
}
