/**
 * Verify-only rental confirmation read — the rental analogue of
 * Skywave_ConfirmBooking.
 *
 * This action does not write anything. It re-reads the Vehicle_Booking__c
 * by code/contact and reports whether the payment widget actually flipped
 * it to Confirmed/Paid. The Skywave Rental Payment Picker LWC posts
 * "Rental payment completed" to chat as the cue; the agent invokes this to
 * check the DB before declaring success. If the rental is still Unpaid
 * (forged cue, aborted write), confirm fails loudly.
 */
public with sharing class Skywave_ConfirmRental {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Rental Code')
        public String bookingCode;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='error message')
        public String errorMessage;

        @InvocableVariable(label='Confirmation code')
        public String confirmationCode;

        @InvocableVariable(label='Vehicle category')
        public String category;

        @InvocableVariable(label='Rental days')
        public Integer rentalDays;

        @InvocableVariable(label='Total charged')
        public String totalCharged;

        @InvocableVariable(label='Pickup date')
        public String pickupDate;

        @InvocableVariable(label='Destination')
        public String destination;
    }

    @InvocableMethod(
        label='Skywave: Verify rental is paid'
        description='Verify-only. Reads the visitor rental and reports whether the payment widget actually completed. Defence against forged client cues.'
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
        out.confirmationCode = '';
        out.totalCharged = '$0.00';

        if (String.isBlank(req.contactId)) {
            out.errorMessage = 'Contact Id missing.';
            return out;
        }

        try {
            List<Vehicle_Booking__c> matches;
            if (String.isNotBlank(req.bookingCode)) {
                matches = [
                    SELECT Id, Status__c, Payment_Status__c, Confirmation_Code__c,
                           Vehicle_Category__c, Rental_Days__c, Total_Amount__c,
                           Pickup_Date__c, Destination__c
                    FROM Vehicle_Booking__c
                    WHERE Confirmation_Code__c = :req.bookingCode
                      AND Contact__c = :req.contactId
                    LIMIT 1
                ];
            } else {
                matches = [
                    SELECT Id, Status__c, Payment_Status__c, Confirmation_Code__c,
                           Vehicle_Category__c, Rental_Days__c, Total_Amount__c,
                           Pickup_Date__c, Destination__c
                    FROM Vehicle_Booking__c
                    WHERE Contact__c = :req.contactId
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
            }

            if (matches.isEmpty()) {
                out.errorMessage = 'No rental found for the visitor.';
                return out;
            }
            Vehicle_Booking__c b = matches[0];

            if (b.Payment_Status__c != 'Paid') {
                out.errorMessage = 'Rental ' + b.Confirmation_Code__c +
                    ' is still Unpaid. The payment widget did not complete.';
                return out;
            }
            if (b.Status__c != 'Confirmed') {
                out.errorMessage = 'Rental ' + b.Confirmation_Code__c +
                    ' is Paid but Status is ' + b.Status__c + '.';
                return out;
            }

            out.success = true;
            out.confirmationCode = b.Confirmation_Code__c;
            out.category = b.Vehicle_Category__c;
            out.rentalDays = b.Rental_Days__c != null ? Integer.valueOf(b.Rental_Days__c) : null;
            if (b.Total_Amount__c != null) {
                out.totalCharged = '$' + b.Total_Amount__c.setScale(2).toPlainString();
            }
            out.pickupDate = b.Pickup_Date__c != null ? String.valueOf(b.Pickup_Date__c) : '';
            out.destination = b.Destination__c;
        } catch (Exception e) {
            out.errorMessage = 'Confirm failed: ' + e.getMessage();
            System.debug('Skywave_ConfirmRental error: ' + e.getMessage() +
                '\n' + e.getStackTraceString());
        }
        return out;
    }
}
