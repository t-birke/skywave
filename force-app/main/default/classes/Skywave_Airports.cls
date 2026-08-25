/**
 * Static geography for the Skywave route network.
 *
 * Holds the lat/lon of every airport Skywave serves and derives the
 * nearest one to an arbitrary coordinate (great-circle / haversine).
 * Used to turn a visitor's IP-geolocated position into a sensible
 * starting airport: every airport in the network connects to the JFK
 * hub in both directions, so any of them is a valid origin.
 *
 * Geography is stored in the Skywave_Airport__mdt CMDT (SSOT); this class is a
 * thin cached accessor over it. Routes still live as Flight__c data.
 */
public with sharing class Skywave_Airports {

    public class Airport {
        public String code;
        public String city;
        public String name;
        public String aliases;   // comma-separated metro codes / city-name variants
        public Double lat;
        public Double lon;
        public Airport(String code, String city, String name, String aliases, Decimal lat, Decimal lon) {
            this.code = code; this.city = city; this.name = name; this.aliases = aliases;
            this.lat = lat.doubleValue(); this.lon = lon.doubleValue();
        }
    }

    // Airport network geography — code, city, name, lat/lon — now lives in the
    // Skywave_Airport__mdt CMDT (single source of truth, deployed as metadata; no
    // seed). This cached accessor preserves the long-standing Skywave_Airports.ALL
    // API, so every consumer (website picker getAirports, demo monitor getAirportGeo,
    // rental agent action, nearest() geolocation) reads the SSOT unchanged.
    private static List<Airport> allCache;
    public static List<Airport> ALL {
        get {
            if (allCache == null) {
                allCache = new List<Airport>();
                for (Skywave_Airport__mdt m : [
                        SELECT Code__c, City__c, Airport_Name__c, Aliases__c, Latitude__c, Longitude__c
                        FROM Skywave_Airport__mdt
                        WHERE Active__c = true
                        ORDER BY City__c
                ]) {
                    allCache.add(new Airport(
                        m.Code__c, m.City__c, m.Airport_Name__c, m.Aliases__c,
                        m.Latitude__c, m.Longitude__c));
                }
            }
            return allCache;
        }
    }

    /**
     * Resolve a caller-supplied location token to the served IATA airport code.
     *
     * Accepts an airport code (SFO), an IATA metropolitan-area code (NYC, LON,
     * PAR…), or a city name (New York, "new york city") — case- and
     * spacing-insensitive. Skywave serves exactly one airport per metro, so the
     * mapping is unambiguous (NYC -> JFK). The metro/variant tokens live in the
     * Skywave_Airport__mdt.Aliases__c SSOT, never a hardcoded list here.
     *
     * When nothing matches, the normalized input is returned unchanged so a
     * genuinely unserved location still falls through to an empty search —
     * search_flights stays the authoritative "do we fly there?" gate.
     */
    public static String resolveCode(String input) {
        if (String.isBlank(input)) return input;
        String norm = normalizeToken(input);

        // 1. Already a served airport code — return canonical (before aliases,
        //    so an exact code always wins).
        for (Airport a : ALL) {
            if (normalizeToken(a.code) == norm) return a.code;
        }
        // 2. City name or a metro/variant alias.
        for (Airport a : ALL) {
            if (normalizeToken(a.city) == norm) return a.code;
            if (String.isNotBlank(a.aliases)) {
                for (String alias : a.aliases.split(',')) {
                    if (normalizeToken(alias) == norm) return a.code;
                }
            }
        }
        // 3. Unknown — pass through uppercased; the flight query will find
        //    nothing and the agent will report we don't serve it.
        return input.trim().toUpperCase();
    }

    // Uppercase + strip everything but letters/digits, so "New York",
    // "new york", "NYC" and "N.Y.C." all compare cleanly.
    private static String normalizeToken(String s) {
        if (s == null) return '';
        return s.toUpperCase().replaceAll('[^A-Z0-9]', '');
    }

    /**
     * Nearest network airport IATA code to the given coordinate, or null
     * if the inputs are missing. Great-circle distance, so it's correct
     * across the antimeridian and hemispheres.
     */
    public static String nearest(Decimal lat, Decimal lon) {
        if (lat == null || lon == null) return null;
        return nearest(lat.doubleValue(), lon.doubleValue());
    }

    public static String nearest(Double lat, Double lon) {
        if (lat == null || lon == null) return null;
        String best = null;
        Double bestKm = null;
        for (Airport a : ALL) {
            Double km = haversineKm(lat, lon, a.lat, a.lon);
            if (bestKm == null || km < bestKm) {
                bestKm = km;
                best = a.code;
            }
        }
        return best;
    }

    private static Double haversineKm(Double lat1, Double lon1, Double lat2, Double lon2) {
        Double r = 6371.0; // earth radius km
        Double dLat = toRad(lat2 - lat1);
        Double dLon = toRad(lon2 - lon1);
        Double a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                   Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
                   Math.sin(dLon / 2) * Math.sin(dLon / 2);
        Double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return r * c;
    }

    private static Double toRad(Double deg) {
        return deg * Math.PI / 180.0;
    }
}
