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
     * seat regardless of record sharing. Reads the segment + parent
     * booking/flight, updates Seat_Number__c, and echoes back the
     * human-facing identifiers the LWC displays in its confirmation.
     */
    private without sharing class GuestSeatWriter {
        public SeatChangeResult write(String segmentId, String newSeat) {
            SeatChangeResult r = new SeatChangeResult();
            r.success = false;

            List<Booking_Segment__c> segs = [
                SELECT Id, Seat_Number__c,
                       Booking__r.Confirmation_Code__c, Booking__r.Status__c,
                       Booking__r.Contact__c, Booking__r.Contact__r.Session_Id__c,
                       Booking__r.Contact__r.Demo_Session__c,
                       Flight__r.Flight_Number__c
                FROM Booking_Segment__c
                WHERE Id = :segmentId
                LIMIT 1
            ];
            if (segs.isEmpty()) {
                r.message = 'Booking segment not found.';
                return r;
            }

            Booking_Segment__c seg = segs[0];
            r.oldSeat = seg.Seat_Number__c;
            seg.Seat_Number__c = newSeat;
            update seg;

            // Live monitor: append a seat badge to the visitor's bubble.
            // Best-effort — never blocks the seat change.
            try {
                String deviceId = seg.Booking__r.Contact__r != null
                    ? seg.Booking__r.Contact__r.Session_Id__c : null;
                Id demoSessionId = seg.Booking__r.Contact__r != null
                    ? seg.Booking__r.Contact__r.Demo_Session__c : null;
                if (String.isNotBlank(deviceId) && demoSessionId != null) {
                    Skywave_RestUtil.publishEvent(
                        'seat_changed',
                        deviceId,
                        demoSessionId,
                        new Map<String, Object>{
                            'seat'         => newSeat,
                            'oldSeat'      => r.oldSeat,
                            'flightNumber' => seg.Flight__r.Flight_Number__c,
                            'bookingCode'  => seg.Booking__r.Confirmation_Code__c
                        }
                    );
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'seat_changed publish skipped: ' + e.getMessage());
            }

            r.success = true;
            r.bookingCode = seg.Booking__r.Confirmation_Code__c;
            r.flightNumber = seg.Flight__r.Flight_Number__c;
            r.seatNumber = newSeat;
            r.message = 'Seat changed to ' + newSeat;
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

        try {
            Booking_Segment__c segment = [
                SELECT Id, Seat_Number__c, Booking__c, Booking__r.Status__c,
                       Flight__c, Flight__r.Flight_Number__c, Flight__r.Aircraft_Type__c
                FROM Booking_Segment__c
                WHERE Id = :req.bookingSegmentId
                LIMIT 1
            ];

            if (segment.Booking__r.Status__c != 'Confirmed') {
                r.success = false;
                r.errorMessage = 'Cannot change seat for a booking that is not confirmed';
                return r;
            }

            String newSeat;
            if (String.isNotBlank(req.newSeatNumber)) {
                if (!isValidSeatFormat(req.newSeatNumber)) {
                    r.success = false;
                    r.errorMessage = 'Invalid seat format. Please use format like 12A, 15C, etc.';
                    return r;
                }
                newSeat = req.newSeatNumber.toUpperCase();
            } else if (String.isNotBlank(req.seatPreference)) {
                newSeat = assignSeatByPreference(req.seatPreference);
            } else {
                r.success = false;
                r.errorMessage = 'Please provide either a specific seat number or a seat preference';
                return r;
            }

            String oldSeat = segment.Seat_Number__c;
            segment.Seat_Number__c = newSeat;
            update segment;

            r.success = true;
            r.updatedSegment = buildSegmentInfo(segment, oldSeat, newSeat);

        } catch (QueryException e) {
            r.success = false;
            r.errorMessage = 'Booking segment not found';
            System.debug('Seat change error: ' + e.getMessage());
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Seat change failed: ' + e.getMessage();
            System.debug('Seat change error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }

        return r;
    }

    private static Boolean isValidSeatFormat(String seat) {
        Pattern seatPattern = Pattern.compile('^\\d{1,2}[A-Z]$');
        Matcher matcher = seatPattern.matcher(seat.toUpperCase());
        return matcher.matches();
    }

    private static String assignSeatByPreference(String preference) {
        Integer row = 10 + Math.mod(Math.abs(Crypto.getRandomInteger()), 20);
        String seat;

        if (preference.toLowerCase().contains('window')) {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'A' : 'F';
        } else if (preference.toLowerCase().contains('aisle')) {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'C' : 'D';
        } else if (preference.toLowerCase().contains('middle')) {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'B' : 'E';
        } else {
            List<String> seats = new List<String>{'A', 'B', 'C', 'D', 'E', 'F'};
            seat = seats[Math.mod(Math.abs(Crypto.getRandomInteger()), seats.size())];
        }

        return String.valueOf(row) + seat;
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
