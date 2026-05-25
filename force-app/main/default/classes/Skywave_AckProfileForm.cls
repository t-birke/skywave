/**
 * No-op acknowledgement action.
 *
 * The Skywave Profile Form LWC submits the form via @AuraEnabled
 * (Skywave_SaveProfile) and then sends "Profile created" as a chat
 * message. The agent's reasoning treats that message as the cue to
 * invoke this action, which simply returns success — its sole job is
 * to flip @variables.profile_collected to True so the booking_step
 * state machine advances to "payment".
 *
 * No DML, no business logic. Decoupled from Skywave_SaveProfile so the
 * Apex write happens regardless of whether the agent ever invokes this.
 */
public with sharing class Skywave_AckProfileForm {

    public class Input {
        @InvocableVariable(label='Contact Id' required=false)
        public String contactId;
    }

    public class Output {
        @InvocableVariable(label='success')
        public Boolean success;

        @InvocableVariable(label='message')
        public String message;
    }

    @InvocableMethod(
        label='Skywave: Acknowledge profile form'
        description='Invoke this when the visitor sends the exact phrase "Profile created" — that text is the cue from the profile form LWC that the form has been submitted. Calling this action is how the agent advances out of booking_step=profile.'
        category='Skywave'
    )
    public static List<Output> ack(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) {
            Output out = new Output();
            out.success = true;
            out.message = 'Profile acknowledged';
            outs.add(out);
        }
        return outs;
    }
}
