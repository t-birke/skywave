public class Skywave_GetFlightBookings {

    public class Request {
        @InvocableVariable(label='Contact Id' description='The contact ID to retrieve bookings for' required=false)
        public String contactId;

        @InvocableVariable(
            label='Deliver historic bookings'
            description='When true, include bookings whose last segment has already arrived. When false (default — and what the chat agent passes), past bookings are dropped so the agent doesn\'t propose seat changes on flown trips. The website calls with true to power the "Past bookings" section on the customer area.'
            required=false)
        public Boolean deliverHistoricBookings;
    }

    @InvocableMethod(label='Get Flights for Current User' description='Gets all active flight bookings for the user')
    public static List<Result> getBookings(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Boolean includePast = req.deliverHistoricBookings == true;
            results.add(getBookingsForContact(req.contactId, includePast));
        }
        return results;
    }

    // Booking__c is the source of truth post-Phase 3.5/4. We surface
    // only Confirmed and Pending Confirmation bookings (skipping
    // Cancelled / Completed / No-Show), grouped per booking with
    // their segments. Fare-class-driven baggage / change /
    // cancellation rules are derived locally so the agent doesn't
    // have to re-reason about them every turn.
    //
    // Past-booking gate: bookings whose last segment has already
    // arrived are dropped before they reach the agent. The agent
    // shouldn't propose seat changes on flown trips or pad
    // "your bookings" with stale itineraries — see
    // Skywave_BookingDateGate for the rule.
    private static Result getBookingsForContact(String contactId, Boolean includePast) {
        Result r = new Result();
        r.bookings = new List<Booking>();

        if (String.isBlank(contactId)) {
            r.bookingCount = 0;
            r.singleBookingCode = '';
            r.success = true;
            return r;
        }

        try {
            // Two-pass: bookings header first, segments second. Lets us run
            // the past-cutoff filter after hydration without juggling the
            // (Booking_Segments__r) sub-relationship inside a stream.
            List<Booking__c> bookings = [
                SELECT Id, Confirmation_Code__c, Status__c, Fare_Class__c, Total_Amount__c
                FROM Booking__c
                WHERE Contact__c = :contactId
                  AND Status__c IN ('Confirmed', 'Pending Confirmation')
                ORDER BY CreatedDate DESC
            ];
            if (bookings.isEmpty()) {
                r.bookingCount = 0;
                r.singleBookingCode = '';
                r.success = true;
                return r;
            }

            Set<Id> bookingIds = (new Map<Id, Booking__c>(bookings)).keySet();
            Map<Id, List<Booking_Segment__c>> segsByBooking =
                new Map<Id, List<Booking_Segment__c>>();
            for (Booking_Segment__c seg : [
                SELECT Id, Booking__c, Segment_Order__c, Travel_Date__c,
                       Departure_DateTime__c, Arrival_DateTime__c,
                       Segment_Status__c,
                       Flight__r.Flight_Number__c,
                       Flight__r.Origin__c, Flight__r.Destination__c,
                       Flight__r.Duration_Minutes__c, Flight__r.Aircraft_Type__c
                FROM Booking_Segment__c
                WHERE Booking__c IN :bookingIds
                ORDER BY Segment_Order__c ASC NULLS LAST, Departure_DateTime__c ASC NULLS LAST
            ]) {
                if (!segsByBooking.containsKey(seg.Booking__c)) {
                    segsByBooking.put(seg.Booking__c, new List<Booking_Segment__c>());
                }
                segsByBooking.get(seg.Booking__c).add(seg);
            }

            List<Booking__c> kept = new List<Booking__c>();
            for (Booking__c bk : bookings) {
                List<Booking_Segment__c> segs = segsByBooking.get(bk.Id);
                Boolean isPast = Skywave_BookingDateGate.isBookingPast(segs);
                if (isPast && !includePast) continue;
                Booking shaped = buildBookingFromHydrated(
                    bk, segs == null ? new List<Booking_Segment__c>() : segs);
                shaped.isPast = isPast;
                r.bookings.add(shaped);
                kept.add(bk);
            }
            r.bookingCount = r.bookings.size();
            // When there's exactly one UPCOMING booking it IS the seat-change
            // target, so surface its code as a scalar — Agent Script can't
            // index the list deterministically, and the seat funnel needs
            // this to run the segment count without spending an LLM cycle.
            // Past bookings (only present when includePast=true) never
            // qualify — you can't change the seat on a flown trip.
            Integer upcomingCount = 0;
            String singleUpcomingCode = '';
            for (Booking shaped : r.bookings) {
                if (shaped.isPast == true) continue;
                upcomingCount++;
                singleUpcomingCode = shaped.bookingReference;
            }
            r.singleBookingCode = (upcomingCount == 1) ? singleUpcomingCode : '';
            r.success = true;
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Error loading bookings: ' + e.getMessage();
            System.debug('GetFlightBookings error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        return r;
    }

    private static Booking buildBookingFromHydrated(Booking__c bk, List<Booking_Segment__c> segs) {
        Booking b = new Booking();
        b.bookingReference = bk.Confirmation_Code__c;
        b.total = bk.Total_Amount__c != null
            ? '$' + bk.Total_Amount__c.setScale(2).toPlainString()
            : '$0.00';
        b.rebookingConditions = rebookingFor(bk.Fare_Class__c);
        b.cancellationConditions = cancellationFor(bk.Fare_Class__c);
        b.checkedBaggageAllowance = baggageFor(bk.Fare_Class__c);
        b.flights = new List<Flight>();

        for (Booking_Segment__c seg : segs) {
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
        @InvocableVariable(label='single booking code' description='Confirmation code when exactly one booking exists; blank otherwise. The seat-change target shortcut.')
        public String singleBookingCode;
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
        @InvocableVariable(label='is past' description='True iff every segment has already arrived. Always false in the agent path (those bookings are filtered out before they get here); only meaningful when deliverHistoricBookings=true.')
        public Boolean isPast = false;
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