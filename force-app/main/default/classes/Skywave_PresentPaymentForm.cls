/**
 * Invocable that returns a renderable Skywave_PaymentFormData payload.
 *
 * The agent calls this once when booking_step transitions to "payment"
 * to display the payment-picker card in chat. Pre-fills with the
 * booking code + total amount the agent pinned from ack_profile_form.
 *
 * No DML — pure read + serialize.
 */
public with sharing class Skywave_PresentPaymentForm {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Booking Code' required=true)
        public String bookingCode;

        @InvocableVariable(label='Total amount (e.g. $1430.00)' required=true)
        public String totalCharged;
    }

    public class Output {
        @InvocableVariable(label='Form Data')
        public Skywave_PaymentFormData formData;

        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;
    }

    @InvocableMethod(
        label='Skywave: Present payment picker'
        description='Returns the SkywavePaymentForm renderable DTO so the agent can show the payment-picker card. Pre-fills with bookingCode and totalCharged.'
        category='Skywave'
    )
    public static List<Output> present(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(presentOne(req));
        return outs;
    }

    private static Output presentOne(Input req) {
        Output out = new Output();
        out.success = false;

        if (String.isBlank(req.bookingCode)) {
            out.message = 'Booking code is required.';
            out.formData = new Skywave_PaymentFormData('{}');
            return out;
        }

        Map<String, Object> state = new Map<String, Object>{
            'contactId' => req.contactId == null ? '' : req.contactId,
            'bookingCode' => req.bookingCode,
            'totalCharged' => req.totalCharged == null ? '' : req.totalCharged
        };

        out.formData = new Skywave_PaymentFormData(JSON.serialize(state));
        out.success = true;
        out.message = 'Payment picker ready';
        return out;
    }
}
