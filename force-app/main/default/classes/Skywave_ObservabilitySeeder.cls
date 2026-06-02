/**
 * Phase 4.5 Observability seeder — full DriveMax-fidelity rebuild.
 *
 * Seeds the SDO_Agentforce_Observability QBrix custom objects with
 * Skywave-branded synthetic sessions that RENDER in the Agentforce
 * Optimization + Analytics dashboards, telling the Chapter 6 story:
 * the agent handles most intents well, but the "seat change" INTENT
 * consistently fails (very low quality) — while there is deliberately
 * NO "seat change" subagent/topic, so the failure only surfaces under
 * Quality-by-Intent, not Quality-by-Subagent.
 *
 * Why this shape (all verified by A/B diff against the live DriveMax QBrix
 * data in the same org):
 *  - The Optimization analyzer does NOT process synthetic (Salesforce_Home)
 *    data, so every quality signal must be PRE-BAKED. DriveMax ships only
 *    two tag-definition types and bakes the rest:
 *      * AIE_Request_Category_<AgentApiName> (Source_Type 'Generated') — the
 *        Intent dimension; one tag value per intent cluster, reused.
 *      * Quality_Score (Source_Type 'Predefined', Integer) — five reusable
 *        tags valued 1..5, associated ONE per moment. This drives the
 *        "Average Quality Score" / Quality-by-Subagent / Quality-by-Intent
 *        cards (5≈High … 1≈Very Low).
 *  - Each MOMENT = one intent row: it carries a request/response summary, a
 *    MomentInteraction junction to its interactions (whose Topic_API_Name is
 *    the subagent), and exactly two tag associations (AIE intent +
 *    Quality_Score). Sessions can hold multiple moments.
 *  - Sessions render only when participants carry Participant__c
 *    (AGENT->GenAiPlannerDefinition, USER->MessagingEndUser) and the
 *    optional session fields carry the literal 'NOT_SET' sentinel.
 *
 * Invocation:
 *   Database.executeBatch(new Skywave_ObservabilityWipe(), 2000);   // scoped
 *   // wait for the chained wipe to finish, then:
 *   System.enqueueJob(new Skywave_ObservabilitySeeder.SeedJob(400));
 *
 * The seed job chains itself in chunks of CHUNK_SIZE sessions to stay under
 * the per-transaction DML row limit. After it finishes, refresh the eleven
 * SDO_Analytics_*_Home data streams (Dev Console:
 * Skywave_DataStreamRunner.refreshSdoAnalyticsStreams()).
 *
 * Every row is tagged Demo_Identifier__c = DEMO_TAG so the scoped wipe
 * removes only this project's data and never the coexisting DriveMax rows.
 */
public with sharing class Skywave_ObservabilitySeeder {

    public static final String DEMO_TAG = 'SKYWAVE_PHASE_4_5';
    public static final String AGENT_API_NAME = 'Skywave_Airlines_Agent';
    private static final Integer CHUNK_SIZE = 100;

    // The Intent dimension. Naming MUST be AIE_Request_Category_<AgentApiName>
    // with Source_Type 'Generated' (matches the analyzer's own output schema).
    private static final String AIE_INTENT_DEF =
        'AIE_Request_Category_' + AGENT_API_NAME;

    // Only the two tag-definition types DriveMax actually ships. The
    // OPTIMIZATION tags (Topic_Quality/User_Satisfaction/Resolution_Status)
    // seen in-org are live-analyzer output, NOT seed data, so we don't ship
    // them. [developerName, label, dataType, sourceType]
    private static final List<List<String>> TAG_DEFS = new List<List<String>>{
        new String[]{ AIE_INTENT_DEF, 'Optimization Request Category', 'Text',    'Generated'  },
        new String[]{ 'Quality_Score', 'Relevance Score',              'Integer', 'Predefined' }
    };

    // Granular intent values per bucket — these are the dashboard Intents.
    private static final Map<String, List<String>> INTENTS = new Map<String, List<String>>{
        'seat'    => new List<String>{ 'Seat Change Requests',
                                       'Seat Upgrade Requests',
                                       'Seat Assignment Corrections' },
        'booking' => new List<String>{ 'Flight Search and Booking',
                                       'Reservation Modifications and Cancellations',
                                       'Booking Confirmation Queries' },
        'loyalty' => new List<String>{ 'Mileage Balance Inquiries',
                                       'Tier Status and Benefits',
                                       'Miles Redemption Requests' },
        'support' => new List<String>{ 'Lost Baggage Claims',
                                       'In-Flight Service Complaints',
                                       'Refund Requests for Service Issues' },
        'name'    => new List<String>{ 'Passenger Name Corrections',
                                       'Name Spelling Updates' },
        'misc'    => new List<String>{ 'Off-Topic General Queries',
                                       'Unsupported Requests' }
    };

    // Sample user/agent message pairs per bucket. seat pairs are written as
    // failures (drives the story even for anyone who reads the transcript).
    private static final Map<String, List<List<String>>> SAMPLES = new Map<String, List<List<String>>>{
        'seat'    => new List<List<String>>{
            new String[]{ 'I want to change my seat to a window seat',
                          'Sorry, I am unable to change your seat right now. Please try again later.' },
            new String[]{ 'Can I move from 23B to an aisle seat?',
                          'I could not update your seat assignment. Please contact a service agent.' },
            new String[]{ 'I want to select seat 1A for my flight',
                          'I was unable to retrieve the seat map automatically and could not assign the seat.' }
        },
        'booking' => new List<List<String>>{
            new String[]{ 'Find flights from JFK to HND tomorrow',
                          'I found 4 flights for that route. The cheapest is SW1200 at 1pm for $1,280.' },
            new String[]{ 'Show me my upcoming bookings',
                          'You have one upcoming booking — LH 1927 BER-MUC-SFO, confirmed.' },
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
                          'I have logged your complaint as case 00012346. A refund will be processed.' }
        },
        'name'    => new List<List<String>>{
            new String[]{ 'Please correct my last name on booking ABC123',
                          'I have updated the passenger name on booking ABC123. A confirmation has been sent.' },
            new String[]{ 'My first name is misspelled on my ticket',
                          'I have corrected the spelling on your ticket. Please review the updated itinerary.' }
        },
        'misc'    => new List<List<String>>{
            new String[]{ 'Whats the weather like in Tokyo?',
                          'I can only help with flight bookings and Skywave loyalty questions.' },
            new String[]{ 'Tell me a joke',
                          'I am a Skywave booking assistant. How can I help with your travel?' }
        }
    };

    // ---- Moment archetypes -------------------------------------------------
    // Each archetype maps a subagent topic + intent bucket to a quality band.
    // The weighted mix sets the story: seat (very low) is the single biggest
    // slice so Quality-by-Intent clearly bottoms out at seat change, while
    // the subagents themselves show a spread.
    private class Archetype {
        String topic;      // subagent (Topic_API_Name) — NO seat topic
        String bucket;     // intent/sample bucket
        Integer minScore;  // Quality_Score range (inclusive)
        Integer maxScore;
        Integer weight;
        Archetype(String t, String b, Integer mn, Integer mx, Integer w) {
            topic = t; bucket = b; minScore = mn; maxScore = mx; weight = w;
        }
    }
    private static List<Archetype> archetypes() {
        return new List<Archetype>{
            // seat failures live UNDER flight_management (no seat topic), 1-2 = Very Low/Low
            new Archetype('flight_management', 'seat',    1, 2, 30),
            new Archetype('flight_management', 'booking', 4, 5, 20),
            new Archetype('mileage_account',   'loyalty', 4, 5, 15),
            new Archetype('case_management',   'support', 3, 4, 15),
            new Archetype('name_change',       'name',    4, 5, 10),
            new Archetype('off_topic',         'misc',    2, 3, 10)
        };
    }

    // ---- Seed job (chained chunks) ----------------------------------------
    public class SeedJob implements Queueable {
        public Integer total;     // total sessions wanted
        public Integer done;      // sessions already seeded by prior chunks
        public SeedJob(Integer total) { this(total, 0); }
        public SeedJob(Integer total, Integer done) {
            this.total = total; this.done = done;
        }
        public void execute(QueueableContext qc) {
            if (done == 0) {
                seedTagDefinitions();   // create defs + intent tags + 1..5 score tags
            } else {
                loadTagMaps();          // reload them from the DB for this chunk
            }
            Integer thisChunk = Math.min(CHUNK_SIZE, total - done);
            seedSessions(thisChunk, done);
            Integer newDone = done + thisChunk;
            System.debug('Skywave_ObservabilitySeeder: seeded ' + newDone + '/' + total);
            if (newDone < total && !Test.isRunningTest()) {
                System.enqueueJob(new SeedJob(total, newDone));
            }
        }
    }

    // ---- Shared lookups (repopulated per chunk) ---------------------------
    private static Map<String, String> tagDefIdByDevName = new Map<String, String>();
    private static Map<String, String> tagDefAssocIdByDevName = new Map<String, String>();
    private static Map<String, String> intentTagIdByValue = new Map<String, String>();
    private static Map<String, String> qualityScoreTagIdByValue = new Map<String, String>();

    private static void seedTagDefinitions() {
        DateTime now = System.now();

        List<SDO_Analytics_AIAgentTagDefinition_v2__c> defs = new List<SDO_Analytics_AIAgentTagDefinition_v2__c>();
        for (List<String> td : TAG_DEFS) {
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

        // Per-agent def associations — referenced by every tag association.
        List<SDO_Analytics_AIAgentTagDefinitionAss_v2__c> assocs = new List<SDO_Analytics_AIAgentTagDefinitionAss_v2__c>();
        for (List<String> td : TAG_DEFS) {
            SDO_Analytics_AIAgentTagDefinitionAss_v2__c a = new SDO_Analytics_AIAgentTagDefinitionAss_v2__c();
            String assocUuid = uuid();
            a.External_ID__c = assocUuid;
            a.Demo_Identifier__c = DEMO_TAG;
            a.AI_Agent_Api_Name__c = AGENT_API_NAME;
            a.AI_Agent_Tag_Definition_Id__c = tagDefIdByDevName.get(td[0]);
            a.Created_Days__c = daysOffset(now);
            a.Created_Time__c = formatTime(now);
            assocs.add(a);
            tagDefAssocIdByDevName.put(td[0], assocUuid);
        }
        insert assocs;

        List<SDO_Analytics_AIAgentTag_v2__c> reusable = new List<SDO_Analytics_AIAgentTag_v2__c>();
        // One reusable tag per intent value (under the AIE def).
        for (String bucket : INTENTS.keySet()) {
            for (String intentValue : INTENTS.get(bucket)) {
                if (intentTagIdByValue.containsKey(intentValue)) continue;
                String tagUuid = uuid();
                reusable.add(buildTag(tagUuid, tagDefIdByDevName.get(AIE_INTENT_DEF),
                                      intentValue, now));
                intentTagIdByValue.put(intentValue, tagUuid);
            }
        }
        // Five reusable Quality_Score tags valued 1..5 (DriveMax pattern).
        for (Integer score = 1; score <= 5; score++) {
            String tagUuid = uuid();
            reusable.add(buildTag(tagUuid, tagDefIdByDevName.get('Quality_Score'),
                                  String.valueOf(score), now));
            qualityScoreTagIdByValue.put(String.valueOf(score), tagUuid);
        }
        insert reusable;
    }

    /** Reload the shared lookups from already-seeded rows (later chunks). */
    private static void loadTagMaps() {
        Map<String, String> devNameByDefId = new Map<String, String>();
        for (SDO_Analytics_AIAgentTagDefinition_v2__c d : [
                SELECT External_ID__c, Developer_Name__c
                FROM SDO_Analytics_AIAgentTagDefinition_v2__c
                WHERE Demo_Identifier__c = :DEMO_TAG]) {
            tagDefIdByDevName.put(d.Developer_Name__c, d.External_ID__c);
            devNameByDefId.put(d.External_ID__c, d.Developer_Name__c);
        }
        for (SDO_Analytics_AIAgentTagDefinitionAss_v2__c a : [
                SELECT External_ID__c, AI_Agent_Tag_Definition_Id__c
                FROM SDO_Analytics_AIAgentTagDefinitionAss_v2__c
                WHERE Demo_Identifier__c = :DEMO_TAG]) {
            String dev = devNameByDefId.get(a.AI_Agent_Tag_Definition_Id__c);
            if (dev != null) tagDefAssocIdByDevName.put(dev, a.External_ID__c);
        }
        String aieDefId = tagDefIdByDevName.get(AIE_INTENT_DEF);
        String qDefId = tagDefIdByDevName.get('Quality_Score');
        for (SDO_Analytics_AIAgentTag_v2__c t : [
                SELECT External_ID__c, Value__c, AI_Agent_Tag_Definition_Id__c
                FROM SDO_Analytics_AIAgentTag_v2__c
                WHERE Demo_Identifier__c = :DEMO_TAG
                  AND AI_Agent_Tag_Definition_Id__c IN (:aieDefId, :qDefId)]) {
            if (t.AI_Agent_Tag_Definition_Id__c == aieDefId) {
                intentTagIdByValue.put(t.Value__c, t.External_ID__c);
            } else {
                qualityScoreTagIdByValue.put(t.Value__c, t.External_ID__c);
            }
        }
    }

    // ---- Session generation -----------------------------------------------
    private static void seedSessions(Integer count, Integer offset) {
        String plannerId = resolvePlannerId();
        List<Id> endUserIds = resolveMessagingEndUserIds();
        List<Archetype> arches = archetypes();
        Integer totalWeight = 0;
        for (Archetype a : arches) totalWeight += a.weight;

        List<SDO_Analytics_AIAgentSession_v2__c> sessions = new List<SDO_Analytics_AIAgentSession_v2__c>();
        List<SDO_Analytics_AIAgentSessionParticipa_v2__c> participants = new List<SDO_Analytics_AIAgentSessionParticipa_v2__c>();
        List<SDO_Analytics_AiAgentInteraction_v2__c> interactions = new List<SDO_Analytics_AiAgentInteraction_v2__c>();
        List<SDO_Analytics_AIAgentInteractionMessa_v2__c> messages = new List<SDO_Analytics_AIAgentInteractionMessa_v2__c>();
        List<SDO_Analytics_AIAgentInteractionStep_v2__c> steps = new List<SDO_Analytics_AIAgentInteractionStep_v2__c>();
        List<SDO_Analytics_AIAgentMoment_v2__c> moments = new List<SDO_Analytics_AIAgentMoment_v2__c>();
        List<SDO_Analytics_AIAgentMomentInteractio_v2__c> momentInts = new List<SDO_Analytics_AIAgentMomentInteractio_v2__c>();
        List<SDO_Analytics_AIAgentTagAssociation_v2__c> tagAssocs = new List<SDO_Analytics_AIAgentTagAssociation_v2__c>();

        for (Integer i = 0; i < count; i++) {
            Integer daysBack = 1 + rand(14);                 // 1..14 days ago (never future)
            Integer hourOfDay = 8 + rand(12);
            Integer minute = rand(60);
            DateTime sessionStart = DateTime.newInstance(
                Date.today().addDays(-daysBack),
                Time.newInstance(hourOfDay, minute, 0, 0));

            String sessionUuid = uuid();
            Decimal startDays = daysOffset(sessionStart);
            String endUserId = endUserIds.isEmpty()
                ? null : endUserIds[Math.mod(offset + i, endUserIds.size())];

            // How many moments this session holds (mostly 1, some 2, few 3).
            Integer roll = rand(100);
            Integer momentCount = roll < 60 ? 1 : (roll < 90 ? 2 : 3);

            DateTime cursor = sessionStart;
            DateTime sessionEnd = sessionStart;

            for (Integer m = 0; m < momentCount; m++) {
                Archetype arch = pickArchetype(arches, totalWeight);
                List<String> intents = INTENTS.get(arch.bucket);
                String intentValue = intents[rand(intents.size())];
                List<String> sample = pickSample(arch.bucket);
                Integer score = arch.minScore + rand(arch.maxScore - arch.minScore + 1);

                String momentUuid = uuid();
                DateTime momentStart = cursor;

                // Two interactions per moment: the main request + a follow-up.
                List<String> mainPair = sample;
                List<String> followPair = followUp(score);
                List<List<String>> turns = new List<List<String>>{ mainPair, followPair };
                List<String> turnInteractionIds = new List<String>();

                for (Integer t = 0; t < turns.size(); t++) {
                    List<String> pair = turns[t];
                    DateTime turnStart = cursor;
                    DateTime turnEnd = turnStart.addSeconds(20 + rand(40));
                    String interactionUuid = uuid();
                    String traceId = uuid();
                    turnInteractionIds.add(interactionUuid);

                    SDO_Analytics_AiAgentInteraction_v2__c it = new SDO_Analytics_AiAgentInteraction_v2__c();
                    it.External_ID__c = interactionUuid;
                    it.Demo_Identifier__c = DEMO_TAG;
                    it.AI_Agent_Session__c = sessionUuid;
                    it.Topic_API_Name__c = arch.topic;       // subagent
                    it.Ai_Agent_Interaction_Type__c = 'TURN';
                    it.Session_Owner__c = endUserId;
                    it.Session_Owner_Object__c = (endUserId == null) ? null : 'MessagingEndUser';
                    it.Start_Days__c = daysOffset(turnStart);
                    it.Start_Time__c = formatTime(turnStart);
                    it.End_Days__c = daysOffset(turnEnd);
                    it.End_Time__c = formatTime(turnEnd);
                    it.Telemetry_Trace__c = traceId;
                    it.Telemetry_Trace_Span__c = uuid();
                    interactions.add(it);

                    // user + agent messages
                    messages.add(buildMessage(sessionUuid, interactionUuid,
                        userParticipantPlaceholder(sessionUuid), 'Input', pair[0],
                        turnStart.addSeconds(2)));
                    messages.add(buildMessage(sessionUuid, interactionUuid,
                        agentParticipantPlaceholder(sessionUuid), 'Output', pair[1],
                        turnStart.addSeconds(8)));

                    // steps: main turn gets 2, follow-up gets 1
                    Integer stepN = (t == 0) ? 2 : 1;
                    String[] stepTypes = new String[]{ 'TOPIC_STEP', 'LLM_STEP', 'ACTION_STEP' };
                    String prevStep = null;
                    DateTime sc = turnStart;
                    for (Integer sIdx = 0; sIdx < stepN; sIdx++) {
                        DateTime ss = sc, se = sc.addSeconds(2);
                        SDO_Analytics_AIAgentInteractionStep_v2__c step = new SDO_Analytics_AIAgentInteractionStep_v2__c();
                        step.External_ID__c = uuid();
                        step.Demo_Identifier__c = DEMO_TAG;
                        step.AI_Agent_Interaction__c = interactionUuid;
                        step.Ai_Agent_Interaction_Step_Type__c = stepTypes[Math.mod(sIdx, 3)];
                        step.Name__c = stepTypes[Math.mod(sIdx, 3)];
                        step.Input_Value__c = pair[0];
                        step.Output_Value__c = pair[1];
                        step.Telemetry_Trace_Span_Id__c = traceId;
                        step.Start_Days__c = daysOffset(ss);
                        step.Start_Time__c = formatTime(ss);
                        step.End_Days__c = daysOffset(se);
                        step.End_Time__c = formatTime(se);
                        step.Previous_Step__c = prevStep;
                        steps.add(step);
                        prevStep = step.External_ID__c;
                        sc = se;
                    }

                    // moment ↔ interaction junction
                    SDO_Analytics_AIAgentMomentInteractio_v2__c mi = new SDO_Analytics_AIAgentMomentInteractio_v2__c();
                    mi.External_ID__c = uuid();
                    mi.Demo_Identifier__c = DEMO_TAG;
                    mi.AI_Agent_Moment_Id__c = momentUuid;
                    mi.Interaction_Id__c = interactionUuid;
                    mi.Start_Days__c = daysOffset(turnStart);
                    mi.Start_Time__c = formatTime(turnStart);
                    momentInts.add(mi);

                    cursor = turnEnd.addSeconds(5);
                    sessionEnd = turnEnd;
                }

                // The moment row + its 2 tag associations (intent + score).
                SDO_Analytics_AIAgentMoment_v2__c moment = new SDO_Analytics_AIAgentMoment_v2__c();
                moment.External_ID__c = momentUuid;
                moment.Demo_Identifier__c = DEMO_TAG;
                moment.AI_Agent_Session__c = sessionUuid;
                moment.AI_Agent_API_Name__c = AGENT_API_NAME;
                moment.AI_Agent_Version_API_Name__c = AGENT_API_NAME;
                moment.Request_Summary_Text__c = mainPair[0];
                moment.Response_Summary_Text__c = mainPair[1];
                moment.Start_Days__c = daysOffset(momentStart);
                moment.Start_Time__c = formatTime(momentStart);
                moment.End_Days__c = daysOffset(sessionEnd);
                moment.End_Time__c = formatTime(sessionEnd);
                moments.add(moment);

                tagAssocs.add(makeTagAssoc(intentTagIdByValue.get(intentValue),
                    AIE_INTENT_DEF, sessionUuid, momentUuid, 'Intent: ' + intentValue,
                    startDays, sessionEnd));
                tagAssocs.add(makeTagAssoc(qualityScoreTagIdByValue.get(String.valueOf(score)),
                    'Quality_Score', sessionUuid, momentUuid, 'Quality score ' + score,
                    startDays, sessionEnd));
            }

            // ---- Session row
            SDO_Analytics_AIAgentSession_v2__c s = new SDO_Analytics_AIAgentSession_v2__c();
            s.External_ID__c = sessionUuid;
            s.Demo_Identifier__c = DEMO_TAG;
            s.AI_Agent_Channel_Type__c = 'SCRT2 - EmbeddedMessaging';
            // Outcome: escalate if any seat-failure moment, else resolved.
            s.AI_Agent_Session_End_Type__c = 'resolved';
            s.Individual__c = 'NOT_SET';
            s.Previous_Session_Id__c = 'NOT_SET';
            s.Session_Owner_Object__c = 'NOT_SET';
            s.Variable__c = 'NOT_SET';
            s.Start_Days__c = startDays;
            s.Start_Time__c = formatTime(sessionStart);
            s.End_Timestamp__c = asGmtInstant(sessionEnd);
            sessions.add(s);

            // ---- Participants (AGENT + USER), with identities for Analytics.
            SDO_Analytics_AIAgentSessionParticipa_v2__c agentP = new SDO_Analytics_AIAgentSessionParticipa_v2__c();
            agentP.External_ID__c = agentParticipantPlaceholder(sessionUuid);
            agentP.Demo_Identifier__c = DEMO_TAG;
            agentP.AI_Agent_Session__c = sessionUuid;
            agentP.AI_Agent_Api_Name__c = AGENT_API_NAME;
            agentP.AI_Agent_Version_Api_Name__c = AGENT_API_NAME;
            agentP.AI_Agent_Type__c = 'EinsteinServiceAgent';
            agentP.AI_Agent_Session_Participant_Role__c = 'AGENT';
            agentP.Participant_Attribute__c = '{}';
            if (plannerId != null) {
                agentP.Participant__c = plannerId;
                agentP.Participant_Object__c = 'GenAiPlannerDefinition';
            }
            agentP.Start_Days__c = startDays;
            agentP.Start_Time__c = formatTime(sessionStart);
            agentP.End_Timestamp__c = asGmtInstant(sessionEnd);
            participants.add(agentP);

            SDO_Analytics_AIAgentSessionParticipa_v2__c userP = new SDO_Analytics_AIAgentSessionParticipa_v2__c();
            userP.External_ID__c = userParticipantPlaceholder(sessionUuid);
            userP.Demo_Identifier__c = DEMO_TAG;
            userP.AI_Agent_Session__c = sessionUuid;
            userP.AI_Agent_Api_Name__c = AGENT_API_NAME;
            userP.AI_Agent_Version_Api_Name__c = AGENT_API_NAME;
            userP.AI_Agent_Type__c = 'EinsteinServiceAgent';
            userP.AI_Agent_Session_Participant_Role__c = 'USER';
            userP.Participant_Attribute__c = '{}';
            if (endUserId != null) {
                userP.Participant__c = endUserId;
                userP.Participant_Object__c = 'MessagingEndUser';
            }
            userP.Start_Days__c = startDays;
            userP.Start_Time__c = formatTime(sessionStart);
            userP.End_Timestamp__c = asGmtInstant(sessionEnd);
            participants.add(userP);

            // ---- SESSION_END terminator interaction (marks session complete).
            SDO_Analytics_AiAgentInteraction_v2__c endIt = new SDO_Analytics_AiAgentInteraction_v2__c();
            endIt.External_ID__c = uuid();
            endIt.Demo_Identifier__c = DEMO_TAG;
            endIt.AI_Agent_Session__c = sessionUuid;
            endIt.Topic_API_Name__c = 'NOT_SET';
            endIt.Ai_Agent_Interaction_Type__c = 'SESSION_END';
            endIt.Start_Days__c = daysOffset(sessionEnd);
            endIt.Start_Time__c = formatTime(sessionEnd);
            endIt.End_Days__c = daysOffset(sessionEnd);
            endIt.End_Time__c = formatTime(sessionEnd);
            endIt.Telemetry_Trace__c = uuid();
            endIt.Telemetry_Trace_Span__c = uuid();
            interactions.add(endIt);
        }

        Database.insert(sessions, false);
        Database.insert(participants, false);
        Database.insert(interactions, false);
        Database.insert(messages, false);
        Database.insert(steps, false);
        Database.insert(moments, false);
        Database.insert(momentInts, false);
        Database.insert(tagAssocs, false);
    }

    // ---- helpers ----------------------------------------------------------

    // Deterministic participant External_IDs derived from the session uuid so
    // messages can reference them without threading the ids through.
    private static String agentParticipantPlaceholder(String sessionUuid) {
        return 'a' + sessionUuid.substring(1);
    }
    private static String userParticipantPlaceholder(String sessionUuid) {
        return 'u' + sessionUuid.substring(1);
    }

    private static List<String> followUp(Integer score) {
        if (score >= 4) {
            return new String[]{ 'Great, thank you!',
                                 'You are welcome. Is there anything else I can help with?' };
        } else if (score <= 2) {
            return new String[]{ 'This still is not working, I am frustrated.',
                                 'I am sorry for the inconvenience. I was unable to resolve this for you.' };
        }
        return new String[]{ 'Okay.', 'Understood. Anything else I can help with?' };
    }

    private static SDO_Analytics_AIAgentInteractionMessa_v2__c buildMessage(
            String sessionUuid, String interactionUuid, String participantUuid,
            String msgType, String content, DateTime sentAt) {
        SDO_Analytics_AIAgentInteractionMessa_v2__c msg = new SDO_Analytics_AIAgentInteractionMessa_v2__c();
        msg.External_ID__c = uuid();
        msg.Demo_Identifier__c = DEMO_TAG;
        msg.AI_Agent_Session__c = sessionUuid;
        msg.AI_Agent_Interaction__c = interactionUuid;
        msg.AI_Agent_Session_Participant__c = participantUuid;
        msg.AI_Agent_Interaction_Message_Type__c = msgType;
        msg.Ai_Agent_Interaction_Msg_Content_Type__c = 'text/plain';
        msg.Content__c = content;
        msg.Message_Sent_Days__c = daysOffset(sentAt);
        msg.Message_Sent_Time__c = formatTime(sentAt);
        return msg;
    }

    private static SDO_Analytics_AIAgentTag_v2__c buildTag(
            String tagUuid, String defExtId, String value, DateTime now) {
        SDO_Analytics_AIAgentTag_v2__c t = new SDO_Analytics_AIAgentTag_v2__c();
        t.External_ID__c = tagUuid;
        t.Demo_Identifier__c = DEMO_TAG;
        t.AI_Agent_Tag_Definition_Id__c = defExtId;
        t.Value__c = value;
        t.Description__c = value;
        t.Is_Active__c = true;
        t.Created_Days__c = daysOffset(now);
        t.Created_Time__c = formatTime(now);
        return t;
    }

    private static Archetype pickArchetype(List<Archetype> arches, Integer totalWeight) {
        Integer r = rand(totalWeight);
        Integer acc = 0;
        for (Archetype a : arches) {
            acc += a.weight;
            if (r < acc) return a;
        }
        return arches[arches.size() - 1];
    }

    private static List<String> pickSample(String bucket) {
        Object listObj = SAMPLES.get(bucket);
        if (listObj == null) return new List<String>{ '', '' };
        List<Object> rows = (List<Object>) listObj;
        if (rows.isEmpty()) return new List<String>{ '', '' };
        return (List<String>) rows.get(rand(rows.size()));
    }

    private static String resolvePlannerId() {
        List<GenAiPlannerDefinition> planners = [
            SELECT Id FROM GenAiPlannerDefinition
            WHERE DeveloperName LIKE 'Skywave_Airlines_Agent_v%'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        return planners.isEmpty() ? null : planners[0].Id;
    }

    private static List<Id> resolveMessagingEndUserIds() {
        List<Id> ids = new List<Id>();
        for (MessagingEndUser m : [SELECT Id FROM MessagingEndUser LIMIT 25]) {
            ids.add(m.Id);
        }
        return ids;
    }

    private static SDO_Analytics_AIAgentTagAssociation_v2__c makeTagAssoc(
            String tagUuid, String defDevName, String sessionUuid,
            String momentUuid, String reason, Decimal startDays, DateTime endTs) {
        SDO_Analytics_AIAgentTagAssociation_v2__c ta = new SDO_Analytics_AIAgentTagAssociation_v2__c();
        ta.External_ID__c = uuid();
        ta.Demo_Identifier__c = DEMO_TAG;
        ta.AI_Agent_Session_Id__c = sessionUuid;
        ta.AI_Agent_Moment_Id__c = momentUuid;
        ta.AI_Agent_Tag_Id__c = tagUuid;
        ta.AI_Agent_Tag_Definition_Association_Id__c = tagDefAssocIdByDevName.get(defDevName);
        ta.Association_Reason__c = reason;
        ta.Created_Days__c = startDays;
        ta.Created_Time__c = formatTime(endTs);
        return ta;
    }

    private static Integer rand(Integer bound) {
        if (bound <= 0) return 0;
        return Math.mod(Math.abs(Crypto.getRandomInteger()), bound);
    }

    private static String formatTime(DateTime dt) {
        return dt.format('HH:mm:ss');
    }

    private static DateTime asGmtInstant(DateTime dt) {
        return DateTime.newInstanceGmt(
            dt.year(), dt.month(), dt.day(), dt.hour(), dt.minute(), dt.second());
    }

    private static Decimal daysOffset(DateTime dt) {
        Date d = Date.newInstance(dt.year(), dt.month(), dt.day());
        return Date.today().daysBetween(d);
    }

    private static String uuid() {
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0, 8)  + '-' +
               hex.substring(8, 12) + '-' +
               '4' + hex.substring(13, 16) + '-' +
               'a' + hex.substring(17, 20) + '-' +
               hex.substring(20, 32);
    }
}
