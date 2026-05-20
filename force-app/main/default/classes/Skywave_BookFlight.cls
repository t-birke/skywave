public class Skywave_BookFlight {

    public class Request {
        @InvocableVariable(label='Contact ID' description='The Contact ID for the booking' required=true)
        public String contactId;
        
        @InvocableVariable(label='Flight ID' description='The Flight__c record ID to book' required=true)
        public String flightId;
        
        @InvocableVariable(label='Travel Date' description='Date of travel (YYYY-MM-DD)' required=true)
        public String travelDate;
        
        @InvocableVariable(label='Fare Class' description='Fare class: Economy, Premium Economy, Business, or First' required=true)
        public String fareClass;
        
        @InvocableVariable(label='Checked Bags' description='Number of checked bags')
        public Integer checkedBags;
        
        @InvocableVariable(label='Seat Preference' description='Seat preference (e.g., Window, Aisle)')
        public String seatPreference;
    }

    @InvocableMethod(label='Book Flight' description='Creates a flight booking for the customer')
    public static List<Result> bookFlight(List<Request> requests) {
        List<Result> results = new List<Result>();
        
        for (Request req : requests) {
            results.add(executeBooking(req));
        }
        
        return results;
    }
    
    private static Result executeBooking(Request req) {
        Result r = new Result();

        try {
            // Normalise the fare class up front so price + Booking
            // both use the canonical name. If the agent says "business"
            // we book and price as Choice Extra, not stash an invalid
            // picklist value.
            String canonicalFareClass = Skywave_FareClass.normalize(req.fareClass);
            if (canonicalFareClass == null) {
                r.success = false;
                r.errorMessage = 'Unknown fare class: ' + req.fareClass +
                    '. Use Economy, Premium Economy, Business, or First.';
                return r;
            }

            // Query the flight details
            Flight__c flight = [
                SELECT Id, Name, Flight_Number__c, Origin__c, Destination__c,
                       Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c,
                       Duration_Minutes__c, Aircraft_Type__c,
                       Base_Price_Economy__c, Base_Price_Premium_Economy__c,
                       Base_Price_Business__c, Base_Price_First__c
                FROM Flight__c
                WHERE Id = :req.flightId
                LIMIT 1
            ];

            // Query the contact for loyalty tier
            Contact contact = [
                SELECT Id, Name, Membership_Tier__c
                FROM Contact
                WHERE Id = :req.contactId
                LIMIT 1
            ];

            // Calculate price using the canonical class
            Decimal basePrice = getPriceForFareClass(flight, canonicalFareClass);
            Decimal totalAmount = basePrice;

            // Create the booking
            Booking__c booking = new Booking__c();
            booking.Contact__c = req.contactId;
            booking.Confirmation_Code__c = generateConfirmationCode();
            // Pending until Phase 4 profile creation + payment flip it to Confirmed.
            // The booking is "made" but the ticket is not yet issued.
            booking.Status__c = 'Pending Confirmation';
            booking.Fare_Class__c = canonicalFareClass;
            booking.Total_Amount__c = totalAmount;
            booking.Checked_Bags__c = req.checkedBags != null ? req.checkedBags : 0;
            booking.Booking_Date__c = Date.today();

            insert booking;

            // Parse travel date
            Date travelDateParsed = Date.valueOf(req.travelDate);

            // Calculate departure and arrival DateTimes
            DateTime departureDateTime = DateTime.newInstance(
                travelDateParsed,
                flight.Scheduled_Departure_Time__c
            );

            DateTime arrivalDateTime = DateTime.newInstance(
                travelDateParsed,
                flight.Scheduled_Arrival_Time__c
            );

            // Handle overnight flights
            if (flight.Scheduled_Arrival_Time__c < flight.Scheduled_Departure_Time__c) {
                arrivalDateTime = arrivalDateTime.addDays(1);
            }

            // Create the booking segment
            Booking_Segment__c segment = new Booking_Segment__c();
            segment.Booking__c = booking.Id;
            segment.Flight__c = flight.Id;
            segment.Travel_Date__c = travelDateParsed;
            segment.Departure_DateTime__c = departureDateTime;
            segment.Arrival_DateTime__c = arrivalDateTime;
            segment.Segment_Order__c = 1;
            segment.Segment_Status__c = 'Scheduled';
            segment.Seat_Number__c = assignSeat(req.seatPreference);

            insert segment;

            // Build the response
            r.success = true;
            r.booking = buildBookingResponse(booking, flight, segment, contact);
            
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Booking failed: ' + e.getMessage();
            System.debug('Booking error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        
        return r;
    }
    
    private static Decimal getPriceForFareClass(Flight__c flight, String fareClass) {
        // Caller normalises before invoking — fareClass is canonical.
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
    
    private static String generateConfirmationCode() {
        // Generate a 6-character alphanumeric confirmation code
        String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // Exclude confusing chars like I, O, 1, 0
        String code = '';
        
        for (Integer i = 0; i < 6; i++) {
            Integer randomIndex = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            code += chars.substring(randomIndex, randomIndex + 1);
        }
        
        return code;
    }
    
    private static String assignSeat(String preference) {
        // Simple seat assignment logic - in real system this would check availability
        Integer row = 10 + Math.mod(Math.abs(Crypto.getRandomInteger()), 20); // Rows 10-29
        String seat;
        
        if (preference == 'Window') {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'A' : 'F';
        } else if (preference == 'Aisle') {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'C' : 'D';
        } else {
            // Random seat
            List<String> seats = new List<String>{'A', 'B', 'C', 'D', 'E', 'F'};
            seat = seats[Math.mod(Math.abs(Crypto.getRandomInteger()), seats.size())];
        }
        
        return String.valueOf(row) + seat;
    }
    
    private static Booking buildBookingResponse(
        Booking__c bookingRow,
        Flight__c flight,
        Booking_Segment__c segment,
        Contact contact
    ) {
        Booking b = new Booking();
        b.bookingReference = bookingRow.Confirmation_Code__c;
        b.total = '$' + bookingRow.Total_Amount__c.setScale(2).toPlainString();

        // Set conditions based on fare class
        String canonical = Skywave_FareClass.normalizeOrDefault(bookingRow.Fare_Class__c);
        if (canonical == Skywave_FareClass.ECONOMY) {
            b.rebookingConditions = 'Change fee $99, plus fare difference';
            b.cancellationConditions = 'Cancellation fee $99';
            b.checkedBaggageAllowance = '1 bag (50lbs)';
        } else if (canonical == Skywave_FareClass.PREMIUM_ECONOMY) {
            b.rebookingConditions = 'No change fee, plus fare difference';
            b.cancellationConditions = 'Cancellation fee $99';
            b.checkedBaggageAllowance = '2 bags (50lbs each)';
        } else if (canonical == Skywave_FareClass.BUSINESS) {
            b.rebookingConditions = 'No change fee, plus fare difference';
            b.cancellationConditions = 'Fully refundable';
            b.checkedBaggageAllowance = '2 bags (70lbs each)';
        } else { // First
            b.rebookingConditions = 'No change fee, plus fare difference';
            b.cancellationConditions = 'Fully refundable';
            b.checkedBaggageAllowance = '3 bags (70lbs each)';
        }
        
        // Apply loyalty tier benefits
        if (contact.Membership_Tier__c == 'Elite' || contact.Membership_Tier__c == 'Premier') {
            b.rebookingConditions = 'No change fee, plus fare difference (waived for Elite/Premier)';
            b.cancellationConditions = 'Fully refundable (Elite/Premier benefit)';
            Integer additionalBags = contact.Membership_Tier__c == 'Premier' ? 2 : 1;
            b.checkedBaggageAllowance += ' + ' + additionalBags + ' bonus bag(s)';
        }
        
        b.flights = new List<Flight>();
        
        Flight f = new Flight();
        f.duration = formatDuration(flight.Duration_Minutes__c);
        f.originDateTime = formatDateTime(segment.Departure_DateTime__c);
        f.destinationDateTime = formatDateTime(segment.Arrival_DateTime__c);
        f.originCity = getAirportCity(flight.Origin__c);
        f.destinationCity = getAirportCity(flight.Destination__c);
        f.bookingClass = bookingRow.Fare_Class__c;
        f.numberOfFlights = 1;
        f.segments = new List<Segment>();
        
        Segment s = new Segment();
        s.segmentType = 'flight';
        s.duration = formatDuration(flight.Duration_Minutes__c);
        s.flightNumber = flight.Flight_Number__c;
        s.departureDateTime = formatDateTime(segment.Departure_DateTime__c);
        s.departureCity = getAirportCity(flight.Origin__c);
        s.departureAirport = getAirportName(flight.Origin__c);
        s.departureAirportCode = flight.Origin__c;
        s.arrivalDateTime = formatDateTime(segment.Arrival_DateTime__c);
        s.arrivalCity = getAirportCity(flight.Destination__c);
        s.arrivalAirport = getAirportName(flight.Destination__c);
        s.arrivalAirportCode = flight.Destination__c;
        s.bookingClass = bookingRow.Fare_Class__c;
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