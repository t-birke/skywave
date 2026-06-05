/**
 * Itinerary resolution for the Skywave hub-and-spoke network.
 *
 * Skywave flies a single hub (JFK): every Flight__c is one non-stop
 * leg. A trip the network can't serve directly (e.g. LAX -> NBO) is
 * sold as a CONNECTING itinerary routed through the hub: LAX -> JFK
 * then JFK -> NBO.
 *
 * A connecting itinerary is represented everywhere as a COMPOUND
 * flight key: the leg flight numbers joined by '+', in travel order,
 * e.g. "SW3001+SW4017". This single string threads through the whole
 * pipeline untouched:
 *   - Skywave_FlightSearch emits it as the option's flightNumber, so
 *     the CLT card's Book button posts "Book flight SW3001+SW4017".
 *   - Skywave_BookFlight resolves it to a 2-leg quote.
 *   - Skywave_AckProfileForm creates one Booking_Segment__c per leg.
 *
 * A plain single key ("SW1200" or a 15/18-char Flight__c Id) resolves
 * to a one-leg itinerary, so existing direct bookings are unaffected.
 *
 * This class centralises the leg-resolution + per-class pricing that
 * was previously duplicated across FlightSearch / BookFlight /
 * AckProfileForm.
 */
public with sharing class Skywave_Itinerary {

    public static final String HUB = 'JFK';
    public static final String SEPARATOR = '+';

    /** One resolved leg + its computed clock DateTimes for a travel date. */
    public class Leg {
        public Flight__c flight;
        public DateTime departure;
        public DateTime arrival;
        public Decimal price;       // price for the chosen fare class on THIS leg
    }

    /** A full itinerary (1 leg = direct, 2 legs = connection via hub). */
    public class Resolved {
        public List<Leg> legs = new List<Leg>();
        public String fareClass;    // canonical
        public Boolean isConnection { get { return legs.size() > 1; } }

        public Decimal totalPrice() {
            Decimal sum = 0;
            for (Leg l : legs) sum += (l.price == null ? 0 : l.price);
            return sum;
        }
        public Integer totalDurationMinutes() {
            Integer total = 0;
            for (Leg l : legs) {
                if (l.flight.Duration_Minutes__c != null) {
                    total += Integer.valueOf(l.flight.Duration_Minutes__c);
                }
            }
            // Add layover (gap between leg-1 arrival and leg-2 departure).
            for (Integer i = 1; i < legs.size(); i++) {
                Long gapMs = legs[i].departure.getTime() - legs[i-1].arrival.getTime();
                if (gapMs > 0) total += (Integer) (gapMs / 60000);
            }
            return total;
        }
        public String compoundKey() {
            List<String> nums = new List<String>();
            for (Leg l : legs) nums.add(l.flight.Flight_Number__c);
            return String.join(nums, SEPARATOR);
        }
    }

    private static final String FLIGHT_FIELDS =
        'Id, Name, Flight_Number__c, Origin__c, Destination__c, ' +
        'Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c, ' +
        'Duration_Minutes__c, Aircraft_Type__c, ' +
        'Base_Price_Economy__c, Base_Price_Premium_Economy__c, ' +
        'Base_Price_Business__c, Base_Price_First__c';

    /**
     * Resolve a flight key (single number, compound "A+B", or a
     * 15/18-char Flight__c Id) into an ordered itinerary with clock
     * DateTimes pinned to travelDate. Layovers roll the second leg to
     * the next day when its scheduled departure is earlier in the day
     * than the first leg's arrival.
     */
    public static Resolved resolve(String flightKey, String fareClassInput, Date travelDate) {
        Resolved r = new Resolved();
        r.fareClass = Skywave_FareClass.normalizeOrDefault(fareClassInput);
        if (String.isBlank(flightKey)) return r;

        String key = flightKey.trim();
        List<String> tokens = key.contains(SEPARATOR)
            ? key.split('\\' + SEPARATOR)
            : new List<String>{ key };

        List<Flight__c> flights = resolveFlights(tokens);
        if (flights.size() != tokens.size()) {
            // One or more legs unresolvable — return what we have empty so
            // callers fail with a clear "flight not found" message.
            return r;
        }

        DateTime prevArrival = null;
        for (Flight__c f : flights) {
            Leg leg = new Leg();
            leg.flight = f;
            leg.price = priceFor(f, r.fareClass);

            DateTime dep = DateTime.newInstance(travelDate, f.Scheduled_Departure_Time__c);
            // For a connecting leg, push to the next day if it would
            // otherwise depart before the previous leg landed.
            if (prevArrival != null && dep < prevArrival) {
                dep = dep.addDays(1);
            }
            DateTime arr = DateTime.newInstance(dep.date(), f.Scheduled_Arrival_Time__c);
            if (f.Scheduled_Arrival_Time__c < f.Scheduled_Departure_Time__c) {
                arr = arr.addDays(1);
            }
            leg.departure = dep;
            leg.arrival = arr;
            prevArrival = arr;
            r.legs.add(leg);
        }
        return r;
    }

    /** Resolve each token (Id or flight number) to a Flight__c, preserving order. */
    private static List<Flight__c> resolveFlights(List<String> tokens) {
        Set<String> ids = new Set<String>();
        Set<String> numbers = new Set<String>();
        for (String t : tokens) {
            String tok = t.trim();
            if (tok.length() == 15 || tok.length() == 18) ids.add(tok);
            else numbers.add(tok);
        }

        Map<String, Flight__c> byId = new Map<String, Flight__c>();
        Map<String, Flight__c> byNumber = new Map<String, Flight__c>();
        if (!ids.isEmpty()) {
            for (Flight__c f : Database.query(
                'SELECT ' + FLIGHT_FIELDS + ' FROM Flight__c WHERE Id IN :ids')) {
                byId.put(f.Id, f);
            }
        }
        if (!numbers.isEmpty()) {
            for (Flight__c f : Database.query(
                'SELECT ' + FLIGHT_FIELDS + ' FROM Flight__c WHERE Flight_Number__c IN :numbers')) {
                byNumber.put(f.Flight_Number__c, f);
            }
        }

        List<Flight__c> ordered = new List<Flight__c>();
        for (String t : tokens) {
            String tok = t.trim();
            Flight__c f = byId.containsKey(tok) ? byId.get(tok) : byNumber.get(tok);
            if (f != null) ordered.add(f);
        }
        return ordered;
    }

    /** Per-leg price for the canonical fare class, defaulting to Economy. */
    public static Decimal priceFor(Flight__c flight, String canonicalFareClass) {
        if (canonicalFareClass == Skywave_FareClass.ECONOMY && flight.Base_Price_Economy__c != null) {
            return flight.Base_Price_Economy__c;
        } else if (canonicalFareClass == Skywave_FareClass.PREMIUM_ECONOMY && flight.Base_Price_Premium_Economy__c != null) {
            return flight.Base_Price_Premium_Economy__c;
        } else if (canonicalFareClass == Skywave_FareClass.BUSINESS && flight.Base_Price_Business__c != null) {
            return flight.Base_Price_Business__c;
        } else if (canonicalFareClass == Skywave_FareClass.FIRST && flight.Base_Price_First__c != null) {
            return flight.Base_Price_First__c;
        }
        return flight.Base_Price_Economy__c != null ? flight.Base_Price_Economy__c : 0;
    }

    /**
     * Find a single connecting itinerary origin -> HUB -> destination
     * on the given travel date, or null if no through-hub path exists.
     * Picks the earliest-departing first leg, then the earliest second
     * leg that departs after the first one lands (same-day connection),
     * falling back to the earliest second leg next day.
     */
    public static Resolved findConnection(String origin, String destination,
                                          String fareClassInput, Date travelDate) {
        String dayField = dayOfWeekField(travelDate);

        List<Flight__c> firstLegs = Database.query(
            'SELECT ' + FLIGHT_FIELDS + ' FROM Flight__c ' +
            'WHERE Active__c = true AND Origin__c = :origin AND Destination__c = :HUB ' +
            'AND ' + dayField + ' = true ORDER BY Scheduled_Departure_Time__c LIMIT 5');
        List<Flight__c> secondLegs = Database.query(
            'SELECT ' + FLIGHT_FIELDS + ' FROM Flight__c ' +
            'WHERE Active__c = true AND Origin__c = :HUB AND Destination__c = :destination ' +
            'AND ' + dayField + ' = true ORDER BY Scheduled_Departure_Time__c LIMIT 5');

        if (firstLegs.isEmpty() || secondLegs.isEmpty()) return null;

        // Earliest first leg; earliest viable second leg after it lands.
        Flight__c first = firstLegs[0];
        DateTime firstDep = DateTime.newInstance(travelDate, first.Scheduled_Departure_Time__c);
        DateTime firstArr = DateTime.newInstance(travelDate, first.Scheduled_Arrival_Time__c);
        if (first.Scheduled_Arrival_Time__c < first.Scheduled_Departure_Time__c) {
            firstArr = firstArr.addDays(1);
        }

        Flight__c second = null;
        for (Flight__c cand : secondLegs) {
            DateTime candDep = DateTime.newInstance(firstArr.date(), cand.Scheduled_Departure_Time__c);
            if (candDep >= firstArr.addMinutes(45)) { // 45-min min connection
                second = cand;
                break;
            }
        }
        if (second == null) second = secondLegs[0]; // fall back: next-day connection

        // Build the resolved itinerary through resolve() so DateTimes/layover
        // are computed identically to the booking path.
        String compound = first.Flight_Number__c + SEPARATOR + second.Flight_Number__c;
        return resolve(compound, fareClassInput, travelDate);
    }

    public static String dayOfWeekField(Date travelDate) {
        DateTime dt = DateTime.newInstance(travelDate, Time.newInstance(0, 0, 0, 0));
        return 'Operates_' + dt.format('EEEE') + '__c';
    }
}
