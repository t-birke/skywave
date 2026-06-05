/**
 * "Select a flight" action.
 *
 * Despite the legacy name `BookFlight`, this action does NOT insert a
 * Booking__c. The booking is deferred to Skywave_ConfirmBooking, which
 * runs only after profile + payment are complete.
 *
 * Why deferred: visitors who walk away after the flight pick should
 * leave no DB residue. The pre-Phase-3.5b flow inserted Pending
 * Confirmation rows on flight pick, which then needed cleanup. The
 * new flow holds the selection in agent variables and only writes a
 * Confirmed booking once the full happy-path sequence completes.
 *
 * The Apex's only job is to validate the inputs against the live
 * Flight__c row, compute the canonical fare class + total price, and
 * return everything as a Booking-shaped DTO so the agent can quote
 * the visitor accurate values during profile/payment collection. The
 * agent pins the values into mutable variables (selected_flight_id,
 * selected_total_price, selected_fare_class) for later use.
 */
public with sharing class Skywave_BookFlight {

    public class Request {
        @InvocableVariable(label='Contact ID' description='The Contact ID for the booking' required=true)
        public String contactId;

        @InvocableVariable(label='Flight ID' description='The Flight__c record ID to book' required=true)
        public String flightId;

        @InvocableVariable(label='Travel Date' description='Date of travel (YYYY-MM-DD)' required=true)
        public String travelDate;

        @InvocableVariable(label='Fare Class' description='Fare class: Economy, Premium Economy, Business, or First. If blank, defaults to Economy.')
        public String fareClass;

        @InvocableVariable(label='Checked Bags' description='Number of checked bags')
        public Integer checkedBags;

        @InvocableVariable(label='Seat Preference' description='Seat preference (e.g., Window, Aisle)')
        public String seatPreference;
    }

    @InvocableMethod(label='Select Flight' description='Validates the visitor flight choice and returns a quote-shaped DTO. Does NOT create a booking — confirmation is deferred to Skywave_ConfirmBooking.')
    public static List<Result> bookFlight(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(executeSelection(req));
        }
        return results;
    }

    private static Result executeSelection(Request req) {
        Result r = new Result();

        // Normalise inputs up-front. Better to fail with a useful message
        // than to query Flight__c with bad data.
        String canonicalFareClass = Skywave_FareClass.normalize(req.fareClass);
        if (canonicalFareClass == null) {
            canonicalFareClass = Skywave_FareClass.ECONOMY;
        }

        if (String.isBlank(req.contactId)) {
            r.success = false;
            r.errorMessage = 'Contact id missing — the resolved Contact for this conversation is not set.';
            return r;
        }
        if (String.isBlank(req.flightId)) {
            r.success = false;
            r.errorMessage = 'Flight id missing — the agent must pass the flightId from search results.';
            return r;
        }
        if (String.isBlank(req.travelDate)) {
            r.success = false;
            r.errorMessage = 'Travel date missing — pass YYYY-MM-DD.';
            return r;
        }

        Date travelDateParsed;
        try {
            travelDateParsed = Date.valueOf(req.travelDate);
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Travel date must be YYYY-MM-DD; got "' + req.travelDate + '".';
            return r;
        }

        try {
            // Resolve the flight key into an itinerary. The key is one of:
            //   - a Flight__c Id (15/18 chars)
            //   - a single flight number ("SW1200")
            //   - a COMPOUND connection key ("SW3001+SW4017"), posted by the
            //     CLT card when the search returned a through-hub connection.
            // The card passes the flightNumber via chat ("Book flight <key>")
            // because the structured flightResult output is filter_from_agent.
            String key = req.flightId.trim();
            Skywave_Itinerary.Resolved itin =
                Skywave_Itinerary.resolve(key, canonicalFareClass, travelDateParsed);
            if (itin.legs.isEmpty()) {
                r.success = false;
                r.errorMessage = 'Flight not found for id or number: ' + key;
                return r;
            }

            List<Contact> contacts = [
                SELECT Id, Name, Membership_Tier__c FROM Contact
                WHERE Id = :req.contactId
                LIMIT 1
            ];
            if (contacts.isEmpty()) {
                r.success = false;
                r.errorMessage = 'Contact not found for id: ' + req.contactId +
                    '. The chat session is not linked to a Skywave contact.';
                return r;
            }
            Contact contact = contacts[0];

            r.success = true;
            r.booking = buildBookingResponse(itin, contact, canonicalFareClass);
            // Echo inputs back so the agent can pin them. Normalise to the
            // itinerary's flight-number key so a connection is pinned as its
            // compound key ("SW3001+SW4017"), which AckProfileForm re-resolves.
            r.selectedFlightId = itin.compoundKey();
            r.selectedTravelDate = req.travelDate;
            r.selectedFareClass = canonicalFareClass;
            r.selectedCheckedBags = req.checkedBags != null ? req.checkedBags : 0;
            r.selectedSeatPreference = req.seatPreference == null ? '' : req.seatPreference;
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Flight selection failed: ' + e.getMessage();
            System.debug('Skywave_BookFlight error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        return r;
    }

    private static Booking buildBookingResponse(
        Skywave_Itinerary.Resolved itin,
        Contact contact,
        String canonicalFareClass
    ) {
        Booking b = new Booking();
        // No confirmation code yet — the booking has not been created.
        // Skywave_ConfirmBooking issues the code at insert time.
        b.bookingReference = '';
        b.total = '$' + itin.totalPrice().setScale(2).toPlainString();

        if (canonicalFareClass == Skywave_FareClass.ECONOMY) {
            b.rebookingConditions = 'Change fee $99, plus fare difference';
            b.cancellationConditions = 'Cancellation fee $99';
            b.checkedBaggageAllowance = '1 bag (50lbs)';
        } else if (canonicalFareClass == Skywave_FareClass.PREMIUM_ECONOMY) {
            b.rebookingConditions = 'No change fee, plus fare difference';
            b.cancellationConditions = 'Cancellation fee $99';
            b.checkedBaggageAllowance = '2 bags (50lbs each)';
        } else if (canonicalFareClass == Skywave_FareClass.BUSINESS) {
            b.rebookingConditions = 'No change fee, plus fare difference';
            b.cancellationConditions = 'Fully refundable';
            b.checkedBaggageAllowance = '2 bags (70lbs each)';
        } else { // First
            b.rebookingConditions = 'No change fee, plus fare difference';
            b.cancellationConditions = 'Fully refundable';
            b.checkedBaggageAllowance = '3 bags (70lbs each)';
        }

        if (contact.Membership_Tier__c == 'Elite' || contact.Membership_Tier__c == 'Premier') {
            b.rebookingConditions = 'No change fee, plus fare difference (waived for Elite/Premier)';
            b.cancellationConditions = 'Fully refundable (Elite/Premier benefit)';
            Integer additionalBags = contact.Membership_Tier__c == 'Premier' ? 2 : 1;
            b.checkedBaggageAllowance += ' + ' + additionalBags + ' bonus bag(s)';
        }

        // One Flight grouping with one Segment per leg. For a connection
        // (>1 leg) the overall journey runs origin -> ... -> final dest with
        // the layover airport(s) implied by adjacent segments.
        Skywave_Itinerary.Leg firstLeg = itin.legs[0];
        Skywave_Itinerary.Leg lastLeg = itin.legs[itin.legs.size() - 1];

        Flight f = new Flight();
        f.duration = formatDuration(itin.totalDurationMinutes());
        f.originDateTime = formatDateTime(firstLeg.departure);
        f.destinationDateTime = formatDateTime(lastLeg.arrival);
        f.originCity = getAirportCity(firstLeg.flight.Origin__c);
        f.destinationCity = getAirportCity(lastLeg.flight.Destination__c);
        f.bookingClass = canonicalFareClass;
        f.numberOfFlights = itin.legs.size();
        f.segments = new List<Segment>();

        for (Skywave_Itinerary.Leg leg : itin.legs) {
            Flight__c flight = leg.flight;
            Segment s = new Segment();
            s.segmentType = 'flight';
            s.duration = formatDuration(flight.Duration_Minutes__c);
            s.flightNumber = flight.Flight_Number__c;
            s.departureDateTime = formatDateTime(leg.departure);
            s.departureCity = getAirportCity(flight.Origin__c);
            s.departureAirport = getAirportName(flight.Origin__c);
            s.departureAirportCode = flight.Origin__c;
            s.arrivalDateTime = formatDateTime(leg.arrival);
            s.arrivalCity = getAirportCity(flight.Destination__c);
            s.arrivalAirport = getAirportName(flight.Destination__c);
            s.arrivalAirportCode = flight.Destination__c;
            s.bookingClass = canonicalFareClass;
            s.operatingAircraft = flight.Aircraft_Type__c;
            s.operatingAirline = 'Skywave Airlines';
            f.segments.add(s);
        }

        b.flights = new List<Flight>{ f };
        return b;
    }

    private static String formatDuration(Decimal minutes) {
        if (minutes == null) return '0h 0m';
        Integer totalMinutes = Integer.valueOf(minutes);
        Integer hours = totalMinutes / 60;
        Integer mins = Math.mod(totalMinutes, 60);
        return hours + 'h ' + mins + 'm';
    }

    private static String formatDateTime(DateTime dt) {
        if (dt == null) return '';
        return dt.format('EEEE, MMMM d, yyyy h:mm a z');
    }

    private static String getAirportCity(String airportCode) {
        Map<String, String> airportCities = new Map<String, String>{
            'ATL' => 'Atlanta', 'DFW' => 'Dallas', 'DEN' => 'Denver',
            'ORD' => 'Chicago', 'LAX' => 'Los Angeles', 'JFK' => 'New York',
            'LAS' => 'Las Vegas', 'MCO' => 'Orlando', 'MIA' => 'Miami',
            'SEA' => 'Seattle', 'PHX' => 'Phoenix', 'IAH' => 'Houston',
            'BOS' => 'Boston', 'SFO' => 'San Francisco', 'EWR' => 'Newark',
            'IAD' => 'Washington', 'YYZ' => 'Toronto',
            'LHR' => 'London', 'CDG' => 'Paris', 'FCO' => 'Rome',
            'HND' => 'Tokyo', 'BKK' => 'Bangkok', 'SIN' => 'Singapore',
            'CPT' => 'Cape Town', 'RAK' => 'Marrakesh', 'NBO' => 'Nairobi',
            'GIG' => 'Rio de Janeiro', 'MEX' => 'Mexico City', 'EZE' => 'Buenos Aires',
            'SYD' => 'Sydney', 'AKL' => 'Auckland',
            'DXB' => 'Dubai', 'IST' => 'Istanbul'
        };
        return airportCities.containsKey(airportCode) ? airportCities.get(airportCode) : airportCode;
    }

    private static String getAirportName(String airportCode) {
        Map<String, String> airportNames = new Map<String, String>{
            'ATL' => 'Hartsfield-Jackson Atlanta International',
            'DFW' => 'Dallas/Fort Worth International',
            'DEN' => 'Denver International',
            'ORD' => 'Chicago O\'Hare International',
            'LAX' => 'Los Angeles International',
            'JFK' => 'John F. Kennedy International',
            'LAS' => 'Harry Reid International',
            'MCO' => 'Orlando International',
            'MIA' => 'Miami International',
            'SEA' => 'Seattle-Tacoma International',
            'PHX' => 'Phoenix Sky Harbor International',
            'IAH' => 'George Bush Intercontinental',
            'BOS' => 'Boston Logan International',
            'SFO' => 'San Francisco International',
            'EWR' => 'Newark Liberty International',
            'IAD' => 'Washington Dulles International',
            'YYZ' => 'Toronto Pearson International',
            'LHR' => 'London Heathrow',
            'CDG' => 'Paris Charles de Gaulle',
            'FCO' => 'Rome Fiumicino',
            'HND' => 'Tokyo Haneda',
            'BKK' => 'Bangkok Suvarnabhumi',
            'SIN' => 'Singapore Changi',
            'CPT' => 'Cape Town International',
            'RAK' => 'Marrakesh Menara',
            'NBO' => 'Nairobi Jomo Kenyatta International',
            'GIG' => 'Rio de Janeiro Galeão International',
            'MEX' => 'Mexico City International',
            'EZE' => 'Buenos Aires Ezeiza International',
            'SYD' => 'Sydney Kingsford Smith',
            'AKL' => 'Auckland International',
            'DXB' => 'Dubai International',
            'IST' => 'Istanbul Airport'
        };
        return airportNames.containsKey(airportCode) ? airportNames.get(airportCode) : airportCode;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='bookingCode' description='the quote-shaped DTO for this flight selection')
        public Booking booking;

        // Inputs echoed back as outputs so the agent can pin them into
        // mutable variables. Skywave_ConfirmBooking will read these later
        // to issue the actual booking.
        @InvocableVariable(label='Selected flight id' description='Flight__c Id the visitor chose; pin into selected_flight_id.')
        public String selectedFlightId;
        @InvocableVariable(label='Selected travel date' description='Travel date echoed back; pin into selected_travel_date.')
        public String selectedTravelDate;
        @InvocableVariable(label='Selected fare class' description='Canonical fare class echoed back; pin into selected_fare_class.')
        public String selectedFareClass;
        @InvocableVariable(label='Selected checked bags' description='Checked bag count echoed back; pin into selected_checked_bags.')
        public Integer selectedCheckedBags;
        @InvocableVariable(label='Selected seat preference' description='Seat preference echoed back; pin into selected_seat_preference.')
        public String selectedSeatPreference;
    }

    public class Booking {
        @InvocableVariable(required=true label='booking reference' description='the unique booking reference code')
        public String bookingReference;
        @InvocableVariable(required=true label='total price' description='the total price including taxes and fees')
        public String total;
        @InvocableVariable(required=true label='rebooking conditions' description='rules for changes to the booking')
        public String rebookingConditions;
        @InvocableVariable(required=true label='cancellation conditions' description='rules for cancellations')
        public String cancellationConditions;
        @InvocableVariable(required=true label='checked baggage allowance' description='the applicable baggage allowance')
        public String checkedBaggageAllowance;
        @InvocableVariable(required=true label='flights' description='all flights in this booking')
        public List<Flight> flights;
    }

    public class Flight {
        @InvocableVariable(required=true label='duration' description='the total duration of the flight')
        public String duration;
        @InvocableVariable(required=true label='origin date time' description='start date and time')
        public String originDateTime;
        @InvocableVariable(required=true label='destination date time' description='end date and time')
        public String destinationDateTime;
        @InvocableVariable(required=true label='origin city' description='departure city')
        public String originCity;
        @InvocableVariable(required=true label='destination city' description='arrival city')
        public String destinationCity;
        @InvocableVariable(required=true label='booking class' description='the class of booking')
        public String bookingClass;
        @InvocableVariable(required=true label='number of flights' description='the number of flight segments')
        public Integer numberOfFlights;
        @InvocableVariable(required=true label='segments' description='all segments including stops')
        public List<Segment> segments;
    }

    public class Segment {
        @InvocableVariable(required=true label='segment type' description='flight or stopover')
        public String segmentType;
        @InvocableVariable(required=true label='segment duration' description='duration in hours and minutes')
        public String duration;
        @InvocableVariable(label='flight number' description='flight number, only for flight segments')
        public String flightNumber;
        @InvocableVariable(required=true label='departure date time' description='the departure date time')
        public String departureDateTime;
        @InvocableVariable(required=true label='departure city' description='city of departure')
        public String departureCity;
        @InvocableVariable(required=true label='departure airport name' description='name of the departure airport')
        public String departureAirport;
        @InvocableVariable(required=true label='departure airport code' description='departure airport IATA code')
        public String departureAirportCode;
        @InvocableVariable(required=true label='arrival date time' description='the arrival date time')
        public String arrivalDateTime;
        @InvocableVariable(required=true label='arrival city' description='city of arrival')
        public String arrivalCity;
        @InvocableVariable(required=true label='arrival airport name' description='name of the arrival airport')
        public String arrivalAirport;
        @InvocableVariable(required=true label='arrival airport code' description='arrival airport IATA code')
        public String arrivalAirportCode;
        @InvocableVariable(label='booking class' description='class of the segment, only for flights')
        public String bookingClass;
        @InvocableVariable(label='operating aircraft' description='aircraft type, only for flights')
        public String operatingAircraft;
        @InvocableVariable(label='operating airline' description='airline operating the flight')
        public String operatingAirline;
    }
}
