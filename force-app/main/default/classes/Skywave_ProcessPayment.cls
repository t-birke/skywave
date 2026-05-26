/**
 * Demo payment endpoint for the Skywave Payment Picker LWC.
 *
 * Visitor clicks "Demo Pay" inside the chat-iframe LWC. The LWC calls
 * this @AuraEnabled method directly (not through the agent). Single
 * atomic transition: Status `Pending Confirmation` -> `Confirmed`,
 * Payment_Status `Unpaid` -> `Paid`.
 *
 * No real charge — Apple Pay / Credit Card buttons in the LWC are
 * intentionally disabled with an inline "demo only" hint, never reach
 * this method. Demo Pay is the only call path.
 *
 * Returns confirmationCode for the LWC to display, then the LWC posts
 * "Payment completed" to chat as the cue. The agent verifies via
 * Skywave_ConfirmBooking (read-only) before declaring success to the
 * visitor — defence against client-cue spoofing.
 *
 * Runs `without sharing` so the ESW site guest user can update the
 * Booking__c regardless of OWD on Booking__c.
 */
public without sharing class Skywave_ProcessPayment {

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
            r.message = 'Booking code is required.';
            return r;
        }
        // We accept any string here — the LWC enforces the three-method
        // contract; this method only cares that something was passed.
        String method = paymentMethod == null ? 'Demo card' : paymentMethod.trim();

        try {
            List<Booking__c> matches = [
                SELECT Id, Status__c, Payment_Status__c, Confirmation_Code__c
                FROM Booking__c
                WHERE Confirmation_Code__c = :bookingCode
                LIMIT 1
            ];
            if (matches.isEmpty()) {
                r.message = 'Booking not found for code: ' + bookingCode;
                return r;
            }
            Booking__c b = matches[0];

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
            System.debug('Skywave_ProcessPayment error: ' + e.getMessage() +
                '\n' + e.getStackTraceString());
        }
        return r;
    }
}
