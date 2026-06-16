/**
 * Set Skywave_Preflight_Config__mdt.Default.Preflight_Key__c in the org to match
 * the Heroku PREFLIGHT_KEY config var, via the native Metadata API (anonymous
 * Apex — no MetadataService library needed). The key is a SECRET and is NOT
 * committed to the CMD XML in source (ARCHITECTURE §3g); install.sh substitutes
 * %%PREFLIGHT_KEY%% from .secrets/preflight.key at run time.
 *
 * Without this, Skywave_PreflightController's callout sends a key the dyno
 * rejects → the Preflight "Check Demo" tab's relay checks fail. Idempotent:
 * re-deploying the same CMD value is a no-op.
 *
 * Run: install.sh Tier 3, after setting the PREFLIGHT_KEY Heroku config var.
 */
String key = '%%PREFLIGHT_KEY%%';
if (String.isBlank(key) || key.startsWith('%%')) {
    System.debug('setPreflightKey: no key substituted — skipping (run via install.sh with .secrets/preflight.key present).');
} else {
    Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
    cmd.fullName = 'Skywave_Preflight_Config.Default';   // <type>.<recordDevName>
    cmd.label = 'Default';

    Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
    v.field = 'Preflight_Key__c';
    v.value = key;
    cmd.values.add(v);

    Metadata.DeployContainer container = new Metadata.DeployContainer();
    container.addMetadata(cmd);
    // Fire-and-forget async deploy; no callback needed for a single-field set.
    Metadata.Operations.enqueueDeployment(container, null);
    System.debug('setPreflightKey: enqueued CMD deploy for Preflight_Key__c.');
}
