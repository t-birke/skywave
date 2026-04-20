public class DemoSetup {

    public static Map<String, Object> run() {
        Map<String, Object> results = new Map<String, Object>();

        // Step 1: Activate Messaging Channel
        try {
            MessagingChannel channel = [
                SELECT Id, IsActive
                FROM MessagingChannel
                WHERE DeveloperName = 'Skywave_MIAW'
                LIMIT 1
            ];
            if (!channel.IsActive) {
                channel.IsActive = true;
                update channel;
                results.put('messagingChannel', 'Activated');
            } else {
                results.put('messagingChannel', 'Already active');
            }
        } catch (Exception e) {
            results.put('messagingChannel', 'FAILED: ' + e.getMessage());
        }

        // Step 2: Verify OmniChannel Queue
        try {
            List<Group> queues = [
                SELECT Id, Name FROM Group
                WHERE Type = 'Queue' AND DeveloperName = 'Skywave_Messaging'
            ];
            if (!queues.isEmpty()) {
                results.put('omniChannelQueue', 'Exists (ID: ' + queues[0].Id + ')');
            } else {
                results.put('omniChannelQueue', 'MISSING: Skywave_Messaging queue not found');
            }
        } catch (Exception e) {
            results.put('omniChannelQueue', 'FAILED: ' + e.getMessage());
        }

        return results;
    }
}
