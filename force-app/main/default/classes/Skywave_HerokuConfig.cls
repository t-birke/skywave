/**
 * Single source of truth for the Heroku relay origin.
 *
 * The dyno URL carries a per-app random suffix that Heroku assigns at create
 * time (e.g. https://skywave-app-<hash>.herokuapp.com), so it differs in
 * every install. Rather than hardcode it in N places, it lives once in
 * Skywave_Preflight_Config.Default.Heroku_Origin_Url__c — written by
 * install.sh (Tier 3) after the app is provisioned — and every consumer reads
 * it through here.
 *
 * Consumers: Skywave_SessionStart (WS url), skywaveDemoMonitor (QR target via
 * Skywave_DemoMonitorController.getHerokuOrigin), Skywave_PreflightController
 * (loads the same CMD directly for its callout).
 */
public with sharing class Skywave_HerokuConfig {

    /** HTTPS origin with no trailing slash, or '' if not yet configured. */
    public static String originUrl() {
        List<Skywave_Preflight_Config__mdt> rows = [
            SELECT Heroku_Origin_Url__c
            FROM Skywave_Preflight_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        if (rows.isEmpty() || String.isBlank(rows[0].Heroku_Origin_Url__c)) return '';
        return rows[0].Heroku_Origin_Url__c.removeEnd('/');
    }

    /**
     * The PUBLIC origin visitors actually reach the consumer site on — the
     * custom domain (e.g. https://app.skywave.flights) when one fronts the
     * dyno, else the raw Heroku origin. This is what the join-QR must encode:
     * phones have to land on the SAME origin the Heroku CORS gate
     * (SKYWAVE_PUBLIC_ORIGIN) allows, or their POSTs (session/peek, session/init)
     * are 403'd and a returning visitor is misclassified as new. Falls back to
     * originUrl() when Public_Site_Url__c is blank (single-origin installs).
     */
    public static String publicSiteUrl() {
        List<Skywave_Preflight_Config__mdt> rows = [
            SELECT Public_Site_Url__c
            FROM Skywave_Preflight_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        if (!rows.isEmpty() && String.isNotBlank(rows[0].Public_Site_Url__c)) {
            return rows[0].Public_Site_Url__c.removeEnd('/');
        }
        return originUrl();
    }
}
