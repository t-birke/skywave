/**
 * Resolves the visitor's declared survey context for the
 * Skywave_Airlines_Agent. Input: MessagingSession.ConversationId
 * (provided by the agent's @MessagingSession.ConversationId linked
 * variable). Output: structured JSON + natural-language summary the
 * agent uses for personalised reasoning.
 *
 * Implementation:
 *   - Looks up the anonymous Contact created by Skywave_ContactUpsert
 *     (keyed on Skywave_Conversation_Id__c).
 *   - Returns the cached survey JSON + summary that was written when
 *     the consumer site's "thanks" screen rendered.
 *
 * Returns silently with empty results if no Contact is found (anonymous
 * sessions, demo without survey, race between the chat-start POST and
 * the agent's first reasoning turn).
 */
public with sharing class Skywave_ResolveSession {

    public class Input {
        // PRIMARY (MIAW User Verification): the verified session's
        // MessagingEndUser.MessagingPlatformKey, e.g.
        //   v2/iamessage/AUTH/Skywave_Identity/uid:<deviceId>
        // We extract the deviceId after "uid:" and resolve the Contact by
        // Contact.Session_Id__c = deviceId — the SAME key the website uses
        // (Skywave_WebsiteResolveSession + the upsert trigger), so agent and
        // website resolve the identical Contact. Stable across conversations
        // and devices. Sourced from the @MessagingEndUser.MessagingPlatformKey
        // linked variable. Takes precedence over conversationId when present.
        @InvocableVariable(label='Messaging Platform Key (verified session)' required=false)
        public String sessionKey;

        @InvocableVariable(label='Conversation Id' required=false)
        public String conversationId;

        // Studio-preview escape hatch. The @MessagingSession.ConversationId
        // linked variable's Override Value picker is platform-broken
        // (Salesforce-confirmed May 2026), so live-test mode can't seed
        // ConversationId. Instead the agent passes @variables.testingSession
        // here; if conversationId is blank we fall back to this value.
        // Real chat ignores this — conversationId is always populated.
        @InvocableVariable(label='Testing Session (studio fallback)' required=false)
        public String testingSession;
    }

    // Extract the deviceId from a MessagingPlatformKey. Returns null if the
    // key isn't a verified (uid:) key. Format:
    //   v2/iamessage/AUTH/<authConfig>/uid:<deviceId>
    @TestVisible
    private static String deviceIdFromPlatformKey(String platformKey) {
        if (String.isBlank(platformKey)) return null;
        Integer i = platformKey.indexOf('uid:');
        if (i < 0) return null;
        String deviceId = platformKey.substring(i + 4).trim();
        return String.isBlank(deviceId) ? null : deviceId;
    }

    public class Output {
        @InvocableVariable(label='Number of survey answers found')
        public Integer answerCount;

        @InvocableVariable(label='Question/answer pairs as JSON')
        public String responsesJson;

        @InvocableVariable(label='Natural-language summary for agent reasoning')
        public String summary;

        @InvocableVariable(label='Resolved Contact Id (for booking actions)')
        public String contactId;

        @InvocableVariable(label='Home airport (IATA) derived from IP geolocation')
        public String homeAirport;

        @InvocableVariable(label='Profile ever collected')
        public Boolean profileEverCollected;
    }

    @InvocableMethod(
        label='Skywave: Resolve session context'
        description='Look up the visitor\'s declared survey answers from the anonymous Contact created at survey-complete time, keyed on the chat ConversationId. Returns structured JSON and a one-line natural-language summary.'
        category='Skywave'
    )
    public static List<Output> resolve(List<Input> inputs) {
        List<Output> outs = new List<Output>();
        for (Input request : inputs) {
            // PRIMARY: verified-session deviceId (MIAW User Verification).
            String deviceId = deviceIdFromPlatformKey(request.sessionKey);
            if (String.isNotBlank(deviceId)) {
                Output byDevice = resolveByDeviceId(deviceId);
                if (byDevice != null) { outs.add(byDevice); continue; }
                // else fall through to the legacy conversation-id path
            }
            // LEGACY fallback: conversation-id keyed (pre-User-Verification),
            // then demo-seed/mint inside resolveOne.
            String key = String.isNotBlank(request.conversationId)
                ? request.conversationId
                : request.testingSession;
            outs.add(resolveOne(key));
        }
        return outs;
    }

    // Resolve the visitor's Contact by deviceId (Contact.Session_Id__c), the
    // canonical website key. Returns a populated Output, or null if no Contact
    // matches (so the caller can fall through to the legacy path / demo seed).
    private static Output resolveByDeviceId(String deviceId) {
        List<Contact> contacts = [
            SELECT Id, Skywave_Survey_Json__c, Skywave_Survey_Summary__c,
                   Home_Airport__c, MailingCity, Profile_Completed__c
            FROM Contact
            WHERE Session_Id__c = :deviceId
            LIMIT 1
        ];
        if (contacts.isEmpty()) return null;
        return buildOutput(contacts[0]);
    }

    private static Output resolveOne(String conversationId) {
        Output out = new Output();
        out.answerCount = 0;
        out.responsesJson = '{}';
        out.summary = '';
        out.profileEverCollected = false;

        if (String.isBlank(conversationId)) {
            return out;
        }

        List<Contact> contacts = [
            SELECT Id, Skywave_Survey_Json__c, Skywave_Survey_Summary__c,
                   Home_Airport__c, MailingCity, Profile_Completed__c
            FROM Contact
            WHERE Skywave_Conversation_Id__c = :conversationId
            LIMIT 1
        ];
        Contact c;
        if (contacts.isEmpty()) {
            // No Contact for this conversation yet. There are three reasons
            // we land here:
            //   - Visitor skipped/blocked the SDK cookie on the consumer site.
            //   - Visitor opened chat without finishing the survey first.
            //   - The chat lives on a secondary Experience Cloud page that
            //     doesn't run our consumer-site JS at all (no deviceId
            //     prechat, no website-side Contact ever existed).
            //
            // Try to fall back to the curated "demo seed" Contact —
            // exactly one Contact in the org carries Skywave_Demo_Seed__c=
            // true. Borrowing it gives the agent a populated survey + a
            // backlog of bookings to talk about, instead of the visitor
            // hitting "you have no flights" the moment they ask. The seed
            // also has Profile_Completed__c=true, so the booking ladder
            // will skip the profile form (no risk of overwriting the
            // seed's curated identity).
            //
            // Final fall-through (no seed exists in the org): mint a fresh
            // placeholder Contact, same shape as before, so downstream
            // booking actions still have a real Id to write against.
            List<Contact> seeds = [
                SELECT Id, Skywave_Survey_Json__c, Skywave_Survey_Summary__c,
                       Home_Airport__c, MailingCity, Profile_Completed__c
                FROM Contact
                WHERE Skywave_Demo_Seed__c = true
                LIMIT 1
            ];
            if (!seeds.isEmpty()) {
                c = seeds[0];
            } else {
                c = new Contact(
                    LastName = conversationId,
                    Skywave_Conversation_Id__c = conversationId
                );
                insert c;
            }
        } else {
            c = contacts[0];
        }
        return buildOutput(c);
    }

    // Shared Output builder — populates contactId, survey JSON/summary,
    // home-airport hint, profile flag from a resolved Contact. Used by both
    // the deviceId path (verified) and the conversation-id path (legacy).
    private static Output buildOutput(Contact c) {
        Output out = new Output();
        out.answerCount = 0;
        out.responsesJson = '{}';
        out.summary = '';
        out.contactId = c.Id;
        out.homeAirport = c.Home_Airport__c;
        out.profileEverCollected = (c.Profile_Completed__c == true);

        if (String.isNotBlank(c.Skywave_Survey_Json__c)) {
            out.responsesJson = c.Skywave_Survey_Json__c;
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(c.Skywave_Survey_Json__c);
                out.answerCount = parsed != null ? parsed.size() : 0;
            } catch (Exception e) {
                out.answerCount = 0;
            }
        }
        if (String.isNotBlank(c.Skywave_Survey_Summary__c)) {
            out.summary = c.Skywave_Survey_Summary__c;
        }
        // Weave the IP-derived home airport into the summary so the booking
        // subagent can default the origin without a separate action.
        if (String.isNotBlank(c.Home_Airport__c)) {
            String locale = String.isNotBlank(c.MailingCity)
                ? c.MailingCity + ' (nearest Skywave airport ' + c.Home_Airport__c + ')'
                : c.Home_Airport__c;
            out.summary = (String.isBlank(out.summary) ? '' : out.summary + ' ')
                + 'The visitor appears to be near ' + locale
                + '; use ' + c.Home_Airport__c + ' as the default origin airport unless they say otherwise.';
        }

        return out;
    }
}
