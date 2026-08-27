/**
 * One-time backfill: give every already-seeded escalated session's agent_router
 * step the 'escalate_to_human' tool-call output that the Analytics Escalation
 * Rate KPI actually reads.
 *
 * WHY: Escalation Rate counts sessions whose agent_router LLM_STEP output JSON
 * carries "gen_ai.output.tool_names":"escalate_to_human" (verified against the
 * live Skywave_Voice_Agent / Skywave_Airlines_Agent: end-type 'Escalated' and the
 * bare '__human__' topic drive NOTHING). The original seed wrote a plain-text
 * router output, so escalation read 0. Skywave_ObservabilitySeeder now bakes the
 * correct JSON for future (re)installs; this patches the rows already in the org.
 *
 * The daily refresh does NOT reseed the SObjects — it only date-shifts + Full-
 * Refreshes the streams — so this runs once. After it, Full-Refresh the
 * SDO_Analytics_AIAgentInteractionStep_v2 stream (Playwright refresh workflow or
 * Dev Console Skywave_DataStreamRunner) to carry the change into the DMO.
 *
 * Idempotent: safe to re-run (it just rewrites the same output).
 *   sf apex run --target-org si --file scripts/apex/fixEscalationRouterSteps.apex
 */
String DEMO_TAG = 'SKYWAVE_PHASE_4_5';

// __human__ (escalation hand-off) interactions for this demo's data.
Set<String> humanInts = new Set<String>();
for (SDO_Analytics_AiAgentInteraction_v2__c it : [
        SELECT External_ID__c FROM SDO_Analytics_AiAgentInteraction_v2__c
        WHERE Demo_Identifier__c = :DEMO_TAG AND Topic_API_Name__c = '__human__']) {
    humanInts.add(it.External_ID__c);
}
System.debug('escalation (__human__) interactions: ' + humanInts.size());

// The agent_router LLM step inside each — rewrite its output to the tool call.
List<SDO_Analytics_AIAgentInteractionStep_v2__c> toUpd =
    new List<SDO_Analytics_AIAgentInteractionStep_v2__c>();
for (SDO_Analytics_AIAgentInteractionStep_v2__c st : [
        SELECT Id, External_ID__c, AI_Agent_Interaction__c
        FROM SDO_Analytics_AIAgentInteractionStep_v2__c
        WHERE Demo_Identifier__c = :DEMO_TAG
          AND Name__c = 'agent_router'
          AND Ai_Agent_Interaction_Step_Type__c = 'LLM_STEP'
          AND AI_Agent_Interaction__c IN :humanInts]) {
    String rid = 'chatcmpl-' + st.External_ID__c.replaceAll('-', '').substring(0, 24);
    st.Output_Value__c =
        '{"gen_ai.response.finish_reasons":"tool_calls",'
      + '"gen_ai.output.tool_names":"escalate_to_human",'
      + '"gen_ai.response.id":"' + rid + '",'
      + '"mgr.output.payload_type":"llm_event"}';
    st.Input_Value__c =
        '{"stepType":"LLM_STEP","topic":"__human__",'
      + '"model":"llmgateway__OpenAIGPT4Omni",'
      + '"userMessage":"I still need help \\u2014 connect me to a person."}';
    toUpd.add(st);
}
update toUpd;
System.debug('patched agent_router escalation steps: ' + toUpd.size());
