public with sharing class Skywave_FlightSearch {

    public class FlightRequest {
        @InvocableVariable(label='Origin Airport Code (IATA)' required=true)
        public String origin;

        @InvocableVariable(label='Destination Airport Code (IATA)' required=true)
        public String destination;

        @InvocableVariable(label='Departure Date (YYYY-MM-DD)' required=true)
        public String departureDate;
        
        @InvocableVariable(label='Fare Class (Economy/Premium Economy/Business/First)')
        public String fareClass;
    }

    public class FlightResponse {
        @InvocableVariable(label='Flight Options')
        public List<FlightOption> options;
    }

    public class FlightOption {
        @InvocableVariable(label='Starting Airport')
        public String startingAirport;

        @InvocableVariable(label='Arriving Airport')
        public String arrivingAirport;

        @InvocableVariable(label='Total Duration (min)')
        public Integer duration;

        @InvocableVariable(label='Number of Legs')
        public Integer numberOfFlights;

        @InvocableVariable(label='Stopover Locations')
        public String stopovers;

        @InvocableVariable(label='Aircraft Type')
        public String aircraft;

        @InvocableVariable(label='Flight Number(s)')
        public String flightNumber;

        @InvocableVariable(label='Price')
        public String price;
        
        @InvocableVariable(label='Flight Record ID')
        public String flightId;
        
        @InvocableVariable(label='Departure Time')
        public String departureTime;
        
        @InvocableVariable(label='Arrival Time')
        public String arrivalTime;
    }

    @InvocableMethod(label='Search Flights' description='Searches available flight itineraries from master schedule')
    public static List<FlightResponse> searchFlights(List<FlightRequest> requests) {
        List<FlightResponse> allResponses = new List<FlightResponse>();
        for (FlightRequest req : requests) {
            allResponses.add(executeSearch(req));
        }
        return allResponses;
    }

    private static FlightResponse executeSearch(FlightRequest req) {
        FlightResponse res = new FlightResponse();
        res.options = new List<FlightOption>();
        
        // Parse the departure date to determine day of week
        Date travelDate = Date.valueOf(req.departureDate);
        String dayOfWeek = getDayOfWeekField(travelDate);
        
        // Build dynamic SOQL query based on day of week
        String query = 'SELECT Id, Name, Flight_Number__c, Origin__c, Destination__c, ' +
                      'Scheduled_Departure_Time__c, Scheduled_Arrival_Time__c, ' +
                      'Duration_Minutes__c, Aircraft_Type__c, ' +
                      'Base_Price_Economy__c, Base_Price_Premium_Economy__c, ' +
                      'Base_Price_Business__c, Base_Price_First__c ' +
                      'FROM Flight__c ' +
                      'WHERE Active__c = true ' +
                      'AND Origin__c = :origin ' +
                      'AND Destination__c = :destination ' +
                      'AND ' + dayOfWeek + ' = true ' +
                      'ORDER BY Scheduled_Departure_Time__c ' +
                      'LIMIT 10';
        
        String origin = req.origin;
        String destination = req.destination;
        
        try {
            List<Flight__c> flights = Database.query(query);
            
            for (Flight__c flight : flights) {
                FlightOption opt = new FlightOption();
                opt.flightId = flight.Id;
                opt.startingAirport = flight.Origin__c;
                opt.arrivingAirport = flight.Destination__c;
                opt.duration = flight.Duration_Minutes__c != null ? Integer.valueOf(flight.Duration_Minutes__c) : 0;
                opt.numberOfFlights = 1;
                opt.stopovers = 'Non-stop';
                opt.aircraft = flight.Aircraft_Type__c;
                opt.flightNumber = flight.Flight_Number__c;
                
                // Calculate departure and arrival times for the specific travel date
                DateTime departureDateTime = calculateDateTime(travelDate, flight.Scheduled_Departure_Time__c);
                DateTime arrivalDateTime = calculateDateTime(travelDate, flight.Scheduled_Arrival_Time__c);
                
                // Handle flights that arrive next day
                if (flight.Scheduled_Arrival_Time__c < flight.Scheduled_Departure_Time__c) {
                    arrivalDateTime = arrivalDateTime.addDays(1);
                }
                
                opt.departureTime = departureDateTime.format('h:mm a');
                opt.arrivalTime = arrivalDateTime.format('h:mm a');
                
                // Set price based on fare class
                opt.price = getPriceForFareClass(flight, req.fareClass);
                
                res.options.add(opt);
            }
        } catch (Exception e) {
            System.debug('Error querying Flight__c: ' + e.getMessage());
        }
        
        return res;
    }
    
    /**
     * Returns the API field name for the day of week checkbox field
     */
    private static String getDayOfWeekField(Date travelDate) {
        DateTime dt = DateTime.newInstance(travelDate, Time.newInstance(0, 0, 0, 0));
        String dayName = dt.format('EEEE'); // Returns full day name like "Monday"
        
        return 'Operates_' + dayName + '__c';
    }
    
    /**
     * Combines a date with a time-only value to create a DateTime
     */
    private static DateTime calculateDateTime(Date travelDate, Time scheduleTime) {
        if (scheduleTime == null) {
            return DateTime.newInstance(travelDate, Time.newInstance(0, 0, 0, 0));
        }
        return DateTime.newInstance(travelDate, scheduleTime);
    }
    
    /**
     * Returns the formatted price string based on fare class
     */
    private static String getPriceForFareClass(Flight__c flight, String fareClass) {
        // Normalise loose names ("business", "economy") onto the
        // canonical Choice/Choice Extra/Basic the org understands.
        // Falls back to Choice when the agent didn't specify a class.
        String canonical = Skywave_FareClass.normalizeOrDefault(fareClass);
        Decimal price = 0;

        if (canonical == Skywave_FareClass.ECONOMY && flight.Base_Price_Economy__c != null) {
            price = flight.Base_Price_Economy__c;
        } else if (canonical == Skywave_FareClass.PREMIUM_ECONOMY && flight.Base_Price_Premium_Economy__c != null) {
            price = flight.Base_Price_Premium_Economy__c;
        } else if (canonical == Skywave_FareClass.BUSINESS && flight.Base_Price_Business__c != null) {
            price = flight.Base_Price_Business__c;
        } else if (canonical == Skywave_FareClass.FIRST && flight.Base_Price_First__c != null) {
            price = flight.Base_Price_First__c;
        } else if (flight.Base_Price_Economy__c != null) {
            price = flight.Base_Price_Economy__c;
        }

        return '$' + price.setScale(2).toPlainString();
    }
}
