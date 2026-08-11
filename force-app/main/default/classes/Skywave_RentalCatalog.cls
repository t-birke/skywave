/**
 * Single source of truth for the Skywave rental-car catalogue: the three
 * vehicle tiers, their example models, and their daily rates.
 *
 * Every rental modality (the offer CLT, the reserve invocable, the engine)
 * reads its pricing and copy from here so there is exactly one place to
 * change a rate or a model name. Mirrors the role Skywave_FareClass plays
 * for flights.
 */
public with sharing class Skywave_RentalCatalog {

    public static final String ECONOMY = 'Economy';
    public static final String COMFORT = 'Comfort';
    public static final String LUXURY  = 'Luxury';

    public static final Integer MIN_DAYS = 1;
    public static final Integer MAX_DAYS = 14;

    /**
     * Immutable descriptor for one vehicle tier. `dailyRate` is the price
     * per rental day in USD.
     */
    public class Tier {
        public String category;
        public String exampleModel;
        public Decimal dailyRate;
        public String blurb;

        public Tier(String category, String exampleModel, Decimal dailyRate, String blurb) {
            this.category = category;
            this.exampleModel = exampleModel;
            this.dailyRate = dailyRate;
            this.blurb = blurb;
        }
    }

    // Ordered lowest → highest tier. Order matters: the offer card renders
    // the tiles left-to-right in this order.
    public static final List<Tier> TIERS = new List<Tier>{
        new Tier(ECONOMY, 'VW Polo or similar',    45,  'Compact and easy on fuel — perfect for city trips.'),
        new Tier(COMFORT, 'Audi A4 or similar',    75,  'Roomy mid-size with extra comfort for longer drives.'),
        new Tier(LUXURY,  'BMW 7 Series or similar', 140, 'Premium ride with the works — arrive in style.')
    };

    /**
     * Canonicalise a free-text / user-supplied category to one of the three
     * tiers. Returns null when it can't be resolved.
     */
    public static String normalize(String input) {
        if (String.isBlank(input)) return null;
        String v = input.trim().toLowerCase();
        if (v.startsWith('eco')) return ECONOMY;
        if (v.startsWith('comf') || v == 'mid' || v.startsWith('mid-size') || v.startsWith('midsize') || v.startsWith('standard')) return COMFORT;
        if (v.startsWith('lux') || v.startsWith('premium') || v.startsWith('first')) return LUXURY;
        // exact-ish match on the canonical labels
        if (v == ECONOMY.toLowerCase()) return ECONOMY;
        if (v == COMFORT.toLowerCase()) return COMFORT;
        if (v == LUXURY.toLowerCase())  return LUXURY;
        return null;
    }

    /** Look up a tier descriptor by (already-normalised) category, or null. */
    public static Tier tierFor(String category) {
        String canonical = normalize(category);
        if (canonical == null) return null;
        for (Tier t : TIERS) {
            if (t.category == canonical) return t;
        }
        return null;
    }

    /** Clamp a requested day count to the supported 1–14 range. */
    public static Integer clampDays(Integer requested) {
        if (requested == null) return MIN_DAYS;
        if (requested < MIN_DAYS) return MIN_DAYS;
        if (requested > MAX_DAYS) return MAX_DAYS;
        return requested;
    }
}
