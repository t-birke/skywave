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

    // Session outcome (STDM ssot__AiAgentSessionEndType__c). The Optimization
    // "Session Outcome" is a derived field: Deflected comes from a Deflection
    // score 4-5, Abandoned from Abandonment=TRUE / Deflection <3, and Escalated
    // from this end-type = 'escalated' (lowercase — the live-verified value the
    // escalation signal reads). The deflection/abandonment SCORES are seeded
    // separately per session (Ingestion API, scripts/datacloud/hero_obs/
    // seed_heroes.py outcomes) keyed off this end-type. Target mix across the
    // synthetic population: ~60% Deflected / ~30% Abandoned / ~10% Escalated.
    // Story: bookings deflect (agent resolved); seat-change requests fail — most
    // visitors abandon, ~a quarter escalate.
    private static final String OUTCOME_COMPLETED = 'Completed';   // -> Deflected (score 4-5)
    private static final String OUTCOME_ESCALATED = 'escalated';   // -> Escalated (lowercase, load-bearing)
    private static final String OUTCOME_ABANDONED = 'Abandoned';   // -> Abandoned (score <3 / Abandonment TRUE)
    // Share of seat-failure sessions that end abandoned (rest escalate) — tuned
    // so the population lands near ~30% Abandoned / ~10% Escalated.
    private static final Integer SEAT_ABANDON_PCT = 75;

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
                // NOTE: the 3 high-fidelity "hero" sessions are no longer seeded
                // here. Custom SObject DateTime fields truncate to whole seconds,
                // so the SDO path can't show the sub-second, random step timings a
                // real trace has. The heroes are now pushed straight into the STDM
                // DMOs (with true millisecond timings) via the Data Cloud Ingestion
                // API — see scripts/datacloud/hero_obs/. This seeder produces only
                // the lo-fi background population; hero code below is retained for
                // reference but intentionally not called.
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
            Integer daysBack = 2 + rand(14);                 // 2..15 days ago; the 3 hero sessions (day 1) always sort above these
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
            Boolean sessionHasSeatFail = false;   // drives the escalated/abandoned outcome

            for (Integer m = 0; m < momentCount; m++) {
                Archetype arch = pickArchetype(arches, totalWeight);
                if (arch.bucket == 'seat') sessionHasSeatFail = true;
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
                    // Interaction Start->End duration is what the dashboard
                    // reports as Average Agent Latency (NOT the message-to-
                    // message delta). Keep it to a realistic agent response
                    // time of 2-4s; a wider window here inflates the latency
                    // metric (e.g. 20-60s -> ~40s average).
                    DateTime turnEnd = turnStart.addSeconds(2 + rand(3));
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

                    // user + agent messages — keep within the interaction's
                    // 2-4s window: user speaks at start, agent replies at end.
                    messages.add(buildMessage(sessionUuid, interactionUuid,
                        userParticipantPlaceholder(sessionUuid), 'Input', pair[0],
                        turnStart));
                    messages.add(buildMessage(sessionUuid, interactionUuid,
                        agentParticipantPlaceholder(sessionUuid), 'Output', pair[1],
                        turnEnd));

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

                    // Inter-turn gap = realistic USER think/away time, which
                    // is independent of (and much longer than) the agent's
                    // 2-4s response time. In a chat the user often fires a
                    // question, switches to other work while the answer
                    // appears, then checks back much later to read and react.
                    // Model that with a wide, right-skewed gap rather than a
                    // flat few seconds: ~70% a normal reading pause (15-75s),
                    // ~30% a long away-from-keyboard gap (1.5-5 min).
                    Integer userGap = (rand(100) < 70)
                        ? 15 + rand(60)        // attentive: 15-75s
                        : 90 + rand(210);      // stepped away: 90-300s
                    cursor = turnEnd.addSeconds(userGap);
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
                    AIE_INTENT_DEF, sessionUuid, momentUuid, 'Categorized as ' + intentValue + '.',
                    startDays, sessionEnd));
                tagAssocs.add(makeTagAssoc(qualityScoreTagIdByValue.get(String.valueOf(score)),
                    'Quality_Score', sessionUuid, momentUuid, qualityReason(arch.bucket, score),
                    startDays, sessionEnd));
            }

            // ---- Session row
            SDO_Analytics_AIAgentSession_v2__c s = new SDO_Analytics_AIAgentSession_v2__c();
            s.External_ID__c = sessionUuid;
            s.Demo_Identifier__c = DEMO_TAG;
            s.AI_Agent_Channel_Type__c = 'SCRT2 - EmbeddedMessaging';
            // Outcome: seat-change requests fail in this demo — most visitors
            // abandon, the rest escalate; every other intent completes.
            s.AI_Agent_Session_End_Type__c = !sessionHasSeatFail
                ? OUTCOME_COMPLETED
                : (rand(100) < SEAT_ABANDON_PCT ? OUTCOME_ABANDONED : OUTCOME_ESCALATED);
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

    // ======================================================================
    //  HERO SESSIONS — three fully-scripted, high-fidelity traces that sit at
    //  the TOP of the session list (most recent, a few hours apart yesterday)
    //  and show the real per-turn step choreography — VARIABLE_UPDATE_STEP,
    //  TOPIC_STEP, LLM_STEP, ACTION_STEP (with the agent's REAL action names
    //  and realistic sub-second/second timings), TRUST_GUARDRAILS_STEP — plus
    //  populated assessments (outcome, quality score, quality reasoning) and
    //  moment request/response summaries. Modeled field-for-field on a real
    //  Skywave_Airlines_Agent session captured from the AIPlatform DMO.
    //
    //    #1 Combined  — a booking that COMPLETES (Q5) then a seat CHANGE that
    //                   fails; the visitor gives up -> ABANDONED.
    //    #2 Booking   — a clean end-to-end booking -> COMPLETED (Q5).
    //    #3 Seat fail — a seat UPGRADE that never applies -> ESCALATED (Q1).
    //  The story: flight booking works well; seat assignment does not.
    // ======================================================================

    private class StepSpec {
        String stype; String name; Integer offSec; Integer durSec;
        String inVal; String outVal; String errMsg;
        StepSpec(String t, String n, Integer o, Integer d) {
            stype = t; name = n; offSec = o; durSec = d;
        }
    }
    private class TurnSpec {
        String topic; String userText; String agentText; Integer gapAfterSec;
        List<StepSpec> steps;
        TurnSpec(String tp, String u, String a, Integer gap, List<StepSpec> s) {
            topic = tp; userText = u; agentText = a; gapAfterSec = gap; steps = s;
        }
    }
    private class MomentSpec {
        String intentValue; Integer score;
        String requestSummary; String responseSummary; String qualityReason;
        List<TurnSpec> turns;
        MomentSpec(String iv, Integer sc, String rq, String rs, String qr, List<TurnSpec> t) {
            intentValue = iv; score = sc; requestSummary = rq;
            responseSummary = rs; qualityReason = qr; turns = t;
        }
    }

    // ---- step / turn factories (keep the scripts below readable) ----------
    private static StepSpec vu(Integer off) {
        return new StepSpec('VARIABLE_UPDATE_STEP', '__state_update_action__', off, 0);
    }
    private static StepSpec topStep(String name) {                 // spans the whole turn
        return new StepSpec('TOPIC_STEP', name, 0, -1);
    }
    private static StepSpec llmStep(String name, Integer off) {
        return new StepSpec('LLM_STEP', name, off, 1);
    }
    private static StepSpec actStep(String name, Integer off, Integer dur, String inv, String outv) {
        StepSpec s = new StepSpec('ACTION_STEP', name, off, dur);
        s.inVal = inv; s.outVal = outv; return s;
    }
    private static StepSpec actErr(String name, Integer off, Integer dur, String inv, String outv, String err) {
        StepSpec s = actStep(name, off, dur, inv, outv); s.errMsg = err; return s;
    }
    private static StepSpec guardStep(Integer off) {
        StepSpec s = new StepSpec('TRUST_GUARDRAILS_STEP', 'InstructionAdherence', off, 1);
        s.inVal = '{"guardrail":"InstructionAdherence"}';
        s.outVal = '{"isPassed":true,"result":"PASSED"}';
        return s;
    }
    private static TurnSpec turn(String topic, String userText, String agentText,
                                 Integer gapAfter, List<StepSpec> steps) {
        return new TurnSpec(topic, userText, agentText, gapAfter, steps);
    }

    private static void seedHeroSessions() {
        String plannerId = resolvePlannerId();
        List<Id> endUserIds = resolveMessagingEndUserIds();

        List<SDO_Analytics_AIAgentSession_v2__c> sessions = new List<SDO_Analytics_AIAgentSession_v2__c>();
        List<SDO_Analytics_AIAgentSessionParticipa_v2__c> participants = new List<SDO_Analytics_AIAgentSessionParticipa_v2__c>();
        List<SDO_Analytics_AiAgentInteraction_v2__c> interactions = new List<SDO_Analytics_AiAgentInteraction_v2__c>();
        List<SDO_Analytics_AIAgentInteractionMessa_v2__c> messages = new List<SDO_Analytics_AIAgentInteractionMessa_v2__c>();
        List<SDO_Analytics_AIAgentInteractionStep_v2__c> steps = new List<SDO_Analytics_AIAgentInteractionStep_v2__c>();
        List<SDO_Analytics_AIAgentMoment_v2__c> moments = new List<SDO_Analytics_AIAgentMoment_v2__c>();
        List<SDO_Analytics_AIAgentMomentInteractio_v2__c> momentInts = new List<SDO_Analytics_AIAgentMomentInteractio_v2__c>();
        List<SDO_Analytics_AIAgentTagAssociation_v2__c> tagAssocs = new List<SDO_Analytics_AIAgentTagAssociation_v2__c>();

        // All three land yesterday (day 1), a few hours apart, so they are the
        // three most recent sessions and top the list. #1 latest -> very top.
        buildHeroSession(1, 18, 40, endUserForIndex(endUserIds, 0), plannerId, OUTCOME_ABANDONED,
            new List<MomentSpec>{ momentBookingLondonTokyo(), momentSeatChangeAbandoned() },
            sessions, participants, interactions, messages, steps, moments, momentInts, tagAssocs);
        buildHeroSession(1, 16, 20, endUserForIndex(endUserIds, 1), plannerId, OUTCOME_COMPLETED,
            new List<MomentSpec>{ momentBookingNyRome() },
            sessions, participants, interactions, messages, steps, moments, momentInts, tagAssocs);
        buildHeroSession(1, 14, 5, endUserForIndex(endUserIds, 2), plannerId, OUTCOME_ESCALATED,
            new List<MomentSpec>{ momentSeatUpgradeEscalated() },
            sessions, participants, interactions, messages, steps, moments, momentInts, tagAssocs);

        Database.insert(sessions, false);
        Database.insert(participants, false);
        Database.insert(interactions, false);
        Database.insert(messages, false);
        Database.insert(steps, false);
        Database.insert(moments, false);
        Database.insert(momentInts, false);
        Database.insert(tagAssocs, false);
    }

    private static void buildHeroSession(
            Integer daysBack, Integer hour, Integer minute, String endUserId,
            String plannerId, String endType, List<MomentSpec> momentSpecs,
            List<SDO_Analytics_AIAgentSession_v2__c> sessions,
            List<SDO_Analytics_AIAgentSessionParticipa_v2__c> participants,
            List<SDO_Analytics_AiAgentInteraction_v2__c> interactions,
            List<SDO_Analytics_AIAgentInteractionMessa_v2__c> messages,
            List<SDO_Analytics_AIAgentInteractionStep_v2__c> steps,
            List<SDO_Analytics_AIAgentMoment_v2__c> moments,
            List<SDO_Analytics_AIAgentMomentInteractio_v2__c> momentInts,
            List<SDO_Analytics_AIAgentTagAssociation_v2__c> tagAssocs) {

        String sessionUuid = uuid();
        DateTime sessionStart = DateTime.newInstance(
            Date.today().addDays(-daysBack), Time.newInstance(hour, minute, 0, 0));
        Decimal startDays = daysOffset(sessionStart);
        DateTime cursor = sessionStart;
        DateTime sessionEnd = sessionStart;

        for (MomentSpec ms : momentSpecs) {
            String momentUuid = uuid();
            DateTime momentStart = cursor;
            DateTime momentEnd = cursor;

            for (TurnSpec ts : ms.turns) {
                DateTime turnStart = cursor;
                // Turn length = latest end across the non-topic steps.
                Integer turnDur = 1;
                for (StepSpec sp : ts.steps) {
                    if (sp.stype == 'TOPIC_STEP') continue;
                    Integer e = sp.offSec + sp.durSec;
                    if (e > turnDur) turnDur = e;
                }
                DateTime turnEnd = turnStart.addSeconds(turnDur);
                String interactionUuid = uuid();
                String traceId = uuid();
                String spanId = uuid();
                String attr = '{"internalTraceId":"' + traceId.replaceAll('-', '')
                    + '","internalSpanId":"' + spanId.replaceAll('-', '').substring(0, 16) + '"}';

                SDO_Analytics_AiAgentInteraction_v2__c it = new SDO_Analytics_AiAgentInteraction_v2__c();
                it.External_ID__c = interactionUuid;
                it.Demo_Identifier__c = DEMO_TAG;
                it.AI_Agent_Session__c = sessionUuid;
                it.Topic_API_Name__c = ts.topic;
                it.Ai_Agent_Interaction_Type__c = 'TURN';
                it.Session_Owner__c = endUserId;
                it.Session_Owner_Object__c = (endUserId == null) ? null : 'MessagingEndUser';
                it.Start_Days__c = daysOffset(turnStart);
                it.Start_Time__c = formatTime(turnStart);
                it.End_Days__c = daysOffset(turnEnd);
                it.End_Time__c = formatTime(turnEnd);
                it.Telemetry_Trace__c = traceId;
                it.Telemetry_Trace_Span__c = spanId;
                interactions.add(it);

                messages.add(buildMessage(sessionUuid, interactionUuid,
                    userParticipantPlaceholder(sessionUuid), 'Input', ts.userText, turnStart));
                messages.add(buildMessage(sessionUuid, interactionUuid,
                    agentParticipantPlaceholder(sessionUuid), 'Output', ts.agentText, turnEnd));

                String prevStep = null;
                for (StepSpec sp : ts.steps) {
                    DateTime ss = turnStart.addSeconds(sp.offSec);
                    Integer d = (sp.stype == 'TOPIC_STEP') ? (turnDur - sp.offSec) : sp.durSec;
                    if (d < 0) d = 0;
                    DateTime se = ss.addSeconds(d);
                    SDO_Analytics_AIAgentInteractionStep_v2__c step = new SDO_Analytics_AIAgentInteractionStep_v2__c();
                    step.External_ID__c = uuid();
                    step.Demo_Identifier__c = DEMO_TAG;
                    step.AI_Agent_Interaction__c = interactionUuid;
                    step.Ai_Agent_Interaction_Step_Type__c = sp.stype;
                    step.Name__c = sp.name;
                    step.Input_Value__c = sp.inVal != null ? sp.inVal
                        : (sp.stype == 'LLM_STEP' ? llmInput(ts.topic, ts.userText)
                        : (sp.stype == 'VARIABLE_UPDATE_STEP' ? '{"variables":"updated"}' : ts.userText));
                    step.Output_Value__c = sp.outVal != null ? sp.outVal
                        : (sp.stype == 'VARIABLE_UPDATE_STEP' ? '{"success":true}' : ts.agentText);
                    if (sp.errMsg != null) step.Error_Message__c = sp.errMsg;
                    step.Attribute__c = attr;
                    step.Telemetry_Trace_Span_Id__c = traceId;
                    if (sp.stype == 'LLM_STEP') {
                        step.Gen_AI_Gateway_Request__c = 'chatcmpl-' + traceId.replaceAll('-', '').substring(0, 20);
                        step.Gen_AI_Gateway_Response__c = 'chatcmpl-' + spanId.replaceAll('-', '').substring(0, 20);
                        step.Generation__c = uuid();
                        step.Pre_step_Variable__c = uuid();
                        step.Post_step_Variable__c = uuid();
                    }
                    step.Start_Days__c = daysOffset(ss);
                    step.Start_Time__c = formatTime(ss);
                    step.End_Days__c = daysOffset(se);
                    step.End_Time__c = formatTime(se);
                    step.Previous_Step__c = prevStep;
                    steps.add(step);
                    prevStep = step.External_ID__c;
                }

                SDO_Analytics_AIAgentMomentInteractio_v2__c mi = new SDO_Analytics_AIAgentMomentInteractio_v2__c();
                mi.External_ID__c = uuid();
                mi.Demo_Identifier__c = DEMO_TAG;
                mi.AI_Agent_Moment_Id__c = momentUuid;
                mi.Interaction_Id__c = interactionUuid;
                mi.Start_Days__c = daysOffset(turnStart);
                mi.Start_Time__c = formatTime(turnStart);
                momentInts.add(mi);

                momentEnd = turnEnd;
                sessionEnd = turnEnd;
                cursor = turnEnd.addSeconds(ts.gapAfterSec);
            }

            SDO_Analytics_AIAgentMoment_v2__c moment = new SDO_Analytics_AIAgentMoment_v2__c();
            moment.External_ID__c = momentUuid;
            moment.Demo_Identifier__c = DEMO_TAG;
            moment.AI_Agent_Session__c = sessionUuid;
            moment.AI_Agent_API_Name__c = AGENT_API_NAME;
            moment.AI_Agent_Version_API_Name__c = AGENT_API_NAME;
            moment.Request_Summary_Text__c = ms.requestSummary;
            moment.Response_Summary_Text__c = ms.responseSummary;
            moment.Start_Days__c = daysOffset(momentStart);
            moment.Start_Time__c = formatTime(momentStart);
            moment.End_Days__c = daysOffset(momentEnd);
            moment.End_Time__c = formatTime(momentEnd);
            moments.add(moment);

            tagAssocs.add(makeTagAssoc(intentTagIdByValue.get(ms.intentValue),
                AIE_INTENT_DEF, sessionUuid, momentUuid, 'Categorized as ' + ms.intentValue + '.',
                startDays, momentEnd));
            tagAssocs.add(makeTagAssoc(qualityScoreTagIdByValue.get(String.valueOf(ms.score)),
                'Quality_Score', sessionUuid, momentUuid, ms.qualityReason, startDays, momentEnd));
        }

        // ---- Session row
        SDO_Analytics_AIAgentSession_v2__c s = new SDO_Analytics_AIAgentSession_v2__c();
        s.External_ID__c = sessionUuid;
        s.Demo_Identifier__c = DEMO_TAG;
        s.AI_Agent_Channel_Type__c = 'SCRT2 - EmbeddedMessaging';
        s.AI_Agent_Session_End_Type__c = endType;
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

        // ---- SESSION_END terminator interaction.
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

    private static String endUserForIndex(List<Id> ids, Integer idx) {
        if (ids == null || ids.isEmpty()) return null;
        return ids[Math.mod(idx, ids.size())];
    }

    // ---- Hero moment scripts ----------------------------------------------
    // A clean, end-to-end First Class booking (LHR -> HND). Completes at Q5.
    private static MomentSpec momentBookingLondonTokyo() {
        String cid = '003gK00000LpQ1aAAF';
        List<TurnSpec> turns = new List<TurnSpec>{
            turn('flight_booking',
                'I\'d like to book a First Class flight from London to Tokyo for next Monday.',
                'I found a few First Class options from London Heathrow to Tokyo Haneda for Monday — here are the flights. Tap **Book** on the one you\'d like.',
                22, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('agent_router', 0),
                    actStep('resolve_session', 1, 1,
                        '{"conversationId":"01JHXG7...","sessionKey":"...AUTH/Skywave_MIAW/uid:dvc_8f31a2"}',
                        '{"success":true,"contactId":"' + cid + '","summary":"Frequent LHR traveller; prefers First cabin","profileEverCollected":true}'),
                    vu(2),
                    actStep('get_bookings', 2, 1, '{"contactId":"' + cid + '"}',
                        '{"success":true,"bookingCount":0,"bookings":[]}'),
                    vu(3), llmStep('flight_booking', 3),
                    actStep('search_flights', 4, 1,
                        '{"origin":"LHR","destination":"HND","departureDate":"2026-06-08","fareClass":"First"}',
                        '{"success":true,"message":"3 options returned","flightSummary":"3 First Class itineraries LHR-HND from $6,650"}'),
                    vu(5)
                }),
            turn('flight_booking', 'Book flight SW2200',
                'Great — **SW2200** in First is held for you. Please complete your details so I can issue the ticket.',
                34, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('flight_booking', 0),
                    actStep('book_flight', 1, 1,
                        '{"contactId":"' + cid + '","flightId":"SW2200","fareClass":"First","travelDate":"2026-06-08"}',
                        '{"success":true,"selectedFlightId":"a08gK000000pQ2rQAE","selectedFareClass":"First","selectedTravelDate":"2026-06-08"}'),
                    vu(2),
                    actStep('present_profile_form', 2, 1, '{"contactId":"' + cid + '"}',
                        '{"success":true,"formData":"<SkywaveProfileForm rendered>"}'),
                    vu(3)
                }),
            turn('flight_booking', 'Profile created',
                'Thanks! Your booking **SW-3F2K** is reserved for **$6,650.00**. Choose how you\'d like to pay.',
                26, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('flight_booking', 0),
                    actStep('ack_profile_form', 1, 1,
                        '{"contactId":"' + cid + '","flightId":"a08gK000000pQ2rQAE","fareClass":"First","travelDate":"2026-06-08"}',
                        '{"success":true,"bookingCode":"SW-3F2K","totalCharged":"$6,650.00"}'),
                    vu(2),
                    actStep('present_payment_form', 2, 1,
                        '{"contactId":"' + cid + '","bookingCode":"SW-3F2K","totalCharged":"$6,650.00"}',
                        '{"success":true,"formData":"<SkywavePaymentForm rendered>"}'),
                    vu(3)
                }),
            turn('flight_booking', 'Payment completed',
                'Your First Class flight from London to Tokyo is confirmed — total **$6,650.00**, confirmation code **SW-3F2K**. Is there anything else I can help with?',
                31, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('flight_booking', 0),
                    actStep('confirm_booking', 1, 2, '{"contactId":"' + cid + '","bookingCode":"SW-3F2K"}',
                        '{"success":true,"confirmedCount":1,"confirmationCodes":"SW-3F2K","totalCharged":"$6,650.00"}'),
                    vu(3), guardStep(4)
                })
        };
        return new MomentSpec('Flight Search and Booking', 5,
            'I want to book a First Class flight from London to Tokyo for next Monday.',
            'The agent guided the user through the booking process, confirming the First Class flight from London to Tokyo with a total charge of $6,650 and provided a booking code.',
            'The agent understood the request, searched Skywave flights, captured the traveler profile, took payment, and confirmed the ticket end-to-end — quoting the confirmation code SW-3F2K and the $6,650.00 total. Fully resolved in a clear, on-topic exchange.',
            turns);
    }

    // The seat CHANGE that fails — the seat map never loads and the visitor
    // gives up (mirrors the reference session). Q1, session ends abandoned.
    private static MomentSpec momentSeatChangeAbandoned() {
        List<TurnSpec> turns = new List<TurnSpec>{
            turn('seat_selection', 'Actually, can you change my seat on that booking to 1A?',
                'Let me pull up the seat map for **SW-3F2K** so you can choose 1A…',
                20, new List<StepSpec>{
                    vu(0), topStep('seat_selection'), llmStep('agent_router', 0),
                    actStep('check_seat_enabled', 1, 1, '{"ignored":""}', '{"success":true,"enabled":true}'),
                    vu(2), llmStep('seat_selection', 2),
                    actStep('get_segment_count', 3, 1, '{"bookingCode":"SW-3F2K"}',
                        '{"success":true,"segmentCount":1}'),
                    vu(4),
                    actErr('present_seat_map', 5, 18,
                        '{"bookingCode":"SW-3F2K","flightNumber":""}',
                        '{"success":false,"message":"Unable to build seat map"}',
                        'SegmentResolutionException: no flight segment id returned for booking SW-3F2K. The seat-map service could not resolve the segment automatically, so the seat map was not generated and seat 1A was never assigned.'),
                    vu(23), guardStep(24)
                }),
            turn('seat_selection', 'It\'s still not letting me pick a seat. This is frustrating.',
                'I\'m sorry — I still can\'t retrieve the seat map for this flight, so I\'m unable to change your seat here. You can try again in a little while, or reach our team by phone and they\'ll move you to 1A.',
                0, new List<StepSpec>{
                    vu(0), topStep('seat_selection'), llmStep('seat_selection', 0),
                    actErr('present_seat_map', 1, 14, '{"bookingCode":"SW-3F2K"}',
                        '{"success":false,"message":"Unable to build seat map"}',
                        'SegmentResolutionException: seat-map generation failed again for booking SW-3F2K; segment id unavailable. Seat change not applied.'),
                    vu(15), guardStep(16)
                })
        };
        return new MomentSpec('Seat Change Requests', 1,
            'I want to select seat 1A for my flight.',
            'The agent requested the flight segment ID to assign seat 1A but was unable to retrieve it automatically. The user expressed frustration and ended the interaction.',
            'The agent recognized the seat-change request and tried to open the seat map, but the flight segment could not be retrieved automatically, so the seat map never loaded and seat 1A was never assigned. The request went unresolved and the visitor abandoned the conversation in frustration.',
            turns);
    }

    // A clean end-to-end Business booking (JFK -> FCO). Completes at Q5.
    private static MomentSpec momentBookingNyRome() {
        String cid = '003gK00000MxT7bAAF';
        List<TurnSpec> turns = new List<TurnSpec>{
            turn('flight_booking', 'Book me a Business class flight from New York to Rome on the 14th.',
                'Here are Business Class options from New York JFK to Rome Fiumicino on the 14th. Tap **Book** on the one you\'d like.',
                24, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('agent_router', 0),
                    actStep('resolve_session', 1, 1,
                        '{"conversationId":"01JHZP2...","sessionKey":"...AUTH/Skywave_MIAW/uid:dvc_2b70c9"}',
                        '{"success":true,"contactId":"' + cid + '","summary":"Based in New York; prefers Business cabin","profileEverCollected":true}'),
                    vu(2),
                    actStep('get_bookings', 2, 1, '{"contactId":"' + cid + '"}',
                        '{"success":true,"bookingCount":0,"bookings":[]}'),
                    vu(3), llmStep('flight_booking', 3),
                    actStep('search_flights', 4, 1,
                        '{"origin":"JFK","destination":"FCO","departureDate":"2026-06-14","fareClass":"Business"}',
                        '{"success":true,"message":"4 options returned","flightSummary":"4 Business itineraries JFK-FCO from $3,180"}'),
                    vu(5)
                }),
            turn('flight_booking', 'Book flight SW1450',
                '**SW1450** in Business is held for you. Please complete your details so I can issue the ticket.',
                28, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('flight_booking', 0),
                    actStep('book_flight', 1, 1,
                        '{"contactId":"' + cid + '","flightId":"SW1450","fareClass":"Business","travelDate":"2026-06-14"}',
                        '{"success":true,"selectedFlightId":"a08gK000000pT4kQAE","selectedFareClass":"Business","selectedTravelDate":"2026-06-14"}'),
                    vu(2),
                    actStep('present_profile_form', 2, 1, '{"contactId":"' + cid + '"}',
                        '{"success":true,"formData":"<SkywaveProfileForm rendered>"}'),
                    vu(3)
                }),
            turn('flight_booking', 'Profile created',
                'Thanks! Your booking **SW-9R7Q** is reserved for **$3,180.00**. Choose how you\'d like to pay.',
                23, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('flight_booking', 0),
                    actStep('ack_profile_form', 1, 1,
                        '{"contactId":"' + cid + '","flightId":"a08gK000000pT4kQAE","fareClass":"Business","travelDate":"2026-06-14"}',
                        '{"success":true,"bookingCode":"SW-9R7Q","totalCharged":"$3,180.00"}'),
                    vu(2),
                    actStep('present_payment_form', 2, 1,
                        '{"contactId":"' + cid + '","bookingCode":"SW-9R7Q","totalCharged":"$3,180.00"}',
                        '{"success":true,"formData":"<SkywavePaymentForm rendered>"}'),
                    vu(3)
                }),
            turn('flight_booking', 'Payment completed',
                'You\'re all set — Business Class from New York to Rome is confirmed for **$3,180.00**, confirmation code **SW-9R7Q**. Anything else I can help with?',
                18, new List<StepSpec>{
                    vu(0), topStep('flight_booking'), llmStep('flight_booking', 0),
                    actStep('confirm_booking', 1, 2, '{"contactId":"' + cid + '","bookingCode":"SW-9R7Q"}',
                        '{"success":true,"confirmedCount":1,"confirmationCodes":"SW-9R7Q","totalCharged":"$3,180.00"}'),
                    vu(3), guardStep(4)
                })
        };
        return new MomentSpec('Flight Search and Booking', 5,
            'Book me a Business class flight from New York to Rome on the 14th.',
            'The agent searched Skywave flights, collected the traveler\'s details, took payment, and confirmed a Business Class New York–Rome booking for $3,180 with a confirmation code.',
            'The agent handled the booking cleanly end-to-end — search, profile, payment, and confirmation — and quoted the confirmation code SW-9R7Q and the $3,180.00 total. Fully resolved.',
            turns);
    }

    // A seat UPGRADE that never applies — the seat map fails and the agent
    // hands off to a human. Q1, session ends escalated.
    private static MomentSpec momentSeatUpgradeEscalated() {
        String cid = '003gK00000MxT7bAAF';
        List<TurnSpec> turns = new List<TurnSpec>{
            turn('seat_selection', 'Can you upgrade my seat to Business on my Rome flight?',
                'Let me open the seat map so I can move you into Business…',
                22, new List<StepSpec>{
                    vu(0), topStep('seat_selection'), llmStep('agent_router', 0),
                    actStep('resolve_session', 1, 1,
                        '{"conversationId":"01JJ0T5...","sessionKey":"...AUTH/Skywave_MIAW/uid:dvc_2b70c9"}',
                        '{"success":true,"contactId":"' + cid + '","summary":"Based in New York; prefers Business cabin"}'),
                    vu(2),
                    actStep('get_bookings', 2, 1, '{"contactId":"' + cid + '"}',
                        '{"success":true,"bookingCount":1,"singleBookingCode":"SW-9R7Q"}'),
                    vu(3),
                    actStep('check_seat_enabled', 3, 1, '{"ignored":""}', '{"success":true,"enabled":true}'),
                    vu(4), llmStep('seat_selection', 4),
                    actStep('get_segment_count', 5, 1, '{"bookingCode":"SW-9R7Q"}',
                        '{"success":true,"segmentCount":1}'),
                    vu(6),
                    actErr('present_seat_map', 7, 16, '{"bookingCode":"SW-9R7Q"}',
                        '{"success":false,"message":"Unable to build seat map"}',
                        'SeatMapUnavailableException: cabin-upgrade seat map could not be generated for booking SW-9R7Q; segment fare-class inventory lookup failed. No seat was reassigned.'),
                    vu(23), guardStep(24)
                }),
            turn('seat_selection', 'Are you able to do the upgrade?',
                'I\'m sorry — the seat map didn\'t load, so I couldn\'t apply the Business upgrade here. I\'ll connect you with a Skywave agent who can complete the upgrade for you.',
                0, new List<StepSpec>{
                    vu(0), topStep('seat_selection'), llmStep('seat_selection', 0),
                    actErr('present_seat_map', 1, 13, '{"bookingCode":"SW-9R7Q"}',
                        '{"success":false,"message":"Unable to build seat map"}',
                        'SeatMapUnavailableException: seat-map generation failed again for booking SW-9R7Q; segment inventory unavailable. Upgrade not applied.'),
                    vu(14), guardStep(15)
                })
        };
        return new MomentSpec('Seat Upgrade Requests', 1,
            'Can you upgrade me to a seat in Business for my Rome flight?',
            'The agent tried to open the seat map to process the upgrade but the seat map failed to load, so the upgrade could not be applied. The visitor was frustrated and the session was escalated to a human agent.',
            'The agent understood the upgrade request and attempted to load the seat map, but the seat-map service failed and no seat was reassigned, so the Business upgrade was never applied. The request went unresolved and the session was escalated to a human agent.',
            turns);
    }

    // Realistic, analyst-style quality reasoning keyed to intent + score —
    // replaces the old canned "Quality score N". Drives Quality Score Reasoning.
    private static String qualityReason(String bucket, Integer score) {
        if (bucket == 'seat') {
            return 'The agent recognized the seat request but could not retrieve the flight '
                + 'segment, so the seat map never loaded and no seat was assigned. The request '
                + 'went unresolved and the visitor was left frustrated.';
        }
        if (bucket == 'booking' && score >= 4) {
            return 'The agent understood the request, searched Skywave flights, and drove the '
                + 'booking through to a confirmed, paid ticket, quoting the confirmation code '
                + 'and total. Fully resolved.';
        }
        if (score >= 4) {
            return 'The agent understood the request and resolved it accurately within a couple '
                + 'of turns, with clear and relevant responses.';
        }
        if (score == 3) {
            return 'The agent stayed on topic and partially addressed the request, but left the '
                + 'visitor to take the next step rather than fully resolving it.';
        }
        return 'The response was only loosely relevant to the request and did not move the '
            + 'visitor toward a resolution.';
    }

    private static String llmInput(String topic, String userText) {
        return '{"stepType":"LLM_STEP","topic":"' + topic
            + '","model":"llmgateway__OpenAIGPT4Omni","userMessage":'
            + JSON.serialize(userText) + '}';
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
