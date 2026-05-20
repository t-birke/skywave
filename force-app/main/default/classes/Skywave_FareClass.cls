/**
 * Single source of truth for fare-class naming.
 *
 * The four canonical classes are Economy, Premium Economy, Business,
 * and First. Visitors and the agent use various synonyms; this class
 * normalises everything to the canonical name and exposes constants
 * for consistent comparisons in callers.
 *
 * The class also bridges legacy data: the original demo used
 * proprietary brand names (Basic / Choice / Choice Preferred /
 * Choice Extra) which still appear on already-seeded Reservation
 * rows and as field API names on Flight__c. Those legacy values are
 * accepted as input synonyms and normalised forward.
 */
public with sharing class Skywave_FareClass {

    public static final String ECONOMY         = 'Economy';
    public static final String PREMIUM_ECONOMY = 'Premium Economy';
    public static final String BUSINESS        = 'Business';
    public static final String FIRST           = 'First';

    /**
     * Normalises any free-form fare class string to the canonical
     * picklist value. Case-insensitive. Returns null if the input is
     * blank or unrecognised.
     */
    public static String normalize(String input) {
        if (String.isBlank(input)) return null;
        String key = input.trim().toLowerCase();

        // Canonical names
        if (key == 'economy')         return ECONOMY;
        if (key == 'premium economy') return PREMIUM_ECONOMY;
        if (key == 'business')        return BUSINESS;
        if (key == 'first')           return FIRST;

        // Industry / informal synonyms
        if (key == 'main cabin' || key == 'coach' ||
            key == 'standard economy' || key == 'main' ||
            key == 'basic economy' || key == 'restricted economy') return ECONOMY;
        if (key == 'economy plus' || key == 'extra comfort' ||
            key == 'premium')                                       return PREMIUM_ECONOMY;
        if (key == 'business class')                                return BUSINESS;
        if (key == 'first class')                                   return FIRST;

        // Legacy Skywave brand names (only on pre-rename data)
        if (key == 'basic')            return ECONOMY;
        if (key == 'choice')           return PREMIUM_ECONOMY;
        if (key == 'choice preferred') return BUSINESS;
        if (key == 'choice extra')     return FIRST;

        return null;
    }

    /**
     * Same as normalize(), but falls back to Economy when the input
     * is blank/unknown — so callers that need a price can quote a
     * default rather than crash.
     */
    public static String normalizeOrDefault(String input) {
        String n = normalize(input);
        return n != null ? n : ECONOMY;
    }
}
