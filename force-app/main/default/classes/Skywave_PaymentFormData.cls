/**
 * Renderer DTO for the Skywave Payment Picker custom Lightning Type.
 *
 * Single @AuraEnabled String holds JSON: bookingCode + totalCharged +
 * contactId. The LWC parses it and shows three payment options
 * (Apple Pay, Credit Card, Demo Pay) with bookingCode + amount visible.
 * Demo Pay calls Skywave_ProcessPayment.processPayment imperatively.
 */
@JsonAccess(serializable='always' deserializable='always')
global class Skywave_PaymentFormData {

    @AuraEnabled
    global String paymentStateJSON;

    global Skywave_PaymentFormData(String paymentStateJSON) {
        this.paymentStateJSON = paymentStateJSON;
    }

    global Skywave_PaymentFormData() {
        this.paymentStateJSON = '';
    }
}
