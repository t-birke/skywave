/**
 * Seed the Skywave survey questions + answer options (Chapter 1 content).
 *
 * Idempotent: keyed on Question_Key__c / Option_Key__c, so re-running upserts in
 * place (safe to run on a populated org). Mirrors the AUTHORITATIVE si state as
 * of 2026-06-16, including the deliberate ACTIVE flags — note `fly_frequency`
 * (and its 4 options) are INACTIVE and must stay that way (the consumer site +
 * Skywave_SurveySchema only serve Active=true rows).
 *
 * Image URLs: set from %%SKYWAVE_HEROKU_ORIGIN%% (substituted by install.sh from
 * the resolved relay origin — every install has a different Heroku hash, so this
 * MUST NOT be hardcoded). Pattern: <origin>/assets/survey/<questionKey>-<optionKey>.jpg
 * (the 21 images ship in heroku/skywave-app/public/assets/survey/). If the
 * placeholder is left unsubstituted (running this file by hand without install.sh),
 * image URLs are left blank rather than pointing at a bogus host.
 *
 * Run: install.sh §1.12 (sf apex run --file), after SKYWAVE_HEROKU_ORIGIN substitution.
 */
String ORIGIN = '%%SKYWAVE_HEROKU_ORIGIN%%';
// If unsubstituted (manual run), don't write a junk host into Image_Url__c.
Boolean haveOrigin = ORIGIN.startsWith('http');
String IMG_BASE = haveOrigin ? (ORIGIN.removeEnd('/') + '/assets/survey/') : '';

// ── Authoritative content: {questionKey => {text, type, active, order, options[]}} ──
// options: list of [optionKey, optionText, active(0/1), order]
Map<String, Object> Q = new Map<String, Object>();

// Helper to assemble a question spec inline.
List<Object> trip = new List<Object>{
    new List<Object>{'beach','Toes in the sand',1,1},
    new List<Object>{'city','Lights that never sleep',1,2},
    new List<Object>{'mountain','Thin air and big peaks',1,3},
    new List<Object>{'cultural','Cobblestones and centuries',1,4},
    new List<Object>{'food','Where the food is the reason',1,5},
    new List<Object>{'megacity','Glass towers and ambition',1,6}
};
List<Object> dest = new List<Object>{
    new List<Object>{'europe','Old-world Europe',1,1},
    new List<Object>{'asia','The Far East',1,2},
    new List<Object>{'americas','The Americas',1,3},
    new List<Object>{'oceania','Down Under',1,4},
    new List<Object>{'africa','Wild Africa',1,5},
    new List<Object>{'mideast','Arabian crossroads',1,6}
};
List<Object> cabin = new List<Object>{
    new List<Object>{'first','In total comfort',1,1},
    new List<Object>{'business','With a little extra room',1,2},
    new List<Object>{'economy','Keeping it simple',1,3}
};
List<Object> freq = new List<Object>{   // INACTIVE question — kept for fidelity
    new List<Object>{'1y','Once a year',0,1},
    new List<Object>{'few','A few times',0,2},
    new List<Object>{'monthly','Monthly',0,3},
    new List<Object>{'weekly','Weekly',0,4}
};
List<Object> seat = new List<Object>{
    new List<Object>{'window','Window seat',1,1},
    new List<Object>{'aisle','Aisle seat',1,2}
};

// [questionKey, text, type, active(0/1), order, options]
List<Object> SPEC = new List<Object>{
    new List<Object>{'trip_type','What’s your vibe?','single_choice',1,1,trip},
    new List<Object>{'fav_destination','Which corner of the world is calling?','single_choice',1,2,dest},
    new List<Object>{'cabin_class','How do you like to arrive?','single_choice',1,3,cabin},
    new List<Object>{'fly_frequency','How often do you get away?','single_choice',0,3,freq},
    new List<Object>{'seat_pref','Your perfect seat?','single_choice',1,4,seat}
};

// ── Upsert questions (keyed on Question_Key__c) ─────────────────────────────
Map<String, Survey_Question__c> existingQ = new Map<String, Survey_Question__c>();
for (Survey_Question__c q : [SELECT Id, Question_Key__c FROM Survey_Question__c]) {
    existingQ.put(q.Question_Key__c, q);
}
List<Survey_Question__c> qUpserts = new List<Survey_Question__c>();
for (Object o : SPEC) {
    List<Object> r = (List<Object>) o;
    String key = (String) r[0];
    Survey_Question__c q = existingQ.containsKey(key) ? existingQ.get(key) : new Survey_Question__c(Question_Key__c = key);
    q.Question_Text__c = (String) r[1];
    q.Question_Type__c = (String) r[2];
    q.Active__c        = ((Integer) r[3]) == 1;
    q.Order__c         = (Integer) r[4];
    qUpserts.add(q);
}
upsert qUpserts Question_Key__c;

// Re-read to get Ids keyed by Question_Key__c (for option parenting).
Map<String, Id> qIdByKey = new Map<String, Id>();
for (Survey_Question__c q : [SELECT Id, Question_Key__c FROM Survey_Question__c]) {
    qIdByKey.put(q.Question_Key__c, q.Id);
}

// ── Insert/update options ───────────────────────────────────────────────────
// Option_Key__c is unique WITHIN a question (not globally) and is NOT an External
// Id, so we can't upsert-by-key. Dedup on the (questionKey:optionKey) pair via the
// parent lookup + Option_Key__c, and use plain insert/update.
Map<String, Survey_Answer_Option__c> existingO = new Map<String, Survey_Answer_Option__c>();
for (Survey_Answer_Option__c oo : [
        SELECT Id, Option_Key__c, Survey_Question__r.Question_Key__c
        FROM Survey_Answer_Option__c]) {
    String qk = oo.Survey_Question__r != null ? oo.Survey_Question__r.Question_Key__c : '';
    existingO.put(qk + ':' + oo.Option_Key__c, oo);
}
List<Survey_Answer_Option__c> oUpserts = new List<Survey_Answer_Option__c>();
for (Object o : SPEC) {
    List<Object> r = (List<Object>) o;
    String qKey = (String) r[0];
    Id qId = qIdByKey.get(qKey);
    for (Object oo2 : (List<Object>) r[5]) {
        List<Object> op = (List<Object>) oo2;
        String oKey = (String) op[0];
        String mapKey = qKey + ':' + oKey;
        Boolean isNew = !existingO.containsKey(mapKey);
        Survey_Answer_Option__c opt = isNew
            ? new Survey_Answer_Option__c(Option_Key__c = oKey)
            : existingO.get(mapKey);
        // Survey_Question__c is a NON-reparentable master-detail — settable only
        // on insert, not writeable on an existing row.
        if (isNew) {
            opt.Survey_Question__c = qId;
        }
        opt.Option_Text__c     = (String) op[1];
        opt.Active__c          = ((Integer) op[2]) == 1;
        opt.Order__c           = (Integer) op[3];
        if (haveOrigin) {
            opt.Image_Url__c = IMG_BASE + qKey + '-' + oKey + '.jpg';
        }
        oUpserts.add(opt);
    }
}
upsert oUpserts;

System.debug('Survey seed: ' + qUpserts.size() + ' questions, ' + oUpserts.size()
    + ' options. Images ' + (haveOrigin ? ('-> ' + IMG_BASE) : 'LEFT BLANK (no origin substituted)'));
