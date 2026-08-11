/**
 * Renderer DTO for the Skywave Rental Payment Picker custom Lightning Type.
 *
 * Single @AuraEnabled String holds JSON: bookingCode + totalCharged +
 * contactId. The LWC parses it and shows three payment options (Apple Pay,
 * Credit Card, Demo Pay) with the rental code + amount visible. Demo Pay
 * calls Skywave_ProcessRentalPayment.processPayment imperatively.
 *
 * Deliberately identical in shape to Skywave_PaymentFormData so the rental
 * payment card behaves exactly like the flight one.
 */
@JsonAccess(serializable='always' deserializable='always')
global class Skywave_RentalPaymentData {

    @AuraEnabled
    global String paymentStateJSON;

    global Skywave_RentalPaymentData(String paymentStateJSON) {
        this.paymentStateJSON = paymentStateJSON;
    }

    global Skywave_RentalPaymentData() {
        this.paymentStateJSON = '';
    }
}
