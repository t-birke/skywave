#!/usr/bin/env python3
"""Auth bridge for the Tier-5 Data Cloud runners.

Mints a Core JWT-Bearer access token for the Skywave_Heroku_Relay Connected App
and returns (instance_url, token). The Core /services/data/<api>/ssot/ API is all
the runners need — VERIFIED on si that a plain Api-scope token reaches every
/ssot endpoint (connections, schema, sitemap, data-streams, data-model-objects,
mappings, identity-resolutions, data-graphs); the Data Cloud cdp_* scopes are NOT
required.

Credentials (read from the repo .env + secrets/, never printed):
    SF_CLIENT_ID            consumer key of Skywave_Heroku_Relay
    SF_USERNAME             the admin/integration user to impersonate (JWT sub)
    secrets/jwt.key         the RSA private key paired with the app's cert
    SF_LOGIN_URL            token endpoint host (default login.salesforce.com)

Two transports, auto-selected:
  1. JWT bearer (preferred) — fully headless, no sf-CLI dependency.
  2. sf-CLI fallback — if JWT creds are absent, shell out to
     `sf api request rest` against --target-org (the transport proven in
     validation). Set TARGET_ORG / pass org=... to use it.

Usage:
    from _auth import Client
    c = Client(target_org="si")          # or Client() to read .env JWT creds
    status, body = c.req("GET", "/services/data/v62.0/ssot/connections")
    status, body = c.req("POST", "/services/data/v62.0/ssot/data-model-objects", payload)
"""
import base64
import json
import os
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def _ssl_context():
    """SSL context for the JWT HTTP path. Honors SF_CA_BUNDLE, then certifi, then
    the system default — so it works where Python's default CA store is broken
    (a common macOS issue). The sf-CLI transport sidesteps this entirely."""
    ca = os.environ.get("SF_CA_BUNDLE")
    if not ca:
        try:
            import certifi
            ca = certifi.where()
        except Exception:  # noqa: BLE001
            ca = None
    try:
        return ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
    except Exception:  # noqa: BLE001
        return ssl.create_default_context()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def load_env(path: Path = None) -> dict:
    path = path or (REPO_ROOT / ".env")
    env = {}
    if path.exists():
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def _b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _jwt_assertion(client_id, username, login_url, key_pem: str) -> str:
    """Build + RS256-sign a JWT bearer assertion. Uses cryptography if present,
    else falls back to `openssl dgst -sha256 -sign`."""
    header = {"alg": "RS256", "typ": "JWT"}
    now = int(time.time())
    # aud must be the LOGIN host (not the instance) for the bearer flow.
    claims = {"iss": client_id, "sub": username,
              "aud": login_url.rstrip("/"), "exp": now + 300}
    signing_input = f"{_b64url(json.dumps(header).encode())}.{_b64url(json.dumps(claims).encode())}".encode()
    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        key = serialization.load_pem_private_key(key_pem.encode(), password=None)
        sig = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    except Exception:  # noqa: BLE001 — fall back to openssl CLI
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as kf:
            kf.write(key_pem)
            keypath = kf.name
        try:
            p = subprocess.run(["openssl", "dgst", "-sha256", "-sign", keypath],
                               input=signing_input, capture_output=True)
            if p.returncode != 0:
                raise RuntimeError(f"openssl sign failed: {p.stderr.decode()[:200]}")
            sig = p.stdout
        finally:
            os.unlink(keypath)
    return f"{signing_input.decode()}.{_b64url(sig)}"


class Client:
    def __init__(self, target_org=None, env=None, api_default="v62.0"):
        self.api_default = api_default
        self.env = env if env is not None else load_env()
        self.target_org = target_org or os.environ.get("TARGET_ORG") or self.env.get("ORG_ALIAS")
        self.mode = None
        self.instance_url = None
        self.token = None
        self._init_transport()

    def _init_transport(self):
        # TRANSPORT PRIORITY (deliberate): sf-CLI FIRST when a target org is
        # available. install.sh always has an authed SDO (the SDO gate), and the
        # sf CLI manages auth + SSL natively — robust even where this Python has
        # no working CA store (common on macOS: login.salesforce.com SSL verify
        # fails, certifi absent). Raw JWT-bearer HTTP is the headless fallback for
        # environments with no sf org but valid JWT creds + a working cert store.
        if self.target_org and self._sf_available():
            try:
                info = self._sf_org_display()
                self.instance_url = info["instanceUrl"]
                self.mode = "sfcli"
                log(f"[auth] sf-CLI transport via -o {self.target_org} → {self.instance_url}")
                return
            except Exception as e:  # noqa: BLE001
                log(f"[auth] sf-CLI transport unavailable ({e}); trying JWT bearer")
        cid = self.env.get("SF_CLIENT_ID")
        user = self.env.get("SF_USERNAME")
        login = self.env.get("SF_LOGIN_URL") or "https://login.salesforce.com"
        keyfile = self.env.get("SF_JWT_PRIVATE_KEY_FILE") or "secrets/jwt.key"
        keypath = (REPO_ROOT / keyfile) if not os.path.isabs(keyfile) else Path(keyfile)
        if cid and user and keypath.exists():
            self._jwt_login(cid, user, login, keypath.read_text())
            self.mode = "jwt"
            log(f"[auth] JWT bearer OK → {self.instance_url}")
            return
        raise RuntimeError("No usable transport: need an authed --org/TARGET_ORG (sf CLI) "
                           "OR JWT creds (SF_CLIENT_ID/SF_USERNAME/secrets/jwt.key) with a "
                           "working cert store. See SECRETS.md.")

    @staticmethod
    def _sf_available():
        try:
            return subprocess.run(["sf", "--version"], capture_output=True).returncode == 0
        except Exception:  # noqa: BLE001
            return False

    def _jwt_login(self, cid, user, login, key_pem):
        assertion = _jwt_assertion(cid, user, login, key_pem)
        data = urllib.parse.urlencode({
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion}).encode()
        req = urllib.request.Request(f"{login.rstrip('/')}/services/oauth2/token",
                                     data=data, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        with urllib.request.urlopen(req, timeout=60, context=_ssl_context()) as r:
            tok = json.loads(r.read().decode())
        self.token = tok["access_token"]
        self.instance_url = tok["instance_url"]

    def _sf_org_display(self):
        r = subprocess.run(["sf", "org", "display", "--target-org", self.target_org, "--json"],
                           capture_output=True, text=True)
        clean = "".join(c for c in r.stdout if c in "\t\n" or ord(c) >= 32)
        return json.loads(clean)["result"]

    # ----------------------------------------------------------------- request
    def req(self, method, path, body=None, timeout=180):
        if self.mode == "jwt":
            return self._http(method, f"{self.instance_url}{path}", body, timeout)
        return self._sf(method, path, body, timeout)

    def _http(self, method, url, body, timeout):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as r:
                txt = r.read().decode()
                return r.status, (json.loads(txt) if txt.strip() else {})
        except urllib.error.HTTPError as e:
            txt = e.read().decode()
            try:
                return e.code, json.loads(txt)
            except Exception:  # noqa: BLE001
                return e.code, txt

    def _sf(self, method, path, body, timeout):
        cmd = ["sf", "api", "request", "rest", path, "-o", self.target_org, "--method", method]
        tmp = None
        if body is not None:
            tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump(body, tmp)
            tmp.close()
            cmd += ["--body", f"@{tmp.name}"]
        elif method in ("POST", "PUT", "PATCH"):
            cmd += ["--body", ""]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        finally:
            if tmp:
                os.unlink(tmp.name)
        out = "".join(c for c in (r.stdout or "") if c in "\t\n" or ord(c) >= 32).strip()
        if not out:
            return (200 if r.returncode == 0 else 500), {"_stderr": (r.stderr or "")[:300]}
        try:
            parsed = json.loads(out)
        except Exception:  # noqa: BLE001
            return (200 if r.returncode == 0 else 500), out
        if isinstance(parsed, list) and parsed and isinstance(parsed[0], dict) and parsed[0].get("errorCode"):
            return 400, parsed
        if isinstance(parsed, dict) and parsed.get("errorCode"):
            return 400, parsed
        return (200 if r.returncode == 0 else 500), parsed


if __name__ == "__main__":
    # Self-test: prove auth + a read.
    org = sys.argv[1] if len(sys.argv) > 1 else None
    c = Client(target_org=org)
    st, body = c.req("GET", f"/services/data/{c.api_default}/ssot/connections?connectorType=StreamingApp")
    conns = body.get("connections", []) if isinstance(body, dict) else []
    print(f"auth OK ({c.mode}) — {st}, {len(conns)} StreamingApp connector(s)")
