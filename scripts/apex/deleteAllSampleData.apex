/**
 * Delete all sample data created by createSampleData.apex
 * Run this before re-creating sample data
 */

System.debug('=== Deleting All Sample Data ===');

try {
    // Delete in reverse dependency order
    
    // Step 1: Delete Reservation Segments
    List<Reservation_Segment__c> segments = [SELECT Id FROM Reservation_Segment__c];
    if (!segments.isEmpty()) {
        delete segments;
        System.debug('Deleted ' + segments.size() + ' reservation segments');
    }
    
    // Step 2: Delete Reservations
    List<Reservation__c> reservations = [SELECT Id FROM Reservation__c];
    if (!reservations.isEmpty()) {
        delete reservations;
        System.debug('Deleted ' + reservations.size() + ' reservations');
    }
    
    // Step 3: Delete Contacts (with Member Numbers starting with SW)
    List<Contact> contacts = [SELECT Id FROM Contact WHERE Member_Number__c LIKE 'SW%'];
    if (!contacts.isEmpty()) {
        delete contacts;
        System.debug('Deleted ' + contacts.size() + ' contacts');
    }
    
    // Step 4: Delete Flights (with Flight Numbers starting with SW)
    List<Flight__c> flights = [SELECT Id FROM Flight__c WHERE Flight_Number__c LIKE 'SW%'];
    if (!flights.isEmpty()) {
        delete flights;
        System.debug('Deleted ' + flights.size() + ' flights');
    }
    
    System.debug('=== Sample Data Deletion Complete ===');
    
} catch (Exception e) {
    System.debug('ERROR: ' + e.getMessage());
    System.debug('Stack Trace: ' + e.getStackTraceString());
    throw e;
}