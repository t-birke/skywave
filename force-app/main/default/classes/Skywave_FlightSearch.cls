public with sharing class Skywave_FlightSearch {

    public class FlightRequest {
        @InvocableVariable(label='Origin Airport Code (IATA)' required=true)
        public String origin;

        @InvocableVariable(label='Destination Airport Code (IATA)' required=true)
        public String destination;

        @InvocableVariable(label='Departure Date (YYYY-MM-DD)' required=true)
        public String departureDate;
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
    }

    @InvocableMethod(label='Search Flights' description='Searches available flight itineraries')
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

        String apiKey = '0fbb1035b31c1777c0183587f1130e1e479685ebf2dcca9e32314f012da53090';
        String endpoint = 'https://serpapi.com/search.json?engine=google_flights' +
                          '&departure_id=' + req.origin +
                          '&arrival_id=' + req.destination +
                          '&outbound_date=' + req.departureDate +
                          '&currency=USD' +
                          '&gl=us' +
                          '&hl=en' +
                          '&type=2' +
                          '&api_key=' + apiKey;

        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');

        try {
            HttpResponse response = http.send(request);
            if (response.getStatusCode() == 200) {
                Map<String, Object> results = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
                List<Object> bestFlights = (List<Object>) results.get('best_flights');

                if (bestFlights == null) {
                    bestFlights = (List<Object>) results.get('other_flights');
                }

                if (bestFlights != null) {
                    for (Integer i = 0; i < Math.min(3, bestFlights.size()); i++) {
                        Map<String, Object> flightData = (Map<String, Object>) bestFlights[i];
                        res.options.add(parseFlight(flightData));
                    }
                }
            }
        } catch (Exception e) {
            System.debug('Error calling Flight API: ' + e.getMessage());
        }

        return res;
    }

    private static FlightOption parseFlight(Map<String, Object> data) {
        FlightOption opt = new FlightOption();
        List<Object> flights = (List<Object>) data.get('flights');

        opt.price = String.valueOf(data.get('price'));
        opt.duration = (Integer) data.get('total_duration');
        opt.numberOfFlights = flights.size();

        List<String> flightNums = new List<String>();
        List<String> aircrafts = new List<String>();
        List<String> stops = new List<String>();

        for (Integer j = 0; j < flights.size(); j++) {
            Map<String, Object> leg = (Map<String, Object>) flights[j];

            if (j == 0) {
                Map<String, Object> dep = (Map<String, Object>) leg.get('departure_airport');
                opt.startingAirport = (String) dep.get('id');
            }
            if (j == flights.size() - 1) {
                Map<String, Object> arr = (Map<String, Object>) leg.get('arrival_airport');
                opt.arrivingAirport = (String) arr.get('id');
            }

            flightNums.add((String) leg.get('flight_number'));
            aircrafts.add((String) leg.get('airplane'));

            if (j < flights.size() - 1) {
                Map<String, Object> arrLeg = (Map<String, Object>) leg.get('arrival_airport');
                stops.add((String) arrLeg.get('id'));
            }
        }

        opt.flightNumber = String.join(flightNums, ' / ');
        opt.aircraft = String.join(aircrafts, ' / ');
        opt.stopovers = stops.isEmpty() ? 'Non-stop' : String.join(stops, ', ');

        return opt;
    }
}
