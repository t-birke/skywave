/**
 * Agent action: is seat-change enabled right now?
 *
 * Multi-tenant: the gate is PER DEMO SESSION. Seat-change is enabled by the
 * Demo_Session__c.State__c picklist (every visitor of that session shares the
 * same result); we just resolve WHICH session to read by following the chat
 * visitor's Contact (resolved_contact_id) → Contact.Demo_Session__c → State__c,
 * enabling once THAT session reaches `agent_seat_pass`. So two presenters
 * running at once stay independent — presenter A advancing their session never
 * affects presenter B's session's visitors. Falls back to the global active
 * session when no contact is supplied (studio preview / unresolved visitor) so
 * the gate never hard-fails.
 *
 * Called from the router each turn (gated so it only runs while still
 * disabled AND the visitor actually has a booking) so a mid-conversation
 * stage flip reaches the open chat session on the visitor's next message —
 * no reload, no agent re-version.
 */
public with sharing class Skywave_CheckSeatEnabled {

    private static final String SEAT_ON = 'agent_seat_pass';
    // Skywave_ResolveSession's "no real contact" sentinel.
    private static final String CONTACT_SENTINEL = '003000000000000';

    @InvocableMethod(
        label='Skywave: Check seat-change enabled'
        description='Returns true when the visitor\'s own demo session is at the agent_seat_pass stage.'
        category='Skywave'
    )
    public static List<Output> check(List<Input> inputs) {
        // Invoked per-conversation, batch size 1.
        String contactId = (inputs != null && !inputs.isEmpty()) ? inputs[0].contactId : null;
        Boolean enabled = resolveEnabled(contactId);

        List<Output> outs = new List<Output>();
        Integer n = (inputs == null || inputs.isEmpty()) ? 1 : inputs.size();
        for (Integer i = 0; i < n; i++) {
            Output o = new Output();
            o.enabled = enabled;
            o.success = true;
            outs.add(o);
        }
        return outs;
    }

    private static Boolean resolveEnabled(String contactId) {
        // 1. Preferred: the visitor's OWN session via their Contact.
        if (String.isNotBlank(contactId) && contactId != CONTACT_SENTINEL) {
            try {
                Id cid = Id.valueOf(contactId);
                List<Contact> cs = [
                    SELECT Demo_Session__c, Demo_Session__r.State__c
                    FROM Contact WHERE Id = :cid LIMIT 1
                ];
                if (!cs.isEmpty() && cs[0].Demo_Session__c != null) {
                    return cs[0].Demo_Session__r.State__c == SEAT_ON;
                }
            } catch (Exception e) {
                // Malformed id or no access — fall through to the global fallback.
            }
        }
        // 2. Fallback: global active session (preview / unresolved visitor).
        List<Demo_Session__c> active = [
            SELECT State__c FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        return !active.isEmpty() && active[0].State__c == SEAT_ON;
    }

    public class Input {
        @InvocableVariable(
            label='Contact Id'
            description='The resolved visitor Contact Id (resolved_contact_id). The visitor\'s own Demo_Session__c.State__c is read from it so the seat gate is per-presenter. Optional — falls back to the global active session.'
        )
        public String contactId;

        // Deprecated. Retained ONLY so agent publish can evolve the existing
        // check_seat_enabled function schema additively — the publisher rejects
        // removing a previously-published property. Unused at runtime.
        @InvocableVariable(label='Ignored (deprecated)' description='Deprecated; unused. Kept for backward-compatible schema evolution.')
        public String ignored;
    }

    public class Output {
        @InvocableVariable(label='enabled' description='True when seat-change is enabled (active demo session at agent_seat_pass).')
        public Boolean enabled;
        @InvocableVariable(label='success' description='True if the check ran without error.')
        public Boolean success;
    }
}
