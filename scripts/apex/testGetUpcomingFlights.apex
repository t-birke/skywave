// Test Skywave_GetUpcomingFlights for ContactId 003di00000ia7xlAAA (Lauren Bailey)
List<String> contactIds = new List<String>{'003di00000ia7xlAAA'};
List<Skywave_GetUpcomingFlights.Result> results = Skywave_GetUpcomingFlights.getUpcomingFlights(contactIds);

// Display results
for (Skywave_GetUpcomingFlights.Result result : results) {
    System.debug('=== GET UPCOMING FLIGHTS RESULT ===');
    System.debug('Success: ' + result.success);
    System.debug('Imminent Flights: ' + result.imminentFlights);
    if (!result.success) {
        System.debug('Error Message: ' + result.errorMessage);
    }
    System.debug('===================================');
}