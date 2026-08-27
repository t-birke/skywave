"""
The 3 Skywave "hero" sessions — high-fidelity, millisecond-precise STDM traces
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

Story (unchanged): flight booking works well; seat assignment does not.
  #1 booking COMPLETES (Q5) then a seat CHANGE fails -> ABANDONED (Q1 seat moment)
  #2 a clean end-to-end booking -> COMPLETED (Q5)
  #3 a seat UPGRADE that never applies -> ESCALATED via escalate_to_human (Q1)
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
               "__human__": "escalate_to_human"}

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
    return 0


# ---- compact step builders (kind, name, arg_keys, error) ----------------------
def vu():                    return ("vu", "__state_update_action__", None, None)
def topic(name):             return ("topic", name, None, None)
def llm(name):               return ("llm", name, None, None)
def act(name):               return ("act", name, ARG_KEYS.get(name, ""), None)
def act_err(name, error):    return ("act_slow", name, ARG_KEYS.get(name, ""), error)
def guard():                 return ("guard", "InstructionAdherence", None, None)


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


# hero = (key, start_offset_minutes_from_now, end_type, [moments])
HEROES = [
    # end_type drives Session Outcome: Completed->Deflected, Abandoned->Abandoned,
    # 'Escalated'->Escalated (capitalised STDM enum; drives Escalation Rate).
    # Deflection/abandonment scores are seeded per-session by seed_heroes.py `outcomes`.
    ("hero1", 45,  "Abandoned", [_hero1_booking(), _hero1_seat_change()]),
    ("hero2", 165, "Completed", [_hero2_booking()]),
    ("hero3", 300, "Escalated", [_hero3_seat_upgrade()]),
]
INTENT_VALUES = ["Flight Search and Booking", "Seat Change Requests", "Seat Upgrade Requests"]


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
                                 "act_slow": "ACTION_STEP", "guard": "TRUST_GUARDRAILS_STEP"}[kind]
                    if kind == "llm":
                        router_tool = ROUTER_TOOL.get(tn["topic"]) if name == "agent_router" else None
                        inp, outp = _llm_input(rng, tn["user"], router_tool), _llm_output(rng, router_tool)
                    elif kind in ("act", "act_slow"):
                        inp = _act_input(rng, ak or "", req_id)
                        outp = _act_output("error" if kind == "act_slow" else "success")
                    elif kind == "guard":
                        inp = '{"mgr.output.payload_type":"guardrail_event"}'
                        outp = '{"mgr.guardrail.passed":"True","mgr.guardrail.name":"InstructionAdherence"}'
                    else:  # vu, topic -> empty like real
                        inp, outp = "", ""
                    rows["AiAgentInteractionStep"].append({
                        "id": _uid(hkey, "step", mi, ti, si), "aiAgentInteractionId": inter_id,
                        "AiAgentInteractionStepType": step_type, "name": name,
                        "inputValueText": inp, "outputValueText": outp,
                        "startTimestamp": _iso(st), "endTimestamp": _iso(en),
                        "prevStepId": prev_step or "", "errorMessageText": err or "",
                        "attributeText": attr, "DataSourceId": DATA_SOURCE_PREFIX,
                        "ExternalSourceId": ES})
                    prev_step = rows["AiAgentInteractionStep"][-1]["id"]

                rows["AiAgentInteraction"].append({
                    "Id": inter_id, "AiAgentSessionId": sess_id, "TopicApiName": tn["topic"],
                    "AiAgentInteractionType": "TURN", "SessionOwnerId": user_id,
                    "SessionOwnerObject": user_obj, "StartTimestamp": _iso(turn_start),
                    "EndTimestamp": _iso(turn_end), "TraceId": trace_id, "SpandId": span_id,
                    "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
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

        rows["AiAgentInteraction"].append({
            "Id": _uid(hkey, "int", "end"), "AiAgentSessionId": sess_id, "TopicApiName": "NOT_SET",
            "AiAgentInteractionType": "SESSION_END", "SessionOwnerId": user_id,
            "SessionOwnerObject": user_obj, "StartTimestamp": _iso(session_end),
            "EndTimestamp": _iso(session_end), "TraceId": _hex(rng, 32), "SpandId": _hex(rng, 16),
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
