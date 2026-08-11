/**
 * Invocable that returns a renderable Skywave_RentalPaymentData payload.
 *
 * The rental agent calls this once when it enters the payment step, to
 * show the rental payment-picker card in chat. Pre-fills with the rental
 * confirmation code + total the agent pinned from Skywave_ReserveVehicle.
 *
 * No DML — pure read + serialize. Identical shape to
 * Skywave_PresentPaymentForm.
 */
public with sharing class Skywave_PresentRentalPayment {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Rental Code' required=true)
        public String bookingCode;

        @InvocableVariable(label='Total amount (e.g. $300.00)' required=true)
        public String totalCharged;
    }

    public class Output {
        @InvocableVariable(label='Form Data')
        public Skywave_RentalPaymentData formData;

        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;
    }

    @InvocableMethod(
        label='Skywave: Present rental payment picker'
        description='Returns the SkywaveRentalPayment renderable DTO so the agent can show the rental payment-picker card. Pre-fills with the rental code and total.'
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
            out.message = 'Rental code is required.';
            out.formData = new Skywave_RentalPaymentData('{}');
            return out;
        }

        Map<String, Object> state = new Map<String, Object>{
            'contactId' => req.contactId == null ? '' : req.contactId,
            'bookingCode' => req.bookingCode,
            'totalCharged' => req.totalCharged == null ? '' : req.totalCharged
        };

        out.formData = new Skywave_RentalPaymentData(JSON.serialize(state));
        out.success = true;
        out.message = 'Rental payment picker ready';
        return out;
    }
}
