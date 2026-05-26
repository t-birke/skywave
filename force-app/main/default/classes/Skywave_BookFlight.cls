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
            List<Flight__c> flights = [
                SELECT Id, Name, Flight_Number__c, Origin__c, Destination__c,
                       Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c,
                       Duration_Minutes__c, Aircraft_Type__c,
                       Base_Price_Economy__c, Base_Price_Premium_Economy__c,
                       Base_Price_Business__c, Base_Price_First__c
                FROM Flight__c
                WHERE Id = :req.flightId
                LIMIT 1
            ];
            if (flights.isEmpty()) {
                r.success = false;
                r.errorMessage = 'Flight not found for id: ' + req.flightId;
                return r;
            }
            Flight__c flight = flights[0];

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

            Decimal basePrice = getPriceForFareClass(flight, canonicalFareClass);

            // Compute departure/arrival DateTimes for the visible quote,
            // mirroring what Skywave_ConfirmBooking will write later.
            DateTime departureDateTime = DateTime.newInstance(
                travelDateParsed, flight.Scheduled_Departure_Time__c
            );
            DateTime arrivalDateTime = DateTime.newInstance(
                travelDateParsed, flight.Scheduled_Arrival_Time__c
            );
            if (flight.Scheduled_Arrival_Time__c < flight.Scheduled_Departure_Time__c) {
                arrivalDateTime = arrivalDateTime.addDays(1);
            }

            r.success = true;
            r.booking = buildBookingResponse(
                flight,
                contact,
                canonicalFareClass,
                basePrice,
                departureDateTime,
                arrivalDateTime
            );
            // Echo inputs back so the agent can pin them.
            r.selectedFlightId = req.flightId;
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

    private static Decimal getPriceForFareClass(Flight__c flight, String fareClass) {
        if (fareClass == Skywave_FareClass.ECONOMY && flight.Base_Price_Economy__c != null) {
            return flight.Base_Price_Economy__c;
        } else if (fareClass == Skywave_FareClass.PREMIUM_ECONOMY && flight.Base_Price_Premium_Economy__c != null) {
            return flight.Base_Price_Premium_Economy__c;
        } else if (fareClass == Skywave_FareClass.BUSINESS && flight.Base_Price_Business__c != null) {
            return flight.Base_Price_Business__c;
        } else if (fareClass == Skywave_FareClass.FIRST && flight.Base_Price_First__c != null) {
            return flight.Base_Price_First__c;
        }
        return flight.Base_Price_Economy__c != null ? flight.Base_Price_Economy__c : 0;
    }

    private static Booking buildBookingResponse(
        Flight__c flight,
        Contact contact,
        String canonicalFareClass,
        Decimal totalAmount,
        DateTime departureDateTime,
        DateTime arrivalDateTime
    ) {
        Booking b = new Booking();
        // No confirmation code yet — the booking has not been created.
        // Skywave_ConfirmBooking issues the code at insert time.
        b.bookingReference = '';
        b.total = '$' + totalAmount.setScale(2).toPlainString();

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

        b.flights = new List<Flight>();
        Flight f = new Flight();
        f.duration = formatDuration(flight.Duration_Minutes__c);
        f.originDateTime = formatDateTime(departureDateTime);
        f.destinationDateTime = formatDateTime(arrivalDateTime);
        f.originCity = getAirportCity(flight.Origin__c);
        f.destinationCity = getAirportCity(flight.Destination__c);
        f.bookingClass = canonicalFareClass;
        f.numberOfFlights = 1;
        f.segments = new List<Segment>();

        Segment s = new Segment();
        s.segmentType = 'flight';
        s.duration = formatDuration(flight.Duration_Minutes__c);
        s.flightNumber = flight.Flight_Number__c;
        s.departureDateTime = formatDateTime(departureDateTime);
        s.departureCity = getAirportCity(flight.Origin__c);
        s.departureAirport = getAirportName(flight.Origin__c);
        s.departureAirportCode = flight.Origin__c;
        s.arrivalDateTime = formatDateTime(arrivalDateTime);
        s.arrivalCity = getAirportCity(flight.Destination__c);
        s.arrivalAirport = getAirportName(flight.Destination__c);
        s.arrivalAirportCode = flight.Destination__c;
        s.bookingClass = canonicalFareClass;
        s.operatingAircraft = flight.Aircraft_Type__c;
        s.operatingAirline = 'Skywave Airlines';

        f.segments.add(s);
        b.flights.add(f);

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
            'LHR' => 'London', 'HND' => 'Tokyo', 'SYD' => 'Sydney'
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
            'LHR' => 'London Heathrow',
            'HND' => 'Tokyo Haneda',
            'SYD' => 'Sydney Kingsford Smith'
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
