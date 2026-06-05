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
        @InvocableVariable(label='Flight Search Result Card' description='Structured payload for the Skywave Flight Search Result LWC renderer.')
        public Skywave_FlightSearchResultData flightResult;

        @InvocableVariable(label='Flight Options Narrative' description='Plain-text narrative the LLM uses to comment on the search results alongside the card.')
        public String flightSummary;

        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Message')
        public String message;
    }

    public class FlightOption {
        public String startingAirport;
        public String arrivingAirport;
        public Integer duration;
        public Integer numberOfFlights;
        public String stopovers;
        public String aircraft;
        public String flightNumber;
        public String price;
        public String flightId;
        public String departureTime;
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
        try {
            List<FlightOption> options = queryFlights(req);
            res.flightResult = new Skywave_FlightSearchResultData(buildFlightsJSON(options, req.fareClass));
            res.flightSummary = buildNarrative(req, options);
            res.success = true;
            res.message = options.isEmpty()
                ? 'No flights matched.'
                : options.size() + ' flight options returned.';
        } catch (Exception e) {
            System.debug('Error querying Flight__c: ' + e.getMessage());
            res.flightResult = new Skywave_FlightSearchResultData(
                '{"error":"' + e.getMessage().replace('"','\\"') + '"}'
            );
            res.flightSummary = 'I could not load flights right now.';
            res.success = false;
            res.message = 'Error: ' + e.getMessage();
        }
        return res;
    }

    private static List<FlightOption> queryFlights(FlightRequest req) {
        Date travelDate = Date.valueOf(req.departureDate);
        String dayOfWeek = getDayOfWeekField(travelDate);

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

        List<Flight__c> flights = Database.query(query);
        List<FlightOption> options = new List<FlightOption>();

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

            DateTime departureDateTime = calculateDateTime(travelDate, flight.Scheduled_Departure_Time__c);
            DateTime arrivalDateTime = calculateDateTime(travelDate, flight.Scheduled_Arrival_Time__c);
            if (flight.Scheduled_Arrival_Time__c < flight.Scheduled_Departure_Time__c) {
                arrivalDateTime = arrivalDateTime.addDays(1);
            }
            opt.departureTime = departureDateTime.format('h:mm a');
            opt.arrivalTime = arrivalDateTime.format('h:mm a');

            opt.price = getPriceForFareClass(flight, req.fareClass);
            options.add(opt);
        }

        // No direct flight on this O&D? Skywave is a JFK hub carrier — try a
        // single connection origin -> JFK -> destination and present it as
        // ONE option with a compound flight key (e.g. SW3001+SW4017). The
        // card and booking pipeline thread the compound key through unchanged.
        if (options.isEmpty() && req.origin != Skywave_Itinerary.HUB
                && req.destination != Skywave_Itinerary.HUB) {
            Skywave_Itinerary.Resolved conn =
                Skywave_Itinerary.findConnection(req.origin, req.destination, req.fareClass, travelDate);
            if (conn != null && conn.isConnection) {
                Skywave_Itinerary.Leg first = conn.legs[0];
                Skywave_Itinerary.Leg last = conn.legs[conn.legs.size() - 1];

                FlightOption opt = new FlightOption();
                opt.flightId = null; // compound — no single Flight__c Id
                opt.startingAirport = first.flight.Origin__c;
                opt.arrivingAirport = last.flight.Destination__c;
                opt.duration = conn.totalDurationMinutes();
                opt.numberOfFlights = conn.legs.size();
                opt.stopovers = '1 stop · ' + first.flight.Destination__c;
                opt.aircraft = first.flight.Aircraft_Type__c;
                opt.flightNumber = conn.compoundKey();
                opt.departureTime = first.departure.format('h:mm a');
                opt.arrivalTime = last.arrival.format('h:mm a');
                opt.price = '$' + conn.totalPrice().setScale(2).toPlainString();
                options.add(opt);
            }
        }
        return options;
    }

    private static String buildFlightsJSON(List<FlightOption> options, String fareClass) {
        String canonical = Skywave_FareClass.normalizeOrDefault(fareClass);
        List<Map<String, Object>> items = new List<Map<String, Object>>();
        for (FlightOption opt : options) {
            items.add(new Map<String, Object>{
                'flightId' => opt.flightId,
                'flightNumber' => opt.flightNumber,
                'startingAirport' => opt.startingAirport,
                'arrivingAirport' => opt.arrivingAirport,
                'departureTime' => opt.departureTime,
                'arrivalTime' => opt.arrivalTime,
                'duration' => opt.duration,
                'stopovers' => opt.stopovers,
                'aircraft' => opt.aircraft,
                'price' => opt.price,
                'fareClass' => canonical
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'flights' => items,
            'fareClass' => canonical
        });
    }

    private static String buildNarrative(FlightRequest req, List<FlightOption> options) {
        if (options.isEmpty()) {
            return 'No flights match ' + req.origin + ' to ' + req.destination + ' on ' + req.departureDate + '.';
        }
        return 'Found ' + options.size() + ' flight option(s) from ' + req.origin + ' to ' + req.destination + ' on ' + req.departureDate + '.';
    }

    private static String getDayOfWeekField(Date travelDate) {
        DateTime dt = DateTime.newInstance(travelDate, Time.newInstance(0, 0, 0, 0));
        String dayName = dt.format('EEEE');
        return 'Operates_' + dayName + '__c';
    }

    private static DateTime calculateDateTime(Date travelDate, Time scheduleTime) {
        if (scheduleTime == null) {
            return DateTime.newInstance(travelDate, Time.newInstance(0, 0, 0, 0));
        }
        return DateTime.newInstance(travelDate, scheduleTime);
    }

    private static String getPriceForFareClass(Flight__c flight, String fareClass) {
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
