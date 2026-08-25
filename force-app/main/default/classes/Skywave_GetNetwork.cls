/**
 * Agent action: returns the live Skywave route network (served cities + IATA
 * codes) sourced from the Skywave_Airport__mdt CMDT via Skywave_Airports.ALL.
 *
 * The agent grounds destination suggestions on this instead of a hardcoded
 * "bookable destinations by region" list baked into its prompt — add an airport
 * (a CMDT record) and the agent's suggestions include it with no agent
 * republish. search_flights remains the authoritative "do we actually fly there"
 * gate (it validates origin/destination against Flight__c).
 *
 * `without sharing`: the whole guest/bot agent-action pipeline runs without
 * sharing on a fresh org; CMDT reads need no object permissions regardless, so
 * the bot user only needs Apex-class access (granted on Skywave_Agent_User).
 */
public without sharing class Skywave_GetNetwork {

    // An invocable Request must expose at least one @InvocableVariable. The network
    // is the same for every visitor, so this input is optional and does not change
    // the result — it just lets the planner pass along the vibe/region it inferred.
    public class Request {
        @InvocableVariable(label='Vibe' description='Optional: the visitor\'s expressed vibe or region. Does NOT change the result — the full served network is always returned.')
        public String vibe;
    }

    public class Response {
        @InvocableVariable(label='Network' description='Comma-separated list of bookable cities with their IATA codes, e.g. "San Francisco (SFO), New York (JFK), London (LHR)".')
        public String network;
    }

    @InvocableMethod(
        label='Get Skywave Network'
        description='Returns the live list of cities Skywave serves (city name + IATA code). Ground destination suggestions on this list; never suggest a city that is not in it.'
    )
    public static List<Response> getNetwork(List<Request> requests) {
        List<String> parts = new List<String>();
        for (Skywave_Airports.Airport a : Skywave_Airports.ALL) {
            parts.add(a.city + ' (' + a.code + ')');
        }
        String net = String.join(parts, ', ');

        // Invocable contract: return one Response per input row (>=1).
        Integer n = (requests == null || requests.isEmpty()) ? 1 : requests.size();
        List<Response> out = new List<Response>();
        for (Integer i = 0; i < n; i++) {
            Response r = new Response();
            r.network = net;
            out.add(r);
        }
        return out;
    }
}
