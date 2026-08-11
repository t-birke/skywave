/**
 * Invocable that returns a renderable Skywave_RentalOfferData payload.
 *
 * The rental agent calls this once when it enters the offer step, to show
 * the rental card in chat: a duration slider (1–14 days) plus the three
 * vehicle tiles (Economy / Comfort / Luxury) with live-updating totals.
 * Pre-fills the destination + pickup date the router resolved from the
 * visitor's flight.
 *
 * No DML — pure read + serialize. Pricing/copy come from
 * Skywave_RentalCatalog (single source of truth).
 */
public with sharing class Skywave_PresentRentalOffer {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='Destination code (IATA)' required=false)
        public String destinationCode;

        @InvocableVariable(label='Destination city' required=false)
        public String destinationCity;

        @InvocableVariable(label='Pickup date (YYYY-MM-DD)' required=false)
        public String pickupDate;

        @InvocableVariable(label='Flight booking code' required=false)
        public String flightBookingCode;
    }

    public class Output {
        @InvocableVariable(label='Offer Data')
        public Skywave_RentalOfferData offerData;

        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;
    }

    @InvocableMethod(
        label='Skywave: Present rental offer'
        description='Returns the SkywaveRentalOffer renderable DTO so the agent can show the rental card (duration slider + 3 vehicle tiles). Pre-fills destination and pickup date.'
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

        // Build the tier descriptors from the catalogue so the card and the
        // reserve/price logic can never disagree.
        List<Map<String, Object>> tiers = new List<Map<String, Object>>();
        for (Skywave_RentalCatalog.Tier t : Skywave_RentalCatalog.TIERS) {
            tiers.add(new Map<String, Object>{
                'category' => t.category,
                'exampleModel' => t.exampleModel,
                'dailyRate' => t.dailyRate,
                'blurb' => t.blurb
            });
        }

        Map<String, Object> state = new Map<String, Object>{
            'contactId' => req.contactId == null ? '' : req.contactId,
            'destinationCode' => req.destinationCode == null ? '' : req.destinationCode,
            'destinationCity' => req.destinationCity == null ? '' : req.destinationCity,
            'pickupDate' => req.pickupDate == null ? '' : req.pickupDate,
            'flightBookingCode' => req.flightBookingCode == null ? '' : req.flightBookingCode,
            'minDays' => Skywave_RentalCatalog.MIN_DAYS,
            'maxDays' => Skywave_RentalCatalog.MAX_DAYS,
            'defaultDays' => 3,
            'tiers' => tiers
        };

        out.offerData = new Skywave_RentalOfferData(JSON.serialize(state));
        out.success = true;
        out.message = 'Rental offer ready';
        return out;
    }
}
