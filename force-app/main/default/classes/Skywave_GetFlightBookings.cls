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
            
            try {
                if (String.isBlank(req.contactId)) {
                    r.success = false;
                    r.errorMessage = 'Contact ID is required';
                    r.bookings = new List<Booking>();
                    results.add(r);
                    continue;
                }
                
                // Query active reservations for this contact
                List<Reservation__c> reservations = [
                    SELECT Id, Name, Confirmation_Code__c, Total_Amount__c, 
                           Fare_Class__c, Status__c, Checked_Bags__c,
                           (SELECT Id, Flight__c, Flight__r.Flight_Number__c, 
                                   Flight__r.Origin__c, Flight__r.Destination__c,
                                   Flight__r.Aircraft_Type__c, Flight__r.Duration_Minutes__c,
                                   Travel_Date__c, Departure_DateTime__c, Arrival_DateTime__c,
                                   Seat_Number__c, Segment_Order__c, Segment_Status__c
                            FROM Reservation_Segments__r
                            WHERE Segment_Status__c != 'Cancelled'
                            ORDER BY Segment_Order__c)
                    FROM Reservation__c
                    WHERE Contact__c = :req.contactId
                      AND Status__c = 'Confirmed'
                      AND Id IN (SELECT Reservation__c 
                                FROM Reservation_Segment__c 
                                WHERE Departure_DateTime__c >= :DateTime.now())
                ];
                
                r.bookings = new List<Booking>();
                
                for (Reservation__c reservation : reservations) {
                    Booking b = new Booking();
                    b.bookingReference = reservation.Confirmation_Code__c;
                    b.total = '$' + reservation.Total_Amount__c.setScale(0).format();
                    
                    // Set rebooking/cancellation conditions based on fare class
                    if (reservation.Fare_Class__c == 'Basic') {
                        b.rebookingConditions = 'change fee $75, plus fare difference';
                        b.cancellationConditions = 'non-refundable';
                    } else if (reservation.Fare_Class__c == 'Choice') {
                        b.rebookingConditions = 'allowed, plus fare difference';
                        b.cancellationConditions = 'fully refundable';
                    } else {
                        b.rebookingConditions = 'free changes, plus fare difference';
                        b.cancellationConditions = 'fully refundable';
                    }
                    
                    Integer bagCount = reservation.Checked_Bags__c != null ? 
                                      reservation.Checked_Bags__c.intValue() : 0;
                    b.checkedBaggageAllowance = bagCount + ' (50lbs each)';
                    
                    b.flights = new List<Flight>();
                    
                    // Group segments by travel date (for multi-city trips)
                    Flight currentFlight = null;
                    Date currentDate = null;
                    
                    for (Reservation_Segment__c segment : reservation.Reservation_Segments__r) {
                        if (currentDate == null || currentDate != segment.Travel_Date__c) {
                            if (currentFlight != null) {
                                b.flights.add(currentFlight);
                            }
                            
                            currentFlight = new Flight();
                            currentFlight.segments = new List<Segment>();
                            currentFlight.numberOfFlights = 0;
                            currentDate = segment.Travel_Date__c;
                        }
                        
                        Segment s = new Segment();
                        s.segmentType = 'flight';
                        s.flightNumber = segment.Flight__r.Flight_Number__c;
                        s.departureDateTime = segment.Departure_DateTime__c.format('EEEE, MMMM d, yyyy h:mm a zzz');
                        s.arrivalDateTime = segment.Arrival_DateTime__c.format('EEEE, MMMM d, yyyy h:mm a zzz');
                        s.departureAirportCode = segment.Flight__r.Origin__c;
                        s.arrivalAirportCode = segment.Flight__r.Destination__c;
                        s.departureCity = getAirportCity(segment.Flight__r.Origin__c);
                        s.arrivalCity = getAirportCity(segment.Flight__r.Destination__c);
                        s.departureAirport = getAirportName(segment.Flight__r.Origin__c);
                        s.arrivalAirport = getAirportName(segment.Flight__r.Destination__c);
                        s.bookingClass = reservation.Fare_Class__c;
                        s.operatingAircraft = segment.Flight__r.Aircraft_Type__c;
                        s.operatingAirline = 'Skywave Airlines';
                        
                        Long durationMinutes = segment.Flight__r.Duration_Minutes__c != null ? 
                                              segment.Flight__r.Duration_Minutes__c.longValue() : 0;
                        s.duration = formatDuration(durationMinutes);
                        
                        currentFlight.segments.add(s);
                        currentFlight.numberOfFlights++;
                        
                        // Set flight-level properties from first segment
                        if (currentFlight.segments.size() == 1) {
                            currentFlight.originDateTime = s.departureDateTime;
                            currentFlight.originCity = s.departureCity;
                            currentFlight.bookingClass = s.bookingClass;
                        }
                        
                        // Always update to last segment
                        currentFlight.destinationDateTime = s.arrivalDateTime;
                        currentFlight.destinationCity = s.arrivalCity;
                        currentFlight.duration = calculateTotalDuration(currentFlight.segments);
                    }
                    
                    if (currentFlight != null) {
                        b.flights.add(currentFlight);
                    }
                    
                    r.bookings.add(b);
                }
                
                r.success = true;
                
            } catch (Exception e) {
                r.success = false;
                r.errorMessage = 'Error retrieving bookings: ' + e.getMessage();
                r.bookings = new List<Booking>();
            }
            
            results.add(r);
        }
        
        return results;
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