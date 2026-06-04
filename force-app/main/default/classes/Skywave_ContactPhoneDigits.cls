/**
 * Maintains Contact.Phone_Digits__c — the Phone reduced to digits only — on
 * every insert/update. This is the field the voice caller-resolver SOQLs
 * against to match an inbound caller ID against a free-text-entered phone,
 * on trailing digits, regardless of how the visitor formatted their number
 * (+49…, 0049…, 0…, spaces, dashes, etc.).
 *
 * Plain Text (not a formula) so it's indexed and queryable without formula
 * recalc/propagation lag.
 */
public class Skywave_ContactPhoneDigits {

    public static void setDigits(List<Contact> records, Map<Id, Contact> oldMap) {
        for (Contact c : records) {
            // Recompute only when Phone changed (or on insert).
            Boolean phoneChanged = (oldMap == null)
                || (oldMap.get(c.Id) != null && oldMap.get(c.Id).Phone != c.Phone);
            if (!phoneChanged) continue;
            c.Phone_Digits__c = onlyDigits(c.Phone);
        }
    }

    private static String onlyDigits(String s) {
        return String.isBlank(s) ? null : s.replaceAll('[^0-9]', '');
    }
}
