// Repoint every Survey_Answer_Option__c.Image_Url__c at the Skywave-served
// images on Heroku (nano-banana generated set), served from
// <origin>/assets/survey/<q>-<o>.jpg.
//
// %%SKYWAVE_HEROKU_ORIGIN%% is substituted by install.sh from the resolved dyno
// origin — every install's Heroku hash differs, so it is NEVER hardcoded. To run
// by hand, replace the placeholder with your dyno origin first.
//
// Idempotent — re-runnable any time we regenerate the images. Keys on
// (Question_Key__c, Option_Key__c) so adding/removing options in either
// place is safe.

final String ORIGIN = '%%SKYWAVE_HEROKU_ORIGIN%%';
final String BASE = ORIGIN.removeEnd('/') + '/assets/survey/';

List<Survey_Answer_Option__c> opts = [
    SELECT Id, Option_Key__c, Image_Url__c,
           Survey_Question__r.Question_Key__c
    FROM Survey_Answer_Option__c
    WHERE Survey_Question__r.Active__c = true
];

List<Survey_Answer_Option__c> toUpdate = new List<Survey_Answer_Option__c>();
for (Survey_Answer_Option__c o : opts) {
    String qk = o.Survey_Question__r.Question_Key__c;
    String ok = o.Option_Key__c;
    if (String.isBlank(qk) || String.isBlank(ok)) continue;
    String wanted = BASE + qk + '-' + ok + '.jpg';
    if (o.Image_Url__c != wanted) {
        o.Image_Url__c = wanted;
        toUpdate.add(o);
    }
}

if (!toUpdate.isEmpty()) {
    update toUpdate;
}
System.debug('updated ' + toUpdate.size() + ' of ' + opts.size() + ' options');
