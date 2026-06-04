/**
 * Resolves the inbound caller to a Contact on VoiceCall create, BEFORE save,
 * so the voice agent's linked variables (VoiceContactId, CallerFirstName, ...)
 * are populated by the time the agent session initialises.
 *
 * Why this exists: the SDO's phone-number-search flow is obsolete (off) and,
 * even when on, bailed whenever a number matched more than one Contact — which
 * is the normal case here because the same demo phone number is entered on many
 * Contacts as the demo is run repeatedly. This resolver instead picks the
 * FRESHEST matching Contact (most recently created) and never bails on
 * duplicates.
 *
 * Matching is digit-only and forgiving of free-text entry: the caller ID and
 * each Contact.Phone are reduced to digits, and we match on the trailing
 * subscriber digits (so +49 152..., 0049 152..., 0152... all resolve to the
 * same person regardless of how they typed their number into the survey).
 *
 * Uses SOQL on the Phone_Digits__c formula field (live data) rather than SOSL,
 * so a Contact created seconds earlier in the demo resolves immediately without
 * waiting for the search index.
 */
public without sharing class Skywave_VoiceCallResolver {

    // Number of trailing digits to match on. 9 covers the subscriber number for
    // German mobiles (15259156372 -> ...259156372) while staying specific enough
    // to avoid cross-matching unrelated numbers.
    private static final Integer MATCH_DIGITS = 9;

    public static void resolveCallers(List<VoiceCall> calls) {
        // Collect the trailing-digit keys for every inbound call needing resolution.
        Map<Integer, String> idxToKey = new Map<Integer, String>();
        for (Integer i = 0; i < calls.size(); i++) {
            VoiceCall vc = calls[i];
            if (vc.Contact__c != null) continue;                 // already resolved
            String digits = onlyDigits(vc.FromPhoneNumber);
            if (String.isBlank(digits)) continue;
            idxToKey.put(i, tail(digits));
        }
        if (idxToKey.isEmpty()) return;

        // One query for all distinct keys: every candidate Contact whose phone
        // digits end with one of the keys, freshest first.
        Set<String> keys = new Set<String>(idxToKey.values());
        // Build a dynamic OR of LIKE %key on the digits formula field.
        List<String> likeClauses = new List<String>();
        for (String k : keys) likeClauses.add('Phone_Digits__c LIKE \'%' + String.escapeSingleQuotes(k) + '\'');
        String soql =
            'SELECT Id, FirstName, LastName, Salutation, Phone_Digits__c, CreatedDate ' +
            'FROM Contact WHERE Phone_Digits__c != null AND (' + String.join(likeClauses, ' OR ') + ') ' +
            'ORDER BY CreatedDate DESC';
        List<Contact> candidates = Database.query(soql);

        // For each key, the freshest matching Contact wins (query is already
        // CreatedDate DESC, so the first candidate whose digits end with the key).
        Map<String, Contact> freshestByKey = new Map<String, Contact>();
        for (Contact c : candidates) {
            String cd = c.Phone_Digits__c;
            for (String k : keys) {
                if (!freshestByKey.containsKey(k) && cd != null && cd.endsWith(k)) {
                    freshestByKey.put(k, c);
                }
            }
        }

        for (Integer i : idxToKey.keySet()) {
            Contact c = freshestByKey.get(idxToKey.get(i));
            if (c == null) continue;                              // unknown caller — agent handles it
            VoiceCall vc = calls[i];
            vc.Contact__c = c.Id;
            vc.Caller_FirstName__c = c.FirstName;
            vc.Caller_LastName__c = c.LastName;
            vc.Caller_Salutation__c = c.Salutation;
        }
    }

    /** Strip everything but 0-9. */
    private static String onlyDigits(String s) {
        if (String.isBlank(s)) return '';
        return s.replaceAll('[^0-9]', '');
    }

    /** Trailing MATCH_DIGITS digits (or the whole thing if shorter). */
    private static String tail(String digits) {
        return digits.length() <= MATCH_DIGITS
            ? digits
            : digits.substring(digits.length() - MATCH_DIGITS);
    }
}
