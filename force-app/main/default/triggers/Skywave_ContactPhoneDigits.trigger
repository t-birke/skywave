/**
 * Keeps Contact.Phone_Digits__c (digits-only Phone) in sync for the voice
 * caller-resolver. Before-save so the value is set in the same DML.
 */
trigger Skywave_ContactPhoneDigits on Contact (before insert, before update) {
    Skywave_ContactPhoneDigits.setDigits(
        Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null
    );
}
