public class Skywave_FlightBook {

    public class Request {
        @InvocableVariable(label='Flight Info' description='The flight information for booking' required=true)
        public String flightInfo;
    }

    @InvocableMethod(label='Book Flight' description='Books a flight for the current user')
    public static List<Result> bookFlight(List<Request> requests) {
        List<Result> results = new List<Result>();
        Result r = new Result();
        r.success = true;

        Booking b = new Booking();
        b.bookingReference = 'SW8K2M';
        b.total = '$487';
        b.rebookingConditions = 'allowed, plus fare difference';
        b.cancellationConditions = 'fully refundable';
        b.checkedBaggageAllowance = '2 (50lbs each)';
        b.flights = new List<Flight>();

        Flight f1 = new Flight();
        f1.duration = '5h 20m';
        f1.originDateTime = 'Thursday, March 19, 2026 6:30 AM PST';
        f1.destinationDateTime = 'Thursday, March 19, 2026 2:50 PM EST';
        f1.originCity = 'Seattle';
        f1.destinationCity = 'New York';
        f1.bookingClass = 'Choice';
        f1.numberOfFlights = 1;
        f1.segments = new List<Segment>();

        Segment s1 = new Segment();
        s1.segmentType = 'flight';
        s1.duration = '5h 20m';
        s1.flightNumber = '1388';
        s1.departureDateTime = 'Thursday, March 19, 2026 6:30 AM PST';
        s1.departureCity = 'Seattle, WA';
        s1.departureAirport = 'Seattle-Tacoma International';
        s1.departureAirportCode = 'SEA';
        s1.arrivalDateTime = 'Thursday, March 19, 2026 2:50 PM EST';
        s1.arrivalCity = 'New York, NY';
        s1.arrivalAirport = 'John F. Kennedy International';
        s1.arrivalAirportCode = 'JFK';
        s1.bookingClass = 'Choice';
        s1.operatingAircraft = 'Boeing 737-800';
        s1.operatingAirline = 'Skywave Airlines';

        f1.segments.add(s1);
        b.flights.add(f1);
        r.booking = b;
        results.add(r);
        return results;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='bookingCode' description='The flight booking code in case of booking success')
        public Booking booking;
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
