/**
 * Links the Admin User to Lauren Bailey's Contact record
 * 
 * This script:
 * 1. Queries for the current admin user
 * 2. Queries for Lauren Bailey's Contact record
 * 3. Updates User.ContactId to link them together
 * 
 * Run this script after createSampleData.apex has been executed
 */

System.debug('=== Linking Admin User to Lauren Bailey Contact ===');

try {
    // Step 1: Get the current admin user
    User adminUser = [SELECT Id, Username, Name FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
    System.debug('Admin User: ' + adminUser.Name + ' (' + adminUser.Username + ')');
    
    // Step 2: Query for Lauren Bailey's Contact
    List<Contact> contacts = [SELECT Id, FirstName, LastName, Email FROM Contact WHERE FirstName = 'Lauren' AND LastName = 'Bailey' LIMIT 1];
    
    if (contacts.isEmpty()) {
        System.debug('ERROR: Lauren Bailey contact not found. Please run createSampleData.apex first.');
        return;
    }
    
    Contact lauren = contacts[0];
    System.debug('Found Contact: ' + lauren.FirstName + ' ' + lauren.LastName + ' (' + lauren.Email + ')');
    
    // Step 3: Update User.ContactId to link to Lauren
    adminUser.ContactId = lauren.Id;
    update adminUser;
    
    System.debug('=== Link Complete ===');
    System.debug('Successfully linked User "' + adminUser.Name + '" to Contact "' + lauren.FirstName + ' ' + lauren.LastName + '"');
    System.debug('User.ContactId = ' + adminUser.ContactId);
    
} catch (Exception e) {
    System.debug('ERROR: ' + e.getMessage());
    System.debug('Stack Trace: ' + e.getStackTraceString());
    throw e;
}