public class Skywave_ResolveContact {

    public class Request {
        @InvocableVariable(label='Contact ID' description='A known Contact ID to validate')
        public String contactId;
        @InvocableVariable(label='Email' description='Email address to look up a Contact')
        public String email;
    }

    @InvocableMethod(label='Resolve Contact' description='Resolves a Contact ID from a known ID or email lookup')
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
                // Validate the provided Contact ID exists
                List<Contact> contacts = [
                    SELECT Id, FirstName, LastName, Email
                    FROM Contact WHERE Id = :req.contactId LIMIT 1
                ];
                if (!contacts.isEmpty()) {
                    r.success = true;
                    r.contactId = contacts[0].Id;
                    r.contactName = contacts[0].FirstName + ' ' + contacts[0].LastName;
                } else {
                    r.success = false;
                    r.errorMessage = 'Contact not found';
                }
            } else if (String.isNotBlank(req.email)) {
                // Look up Contact by email
                List<Contact> contacts = [
                    SELECT Id, FirstName, LastName, Email
                    FROM Contact WHERE Email = :req.email LIMIT 1
                ];
                if (!contacts.isEmpty()) {
                    r.success = true;
                    r.contactId = contacts[0].Id;
                    r.contactName = contacts[0].FirstName + ' ' + contacts[0].LastName;
                } else {
                    r.success = false;
                    r.errorMessage = 'No account found for that email address';
                }
            } else {
                r.success = false;
                r.errorMessage = 'Please provide either a Contact ID or email address';
            }
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Error resolving contact: ' + e.getMessage();
        }
        return r;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the contact was resolved')
        public Boolean success;
        @InvocableVariable(label='contactId' description='The resolved Contact ID')
        public String contactId;
        @InvocableVariable(label='contactName' description='The contact name')
        public String contactName;
        @InvocableVariable(label='errorMessage' description='Error details')
        public String errorMessage;
    }
}
