/**
 * GET /services/apexrest/skywave/survey/schema
 *
 * Returns active survey questions + their active options, ordered for the
 * consumer site to render. Single query (parent + child) — schema is
 * small (a handful of questions) so we don't paginate.
 *
 * Response shape:
 * {
 *   "questions": [
 *     { "key": "fav_destination",
 *       "text": "Where would you fly?",
 *       "type": "single_choice",
 *       "options": [
 *         { "key": "tyo", "text": "Tokyo", "imageUrl": "https://..." },
 *         ...
 *       ]
 *     },
 *     ...
 *   ]
 * }
 */
@RestResource(urlMapping='/skywave/survey/schema')
global without sharing class Skywave_SurveySchema {

    public class OptionDTO {
        public String key;
        public String text;
        public String imageUrl;
    }

    public class QuestionDTO {
        public String key;
        public String text;
        public String type;
        public List<OptionDTO> options;
    }

    public class SchemaDTO {
        public List<QuestionDTO> questions;
    }

    @HttpGet
    global static void get() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        SchemaDTO out = new SchemaDTO();
        out.questions = new List<QuestionDTO>();

        for (Survey_Question__c q : [
            SELECT Id, Question_Text__c, Question_Key__c, Question_Type__c, Order__c,
                   (SELECT Option_Text__c, Option_Key__c, Image_Url__c, Order__c
                    FROM Options__r
                    WHERE Active__c = true
                    ORDER BY Order__c ASC NULLS LAST)
            FROM Survey_Question__c
            WHERE Active__c = true
            ORDER BY Order__c ASC NULLS LAST
        ]) {
            QuestionDTO qd = new QuestionDTO();
            qd.key = q.Question_Key__c;
            qd.text = q.Question_Text__c;
            qd.type = q.Question_Type__c;
            qd.options = new List<OptionDTO>();
            for (Survey_Answer_Option__c opt : q.Options__r) {
                OptionDTO od = new OptionDTO();
                od.key = opt.Option_Key__c;
                od.text = opt.Option_Text__c;
                od.imageUrl = opt.Image_Url__c;
                qd.options.add(od);
            }
            out.questions.add(qd);
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(out));
    }
}
