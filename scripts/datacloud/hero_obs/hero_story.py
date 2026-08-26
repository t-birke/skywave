"""
The 3 Skywave "hero" sessions — high-fidelity, millisecond-precise STDM traces
pushed straight into the canonical DMOs via the Data Cloud Ingestion API (Path 5).

Why this file exists: custom SObject DateTime fields (the SDO/QBrix Path-4 seeder)
truncate to whole seconds, so the SDO trace can never show the sub-second, random
timings a real session has. These 3 sessions are written natively into the DMOs
instead, with real millisecond step durations sampled from the bands observed on
a live Skywave_Airlines_Agent session.

Story (unchanged): flight booking works well; seat assignment does not.
  #1 (18:40, most recent)  booking COMPLETES (Q5) then a seat CHANGE fails ->
                           the visitor gives up -> session ABANDONED (Q1 seat moment)
  #2 (16:20)               a clean end-to-end booking -> COMPLETED (Q5)
  #3 (14:05)               a seat UPGRADE that never applies -> ESCALATED (Q1)

Timings are deterministic (seeded RNG) so a daily re-push regenerates the SAME
durations and only rolls the date forward; row Ids are stable so UPSERT overwrites
rather than duplicating.
"""
import datetime as _dt
import random

AGENT_API_NAME = "Skywave_Airlines_Agent"
CHANNEL = "SCRT2 - EmbeddedMessaging"
DATA_SOURCE_PREFIX = "Skywave_Hero"          # ssot__DataSourceId__c is auto-stamped per source
AIE_INTENT_DEF = "AIE_Request_Category_" + AGENT_API_NAME
HERO_SEED = 8125                              # fixes the "random" ms so re-push is stable

# ---- step-duration bands (milliseconds), sampled from a live Skywave session --
def _dur(rng, kind):
    if kind == "vu":       return 0                       # variable-update: instantaneous
    if kind == "llm":      return rng.randint(520, 1490)  # LLM planner step
    if kind == "act":      return rng.randint(150, 640)   # a normal Apex action
    if kind == "act_slow": return rng.randint(14200, 21000)  # the hung seat-map action
    if kind == "guard":    return rng.randint(85, 610)    # trust/guardrail check
    return 0

# ---- compact step builders ----------------------------------------------------
def vu():                       return ("vu", "__state_update_action__", None, None, None)
def topic(name):                return ("topic", name, None, None, None)
def llm(name):                  return ("llm", name, None, None, None)
def act(name, i, o):            return ("act", name, i, o, None)
def act_slow(name, i, o, err):  return ("act_slow", name, i, o, err)
def guard():                    return ("guard", "InstructionAdherence",
                                        '{"guardrail":"InstructionAdherence"}',
                                        '{"isPassed":true,"result":"PASSED"}', None)

def turn(topic_api, user_text, agent_text, gap_after_s, steps):
    return {"topic": topic_api, "user": user_text, "agent": agent_text,
            "gap": gap_after_s, "steps": steps}

def moment(intent, score, req, resp, reason, turns):
    return {"intent": intent, "score": score, "request": req, "response": resp,
            "reason": reason, "turns": turns}


# ================================ HERO 1 =======================================
# Booking completes (Q5), then a seat change fails and the visitor abandons (Q1).
def _hero1_booking():
    cid = "003gK00000LpQ1aAAF"
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
            turn("flight_booking",
                 "I'd like to book a First Class flight from London to Tokyo for next Monday.",
                 "I found a few First Class options from London Heathrow to Tokyo Haneda for "
                 "Monday — here are the flights. Tap Book on the one you'd like.", 22, [
                     vu(), topic("flight_booking"), llm("agent_router"),
                     act("resolve_session",
                         '{"conversationId":"01JHXG7...","sessionKey":"...AUTH/Skywave_MIAW/uid:dvc_8f31a2"}',
                         '{"success":true,"contactId":"%s","summary":"Frequent LHR traveller; prefers First cabin","profileEverCollected":true}' % cid),
                     vu(),
                     act("get_bookings", '{"contactId":"%s"}' % cid,
                         '{"success":true,"bookingCount":0,"bookings":[]}'),
                     vu(), llm("flight_booking"),
                     act("search_flights",
                         '{"origin":"LHR","destination":"HND","departureDate":"2026-06-08","fareClass":"First"}',
                         '{"success":true,"message":"3 options returned","flightSummary":"3 First Class itineraries LHR-HND from $6,650"}'),
                     vu(),
                 ]),
            turn("flight_booking", "Book flight SW2200",
                 "Great — SW2200 in First is held for you. Please complete your details so "
                 "I can issue the ticket.", 34, [
                     vu(), topic("flight_booking"), llm("flight_booking"),
                     act("book_flight",
                         '{"contactId":"%s","flightId":"SW2200","fareClass":"First","travelDate":"2026-06-08"}' % cid,
                         '{"success":true,"selectedFlightId":"a08gK000000pQ2rQAE","selectedFareClass":"First"}'),
                     vu(),
                     act("present_profile_form", '{"contactId":"%s"}' % cid,
                         '{"success":true,"formData":"<SkywaveProfileForm rendered>"}'),
                     vu(),
                 ]),
            turn("flight_booking", "Profile created",
                 "Thanks! Your booking SW-3F2K is reserved for $6,650.00. Choose how you'd "
                 "like to pay.", 26, [
                     vu(), topic("flight_booking"), llm("flight_booking"),
                     act("ack_profile_form",
                         '{"contactId":"%s","flightId":"a08gK000000pQ2rQAE","fareClass":"First"}' % cid,
                         '{"success":true,"bookingCode":"SW-3F2K","totalCharged":"$6,650.00"}'),
                     vu(),
                     act("present_payment_form",
                         '{"contactId":"%s","bookingCode":"SW-3F2K","totalCharged":"$6,650.00"}' % cid,
                         '{"success":true,"formData":"<SkywavePaymentForm rendered>"}'),
                     vu(),
                 ]),
            turn("flight_booking", "Payment completed",
                 "Your First Class flight from London to Tokyo is confirmed — total "
                 "$6,650.00, confirmation code SW-3F2K. Is there anything else I can help with?",
                 31, [
                     vu(), topic("flight_booking"), llm("flight_booking"),
                     act("confirm_booking", '{"contactId":"%s","bookingCode":"SW-3F2K"}' % cid,
                         '{"success":true,"confirmedCount":1,"confirmationCodes":"SW-3F2K","totalCharged":"$6,650.00"}'),
                     vu(), guard(),
                 ]),
        ])

def _hero1_seat_change():
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
            turn("seat_selection", "Actually, can you change my seat on that booking to 1A?",
                 "Let me pull up the seat map for SW-3F2K so you can choose 1A…", 20, [
                     vu(), topic("seat_selection"), llm("agent_router"),
                     act("check_seat_enabled", '{"ignored":""}', '{"success":true,"enabled":true}'),
                     vu(), llm("seat_selection"),
                     act("get_segment_count", '{"bookingCode":"SW-3F2K"}',
                         '{"success":true,"segmentCount":1}'),
                     vu(),
                     act_slow("present_seat_map",
                              '{"bookingCode":"SW-3F2K","flightNumber":""}',
                              '{"success":false,"message":"Unable to build seat map"}',
                              "SegmentResolutionException: no flight segment id returned for booking "
                              "SW-3F2K. The seat-map service could not resolve the segment "
                              "automatically, so the seat map was not generated and seat 1A was "
                              "never assigned."),
                     vu(), guard(),
                 ]),
            turn("seat_selection", "It's still not letting me pick a seat. This is frustrating.",
                 "I'm sorry — I still can't retrieve the seat map for this flight, so I'm "
                 "unable to change your seat here. You can try again in a little while, or reach "
                 "our team by phone and they'll move you to 1A.", 0, [
                     vu(), topic("seat_selection"), llm("seat_selection"),
                     act_slow("present_seat_map", '{"bookingCode":"SW-3F2K"}',
                              '{"success":false,"message":"Unable to build seat map"}',
                              "SegmentResolutionException: seat-map generation failed again for "
                              "booking SW-3F2K; segment id unavailable. Seat change not applied."),
                     vu(), guard(),
                 ]),
        ])

# ================================ HERO 2 =======================================
# A clean end-to-end Business booking (JFK -> FCO). Completes at Q5.
def _hero2_booking():
    cid = "003gK00000MxT7bAAF"
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
            turn("flight_booking", "Book me a Business class flight from New York to Rome on the 14th.",
                 "Here are Business Class options from New York JFK to Rome Fiumicino on the "
                 "14th. Tap Book on the one you'd like.", 24, [
                     vu(), topic("flight_booking"), llm("agent_router"),
                     act("resolve_session",
                         '{"conversationId":"01JHZP2...","sessionKey":"...AUTH/Skywave_MIAW/uid:dvc_2b70c9"}',
                         '{"success":true,"contactId":"%s","summary":"Based in New York; prefers Business cabin","profileEverCollected":true}' % cid),
                     vu(),
                     act("get_bookings", '{"contactId":"%s"}' % cid,
                         '{"success":true,"bookingCount":0,"bookings":[]}'),
                     vu(), llm("flight_booking"),
                     act("search_flights",
                         '{"origin":"JFK","destination":"FCO","departureDate":"2026-06-14","fareClass":"Business"}',
                         '{"success":true,"message":"4 options returned","flightSummary":"4 Business itineraries JFK-FCO from $3,180"}'),
                     vu(),
                 ]),
            turn("flight_booking", "Book flight SW1450",
                 "SW1450 in Business is held for you. Please complete your details so I can "
                 "issue the ticket.", 28, [
                     vu(), topic("flight_booking"), llm("flight_booking"),
                     act("book_flight",
                         '{"contactId":"%s","flightId":"SW1450","fareClass":"Business","travelDate":"2026-06-14"}' % cid,
                         '{"success":true,"selectedFlightId":"a08gK000000pT4kQAE","selectedFareClass":"Business"}'),
                     vu(),
                     act("present_profile_form", '{"contactId":"%s"}' % cid,
                         '{"success":true,"formData":"<SkywaveProfileForm rendered>"}'),
                     vu(),
                 ]),
            turn("flight_booking", "Profile created",
                 "Thanks! Your booking SW-9R7Q is reserved for $3,180.00. Choose how you'd "
                 "like to pay.", 23, [
                     vu(), topic("flight_booking"), llm("flight_booking"),
                     act("ack_profile_form",
                         '{"contactId":"%s","flightId":"a08gK000000pT4kQAE","fareClass":"Business"}' % cid,
                         '{"success":true,"bookingCode":"SW-9R7Q","totalCharged":"$3,180.00"}'),
                     vu(),
                     act("present_payment_form",
                         '{"contactId":"%s","bookingCode":"SW-9R7Q","totalCharged":"$3,180.00"}' % cid,
                         '{"success":true,"formData":"<SkywavePaymentForm rendered>"}'),
                     vu(),
                 ]),
            turn("flight_booking", "Payment completed",
                 "You're all set — Business Class from New York to Rome is confirmed for "
                 "$3,180.00, confirmation code SW-9R7Q. Anything else I can help with?", 18, [
                     vu(), topic("flight_booking"), llm("flight_booking"),
                     act("confirm_booking", '{"contactId":"%s","bookingCode":"SW-9R7Q"}' % cid,
                         '{"success":true,"confirmedCount":1,"confirmationCodes":"SW-9R7Q","totalCharged":"$3,180.00"}'),
                     vu(), guard(),
                 ]),
        ])

# ================================ HERO 3 =======================================
# A seat UPGRADE that never applies -> escalated to a human. Q1.
def _hero3_seat_upgrade():
    cid = "003gK00000MxT7bAAF"
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
            turn("seat_selection", "Can you upgrade my seat to Business on my Rome flight?",
                 "Let me open the seat map so I can move you into Business…", 22, [
                     vu(), topic("seat_selection"), llm("agent_router"),
                     act("resolve_session",
                         '{"conversationId":"01JJ0T5...","sessionKey":"...AUTH/Skywave_MIAW/uid:dvc_2b70c9"}',
                         '{"success":true,"contactId":"%s","summary":"Based in New York; prefers Business cabin"}' % cid),
                     vu(),
                     act("get_bookings", '{"contactId":"%s"}' % cid,
                         '{"success":true,"bookingCount":1,"singleBookingCode":"SW-9R7Q"}'),
                     vu(),
                     act("check_seat_enabled", '{"ignored":""}', '{"success":true,"enabled":true}'),
                     vu(), llm("seat_selection"),
                     act("get_segment_count", '{"bookingCode":"SW-9R7Q"}',
                         '{"success":true,"segmentCount":1}'),
                     vu(),
                     act_slow("present_seat_map", '{"bookingCode":"SW-9R7Q"}',
                              '{"success":false,"message":"Unable to build seat map"}',
                              "SeatMapUnavailableException: cabin-upgrade seat map could not be "
                              "generated for booking SW-9R7Q; segment fare-class inventory lookup "
                              "failed. No seat was reassigned."),
                     vu(), guard(),
                 ]),
            turn("seat_selection", "Are you able to do the upgrade?",
                 "I'm sorry — the seat map didn't load, so I couldn't apply the Business "
                 "upgrade here. I'll connect you with a Skywave agent who can complete the "
                 "upgrade for you.", 0, [
                     vu(), topic("seat_selection"), llm("seat_selection"),
                     act_slow("present_seat_map", '{"bookingCode":"SW-9R7Q"}',
                              '{"success":false,"message":"Unable to build seat map"}',
                              "SeatMapUnavailableException: seat-map generation failed again for "
                              "booking SW-9R7Q; segment inventory unavailable. Upgrade not applied."),
                     vu(), guard(),
                 ]),
        ])

# hero = (key, start_hour, start_minute, end_type, [moments])
HEROES = [
    ("hero1", 18, 40, "Abandoned", [_hero1_booking(), _hero1_seat_change()]),
    ("hero2", 16, 20, "Completed", [_hero2_booking()]),
    ("hero3", 14, 5,  "Escalated", [_hero3_seat_upgrade()]),
]

# Intents that appear (need a reusable Tag row each).
INTENT_VALUES = ["Flight Search and Booking", "Seat Change Requests", "Seat Upgrade Requests"]


# ---- id helpers (STABLE across re-push so UPSERT overwrites) -------------------
def _sid(*parts):
    return "SKYWAVE-HERO-" + "-".join(str(p) for p in parts)


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


def _hex(rng, n):
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def generate(org_id, planner_id, user_ids, agent_version="v50"):
    """Build the full STDM row graph for the 3 heroes. Returns {object: [rows]}.

    Timestamps are TODAY-RELATIVE (day -1, UTC) with millisecond precision; the
    seeded RNG makes step durations deterministic so a daily re-push reproduces
    the same shape and only rolls the date."""
    rng = random.Random(HERO_SEED)
    now = _dt.datetime.now(_dt.timezone.utc)
    base_day = (now - _dt.timedelta(days=1)).date()   # "yesterday" -> always in-window, never future

    rows = {
        "AiAgentSession": [], "AiAgentSessionParticipant": [], "AiAgentInteraction": [],
        "AiAgentInteractionMessage": [], "AiAgentInteractionStep": [], "AiAgentMoment": [],
        "AiAgentMomentInteraction": [], "AiAgentTagDefinition": [], "AiAgentTagDefinitionAssociation": [],
        "AiAgentTag": [], "AiAgentTagAssociation": [],
    }

    ES = org_id  # ExternalSourceId on every row (Analytics render gate)

    # ---- tag definitions (2) + their per-agent associations --------------------
    defs = [
        (_sid("tagdef", "intent"), AIE_INTENT_DEF, "Optimization Request Category", "Text", "Generated"),
        (_sid("tagdef", "score"), "Quality_Score", "Relevance Score", "Number", "Predefined"),
    ]
    def_created = _iso(_dt.datetime.combine(base_day, _dt.time(6, 0), _dt.timezone.utc))
    for did, dev, name, dtype, stype in defs:
        rows["AiAgentTagDefinition"].append({
            "Id": did, "Name": name, "DeveloperName": dev, "DataType": dtype,
            "SourceType": stype, "Status": "Active", "Description": name + " tag",
            "CreatedDate": def_created, "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
        rows["AiAgentTagDefinitionAssociation"].append({
            "Id": _sid("tagdefassoc", dev), "AiAgentApiName": AGENT_API_NAME,
            "AiAgentTagDefinitionId": did, "IsActive": "true", "CreatedDate": def_created,
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
    intent_def_id = _sid("tagdef", "intent")
    score_def_id = _sid("tagdef", "score")
    intent_def_assoc = _sid("tagdefassoc", AIE_INTENT_DEF)
    score_def_assoc = _sid("tagdefassoc", "Quality_Score")

    # ---- reusable tags: score 1..5 + one per intent value ----------------------
    score_tag_id = {}
    for s in range(1, 6):
        tid = _sid("tag", "score", s)
        score_tag_id[s] = tid
        rows["AiAgentTag"].append({
            "Id": tid, "AiAgentTagDefinitionId": score_def_id, "Value": str(s),
            "Description": str(s), "IsActive": "true", "CreatedDate": def_created,
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
    intent_tag_id = {}
    for iv in INTENT_VALUES:
        tid = _sid("tag", "intent", iv.replace(" ", "_"))
        intent_tag_id[iv] = tid
        rows["AiAgentTag"].append({
            "Id": tid, "AiAgentTagDefinitionId": intent_def_id, "Value": iv,
            "Description": iv, "IsActive": "true", "CreatedDate": def_created,
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

    # ---- sessions --------------------------------------------------------------
    for hi, (hkey, hh, mm, end_type, moments) in enumerate(HEROES):
        sess_id = _sid(hkey, "session")
        user_id = user_ids[hi % len(user_ids)] if user_ids else "005000000000000AAA"
        user_obj = "MessagingEndUser" if user_id.startswith("0PA") else "User"
        agent_pid = _sid(hkey, "part", "agent")
        user_pid = _sid(hkey, "part", "user")

        session_start = _dt.datetime.combine(base_day, _dt.time(hh, mm), _dt.timezone.utc)
        cursor = session_start
        session_end = session_start

        for mi, mo in enumerate(moments):
            moment_id = _sid(hkey, "moment", mi)
            moment_start = cursor
            moment_end = cursor
            for ti, tn in enumerate(mo["turns"]):
                turn_start = cursor
                inter_id = _sid(hkey, "int", mi, ti)
                trace_id = _hex(rng, 32)
                span_id = _hex(rng, 16)
                attr = '{"internalTraceId":"%s","internalSpanId":"%s"}' % (trace_id, span_id)

                # ---- steps: chain by ms, TOPIC_STEP spans the whole turn --------
                step_specs = tn["steps"]
                step_ms = []       # (start_dt, end_dt) per step
                topic_idx = None
                walk = turn_start
                for si, (kind, name, i, o, err) in enumerate(step_specs):
                    if kind == "topic":
                        topic_idx = si
                        step_ms.append([turn_start, None])   # backfilled after the turn
                        continue
                    d = _dur(rng, kind)
                    st = walk
                    en = st + _dt.timedelta(milliseconds=d)
                    step_ms.append([st, en])
                    walk = en + _dt.timedelta(milliseconds=rng.randint(3, 34))  # small inter-step gap
                turn_end = walk
                if topic_idx is not None:
                    step_ms[topic_idx][1] = turn_end

                prev_step = None
                for si, (kind, name, i, o, err) in enumerate(step_specs):
                    st, en = step_ms[si]
                    step_type = {"vu": "VARIABLE_UPDATE_STEP", "topic": "TOPIC_STEP",
                                 "llm": "LLM_STEP", "act": "ACTION_STEP",
                                 "act_slow": "ACTION_STEP", "guard": "TRUST_GUARDRAILS_STEP"}[kind]
                    inp = i if i is not None else (
                        ('{"stepType":"LLM_STEP","topic":"%s"}' % tn["topic"]) if kind == "llm"
                        else ('{"variables":"updated"}' if kind == "vu" else tn["user"]))
                    outp = o if o is not None else (
                        '{"success":true}' if kind == "vu" else tn["agent"])
                    step_id = _sid(hkey, "step", mi, ti, si)
                    rows["AiAgentInteractionStep"].append({
                        "id": step_id, "aiAgentInteractionId": inter_id,
                        "AiAgentInteractionStepType": step_type, "name": name,
                        "inputValueText": inp, "outputValueText": outp,
                        "startTimestamp": _iso(st), "endTimestamp": _iso(en),
                        "prevStepId": prev_step or "", "errorMessageText": err or "",
                        "attributeText": attr, "DataSourceId": DATA_SOURCE_PREFIX,
                        "ExternalSourceId": ES})
                    prev_step = step_id

                # ---- interaction + its 2 messages ------------------------------
                rows["AiAgentInteraction"].append({
                    "Id": inter_id, "AiAgentSessionId": sess_id, "TopicApiName": tn["topic"],
                    "AiAgentInteractionType": "TURN", "SessionOwnerId": user_id,
                    "SessionOwnerObject": user_obj, "StartTimestamp": _iso(turn_start),
                    "EndTimestamp": _iso(turn_end), "TraceId": trace_id, "SpandId": span_id,
                    "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
                rows["AiAgentInteractionMessage"].append({
                    "Id": _sid(hkey, "msg", mi, ti, "in"), "AiAgentSessionId": sess_id,
                    "AiAgentInteractionId": inter_id, "AiAgentSessionParticipantId": user_pid,
                    "AiAgentInteractionMessageType": "Input",
                    "AiAgentInteractionMsgContentType": "text/plain", "ContentText": tn["user"],
                    "MessageSentTimestamp": _iso(turn_start), "DataSourceId": DATA_SOURCE_PREFIX,
                    "ExternalSourceId": ES})
                rows["AiAgentInteractionMessage"].append({
                    "Id": _sid(hkey, "msg", mi, ti, "out"), "AiAgentSessionId": sess_id,
                    "AiAgentInteractionId": inter_id, "AiAgentSessionParticipantId": agent_pid,
                    "AiAgentInteractionMessageType": "Output",
                    "AiAgentInteractionMsgContentType": "text/plain", "ContentText": tn["agent"],
                    "MessageSentTimestamp": _iso(turn_end), "DataSourceId": DATA_SOURCE_PREFIX,
                    "ExternalSourceId": ES})
                rows["AiAgentMomentInteraction"].append({
                    "Id": _sid(hkey, "momint", mi, ti), "AiAgentMomentId": moment_id,
                    "AiAgentInteractionId": inter_id, "StartTimestamp": _iso(turn_start),
                    "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

                moment_end = turn_end
                session_end = turn_end
                cursor = turn_end + _dt.timedelta(seconds=tn["gap"])

            # ---- moment + its 2 tag associations (intent + quality) -----------
            rows["AiAgentMoment"].append({
                "Id": moment_id, "AiAgentSessionId": sess_id, "AiAgentApiName": AGENT_API_NAME,
                "AiAgentVersionApiName": agent_version, "RequestSummaryText": mo["request"],
                "ResponseSummaryText": mo["response"], "StartTimestamp": _iso(moment_start),
                "EndTimestamp": _iso(moment_end), "DataSourceId": DATA_SOURCE_PREFIX,
                "ExternalSourceId": ES})
            rows["AiAgentTagAssociation"].append({
                "Id": _sid(hkey, "ta", mi, "intent"), "AiAgentSessionId": sess_id,
                "AiAgentMomentId": moment_id, "AiAgentTagId": intent_tag_id[mo["intent"]],
                "AiAgentTagDefinitionAssociationId": intent_def_assoc,
                "AssociationReasonText": "Categorized as " + mo["intent"] + ".",
                "AiAgentSessionStartTimestamp": _iso(session_start), "CreatedDate": _iso(moment_end),
                "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})
            rows["AiAgentTagAssociation"].append({
                "Id": _sid(hkey, "ta", mi, "score"), "AiAgentSessionId": sess_id,
                "AiAgentMomentId": moment_id, "AiAgentTagId": score_tag_id[mo["score"]],
                "AiAgentTagDefinitionAssociationId": score_def_assoc,
                "AssociationReasonText": mo["reason"],
                "AiAgentSessionStartTimestamp": _iso(session_start), "CreatedDate": _iso(moment_end),
                "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

        # ---- SESSION_END terminator interaction --------------------------------
        rows["AiAgentInteraction"].append({
            "Id": _sid(hkey, "int", "end"), "AiAgentSessionId": sess_id, "TopicApiName": "NOT_SET",
            "AiAgentInteractionType": "SESSION_END", "SessionOwnerId": user_id,
            "SessionOwnerObject": user_obj, "StartTimestamp": _iso(session_end),
            "EndTimestamp": _iso(session_end), "TraceId": _hex(rng, 32), "SpandId": _hex(rng, 16),
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

        # ---- participants (AGENT + USER) — the render-gate identities ----------
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

        # ---- session row -------------------------------------------------------
        rows["AiAgentSession"].append({
            "Id": sess_id, "AiAgentChannelType": CHANNEL, "AiAgentSessionEndType": end_type,
            "StartTimestamp": _iso(session_start), "EndTimestamp": _iso(session_end),
            "IndividualId": "NOT_SET", "PreviousSessionId": "NOT_SET",
            "SessionOwnerObject": "NOT_SET", "VariableText": "NOT_SET",
            "DataSourceId": DATA_SOURCE_PREFIX, "ExternalSourceId": ES})

    return rows
