/**
 * freshenObservabilityDates.apex — keep the observability seed data "today-fresh".
 *
 * WHY THIS EXISTS
 * Almost every timestamp the observability DMOs consume is a TODAY()-relative
 * FORMULA field on the SDO_Analytics_* objects, e.g.
 *   Start_Timestamp__c = DATETIMEVALUE(TEXT(TODAY() + Start_Days__c) + " " + Start_Time__c)
 * Those roll forward on their own — the seed data is a permanent rolling window
 * (Start_Days__c is a fixed -14..-1 offset). The ONLY exceptions are two STORED
 * (non-formula) DateTime fields that Skywave_ObservabilitySeeder writes as absolute
 * instants and therefore freeze at seed time:
 *   - SDO_Analytics_AIAgentSession_v2__c.End_Timestamp__c
 *   - SDO_Analytics_AIAgentSessionParticipa_v2__c.End_Timestamp__c
 * Both are mapped to STDM DMOs (AiAgentSession.EndTimestamp /
 * AiAgentSessionParticipant.EndTimestamp), so once N days pass a session shows a
 * fresh (formula) Start but a stale End N days earlier — a negative duration.
 *
 * WHAT IT DOES
 * Re-aligns each stored End_Timestamp to the SAME calendar day as its own
 * auto-freshened formula Start_Timestamp, preserving the time-of-day. Seeded
 * sessions never cross midnight (start hour 8..19, span < ~15 min), so
 * "End.date == Start.date" is the correct invariant.
 *
 * IDEMPOTENT: the shift is derived per row from the live divergence, so re-running
 * once the data is aligned is a no-op (shift = 0). Safe to run any number of times,
 * any number of days after seeding.
 *
 * AFTER RUNNING: Full-Refresh the data streams so Data Cloud re-ingests —
 *   node scripts/refreshDataStreams.mjs --target-org <org>
 * (DMOs are a frozen snapshot; the CRM fix is invisible on the dashboards until
 * the streams re-run.)
 *
 * Scoped to Demo_Identifier__c = SKYWAVE_PHASE_4_5 so coexisting DriveMax/QBrix
 * rows are never touched.
 */
// Inlined from Skywave_ObservabilitySeeder.DEMO_TAG (SSOT) so this maintenance
// script needs NO Apex-class access — the CI automation user (skywave.refresh.bot)
// runs it under a minimal profile and can't be granted access to the seeder class.
// This identifier is baked into all observability seed rows and never changes; if
// the seeder's DEMO_TAG ever does, update this literal to match.
String TAG = 'SKYWAVE_PHASE_4_5';
Integer sessionsShifted = 0;
Integer participantsShifted = 0;

List<SDO_Analytics_AIAgentSession_v2__c> sessions = [
    SELECT Id, Start_Timestamp__c, End_Timestamp__c
    FROM SDO_Analytics_AIAgentSession_v2__c
    WHERE Demo_Identifier__c = :TAG
      AND End_Timestamp__c != null
      AND Start_Timestamp__c != null];
for (SDO_Analytics_AIAgentSession_v2__c s : sessions) {
    Integer shift = s.End_Timestamp__c.dateGmt().daysBetween(s.Start_Timestamp__c.dateGmt());
    if (shift != 0) {
        s.End_Timestamp__c = s.End_Timestamp__c.addDays(shift);
        sessionsShifted++;
    }
}
if (!sessions.isEmpty()) update sessions;

List<SDO_Analytics_AIAgentSessionParticipa_v2__c> participants = [
    SELECT Id, Start_Timestamp__c, End_Timestamp__c
    FROM SDO_Analytics_AIAgentSessionParticipa_v2__c
    WHERE Demo_Identifier__c = :TAG
      AND End_Timestamp__c != null
      AND Start_Timestamp__c != null];
for (SDO_Analytics_AIAgentSessionParticipa_v2__c p : participants) {
    Integer shift = p.End_Timestamp__c.dateGmt().daysBetween(p.Start_Timestamp__c.dateGmt());
    if (shift != 0) {
        p.End_Timestamp__c = p.End_Timestamp__c.addDays(shift);
        participantsShifted++;
    }
}
if (!participants.isEmpty()) update participants;

System.debug(LoggingLevel.ERROR,
    '>>> freshenObservabilityDates: realigned ' + sessionsShifted + '/' + sessions.size()
    + ' sessions and ' + participantsShifted + '/' + participants.size() + ' participants'
    + ' (End_Timestamp -> formula Start day). Now Full-Refresh the streams.');
