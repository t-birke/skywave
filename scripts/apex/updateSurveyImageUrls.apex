// Repoint every Survey_Answer_Option__c.Image_Url__c at the Skywave-served
// images on Heroku. Replaces the legacy Unsplash CDN URLs with our
// nano-banana generated set, served from
// https://skywave-app-bb0e8666933b.herokuapp.com/assets/survey/<q>-<o>.jpg.
//
// Idempotent — re-runnable any time we regenerate the images. Keys on
// (Question_Key__c, Option_Key__c) so adding/removing options in either
// place is safe.

final String BASE = 'https://skywave-app-bb0e8666933b.herokuapp.com/assets/survey/';

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
