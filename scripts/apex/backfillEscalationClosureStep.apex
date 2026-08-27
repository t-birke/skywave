/**
 * One-time backfill: give every already-seeded ESCALATED session a SESSION_END-
 * type interaction step named 'CLOSED_TRANSFERRED' — the exact signal the
 * Analytics Escalation Rate reads.
 *
 * WHY (verified by retrieving the semantic model formula via the Tableau
 * Semantics REST API, /ssot/semantic/models/Service_Agent_Analytics_SDM_e11):
 *   Escalation_Status_clc = { FIXED session :
 *       MAX( IF (stepType='SESSION_END' OR sessionEnded>=24h ago)
 *               AND [Interaction Step].[Name]='CLOSED_TRANSFERRED'
 *            THEN TRUE ELSE FALSE END ) }
 *   Escalated Sessions = COUNTD(sessions where Escalation_Status)
 *   Escalation Rate = Escalated Sessions / Unique Sessions
 * So escalation is NOT the end-type, NOT the __human__ topic, NOT escalate_to_human
 * — it's a SESSION_END-type step named CLOSED_TRANSFERRED. Setting the step type to
 * SESSION_END satisfies the OR-branch, so even <24h-old sessions count.
 *
 * Skywave_ObservabilitySeeder now bakes this closure step for future (re)installs;
 * this patches the rows already in the org. The daily refresh does NOT reseed —
 * it date-shifts + Full-Refreshes the streams — so this runs once, then Full-
 * Refresh the SDO_Analytics_AIAgentInteractionStep_v2 stream.
 *
 * Idempotent: skips SESSION_END interactions that already have a CLOSED_TRANSFERRED
 * step, so re-running inserts nothing.
 *   sf apex run --target-org si --file scripts/apex/backfillEscalationClosureStep.apex
 */
String DEMO_TAG = 'SKYWAVE_PHASE_4_5';

// Escalated sessions for this demo.
Set<String> escSessions = new Set<String>();
for (SDO_Analytics_AIAgentSession_v2__c s : [
        SELECT External_ID__c FROM SDO_Analytics_AIAgentSession_v2__c
        WHERE Demo_Identifier__c = :DEMO_TAG AND AI_Agent_Session_End_Type__c = 'Escalated']) {
    escSessions.add(s.External_ID__c);
}
System.debug('escalated sessions: ' + escSessions.size());

// SESSION_END interactions of those sessions.
Map<String, SDO_Analytics_AiAgentInteraction_v2__c> endByExtId =
    new Map<String, SDO_Analytics_AiAgentInteraction_v2__c>();
for (SDO_Analytics_AiAgentInteraction_v2__c it : [
        SELECT External_ID__c, Telemetry_Trace__c, Start_Days__c, Start_Time__c,
               End_Days__c, End_Time__c
        FROM SDO_Analytics_AiAgentInteraction_v2__c
        WHERE Demo_Identifier__c = :DEMO_TAG AND Ai_Agent_Interaction_Type__c = 'SESSION_END'
          AND AI_Agent_Session__c IN :escSessions]) {
    endByExtId.put(it.External_ID__c, it);
}
System.debug('SESSION_END interactions to close: ' + endByExtId.size());

// Idempotency: skip interactions that already have a CLOSED_TRANSFERRED step.
for (SDO_Analytics_AIAgentInteractionStep_v2__c st : [
        SELECT AI_Agent_Interaction__c FROM SDO_Analytics_AIAgentInteractionStep_v2__c
        WHERE Demo_Identifier__c = :DEMO_TAG AND Name__c = 'CLOSED_TRANSFERRED'
          AND AI_Agent_Interaction__c IN :endByExtId.keySet()]) {
    endByExtId.remove(st.AI_Agent_Interaction__c);
}

List<SDO_Analytics_AIAgentInteractionStep_v2__c> toInsert =
    new List<SDO_Analytics_AIAgentInteractionStep_v2__c>();
for (SDO_Analytics_AiAgentInteraction_v2__c it : endByExtId.values()) {
    SDO_Analytics_AIAgentInteractionStep_v2__c cs = new SDO_Analytics_AIAgentInteractionStep_v2__c();
    cs.External_ID__c = 'clt-' + it.External_ID__c;   // deterministic -> re-run safe
    cs.Demo_Identifier__c = DEMO_TAG;
    cs.AI_Agent_Interaction__c = it.External_ID__c;
    cs.Ai_Agent_Interaction_Step_Type__c = 'SESSION_END';
    cs.Name__c = 'CLOSED_TRANSFERRED';
    cs.Input_Value__c = '';
    cs.Output_Value__c = '';
    cs.Telemetry_Trace_Span_Id__c = it.Telemetry_Trace__c;
    cs.Start_Days__c = it.Start_Days__c;
    cs.Start_Time__c = it.Start_Time__c;
    cs.End_Days__c = it.End_Days__c;
    cs.End_Time__c = it.End_Time__c;
    toInsert.add(cs);
}
insert toInsert;
System.debug('inserted CLOSED_TRANSFERRED closure steps: ' + toInsert.size());
