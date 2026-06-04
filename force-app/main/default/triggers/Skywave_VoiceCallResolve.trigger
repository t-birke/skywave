/**
 * Before-insert on VoiceCall: resolve the inbound caller to the freshest
 * matching Contact (digit-only phone match) and stamp Contact__c + caller name
 * fields, so the Skywave voice agent greets by name and loads real context.
 * See Skywave_VoiceCallResolver for the matching rationale.
 */
trigger Skywave_VoiceCallResolve on VoiceCall (before insert) {
    Skywave_VoiceCallResolver.resolveCallers(Trigger.new);
}
