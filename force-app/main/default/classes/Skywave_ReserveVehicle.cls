/**
 * Reserve-vehicle action — the rental analogue of Skywave_AckProfileForm.
 *
 * Invoked when the visitor taps a tier's Reserve button on the rental
 * offer card (which posts "Rent <category> for <N> days" to chat). Creates
 * a Pending/Unpaid Vehicle_Booking__c from the chosen category + day count
 * and the destination/pickup/flight context the router pinned, then returns
 * the booking code + total so the agent can hand them to the payment card.
 *
 * Profile is intentionally NOT collected here: the rental option only ever
 * appears after the visitor has booked a flight, so their Contact profile
 * is already complete. Payment then flips the record to Paid/Confirmed via
 * Skywave_ProcessRentalPayment (LWC-invoked), mirroring the flight flow.
 */
public with sharing class Skywave_ReserveVehicle {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Vehicle Category' required=true)
        public String category;

        @InvocableVariable(label='Rental Days' required=true)
        public Integer rentalDays;

        @InvocableVariable(label='Pickup Date (YYYY-MM-DD)' required=false)
        public String pickupDate;

        @InvocableVariable(label='Destination' required=false)
        public String destination;

        @InvocableVariable(label='Flight Booking Code' required=false)
        public String flightBookingCode;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;

        @InvocableVariable(label='Booking code')
        public String bookingCode;

        @InvocableVariable(label='Total charged')
        public String totalCharged;

        @InvocableVariable(label='Vehicle category')
        public String category;

        @InvocableVariable(label='Example model')
        public String exampleModel;

        @InvocableVariable(label='Rental days')
        public Integer rentalDays;
    }

    @InvocableMethod(
        label='Skywave: Reserve vehicle + create rental'
        description='Invoke when the visitor taps Reserve on the rental card ("Rent <category> for <N> days"). Inserts the Pending/Unpaid Vehicle_Booking__c and returns the rental code + total, which the agent passes to the rental payment card.'
        category='Skywave'
    )
    public static List<Output> reserve(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(reserveOne(req));
        return outs;
    }

    private static Output reserveOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.bookingCode = '';
        out.totalCharged = '$0.00';

        if (String.isBlank(req.contactId)) {
            out.message = 'Contact Id is required.';
            return out;
        }
        if (String.isBlank(req.category)) {
            out.message = 'Vehicle category is required.';
            return out;
        }

        Date pickup = null;
        if (String.isNotBlank(req.pickupDate)) {
            try {
                pickup = Date.valueOf(req.pickupDate);
            } catch (Exception e) {
                out.message = 'Pickup date must be YYYY-MM-DD; got "' + req.pickupDate + '".';
                return out;
            }
        }

        Skywave_RentalEngine.CreateRequest engineReq = new Skywave_RentalEngine.CreateRequest();
        engineReq.contactId = req.contactId;
        engineReq.category = req.category;
        engineReq.rentalDays = req.rentalDays;
        engineReq.pickupDate = pickup;
        engineReq.destination = req.destination;
        engineReq.flightBookingCode = req.flightBookingCode;
        engineReq.initialStatus = 'Pending Confirmation';
        engineReq.initialPaymentStatus = 'Unpaid';

        Skywave_RentalEngine.CreateResult r = Skywave_RentalEngine.createBooking(engineReq);
        if (!r.success) {
            out.message = String.isNotBlank(r.errorMessage)
                ? 'Rental reservation failed: ' + r.errorMessage
                : 'Rental reservation failed: ' + r.errorCode;
            return out;
        }

        out.success = true;
        out.bookingCode = r.bookingCode;
        out.totalCharged = r.totalDisplay;
        out.category = r.category;
        out.exampleModel = r.exampleModel;
        out.rentalDays = r.rentalDays;
        out.message = 'Rental reserved (Pending/Unpaid): ' + r.category + ', ' + r.rentalDays + ' day(s).';
        return out;
    }
}
