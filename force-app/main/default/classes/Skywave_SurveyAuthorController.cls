/**
 * Apex backing for the skywaveSurveyAuthor LWC.
 *
 * Three methods:
 *   - listQuestions(): all questions + their options, ordered.
 *   - saveQuestion(...): upsert one question and its options atomically.
 *     Options absent from the payload but present in the org for that
 *     question are deleted (lets the LWC drive deletes in-place).
 *   - deleteQuestion(id): cascades via master-detail.
 */
public with sharing class Skywave_SurveyAuthorController {

    public class OptionInput {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String optionText { get; set; }
        @AuraEnabled public String optionKey { get; set; }
        @AuraEnabled public String imageUrl { get; set; }
        @AuraEnabled public Decimal order { get; set; }
        @AuraEnabled public Boolean active { get; set; }
    }

    public class QuestionInput {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String questionText { get; set; }
        @AuraEnabled public String questionKey { get; set; }
        @AuraEnabled public String questionType { get; set; }
        @AuraEnabled public Decimal order { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public List<OptionInput> options { get; set; }
    }

    public class QuestionDTO {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String questionText { get; set; }
        @AuraEnabled public String questionKey { get; set; }
        @AuraEnabled public String questionType { get; set; }
        @AuraEnabled public Decimal order { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public List<OptionDTO> options { get; set; }
    }

    public class OptionDTO {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String optionText { get; set; }
        @AuraEnabled public String optionKey { get; set; }
        @AuraEnabled public String imageUrl { get; set; }
        @AuraEnabled public Decimal order { get; set; }
        @AuraEnabled public Boolean active { get; set; }
    }

    @AuraEnabled(cacheable=false)
    public static List<QuestionDTO> listQuestions() {
        List<QuestionDTO> out = new List<QuestionDTO>();
        for (Survey_Question__c q : [
            SELECT Id, Name, Question_Text__c, Question_Key__c, Question_Type__c, Order__c, Active__c,
                   (SELECT Id, Name, Option_Text__c, Option_Key__c, Image_Url__c, Order__c, Active__c
                    FROM Options__r
                    ORDER BY Order__c ASC NULLS LAST)
            FROM Survey_Question__c
            ORDER BY Order__c ASC NULLS LAST
        ]) {
            QuestionDTO qd = new QuestionDTO();
            qd.id = q.Id;
            qd.name = q.Name;
            qd.questionText = q.Question_Text__c;
            qd.questionKey = q.Question_Key__c;
            qd.questionType = q.Question_Type__c;
            qd.order = q.Order__c;
            qd.active = q.Active__c;
            qd.options = new List<OptionDTO>();
            for (Survey_Answer_Option__c opt : q.Options__r) {
                OptionDTO od = new OptionDTO();
                od.id = opt.Id;
                od.name = opt.Name;
                od.optionText = opt.Option_Text__c;
                od.optionKey = opt.Option_Key__c;
                od.imageUrl = opt.Image_Url__c;
                od.order = opt.Order__c;
                od.active = opt.Active__c;
                qd.options.add(od);
            }
            out.add(qd);
        }
        return out;
    }

    @AuraEnabled
    public static QuestionDTO saveQuestion(QuestionInput question) {
        if (question == null) throw new AuraHandledException('question payload is required');

        Survey_Question__c q;
        if (String.isBlank(question.id)) {
            q = new Survey_Question__c();
        } else {
            q = new Survey_Question__c(Id = question.id);
        }
        q.Question_Text__c = question.questionText;
        q.Question_Key__c = question.questionKey;
        q.Question_Type__c = String.isBlank(question.questionType) ? 'single_choice' : question.questionType;
        q.Order__c = question.order;
        q.Active__c = question.active == null ? true : question.active;
        upsert q;

        // Diff existing options against the payload — anything in the org but
        // not in the payload was removed by the user, so we delete it.
        Set<Id> incomingIds = new Set<Id>();
        for (OptionInput opt : question.options ?? new List<OptionInput>()) {
            if (String.isNotBlank(opt.id)) incomingIds.add((Id) opt.id);
        }
        List<Survey_Answer_Option__c> existing = [
            SELECT Id FROM Survey_Answer_Option__c WHERE Survey_Question__c = :q.Id
        ];
        List<Survey_Answer_Option__c> toDelete = new List<Survey_Answer_Option__c>();
        for (Survey_Answer_Option__c o : existing) {
            if (!incomingIds.contains(o.Id)) toDelete.add(o);
        }
        if (!toDelete.isEmpty()) delete toDelete;

        List<Survey_Answer_Option__c> toUpsert = new List<Survey_Answer_Option__c>();
        for (OptionInput opt : question.options ?? new List<OptionInput>()) {
            Survey_Answer_Option__c o;
            if (String.isBlank(opt.id)) {
                o = new Survey_Answer_Option__c();
            } else {
                o = new Survey_Answer_Option__c(Id = opt.id);
            }
            o.Survey_Question__c = q.Id;
            o.Option_Text__c = opt.optionText;
            o.Option_Key__c = opt.optionKey;
            o.Image_Url__c = opt.imageUrl;
            o.Order__c = opt.order;
            o.Active__c = opt.active == null ? true : opt.active;
            toUpsert.add(o);
        }
        if (!toUpsert.isEmpty()) upsert toUpsert;

        // Re-read so the LWC gets the canonical state.
        return loadOne(q.Id);
    }

    @AuraEnabled
    public static void deleteQuestion(Id questionId) {
        delete [SELECT Id FROM Survey_Question__c WHERE Id = :questionId];
    }

    @AuraEnabled
    public static QuestionDTO reorderQuestions(List<Id> orderedIds) {
        // Persists drag/up-down reorder by writing Order__c = position+1
        // for every id in the list. Returns the first one as a no-op
        // payload (LWC re-fetches the full list anyway).
        List<Survey_Question__c> upd = new List<Survey_Question__c>();
        Integer i = 1;
        for (Id qid : orderedIds) {
            upd.add(new Survey_Question__c(Id = qid, Order__c = i++));
        }
        if (!upd.isEmpty()) update upd;
        return upd.isEmpty() ? null : loadOne(upd[0].Id);
    }

    private static QuestionDTO loadOne(Id qid) {
        Survey_Question__c q = [
            SELECT Id, Name, Question_Text__c, Question_Key__c, Question_Type__c, Order__c, Active__c,
                   (SELECT Id, Name, Option_Text__c, Option_Key__c, Image_Url__c, Order__c, Active__c
                    FROM Options__r
                    ORDER BY Order__c ASC NULLS LAST)
            FROM Survey_Question__c
            WHERE Id = :qid
            LIMIT 1
        ];
        QuestionDTO qd = new QuestionDTO();
        qd.id = q.Id;
        qd.name = q.Name;
        qd.questionText = q.Question_Text__c;
        qd.questionKey = q.Question_Key__c;
        qd.questionType = q.Question_Type__c;
        qd.order = q.Order__c;
        qd.active = q.Active__c;
        qd.options = new List<OptionDTO>();
        for (Survey_Answer_Option__c opt : q.Options__r) {
            OptionDTO od = new OptionDTO();
            od.id = opt.Id;
            od.name = opt.Name;
            od.optionText = opt.Option_Text__c;
            od.optionKey = opt.Option_Key__c;
            od.imageUrl = opt.Image_Url__c;
            od.order = opt.Order__c;
            od.active = opt.Active__c;
            qd.options.add(od);
        }
        return qd;
    }
}
