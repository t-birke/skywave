public class Skywave_GetMileageBalance {

    public class Request {
        @InvocableVariable(label='Contact ID' description='The contact ID for the customer whose mileage balance is being requested')
        public String contactId;
    }

    @InvocableMethod(label='Get Mileage Balance' description='Returns the customer\'s loyalty miles / tier points balance. Demo stub: returns a random value between 10,000 and 230,000.')
    public static List<Result> getMileageBalance(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result r = new Result();
            Integer balance = 10000 + Math.mod(Math.abs(Crypto.getRandomInteger()), 220001);
            r.success = true;
            r.milesBalance = balance;
            r.confirmationMessage = 'Your current mileage balance is ' + balance + ' miles.';
            results.add(r);
        }

        return results;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='miles balance' description='the customer\'s current mileage / tier points balance')
        public Integer milesBalance;
        @InvocableVariable(label='confirmation message' description='human-readable summary of the mileage balance')
        public String confirmationMessage;
    }
}
