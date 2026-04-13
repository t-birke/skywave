public class Skywave_FlightUpcoming {

    @InvocableMethod(label='Check for Upcoming Flights' description='Checks if the user has flights within the next 72 hours')
    public static List<Result> getImminentFlights(List<String> userId) {
        List<Result> results = new List<Result>();
        Result r = new Result();
        r.success = true;
        r.imminentFlights = 2;
        results.add(r);
        return results;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='imminent flights' description='flights within the next 72 hours')
        public Integer imminentFlights;
    }
}
