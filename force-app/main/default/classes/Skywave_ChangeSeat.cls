public class Skywave_ChangeSeat {

    public class Request {
        @InvocableVariable(label='Booking Segment ID' description='The Booking Segment ID to change seat for' required=true)
        public String bookingSegmentId;

        @InvocableVariable(label='New Seat Number' description='The desired seat number (e.g., 12A)')
        public String newSeatNumber;

        @InvocableVariable(label='Seat Preference' description='Seat preference if no specific seat: Window, Aisle, or Middle')
        public String seatPreference;
    }

    @InvocableMethod(label='Change Seat' description='Changes the seat assignment for a booking segment')
    public static List<Result> changeSeat(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            results.add(executeSeatChange(req));
        }
        return results;
    }

    /**
     * Imperative entry point for the Skywave Seat Map renderer LWC.
     *
     * The visitor picks a seat in the chat-iframe seatmap and taps
     * "Confirm seat". The LWC calls this @AuraEnabled method directly
     * (NOT through the agent), mirroring Skywave_ProcessPayment. Runs
     * `without sharing` (via the GuestSeatWriter inner class) so the
     * ESW site guest user can update the Booking_Segment__c regardless
     * of OWD/FLS.
     *
     * On success the LWC shows a confirmation (booking + flight + seat)
     * and posts "seat change confirmed" to chat as the verify-only cue.
     */
    @AuraEnabled
    public static SeatChangeResult confirmSeatChange(String bookingSegmentId, String newSeatNumber) {
        SeatChangeResult r = new SeatChangeResult();
        r.success = false;

        if (String.isBlank(bookingSegmentId)) {
            r.message = 'Booking segment id is required.';
            return r;
        }
        if (String.isBlank(newSeatNumber)) {
            r.message = 'A seat selection is required.';
            return r;
        }
        if (!isValidSeatFormat(newSeatNumber)) {
            r.message = 'Invalid seat format. Please use format like 12A, 15C, etc.';
            return r;
        }

        try {
            return new GuestSeatWriter().write(bookingSegmentId, newSeatNumber.toUpperCase());
        } catch (Exception e) {
            r.message = 'Seat change failed: ' + e.getMessage();
            System.debug('confirmSeatChange error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return r;
        }
    }

    /**
     * `without sharing` writer so the ESW guest user can persist the
     * seat regardless of record sharing. Delegates the actual update +
     * monitor publish to Skywave_BookingEngine — single source of truth
     * shared with the website's seat-change path.
     */
    private without sharing class GuestSeatWriter {
        public SeatChangeResult write(String segmentId, String newSeat) {
            SeatChangeResult r = new SeatChangeResult();
            r.success = false;
            Skywave_BookingEngine.SeatChangeResult er =
                Skywave_BookingEngine.changeSeatBySegmentId(segmentId, newSeat);
            if (!er.success) {
                r.message = String.isNotBlank(er.errorMessage)
                    ? er.errorMessage
                    : 'Seat change failed: ' + er.errorCode;
                return r;
            }
            r.success = true;
            r.bookingCode = er.bookingCode;
            r.flightNumber = er.flightNumber;
            r.seatNumber = er.newSeat;
            r.oldSeat = er.oldSeat;
            r.message = 'Seat changed to ' + er.newSeat;
            return r;
        }
    }

    /** Result shape for the imperative LWC path (@AuraEnabled-serialisable). */
    public class SeatChangeResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String bookingCode;
        @AuraEnabled public String flightNumber;
        @AuraEnabled public String seatNumber;
        @AuraEnabled public String oldSeat;
    }

    private static Result executeSeatChange(Request req) {
        Result r = new Result();

        // If the agent passed a specific seat → engine handles validation +
        // class-aware update. If only a preference, derive a seat from the
        // booked fare class first, then send through the engine.
        String newSeat = req.newSeatNumber;
        if (String.isBlank(newSeat) && String.isNotBlank(req.seatPreference)) {
            // Resolve the booked fare class + flight for sensible auto-pick.
            List<Booking_Segment__c> segs = [
                SELECT Id, Flight__c, Booking__r.Fare_Class__c
                FROM Booking_Segment__c
                WHERE Id = :req.bookingSegmentId LIMIT 1
            ];
            if (segs.isEmpty()) {
                r.success = false;
                r.errorMessage = 'Booking segment not found';
                return r;
            }
            Booking_Segment__c seg = segs[0];
            newSeat = Skywave_BookingEngine.autoSeat(
                seg.Flight__c, seg.Booking__r.Fare_Class__c, normalizePreference(req.seatPreference));
        }
        if (String.isBlank(newSeat)) {
            r.success = false;
            r.errorMessage = 'Please provide either a specific seat number or a seat preference';
            return r;
        }

        Skywave_BookingEngine.SeatChangeResult er =
            Skywave_BookingEngine.changeSeatBySegmentId(req.bookingSegmentId, newSeat);
        if (!er.success) {
            r.success = false;
            r.errorMessage = String.isNotBlank(er.errorMessage)
                ? er.errorMessage : 'Seat change failed: ' + er.errorCode;
            return r;
        }
        r.success = true;
        SegmentInfo info = new SegmentInfo();
        info.segmentId = req.bookingSegmentId;
        info.flightNumber = er.flightNumber;
        info.aircraftType = null;  // not surfaced by the engine; agent doesn't need it
        info.oldSeat = er.oldSeat;
        info.newSeat = er.newSeat;
        info.message = 'Seat successfully changed from ' + er.oldSeat + ' to ' + er.newSeat;
        r.updatedSegment = info;
        return r;
    }

    private static String normalizePreference(String pref) {
        if (String.isBlank(pref)) return null;
        String lower = pref.toLowerCase();
        if (lower.contains('window')) return 'Window';
        if (lower.contains('aisle')) return 'Aisle';
        return null;
    }

    private static Boolean isValidSeatFormat(String seat) {
        Pattern seatPattern = Pattern.compile('^\\d{1,2}[A-Z]$');
        Matcher matcher = seatPattern.matcher(seat.toUpperCase());
        return matcher.matches();
    }

    private static SegmentInfo buildSegmentInfo(
        Booking_Segment__c segment,
        String oldSeat,
        String newSeat
    ) {
        SegmentInfo info = new SegmentInfo();
        info.segmentId = segment.Id;
        info.flightNumber = segment.Flight__r.Flight_Number__c;
        info.aircraftType = segment.Flight__r.Aircraft_Type__c;
        info.oldSeat = oldSeat;
        info.newSeat = newSeat;
        info.message = 'Seat successfully changed from ' + oldSeat + ' to ' + newSeat;
        return info;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='updated segment' description='Information about the seat change')
        public SegmentInfo updatedSegment;
    }

    public class SegmentInfo {
        @InvocableVariable(label='segment ID' description='The booking segment ID')
        public String segmentId;
        @InvocableVariable(label='flight number' description='The flight number')
        public String flightNumber;
        @InvocableVariable(label='aircraft type' description='The aircraft type')
        public String aircraftType;
        @InvocableVariable(label='old seat' description='The previous seat assignment')
        public String oldSeat;
        @InvocableVariable(label='new seat' description='The new seat assignment')
        public String newSeat;
        @InvocableVariable(label='message' description='Confirmation message')
        public String message;
    }
}
