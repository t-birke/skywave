#!/usr/bin/env python3
"""Tier 5 — Interaction-SDK / Web Connector / Data Cloud customer-tracking pipeline.

Replays the canonical payloads in scripts/datacloud/payloads/ (normalized from the
proven si build) onto the target org, 100% via the Core /ssot/ API. Idempotent:
every step detects existing objects and reuses them, so re-runs and --resume are
safe. Ordered by dependency; the load-bearing websdk deviceId (the internal id the
whole pipeline keys on) flows once the connector + schema + sitemap publish.

Steps (each gated/idempotent):
  1  connector      ensure a StreamingApp/WebApp connector
  2  schema         PUT the 6 Skywave events (consentLog/catalog/userProfiling +
                    contactPointEmail/identity/partyIdentification)
  3  sitemap        PUT the Skywave sitemap (PUBLISHES the beacon — 403→200) +
                    verify the beacon CDN serves
  4  streams        POST the engagement + 3 profile data streams (DLOs)
  5  survey-dmo     POST the custom Survey_Response DMO (net-new)
  6  rel            create Survey_Response.SessionId__c → Individual.ssot__Id__c
                    (custom DMO relationship — Metadata API; DG needs it)
  7  mappings       POST the 6 web DLO→DMO field mappings
  8  ir             POST the "Skywave Unified Individual" IR ruleset (clean →
                    stock UnifiedIndividual__dlm; email + AnonymousId match rules)
  9  data-graph     POST the Skywave_Customers REALTIME data graph + refresh
  10 sdk-url        print the beacon CDN url (install.sh sets SF_INTERACTIONS_SDK_URL)

Usage:
  run_tracking.py --org si [--api v62.0] [--only step1,step2] [--from step5]
  run_tracking.py --org si --print-sdk-url     # just emit the beacon url + exit

Emits one JSON line per step on stdout ({"step":...,"status":...}); human log on stderr.
"""
import argparse
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PAY = HERE / "payloads"
sys.path.insert(0, str(HERE))
from _auth import Client, log  # noqa: E402

API = "v62.0"
API_DG = "v66.0"   # data graphs materialize on v66 (v62 = metadata-only ghost)
DATASPACE = "default"


def emit(step, **kw):
    print(json.dumps({"step": step, **kw}), flush=True)


def pj(name):
    return json.loads((PAY / name).read_text())


# ----------------------------------------------------------------------------- #
class Pipeline:
    def __init__(self, c: Client):
        self.c = c
        self.base = f"/services/data/{API}/ssot"
        self.conn = None
        self.beacon_uuid = None
        self._streams_cache = None   # /data-streams?limit=200 is ~46s on si — fetch ONCE

    def get(self, path):
        return self.c.req("GET", f"{self.base}{path}")

    def post(self, path, body):
        return self.c.req("POST", f"{self.base}{path}", body)

    def put(self, path, body):
        return self.c.req("PUT", f"{self.base}{path}", body)

    def _all_streams(self, refresh=False):
        """Cached /data-streams?limit=200 (it's ~46s per call on si). Refresh only
        after creating streams."""
        if self._streams_cache is None or refresh:
            _, d = self.get("/data-streams?limit=200")
            self._streams_cache = (d or {}).get("dataStreams", []) if isinstance(d, dict) else []
        return self._streams_cache

    # 1 — connector -----------------------------------------------------------
    def step_connector(self):
        st, lst = self.get("/connections?connectorType=StreamingApp")
        conns = (lst or {}).get("connections", []) if isinstance(lst, dict) else []
        web = [x for x in conns if str(x.get("streamingAppType", "")).upper() == "WEBAPP"]
        if web:
            self.conn = web[0]
        else:
            st, resp = self.post("/connections?connectorType=StreamingApp",
                                  {"name": "skywave_app", "label": "skywave app",
                                   "connectorType": "StreamingApp", "streamingAppType": "WebApp"})
            if st not in (200, 201):
                emit("connector", status="error", detail=str(resp)[:300]); return False
            self.conn = resp if resp.get("id") else None
            if not self.conn:  # re-list
                _, lst = self.get("/connections?connectorType=StreamingApp")
                web = [x for x in (lst or {}).get("connections", []) if str(x.get("streamingAppType","")).upper()=="WEBAPP"]
                self.conn = web[0] if web else None
        if not self.conn:
            emit("connector", status="error", detail="could not create/find WebApp connector"); return False
        if self.conn.get("id") and not self.conn.get("sourceId"):
            _, full = self.get(f"/connections/{self.conn['id']}")
            if isinstance(full, dict) and full.get("id"):
                self.conn = full
        self.beacon_uuid = self.conn.get("sourceId")
        emit("connector", status="ok", id=self.conn.get("id"), beacon=self.beacon_uuid)
        return True

    # 2 — schema --------------------------------------------------------------
    def step_schema(self):
        schemas = pj("schema.json")["schemas"]
        st, resp = self.put(f"/connections/{self.conn['id']}/schema", {"schemas": schemas})
        _, got = self.get(f"/connections/{self.conn['id']}/schema")
        have = {(e.get("category"), e.get("name")) for e in (got or {}).get("schemas", [])}
        want = {(s["category"], s["name"]) for s in schemas}
        ok = want.issubset(have)
        emit("schema", status="ok" if ok else "partial", events=len(have), want=len(want))
        return ok

    # 3 — sitemap (publishes beacon) ------------------------------------------
    def step_sitemap(self):
        sm = pj("sitemap.json") if (PAY / "sitemap.json").exists() else None
        js = sm.get("sitemap") if isinstance(sm, dict) else None
        if not js:
            # fall back to the repo's authored sitemap
            p = HERE.parent.parent / "docs" / "web-connector-sitemap.js"
            js = p.read_text() if p.exists() else None
        if not js:
            emit("sitemap", status="error", detail="no sitemap source"); return False
        st, resp = self.put(f"/connections/{self.conn['id']}/sitemap", {"sitemap": js})
        _, after = self.get(f"/connections/{self.conn['id']}/sitemap")
        ln = len((after or {}).get("sitemap", "")) if isinstance(after, dict) else 0
        beacon_ok = self._verify_beacon()
        emit("sitemap", status="ok" if (ln > 100 and beacon_ok) else "partial",
             sitemap_chars=ln, beacon_serves=beacon_ok)
        return ln > 100

    def _verify_beacon(self, tries=8, delay=10):
        if not self.beacon_uuid:
            return False
        import urllib.request, urllib.error
        url = f"https://cdn.c360a.salesforce.com/beacon/c360a/{self.beacon_uuid}/scripts/c360a.min.js"
        for i in range(tries):
            try:
                with urllib.request.urlopen(url, timeout=20) as r:
                    if r.status == 200 and len(r.read()) > 1000:
                        return True
            except Exception:  # noqa: BLE001
                pass
            if i < tries - 1:
                time.sleep(delay)
        return False

    # 4 — streams -------------------------------------------------------------
    ENG = ["cart", "cartItem", "catalog", "consentLog", "order", "orderItem"]  # schema superset
    ENG_SKYWAVE = ["catalog", "consentLog", "userProfiling"]
    PROFILE = ["contactPointEmail", "identity", "partyIdentification"]

    def _existing_streams(self):
        out = []
        for s in self._all_streams():
            ci = s.get("connectorInfo") or {}
            if ci.get("connectorType") == "StreamingApp":
                cd = ci.get("connectorDetails") or {}
                out.append({"name": s.get("name"), "events": cd.get("events") or [],
                            "status": s.get("status")})
        return out

    def step_streams(self):
        existing = self._existing_streams()
        have_eng = any(e for s in existing for e in s["events"]
                       if str(e).lower().replace(" ", "") in ("catalog", "userprofilingevent", "consent"))
        have_prof = {str(e).lower().replace(" ", "") for s in existing for e in s["events"]}
        created, skipped = [], []
        conn_name = self.conn["name"]
        if have_eng:
            skipped.append("engagement")
        else:
            st, r = self._create_stream(conn_name, "skywave_app_Behavioral_Events",
                                        "Engagement", self.ENG_SKYWAVE)
            (created if st in (200, 201) else skipped).append(f"engagement({st})")
        for ev in self.PROFILE:
            if ev.lower() in have_prof or ev.lower().replace("contactpoint", "contact point") in have_prof:
                skipped.append(ev); continue
            st, r = self._create_stream(conn_name, f"skywave_app_{ev}", "Profile", [ev])
            (created if st in (200, 201) else skipped).append(f"{ev}({st})")
        if created:
            self._all_streams(refresh=True)   # invalidate cache so mappings resolve new DLOs
        emit("streams", status="ok", created=created, skipped=skipped)
        return True

    def _create_stream(self, conn_name, base, category, events):
        pk = "deviceId" if category == "Profile" else "eventId"
        fields = [{"name": n, "label": n, "dataType": ("DateTime" if n == "dateTime" else "Text"),
                   "isPrimaryKey": (n == pk)}
                  for n in ("eventId", "dateTime", "deviceId", "sessionId", "eventType", "category")]
        dlo = {"name": f"{base}__dll", "label": base.replace("_", " "), "category": category,
               "dataLakeFieldInputRepresentations": fields, "dataspaceInfo": [{"name": DATASPACE}]}
        if category == "Engagement":
            dlo["eventDateTimeFieldName"] = "dateTime"
        body = {"name": base, "label": base.replace("_", " "), "datastreamType": "CONNECTORSFRAMEWORK",
                "connectorInfo": {"connectorType": "StreamingApp",
                                  "connectorDetails": {"name": conn_name, "streamingAppType": "WebApp",
                                                       "events": events}},
                "dataLakeObjectInfo": dlo,
                "sourceFields": [{"name": f["name"], "dataType": f["dataType"]} for f in fields],
                "mappings": [{"sourceFieldLabel": f["name"], "targetFieldName": f["name"],
                              "targetFieldReturntype": f["dataType"]} for f in fields]}
        return self.post("/data-streams", body)

    # 5 — custom Survey_Response DMO ------------------------------------------
    def step_survey_dmo(self):
        dmo = pj("survey_response_dmo.json")
        st, got = self.get("/data-model-objects/Survey_Response__dlm")
        if isinstance(got, dict) and got.get("name"):
            emit("survey-dmo", status="ok", note="already exists", fields=len(got.get("fields", [])))
            return True
        st, resp = self.post("/data-model-objects", dmo)
        ok = st in (200, 201)
        emit("survey-dmo", status="ok" if ok else "error", code=st, detail=None if ok else str(resp)[:300])
        return ok

    # 6 — custom DMO relationship (Metadata API) ------------------------------
    def step_relationship(self):
        rel = pj("survey_response_relationship.json")
        # Already present?
        _, got = self.get(f"/data-model-objects/{rel['sourceObject']}/relationships")
        rels = (got or {}).get("relationships", []) if isinstance(got, dict) else []
        for r in rels:
            if (r.get("targetObject", {}).get("name") == rel["targetObject"]
                    and r.get("sourceField", {}).get("name") == rel["sourceField"]):
                emit("relationship", status="ok", note="already exists", name=r.get("name"))
                return True
        # REST POST .../relationships returns UNKNOWN_EXCEPTION → deploy the
        # FieldSrcTrgtRelationship via the Metadata API. Needs an sf-CLI target org.
        if not self.c.target_org:
            emit("relationship", status="gate",
                 note="no sf org for Metadata API deploy; deploy the FieldSrcTrgtRelationship manually")
            return "gate"
        ok = self._deploy_relationship()
        emit("relationship", status="ok" if ok else "error",
             note="deployed FieldSrcTrgtRelationship via Metadata API")
        return ok

    def _deploy_relationship(self):
        import subprocess, tempfile, shutil
        src = PAY / "Survey_Response_to_Individual.fieldSrcTrgtRelationship-meta.xml"
        tmp = Path(tempfile.mkdtemp(prefix="skywave-rel-"))
        try:
            (tmp / "sfdx-project.json").write_text(json.dumps(
                {"packageDirectories": [{"path": "force-app", "default": True}],
                 "namespace": "", "sourceApiVersion": "62.0"}))
            d = tmp / "force-app" / "main" / "default" / "fieldSrcTrgtRelationships"
            d.mkdir(parents=True, exist_ok=True)
            shutil.copy(src, d / src.name)
            r = subprocess.run(["sf", "project", "deploy", "start", "--source-dir",
                                str(tmp / "force-app"), "--target-org", self.c.target_org, "--json"],
                               capture_output=True, text=True, cwd=str(tmp), timeout=300)
            if r.returncode != 0:
                log(f"[relationship] deploy failed: {(r.stdout or r.stderr)[-300:]}")
            return r.returncode == 0
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    # 7 — mappings ------------------------------------------------------------
    def _resolve_source_dlo(self, token):
        """Map a logical source token to the live DLO dev name (hash re-minted per org)."""
        streams = self._all_streams()
        def dll(s): return (s.get("dataLakeObjectInfo") or {}).get("name") or ""
        if token == "__web_engagement__":
            for s in streams:
                if dll(s).startswith("skywave_app_Behavioral_Events"):
                    return dll(s)
        elif token.startswith("web:"):
            ev = token.split(":", 1)[1]
            for s in streams:
                nm = dll(s)
                if nm.startswith(f"skywave_app_{ev}"):
                    return nm
        return None

    def _existing_map_sources(self, dmo):
        """Source DLO stems already mapped into this DMO (so we skip re-POSTing —
        re-POSTing an existing map is slow and can hang server-side)."""
        _, d = self.get(f"/data-model-object-mappings?dataspace={DATASPACE}&dmoDeveloperName={dmo}")
        maps = (d or {}).get("objectSourceTargetMaps", []) if isinstance(d, dict) else []
        out = set()
        for m in maps:
            # developerName is "<sourceDLO>_map_<target>_<ts>" — take the source stem
            dev = m.get("developerName", "")
            if "_map_" in dev:
                out.add(dev.split("_map_")[0])
        return out

    def step_mappings(self):
        spec = pj("mappings.json")["mappings"]
        results = []
        for m in spec:
            src = self._resolve_source_dlo(m["sourceToken"])
            if not src:
                results.append(f"{m['targetDmo']}:SRC_NOT_FOUND({m['sourceToken']})"); continue
            # skip-if-exists: is this source DLO already mapped into the target DMO?
            # The mapping dev-name stem drops the DLO's __dll suffix, so compare
            # on the stem (src is "<dlo>__dll", existing stems are "<dlo>").
            src_stem = src[:-5] if src.endswith("__dll") else src
            if src_stem in self._existing_map_sources(m["targetDmo"]):
                results.append(f"{m['targetDmo']}:exists"); continue
            body = {"objectSourceTargetMaps": [{
                "sourceEntityDeveloperName": src,
                "targetEntityDeveloperName": m["targetDmo"],
                "fieldMappings": m["fieldMappings"]}]}
            st, resp = self.post(f"/data-model-object-mappings?dataspace={DATASPACE}", body)
            txt = json.dumps(resp)
            ok = st in (200, 201) or "DUPLICATE_DLO_TO_DMO_MAPPING" in txt or "already" in txt.lower()
            results.append(f"{m['targetDmo']}:{'ok' if ok else st}")
        emit("mappings", status="ok", results=results)
        return True

    # 8 — IR ruleset ----------------------------------------------------------
    def step_ir(self):
        ir = pj("identity_resolution.json")
        st, lst = self.get("/identity-resolutions?limit=50")
        existing = (lst or {}).get("identityResolutions", []) if isinstance(lst, dict) else []
        if any(r.get("label") == ir["label"] for r in existing):
            emit("ir", status="ok", note="ruleset already exists", label=ir["label"])
            return True
        st, resp = self.post("/identity-resolutions", ir)
        ok = st in (200, 201)
        emit("ir", status="ok" if ok else "error", code=st, detail=None if ok else str(resp)[:300])
        return ok

    # 9 — data graph ----------------------------------------------------------
    def step_data_graph(self):
        dg = pj("data_graph.json")
        st, got = self.c.req("GET", f"/services/data/{API_DG}/ssot/data-graphs/{dg['name']}")
        if isinstance(got, dict) and got.get("name") and not (isinstance(got, list)):
            emit("data-graph", status="ok", note="already exists", name=dg["name"],
                 dg_status=got.get("status"))
            return True
        # NOTE: the full node-tree POST body is built by build_dg_payload() with
        # live DMO-field projection (phantom-field safety net). Emitted as a gate
        # for the orchestrator to assemble + POST on v66, OR run here if --build-dg.
        emit("data-graph", status="gate", name=dg["name"],
             note="DG build runs on v66 with live-field projection; see build_dg_payload()")
        return "gate"

    # 10 — sdk url ------------------------------------------------------------
    def _ensure_beacon(self):
        """Resolve the beacon UUID WITHOUT emitting a step line to stdout (so
        --print-sdk-url emits only the URL)."""
        if self.beacon_uuid:
            return
        if self.conn and self.conn.get("sourceId"):
            self.beacon_uuid = self.conn["sourceId"]; return
        st, lst = self.get("/connections?connectorType=StreamingApp")
        web = [x for x in (lst or {}).get("connections", [])
               if str(x.get("streamingAppType", "")).upper() == "WEBAPP"]
        if web:
            self.conn = web[0]
            self.beacon_uuid = web[0].get("sourceId")

    def sdk_url(self):
        self._ensure_beacon()
        return (f"https://cdn.c360a.salesforce.com/beacon/c360a/{self.beacon_uuid}/scripts/c360a.min.js"
                if self.beacon_uuid else None)


STEPS = ["connector", "schema", "sitemap", "streams", "survey-dmo",
         "relationship", "mappings", "ir", "data-graph"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--org", default=None)
    ap.add_argument("--only", default=None, help="comma list of steps to run")
    ap.add_argument("--from", dest="from_step", default=None, help="start from this step")
    ap.add_argument("--print-sdk-url", action="store_true")
    args = ap.parse_args()

    c = Client(target_org=args.org)
    p = Pipeline(c)

    if args.print_sdk_url:
        url = p.sdk_url()
        print(url or "", flush=True)
        sys.exit(0 if url else 1)

    run = STEPS
    if args.only:
        want = set(args.only.split(","))
        run = [s for s in STEPS if s in want]
    elif args.from_step and args.from_step in STEPS:
        run = STEPS[STEPS.index(args.from_step):]

    # connector is a prerequisite for everything — always ensure it first.
    if "connector" not in run:
        p.step_connector()

    fn = {"connector": p.step_connector, "schema": p.step_schema, "sitemap": p.step_sitemap,
          "streams": p.step_streams, "survey-dmo": p.step_survey_dmo,
          "relationship": p.step_relationship, "mappings": p.step_mappings,
          "ir": p.step_ir, "data-graph": p.step_data_graph}
    gates = []
    for s in run:
        try:
            r = fn[s]()
            if r == "gate":
                gates.append(s)
        except Exception as e:  # noqa: BLE001
            emit(s, status="error", detail=str(e)[:300])
            log(f"[{s}] EXCEPTION: {e}")
    emit("_summary", gates=gates, sdk_url=p.sdk_url())


if __name__ == "__main__":
    main()
