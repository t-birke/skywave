/**
 * Returns how many flight segments are on a single booking, identified by
 * confirmation code. Used by the seat_selection subagent to drive its
 * funnel deterministically: once the visitor's booking is known (either it's
 * their only booking, or they picked one), the agent queries the segment
 * count and branches — 1 segment -> show the seat map directly; >1 -> ask
 * which flight first.
 *
 * Counting segments cannot be done in Agent Script (no list-length operator),
 * so it is resolved here and returned as a scalar Integer the agent can
 * compare against.
 */
public with sharing class Skywave_GetSegmentCount {

    public class Input {
        @InvocableVariable(label='Booking Code' required=true
            description='Confirmation code of the booking to count segments for.')
        public String bookingCode;
    }

    public class Output {
        @InvocableVariable(label='segment count'
            description='Number of segments (flights) on the booking. 0 if the booking was not found.')
        public Integer segmentCount;

        @InvocableVariable(label='success' description='true if the count was resolved')
        public Boolean success;

        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
    }

    @InvocableMethod(
        label='Skywave: Count booking segments'
        description='Returns the number of flight segments on a booking, looked up by confirmation code.'
        category='Skywave'
    )
    public static List<Output> getSegmentCount(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input req : inputs) outs.add(countOne(req));
        return outs;
    }

    private static Output countOne(Input req) {
        Output out = new Output();
        out.success = false;
        out.segmentCount = 0;

        if (String.isBlank(req.bookingCode)) {
            out.errorMessage = 'Booking code is required.';
            return out;
        }

        try {
            out.segmentCount = [
                SELECT COUNT()
                FROM Booking_Segment__c
                WHERE Booking__r.Confirmation_Code__c = :req.bookingCode
            ];
            out.success = true;
        } catch (Exception e) {
            out.errorMessage = 'Error counting segments: ' + e.getMessage();
            System.debug('GetSegmentCount error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        return out;
    }
}
