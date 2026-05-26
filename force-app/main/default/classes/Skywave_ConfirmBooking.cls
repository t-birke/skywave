/**
 * Verify-only confirmation read.
 *
 * Phase 3.5b-r2: the actual booking insert moved to
 * Skywave_AckProfileForm and the Status/Payment_Status flip moved to
 * Skywave_ProcessPayment (LWC-invoked). This action no longer writes
 * anything — it just re-reads the Booking__c by code/contact and
 * reports whether it's Confirmed/Paid.
 *
 * Why keep it: defence against client-cue spoofing. The Skywave
 * Payment Picker LWC posts "Payment completed" to chat as the cue
 * for the agent to advance. The agent invokes this action to check
 * the DB before declaring success to the visitor; if the booking is
 * still Unpaid (e.g. the cue was forged or a network blip aborted the
 * @AuraEnabled write), confirm fails loudly.
 */
public with sharing class Skywave_ConfirmBooking {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Booking Code')
        public String bookingCode;
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

        @InvocableVariable(label='Total charged')
        public String totalCharged;
    }

    @InvocableMethod(
        label='Skywave: Verify booking is paid'
        description='Verify-only. Reads the visitor booking and reports whether the payment widget actually completed. Defence against forged client cues.'
        category='Skywave'
    )
    public static List<Output> confirm(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(confirmOne(req));
        return outs;
    }

    private static Output confirmOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.confirmedCount = 0;
        out.confirmationCodes = '';
        out.totalCharged = '$0.00';

        if (String.isBlank(req.contactId)) {
            out.errorMessage = 'Contact Id missing.';
            return out;
        }

        try {
            // Prefer lookup by booking code (1 row), fall back to
            // contactId (latest pending) when the agent has only context.
            List<Booking__c> matches;
            if (String.isNotBlank(req.bookingCode)) {
                matches = [
                    SELECT Id, Status__c, Payment_Status__c, Confirmation_Code__c, Total_Amount__c
                    FROM Booking__c
                    WHERE Confirmation_Code__c = :req.bookingCode
                      AND Contact__c = :req.contactId
                    LIMIT 1
                ];
            } else {
                matches = [
                    SELECT Id, Status__c, Payment_Status__c, Confirmation_Code__c, Total_Amount__c
                    FROM Booking__c
                    WHERE Contact__c = :req.contactId
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
            }

            if (matches.isEmpty()) {
                out.errorMessage = 'No booking found for the visitor.';
                return out;
            }
            Booking__c b = matches[0];

            if (b.Payment_Status__c != 'Paid') {
                out.errorMessage = 'Booking ' + b.Confirmation_Code__c +
                    ' is still Unpaid. The payment widget did not complete.';
                return out;
            }
            if (b.Status__c != 'Confirmed') {
                out.errorMessage = 'Booking ' + b.Confirmation_Code__c +
                    ' is Paid but Status is ' + b.Status__c + '.';
                return out;
            }

            out.success = true;
            out.confirmedCount = 1;
            out.confirmationCodes = b.Confirmation_Code__c;
            if (b.Total_Amount__c != null) {
                out.totalCharged = '$' + b.Total_Amount__c.setScale(2).toPlainString();
            }
        } catch (Exception e) {
            out.errorMessage = 'Confirm failed: ' + e.getMessage();
            System.debug('Skywave_ConfirmBooking error: ' + e.getMessage() +
                '\n' + e.getStackTraceString());
        }
        return out;
    }
}
