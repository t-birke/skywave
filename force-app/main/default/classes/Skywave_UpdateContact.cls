/**
 * Phase 4: writes the visitor's real first/last/email onto the
 * anonymous Contact created in Phase 3. The agent calls this once it
 * has collected the values during the post-booking profile step.
 *
 * Light validation only: trims input, rejects blank names shorter
 * than 2 chars, requires '@' in email. Anything else the agent
 * extracts is trusted verbatim — this is a demo where the reveal is
 * the visitor seeing their own typed data flow back through the UI.
 *
 * Does NOT confirm the booking; that's Skywave_ConfirmBooking.
 * Splitting the two keeps the actions composable for any future
 * standalone profile update.
 */
public with sharing class Skywave_UpdateContact {

    public class Input {
        @InvocableVariable(label='Contact Id' required=true)
        public String contactId;

        @InvocableVariable(label='First name' required=true)
        public String firstName;

        @InvocableVariable(label='Last name' required=true)
        public String lastName;

        @InvocableVariable(label='Email' required=true)
        public String email;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='error message')
        public String errorMessage;

        @InvocableVariable(label='Updated Contact Id')
        public String contactId;
    }

    @InvocableMethod(
        label='Skywave: Update visitor profile'
        description='Writes first name, last name, and email onto the anonymous Contact. Validates that names are >= 2 chars and email contains @.'
        category='Skywave'
    )
    public static List<Output> updateProfiles(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) {
            outs.add(updateOne(req));
        }
        return outs;
    }

    private static Output updateOne(Input req) {
        Output out = new Output();
        out.success = false;

        String firstName = req.firstName == null ? '' : req.firstName.trim();
        String lastName  = req.lastName  == null ? '' : req.lastName.trim();
        String email     = req.email     == null ? '' : req.email.trim();

        if (String.isBlank(req.contactId)) {
            out.errorMessage = 'Contact Id is required.';
            return out;
        }
        if (firstName.length() < 2) {
            out.errorMessage = 'First name must be at least 2 characters.';
            return out;
        }
        if (lastName.length() < 2) {
            out.errorMessage = 'Last name must be at least 2 characters.';
            return out;
        }
        if (!email.contains('@')) {
            out.errorMessage = 'Email must contain @.';
            return out;
        }

        try {
            Contact c = new Contact(
                Id = req.contactId,
                FirstName = firstName,
                LastName = lastName,
                Email = email
            );
            update c;
            out.success = true;
            out.contactId = req.contactId;
        } catch (Exception e) {
            out.errorMessage = 'Profile update failed: ' + e.getMessage();
        }
        return out;
    }
}
