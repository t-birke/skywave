public class Skywave_ChangeSeat {

    public class Request {
        @InvocableVariable(label='Reservation Segment ID' description='The Reservation Segment ID to change seat for' required=true)
        public String reservationSegmentId;
        
        @InvocableVariable(label='New Seat Number' description='The desired seat number (e.g., 12A)')
        public String newSeatNumber;
        
        @InvocableVariable(label='Seat Preference' description='Seat preference if no specific seat: Window, Aisle, or Middle')
        public String seatPreference;
    }

    @InvocableMethod(label='Change Seat' description='Changes the seat assignment for a reservation segment')
    public static List<Result> changeSeat(List<Request> requests) {
        List<Result> results = new List<Result>();
        
        for (Request req : requests) {
            results.add(executeSeatChange(req));
        }
        
        return results;
    }
    
    private static Result executeSeatChange(Request req) {
        Result r = new Result();
        
        try {
            // Query the reservation segment
            Reservation_Segment__c segment = [
                SELECT Id, Seat_Number__c, Reservation__c, Reservation__r.Status__c,
                       Flight__c, Flight__r.Flight_Number__c, Flight__r.Aircraft_Type__c
                FROM Reservation_Segment__c
                WHERE Id = :req.reservationSegmentId
                LIMIT 1
            ];
            
            // Validate reservation is active
            if (segment.Reservation__r.Status__c != 'Confirmed') {
                r.success = false;
                r.errorMessage = 'Cannot change seat for a reservation that is not confirmed';
                return r;
            }
            
            // Determine the new seat
            String newSeat;
            if (String.isNotBlank(req.newSeatNumber)) {
                // Validate seat format (basic validation)
                if (!isValidSeatFormat(req.newSeatNumber)) {
                    r.success = false;
                    r.errorMessage = 'Invalid seat format. Please use format like 12A, 15C, etc.';
                    return r;
                }
                newSeat = req.newSeatNumber.toUpperCase();
            } else if (String.isNotBlank(req.seatPreference)) {
                // Assign based on preference
                newSeat = assignSeatByPreference(req.seatPreference);
            } else {
                r.success = false;
                r.errorMessage = 'Please provide either a specific seat number or a seat preference';
                return r;
            }
            
            // Update the seat
            String oldSeat = segment.Seat_Number__c;
            segment.Seat_Number__c = newSeat;
            update segment;
            
            // Build success response
            r.success = true;
            r.updatedSegment = buildSegmentInfo(segment, oldSeat, newSeat);
            
        } catch (QueryException e) {
            r.success = false;
            r.errorMessage = 'Reservation segment not found';
            System.debug('Seat change error: ' + e.getMessage());
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Seat change failed: ' + e.getMessage();
            System.debug('Seat change error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        
        return r;
    }
    
    private static Boolean isValidSeatFormat(String seat) {
        // Basic validation: should be 1-2 digits followed by a letter
        Pattern seatPattern = Pattern.compile('^\\d{1,2}[A-Z]$');
        Matcher matcher = seatPattern.matcher(seat.toUpperCase());
        return matcher.matches();
    }
    
    private static String assignSeatByPreference(String preference) {
        // Generate a seat based on preference
        Integer row = 10 + Math.mod(Math.abs(Crypto.getRandomInteger()), 20); // Rows 10-29
        String seat;
        
        if (preference.toLowerCase().contains('window')) {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'A' : 'F';
        } else if (preference.toLowerCase().contains('aisle')) {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'C' : 'D';
        } else if (preference.toLowerCase().contains('middle')) {
            seat = Math.mod(Math.abs(Crypto.getRandomInteger()), 2) == 0 ? 'B' : 'E';
        } else {
            // Default to random
            List<String> seats = new List<String>{'A', 'B', 'C', 'D', 'E', 'F'};
            seat = seats[Math.mod(Math.abs(Crypto.getRandomInteger()), seats.size())];
        }
        
        return String.valueOf(row) + seat;
    }
    
    private static SegmentInfo buildSegmentInfo(
        Reservation_Segment__c segment,
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
        @InvocableVariable(label='segment ID' description='The reservation segment ID')
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