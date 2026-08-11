/**
 * Renderer DTO for the Skywave Rental Offer custom Lightning Type.
 *
 * Single @AuraEnabled String holds JSON: destination, pickup date, and the
 * three vehicle tiers (category, model, daily rate). The LWC parses it and
 * renders a duration slider (1–14 days) plus three tier tiles whose totals
 * update live as the slider moves. Each tile's Reserve button posts
 * "Rent <category> for <N> days" back to chat.
 *
 * Same shape as Skywave_PaymentFormData / Skywave_FlightSearchResultData —
 * a JSON envelope keeps the Lightning Type schema trivial and lets the DTO
 * evolve without a schema redeploy.
 */
@JsonAccess(serializable='always' deserializable='always')
global class Skywave_RentalOfferData {

    @AuraEnabled
    global String offerStateJSON;

    global Skywave_RentalOfferData(String offerStateJSON) {
        this.offerStateJSON = offerStateJSON;
    }

    global Skywave_RentalOfferData() {
        this.offerStateJSON = '';
    }
}
