/**
 * Validate payment-method choice. No DB writes.
 *
 * Phase 3.5b moves all DB writes into Skywave_ConfirmBooking. This
 * action's only job is now to validate the visitor's chosen payment
 * method (one of three accepted strings) so the agent knows whether
 * to advance to confirm. The agent pins the method into
 * @variables.selected_payment_method; Skywave_ConfirmBooking
 * stamps the value onto the Booking__c at insert.
 *
 * Three named methods are accepted: Apple Pay, Saved card, Demo card.
 * Demo only — no real charge ever happens.
 */
public with sharing class Skywave_ProcessPayment {

    private static final Set<String> ALLOWED_METHODS = new Set<String>{
        'Apple Pay', 'Saved card', 'Demo card'
    };

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(
            label='Payment Method'
            description='Apple Pay, Saved card, or Demo card'
            required=true
        )
        public String paymentMethod;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='error message')
        public String errorMessage;

        @InvocableVariable(label='Payment method used')
        public String paymentMethod;
    }

    @InvocableMethod(
        label='Skywave: Process payment'
        description='Validates the visitor payment-method choice. No DB write — Skywave_ConfirmBooking stamps the method onto the booking at insert. Demo only.'
        category='Skywave'
    )
    public static List<Output> processPayments(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) {
            outs.add(processOne(req));
        }
        return outs;
    }

    private static Output processOne(Input req) {
        Output out = new Output();
        out.success = false;

        if (String.isBlank(req.contactId)) {
            out.errorMessage = 'Contact Id is required.';
            return out;
        }
        String method = req.paymentMethod == null ? '' : req.paymentMethod.trim();
        if (!ALLOWED_METHODS.contains(method)) {
            out.errorMessage = 'Unknown payment method: ' + method +
                '. Use Apple Pay, Saved card, or Demo card.';
            return out;
        }
        out.paymentMethod = method;
        out.success = true;
        return out;
    }
}
