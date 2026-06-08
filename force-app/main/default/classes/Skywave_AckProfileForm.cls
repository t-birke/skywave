/**
 * Profile-saved acknowledgement + Booking__c insert.
 *
 * Phase 3.5b-r2 moved booking creation here. The visitor's profile is
 * the gate: as soon as we have a real Contact identity, we create the
 * Booking__c so it's live with status `Pending Confirmation` /
 * payment_status `Unpaid`. The CLT 4 payment widget then flips both
 * fields to `Confirmed` / `Paid` once Demo Pay completes.
 *
 * Why insert here (not in confirm_booking): the payment widget is
 * client-side and needs a real bookingCode + amount BEFORE it animates.
 * Inserting at the profile gate gives the agent something to pass to
 * present_payment_form; abandoned-after-profile sessions leave a
 * single Pending/Unpaid row that's easy to filter.
 *
 * Inputs: contactId + the pinned selection variables. Reads the
 * Flight__c row, computes the total, inserts Booking__c +
 * Booking_Segment__c.
 *
 * Outputs: bookingCode + totalCharged for the agent to pin and pass
 * to the payment widget.
 */
public with sharing class Skywave_AckProfileForm {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Flight Id' required=true)
        public String flightId;

        @InvocableVariable(label='Travel Date (YYYY-MM-DD)' required=true)
        public String travelDate;

        @InvocableVariable(label='Fare Class' required=true)
        public String fareClass;

        @InvocableVariable(label='Checked Bags')
        public Integer checkedBags;

        @InvocableVariable(label='Seat Preference')
        public String seatPreference;
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
    }

    @InvocableMethod(
        label='Skywave: Acknowledge profile + create booking'
        description='Invoke when the visitor sends "Profile created" (cue from the form LWC) OR when the visitor has provided full name + email via text fallback. Inserts the Pending/Unpaid Booking__c using pinned selection variables and returns the booking code + total amount, which the agent passes to the payment widget.'
        category='Skywave'
    )
    public static List<Output> ack(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(ackOne(req));
        return outs;
    }

    private static Output ackOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.bookingCode = '';
        out.totalCharged = '$0.00';

        if (String.isBlank(req.contactId)) {
            out.message = 'Contact Id is required.';
            return out;
        }
        if (String.isBlank(req.flightId)) {
            out.message = 'Flight selection lost — flightId missing.';
            return out;
        }
        if (String.isBlank(req.travelDate)) {
            out.message = 'Travel date missing.';
            return out;
        }
        if (String.isBlank(req.fareClass)) {
            out.message = 'Fare class missing.';
            return out;
        }

        Date travelDateParsed;
        try {
            travelDateParsed = Date.valueOf(req.travelDate);
        } catch (Exception e) {
            out.message = 'Travel date must be YYYY-MM-DD; got "' + req.travelDate + '".';
            return out;
        }

        // Delegate the actual booking insert to Skywave_BookingEngine —
        // single source of truth shared with the website's create path.
        // Chat-specific bit: we want a Pending/Unpaid booking so the
        // payment-widget LWC can flip it to Confirmed/Paid afterward.
        Skywave_BookingEngine.CreateRequest engineReq = new Skywave_BookingEngine.CreateRequest();
        engineReq.contactId = req.contactId;
        engineReq.flightKey = req.flightId.trim();
        engineReq.travelDate = travelDateParsed;
        engineReq.fareClass = req.fareClass;
        engineReq.checkedBags = req.checkedBags != null ? req.checkedBags : 0;
        engineReq.seatPreference = req.seatPreference;
        engineReq.initialStatus = 'Pending Confirmation';
        engineReq.initialPaymentStatus = 'Unpaid';

        Skywave_BookingEngine.CreateResult r = Skywave_BookingEngine.createBooking(engineReq);
        if (!r.success) {
            out.message = String.isNotBlank(r.errorMessage)
                ? 'Booking creation failed: ' + r.errorMessage
                : 'Booking creation failed: ' + r.errorCode;
            return out;
        }
        out.success = true;
        out.bookingCode = r.bookingCode;
        out.totalCharged = r.totalDisplay;
        out.message = 'Booking created (Pending/Unpaid), ' + r.segmentCount + ' segment(s).';
        return out;
    }

    // assignSeat / generateConfirmationCode / publishFlightBookedEvent
    // moved to Skywave_BookingEngine. This class is now a pure Invocable
    // shim for the chat agent's "Profile created" cue.
}
