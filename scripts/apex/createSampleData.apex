/**
 * Sample Data Creation Script for Skywave Airlines
 * 
 * This script creates a complete set of sample data including:
 * - Lauren Bailey contact with Gold loyalty tier
 * - Flight master schedule
 * - Reservations with segments for Lauren
 * 
 * Run this script in Anonymous Apex after deploying the metadata
 */

System.debug('=== Starting Skywave Airlines Sample Data Creation ===');

try {
    // Step 1: Create Lauren Bailey Contact
    System.debug('Creating Lauren Bailey contact...');
    List<Contact> contacts = GenerateDemoData.createContacts();
    insert contacts;
    System.debug('Created ' + contacts.size() + ' contact: ' + contacts[0].FirstName + ' ' + contacts[0].LastName);
    
    // Step 2: Create Flight Schedule
    System.debug('Creating flight schedule...');
    List<Flight__c> flights = GenerateDemoData.createFlights();
    insert flights;
    System.debug('Created ' + flights.size() + ' flights in master schedule');
    
    // Step 3: Create Reservations for Lauren
    System.debug('Creating reservations...');
    List<Reservation__c> reservations = GenerateDemoData.createReservations(contacts, flights, 2);
    insert reservations;
    System.debug('Created ' + reservations.size() + ' reservations for Lauren Bailey');
    
    // Step 4: Create Reservation Segments
    System.debug('Creating reservation segments...');
    List<Reservation_Segment__c> segments = GenerateDemoData.createReservationSegments(reservations, flights);
    insert segments;
    System.debug('Created ' + segments.size() + ' reservation segments');
    
    System.debug('=== Sample Data Creation Complete ===');
    System.debug('Summary:');
    System.debug('  - Contact: Lauren Bailey (Gold tier, Member #' + contacts[0].Member_Number__c + ')');
    System.debug('  - Flights: ' + flights.size());
    System.debug('  - Reservations: ' + reservations.size());
    System.debug('  - Segments: ' + segments.size());
    
    // Display confirmation codes
    System.debug('\nLauren Bailey\'s Confirmation Codes:');
    for (Reservation__c reservation : reservations) {
        System.debug('  - ' + reservation.Confirmation_Code__c);
    }
    
} catch (Exception e) {
    System.debug('ERROR: ' + e.getMessage());
    System.debug('Stack Trace: ' + e.getStackTraceString());
    throw e;
}