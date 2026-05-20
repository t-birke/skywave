/**
 * Phase 4: flips every Pending Confirmation booking for a Contact to
 * Confirmed. The agent calls this immediately after the visitor pays,
 * completing the booking.
 *
 * Returns the number of bookings confirmed and the list of
 * confirmation codes — the agent uses these to compose the closing
 * message ("Confirmed: SKN2RT, ABC123") and any downstream UI gets a
 * record of what just changed.
 *
 * Defence in depth: refuses to confirm any booking still Unpaid, so
 * the agent can't accidentally ticket without payment.
 */
public with sharing class Skywave_ConfirmBooking {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='error message')
        public String errorMessage;

        @InvocableVariable(label='Number of bookings confirmed')
        public Integer confirmedCount;

        @InvocableVariable(label='Confirmation codes (comma-separated)')
        public String confirmationCodes;
    }

    @InvocableMethod(
        label='Skywave: Confirm pending bookings'
        description='Flips all Paid Pending Confirmation bookings for a Contact to Confirmed. Refuses unpaid bookings.'
        category='Skywave'
    )
    public static List<Output> confirm(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) {
            outs.add(confirmOne(req));
        }
        return outs;
    }

    private static Output confirmOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.confirmedCount = 0;
        out.confirmationCodes = '';

        if (String.isBlank(req.contactId)) {
            out.errorMessage = 'Contact Id is required.';
            return out;
        }

        try {
            List<Booking__c> pending = [
                SELECT Id, Confirmation_Code__c, Payment_Status__c
                FROM Booking__c
                WHERE Contact__c = :req.contactId
                  AND Status__c = 'Pending Confirmation'
            ];

            if (pending.isEmpty()) {
                out.success = true;
                return out;
            }

            // Never ticket an unpaid booking, even if the agent
            // reasoning forgot to call payment.
            List<Booking__c> paid = new List<Booking__c>();
            List<String> unpaidCodes = new List<String>();
            for (Booking__c b : pending) {
                if (b.Payment_Status__c == 'Paid') {
                    paid.add(b);
                } else {
                    unpaidCodes.add(b.Confirmation_Code__c);
                }
            }
            if (!unpaidCodes.isEmpty()) {
                out.errorMessage = 'Cannot confirm — payment is still pending for: '
                    + String.join(unpaidCodes, ', ') + '. Run process_payment first.';
                return out;
            }

            List<String> codes = new List<String>();
            for (Booking__c b : paid) {
                b.Status__c = 'Confirmed';
                codes.add(b.Confirmation_Code__c);
            }
            update paid;

            out.success = true;
            out.confirmedCount = paid.size();
            out.confirmationCodes = String.join(codes, ', ');
        } catch (Exception e) {
            out.errorMessage = 'Confirm failed: ' + e.getMessage();
        }
        return out;
    }
}
