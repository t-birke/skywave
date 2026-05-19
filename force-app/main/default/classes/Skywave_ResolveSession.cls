/**
 * Resolves Skywave's anonymous deviceId (Session_ID, captured by the
 * Skywave_Channel hidden prechat parameter and persisted to
 * MessagingSession.Session_ID__c) into the survey-answer history the
 * agent can use to personalise its first turn.
 *
 * Wired as an action on the Skywave_Airlines_Agent flight-booking topic.
 * The agent reads `summary` for natural-language reasoning and
 * `responsesJson` for structured access if it needs to.
 *
 * Implementation notes:
 *   - Queries Survey_Response__dlm via ConnectApi.CdpQuery.queryAnsiSqlV2
 *     (no callout, no Named Credential — runs in the agent's session
 *     context).
 *   - Multiple answers per question (re-takes) are deduped to MOST RECENT
 *     by EventDateTime__c.
 *   - Returns silently with empty results if the deviceId has no answers
 *     (anonymous sessions, demo without survey, etc.).
 */
public with sharing class Skywave_ResolveSession {

    public class Input {
        @InvocableVariable(label='Session ID (deviceId)' required=true)
        public String sessionId;
    }

    public class Output {
        @InvocableVariable(label='Number of answers found')
        public Integer answerCount;

        @InvocableVariable(label='Question/answer pairs as JSON')
        public String responsesJson;

        @InvocableVariable(label='Natural-language summary for agent reasoning')
        public String summary;
    }

    @InvocableMethod(
        label='Skywave: Resolve session context'
        description='Look up the visitor\'s declared survey answers from Data Cloud using the deviceId. Returns a JSON map of question→answer pairs and a one-line natural-language summary.'
        category='Skywave'
    )
    public static List<Output> resolve(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input request : inputs) {
            outs.add(resolveOne(request.sessionId));
        }
        return outs;
    }

    private static Output resolveOne(String sessionId) {
        Output out = new Output();
        out.answerCount = 0;
        out.responsesJson = '{}';
        out.summary = '';

        if (String.isBlank(sessionId)) {
            return out;
        }

        // Get the latest answer per QuestionKey for this deviceId. SQL on the
        // DLM directly — Survey_Response is not part of the data graph yet
        // (Phase 4 task to add it). The DMO has multiple rows per question
        // when the user re-took the survey; we keep only the most recent.
        String escapedId = sessionId.replace('\'', '\'\'');
        String sql =
            'SELECT QuestionKey__c, QuestionText__c, AnswerText__c, AnswerKey__c, EventDateTime__c ' +
            'FROM Survey_Response__dlm ' +
            'WHERE DeviceId__c = \'' + escapedId + '\' ' +
            'ORDER BY EventDateTime__c DESC';

        ConnectApi.CdpQueryOutputV2 resp;
        try {
            ConnectApi.CdpQueryInput req = new ConnectApi.CdpQueryInput();
            req.sql = sql;
            resp = ConnectApi.CdpQuery.queryAnsiSqlV2(req);
        } catch (Exception e) {
            // Don't fail the agent action; return empty so the agent
            // falls back to asking the user.
            System.debug(LoggingLevel.WARN, 'Skywave_ResolveSession: query failed: ' + e.getMessage());
            return out;
        }

        if (resp == null || resp.data == null || resp.data.isEmpty()) {
            return out;
        }

        // Each row is a CdpQueryV2Row whose JSON form is a positional array
        // ["QuestionKey__c","QuestionText__c","AnswerText__c","AnswerKey__c","EventDateTime__c"]
        // matching the SELECT column order above.
        Map<String, Map<String, String>> latestByKey = new Map<String, Map<String, String>>();
        for (ConnectApi.CdpQueryV2Row row : resp.data) {
            List<Object> cols = (List<Object>) JSON.deserializeUntyped(JSON.serialize(row));
            if (cols == null || cols.size() < 4) continue;
            String qKey = (String) cols.get(0);
            if (String.isBlank(qKey) || latestByKey.containsKey(qKey)) {
                continue;   // first row wins — already sorted DESC by EventDateTime
            }
            latestByKey.put(qKey, new Map<String, String>{
                'questionText' => (String) cols.get(1),
                'answerText'   => (String) cols.get(2),
                'answerKey'    => (String) cols.get(3)
            });
        }

        if (latestByKey.isEmpty()) {
            return out;
        }

        out.answerCount = latestByKey.size();
        out.responsesJson = JSON.serialize(latestByKey);

        // Natural-language summary. The agent uses this directly for
        // reasoning — phrased as an observation, not a directive.
        List<String> phrases = new List<String>();
        for (String qKey : latestByKey.keySet()) {
            Map<String, String> r = latestByKey.get(qKey);
            phrases.add(r.get('questionText') + ' → ' + r.get('answerText'));
        }
        out.summary = 'The visitor previously answered: ' + String.join(phrases, '; ') + '.';

        return out;
    }
}
