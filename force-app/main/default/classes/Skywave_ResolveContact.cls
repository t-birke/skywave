public class Skywave_ResolveContact {

    public class Request {
        @InvocableVariable(label='Contact ID' description='A known Contact ID to validate')
        public String contactId;
        @InvocableVariable(label='Email' description='Email address to look up a Contact')
        public String email;
        @InvocableVariable(label='Phone Number' description='Phone number to look up a Contact (E.164 or national format accepted)')
        public String phoneNumber;
    }

    @InvocableMethod(label='Resolve Contact' description='Resolves a Contact ID from a known ID, email, or phone number')
    public static List<Result> resolveContact(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(execute(req));
        }
        return results;
    }

    private static Result execute(Request req) {
        Result r = new Result();
        try {
            if (String.isNotBlank(req.contactId)) {
                List<Contact> contacts = [
                    SELECT Id, FirstName, LastName, Email
                    FROM Contact WHERE Id = :req.contactId LIMIT 1
                ];
                if (!contacts.isEmpty()) {
                    populateFromContact(r, contacts[0]);
                } else {
                    r.success = false;
                    r.errorMessage = 'Contact not found';
                }
            } else if (String.isNotBlank(req.email)) {
                List<Contact> contacts = [
                    SELECT Id, FirstName, LastName, Email
                    FROM Contact WHERE Email = :req.email LIMIT 1
                ];
                if (!contacts.isEmpty()) {
                    populateFromContact(r, contacts[0]);
                } else {
                    r.success = false;
                    r.errorMessage = 'No account found for that email address';
                }
            } else if (String.isNotBlank(req.phoneNumber)) {
                Contact match = findContactByPhone(req.phoneNumber);
                if (match != null) {
                    populateFromContact(r, match);
                } else {
                    r.success = false;
                    r.errorMessage = 'No contact found for that phone number';
                }
            } else {
                r.success = false;
                r.errorMessage = 'Please provide a Contact ID, email, or phone number';
            }
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Error resolving contact: ' + e.getMessage();
        }
        return r;
    }

    private static void populateFromContact(Result r, Contact c) {
        r.success = true;
        r.contactId = c.Id;
        r.firstName = c.FirstName;
        r.lastName = c.LastName;
        r.contactName = c.FirstName + ' ' + c.LastName;
    }

    // SOSL across phone fields, using the same normalization idea as
    // SDO_Service_Phone_Number_Search: strip +1 / + country prefix and hyphens,
    // then search. SOSL handles stored-format variations (parentheses, spaces).
    private static Contact findContactByPhone(String raw) {
        String stripped = normalizePhone(raw);
        if (String.isBlank(stripped)) return null;

        String searchTerm = String.escapeSingleQuotes(stripped);
        List<List<SObject>> results = Search.query(
            'FIND {' + searchTerm + '} IN PHONE FIELDS ' +
            'RETURNING Contact(Id, FirstName, LastName, Email, LastActivityDate ORDER BY LastActivityDate DESC NULLS LAST LIMIT 5)'
        );
        List<Contact> contacts = (List<Contact>) results[0];
        return contacts.isEmpty() ? null : contacts[0];
    }

    private static String normalizePhone(String raw) {
        if (String.isBlank(raw)) return null;
        String trimmed = raw.trim();
        if (trimmed.startsWith('+1')) {
            trimmed = trimmed.substring(2);
        } else if (trimmed.startsWith('+')) {
            trimmed = trimmed.substring(3);
        }
        return trimmed.replaceAll('[^0-9]', '');
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the contact was resolved')
        public Boolean success;
        @InvocableVariable(label='contactId' description='The resolved Contact ID')
        public String contactId;
        @InvocableVariable(label='firstName' description='The contact first name')
        public String firstName;
        @InvocableVariable(label='lastName' description='The contact last name')
        public String lastName;
        @InvocableVariable(label='contactName' description='The contact full name')
        public String contactName;
        @InvocableVariable(label='errorMessage' description='Error details')
        public String errorMessage;
    }
}
