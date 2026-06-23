/**
 * Backing for the skywaveReleaseNotes LWC (the Demo Home changelog panel).
 * Returns the most recent Release_Note__c rows, newest first. Records are
 * written by the release-notes GitHub Action on each GitHub Release.
 */
public with sharing class Skywave_ReleaseNotesController {

    public class ReleaseNote {
        @AuraEnabled public String version { get; set; }
        @AuraEnabled public Datetime releaseDate { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String notes { get; set; }
        @AuraEnabled public String url { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<ReleaseNote> getRecentReleases() {
        List<ReleaseNote> out = new List<ReleaseNote>();
        for (Release_Note__c r : [
            SELECT Version__c, Release_Date__c, Title__c, Notes__c, GitHub_Url__c
            FROM Release_Note__c
            ORDER BY Release_Date__c DESC NULLS LAST
            LIMIT 10
        ]) {
            ReleaseNote n = new ReleaseNote();
            n.version = r.Version__c;
            n.releaseDate = r.Release_Date__c;
            n.title = r.Title__c;
            n.notes = r.Notes__c;
            n.url = r.GitHub_Url__c;
            out.add(n);
        }
        return out;
    }
}
