"""
Data Cloud Ingestion-API client for the Skywave "hero session" observability seed.

Adapted from the proven pronto reference (~/dev/pronto/observability/scripts/
dc_client.py). The ONLY change is the auth path: Skywave's Connected App
(Skywave_Heroku_Relay) is wired for the **client-credentials** flow with the
cdp_ingest_api / cdp_query_api scopes (creds in .secrets/dc.env: DC_CONSUMER_KEY
+ DC_CONSUMER_SECRET), so we mint the Core token with client_credentials instead
of a JWT assertion, then do the same a360 -> CDP exchange.

Host split (the #1 404 cause):
  * Core proxy = <instance>.my.salesforce.com/services/data/v62.0/ssot/...
                 connection / schema / data-stream / mapping CRUD (Core token).
  * CDP edge   = <tenant>.c360a.salesforce.com/api/v1|v2/...
                 ingest jobs + query (CDP token).

No third-party deps (urllib only; certifi used if present).
"""
import json, os, ssl, time
import urllib.request, urllib.error, urllib.parse

SSOT = "/services/data/v62.0/ssot"

# macOS Python.framework often lacks a usable CA bundle; prefer certifi, else
# fall back to an unverified context (traffic is TLS to *.salesforce.com only).
try:
    import certifi
    _SSL_CTX = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CTX = ssl.create_default_context()
    try:
        _SSL_CTX.load_default_certs()
    except Exception:
        pass
    if not _SSL_CTX.get_ca_certs():
        _SSL_CTX.check_hostname = False
        _SSL_CTX.verify_mode = ssl.CERT_NONE


def _form_post(url, form):
    data = "&".join("%s=%s" % (k, urllib.parse.quote(str(v), safe="")) for k, v in form.items()).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=60, context=_SSL_CTX) as r:
        return json.loads(r.read().decode())


class DC:
    def __init__(self, env_path=None):
        env_path = env_path or os.path.join(
            os.path.dirname(__file__), "..", "..", "..", ".secrets", "dc.env")
        env = self._load_env(env_path) if os.path.exists(env_path) else {}
        # CI fallback: let GitHub-secret env vars supply the creds when the
        # .secrets/dc.env file isn't present (the daily-refresh cron).
        for k in ("DC_CONSUMER_KEY", "DC_CONSUMER_SECRET", "DC_LOGIN_URL", "DC_INSTANCE_URL"):
            if not env.get(k) and os.environ.get(k):
                env[k] = os.environ[k]
        inst = (env.get("DC_INSTANCE_URL") or env.get("DC_LOGIN_URL")
                or "https://login.salesforce.com").rstrip("/")
        # Client-credentials grant -> Core token (Skywave_Heroku_Relay is wired
        # for this flow with a run-as user; see the connected-app description).
        core = _form_post(inst + "/services/oauth2/token", {
            "grant_type": "client_credentials",
            "client_id": env["DC_CONSUMER_KEY"],
            "client_secret": env["DC_CONSUMER_SECRET"],
        })
        self.core_token = core["access_token"]
        self.core_url = core["instance_url"].rstrip("/")
        # a360 exchange -> CDP token + the *.c360a.salesforce.com edge host.
        dc = _form_post(self.core_url + "/services/a360/token", {
            "grant_type": "urn:salesforce:grant-type:external:cdp",
            "subject_token": self.core_token,
            "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        })
        edge = dc["instance_url"]
        self.cdp_url = (edge if edge.startswith("http") else "https://" + edge).rstrip("/")
        self.cdp_token = dc["access_token"]

    @staticmethod
    def _load_env(path):
        env = {}
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:]
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    env[k.strip()] = v.strip().strip("'\"")
        return env

    # ---- raw HTTP -----------------------------------------------------------
    def _req(self, host_token, url, method="GET", body=None, ctype="application/json", raw=False):
        token = self.core_token if host_token == "core" else self.cdp_token
        data = None
        headers = {"Authorization": "Bearer " + token}
        if body is not None:
            headers["Content-Type"] = ctype
            data = body if raw else json.dumps(body).encode()
            if raw and isinstance(data, str):
                data = data.encode()
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120, context=_SSL_CTX) as r:
                txt = r.read().decode()
                return r.status, (json.loads(txt) if txt.strip() and txt.lstrip()[:1] in "[{" else txt)
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            try:
                return e.code, json.loads(txt)
            except Exception:
                return e.code, txt

    def core(self, path, method="GET", body=None):
        return self._req("core", self.core_url + path, method, body)

    def edge(self, path, method="GET", body=None, ctype="application/json", raw=False):
        return self._req("cdp", self.cdp_url + path, method, body, ctype, raw)

    # ---- Ingestion API: source / schema / stream (Core proxy) ---------------
    def find_ingest_connection(self, label):
        st, r = self.core(SSOT + "/connections?connectorType=IngestApi")
        if st == 200 and isinstance(r, dict):
            for c in r.get("connections", r.get("connectionInfoList", [])) or []:
                if c.get("label") == label or c.get("connectorName") == label or c.get("name") == label:
                    return c
        return None

    def create_ingest_connection(self, name, label):
        """Returns (submitted_name, returned_name, id). submitted_name -> sourceName."""
        st, r = self.core(SSOT + "/connections?connectorType=IngestApi", "POST",
                          {"connectorType": "IngestApi", "label": label, "name": name})
        if st not in (200, 201):
            raise RuntimeError("connection create failed %s: %s" % (st, r))
        return name, r.get("name", name), r.get("id")

    def put_schema(self, conn_id, obj_name, fields):
        """fields: list of (name, dataType). dataType in Text|Number|Date|DateTime."""
        body = {"schemas": [{"label": obj_name, "name": obj_name, "schemaType": "IngestApi",
                             "fields": [{"name": n, "label": n, "dataType": dt} for n, dt in fields]}]}
        st, r = self.core(SSOT + "/connections/%s/schema" % conn_id, "PUT", body)
        if st not in (200, 201):
            raise RuntimeError("schema PUT failed %s: %s" % (st, r))
        return r

    def create_stream(self, stream_name, returned_conn_name, obj_name, pk, label=None,
                      category="Other", event_time_field=None, retries=4):
        dlo_info = {
            "label": label or stream_name, "category": category,
            "dataspaceInfo": [{"name": "default"}],
            "dataLakeFieldInputRepresentations": [
                {"name": pk, "label": pk, "dataType": "Text", "isPrimaryKey": True}],
        }
        if category == "Engagement" and event_time_field:
            dlo_info["eventDateTimeFieldName"] = event_time_field
        body = {
            "name": stream_name, "datastreamType": "INGESTAPI",
            "connectorInfo": {"connectorType": "IngestApi",
                              "connectorDetails": {"name": returned_conn_name, "events": [obj_name]}},
            "dataLakeObjectInfo": dlo_info,
            "refreshConfig": {"refreshMode": "UPSERT"},
        }
        last = None
        for _ in range(retries):
            st, r = self.core(SSOT + "/data-streams", "POST", body)
            if st in (200, 201):
                return r
            last = (st, r)
            if st == 400 and isinstance(r, list) and "try again" in json.dumps(r):
                time.sleep(8); continue
            break
        raise RuntimeError("stream create failed %s: %s" % (last,))

    def find_stream_dlo(self, base):
        """Match the auto-suffixed stream name '<base>_<event>_<hash>' at the base
        boundary so 'AiAgentTag' does not match 'AiAgentTagDefinition'."""
        st, r = self.core(SSOT + "/data-streams?limit=200")
        if st == 200 and isinstance(r, dict):
            for ds in r.get("dataStreams", []):
                nm = ds.get("name", "")
                if nm == base or nm.startswith(base + "_"):
                    return nm, ds.get("dataLakeObjectInfo", {}).get("name")
        return None, None

    def delete_stream(self, stream_name):
        st, r = self.core(SSOT + "/data-streams/%s?shouldDeleteDataLakeObject=true"
                          % urllib.parse.quote(stream_name), "DELETE")
        return st, r

    def delete_connection(self, conn_id):
        st, r = self.core(SSOT + "/connections/%s" % conn_id, "DELETE")
        return st, r

    def create_mapping(self, dlo_dev, dmo_dev, pairs):
        body = {"sourceEntityDeveloperName": dlo_dev, "targetEntityDeveloperName": dmo_dev,
                "fieldMapping": [{"sourceFieldDeveloperName": a, "targetFieldDeveloperName": b}
                                 for a, b in pairs]}
        st, r = self.core(SSOT + "/data-model-object-mappings?dataspace=default", "POST", body)
        return st, r

    # ---- ingest job lifecycle (CDP edge) ------------------------------------
    def ingest_csv(self, obj_name, source_name, csv_bytes, operation="upsert", retries=12):
        job = None
        for _ in range(retries):
            st, r = self.edge("/api/v1/ingest/jobs", "POST",
                              {"object": obj_name, "sourceName": source_name, "operation": operation})
            if st in (200, 201):
                job = r["id"]; break
            if st in (404, 409):
                time.sleep(10); continue
            raise RuntimeError("ingest job create failed %s: %s" % (st, r))
        if not job:
            raise RuntimeError("ingest job create did not settle for %s" % obj_name)
        st, r = self.edge("/api/v1/ingest/jobs/%s/batches" % job, "PUT",
                          csv_bytes, ctype="text/csv", raw=True)
        if st not in (200, 202):
            raise RuntimeError("batch upload failed %s: %s" % (st, r))
        st, r = self.edge("/api/v1/ingest/jobs/%s" % job, "PATCH", {"state": "UploadComplete"})
        if st not in (200, 202):
            raise RuntimeError("job close failed %s: %s" % (st, r))
        return job

    def query(self, sql):
        st, r = self.edge("/api/v2/query", "POST", {"sql": sql})
        return st, r
