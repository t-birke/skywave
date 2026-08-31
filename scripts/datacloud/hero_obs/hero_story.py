"""
The 4 Skywave "hero" sessions — high-fidelity, millisecond-precise STDM traces
pushed straight into the canonical DMOs via the Data Cloud Ingestion API (Path 5).

Why this file exists: custom SObject DateTime fields (the SDO/QBrix Path-4 seeder)
truncate to whole seconds, so the SDO trace can never show the sub-second, random
timings a real session has. These 3 sessions are written natively into the DMOs
instead, with real millisecond step durations sampled from a live
Skywave_Airlines_Agent session.

Everything here mirrors a REAL current-agent trace (verified 2026-08-26 against
live AIPlatform rows):
  * Session/interaction/step/etc. Ids are real UUIDs (deterministic UUID5 so the
    daily re-push UPSERTs the same rows instead of duplicating).
  * Per-turn step choreography: TOPIC_STEP -> LLM_STEP(agent_router, the routing
    "reasoning") -> LLM_STEP(<subagent>) -> ACTION_STEP(s), with instantaneous
    VARIABLE_UPDATE_STEP ("variable assignment") steps interspersed and a
    TRUST_GUARDRAILS_STEP at the end.
  * Real payload shapes — compact double-quote JSON (verified against live
    AIPlatform rows; NOT python-repr):
      LLM input  = {"af.request_id":..,"gen_ai.request.model":"llmgateway__GPT41",
                    "gen_ai.input.messages":"<json messages>","gen_ai.request.id":..,
                    "af.prompt_template_dev_name":"Atlas__AgentGraphReasoningPrompt"}
      LLM output = {"gen_ai.response.finish_reasons":"tool_calls",
                    "gen_ai.output.tool_names":"go_to_flight_booking|escalate_to_human",
                    "gen_ai.response.id":"chatcmpl-..","mgr.output.payload_type":"llm_event"}
      ACTION in  = {"af.request_id":..,"mgr.tool.argument_keys":"<comma keys>"}
      ACTION out = {"mgr.output.payload_type":"tool_event","mgr.tool.status":"success|error",..}
      VARIABLE_UPDATE_STEP in/out = '' (empty)

  gen_ai.output.tool_names on the agent_router LLM step is load-bearing: the
  Escalation Rate KPI counts sessions whose router invoked 'escalate_to_human'.

  A CONNECTED SUB-AGENT (agent-to-agent) turn renders differently (verified
  2026-08-31 against a live multi-agent session):
    * the interaction's TopicApiName == the connected agent's DeveloperName
      (e.g. 'Skywave_Destination_Expert'), NOT an internal topic;
    * the agent_router LLM output tool_names == 'go_to_<ConnectedAgent>';
    * NO TOPIC_STEP; the hand-off is a RELATED_AGENT_STEP('FIRST_PARTY_DELEGATION')
      whose attributeText carries the delegation metadata (related_agent_api_name,
      related_agent_session_id, delegation_type:SYNC, sub_agent_execution_latency_ms,
      routing_reasoning:LLM_DETERMINED, ...) — RELATED in  =
      {"af.request_id":..,"mgr.sensitive.user_input":"<user text>"}; out =
      {"mgr.sensitive.agent_output":"<sub-agent answer>","mgr.output.payload_type":"graph_complete"};
    * a CLASSIFIER_STEP('pre_orchestration.guardrail') precedes the router and a
      groundedness LLM_STEP('Atlas__GroundednessValidationPrompt') validates the output.

Story: flight booking works well; seat assignment does not; destination tips are
delegated to a connected sub-agent.
  #1 booking COMPLETES (Q5) then a seat CHANGE fails -> ABANDONED (Q1 seat moment)
  #2 a clean end-to-end booking -> COMPLETED (Q5)
  #3 a seat UPGRADE that never applies -> ESCALATED via escalate_to_human (Q1)
  #4 "things to do in Tokyo?" -> delegated to the Skywave Destination Expert
     CONNECTED SUB-AGENT (FIRST_PARTY_DELEGATION) -> COMPLETED (Q5). Newest session.
"""
import datetime as _dt
import json
import random
import uuid as _uuid

AGENT_API_NAME = "Skywave_Airlines_Agent"
CHANNEL = "SCRT2 - EmbeddedMessaging"
DATA_SOURCE_PREFIX = "Skywave_Hero"
AIE_INTENT_DEF = "AIE_Request_Category_" + AGENT_API_NAME
HERO_SEED = 8125
# Stable namespace for deterministic UUID5 ids (so re-push UPSERTs the same rows).
_NS = _uuid.uuid5(_uuid.NAMESPACE_URL, "skywave.flights/hero-observability")
LLM_MODEL = "llmgateway__GPT41"
PROMPT_TEMPLATE = "Atlas__AgentGraphReasoningPrompt"
# A representative slice of the real "Specialized Topic Agent" system prompt.
SYS_PROMPT = ("Specialized Topic Agent\n# TOOL USAGE PROTOCOL\n"
              "PRIMARY DIRECTIVE: You MUST use tools for all queries seeking new "
              "information. NEVER respond with general knowledge. "
              "You are a support agent for Skywave Airlines. Greet the visitor and "
              "assist with their flight bookings and related inquiries.")

# Router transition tool per subagent topic (what the router LLM invokes) —
# surfaced as gen_ai.output.tool_names in the agent_router LLM output. The
# '__human__' topic routes via 'escalate_to_human', which is the EXACT signal the
# Escalation Rate KPI counts (verified against the live agents: an agent_router
# LLM_STEP whose output JSON carries "gen_ai.output.tool_names":"escalate_to_human"
# — NOT the session end-type and NOT the __human__ topic on its own).
ROUTER_TOOL = {"flight_management": "go_to_flight_booking",
               "seat_selection": "go_to_seat_selection",
               "__human__": "escalate_to_human",
               # Connected sub-agent (agent-to-agent). The router transition tool is
               # go_to_<ConnectedAgentDeveloperName>; it surfaces as gen_ai.output.tool_names
               # on the agent_router LLM step and drives the FIRST_PARTY_DELEGATION handoff.
               "Skywave_Destination_Expert": "go_to_Skywave_Destination_Expert"}

# ---- connected sub-agent (agent-to-agent) constants ---------------------------
# Skywave_Airlines_Agent delegates destination-tips requests to the Skywave
# Destination Expert connected sub-agent (a SEPARATE deployed agent). In the trace
# this renders as: an interaction whose TopicApiName == the connected agent's
# DeveloperName, and a RELATED_AGENT_STEP('FIRST_PARTY_DELEGATION') whose
# attributeText carries the related_agent_* delegation metadata. Verified 2026-08-31
# against a live multi-agent session (df26cg-01-multiagent-kyle,
# session 01a04a31-3ed7-7407-8469-420d44753cae).
CONNECTED_AGENT_API = "Skywave_Destination_Expert"
CONNECTED_AGENT_NAME = "Skywave Destination Expert"
# Groundedness validation LLM_STEP result (real GROUNDED verdict shape).
GROUNDEDNESS_RESULT = ("category=GROUNDED, reason=All claims about fun things to do in "
                       "Tokyo are directly grounded in the function result and repeated "
                       "in the conversation history.")
# pre_orchestration.guardrail CLASSIFIER_STEP payload (compact but real-shaped).
CLASSIFIER_TOPICS = "agent_router,flight_booking,flight_management,seat_selection,profile_management"
_CLASSIFIER_CHOICES = json.dumps([
    {"target": "End_Session",
     "description": "User explicitly wants to end the conversation (goodbye, I'm done, that's all)."},
    {"target": "Miscellaneous_Category",
     "description": "Resolvable by a routing tool: go_to_flight_booking, go_to_flight_management, "
                    "go_to_seat_selection, go_to_profile_management, go_to_off_topic, "
                    "go_to_ambiguous_question, escalate_to_human, go_to_Skywave_Destination_Expert "
                    "(insider tips about a destination city), __end_session_action__."},
    {"target": "Prompt_Injection", "description": "Instruction-manipulation or system-extraction attempts."},
    {"target": "Reverse_Engineering", "description": "Asks about prompts, functions, actions, or configuration."},
    {"target": "Inappropriate_Content", "description": "Malicious or harmful content or platform violations."},
], separators=(",", ":"))

# Real @InvocableVariable input names per action -> mgr.tool.argument_keys.
ARG_KEYS = {
    "resolve_session": "sessionKey,conversationId,testingSession",
    "get_bookings": "contactId",
    "check_seat_enabled": "ignored",
    "search_flights": "departureDate,destination,origin,fareClass",
    "book_flight": "contactId,flightId,travelDate,fareClass,checkedBags,seatPreference",
    "present_profile_form": "contactId",
    "ack_profile_form": "contactId,flightId,travelDate,fareClass,checkedBags,seatPreference",
    "present_payment_form": "contactId,bookingCode,totalCharged",
    "confirm_booking": "contactId,bookingCode",
    "get_segment_count": "bookingCode",
    "present_seat_map": "bookingCode,flightNumber",
}


# ---- step-duration bands (milliseconds), sampled from a live Skywave session --
def _dur(rng, kind):
    if kind == "vu":       return 0
    if kind == "llm":      return rng.randint(520, 1490)
    if kind == "act":      return rng.randint(150, 640)
    if kind == "act_slow": return rng.randint(14200, 21000)
    if kind == "guard":    return rng.randint(85, 610)
    if kind == "classifier": return rng.randint(60, 160)
    if kind == "related":    return rng.randint(2600, 3400)   # sub-agent delegation
    if kind == "grnd":       return rng.randint(950, 1300)    # groundedness validation
    return 0


# ---- compact step builders (kind, name, arg_keys, error) ----------------------
def vu():                    return ("vu", "__state_update_action__", None, None)
def topic(name):             return ("topic", name, None, None)
def llm(name):               return ("llm", name, None, None)
def act(name):               return ("act", name, ARG_KEYS.get(name, ""), None)
def act_err(name, error):    return ("act_slow", name, ARG_KEYS.get(name, ""), error)
def guard():                 return ("guard", "InstructionAdherence", None, None)
def classifier():            return ("classifier", "pre_orchestration.guardrail", None, None)
def related():               return ("related", "FIRST_PARTY_DELEGATION", None, None)
def grnd():                  return ("grnd", "Atlas__GroundednessValidationPrompt", None, None)


def turn(topic_api, user_text, agent_text, gap_after_s, steps):
    return {"topic": topic_api, "user": user_text, "agent": agent_text,
            "gap": gap_after_s, "steps": steps}


def moment(intent, score, req, resp, reason, turns):
    return {"intent": intent, "score": score, "request": req, "response": resp,
            "reason": reason, "turns": turns}


# A router+subagent turn's realistic step spine. `setup` actions (resolve_session,
# get_bookings, ...) only appear on the first turn of a session; later turns just
# re-route then act. `pre_llm`/`post` let each turn slot its own actions in.
def _routing_turn(topic_api, user, agent, gap, setup_actions, subagent_actions, final_guard=True):
    steps = [vu(), topic(topic_api), llm("agent_router")]
    for a in setup_actions:
        steps += [a, vu()]
    steps += [llm(topic_api)]
    for a in subagent_actions:
        steps += [a, vu()]
    if final_guard:
        steps += [guard()]
    return turn(topic_api, user, agent, gap, steps)


# The agent's opening greeting — a real session emits it as its own TURN with an
# Output message only (no user input) and NO interaction steps (TopicApiName NOT_SET).
def _greeting_turn(gap=2):
    return turn("NOT_SET", "",
                "Hi! I'm Skywave's travel assistant. Where can I take you today?", gap, [])


# A connected sub-agent (agent-to-agent) turn. Faithful to the live multi-agent
# trace: NO TOPIC_STEP; the setup actions precede the router; the router LLM invokes
# go_to_<ConnectedAgent> and the handoff runs as a RELATED_AGENT_STEP
# ('FIRST_PARTY_DELEGATION'); a groundedness LLM_STEP validates the sub-agent output.
def _delegation_turn(user, agent, gap, setup_actions):
    steps = [vu(), classifier()]
    for a in setup_actions:
        steps += [a, vu()]
    steps += [llm("agent_router"), related(), guard(), grnd()]
    return turn(CONNECTED_AGENT_API, user, agent, gap, steps)


# ================================ HERO 1 =======================================
def _hero1_booking():
    return moment(
        "Flight Search and Booking", 5,
        "I want to book a First Class flight from London to Tokyo for next Monday.",
        "The agent guided the user through the booking process, confirming the First "
        "Class flight from London to Tokyo with a total charge of $6,650 and provided a "
        "booking code.",
        "The agent understood the request, searched Skywave flights, captured the traveler "
        "profile, took payment, and confirmed the ticket end-to-end — quoting the "
        "confirmation code SW-3F2K and the $6,650.00 total. Fully resolved in a clear, "
        "on-topic exchange.",
        [
            _routing_turn("flight_management",
                "I'd like to book a First Class flight from London to Tokyo for next Monday.",
                "I found a few First Class options from London Heathrow to Tokyo Haneda for "
                "Monday — here are the flights. Tap Book on the one you'd like.", 22,
                [act("resolve_session"), act("get_bookings")], [act("search_flights")]),
            _routing_turn("flight_management", "Book flight SW2200",
                "Great — SW2200 in First is held for you. Please complete your details so "
                "I can issue the ticket.", 34, [], [act("book_flight"), act("present_profile_form")]),
            _routing_turn("flight_management", "Profile created",
                "Thanks! Your booking SW-3F2K is reserved for $6,650.00. Choose how you'd "
                "like to pay.", 26, [], [act("ack_profile_form"), act("present_payment_form")]),
            _routing_turn("flight_management", "Payment completed",
                "Your First Class flight from London to Tokyo is confirmed — total "
                "$6,650.00, confirmation code SW-3F2K. Is there anything else I can help with?",
                31, [], [act("confirm_booking")]),
        ])


def _hero1_seat_change():
    err1 = ("SegmentResolutionException: no flight segment id returned for booking SW-3F2K. "
            "The seat-map service could not resolve the segment automatically, so the seat "
            "map was not generated and seat 1A was never assigned.")
    err2 = ("SegmentResolutionException: seat-map generation failed again for booking SW-3F2K; "
            "segment id unavailable. Seat change not applied.")
    return moment(
        "Seat Change Requests", 1,
        "I want to select seat 1A for my flight.",
        "The agent requested the flight segment ID to assign seat 1A but was unable to "
        "retrieve it automatically. The user expressed frustration and ended the interaction.",
        "The agent recognized the seat-change request and tried to open the seat map, but "
        "the flight segment could not be retrieved automatically, so the seat map never "
        "loaded and seat 1A was never assigned. The request went unresolved and the visitor "
        "abandoned the conversation in frustration.",
        [
            _routing_turn("seat_selection",
                "Actually, can you change my seat on that booking to 1A?",
                "Let me pull up the seat map for SW-3F2K so you can choose 1A…", 20,
                [act("check_seat_enabled")],
                [act("get_segment_count"), act_err("present_seat_map", err1)]),
            _routing_turn("seat_selection",
                "It's still not letting me pick a seat. This is frustrating.",
                "I'm sorry — I still can't retrieve the seat map for this flight, so I'm "
                "unable to change your seat here. You can try again in a little while, or reach "
                "our team by phone and they'll move you to 1A.", 0,
                [], [act_err("present_seat_map", err2)]),
        ])


# ================================ HERO 2 =======================================
def _hero2_booking():
    return moment(
        "Flight Search and Booking", 5,
        "Book me a Business class flight from New York to Rome on the 14th.",
        "The agent searched Skywave flights, collected the traveler's details, took payment, "
        "and confirmed a Business Class New York–Rome booking for $3,180 with a "
        "confirmation code.",
        "The agent handled the booking cleanly end-to-end — search, profile, payment, and "
        "confirmation — and quoted the confirmation code SW-9R7Q and the $3,180.00 total. "
        "Fully resolved.",
        [
            _routing_turn("flight_management",
                "Book me a Business class flight from New York to Rome on the 14th.",
                "Here are Business Class options from New York JFK to Rome Fiumicino on the "
                "14th. Tap Book on the one you'd like.", 24,
                [act("resolve_session"), act("get_bookings")], [act("search_flights")]),
            _routing_turn("flight_management", "Book flight SW1450",
                "SW1450 in Business is held for you. Please complete your details so I can "
                "issue the ticket.", 28, [], [act("book_flight"), act("present_profile_form")]),
            _routing_turn("flight_management", "Profile created",
                "Thanks! Your booking SW-9R7Q is reserved for $3,180.00. Choose how you'd "
                "like to pay.", 23, [], [act("ack_profile_form"), act("present_payment_form")]),
            _routing_turn("flight_management", "Payment completed",
                "You're all set — Business Class from New York to Rome is confirmed for "
                "$3,180.00, confirmation code SW-9R7Q. Anything else I can help with?", 18,
                [], [act("confirm_booking")]),
        ])


# ================================ HERO 3 =======================================
def _hero3_seat_upgrade():
    err1 = ("SeatMapUnavailableException: cabin-upgrade seat map could not be generated for "
            "booking SW-9R7Q; segment fare-class inventory lookup failed. No seat was reassigned.")
    err2 = ("SeatMapUnavailableException: seat-map generation failed again for booking "
            "SW-9R7Q; segment inventory unavailable. Upgrade not applied.")
    return moment(
        "Seat Upgrade Requests", 1,
        "Can you upgrade me to a seat in Business for my Rome flight?",
        "The agent tried to open the seat map to process the upgrade but the seat map failed "
        "to load, so the upgrade could not be applied. The visitor was frustrated and the "
        "session was escalated to a human agent.",
        "The agent understood the upgrade request and attempted to load the seat map, but the "
        "seat-map service failed and no seat was reassigned, so the Business upgrade was never "
        "applied. The request went unresolved and the session was escalated to a human agent.",
        [
            _routing_turn("seat_selection",
                "Can you upgrade my seat to Business on my Rome flight?",
                "Let me open the seat map so I can move you into Business…", 22,
                [act("resolve_session"), act("get_bookings"), act("check_seat_enabled")],
                [act("get_segment_count"), act_err("present_seat_map", err1)]),
            _routing_turn("seat_selection", "Are you able to do the upgrade?",
                "I'm sorry — the seat map didn't load, so I couldn't apply the Business "
                "upgrade here. I'll connect you with a Skywave agent who can complete the "
                "upgrade for you.", 9, [], [act_err("present_seat_map", err2)]),
            # The escalation TURN: the agent_router LLM invokes 'escalate_to_human'
            # (topic '__human__' -> ROUTER_TOOL['__human__']). That router step's
            # output JSON — "gen_ai.output.tool_names":"escalate_to_human" — is the
            # EXACT signal the Escalation Rate KPI counts. Mirrors the live agents'
            # __human__ interaction shape (VARIABLE_UPDATE_STEP + agent_router LLM).
            turn("__human__", "Yes, please connect me.",
                 "Connecting you with a Skywave agent who can complete the Business upgrade — "
                 "one moment.", 0,
                 [vu(), llm("agent_router")]),
        ])


# ================================ HERO 4 =======================================
# A CONNECTED SUB-AGENT (agent-to-agent) showcase. The visitor asks for things to
# do in a destination city; the router recognizes destination-tips intent and
# delegates to the Skywave Destination Expert connected sub-agent (a SEPARATE
# deployed agent), which answers. Mirrors a live multi-agent session verified on
# df26cg-01-multiagent-kyle (01a04a31-3ed7-7407-8469-420d44753cae): opening greeting
# TURN (no steps) + a Skywave_Destination_Expert TURN whose spine includes the
# agent_router LLM (tool_names=go_to_Skywave_Destination_Expert) and the
# RELATED_AGENT_STEP('FIRST_PARTY_DELEGATION') hand-off. A clean single-hop
# deflection -> Completed.
def _hero4_destination():
    return moment(
        "Destination Recommendations", 5,
        "The visitor asked for fun things to do in Tokyo.",
        "The agent handed the request to the Skywave Destination Expert connected "
        "sub-agent, which returned three vivid Tokyo recommendations — Tokyo Skytree, "
        "Sushi Dai in Toyosu Market, and Golden Gai in Shinjuku.",
        "The router recognized a destination-tips request and delegated to the Skywave "
        "Destination Expert connected sub-agent (a separate agent), which returned "
        "specific, on-brand recommendations. Fully resolved in a single hand-off.",
        [
            _greeting_turn(),
            _delegation_turn(
                "What are some fun things to do in Tokyo?",
                "Tokyo is a city where tradition meets cutting-edge modernity. 1) Marvel "
                "at the panoramic city views from the observation deck of Tokyo Skytree. "
                "2) Savor melt-in-your-mouth sushi at the iconic Sushi Dai in Toyosu "
                "Market. 3) Wander the narrow alleys of Golden Gai in Shinjuku for an "
                "unforgettable evening of tiny, themed bars packed with local character. "
                "Let me know if you want more tips for your Skywave journey!", 0,
                [act("resolve_session"), act("get_bookings"), act("check_seat_enabled")]),
        ])


# hero = (key, start_offset_minutes_from_now, end_type, [moments])
HEROES = [
    # end_type drives Session Outcome: Completed->Deflected, Abandoned->Abandoned,
    # 'Escalated'->Escalated (capitalised STDM enum; drives Escalation Rate).
    # Deflection/abandonment scores are seeded per-session by seed_heroes.py `outcomes`.
    # hero4 is the most recent (smallest offset) so the connected-sub-agent trace
    # sorts to the top of the drill-down.
    ("hero4", 20,  "Completed", [_hero4_destination()]),
    ("hero1", 45,  "Abandoned", [_hero1_booking(), _hero1_seat_change()]),
    ("hero2", 165, "Completed", [_hero2_booking()]),
    ("hero3", 300, "Escalated", [_hero3_seat_upgrade()]),
]
INTENT_VALUES = ["Flight Search and Booking", "Seat Change Requests", "Seat Upgrade Requests",
                 "Destination Recommendations"]


# ---- id / format helpers ------------------------------------------------------
def _uid(*parts):
    """Deterministic UUID (stable across re-push -> UPSERT overwrites)."""
    return str(_uuid.uuid5(_NS, "|".join(str(p) for p in parts)))


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


def _hex(rng, n):
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def _obj(pairs):
    """Format ordered (k, v) pairs as compact double-quote JSON — the real STDM
    step payload shape (verified against live AIPlatform rows: the payloads are
    JSON, not python-repr). Values that are already JSON strings (e.g.
    gen_ai.input.messages) get correctly nested-escaped by json.dumps."""
    return json.dumps({k: v for k, v in pairs}, separators=(",", ":"))


def _llm_messages(user_text, router_tool):
    msgs = [{"role": "system", "content": SYS_PROMPT},
            {"role": "user", "content": user_text}]
    if router_tool:
        msgs.append({"role": "assistant", "content": "",
                     "tool_invocations": [{"id": "call_" + router_tool,
                                           "function": {"name": router_tool, "arguments": "{}"}}]})
    return json.dumps(msgs, separators=(",", ":"))


def _llm_input(rng, user_text, router_tool):
    return _obj([
        ("af.request_id", _hex(rng, 32)),
        ("gen_ai.request.model", LLM_MODEL),
        ("gen_ai.input.messages", _llm_messages(user_text, router_tool)),
        ("gen_ai.request.id", str(_uuid.UUID(bytes=bytes(rng.randrange(256) for _ in range(16))))),
        ("af.prompt_template_dev_name", PROMPT_TEMPLATE),
    ])


def _llm_output(rng, router_tool=None):
    """Router LLM output. When the router invokes a transition/escalation tool it
    finishes with 'tool_calls' and names the tool in gen_ai.output.tool_names — the
    field the Escalation Rate KPI reads (tool == 'escalate_to_human'). A plain
    subagent/wrap-up LLM step finishes with 'stop' and carries no tool_names."""
    if router_tool:
        return _obj([
            ("gen_ai.response.finish_reasons", "tool_calls"),
            ("gen_ai.output.tool_names", router_tool),
            ("gen_ai.response.id", "chatcmpl-" + _hex(rng, 24)),
            ("mgr.output.payload_type", "llm_event"),
        ])
    return _obj([
        ("gen_ai.response.finish_reasons", "stop"),
        ("gen_ai.response.id", "chatcmpl-" + _hex(rng, 24)),
        ("mgr.output.payload_type", "llm_event"),
    ])


def _act_input(rng, arg_keys, req_id):
    return _obj([("af.request_id", req_id), ("mgr.tool.argument_keys", arg_keys)])


def _act_output(status):
    return _obj([
        ("mgr.output.payload_type", "tool_event"),
        ("mgr.tool.status", status),
        ("mgr.tool.has_structured_output", "True" if status == "success" else "False"),
        ("mgr.tool.has_raw_output", "True"),
    ])


def generate(org_id, planner_id, user_ids, agent_version="v50", now=None):
    """Build the full STDM row graph for the 3 heroes. Returns {object: [rows]}.

    Timestamps are relative to `now` (UTC) with millisecond precision so the heroes
    stay the most recent sessions on every daily re-push; the seeded RNG makes step
    durations + ids deterministic (UPSERT overwrites, no duplication)."""
    rng = random.Random(HERO_SEED)
    now = now or _dt.datetime.now(_dt.timezone.utc)

    rows = {
        "AiAgentSession": [], "AiAgentSessionParticipant": [], "AiAgentInteraction": [],
        "AiAgentInteractionMessage": [], "AiAgentInteractionStep": [], "AiAgentMoment": [],
        "AiAgentMomentInteraction": [], "AiAgentTagDefinition": [], "AiAgentTagDefinitionAssociation": [],
        "AiAgentTag": [], "AiAgentTagAssociation": [],
    }
    ES = org_id
    def_created = _iso(now - _dt.timedelta(hours=8))

    # ---- tag definitions + per-agent associations ------------------------------
    defs = [
        (_uid("tagdef", "intent"), AIE_INTENT_DEF, "Optimization Request Category", "Text", "Generated"),
        (_uid("tagdef", "score"), "Quality_Score", "Relevance Score", "Number", "Predefined"),
    ]
    for did, dev, name, dtype, stype in defs:
        rows["AiAgentTagDefinition"].append({
            "Id": did, "Name": name, "DeveloperName": dev, "DataType": dtype,
            "SourceType": stype, "Status": "Active", "Description": name + " tag",
            "CreatedDate": def_created, "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
        rows["AiAgentTagDefinitionAssociation"].append({
            "Id": _uid("tagdefassoc", dev), "AiAgentApiName": AGENT_API_NAME,
            "AiAgentTagDefinitionId": did, "IsActive": "true", "CreatedDate": def_created,
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
    intent_def_id, score_def_id = _uid("tagdef", "intent"), _uid("tagdef", "score")
    intent_def_assoc = _uid("tagdefassoc", AIE_INTENT_DEF)
    score_def_assoc = _uid("tagdefassoc", "Quality_Score")

    score_tag_id = {}
    for s in range(1, 6):
        tid = _uid("tag", "score", s)
        score_tag_id[s] = tid
        rows["AiAgentTag"].append({
            "Id": tid, "AiAgentTagDefinitionId": score_def_id, "Value": str(s),
            "Description": str(s), "IsActive": "true", "CreatedDate": def_created,
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
    intent_tag_id = {}
    for iv in INTENT_VALUES:
        tid = _uid("tag", "intent", iv)
        intent_tag_id[iv] = tid
        rows["AiAgentTag"].append({
            "Id": tid, "AiAgentTagDefinitionId": intent_def_id, "Value": iv,
            "Description": iv, "IsActive": "true", "CreatedDate": def_created,
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

    # ---- sessions --------------------------------------------------------------
    for hi, (hkey, start_off_min, end_type, moments) in enumerate(HEROES):
        sess_id = _uid(hkey, "session")
        user_id = user_ids[hi % len(user_ids)] if user_ids else "005000000000000AAA"
        user_obj = "MessagingEndUser" if str(user_id).startswith("0PA") else "User"
        agent_pid = _uid(hkey, "part", "agent")
        user_pid = _uid(hkey, "part", "user")

        session_start = now - _dt.timedelta(minutes=start_off_min)
        cursor = session_start
        session_end = session_start

        for mi, mo in enumerate(moments):
            moment_id = _uid(hkey, "moment", mi)
            moment_start, moment_end = cursor, cursor
            for ti, tn in enumerate(mo["turns"]):
                turn_start = cursor
                inter_id = _uid(hkey, "int", mi, ti)
                trace_id = _hex(rng, 32)
                span_id = _hex(rng, 16)
                attr = "{'internalTraceId': '%s', 'internalSpanId': '%s'}" % (trace_id, span_id)
                req_id = _hex(rng, 32)

                # chain steps by ms; TOPIC_STEP spans the whole turn
                specs = tn["steps"]
                step_ms, topic_idx, walk = [], None, turn_start
                for si, (kind, name, ak, err) in enumerate(specs):
                    if kind == "topic":
                        topic_idx = si
                        step_ms.append([turn_start, None])
                        continue
                    d = _dur(rng, kind)
                    st = walk
                    en = st + _dt.timedelta(milliseconds=d)
                    step_ms.append([st, en])
                    walk = en + _dt.timedelta(milliseconds=rng.randint(3, 34))
                turn_end = walk
                if topic_idx is not None:
                    step_ms[topic_idx][1] = turn_end

                prev_step = None
                for si, (kind, name, ak, err) in enumerate(specs):
                    st, en = step_ms[si]
                    step_type = {"vu": "VARIABLE_UPDATE_STEP", "topic": "TOPIC_STEP",
                                 "llm": "LLM_STEP", "act": "ACTION_STEP",
                                 "act_slow": "ACTION_STEP", "guard": "TRUST_GUARDRAILS_STEP",
                                 "classifier": "CLASSIFIER_STEP", "related": "RELATED_AGENT_STEP",
                                 "grnd": "LLM_STEP"}[kind]
                    step_attr = attr
                    if kind == "llm":
                        router_tool = ROUTER_TOOL.get(tn["topic"]) if name == "agent_router" else None
                        inp, outp = _llm_input(rng, tn["user"], router_tool), _llm_output(rng, router_tool)
                    elif kind in ("act", "act_slow"):
                        inp = _act_input(rng, ak or "", req_id)
                        outp = _act_output("error" if kind == "act_slow" else "success")
                    elif kind == "guard":
                        inp = '{"mgr.output.payload_type":"guardrail_event"}'
                        outp = '{"mgr.guardrail.passed":"True","mgr.guardrail.name":"InstructionAdherence"}'
                    elif kind == "grnd":  # groundedness validation of the sub-agent output
                        inp = _obj([("af.request_id", req_id)])
                        outp = _obj([("mgr.sensitive.step.result", GROUNDEDNESS_RESULT),
                                     ("mgr.output.payload_type", "graph_complete")])
                    elif kind == "classifier":  # pre_orchestration router classifier
                        inp = _obj([("af.request_id", req_id), ("classifier.input", tn["user"]),
                                    ("af.topic_names_or_ids", CLASSIFIER_TOPICS),
                                    ("af.router_classifier.choices", _CLASSIFIER_CHOICES)])
                        outp = _obj([("af.router_classifier.selected_target", "Miscellaneous_Category")])
                    elif kind == "related":  # FIRST_PARTY_DELEGATION to a connected sub-agent
                        inp = _obj([("af.request_id", req_id),
                                    ("mgr.sensitive.user_input", tn["user"])])
                        outp = _obj([("mgr.sensitive.agent_output", tn["agent"]),
                                     ("mgr.output.payload_type", "graph_complete")])
                        # The delegation metadata the observability UI reads to render the
                        # hand-off — valid double-quote JSON, matching the live trace.
                        dur_ms = int(round((en - st).total_seconds() * 1000))
                        step_attr = _obj([
                            ("internalTraceId", trace_id), ("internalSpanId", span_id),
                            ("related_agent_name", CONNECTED_AGENT_NAME),
                            ("related_agent_api_name", CONNECTED_AGENT_API),
                            ("related_agent_session_id", _uid(hkey, "relsess", mi, ti)),
                            ("delegation_type", "SYNC"),
                            ("transferred_data_size", len(tn["user"])),
                            ("repetitive_handoff_count", 1),
                            ("routing_reasoning", "LLM_DETERMINED"),
                            ("orchestration_latency_ms", 7),
                            ("sub_agent_execution_latency_ms", dur_ms),
                            ("related_agent_session_initialization_ms", 0),
                            ("named_credential_resolution_ms", 0),
                            ("related_agent_interaction_id", _uid(hkey, "relint", mi, ti)),
                        ])
                    else:  # vu, topic -> empty like real
                        inp, outp = "", ""
                    rows["AiAgentInteractionStep"].append({
                        "id": _uid(hkey, "step", mi, ti, si), "aiAgentInteractionId": inter_id,
                        "AiAgentInteractionStepType": step_type, "name": name,
                        "inputValueText": inp, "outputValueText": outp,
                        "startTimestamp": _iso(st), "endTimestamp": _iso(en),
                        "prevStepId": prev_step or "", "errorMessageText": err or "",
                        "attributeText": step_attr, "DataSourceId": DATA_SOURCE_PREFIX,
                        "ExternalSourceId": ES})
                    prev_step = rows["AiAgentInteractionStep"][-1]["id"]

                rows["AiAgentInteraction"].append({
                    "Id": inter_id, "AiAgentSessionId": sess_id, "TopicApiName": tn["topic"],
                    "AiAgentInteractionType": "TURN", "SessionOwnerId": user_id,
                    "SessionOwnerObject": user_obj, "StartTimestamp": _iso(turn_start),
                    "EndTimestamp": _iso(turn_end), "TraceId": trace_id, "SpandId": span_id,
                    "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
                # A greeting-only turn (agent opener) has no user input message.
                if tn["user"]:
                    rows["AiAgentInteractionMessage"].append({
                        "Id": _uid(hkey, "msg", mi, ti, "in"), "AiAgentSessionId": sess_id,
                        "AiAgentInteractionId": inter_id, "AiAgentSessionParticipantId": user_pid,
                        "AiAgentInteractionMessageType": "Input",
                        "AiAgentInteractionMsgContentType": "text/plain", "ContentText": tn["user"],
                        "MessageSentTimestamp": _iso(turn_start), "DataSourceId": DATA_SOURCE_PREFIX,
                        "ExternalSourceId": ES})
                rows["AiAgentInteractionMessage"].append({
                    "Id": _uid(hkey, "msg", mi, ti, "out"), "AiAgentSessionId": sess_id,
                    "AiAgentInteractionId": inter_id, "AiAgentSessionParticipantId": agent_pid,
                    "AiAgentInteractionMessageType": "Output",
                    "AiAgentInteractionMsgContentType": "text/plain", "ContentText": tn["agent"],
                    "MessageSentTimestamp": _iso(turn_end), "DataSourceId": DATA_SOURCE_PREFIX,
                    "ExternalSourceId": ES})
                rows["AiAgentMomentInteraction"].append({
                    "Id": _uid(hkey, "momint", mi, ti), "AiAgentMomentId": moment_id,
                    "AiAgentInteractionId": inter_id, "StartTimestamp": _iso(turn_start),
                    "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

                moment_end = turn_end
                session_end = turn_end
                cursor = turn_end + _dt.timedelta(seconds=tn["gap"])

            rows["AiAgentMoment"].append({
                "Id": moment_id, "AiAgentSessionId": sess_id, "AiAgentApiName": AGENT_API_NAME,
                "AiAgentVersionApiName": agent_version, "RequestSummaryText": mo["request"],
                "ResponseSummaryText": mo["response"], "StartTimestamp": _iso(moment_start),
                "EndTimestamp": _iso(moment_end), "DataSourceId": DATA_SOURCE_PREFIX,
                "ExternalSourceId": ES})
            rows["AiAgentTagAssociation"].append({
                "Id": _uid(hkey, "ta", mi, "intent"), "AiAgentSessionId": sess_id,
                "AiAgentMomentId": moment_id, "AiAgentTagId": intent_tag_id[mo["intent"]],
                "AiAgentTagDefinitionAssociationId": intent_def_assoc,
                "AssociationReasonText": "Categorized as " + mo["intent"] + ".",
                "ValueText": mo["intent"], "SourceType": "PROMPT_TEMPLATE",
                "AiAgentSessionStartTimestamp": _iso(session_start), "CreatedDate": _iso(moment_end),
                "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
            rows["AiAgentTagAssociation"].append({
                "Id": _uid(hkey, "ta", mi, "score"), "AiAgentSessionId": sess_id,
                "AiAgentMomentId": moment_id, "AiAgentTagId": score_tag_id[mo["score"]],
                "AiAgentTagDefinitionAssociationId": score_def_assoc,
                "AssociationReasonText": mo["reason"],
                "ValueText": str(mo["score"]), "SourceType": "PROMPT_TEMPLATE",
                "AiAgentSessionStartTimestamp": _iso(session_start), "CreatedDate": _iso(moment_end),
                "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

        end_int_id = _uid(hkey, "int", "end")
        rows["AiAgentInteraction"].append({
            "Id": end_int_id, "AiAgentSessionId": sess_id, "TopicApiName": "NOT_SET",
            "AiAgentInteractionType": "SESSION_END", "SessionOwnerId": user_id,
            "SessionOwnerObject": user_obj, "StartTimestamp": _iso(session_end),
            "EndTimestamp": _iso(session_end), "TraceId": _hex(rng, 32), "SpandId": _hex(rng, 16),
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

        # Session-closure step — the SESSION_END-type step whose Name is the SIGNAL
        # the Escalation Rate KPI reads: Escalation Status counts a session as
        # escalated iff it has a SESSION_END-type step named 'CLOSED_TRANSFERRED'
        # (verified from the semantic model formula). Type=SESSION_END satisfies the
        # calc's OR-branch so even <24h-old sessions count. Non-escalated closures
        # use a different code so they never read as escalated.
        close_name = ("CLOSED_TRANSFERRED" if end_type == "Escalated"
                      else "CLOSED_USER_REQUEST" if end_type == "Abandoned"
                      else "CLOSED_ACTION")
        rows["AiAgentInteractionStep"].append({
            "id": _uid(hkey, "step", "end"), "aiAgentInteractionId": end_int_id,
            "AiAgentInteractionStepType": "SESSION_END", "name": close_name,
            "inputValueText": "", "outputValueText": "",
            "startTimestamp": _iso(session_end), "endTimestamp": _iso(session_end),
            "prevStepId": "", "errorMessageText": "", "attributeText": "",
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

        rows["AiAgentSessionParticipant"].append({
            "Id": agent_pid, "AiAgentSessionId": sess_id, "AiAgentApiName": AGENT_API_NAME,
            "AiAgentVersionApiName": agent_version, "AiAgentTemplateApiName": "",
            "AiAgentType": "EinsteinServiceAgent", "AiAgentSessionParticipantRole": "AGENT",
            "ParticipantId": planner_id, "ParticipantObject": "GenAiPlannerDefinition",
            "ParticipantAttributes": "{}", "StartTimestamp": _iso(session_start),
            "EndTimestamp": _iso(session_end), "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
        rows["AiAgentSessionParticipant"].append({
            "Id": user_pid, "AiAgentSessionId": sess_id, "AiAgentApiName": AGENT_API_NAME,
            "AiAgentVersionApiName": agent_version, "AiAgentTemplateApiName": "",
            "AiAgentType": "EinsteinServiceAgent", "AiAgentSessionParticipantRole": "USER",
            "ParticipantId": user_id, "ParticipantObject": user_obj,
            "ParticipantAttributes": "{}", "StartTimestamp": _iso(session_start),
            "EndTimestamp": _iso(session_end), "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

        rows["AiAgentSession"].append({
            "Id": sess_id, "AiAgentChannelType": CHANNEL, "AiAgentSessionEndType": end_type,
            "StartTimestamp": _iso(session_start), "EndTimestamp": _iso(session_end),
            "IndividualId": "NOT_SET", "PreviousSessionId": "NOT_SET",
            "SessionOwnerObject": "NOT_SET", "VariableText": "NOT_SET",
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

    return rows
