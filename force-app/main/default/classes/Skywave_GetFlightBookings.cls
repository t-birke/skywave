public class Skywave_GetFlightBookings {

    public class Request {
        @InvocableVariable(label='Contact Id' description='The contact ID to retrieve bookings for' required=false)
        public String contactId;
    }

    @InvocableMethod(label='Get Flights for Current User' description='Gets all active flight bookings for the user')
    public static List<Result> getBookings(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result r = new Result();
            r.success = true;
            r.bookings = buildDemoBookings();
            results.add(r);
        }

        return results;
    }

    // Demo data: returns two active bookings whose dates always sit
    // 3 days and 2 months out from today, so the demo stays current.
    private static List<Booking> buildDemoBookings() {
        Date today = Date.today();
        Date oneWayDate = today.addDays(3);
        Date returnOutboundDate = today.addMonths(2);
        Date returnInboundDate = returnOutboundDate.addDays(7);

        List<Booking> bookings = new List<Booking>();
        bookings.add(buildOneWayBooking(oneWayDate));
        bookings.add(buildReturnBooking(returnOutboundDate, returnInboundDate));
        return bookings;
    }

    private static Booking buildOneWayBooking(Date travelDate) {
        Booking b = new Booking();
        b.bookingReference = 'SW-LV2401';
        b.total = '$389';
        b.rebookingConditions = 'semi-flexible, plus fare difference';
        b.cancellationConditions = 'semi-flexible: $200 cancellation fee';
        b.checkedBaggageAllowance = '1 (50lbs each)';
        b.flights = new List<Flight>();

        DateTime depart = Datetime.newInstance(travelDate, Time.newInstance(9, 30, 0, 0));
        DateTime arrive = depart.addMinutes(345); // 5h 45m flight

        Segment seg = buildFlightSegment(
            'SW412', 'JFK', 'LAS', depart, arrive,
            'Choice', 'Boeing 737-800', '5h 45m'
        );

        Flight f = new Flight();
        f.segments = new List<Segment>{ seg };
        f.numberOfFlights = 1;
        f.duration = seg.duration;
        f.originDateTime = seg.departureDateTime;
        f.destinationDateTime = seg.arrivalDateTime;
        f.originCity = seg.departureCity;
        f.destinationCity = seg.arrivalCity;
        f.bookingClass = seg.bookingClass;
        b.flights.add(f);

        return b;
    }

    private static Booking buildReturnBooking(Date outboundDate, Date inboundDate) {
        Booking b = new Booking();
        b.bookingReference = 'SW-SF8825';
        b.total = '$642';
        b.rebookingConditions = 'free changes, plus fare difference';
        b.cancellationConditions = 'fully refundable';
        b.checkedBaggageAllowance = '1 (50lbs each)';
        b.flights = new List<Flight>();

        // Outbound: JFK -> SFO
        DateTime outDepart = Datetime.newInstance(outboundDate, Time.newInstance(8, 0, 0, 0));
        DateTime outArrive = outDepart.addMinutes(390); // 6h 30m
        Segment outSeg = buildFlightSegment(
            'SW88', 'JFK', 'SFO', outDepart, outArrive,
            'Choice', 'Airbus A321neo', '6h 30m'
        );
        Flight outFlight = new Flight();
        outFlight.segments = new List<Segment>{ outSeg };
        outFlight.numberOfFlights = 1;
        outFlight.duration = outSeg.duration;
        outFlight.originDateTime = outSeg.departureDateTime;
        outFlight.destinationDateTime = outSeg.arrivalDateTime;
        outFlight.originCity = outSeg.departureCity;
        outFlight.destinationCity = outSeg.arrivalCity;
        outFlight.bookingClass = outSeg.bookingClass;
        b.flights.add(outFlight);

        // Inbound: SFO -> JFK
        DateTime inDepart = Datetime.newInstance(inboundDate, Time.newInstance(18, 0, 0, 0));
        DateTime inArrive = inDepart.addMinutes(330); // 5h 30m
        Segment inSeg = buildFlightSegment(
            'SW123', 'SFO', 'JFK', inDepart, inArrive,
            'Choice', 'Airbus A321neo', '5h 30m'
        );
        Flight inFlight = new Flight();
        inFlight.segments = new List<Segment>{ inSeg };
        inFlight.numberOfFlights = 1;
        inFlight.duration = inSeg.duration;
        inFlight.originDateTime = inSeg.departureDateTime;
        inFlight.destinationDateTime = inSeg.arrivalDateTime;
        inFlight.originCity = inSeg.departureCity;
        inFlight.destinationCity = inSeg.arrivalCity;
        inFlight.bookingClass = inSeg.bookingClass;
        b.flights.add(inFlight);

        return b;
    }

    private static Segment buildFlightSegment(String flightNumber, String originCode, String destCode,
                                              DateTime depart, DateTime arrive,
                                              String fareClass, String aircraft, String duration) {
        Segment s = new Segment();
        s.segmentType = 'flight';
        s.flightNumber = flightNumber;
        s.departureDateTime = depart.format('EEEE, MMMM d, yyyy h:mm a zzz');
        s.arrivalDateTime = arrive.format('EEEE, MMMM d, yyyy h:mm a zzz');
        s.departureAirportCode = originCode;
        s.arrivalAirportCode = destCode;
        s.departureCity = getAirportCity(originCode);
        s.arrivalCity = getAirportCity(destCode);
        s.departureAirport = getAirportName(originCode);
        s.arrivalAirport = getAirportName(destCode);
        s.bookingClass = fareClass;
        s.operatingAircraft = aircraft;
        s.operatingAirline = 'Skywave Airlines';
        s.duration = duration;
        return s;
    }
    
    private static String formatDuration(Long minutes) {
        if (minutes == null || minutes == 0) return '0m';
        Long hours = minutes / 60;
        Long mins = Math.mod(minutes, 60);
        return hours + 'h ' + mins + 'm';
    }
    
    private static String calculateTotalDuration(List<Segment> segments) {
        if (segments.isEmpty()) return '0m';
        // For simplicity, sum individual segment durations
        // In real scenario, calculate from first departure to last arrival
        Long totalMinutes = 0;
        for (Segment seg : segments) {
            String[] parts = seg.duration.split('h\\s*|m');
            if (parts.size() >= 2) {
                totalMinutes += Long.valueOf(parts[0].trim()) * 60;
                if (parts[1].trim().length() > 0) {
                    totalMinutes += Long.valueOf(parts[1].trim());
                }
            }
        }
        return formatDuration(totalMinutes);
    }
    
    private static String getAirportCity(String airportCode) {
        Map<String, String> cityMap = new Map<String, String>{
            'SEA' => 'Seattle, WA',
            'JFK' => 'New York, NY',
            'LAX' => 'Los Angeles, CA',
            'LAS' => 'Las Vegas, NV',
            'ORD' => 'Chicago, IL',
            'HNL' => 'Honolulu, HI',
            'SFO' => 'San Francisco, CA',
            'MIA' => 'Miami, FL'
        };
        return cityMap.containsKey(airportCode) ? cityMap.get(airportCode) : airportCode;
    }

    private static String getAirportName(String airportCode) {
        Map<String, String> nameMap = new Map<String, String>{
            'SEA' => 'Seattle-Tacoma International',
            'JFK' => 'John F. Kennedy International',
            'LAX' => 'Los Angeles International',
            'LAS' => 'Harry Reid International',
            'ORD' => 'O\'Hare International',
            'HNL' => 'Daniel K. Inouye International',
            'SFO' => 'San Francisco International',
            'MIA' => 'Miami International'
        };
        return nameMap.containsKey(airportCode) ? nameMap.get(airportCode) : airportCode + ' Airport';
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='bookings' description='a list of bookings for the customer')
        public List<Booking> bookings;
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