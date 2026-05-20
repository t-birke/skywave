/**
 * Resolves the visitor's declared survey context for the
 * Skywave_Airlines_Agent. Input: MessagingSession.ConversationId
 * (provided by the agent's @MessagingSession.ConversationId linked
 * variable). Output: structured JSON + natural-language summary the
 * agent uses for personalised reasoning.
 *
 * Implementation:
 *   - Looks up the anonymous Contact created by Skywave_ContactUpsert
 *     (keyed on Skywave_Conversation_Id__c).
 *   - Returns the cached survey JSON + summary that was written when
 *     the consumer site's "thanks" screen rendered.
 *
 * Returns silently with empty results if no Contact is found (anonymous
 * sessions, demo without survey, race between the chat-start POST and
 * the agent's first reasoning turn).
 */
public with sharing class Skywave_ResolveSession {

    public class Input {
        @InvocableVariable(label='Conversation Id' required=true)
        public String conversationId;
    }

    public class Output {
        @InvocableVariable(label='Number of survey answers found')
        public Integer answerCount;

        @InvocableVariable(label='Question/answer pairs as JSON')
        public String responsesJson;

        @InvocableVariable(label='Natural-language summary for agent reasoning')
        public String summary;

        @InvocableVariable(label='Resolved Contact Id (for booking actions)')
        public String contactId;
    }

    @InvocableMethod(
        label='Skywave: Resolve session context'
        description='Look up the visitor\'s declared survey answers from the anonymous Contact created at survey-complete time, keyed on the chat ConversationId. Returns structured JSON and a one-line natural-language summary.'
        category='Skywave'
    )
    public static List<Output> resolve(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input request : inputs) {
            outs.add(resolveOne(request.conversationId));
        }
        return outs;
    }

    private static Output resolveOne(String conversationId) {
        Output out = new Output();
        out.answerCount = 0;
        out.responsesJson = '{}';
        out.summary = '';

        if (String.isBlank(conversationId)) {
            return out;
        }

        List<Contact> contacts = [
            SELECT Id, Skywave_Survey_Json__c, Skywave_Survey_Summary__c
            FROM Contact
            WHERE Skywave_Conversation_Id__c = :conversationId
            LIMIT 1
        ];
        if (contacts.isEmpty()) {
            return out;
        }
        Contact c = contacts[0];
        out.contactId = c.Id;

        if (String.isNotBlank(c.Skywave_Survey_Json__c)) {
            out.responsesJson = c.Skywave_Survey_Json__c;
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(c.Skywave_Survey_Json__c);
                out.answerCount = parsed != null ? parsed.size() : 0;
            } catch (Exception e) {
                out.answerCount = 0;
            }
        }
        if (String.isNotBlank(c.Skywave_Survey_Summary__c)) {
            out.summary = c.Skywave_Survey_Summary__c;
        }

        return out;
    }
}
