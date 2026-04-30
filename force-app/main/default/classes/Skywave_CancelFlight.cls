public class Skywave_CancelFlight {

    public class Request {
        @InvocableVariable(label='Booking Reference' description='The booking reference to cancel' required=true)
        public String bookingReference;
        @InvocableVariable(label='Contact Id' description='The contact ID for the booking' required=false)
        public String contactId;
    }

    @InvocableMethod(label='Cancel Flight Booking' description='Cancels a flight booking and processes the refund')
    public static List<Result> cancel(List<Request> requests) {
        List<Result> results = new List<Result>();

        for (Request req : requests) {
            Result r = new Result();

            if (String.isBlank(req.bookingReference)) {
                r.success = false;
                r.errorMessage = 'Booking reference is required';
                results.add(r);
                continue;
            }

            // Demo: hardcoded refund handling per booking. In production this
            // would update the Reservation record and trigger a refund flow.
            r.success = true;
            r.bookingReference = req.bookingReference;
            r.refundMethod = 'original payment method';

            if (req.bookingReference == 'SW-LV2401') {
                r.cancellationFee = '$200';
                r.refundAmount = '$189';
                r.confirmationMessage = 'Booking SW-LV2401 (JFK to LAS) has been cancelled. '
                    + 'A refund of $189 will be issued to the original payment method '
                    + '(after the $200 cancellation fee).';
            } else if (req.bookingReference == 'SW-SF8825') {
                r.cancellationFee = '$0';
                r.refundAmount = '$642';
                r.confirmationMessage = 'Booking SW-SF8825 (JFK to SFO return) has been cancelled. '
                    + 'A full refund of $642 will be issued to the original payment method.';
            } else {
                r.cancellationFee = '$0';
                r.refundAmount = '';
                r.confirmationMessage = 'Booking ' + req.bookingReference
                    + ' has been cancelled. A refund will be issued to the original payment method.';
            }

            results.add(r);
        }

        return results;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the cancellation was processed')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='booking reference' description='the cancelled booking reference')
        public String bookingReference;
        @InvocableVariable(label='cancellation fee' description='the fee applied for cancelling the booking')
        public String cancellationFee;
        @InvocableVariable(label='refund amount' description='the amount refunded to the customer')
        public String refundAmount;
        @InvocableVariable(label='refund method' description='where the refund will be issued')
        public String refundMethod;
        @InvocableVariable(label='confirmation message' description='human-readable confirmation of the cancellation')
        public String confirmationMessage;
    }
}
