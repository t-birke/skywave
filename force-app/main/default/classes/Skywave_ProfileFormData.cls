/**
 * Renderer DTO for the Skywave Profile Form custom Lightning Type.
 *
 * Mirrors the Skywave_FlightSearchResultData envelope pattern: a single
 * @AuraEnabled String holds JSON. The LWC parses it and renders a form
 * pre-populated with whatever the Contact already has on file (firstName,
 * lastName, email, phone, contactId).
 *
 * The form captures a base64 avatar + the four fields and posts back to
 * Skywave_SaveProfile via @AuraEnabled imperative call. Avatar upload
 * NEVER goes through the agent — it's a direct LWC-to-Apex round trip.
 */
@JsonAccess(serializable='always' deserializable='always')
global class Skywave_ProfileFormData {

    @AuraEnabled
    global String formStateJSON;

    global Skywave_ProfileFormData(String formStateJSON) {
        this.formStateJSON = formStateJSON;
    }

    global Skywave_ProfileFormData() {
        this.formStateJSON = '';
    }
}
