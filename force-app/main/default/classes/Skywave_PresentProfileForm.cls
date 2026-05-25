/**
 * Invocable that returns a renderable Skywave_ProfileFormData payload.
 *
 * The agent calls this once when booking_step == "profile" to display
 * the profile form card in chat. The DTO is keyed off @variables.resolved_contact_id
 * and pre-fills any name/email/phone the Contact already has.
 *
 * No DML — pure read + serialize.
 */
public with sharing class Skywave_PresentProfileForm {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;
    }

    public class Output {
        @InvocableVariable(label='Form Data')
        public Skywave_ProfileFormData formData;

        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;
    }

    @InvocableMethod(
        label='Skywave: Present profile form'
        description='Returns the SkywaveProfileForm renderable DTO so the agent can show the profile form card. Pre-fills with whatever the Contact already has on file.'
        category='Skywave'
    )
    public static List<Output> present(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) {
            outs.add(presentOne(req));
        }
        return outs;
    }

    private static Output presentOne(Input req) {
        Output out = new Output();
        out.success = false;

        if (String.isBlank(req.contactId)) {
            out.message = 'Contact Id is required.';
            out.formData = new Skywave_ProfileFormData('{}');
            return out;
        }

        Map<String, Object> state = new Map<String, Object>{
            'contactId' => req.contactId,
            'firstName' => '',
            'lastName' => '',
            'email' => '',
            'phone' => ''
        };

        try {
            List<Contact> hits = [
                SELECT Id, FirstName, LastName, Email, Phone
                FROM Contact
                WHERE Id = :req.contactId
                LIMIT 1
            ];
            if (!hits.isEmpty()) {
                Contact c = hits[0];
                state.put('firstName', c.FirstName == null ? '' : c.FirstName);
                state.put('lastName', c.LastName == null ? '' : c.LastName);
                state.put('email', c.Email == null ? '' : c.Email);
                state.put('phone', c.Phone == null ? '' : c.Phone);
            }
        } catch (Exception e) {
            // soft-fail: we can still show an empty form
            out.message = 'Could not pre-fill form: ' + e.getMessage();
        }

        out.formData = new Skywave_ProfileFormData(JSON.serialize(state));
        out.success = true;
        if (String.isBlank(out.message)) {
            out.message = 'Form ready';
        }
        return out;
    }
}
