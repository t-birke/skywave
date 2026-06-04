public class Skywave_GetFlightBookings {

    public class Request {
        @InvocableVariable(label='Contact Id' description='The contact ID to retrieve bookings for' required=false)
        public String contactId;
    }

    @InvocableMethod(label='Get Flights for Current User' description='Gets all active flight bookings for the user')
    public static List<Result> getBookings(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(getBookingsForContact(req.contactId));
        }
        return results;
    }

    // Booking__c is the source of truth post-Phase 3.5/4. We surface
    // only Confirmed and Pending Confirmation bookings (skipping
    // Cancelled / Completed / No-Show), grouped per booking with
    // their segments. Fare-class-driven baggage / change /
    // cancellation rules are derived locally so the agent doesn't
    // have to re-reason about them every turn.
    private static Result getBookingsForContact(String contactId) {
        Result r = new Result();
        r.bookings = new List<Booking>();

        if (String.isBlank(contactId)) {
            r.bookingCount = 0;
            r.success = true;
            return r;
        }

        try {
            List<Booking__c> bookings = [
                SELECT Id, Confirmation_Code__c, Status__c, Fare_Class__c, Total_Amount__c,
                       (SELECT Id, Segment_Order__c, Travel_Date__c,
                               Departure_DateTime__c, Arrival_DateTime__c,
                               Segment_Status__c,
                               Flight__r.Flight_Number__c,
                               Flight__r.Origin__c, Flight__r.Destination__c,
                               Flight__r.Duration_Minutes__c, Flight__r.Aircraft_Type__c
                        FROM Booking_Segments__r
                        ORDER BY Segment_Order__c, Departure_DateTime__c)
                FROM Booking__c
                WHERE Contact__c = :contactId
                  AND Status__c IN ('Confirmed', 'Pending Confirmation')
                ORDER BY CreatedDate DESC
            ];

            for (Booking__c bk : bookings) {
                r.bookings.add(buildBooking(bk));
            }
            r.bookingCount = r.bookings.size();
            r.success = true;
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Error loading bookings: ' + e.getMessage();
            System.debug('GetFlightBookings error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        return r;
    }

    private static Booking buildBooking(Booking__c bk) {
        Booking b = new Booking();
        b.bookingReference = bk.Confirmation_Code__c;
        b.total = bk.Total_Amount__c != null
            ? '$' + bk.Total_Amount__c.setScale(2).toPlainString()
            : '$0.00';
        b.rebookingConditions = rebookingFor(bk.Fare_Class__c);
        b.cancellationConditions = cancellationFor(bk.Fare_Class__c);
        b.checkedBaggageAllowance = baggageFor(bk.Fare_Class__c);
        b.flights = new List<Flight>();

        for (Booking_Segment__c seg : bk.Booking_Segments__r) {
            b.flights.add(buildFlight(seg, bk.Fare_Class__c));
        }
        return b;
    }

    private static Flight buildFlight(Booking_Segment__c seg, String fareClass) {
        Segment s = buildFlightSegment(seg, fareClass);

        Flight f = new Flight();
        f.segments = new List<Segment>{ s };
        f.numberOfFlights = 1;
        f.duration = s.duration;
        f.originDateTime = s.departureDateTime;
        f.destinationDateTime = s.arrivalDateTime;
        f.originCity = s.departureCity;
        f.destinationCity = s.arrivalCity;
        f.bookingClass = s.bookingClass;
        return f;
    }

    private static Segment buildFlightSegment(Booking_Segment__c seg, String fareClass) {
        Flight__c flight = seg.Flight__r;
        String originCode = flight != null ? flight.Origin__c : '';
        String destCode   = flight != null ? flight.Destination__c : '';

        Segment s = new Segment();
        s.segmentType = 'flight';
        s.flightNumber = flight != null ? flight.Flight_Number__c : '';
        s.departureDateTime = seg.Departure_DateTime__c != null
            ? seg.Departure_DateTime__c.format('EEEE, MMMM d, yyyy h:mm a zzz')
            : '';
        s.arrivalDateTime = seg.Arrival_DateTime__c != null
            ? seg.Arrival_DateTime__c.format('EEEE, MMMM d, yyyy h:mm a zzz')
            : '';
        s.departureAirportCode = originCode;
        s.arrivalAirportCode = destCode;
        s.departureCity = getAirportCity(originCode);
        s.arrivalCity = getAirportCity(destCode);
        s.departureAirport = getAirportName(originCode);
        s.arrivalAirport = getAirportName(destCode);
        s.bookingClass = fareClass;
        s.operatingAircraft = flight != null ? flight.Aircraft_Type__c : '';
        s.operatingAirline = 'Skywave Airlines';
        s.duration = formatDuration(flight != null ? flight.Duration_Minutes__c : null);
        return s;
    }

    private static String rebookingFor(String fareClass) {
        String c = Skywave_FareClass.normalizeOrDefault(fareClass);
        if (c == Skywave_FareClass.ECONOMY) return 'Change fee $99, plus fare difference';
        return 'No change fee, plus fare difference';
    }

    private static String cancellationFor(String fareClass) {
        String c = Skywave_FareClass.normalizeOrDefault(fareClass);
        if (c == Skywave_FareClass.ECONOMY) return 'Cancellation fee $99';
        if (c == Skywave_FareClass.PREMIUM_ECONOMY) return 'Cancellation fee $99';
        return 'Fully refundable';
    }

    private static String baggageFor(String fareClass) {
        String c = Skywave_FareClass.normalizeOrDefault(fareClass);
        if (c == Skywave_FareClass.ECONOMY) return '1 bag (50lbs)';
        if (c == Skywave_FareClass.PREMIUM_ECONOMY) return '2 bags (50lbs each)';
        if (c == Skywave_FareClass.BUSINESS) return '2 bags (70lbs each)';
        return '3 bags (70lbs each)';
    }

    private static String formatDuration(Decimal minutes) {
        if (minutes == null) return '';
        Integer total = Integer.valueOf(minutes);
        Integer hours = total / 60;
        Integer mins = Math.mod(total, 60);
        return hours + 'h ' + mins + 'm';
    }
    
    private static String getAirportCity(String airportCode) {
        Map<String, String> cityMap = new Map<String, String>{
            'ATL' => 'Atlanta',
            'DFW' => 'Dallas',
            'DEN' => 'Denver',
            'ORD' => 'Chicago',
            'LAX' => 'Los Angeles',
            'JFK' => 'New York',
            'LAS' => 'Las Vegas',
            'MCO' => 'Orlando',
            'MIA' => 'Miami',
            'SEA' => 'Seattle',
            'PHX' => 'Phoenix',
            'IAH' => 'Houston',
            'BOS' => 'Boston',
            'SFO' => 'San Francisco',
            'EWR' => 'Newark',
            'LHR' => 'London',
            'HND' => 'Tokyo',
            'SYD' => 'Sydney'
        };
        return cityMap.containsKey(airportCode) ? cityMap.get(airportCode) : airportCode;
    }

    private static String getAirportName(String airportCode) {
        Map<String, String> nameMap = new Map<String, String>{
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
        return nameMap.containsKey(airportCode) ? nameMap.get(airportCode) : airportCode;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='bookings' description='a list of bookings for the customer')
        public List<Booking> bookings;
        @InvocableVariable(label='booking count' description='number of active bookings returned (0 if none)')
        public Integer bookingCount;
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