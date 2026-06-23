@IsTest
private class Skywave_ReleaseNotesController_Test {

    @IsTest
    static void getRecentReleases_returnsNewestFirst() {
        insert new List<Release_Note__c>{
            new Release_Note__c(Version__c='1.0.0', Release_Date__c=Datetime.newInstance(2026,1,1,0,0,0),
                                Title__c='First', Notes__c='- feat: initial', GitHub_Url__c='https://example.com/r/1.0.0'),
            new Release_Note__c(Version__c='1.1.0', Release_Date__c=Datetime.newInstance(2026,2,1,0,0,0),
                                Title__c='Second', Notes__c='- fix: a bug')
        };

        List<Skywave_ReleaseNotesController.ReleaseNote> rows =
            Skywave_ReleaseNotesController.getRecentReleases();

        System.assertEquals(2, rows.size());
        System.assertEquals('1.1.0', rows[0].version, 'newest release first');
        System.assertEquals('1.0.0', rows[1].version);
        System.assertEquals('https://example.com/r/1.0.0', rows[1].url);
    }

    @IsTest
    static void getRecentReleases_emptyWhenNone() {
        System.assertEquals(0, Skywave_ReleaseNotesController.getRecentReleases().size());
    }
}
