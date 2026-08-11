/**
 * Demo payment endpoint for the Skywave Rental Payment Picker LWC.
 *
 * Visitor clicks "Demo Pay" inside the chat-iframe LWC. The LWC calls this
 * @AuraEnabled method directly (not through the agent). Single atomic
 * transition on the Vehicle_Booking__c: Status `Pending Confirmation` ->
 * `Confirmed`, Payment_Status `Unpaid` -> `Paid`.
 *
 * No real charge — Apple Pay / Credit Card buttons in the LWC are
 * intentionally disabled with an inline "demo only" hint and never reach
 * this method. Demo Pay is the only call path.
 *
 * Returns the confirmation code for the LWC to display, then the LWC posts
 * "Rental payment completed" to chat as the cue. The agent verifies via
 * Skywave_ConfirmRental (read-only) before declaring success — defence
 * against client-cue spoofing. Directly mirrors Skywave_ProcessPayment.
 *
 * Runs `without sharing` so the ESW site guest user can update the
 * Vehicle_Booking__c regardless of OWD.
 */
public without sharing class Skywave_ProcessRentalPayment {

    public class Result {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String bookingCode;
        @AuraEnabled public String paymentMethod;
    }

    @AuraEnabled
    public static Result processPayment(String bookingCode, String paymentMethod) {
        Result r = new Result();
        r.success = false;

        if (String.isBlank(bookingCode)) {
            r.message = 'Rental code is required.';
            return r;
        }
        String method = paymentMethod == null ? 'Demo card' : paymentMethod.trim();

        try {
            List<Vehicle_Booking__c> matches = [
                SELECT Id, Status__c, Payment_Status__c, Confirmation_Code__c
                FROM Vehicle_Booking__c
                WHERE Confirmation_Code__c = :bookingCode
                LIMIT 1
            ];
            if (matches.isEmpty()) {
                r.message = 'Rental not found for code: ' + bookingCode;
                return r;
            }
            Vehicle_Booking__c b = matches[0];

            // Idempotent — visitor double-tapping shouldn't error.
            if (b.Payment_Status__c == 'Paid' && b.Status__c == 'Confirmed') {
                r.success = true;
                r.bookingCode = b.Confirmation_Code__c;
                r.paymentMethod = method;
                r.message = 'Already paid.';
                return r;
            }

            b.Payment_Status__c = 'Paid';
            b.Payment_Method__c = method;
            b.Status__c = 'Confirmed';
            update b;

            r.success = true;
            r.bookingCode = b.Confirmation_Code__c;
            r.paymentMethod = method;
            r.message = 'Payment completed.';
        } catch (Exception e) {
            r.message = 'Payment failed: ' + e.getMessage();
            System.debug('Skywave_ProcessRentalPayment error: ' + e.getMessage() +
                '\n' + e.getStackTraceString());
        }
        return r;
    }
}
