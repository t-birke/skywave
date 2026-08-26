#!/usr/bin/env python3
"""
Seed the 3 Skywave "hero" observability sessions straight into the STDM DMOs via
the Data Cloud Ingestion API (Path 5) — with true millisecond step timings that
the custom-SObject (Path 4 / SDO QBrix) path cannot represent.

Subcommands:
  setup     Create the 11 IngestApi sources/schemas/streams/DLO->DMO mappings
            (idempotent; state cached in source_state.json).
  push      Generate the 3 heroes (today-relative, ms-precise) and ingest them.
            Re-run daily to keep them dated "yesterday" (UPSERT, stable Ids).
  verify    Query the DMOs for the hero rows (counts + sample step timings).
  teardown  Remove the hero sources (mappings -> streams -> connections).

Auth: reuses .secrets/dc.env (Skywave_Heroku_Relay client-credentials + cdp
scopes) via dc_ingest.DC. Identities (org id, planner id, MessagingEndUser ids)
are resolved from the target org with the sf CLI.

Usage:
  python3 seed_heroes.py setup    [--target-org si]
  python3 seed_heroes.py push     [--target-org si]
  python3 seed_heroes.py verify   [--target-org si]
  python3 seed_heroes.py teardown [--target-org si]
"""
import argparse, csv, io, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stdm_schema as S        # noqa: E402
import hero_story              # noqa: E402
from dc_ingest import DC       # noqa: E402

STATE_FILE = os.path.join(HERE, "source_state.json")


def conn_name(obj):
    # Connection name == sourceName; DataSourceId derives from it. Use the short
    # STREAM_BASE (the full "Skywave_Hero_<Object>" 500s on the longest names).
    return S.STREAM_BASE[obj]


# ---- small helpers ------------------------------------------------------------
def sf_json(target_org, soql=None, org_display=False):
    if org_display:
        cmd = ["sf", "org", "display", "--json", "-o", target_org]
    else:
        cmd = ["sf", "data", "query", "--json", "-o", target_org, "-q", soql]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError("sf failed: " + (out.stderr or out.stdout))
    # sf may prepend warnings; slice from the first '{'
    txt = out.stdout
    return json.loads(txt[txt.index("{"):])


def resolve_identities(target_org):
    org_id = sf_json(target_org, org_display=True)["result"]["id"]          # 18-char
    planners = sf_json(target_org,
        "SELECT Id FROM GenAiPlannerDefinition WHERE DeveloperName LIKE "
        "'%s%%' ORDER BY CreatedDate DESC LIMIT 1" % hero_story.AGENT_API_NAME)["result"]["records"]
    if not planners:
        raise RuntimeError("no GenAiPlannerDefinition for " + hero_story.AGENT_API_NAME)
    planner_id = planners[0]["Id"][:15]                                     # 15-char form (matches live rendering rows)
    users = sf_json(target_org,
        "SELECT Id FROM MessagingEndUser LIMIT 5")["result"]["records"]
    user_ids = [u["Id"] for u in users]
    if not user_ids:
        users = sf_json(target_org, "SELECT Id FROM User WHERE IsActive=true LIMIT 5")["result"]["records"]
        user_ids = [u["Id"] for u in users]
    print("  org=%s planner=%s users=%d" % (org_id, planner_id, len(user_ids)))
    return org_id, planner_id, user_ids


def load_state():
    return json.load(open(STATE_FILE)) if os.path.exists(STATE_FILE) else {}


def save_state(st):
    json.dump(st, open(STATE_FILE, "w"), indent=2)


def to_csv(obj_def, rows):
    buf = io.StringIO()
    w = csv.writer(buf)
    cols = obj_def["cols"]
    w.writerow(cols)
    for r in rows:
        w.writerow(["" if r.get(c) is None else r.get(c) for c in cols])
    return buf.getvalue().encode()


# ---- subcommands --------------------------------------------------------------
def cmd_setup(dc, target_org):
    st = load_state()
    for o in S.OBJECTS:
        obj = o["object"]
        cname = conn_name(obj)
        entry = st.get(obj, {})
        # 1. connection (idempotent by label/name)
        existing = dc.find_ingest_connection(cname)
        if existing:
            entry["conn_id"] = existing.get("id", entry.get("conn_id"))
            entry["returned_name"] = existing.get("name", entry.get("returned_name", cname))
        else:
            _, returned, cid = dc.create_ingest_connection(cname, cname)
            entry["conn_id"] = cid
            entry["returned_name"] = returned
        entry["source_name"] = cname
        # 2. schema (safe to re-PUT)
        dc.put_schema(entry["conn_id"], obj, S.schema_fields(o))
        # 3. stream / DLO (create if not present)
        base = S.STREAM_BASE.get(obj, conn_name)
        stream_nm, dlo = dc.find_stream_dlo(base)
        if not dlo:
            dc.create_stream(base, entry["returned_name"], obj, o["pk"],
                             label=base, category=S.CATEGORY[obj],
                             event_time_field=S.EVENT_TIME.get(obj))
            for _ in range(6):
                time.sleep(4)
                stream_nm, dlo = dc.find_stream_dlo(base)
                if dlo:
                    break
        entry["stream"] = stream_nm
        entry["dlo"] = dlo
        # 4. DLO -> DMO mapping (the resolved DLO name already carries __dll)
        if dlo:
            dlo_dev = dlo if dlo.endswith("__dll") else dlo + "__dll"
            pairs = [(a + "__c", b) for a, b in o["map"]]
            code, resp = dc.create_mapping(dlo_dev, o["dmo"], pairs)
            ok = code in (200, 201) or (isinstance(resp, (list, dict)) and "DUPLICATE" in json.dumps(resp))
            entry["mapped"] = bool(ok)
            print("  %-32s conn=%s dlo=%s map=%s%s" % (
                obj, "ok", (dlo or "-"), ("ok" if ok else "FAIL"),
                "" if ok else (" -> %s %s" % (code, json.dumps(resp)[:200]))))
        else:
            entry["mapped"] = False
            print("  %-32s DLO not materialized yet — re-run setup" % obj)
        st[obj] = entry
        save_state(st)
    mapped = sum(1 for e in st.values() if e.get("mapped"))
    print("setup: %d/%d objects mapped" % (mapped, len(S.OBJECTS)))


def cmd_push(dc, target_org):
    org_id, planner_id, user_ids = resolve_identities(target_org)
    rows_by_obj = hero_story.generate(org_id, planner_id, user_ids)
    for o in S.OBJECTS:
        obj = o["object"]
        rows = rows_by_obj.get(obj, [])
        if not rows:
            continue
        csv_bytes = to_csv(o, rows)
        job = dc.ingest_csv(obj, conn_name(obj), csv_bytes)
        print("  pushed %-32s rows=%-4d job=%s" % (obj, len(rows), job))
    print("push: submitted (async — rows land in the DMOs within ~1-4 min).")


def _edge_rows(dc, sql):
    st, r = dc.query(sql)
    return (r.get("data") if isinstance(r, dict) else None) or []


def cmd_outcomes(dc, target_org):
    """Seed per-session Deflection + Abandonment score associations so the
    Optimization dashboard's Session Outcome / Deflection / Abandon / Escalation
    KPIs populate (the analyzer never scores synthetic data). Session-level
    associations (null moment) via the Ingestion API — the stable path. Derives
    each session's scores from its end-type:
       Completed -> Deflected (deflection 4-5, abandonment FALSE)
       Abandoned -> Abandoned (deflection 0-2, abandonment TRUE)
       escalated -> Escalated (via end-type; deflection 4, abandonment FALSE)
    Re-run after any SObject reseed (session unified ids change) — the daily
    cron runs it too (idempotent UPSERT keyed on stable UUID5 ids)."""
    import hashlib
    org_id = sf_json(target_org, org_display=True)["result"]["id"]
    agent = hero_story.AGENT_API_NAME

    # Resolve the platform std_ Deflection/Abandonment tag graph (org-specific ids).
    def _def_id(kind):
        rows = _edge_rows(dc, "SELECT ssot__Id__c FROM ssot__AiAgentTagDefinition__dlm "
                          "WHERE ssot__DeveloperName__c = 'std_%s_Score_%s_V1'" % (kind, agent))
        return rows[0][0] if rows else None
    defl_def, aband_def = _def_id("Deflection"), _def_id("Abandonment")
    if not defl_def or not aband_def:
        raise RuntimeError("std_ Deflection/Abandonment tag defs not found for " + agent)

    def _val_map(def_id):
        m = {}
        for v, tid in _edge_rows(dc, "SELECT ssot__Value__c, ssot__Id__c FROM ssot__AiAgentTag__dlm "
                                 "WHERE ssot__AiAgentTagDefinitionId__c = '%s'" % def_id):
            m.setdefault(v, tid)   # any one tag row per value
        return m
    defl_tag, aband_tag = _val_map(defl_def), _val_map(aband_def)

    def _defassoc(def_id):
        rows = _edge_rows(dc, "SELECT ssot__Id__c FROM ssot__AiAgentTagDefinitionAssociation__dlm "
                          "WHERE ssot__AiAgentTagDefinitionId__c = '%s' AND ssot__AiAgentApiName__c = '%s'"
                          % (def_id, agent))
        return rows[0][0] if rows else ""
    defl_da, aband_da = _defassoc(defl_def), _defassoc(aband_def)

    # Live synthetic sessions (ids drift on reseed — always query fresh).
    sessions = _edge_rows(dc, "SELECT ssot__Id__c, ssot__AiAgentSessionEndType__c, ssot__StartTimestamp__c "
                          "FROM ssot__AiAgentSession__dlm WHERE ssot__DataSourceId__c = 'Salesforce_Home' "
                          "OR ssot__DataSourceId__c LIKE 'Skywave_Hero%'")
    print("  scoring %d synthetic sessions (defl_def=%s aband_def=%s)" % (len(sessions), defl_def, aband_def))

    def _pick(sid, choices):
        h = int(hashlib.md5(sid.encode()).hexdigest(), 16)
        return choices[h % len(choices)]

    now_iso = hero_story._iso(__import__("datetime").datetime.now(__import__("datetime").timezone.utc))
    ta_obj = next(o for o in S.OBJECTS if o["object"] == "AiAgentTagAssociation")
    rows = []
    counts = {"Deflected": 0, "Abandoned": 0, "Escalated": 0}
    for sid, end_type, start_ts in sessions:
        et = (end_type or "").lower()
        if "escal" in et:
            dv, av, outcome = "4", "FALSE", "Escalated"
        elif et.startswith("aband"):
            dv, av, outcome = _pick(sid, ["0", "1", "1", "2"]), "TRUE", "Abandoned"
        else:  # Completed / Deflected
            dv, av, outcome = _pick(sid, ["5", "5", "4"]), "FALSE", "Deflected"
        counts[outcome] += 1
        if dv in defl_tag:
            rows.append({"Id": hero_story._uid("score", sid, "defl"), "AiAgentSessionId": sid,
                         "AiAgentMomentId": "", "AiAgentTagId": defl_tag[dv],
                         "AiAgentTagDefinitionAssociationId": defl_da,
                         "AssociationReasonText": "Deflection score %s: %s." % (dv, outcome),
                         "AiAgentSessionStartTimestamp": now_iso, "CreatedDate": now_iso,
                         "DataSourceId": hero_story.DATA_SOURCE_PREFIX, "ExternalSourceId": org_id})
        if av in aband_tag:
            rows.append({"Id": hero_story._uid("score", sid, "aband"), "AiAgentSessionId": sid,
                         "AiAgentMomentId": "", "AiAgentTagId": aband_tag[av],
                         "AiAgentTagDefinitionAssociationId": aband_da,
                         "AssociationReasonText": "Abandonment=%s." % av,
                         "AiAgentSessionStartTimestamp": now_iso, "CreatedDate": now_iso,
                         "DataSourceId": hero_story.DATA_SOURCE_PREFIX, "ExternalSourceId": org_id})
    print("  outcome mix: %s" % counts)
    if rows:
        job = dc.ingest_csv("AiAgentTagAssociation", conn_name("AiAgentTagAssociation"), to_csv(ta_obj, rows))
        print("  pushed %d score associations (job=%s)" % (len(rows), job))


def cmd_verify(dc, target_org):
    prefix = hero_story.DATA_SOURCE_PREFIX
    for dmo in ["ssot__AiAgentSession__dlm", "ssot__AiAgentInteraction__dlm",
                "ssot__AiAgentInteractionStep__dlm", "ssot__AiAgentMoment__dlm",
                "ssot__AiAgentTagAssociation__dlm"]:
        st, r = dc.query("SELECT COUNT(*) FROM %s WHERE ssot__DataSourceId__c LIKE '%s%%'" % (dmo, prefix))
        n = (r.get("data") or [[None]])[0][0] if isinstance(r, dict) else r
        print("  %-40s %s" % (dmo, n))
    st, r = dc.query(
        "SELECT ssot__Name__c, ssot__StartTimestamp__c, ssot__EndTimestamp__c "
        "FROM ssot__AiAgentInteractionStep__dlm WHERE ssot__DataSourceId__c LIKE '%s%%' "
        "AND ssot__AiAgentInteractionStepType__c='ACTION_STEP' LIMIT 8" % prefix)
    print("  sample ACTION_STEP timings (ms precision):")
    for row in (r.get("data") if isinstance(r, dict) else []) or []:
        print("    ", row)


def cmd_teardown(dc, target_org):
    st = load_state()
    # mappings are removed implicitly when the DLO is deleted with the stream.
    for o in reversed(S.OBJECTS):
        e = st.get(o["object"], {})
        if e.get("stream"):
            code, resp = dc.delete_stream(e["stream"])
            print("  stream %-32s del=%s" % (e["stream"], code))
    time.sleep(20)
    for o in reversed(S.OBJECTS):
        e = st.get(o["object"], {})
        if e.get("conn_id"):
            code, resp = dc.delete_connection(e["conn_id"])
            print("  conn   %-32s del=%s" % (o["object"], code))
    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
    print("teardown done.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["setup", "push", "outcomes", "verify", "teardown"])
    ap.add_argument("--target-org", default="si")
    args = ap.parse_args()
    dc = DC()
    print("[dc] core=%s cdp=%s" % (dc.core_url, dc.cdp_url))
    {"setup": cmd_setup, "push": cmd_push, "outcomes": cmd_outcomes,
     "verify": cmd_verify, "teardown": cmd_teardown}[args.command](dc, args.target_org)


if __name__ == "__main__":
    main()
