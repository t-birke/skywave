public class Skywave_ChangeName {

    public class Request {
        @InvocableVariable(label='Booking Reference' description='The booking reference (confirmation code) for the booking to update' required=true)
        public String bookingReference;

        @InvocableVariable(label='First Name' description='The corrected first name for the traveler' required=true)
        public String firstName;

        @InvocableVariable(label='Last Name' description='The corrected last name for the traveler' required=true)
        public String lastName;

        @InvocableVariable(label='Contact ID' description='The contact ID associated with the booking')
        public String contactId;
    }

    @InvocableMethod(label='Change Name on Booking' description='Updates the traveler name on a booking. Demo stub: returns a confirmation without mutating records.')
    public static List<Result> changeName(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result r = new Result();

            if (String.isBlank(req.bookingReference) || String.isBlank(req.firstName) || String.isBlank(req.lastName)) {
                r.success = false;
                r.errorMessage = 'bookingReference, firstName, and lastName are all required';
                results.add(r);
                continue;
            }

            r.success = true;
            r.bookingReference = req.bookingReference;
            r.updatedFirstName = req.firstName;
            r.updatedLastName = req.lastName;
            r.confirmationMessage = 'Name on booking ' + req.bookingReference
                + ' has been updated to ' + req.firstName + ' ' + req.lastName + '. No change fee applied.';
            results.add(r);
        }

        return results;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='booking reference' description='the booking reference that was updated')
        public String bookingReference;
        @InvocableVariable(label='updated first name' description='the new first name on the booking')
        public String updatedFirstName;
        @InvocableVariable(label='updated last name' description='the new last name on the booking')
        public String updatedLastName;
        @InvocableVariable(label='confirmation message' description='human-readable confirmation of the name change')
        public String confirmationMessage;
    }
}
