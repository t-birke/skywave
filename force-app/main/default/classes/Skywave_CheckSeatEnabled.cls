/**
 * Agent action: is seat-change enabled right now?
 *
 * Reads the active Demo_Session__c (one row per presenter run, resolved the
 * same way as Skywave_SessionStart / Skywave_DemoMonitorController:
 * Active__c=true, newest Started__c). Seat change is enabled once the
 * presenter has advanced the demo to the `agent_seat_pass` stage.
 *
 * Called from the router each turn (gated so it only runs while still
 * disabled AND the visitor actually has a booking) so a mid-conversation
 * stage flip reaches the open chat session on the visitor's next message —
 * no reload, no agent re-version. The whole point: the demo can switch the
 * agent's capability live by advancing one Demo_Session__c picklist the
 * monitor already drives.
 */
public with sharing class Skywave_CheckSeatEnabled {

    @InvocableMethod(
        label='Skywave: Check seat-change enabled'
        description='Returns true when the active demo session is at the agent_seat_pass stage.'
        category='Skywave'
    )
    public static List<Output> check(List<Input> inputs) {
        // Resolve once; the action is invoked per-conversation, batch size 1.
        Boolean enabled = false;
        List<Demo_Session__c> active = [
            SELECT State__c FROM Demo_Session__c
            WHERE Active__c = true
            ORDER BY Started__c DESC NULLS LAST
            LIMIT 1
        ];
        if (!active.isEmpty()) {
            enabled = (active[0].State__c == 'agent_seat_pass');
        }

        List<Output> outs = new List<Output>();
        for (Integer i = 0; i < inputs.size(); i++) {
            Output o = new Output();
            o.enabled = enabled;
            o.success = true;
            outs.add(o);
        }
        if (outs.isEmpty()) {
            Output o = new Output();
            o.enabled = enabled;
            o.success = true;
            outs.add(o);
        }
        return outs;
    }

    public class Input {
        // No inputs needed — the active session is resolved server-side.
        // A placeholder keeps the invocable contract stable for the agent.
        @InvocableVariable(label='Ignored' description='Unused; the active demo session is resolved server-side.')
        public String ignored;
    }

    public class Output {
        @InvocableVariable(label='enabled' description='True when seat-change is enabled (active demo session at agent_seat_pass).')
        public Boolean enabled;
        @InvocableVariable(label='success' description='True if the check ran without error.')
        public Boolean success;
    }
}
