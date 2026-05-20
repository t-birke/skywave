/**
 * Phase 4 payment step. Marks every Pending Confirmation booking
 * for a Contact as Paid with the chosen payment method. Sits between
 * Skywave_UpdateContact and Skywave_ConfirmBooking — confirm should
 * only flip Pending → Confirmed once payment has succeeded.
 *
 * For the live audience demo there is no real payment processing.
 * Three named methods are accepted: "Apple Pay", "Saved card", and
 * "Demo card". All three succeed silently — cosmetic branding only,
 * for the eventual CLT card with real buttons. The action validates
 * that the named method is one of the three so a typo in the agent
 * prompt fails loudly rather than silently writing junk.
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

        @InvocableVariable(label='Number of bookings paid')
        public Integer paidCount;

        @InvocableVariable(label='Total amount charged (sum across bookings)')
        public String totalCharged;

        @InvocableVariable(label='Payment method used')
        public String paymentMethod;
    }

    @InvocableMethod(
        label='Skywave: Process payment'
        description='Marks every Pending Confirmation booking for the Contact as Paid using the named method. Demo only — no real charge.'
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
        out.paidCount = 0;
        out.totalCharged = '$0.00';

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

        try {
            List<Booking__c> pending = [
                SELECT Id, Total_Amount__c, Payment_Status__c
                FROM Booking__c
                WHERE Contact__c = :req.contactId
                  AND Status__c = 'Pending Confirmation'
                  AND Payment_Status__c != 'Paid'
            ];

            if (pending.isEmpty()) {
                out.success = true;
                return out;
            }

            Decimal total = 0;
            for (Booking__c b : pending) {
                b.Payment_Status__c = 'Paid';
                b.Payment_Method__c = method;
                if (b.Total_Amount__c != null) total += b.Total_Amount__c;
            }
            update pending;

            out.success = true;
            out.paidCount = pending.size();
            out.totalCharged = '$' + total.setScale(2).toPlainString();
        } catch (Exception e) {
            out.errorMessage = 'Payment failed: ' + e.getMessage();
        }
        return out;
    }
}
