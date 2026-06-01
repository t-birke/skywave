/**
 * Phase 4.5 Observability seeder.
 *
 * Repopulates the SDO_Agentforce_Observability QBrix custom objects
 * with Skywave-branded synthetic sessions. The QBrix ships pre-loaded
 * with DriveMax (auto-industry) demo data; we wipe that and replace
 * with airline traces matching Skywave_Airlines_Agent so Chapter 6's
 * Optimization tab pops with the right brand and the right "seat-change
 * underperforms" aggregate.
 *
 * Invocation:
 *
 *   Database.executeBatch(new Skywave_ObservabilityWipe(), 2000);
 *   // wait for the chained batch to finish (~5 min), then:
 *   System.enqueueJob(new Skywave_ObservabilitySeeder.SeedJob(80));
 *
 * After both jobs complete, refresh the eleven SDO_Analytics_*_Home
 * data streams (Setup -> Data Cloud -> Data Streams -> each row
 * -> Refresh Now -> Full Refresh).
 *
 * Bias profile (per design doc Phase 4.5 + user choice):
 *   30% sessions use the seat-change intent and get tagged as
 *       low-satisfaction so the Chapter 6 aggregate shows seat-change
 *       underperforming the rest of the agent.
 *   70% sessions split across search-flights / booking / mileage /
 *       cancel / off-topic with normal satisfaction.
 *
 * Demo_Identifier__c is set to "SKYWAVE_PHASE_4_5" on every row this
 * seeder writes, so a re-run can target only its own data without
 * touching anything else later loaded into the QBrix tables.
 */
public with sharing class Skywave_ObservabilitySeeder {

    public static final String DEMO_TAG = 'SKYWAVE_PHASE_4_5';
    public static final String AGENT_API_NAME = 'Skywave_Airlines_Agent';

    // ---- Topic catalog (api_name, label, intent_bucket) ---------------
    // Mirrors the actual subagents/topics in Skywave_Airlines_Agent.agent
    // — seat_selection is the one we deliberately starve of high
    // satisfaction so the Chapter 6 aggregate dashboard pops.
    private static final List<TopicSpec> TOPICS = new List<TopicSpec>{
        new TopicSpec('seat_selection',     'Seat Selection',     'seat'),
        new TopicSpec('flight_management',  'Flight Management',  'booking'),
        new TopicSpec('mileage_account',    'Mileage Account',    'loyalty'),
        new TopicSpec('case_management',    'Case Management',    'support'),
        new TopicSpec('name_change',        'Name Change',        'booking'),
        new TopicSpec('off_topic',          'Off Topic',          'misc')
    };

    // Sample utterance / response pairs per intent. The seeder picks
    // one randomly when generating each interaction so the Insights tab
    // shows realistic-looking conversation snippets.
    private static final Map<String, List<List<String>>> SAMPLES = new Map<String, List<List<String>>>{
        'seat'    => new List<List<String>>{
            new String[]{ 'I want to change my seat to a window seat',
                          'Sorry, I cannot change your seat at this time. Please try again later.' },
            new String[]{ 'Can I move from 23B to an aisle seat?',
                          'I was unable to update your seat. Please contact a service agent.' },
            new String[]{ 'My seat assignment is wrong, fix it',
                          'I am not able to reassign seats automatically. Could you contact us by phone?' },
            new String[]{ 'Change my seat for tomorrows flight',
                          'I encountered an error retrieving the seat map. Please try again.' }
        },
        'booking' => new List<List<String>>{
            new String[]{ 'Find flights from JFK to HND tomorrow',
                          'I found 4 flights for that route. The cheapest is SW1200 at 1pm for $1,280.' },
            new String[]{ 'Show me my upcoming bookings',
                          'You have one upcoming booking — LH 1927 BER-MUC-SFO confirmed.' },
            new String[]{ 'Cancel my booking ABC123',
                          'I have cancelled booking ABC123. A refund of $480 will be issued.' }
        },
        'loyalty' => new List<List<String>>{
            new String[]{ 'How many miles do I have?',
                          'You currently have 18,450 SkyWave miles. You are at Premier tier.' },
            new String[]{ 'What is my tier status?',
                          'You are Gold tier with 14,200 qualifying points this year.' }
        },
        'support' => new List<List<String>>{
            new String[]{ 'I lost my luggage in Munich last week, can you help?',
                          'I have created case 00012345 for your lost luggage. We will contact you within 24 hours.' },
            new String[]{ 'My in-flight wifi did not work, I want a refund',
                          'I have logged your complaint as case 00012346. Refund will be processed.' }
        },
        'misc'    => new List<List<String>>{
            new String[]{ 'Whats the weather like in Tokyo?',
                          'I can only help with flight bookings and Skywave loyalty questions.' },
            new String[]{ 'Tell me a joke',
                          'I am a Skywave booking assistant. How can I help with your travel?' }
        }
    };

    // Tag definitions seeded once — referenced by every Tag row.
    // (Mirrors the stock Optimization analyzer's tag schema.)
    private static final List<List<String>> TAG_DEFS = new List<List<String>>{
        // [developerName, label, dataType, sourceType]
        new String[]{ 'Topic_Quality',          'Topic Quality',          'PICKLIST', 'OPTIMIZATION' },
        new String[]{ 'User_Satisfaction',      'User Satisfaction',      'PICKLIST', 'OPTIMIZATION' },
        new String[]{ 'Resolution_Status',      'Resolution Status',      'PICKLIST', 'OPTIMIZATION' },
        new String[]{ 'Request_Category',       'Request Category',       'STRING',   'OPTIMIZATION' }
    };

    // Possible tag values per tag definition.
    private static final Map<String, List<String>> TAG_VALUES = new Map<String, List<String>>{
        'Topic_Quality'      => new List<String>{ 'High', 'Medium', 'Low' },
        'User_Satisfaction'  => new List<String>{ 'Satisfied', 'Neutral', 'Unsatisfied' },
        'Resolution_Status'  => new List<String>{ 'Resolved', 'Unresolved', 'Escalated' },
        'Request_Category'   => new List<String>{ 'Self-Service', 'Information', 'Transaction' }
    };

    // ---- Wipe job: deletes all SDO_Analytics_* rows in dependency order

    // Wipe is implemented in Skywave_ObservabilityWipe (top-level
    // Batchable class — Apex doesn't allow inner classes to implement
    // Database.Batchable<SObject>).

    // ---- Seed job: inserts numSessions Skywave-branded sessions
    public class SeedJob implements Queueable {
        public Integer numSessions;
        public SeedJob(Integer numSessions) {
            this.numSessions = numSessions;
        }

        public void execute(QueueableContext qc) {
            seedTagDefinitions();
            seedSessions(this.numSessions);
            System.debug('Skywave_ObservabilitySeeder.SeedJob: ' + numSessions + ' sessions inserted');
        }
    }

    // ---- Implementation -----------------------------------------------

    /**
     * Tag definitions + their per-agent association rows.
     * Inserted once before sessions; referenced by every Tag row.
     */
    private static Map<String, String> tagDefIdByDevName = new Map<String, String>();

    private static void seedTagDefinitions() {
        DateTime now = System.now();
        Date today = Date.today();

        List<SDO_Analytics_AIAgentTagDefinition_v2__c> defs = new List<SDO_Analytics_AIAgentTagDefinition_v2__c>();
        for (String[] td : TAG_DEFS) {
            SDO_Analytics_AIAgentTagDefinition_v2__c d = new SDO_Analytics_AIAgentTagDefinition_v2__c();
            d.External_ID__c = uuid();
            d.Demo_Identifier__c = DEMO_TAG;
            d.Developer_Name__c = td[0];
            d.Name__c = td[1];
            d.Data_Type__c = td[2];
            d.Source_Type__c = td[3];
            d.Description__c = td[1] + ' tag';
            d.Created_Days__c = daysOffset(now);
            d.Created_Time__c = formatTime(now);
            defs.add(d);
        }
        insert defs;
        for (Integer i = 0; i < defs.size(); i++) {
            tagDefIdByDevName.put(TAG_DEFS[i][0], defs[i].External_ID__c);
        }

        // Per-agent association — links each tag definition to the agent.
        List<SDO_Analytics_AIAgentTagDefinitionAss_v2__c> assocs = new List<SDO_Analytics_AIAgentTagDefinitionAss_v2__c>();
        for (String[] td : TAG_DEFS) {
            SDO_Analytics_AIAgentTagDefinitionAss_v2__c a = new SDO_Analytics_AIAgentTagDefinitionAss_v2__c();
            a.External_ID__c = uuid();
            a.Demo_Identifier__c = DEMO_TAG;
            a.AI_Agent_Api_Name__c = AGENT_API_NAME;
            a.AI_Agent_Tag_Definition_Id__c = tagDefIdByDevName.get(td[0]);
a.Created_Days__c = today.daysBetween(today);
            a.Created_Time__c = formatTime(now);
            assocs.add(a);
        }
        insert assocs;
    }

    private static void seedSessions(Integer count) {
        // Spread sessions over the last 14 days for a healthy time range
        // on the dashboards.
        Date today = Date.today();

        // Buffers so each table is one big insert at the end.
        List<SDO_Analytics_AIAgentSession_v2__c> sessions =
            new List<SDO_Analytics_AIAgentSession_v2__c>();
        List<SDO_Analytics_AIAgentSessionParticipa_v2__c> participants =
            new List<SDO_Analytics_AIAgentSessionParticipa_v2__c>();
        List<SDO_Analytics_AiAgentInteraction_v2__c> interactions =
            new List<SDO_Analytics_AiAgentInteraction_v2__c>();
        List<SDO_Analytics_AIAgentInteractionMessa_v2__c> messages =
            new List<SDO_Analytics_AIAgentInteractionMessa_v2__c>();
        List<SDO_Analytics_AIAgentInteractionStep_v2__c> steps =
            new List<SDO_Analytics_AIAgentInteractionStep_v2__c>();
        List<SDO_Analytics_AIAgentMoment_v2__c> moments =
            new List<SDO_Analytics_AIAgentMoment_v2__c>();
        List<SDO_Analytics_AIAgentMomentInteractio_v2__c> momentInts =
            new List<SDO_Analytics_AIAgentMomentInteractio_v2__c>();
        List<SDO_Analytics_AIAgentTag_v2__c> tags =
            new List<SDO_Analytics_AIAgentTag_v2__c>();
        List<SDO_Analytics_AIAgentTagAssociation_v2__c> tagAssocs =
            new List<SDO_Analytics_AIAgentTagAssociation_v2__c>();

        for (Integer i = 0; i < count; i++) {
            // 30% seat-change low-sat / 70% other intents.
            Boolean seatBucket = (Math.mod(Math.abs(Crypto.getRandomInteger()), 100) < 30);

            TopicSpec topic = pickTopic(seatBucket);
            List<String> sample = pickSample(topic.bucket);

            // Session timing — 1 to 14 days ago. Start at daysBack=1 (not 0):
            // a "today" date combined with an afternoon/evening time below
            // lands ahead of an early-morning org clock, producing
            // future-dated sessions that muddy the demo's time range.
            Integer daysBack = 1 + Math.mod(Math.abs(Crypto.getRandomInteger()), 14);
            Integer hourOfDay = 8 + Math.mod(Math.abs(Crypto.getRandomInteger()), 12);
            Integer minute = Math.mod(Math.abs(Crypto.getRandomInteger()), 60);
            DateTime startTs = DateTime.newInstance(
                today.addDays(-daysBack), Time.newInstance(hourOfDay, minute, 0, 0));
            // Conversation length 30s - 5min
            DateTime endTs = startTs.addSeconds(30 + Math.mod(Math.abs(Crypto.getRandomInteger()), 270));

            String sessionUuid = uuid();

            // Session row
            SDO_Analytics_AIAgentSession_v2__c s = new SDO_Analytics_AIAgentSession_v2__c();
            s.External_ID__c = sessionUuid;
            s.Demo_Identifier__c = DEMO_TAG;
            s.AI_Agent_Channel_Type__c = 'EnhancedWebChat';
            // Session end type drives the Session Flow outcome label. STDM
            // valid values are resolved / escalated / deflected / other
            // (canvas + internal guide; 'EndedNormally' was invented).
            // Reinforce the Chapter 6 story: seat-change sessions escalate,
            // everything else resolves.
            s.AI_Agent_Session_End_Type__c =
                (seatBucket && topic.bucket == 'seat') ? 'escalated' : 'resolved';
            s.Session_Owner_Object__c = 'Contact';
            s.Start_Days__c = daysOffset(startTs);
            s.Start_Time__c = formatTime(startTs);
            // End_Timestamp__c is a plain writable DateTime (no End_Days/
            // End_Time formula pair like the Interaction object). The
            // Start_Timestamp__c formula reads Start_Days/Start_Time as a
            // wall-clock string in GMT, so End must be stored as the same
            // wall-clock reinterpreted as a GMT instant — otherwise the
            // running user's TZ offset is applied to End but not Start, the
            // two disagree, duration goes negative, and Studio hides the
            // session. See commit 2acc772 for the failure this replaces.
            s.End_Timestamp__c = asGmtInstant(endTs);
            sessions.add(s);

            // Two participants — agent + user
            SDO_Analytics_AIAgentSessionParticipa_v2__c agentP = new SDO_Analytics_AIAgentSessionParticipa_v2__c();
            agentP.External_ID__c = uuid();
            agentP.Demo_Identifier__c = DEMO_TAG;
            agentP.AI_Agent_Session__c = sessionUuid;
            agentP.AI_Agent_Api_Name__c = AGENT_API_NAME;
            agentP.AI_Agent_Version_Api_Name__c = AGENT_API_NAME;
            agentP.AI_Agent_Type__c = 'EinsteinServiceAgent';
            agentP.AI_Agent_Session_Participant_Role__c = 'AGENT';
            agentP.Start_Days__c = s.Start_Days__c;
            agentP.Start_Time__c = formatTime(startTs);
            agentP.End_Timestamp__c = asGmtInstant(endTs);
            participants.add(agentP);

            SDO_Analytics_AIAgentSessionParticipa_v2__c userP = new SDO_Analytics_AIAgentSessionParticipa_v2__c();
            userP.External_ID__c = uuid();
            userP.Demo_Identifier__c = DEMO_TAG;
            userP.AI_Agent_Session__c = sessionUuid;
            userP.AI_Agent_Api_Name__c = AGENT_API_NAME;
            userP.AI_Agent_Version_Api_Name__c = AGENT_API_NAME;
            userP.AI_Agent_Type__c = 'EinsteinServiceAgent';
            userP.AI_Agent_Session_Participant_Role__c = 'USER';
            userP.Start_Days__c = s.Start_Days__c;
            userP.Start_Time__c = formatTime(startTs);
            userP.End_Timestamp__c = asGmtInstant(endTs);
            participants.add(userP);

            // One interaction (user turn -> agent turn pair)
            String interactionUuid = uuid();
            SDO_Analytics_AiAgentInteraction_v2__c it = new SDO_Analytics_AiAgentInteraction_v2__c();
            it.External_ID__c = interactionUuid;
            it.Demo_Identifier__c = DEMO_TAG;
            it.AI_Agent_Session__c = sessionUuid;
            it.Topic_API_Name__c = topic.apiName;
            // STDM interaction type is 'TURN' (one per user/agent exchange) —
            // verified against the AIPlatform-sourced rows. The dashboard
            // counts TURN rows for "Number of Interactions" and derives
            // duration/latency from them; an invented type like
            // 'PROMPT_RESPONSE' renders the session but leaves every metric
            // blank ("--").
            it.Ai_Agent_Interaction_Type__c = 'TURN';
            it.Start_Days__c = s.Start_Days__c;
            it.Start_Time__c = formatTime(startTs);
            it.End_Days__c = s.Start_Days__c;
            it.End_Time__c = formatTime(endTs);
            // Telemetry trace IDs let the UI link a chat bubble to its
            // session trace. They can be synthetic UUIDs but must be
            // non-empty — the seeder previously left them blank, so the
            // trace view wouldn't open. (STDM ref: TelemetryTraceId /
            // TelemetryTraceSpanId on AIAgentInteraction.)
            String traceId = uuid();
            it.Telemetry_Trace__c = traceId;
            it.Telemetry_Trace_Span__c = uuid();
            interactions.add(it);

            // Two messages — user + agent
            DateTime userTs = startTs.addSeconds(2);
            SDO_Analytics_AIAgentInteractionMessa_v2__c userMsg = new SDO_Analytics_AIAgentInteractionMessa_v2__c();
            userMsg.External_ID__c = uuid();
            userMsg.Demo_Identifier__c = DEMO_TAG;
            userMsg.AI_Agent_Session__c = sessionUuid;
            userMsg.AI_Agent_Interaction__c = interactionUuid;
            userMsg.AI_Agent_Session_Participant__c = userP.External_ID__c;
            // STDM message-type vocabulary is 'Input'/'Output' (NOT
            // 'USER_INPUT'/'AGENT_RESPONSE') and content type is the MIME
            // string 'text/plain' (NOT 'TEXT') — verified against
            // AIPlatform rows. The Session Log decides left/right bubble
            // alignment from this value; an unrecognized type makes every
            // message fall through to the agent (right→left) default, which
            // is why both bubbles appeared as the agent.
            userMsg.AI_Agent_Interaction_Message_Type__c = 'Input';
            userMsg.Ai_Agent_Interaction_Msg_Content_Type__c = 'text/plain';
            userMsg.Content__c = sample[0];
userMsg.Message_Sent_Days__c = s.Start_Days__c;
            userMsg.Message_Sent_Time__c = formatTime(userTs);
            messages.add(userMsg);

            DateTime agentTs = startTs.addSeconds(8);
            SDO_Analytics_AIAgentInteractionMessa_v2__c agentMsg = new SDO_Analytics_AIAgentInteractionMessa_v2__c();
            agentMsg.External_ID__c = uuid();
            agentMsg.Demo_Identifier__c = DEMO_TAG;
            agentMsg.AI_Agent_Session__c = sessionUuid;
            agentMsg.AI_Agent_Interaction__c = interactionUuid;
            agentMsg.AI_Agent_Session_Participant__c = agentP.External_ID__c;
            agentMsg.AI_Agent_Interaction_Message_Type__c = 'Output';
            agentMsg.Ai_Agent_Interaction_Msg_Content_Type__c = 'text/plain';
            agentMsg.Content__c = sample[1];
agentMsg.Message_Sent_Days__c = s.Start_Days__c;
            agentMsg.Message_Sent_Time__c = formatTime(agentTs);
            messages.add(agentMsg);

            // Three reasoning steps rendered inside the session trace view.
            // Step-type vocabulary must match the STDM enum that view
            // understands — TOPIC_STEP / LLM_STEP / ACTION_STEP (verified
            // against AIPlatform rows, which also emit VARIABLE_UPDATE_STEP,
            // TRUST_GUARDRAILS_STEP, SESSION_END). Invented names like
            // 'PlannerStep' render as unknown step types in the trace. Each
            // step's span shares the interaction's trace id so the trace
            // hangs together as one tree.
            String[] stepNames = new String[]{ 'TOPIC_STEP', 'LLM_STEP', 'ACTION_STEP' };
            DateTime cursor = startTs;
            String prevStepUuid = null;
            for (String stepName : stepNames) {
                DateTime stepStart = cursor;
                DateTime stepEnd = cursor.addSeconds(2);
                SDO_Analytics_AIAgentInteractionStep_v2__c step = new SDO_Analytics_AIAgentInteractionStep_v2__c();
                step.External_ID__c = uuid();
                step.Demo_Identifier__c = DEMO_TAG;
                step.AI_Agent_Interaction__c = interactionUuid;
                step.Ai_Agent_Interaction_Step_Type__c = stepName;
                step.Name__c = stepName;
                step.Telemetry_Trace_Span_Id__c = traceId;
step.Start_Days__c = s.Start_Days__c;
                step.Start_Time__c = formatTime(stepStart);
                step.End_Days__c = s.Start_Days__c;
                step.End_Time__c = formatTime(stepEnd);
                step.Previous_Step__c = prevStepUuid;
                steps.add(step);
                prevStepUuid = step.External_ID__c;
                cursor = stepEnd;
            }

            // Moment — every session has one for the dashboards' Moment count.
            String momentUuid = uuid();
            SDO_Analytics_AIAgentMoment_v2__c moment = new SDO_Analytics_AIAgentMoment_v2__c();
            moment.External_ID__c = momentUuid;
            moment.Demo_Identifier__c = DEMO_TAG;
            moment.AI_Agent_Session__c = sessionUuid;
            moment.AI_Agent_API_Name__c = AGENT_API_NAME;
            moment.AI_Agent_Version_API_Name__c = AGENT_API_NAME;
            moment.Request_Summary_Text__c = sample[0];
            moment.Response_Summary_Text__c = sample[1];
moment.Start_Days__c = s.Start_Days__c;
            moment.Start_Time__c = formatTime(startTs);
            moment.End_Days__c = s.Start_Days__c;
            moment.End_Time__c = formatTime(endTs);
            moments.add(moment);

            SDO_Analytics_AIAgentMomentInteractio_v2__c mi = new SDO_Analytics_AIAgentMomentInteractio_v2__c();
            mi.External_ID__c = uuid();
            mi.Demo_Identifier__c = DEMO_TAG;
            mi.AI_Agent_Moment_Id__c = momentUuid;
            mi.Interaction_Id__c = interactionUuid;
mi.Start_Days__c = s.Start_Days__c;
            mi.Start_Time__c = formatTime(startTs);
            momentInts.add(mi);

            // Tags + tag-associations. Bias: seat-change → Low/Unsatisfied/Unresolved.
            Map<String, String> picked = new Map<String, String>();
            if (seatBucket && topic.bucket == 'seat') {
                picked.put('Topic_Quality',     'Low');
                picked.put('User_Satisfaction', 'Unsatisfied');
                picked.put('Resolution_Status', 'Unresolved');
                picked.put('Request_Category',  'Self-Service');
            } else {
                picked.put('Topic_Quality',     pickHigh('Topic_Quality'));
                picked.put('User_Satisfaction', pickHigh('User_Satisfaction'));
                picked.put('Resolution_Status', pickHigh('Resolution_Status'));
                picked.put('Request_Category',  pickAny('Request_Category'));
            }

            for (String tagDevName : picked.keySet()) {
                String tagUuid = uuid();
                SDO_Analytics_AIAgentTag_v2__c tag = new SDO_Analytics_AIAgentTag_v2__c();
                tag.External_ID__c = tagUuid;
                tag.Demo_Identifier__c = DEMO_TAG;
                tag.AI_Agent_Tag_Definition_Id__c = tagDefIdByDevName.get(tagDevName);
                tag.Value__c = picked.get(tagDevName);
                tag.Description__c = picked.get(tagDevName);
                tag.Is_Active__c = true;
tag.Created_Days__c = s.Start_Days__c;
                tag.Created_Time__c = formatTime(endTs);
                tags.add(tag);

                SDO_Analytics_AIAgentTagAssociation_v2__c ta = new SDO_Analytics_AIAgentTagAssociation_v2__c();
                ta.External_ID__c = uuid();
                ta.Demo_Identifier__c = DEMO_TAG;
                ta.AI_Agent_Session_Id__c = sessionUuid;
                ta.AI_Agent_Moment_Id__c = momentUuid;
                ta.AI_Agent_Tag_Id__c = tagUuid;
                ta.Association_Reason__c = 'Pre-baked Skywave Phase 4.5 seed';
ta.Created_Days__c = s.Start_Days__c;
                ta.Created_Time__c = formatTime(endTs);
                tagAssocs.add(ta);
            }
        }

        // Insert in dependency order. ALL_OR_NONE=false so a single bad
        // row doesn't abort the whole seed.
        Database.insert(sessions, false);
        Database.insert(participants, false);
        Database.insert(interactions, false);
        Database.insert(messages, false);
        Database.insert(steps, false);
        Database.insert(moments, false);
        Database.insert(momentInts, false);
        Database.insert(tags, false);
        Database.insert(tagAssocs, false);
    }

    // ---- helpers ------------------------------------------------------

    private class TopicSpec {
        public String apiName;
        public String label;
        public String bucket;
        public TopicSpec(String a, String l, String b) {
            apiName = a; label = l; bucket = b;
        }
    }

    private static TopicSpec pickTopic(Boolean forceSeat) {
        if (forceSeat) return TOPICS[0]; // seat_selection
        // Pick uniformly across the non-seat topics.
        Integer idx = 1 + Math.mod(Math.abs(Crypto.getRandomInteger()), TOPICS.size() - 1);
        return TOPICS[idx];
    }

    private static List<String> pickSample(String bucket) {
        Object listObj = SAMPLES.get(bucket);
        if (listObj == null) return new List<String>{ '', '' };
        // Apex doesn't allow `List<List<String>>` as a local variable type
        // but does allow it as a Map value type — round-trip via Object
        // to dodge the parser quirk.
        List<Object> rows = (List<Object>) listObj;
        if (rows.isEmpty()) return new List<String>{ '', '' };
        Integer idx = Math.mod(Math.abs(Crypto.getRandomInteger()), rows.size());
        return (List<String>) rows.get(idx);
    }

    private static String pickHigh(String tagName) {
        // Bias non-seat sessions toward the first (positive) value 70% of the time.
        List<String> options = TAG_VALUES.get(tagName);
        return Math.mod(Math.abs(Crypto.getRandomInteger()), 100) < 70
            ? options[0]
            : options[Math.mod(Math.abs(Crypto.getRandomInteger()), options.size())];
    }

    private static String pickAny(String tagName) {
        List<String> options = TAG_VALUES.get(tagName);
        return options[Math.mod(Math.abs(Crypto.getRandomInteger()), options.size())];
    }

    private static String formatTime(DateTime dt) {
        return dt.format('HH:mm:ss');
    }

    /**
     * Re-anchor a DateTime's wall-clock components to GMT.
     *
     * The seeder builds startTs/endTs with DateTime.newInstance(date, time),
     * which treats the supplied date+time as the running user's local zone.
     * But the Start_Timestamp__c formula evaluates Start_Days/Start_Time as
     * a wall-clock string in GMT. To keep End on the same footing as Start,
     * take the *local* wall-clock fields of dt and rebuild the same fields
     * as a GMT instant. This makes End - Start a real, non-negative duration
     * regardless of the running user's time zone.
     */
    private static DateTime asGmtInstant(DateTime dt) {
        return DateTime.newInstanceGmt(
            dt.year(), dt.month(), dt.day(),
            dt.hour(), dt.minute(), dt.second());
    }

    /**
     * Days offset from today — the *_Timestamp__c formula on the SDO
     * tables uses this as `TODAY() + Days`. Negative numbers reach
     * back into history, positive numbers project forward.
     */
    private static Decimal daysOffset(DateTime dt) {
        Date d = Date.newInstance(dt.year(), dt.month(), dt.day());
        return Date.today().daysBetween(d);
    }

    private static String uuid() {
        // Synthetic UUID v4 — random, not crypto-grade but adequate
        // for cross-row foreign-key strings in the SDO tables.
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0, 8)  + '-' +
               hex.substring(8, 12) + '-' +
               '4' + hex.substring(13, 16) + '-' +
               'a' + hex.substring(17, 20) + '-' +
               hex.substring(20, 32);
    }
}
