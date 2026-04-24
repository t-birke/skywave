// Activate the Skywave_Channel messaging channel. IsActive is read-only via
// Metadata API so this has to be an Apex DML update. The channel's routing is
// wired at metadata-deploy time (sessionHandlerType=Flow → Skywave_Route_to_Agent
// → BotDefinition.Id). Idempotent.
MessagingChannel channel = [SELECT Id, IsActive FROM MessagingChannel WHERE DeveloperName = 'Skywave_Channel' LIMIT 1];
if (!channel.IsActive) {
    channel.IsActive = true;
    update channel;
    System.debug('Activated MessagingChannel: ' + channel.Id);
} else {
    System.debug('MessagingChannel already active: ' + channel.Id);
}
