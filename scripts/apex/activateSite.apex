// Check Experience Site status and provide activation guidance
// Usage: Update NETWORK_ID before running
String networkId = 'NETWORK_ID_PLACEHOLDER';

try {
    // Get community info
    ConnectApi.Community comm = ConnectApi.Communities.getCommunity(networkId);
    System.debug('=== SITE INFO ===');
    System.debug('Name: ' + comm.name);
    System.debug('ID: ' + comm.id);
    System.debug('Status: ' + comm.status);
    System.debug('URL: ' + comm.siteUrl);
    
    if (comm.status == ConnectApi.CommunityStatus.Live) {
        System.debug('=== RESULT ===');
        System.debug('SUCCESS: Site is already Live!');
    } else {
        System.debug('=== RESULT ===');
        System.debug('MANUAL_ACTIVATION_NEEDED: Site status is ' + comm.status);
        System.debug('The ConnectApi does not provide a method to activate sites programmatically.');
        System.debug('Manual activation required via UI:');
        System.debug('  Setup → Digital Experiences → All Sites → ' + comm.name + ' → Activate');
    }
    
} catch (Exception e) {
    System.debug('=== ERROR ===');
    System.debug('Could not access community: ' + e.getMessage());
    System.debug('Stack trace: ' + e.getStackTraceString());
}
