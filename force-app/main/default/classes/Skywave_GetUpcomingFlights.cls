public class Skywave_GetUpcomingFlights {

    @InvocableMethod(label='Get Upcoming Flights' description='Gets flights for the contact within the next 72 hours')
    public static List<Result> getUpcomingFlights(List<String> contactId) {
        List<Result> results = new List<Result>();
        
        for (String contact : contactId) {
            results.add(getFlightsForContact(contact));
        }
        
        return results;
    }
    
    private static Result getFlightsForContact(String contactId) {
        Result r = new Result();
        
        try {
            // Calculate 72-hour window
            DateTime now = DateTime.now();
            DateTime cutoff = now.addHours(72);
            
            // Query for confirmed bookings with segments departing within 72 hours
            List<Booking__c> upcomingBookings = [
                SELECT Id, Name, Confirmation_Code__c,
                       (SELECT Id, Departure_DateTime__c
                        FROM Booking_Segments__r
                        WHERE Segment_Status__c = 'Scheduled'
                          AND Departure_DateTime__c >= :now
                          AND Departure_DateTime__c <= :cutoff
                        ORDER BY Departure_DateTime__c)
                FROM Booking__c
                WHERE Contact__c = :contactId
                  AND Status__c = 'Confirmed'
                  AND Id IN (SELECT Booking__c
                            FROM Booking_Segment__c
                            WHERE Segment_Status__c = 'Scheduled'
                              AND Departure_DateTime__c >= :now
                              AND Departure_DateTime__c <= :cutoff)
            ];

            // Count total segments (flights) within the window
            Integer flightCount = 0;
            for (Booking__c booking : upcomingBookings) {
                flightCount += booking.Booking_Segments__r.size();
            }
            
            r.success = true;
            r.imminentFlights = flightCount;
            
        } catch (Exception e) {
            r.success = false;
            r.errorMessage = 'Error getting upcoming flights: ' + e.getMessage();
            r.imminentFlights = 0;
            System.debug('Error in getUpcomingFlights: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
        
        return r;
    }

    public class Result {
        @InvocableVariable(required=true label='success' description='true if the action completed without error')
        public Boolean success;
        @InvocableVariable(label='error message' description='details in case of an error')
        public String errorMessage;
        @InvocableVariable(label='imminent flights' description='flights within the next 72 hours')
        public Integer imminentFlights;
    }
}
