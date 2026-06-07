/**
 * Static geography for the Skywave route network.
 *
 * Holds the lat/lon of every airport Skywave serves and derives the
 * nearest one to an arbitrary coordinate (great-circle / haversine).
 * Used to turn a visitor's IP-geolocated position into a sensible
 * starting airport: every airport in the network connects to the JFK
 * hub in both directions, so any of them is a valid origin.
 *
 * Keep this list in sync with scripts/apex/seedSkywaveRouteNetwork.apex.
 */
public with sharing class Skywave_Airports {

    public class Airport {
        public String code;
        public String city;
        public String name;
        public Double lat;
        public Double lon;
        public Airport(String code, String city, String name, Decimal lat, Decimal lon) {
            this.code = code; this.city = city; this.name = name;
            this.lat = lat.doubleValue(); this.lon = lon.doubleValue();
        }
    }

    // IATA -> city/name/coordinates. Keep in sync with the master schedule
    // seeder. Cities are the human-friendly name (no state/country) so the
    // website's autocomplete can filter on either "Paris" or "CDG".
    public static final List<Airport> ALL = new List<Airport>{
        new Airport('JFK', 'New York', 'John F. Kennedy International', 40.64, -73.78),
        new Airport('LAX', 'Los Angeles', 'Los Angeles International', 33.94, -118.41),
        new Airport('ORD', 'Chicago', 'Chicago O\'Hare International', 41.98, -87.90),
        new Airport('SFO', 'San Francisco', 'San Francisco International', 37.62, -122.38),
        new Airport('DFW', 'Dallas', 'Dallas/Fort Worth International', 32.90, -97.04),
        new Airport('ATL', 'Atlanta', 'Hartsfield-Jackson Atlanta International', 33.64, -84.43),
        new Airport('SEA', 'Seattle', 'Seattle-Tacoma International', 47.45, -122.31),
        new Airport('MIA', 'Miami', 'Miami International', 25.80, -80.29),
        new Airport('BOS', 'Boston', 'Boston Logan International', 42.36, -71.01),
        new Airport('DEN', 'Denver', 'Denver International', 39.86, -104.67),
        new Airport('IAD', 'Washington', 'Washington Dulles International', 38.95, -77.46),
        new Airport('YYZ', 'Toronto', 'Toronto Pearson International', 43.68, -79.63),
        new Airport('PHX', 'Phoenix', 'Phoenix Sky Harbor International', 33.43, -112.01),
        new Airport('LHR', 'London', 'London Heathrow', 51.47, -0.45),
        new Airport('CDG', 'Paris', 'Paris Charles de Gaulle', 49.01, 2.55),
        new Airport('FCO', 'Rome', 'Rome Fiumicino', 41.80, 12.25),
        new Airport('HND', 'Tokyo', 'Tokyo Haneda', 35.55, 139.78),
        new Airport('BKK', 'Bangkok', 'Bangkok Suvarnabhumi', 13.69, 100.75),
        new Airport('SIN', 'Singapore', 'Singapore Changi', 1.36, 103.99),
        new Airport('CPT', 'Cape Town', 'Cape Town International', -33.97, 18.60),
        new Airport('RAK', 'Marrakesh', 'Marrakesh Menara', 31.61, -8.04),
        new Airport('NBO', 'Nairobi', 'Nairobi Jomo Kenyatta International', -1.32, 36.93),
        new Airport('GIG', 'Rio de Janeiro', 'Rio de Janeiro Galeão International', -22.81, -43.25),
        new Airport('MEX', 'Mexico City', 'Mexico City International', 19.44, -99.07),
        new Airport('EZE', 'Buenos Aires', 'Buenos Aires Ezeiza International', -34.82, -58.54),
        new Airport('SYD', 'Sydney', 'Sydney Kingsford Smith', -33.95, 151.18),
        new Airport('AKL', 'Auckland', 'Auckland International', -37.01, 174.79),
        new Airport('DXB', 'Dubai', 'Dubai International', 25.25, 55.36),
        new Airport('IST', 'Istanbul', 'Istanbul Airport', 41.28, 28.75)
    };

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
