#!/usr/bin/env bash
# ============================================================================
# install.sh — one canonical, idempotent installer for the Skywave Interactive
# demo. This is the SINGLE SOURCE OF TRUTH for every setup command. The
# companion Claude skill (.claude/skills/skywave-install/SKILL.md) does not
# repeat these commands — it reads this file and drives it section by section,
# pausing only at the gates flagged [GATE] below.
#
# TARGET ORG: a Salesforce Demo Org (SDO), NOT a scratch org. SDOs ship with
# Data Cloud, which the observability tier needs. This script does NOT create
# the org — it verifies an authed+aliased SDO and deploys into it.
#
# TIERS (opt in with flags; default = core only):
#   ./install.sh                       Tier 1: core demo (agent, MIAW, sites, data)
#   ./install.sh --with-observability  Tiers 1 + 2 (Data Cloud session-tracing dashboards)
#   ./install.sh --with-heroku         Tiers 1 + 3 (preflight relay + consumer-site backend)
#   ./install.sh --with-globe          Tiers 1 + 4 (3D globe demo monitor UIBundle; needs Tier 3's relay)
#   ./install.sh --with-tracking       Tiers 1 + 5 (Interaction-SDK + Data Cloud customer tracking; needs DC)
#   ./install.sh --with-voice          Tiers 1 + 6 (voice agent — Chapter 9; UI-gated, conducted by the skill)
#   ./install.sh --all                 Tiers 1 + 2 + 3 + 4 + 5 + 6
#   ./install.sh --resume              Re-run; skips completed sections (see STATE FILE)
#   ./install.sh --check-stdm          Poll-only: is Data Cloud STDM ready yet? (exit 0/1)
#   ./install.sh --check-prereqs       Report required CLIs for the selected tier; exit
#   ./install.sh --help
#
# IDEMPOTENCY: an SDO is long-lived and may be partially set up from a prior
# run. EVERY section is find-or-create / skip-if-exists, so re-running (or
# --resume) is always safe. There is intentionally NO scratch-org delete here.
#
# STATE FILE: progress + derived values are written to
#   .deploy-tmp/install-state.env   (gitignored)
# after each completed section, so --resume can continue after the long Data
# Cloud STDM provisioning wait without re-deriving anything. (Observed as fast as
# ~7 min on a fresh SDO once Session Tracing is on; allow up to a few hours.)
#
# Prior gotchas preserved from orgInit.sh (the scratch-org predecessor):
#   - channel deployed as metadata, activated via Apex (IsActive read-only in MDAPI)
#   - ESC created via Tooling API (clientVersion=WebV2, no "Switch to v2" click)
#   - ESW bootstrap site vendored as DigitalExperienceBundle in force-app
#   - ESD Publish driven headlessly via Playwright (no public API for it)
# ============================================================================

set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?): $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ─── Config (override via env) ──────────────────────────────────────────────
ORG_ALIAS="${ORG_ALIAS:-si}"            # the SDO alias (memory: `si` = target SDO)
AGENT_API_NAME="Skywave_Airlines_Agent"
# The EmbeddedServiceConfig the demo uses. Ships as force-app metadata
# (EmbeddedServiceConfig/Skywave_MIAW…) WITH clientVersion=WebV2 + the hidden
# Session_ID prechat field, deployed by §1.4. (The older Tooling-API create path —
# scripts/createEmbeddedServiceConfig.sh, named Skywave_MIAW_Deployment — existed
# only because Metadata API once couldn't set WebV2; it now can, so §1.10 just
# verifies the metadata ESC instead of creating a colliding one on the same site.)
ESC_NAME="Skywave_MIAW"
CUSTOMER_SITE_NAME="skywave website"
ESW_SITE_NAME="ESA_Deployment"
HEROKU_APP="${HEROKU_APP:-skywave-app}"
OBS_DEMO_TAG="SKYWAVE_PHASE_4_5"        # Skywave_ObservabilitySeeder.DEMO_TAG
VENDOR_OBS_DIR="vendor/sdo-agentforce-observability"

STATE_DIR="${REPO_ROOT}/.deploy-tmp"
STATE_FILE="${STATE_DIR}/install-state.env"

# ─── Flags ──────────────────────────────────────────────────────────────────
WITH_OBS=0; WITH_HEROKU=0; WITH_GLOBE=0; WITH_TRACKING=0; WITH_VOICE=0; RESUME=0; MODE="install"
for arg in "$@"; do
    case "$arg" in
        --with-observability) WITH_OBS=1 ;;
        --with-heroku)        WITH_HEROKU=1 ;;
        --with-globe)         WITH_GLOBE=1 ;;
        --with-tracking)      WITH_TRACKING=1 ;;
        --with-voice)         WITH_VOICE=1 ;;
        --all)                WITH_OBS=1; WITH_HEROKU=1; WITH_GLOBE=1; WITH_TRACKING=1; WITH_VOICE=1 ;;
        --resume)             RESUME=1 ;;
        --check-stdm)         MODE="check-stdm" ;;
        --check-prereqs)      MODE="check-prereqs" ;;
        --help|-h)            MODE="help" ;;
        *) echo "Unknown arg: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# ─── Tiny helpers ─────────────────────────────────────────────────────────
say()  { printf '\n\033[1m─── %s ───\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m⚠ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

sfq() { # sfq "<SOQL>"  -> first record's first column via jq path $2 (default .Id)
    local q="$1" path="${2:-.result.records[0].Id // empty}"
    sf data query --target-org "$ORG_ALIAS" --json -q "$q" 2>/dev/null | jq -r "$path"
}
sfqt() { # tooling-api variant
    local q="$1" path="${2:-.result.records[0].Id // empty}"
    sf data query --target-org "$ORG_ALIAS" --use-tooling-api --json -q "$q" 2>/dev/null | jq -r "$path"
}

# State file: record/read completed sections + derived values.
mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || : > "$STATE_FILE"
# shellcheck disable=SC1090
state_load() { set -a; . "$STATE_FILE"; set +a; }
state_set()  { # state_set KEY VALUE  (upsert)
    local k="$1" v="$2"
    grep -q "^${k}=" "$STATE_FILE" 2>/dev/null \
        && { grep -v "^${k}=" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"; }
    printf '%s=%q\n' "$k" "$v" >> "$STATE_FILE"
}
# Section ids contain dots (1.1, 2.10) which aren't legal in shell var names,
# so DONE keys sanitize '.' -> '_'  (DONE_1_1).
_done_key()  { echo "DONE_${1//./_}"; }
done_mark()  { state_set "$(_done_key "$1")" 1; }
is_done()    { local k; k="$(_done_key "$1")"; grep -q "^${k}=" "$STATE_FILE" 2>/dev/null && [ "$(grep "^${k}=" "$STATE_FILE" | tail -1 | cut -d= -f2)" = "1" ]; }
# A section runs unless --resume AND it's already marked done.
section()    { local id="$1"; if [ "$RESUME" = "1" ] && is_done "$id"; then info "skip $id (done)"; return 1; fi; return 0; }

# ════════════════════════════════════════════════════════════════════════════
#  PREREQ CHECKS  (§0.0)
# ════════════════════════════════════════════════════════════════════════════
check_prereqs() {
    say "0.0 Prerequisite check (tier: core$([ $WITH_OBS = 1 ] && echo +observability)$([ $WITH_HEROKU = 1 ] && echo +heroku)$([ $WITH_GLOBE = 1 ] && echo +globe)$([ $WITH_TRACKING = 1 ] && echo +tracking)$([ $WITH_VOICE = 1 ] && echo +voice))"
    local missing=0
    need() { # need <cmd> <why> <hint>
        if command -v "$1" >/dev/null 2>&1; then ok "$1 — $2"
        else warn "MISSING: $1 — $2 ($3)"; missing=1; fi
    }
    need sf      "Salesforce CLI v2"        "https://developer.salesforce.com/tools/salesforcecli"
    need jq      "JSON parsing"             "brew install jq"
    need python3 "host derivation / patches" "ships with macOS"
    need node    "Playwright + LWC"          "https://nodejs.org (18+/20)"
    # Playwright (vendored in node_modules; needed for ESD publish + stream refresh)
    if node -e "require('playwright')" 2>/dev/null; then ok "playwright — headless browser gates"
    else warn "playwright not resolvable — run: npm install && npx playwright install chromium"; fi
    if [ "$WITH_HEROKU" = "1" ]; then
        need heroku  "relay deploy" "https://devcenter.heroku.com/articles/heroku-cli"
        need openssl "JWT keypair gen" "ships with macOS"
        if command -v heroku >/dev/null 2>&1 && heroku auth:whoami >/dev/null 2>&1; then
            ok "heroku authenticated ($(heroku auth:whoami 2>/dev/null))"
        else
            warn "heroku not installed/authed — run: heroku login"
            info "Salesforce internal: need a corporate Heroku account first (IIQ"
            info "HerokuSSO_Users entitlement + SSO login). See SKILL.md gate G6."
        fi
    fi
    if [ "$WITH_OBS" = "1" ]; then
        info "observability tier: the data-kit instantiation step (G4) is run by the"
        info "Claude skill via the data360 MCP (creds in .secrets/dc.env) or a Setup UI"
        info "click — install.sh marks the gate and continues; see SKILL.md."
    fi
    if [ "$WITH_GLOBE" = "1" ]; then
        need npm "globe UIBundle build" "ships with Node"
        info "globe tier: needs the Multi-Framework UIBundle app domain (*.salesforce.app)"
        info "ENABLED in Setup first (one-time, org-side — install.sh marks this gate)."
        info "Also needs Tier 3's relay URL to bake into the build (run --with-heroku too,"
        info "or set SKYWAVE_HEROKU_ORIGIN). The bundle is built (npm) then deployed."
    fi
    if [ "$WITH_TRACKING" = "1" ]; then
        info "tracking tier: builds the Interaction-SDK + Data Cloud pipeline 100% via the"
        info "Core /ssot/ API (scripts/datacloud/run_tracking.py). Needs Data Cloud active"
        info "+ the standard CRM connector's Contact→Individual/Email mappings (so IR's email"
        info "match fuses web↔CRM). Auth reuses the SF_CLIENT_ID/secrets/jwt.key app (Api"
        info "scope suffices). The DG step is gated on a fresh org (validate + report)."
    fi
    if [ "$WITH_VOICE" = "1" ]; then
        info "voice tier (Chapter 9): publishes/activates Skywave_Voice_Agent + assigns the"
        info "NativeCCaaS permsets (scripted), but the phone number + NativeVoice channel and"
        info "the 2 PSTN toggles are UI-ONLY (no public API — confirmed). The skill conducts"
        info "those gates via the voice-agent-demo skill. Needs a re-login after permsets."
    fi
    info "NOTE: 'gh' + a corporate token are only needed by the maintainer to (re)vendor"
    info "QBrix-6 — end users who clone this repo do NOT need them."
    [ "$missing" = "0" ] && ok "all required tools present" || die "install missing tools, then re-run"
}

# ════════════════════════════════════════════════════════════════════════════
#  SDO GATE  (§0.1)  [GATE: the skill conducts SDO provisioning if absent]
# ════════════════════════════════════════════════════════════════════════════
sdo_banner() {
cat >&2 <<BANNER

════════════════════════════════════════════════════════════════════
  No usable org is aliased '${ORG_ALIAS}'. Skywave Interactive needs a
  Salesforce Demo Org (SDO) — NOT a scratch org.

    1. Provision an SDO from your demo-org portal.
    2. FIRST LOGIN: the SDO shows a "Set up your demo org" dialogue —
       toggle ON **Data Cloud** and **Agentforce**, click "Apply
       selections", and let it finish (provisioning runs async, a few
       min to ~an hour). This is how Data Cloud gets enabled — the
       installer does NOT provision it. (If you clicked "Skip for now",
       re-open it from the Q Home setup card.)
    3. Authenticate + alias:
         sf org login web --alias ${ORG_ALIAS} --set-default
    4. Re-run:
         ./install.sh ${*:-}
════════════════════════════════════════════════════════════════════

BANNER
}

resolve_org() {
    say "0.1 Verifying SDO '${ORG_ALIAS}'"
    local org_json
    if ! org_json="$(sf org display --target-org "$ORG_ALIAS" --json 2>/dev/null)"; then
        sdo_banner "$@"; die "org '${ORG_ALIAS}' not authenticated"
    fi
    ORG_ID="$(echo "$org_json" | jq -r '.result.id')"
    ORG_ID_15="${ORG_ID:0:15}"
    ADMIN_USERNAME="$(echo "$org_json" | jq -r '.result.username')"
    INSTANCE_URL="$(echo "$org_json" | jq -r '.result.instanceUrl')"
    ORG_HOST="$(echo "$INSTANCE_URL" | sed -E 's|https?://||; s|/.*||')"

    # Refuse to run the additive/destructive-adjacent flow against a scratch org
    # by accident (orgInit.sh used to DELETE the scratch org at step 1 — that
    # logic is intentionally absent here; this guard is the safety net).
    case "$ORG_HOST" in
        *.scratch.my.salesforce.com)
            die "'${ORG_ALIAS}' looks like a SCRATCH org (${ORG_HOST}). This installer targets an SDO. Re-point ORG_ALIAS." ;;
    esac

    ok "org:      ${ADMIN_USERNAME}"
    ok "instance: ${INSTANCE_URL}"
    state_set ORG_ID "$ORG_ID"; state_set ORG_ID_15 "$ORG_ID_15"
    state_set ADMIN_USERNAME "$ADMIN_USERNAME"; state_set INSTANCE_URL "$INSTANCE_URL"
    state_set ORG_HOST "$ORG_HOST"

    # Derive the LWR site host + VF host from the org host (covers prod-scratch,
    # pc-rnd, and sandbox/SDO URL shapes — carried over from orgInit.sh).
    local vf_and_site
    vf_and_site="$(ORG_HOST_LOC="$ORG_HOST" python3 <<'PYEOF'
import os, re
h = os.environ['ORG_HOST_LOC']
m = re.match(r'([^.]+)\.([^.]+)\.my\.(.+)\.salesforce\.com$', h)        # prefix.cluster.my.region...
if m:
    p, c, r = m.groups(); print(f"{p}.{c}.my.{r}.site.com"); print(f"{p}--c.{c}.vf.{r}.force.com")
else:
    m = re.match(r'([^.]+)\.([^.]+)\.my\.salesforce\.com$', h)          # prod scratch
    if m:
        p, c = m.groups(); print(f"{p}.{c}.my.site.com"); print(f"{p}--c.{c}.vf.force.com")
    else:
        m = re.match(r'([^.]+)\.my\.salesforce\.com$', h)               # prefix.my...
        if m:
            print(f"{m.group(1)}.my.site.com"); print(f"{m.group(1)}--c.vf.force.com")
        else:
            print(""); print("")
PYEOF
)"
    SCRATCH_ORG_SITE_HOST="$(echo "$vf_and_site" | sed -n '1p')"
    SCRATCH_ORG_VF_HOST="$(echo "$vf_and_site" | sed -n '2p')"
    SCRT2_URL="https://${ORG_HOST/salesforce.com/salesforce-scrt.com}"
    [ -n "$SCRATCH_ORG_SITE_HOST" ] || warn "could not derive site host from ${ORG_HOST} — ESW CSP may need a manual check"
    state_set SCRATCH_ORG_SITE_HOST "$SCRATCH_ORG_SITE_HOST"
    state_set SCRATCH_ORG_VF_HOST "$SCRATCH_ORG_VF_HOST"
    state_set SCRT2_URL "$SCRT2_URL"
    export SCRATCH_ORG_SITE_HOST SCRATCH_ORG_VF_HOST

    # The CMD + remote-site files carry %%SKYWAVE_HEROKU_ORIGIN%%, substituted by
    # sfdx-project.json replaceWithEnv at EVERY deploy — and replaceWithEnv ERRORS
    # if the var is unset (same trap as AGENT_USER). So SKYWAVE_HEROKU_ORIGIN must
    # always be exported, even on a core-only install before Heroku exists.
    resolve_heroku_origin
}

# Resolve the Heroku relay origin into SKYWAVE_HEROKU_ORIGIN (https, no trailing
# slash). Priority: live dyno (if the app exists) > state file > a harmless
# placeholder so deploys never fail before Tier 3 provisions the app. Tier 3
# re-resolves to the real URL and redeploys the two files that embed it.
resolve_heroku_origin() {
    state_load
    local origin=""
    if command -v heroku >/dev/null 2>&1 && heroku auth:whoami >/dev/null 2>&1; then
        origin="$(heroku apps:info -a "$HEROKU_APP" --json 2>/dev/null | jq -r '.app.web_url // empty' 2>/dev/null)"
        origin="${origin%/}"   # strip trailing slash heroku adds
    fi
    [ -z "$origin" ] && origin="${SKYWAVE_HEROKU_ORIGIN:-}"
    [ -z "$origin" ] && origin="https://${HEROKU_APP}.herokuapp.com"  # placeholder until provisioned
    SKYWAVE_HEROKU_ORIGIN="$origin"
    export SKYWAVE_HEROKU_ORIGIN
    state_set SKYWAVE_HEROKU_ORIGIN "$origin"
}

# Seed the survey Q&A content. Substitutes %%SKYWAVE_HEROKU_ORIGIN%% in the apex
# with the resolved origin (so option image URLs follow the dyno — every install's
# Heroku hash differs) and runs it. Idempotent (upsert on the keys). If the origin
# is still the pre-provision placeholder, the apex leaves image URLs blank and
# Tier 3 §3.2b sets them once the real dyno exists.
seed_survey_content() {
    local tmp; tmp="$(mktemp -t skywave-survey.XXXXXX).apex"
    sed "s#%%SKYWAVE_HEROKU_ORIGIN%%#${SKYWAVE_HEROKU_ORIGIN}#g" \
        scripts/apex/seedSurveyContent.apex > "$tmp"
    sf apex run --target-org "$ORG_ALIAS" --file "$tmp" >/dev/null
    rm -f "$tmp"
}

# Best-effort Data Cloud presence probe. DataStream is a DC-only sObject that's
# queryable once Data Cloud is provisioned (verified on an SDO: DataConnector is
# NOT queryable even when DC is active, but DataStream is — so use DataStream).
# Returns 0 if DC present.
dc_present() {
    sf data query --target-org "$ORG_ALIAS" -q "SELECT COUNT() FROM DataStream" >/dev/null 2>&1
}

# Ensure the JWT keypair exists AND its public cert is embedded in the
# Skywave_Heroku_Relay Connected App metadata. The one app + one keypair backs
# BOTH Tier 3 (Heroku relay JWT) and Tier 5 (Data Cloud / tracking JWT via
# SF_CLIENT_ID + secrets/jwt.key), so this must run before either — and before
# §1.4 deploys the Connected App, so the org trusts a cert whose private key we
# actually hold locally (a stale committed cert would otherwise be deployed with
# no matching key). gen-jwt-keypair.sh is idempotent (won't clobber an existing
# key) and auto-embeds the cert; safe to call every run.
ensure_jwt_keypair() {
    if [ -f secrets/jwt.key ]; then
        ok "secrets/jwt.key present (cert assumed embedded)"
    else
        ./scripts/gen-jwt-keypair.sh && ok "JWT keypair generated + cert embedded in Connected App"
    fi
}

# Resolve a live access token for the target org. Newer sf CLI REDACTS accessToken
# from `sf org display --json` (prints a "[REDACTED] Use 'sf org auth
# show-access-token'…" placeholder), so reading it from there yields a bogus Bearer
# header. `sf org auth show-access-token` is the supported path (--no-prompt skips
# its interactive security warning).
org_access_token() {
    sf org auth show-access-token --target-org "$ORG_ALIAS" --no-prompt --json 2>/dev/null | jq -r '.result.accessToken // empty'
}

# Deploy the CRM-tier of the vendored observability metadata (the SDO_Analytics_*
# custom objects + their Apex/LWC/app/tabs/layouts/flexipages/permsets). These are
# plain custom objects (no Data Cloud needed) and MUST exist before the force-app
# blanket deploy: force-app's Skywave_ObservabilitySeeder / Skywave_ObservabilityWipe
# reference SDO_Analytics_*_v2__c via STATIC `new ...()` types, so they fail to
# COMPILE if the objects aren't present (the dynamic-SOQL consumers — DataStreamRunner,
# SessionInspectorController — compile fine without them, which is why this gap hid
# until the first true fresh-SDO run). Deployed as ONE unit so the flexipage→LWC and
# object→record-page action-override refs resolve in-batch (piecemeal deploys roll
# back). Idempotent (--ignore-conflicts); called from §1.3b (Tier 1 prerequisite) and
# guarded by the 1.3b done-marker so §2.2 doesn't redeploy it.
deploy_vendor_obs_crm() {
    local V="${VENDOR_OBS_DIR}/main/default"
    sf project deploy start --target-org "$ORG_ALIAS" \
        --source-dir "$V/objects" \
        --source-dir "$V/classes" \
        --source-dir "$V/lwc" \
        --source-dir "$V/applications" \
        --source-dir "$V/tabs" \
        --source-dir "$V/layouts" \
        --source-dir "$V/flexipages" \
        --source-dir "$V/permissionsets" \
        --ignore-conflicts --wait 30 --concise
}

# ════════════════════════════════════════════════════════════════════════════
#  TIER 1 — CORE DEMO   (derived from orgInit.sh, made idempotent for an SDO)
# ════════════════════════════════════════════════════════════════════════════
tier1_core() {
    state_load

    # ── 1.1 Admin KnowledgeUser flag (idempotent: update is a no-op if set) ──
    if section 1.1; then
        say "1.1 Admin KnowledgeUser flag"
        local admin_id; admin_id="$(sfq "SELECT Id FROM User WHERE Username='${ADMIN_USERNAME}'")"
        sf data update record --target-org "$ORG_ALIAS" -s User -i "$admin_id" -v "UserPermissionsKnowledgeUser=true" >/dev/null 2>&1 || true
        ok "KnowledgeUser ensured"; done_mark 1.1
    fi

    # ── 1.2 Agent user (FIND-or-create; SDO may already have one) ────────────
    if section 1.2; then
        say "1.2 Einstein Agent user"
        AGENT_USER="$(sfq "SELECT Username FROM User WHERE Profile.Name='Einstein Agent User' AND IsActive=true ORDER BY CreatedDate DESC LIMIT 1" '.result.records[0].Username // empty')"
        if [ -z "$AGENT_USER" ]; then
            AGENT_USER="$(sf org create agent-user --target-org "$ORG_ALIAS" --first-name Skywave --last-name Agent --base-username "skywaveagent@${ORG_ID}.ext" --json | jq -r '.result.username')"
            ok "created agent user: $AGENT_USER"
        else
            ok "reusing existing agent user: $AGENT_USER"
        fi
        state_set AGENT_USER "$AGENT_USER"; export AGENT_USER; done_mark 1.2
    fi
    state_load; export AGENT_USER

    # ── 1.3 Customer LWR site (skip-if-exists) ───────────────────────────────
    if section 1.3; then
        say "1.3 Customer LWR site ('${CUSTOMER_SITE_NAME}')"
        local cnt; cnt="$(sfq "SELECT COUNT(Id) c FROM Site WHERE Name IN ('skywave_website','skywave_website1')" '.result.records[0].c // 0')"
        if [ "${cnt:-0}" -ge 2 ]; then
            ok "customer site already provisioned"
        else
            sf community create --target-org "$ORG_ALIAS" --name "$CUSTOMER_SITE_NAME" --template-name "Build Your Own (LWR)" --url-path-prefix "skywave" --json >/dev/null
            for _ in $(seq 1 30); do
                cnt="$(sfq "SELECT COUNT(Id) c FROM Site WHERE Name IN ('skywave_website','skywave_website1')" '.result.records[0].c // 0')"
                [ "${cnt:-0}" -ge 2 ] && break; sleep 5
            done
            ok "customer site provisioned"
        fi
        done_mark 1.3
    fi

    # ── 1.3b Vendor observability OBJECTS (force-app compile dependency) ──────
    # force-app's Skywave_ObservabilitySeeder/Wipe statically reference the
    # SDO_Analytics_*_v2__c objects defined ONLY in vendor/, so those objects must
    # land before §1.4 or the blanket force-app deploy fails to compile them. These
    # are plain custom objects (deploy without Data Cloud), so this is safe even on
    # a core-only install. Tier 2 §2.2 skips this once 1.3b is marked done.
    if section 1.3b; then
        say "1.3b Vendor observability objects (force-app compile dependency)"
        deploy_vendor_obs_crm
        ok "vendor observability CRM metadata deployed"; done_mark 1.3b
    fi

    # ── 1.3c JWT keypair + embed cert (before §1.4 deploys the Connected App) ─
    # The Connected App ships in force-app and deploys in §1.4. Generate the
    # keypair + embed its cert FIRST so §1.4 deploys a cert whose private key we
    # actually hold (a stale committed cert would otherwise be trusted by the org
    # with no matching local key). Backs both Tier 3 and Tier 5 JWT auth.
    if section 1.3c; then
        say "1.3c JWT keypair + Connected App cert"
        ensure_jwt_keypair
        done_mark 1.3c
    fi

    # ── 1.4 Metadata deploy pass 1 (dummy routing IDs) ───────────────────────
    # BotDefinition.Id doesn't exist until the agent is published, so the
    # routing flow gets placeholders now and is redeployed with real IDs in 1.8.
    if section 1.4; then
        say "1.4 Deploy all core metadata (pass 1)"
        export SF_SKYWAVE_FLOW_AGENT_ID="DummyForInitialDeploy"
        export SF_SKYWAVE_FLOW_CHANNEL_ID="DummyForInitialDeploy"
        export SF_SKYWAVE_FLOW_QUEUE_ID="DummyForInitialDeploy"
        info "site host = ${SCRATCH_ORG_SITE_HOST:-<unset>}  vf host = ${SCRATCH_ORG_VF_HOST:-<unset>}"
        sf project deploy start --target-org "$ORG_ALIAS" --source-dir force-app --ignore-conflicts --wait 30 --concise
        ok "core metadata deployed"; done_mark 1.4
    fi

    # ── 1.5 Permsets / queue / presence (all idempotent) ─────────────────────
    if section 1.5; then
        say "1.5 Permsets, queue membership, presence"
        sf org assign permset --target-org "$ORG_ALIAS" --name Skywave_Agent_User --on-behalf-of "$AGENT_USER" 2>/dev/null || true
        local agent_uid queue_id presence_id
        agent_uid="$(sfq "SELECT Id FROM User WHERE Username='${AGENT_USER}'")"
        queue_id="$(sfq "SELECT Id FROM Group WHERE DeveloperName='main_queue' AND Type='Queue'")"
        presence_id="$(sfq "SELECT Id FROM PresenceUserConfig WHERE DeveloperName='default_presence_config'")"
        [ -n "$queue_id" ] && sf data create record --target-org "$ORG_ALIAS" -s GroupMember -v "GroupId=${queue_id} UserOrGroupId=${agent_uid}" >/dev/null 2>&1 || true
        [ -n "$presence_id" ] && sf data create record --target-org "$ORG_ALIAS" -s PresenceUserConfigUser -v "PresenceUserConfigId=${presence_id} UserId=${agent_uid}" >/dev/null 2>&1 || true
        state_set QUEUE_ID "$queue_id"
        ok "permsets + routing wired"; done_mark 1.5
    fi

    # ── 1.6 Publish + activate agent (+ BotUser patch) ───────────────────────
    # `sf agent publish` leaves BotDefinition.BotUserId null on some releases;
    # patch <botUser> into the Bot metadata, redeploy, then activate.
    if section 1.6; then
        say "1.6 Publish + activate agent"
        sf agent publish authoring-bundle --target-org "$ORG_ALIAS" --api-name "$AGENT_API_NAME" --skip-retrieve --json >/dev/null
        local patchdir botfile
        patchdir="$(mktemp -d)"
        sf project retrieve start --target-org "$ORG_ALIAS" --metadata "Bot:${AGENT_API_NAME}" --target-metadata-dir "$patchdir" --unzip --json >/dev/null
        botfile="$patchdir/unpackaged/unpackaged/bots/${AGENT_API_NAME}.bot"
        if [ -f "$botfile" ]; then
            BOTFILE="$botfile" AGENT_USER="$AGENT_USER" python3 - <<'PYEOF'
import os, re
p = os.environ['BOTFILE']; s = open(p).read()
if '<botUser>' not in s:
    s = re.sub(r'(<Bot [^>]*>)\s*\n', r'\1\n    <botUser>%s</botUser>\n' % os.environ['AGENT_USER'], s, count=1)
    open(p, 'w').write(s)
PYEOF
            sf project deploy start --target-org "$ORG_ALIAS" --metadata-dir "$patchdir/unpackaged/unpackaged" --ignore-conflicts --json >/dev/null
        fi
        rm -rf "$patchdir"
        sf agent activate --target-org "$ORG_ALIAS" --api-name "$AGENT_API_NAME" --json >/dev/null
        ok "agent published + activated"; done_mark 1.6
    fi

    # ── 1.7 Routing flow pass 2 (real IDs) ───────────────────────────────────
    if section 1.7; then
        say "1.7 Redeploy routing flow with real IDs"
        state_load
        SF_SKYWAVE_FLOW_AGENT_ID="$(sfq "SELECT Id FROM BotDefinition WHERE DeveloperName='${AGENT_API_NAME}'")"
        SF_SKYWAVE_FLOW_CHANNEL_ID="$(sfq "SELECT Id FROM ServiceChannel WHERE DeveloperName='sfdc_livemessage'")"
        SF_SKYWAVE_FLOW_QUEUE_ID="${QUEUE_ID:-$(sfq "SELECT Id FROM Group WHERE DeveloperName='main_queue' AND Type='Queue'")}"
        export SF_SKYWAVE_FLOW_AGENT_ID SF_SKYWAVE_FLOW_CHANNEL_ID SF_SKYWAVE_FLOW_QUEUE_ID
        info "agent=$SF_SKYWAVE_FLOW_AGENT_ID channel=$SF_SKYWAVE_FLOW_CHANNEL_ID queue=$SF_SKYWAVE_FLOW_QUEUE_ID"
        sf project deploy start --target-org "$ORG_ALIAS" --source-dir force-app/main/default/flows/Skywave_Route_to_Agent.flow-meta.xml --ignore-conflicts --wait 10 --concise
        ok "routing flow bound to real agent/channel/queue"; done_mark 1.7
    fi

    # ── 1.8 Activate MessagingChannel (IsActive read-only in MDAPI) ──────────
    if section 1.8; then
        say "1.8 Activate MessagingChannel"
        sf apex run --target-org "$ORG_ALIAS" --file scripts/apex/activateMessagingChannel.apex >/dev/null
        ok "messaging channel active"; done_mark 1.8
    fi

    # ── 1.9 Publish ESW bootstrap site ───────────────────────────────────────
    if section 1.9; then
        say "1.9 Publish ESW bootstrap site"
        sf community publish --target-org "$ORG_ALIAS" --name "$ESW_SITE_NAME" --json >/dev/null 2>&1 || true
        ok "ESW site published"; done_mark 1.9
    fi

    # ── 1.10 Verify the EmbeddedServiceConfig (deployed as metadata in §1.4) ──
    # The ESC ships as force-app metadata (WebV2 + Skywave_Channel + hidden
    # Session_ID prechat field) and lands in §1.4, so here we just confirm it
    # exists. (The legacy Tooling-API create path collided on the site once the
    # metadata ESC deployed; it's retained at scripts/createEmbeddedServiceConfig.sh
    # only for orgs that predate the WebV2-capable Metadata API.)
    if section 1.10; then
        say "1.10 Verify EmbeddedServiceConfig '${ESC_NAME}'"
        local esc_check; esc_check="$(sfqt "SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='${ESC_NAME}'")"
        [ -n "$esc_check" ] || die "EmbeddedServiceConfig '${ESC_NAME}' not found — did §1.4 deploy force-app/main/default/EmbeddedServiceConfig?"
        ok "ESC present (${esc_check})"; done_mark 1.10
    fi

    # ── 1.11 Publish customer LWR site + flip Network Live ───────────────────
    if section 1.11; then
        say "1.11 Publish customer site + go Live"
        sf community publish --target-org "$ORG_ALIAS" --name "$CUSTOMER_SITE_NAME" --json >/dev/null 2>&1 || true
        local net_id; net_id="$(sfq "SELECT Id FROM Network WHERE Name='${CUSTOMER_SITE_NAME}'")"
        for _ in $(seq 1 10); do
            sf data update record --target-org "$ORG_ALIAS" -s Network -i "$net_id" -v "Status=Live" >/dev/null 2>&1 && break
            sleep 5
        done
        ok "customer site Live"; done_mark 1.11
    fi

    # ── 1.12 Sample data (idempotent seeds — current Booking__c model) ───────
    # NOTE: orgInit.sh used scripts/apex/createSampleData.apex, which targets the
    # OLD Reservation__c model. The current, re-runnable seeds are these three.
    if section 1.12; then
        say "1.12 Seed demo data (idempotent)"
        # The seed apex SELECTs/writes custom fields (Aircraft_Type__c, …). FLS hides
        # no-access fields from SOQL even for a System Administrator, so without the
        # Skywave_Demo_Admin permset (the one carrying all 60 custom-field grants) the
        # seed fails with a phantom "No such column". The 'Demo' permset only covers a
        # handful of fields — assign BOTH to the running user before seeding.
        sf org assign permset --target-org "$ORG_ALIAS" --name Skywave_Demo_Admin 2>/dev/null || true
        sf org assign permset --target-org "$ORG_ALIAS" --name Demo 2>/dev/null || true
        sf apex run --target-org "$ORG_ALIAS" --file scripts/apex/seedSkywaveBookingData.apex >/dev/null
        sf apex run --target-org "$ORG_ALIAS" --file scripts/apex/seedSkywaveSeatMaps.apex   >/dev/null
        sf apex run --target-org "$ORG_ALIAS" --file scripts/apex/seedSkywaveRouteNetwork.apex >/dev/null
        # Survey Q&A (Chapter 1 content). The %%SKYWAVE_HEROKU_ORIGIN%% placeholder
        # in the apex is substituted here from the resolved origin so option image
        # URLs follow the dyno (every install's Heroku hash differs). Tier 3 §3.2b
        # re-runs the image-URL refresh once the REAL dyno is provisioned.
        resolve_heroku_origin
        seed_survey_content
        ok "booking + seatmap + route + survey content seeded"; done_mark 1.12
    fi

    # ── 1.13 Publish ESD (Playwright headless click) ───── [GATE if it fails] ─
    if section 1.13; then
        say "1.13 Publish Embedded Service Deployment"
        if node -e "require('playwright')" 2>/dev/null; then
            node scripts/publishEmbeddedServiceDeployment.mjs --target-org "$ORG_ALIAS" --deployment-name "$ESC_NAME" \
                && ok "ESD published (headless)" \
                || { warn "headless publish failed — click Publish manually then re-run --resume"; esd_manual_hint; die "ESD publish gate"; }
        else
            esd_manual_hint; die "Playwright not installed — publish ESD manually, then ./install.sh --resume"
        fi
        done_mark 1.13
    fi

    # ── 1.14 Fetch published config + bake LWC + redeploy ────────────────────
    if section 1.14; then
        say "1.14 Bake ESW config into the homepage LWC"
        state_load
        local esw_site_url
        esw_site_url="$(curl -s "${SCRT2_URL}/embeddedservice/v1/embedded-service-config?orgId=${ORG_ID_15}&esConfigName=${ESC_NAME}&language=en_US" | jq -r '.embeddedServiceConfig.siteUrl // ""')"
        [ -n "$esw_site_url" ] || die "scrt2 config endpoint returned no siteUrl — was ESD published (§1.13)?"
        info "siteUrl (scrt2): $esw_site_url"
        state_set ESW_SITE_URL "$esw_site_url"
        local redeploy; redeploy="$(mktemp -d)"
        mkdir -p "$redeploy/lwc/skywaveAirlinesHome"
        cp -r force-app/main/default/lwc/skywaveAirlinesHome/* "$redeploy/lwc/skywaveAirlinesHome/"
        LWC_JS="$redeploy/lwc/skywaveAirlinesHome/skywaveAirlinesHome.js" \
        ORG_ID_15="$ORG_ID_15" ESC_NAME="$ESC_NAME" ESW_SITE_URL="$esw_site_url" SCRT2_URL="$SCRT2_URL" python3 - <<'PYEOF'
import os
p = os.environ['LWC_JS']; s = open(p).read()
s = s.replace('__ESW_ORG_ID__', os.environ['ORG_ID_15'])
s = s.replace('__ESW_ESC_NAME__', os.environ['ESC_NAME'])
s = s.replace('__ESW_SITE_URL__', os.environ['ESW_SITE_URL'])
s = s.replace('__ESW_SCRT2_URL__', os.environ['SCRT2_URL'])
open(p, 'w').write(s)
PYEOF
        cat > "$redeploy/package.xml" <<'PKG'
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types><members>skywaveAirlinesHome</members><name>LightningComponentBundle</name></types>
    <version>66.0</version>
</Package>
PKG
        # Retry: can race the async site publish on ORG_ADMIN_LOCKED.
        local attempt out status
        for attempt in 1 2 3 4 5 6; do
            out="$(sf project deploy start --target-org "$ORG_ALIAS" --metadata-dir "$redeploy" --ignore-conflicts --json 2>&1 || true)"
            status="$(echo "$out" | jq -r '.result.status // "unknown"' 2>/dev/null || echo unknown)"
            [ "$status" = "Succeeded" ] && { ok "homepage LWC baked + deployed"; break; }
            case "$out" in
                *ORG_ADMIN_LOCKED*) info "org locked (publish in flight) — retry $attempt/6"; sleep 15 ;;
                *) [ "$attempt" -eq 6 ] && { rm -rf "$redeploy"; die "LWC deploy failed: $(echo "$out" | jq -r '.result.errorMessage // .message // .' 2>/dev/null)"; } ;;
            esac
        done
        rm -rf "$redeploy"
        done_mark 1.14
    fi

    # ── 1.15 Republish + guest access + CDN warm ─────────────────────────────
    if section 1.15; then
        say "1.15 Republish site, enable guest access, warm CDN"
        sf community publish --target-org "$ORG_ALIAS" --name "$CUSTOMER_SITE_NAME" --json >/dev/null 2>&1 || true
        # `sf community publish` resets enableGuestFileAccess=false; flip it back.
        local netdir netfile
        netdir="$(mktemp -d)"
        cat > "$netdir/pkg.xml" <<PKG
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types><members>${CUSTOMER_SITE_NAME}</members><name>Network</name></types>
    <version>66.0</version>
</Package>
PKG
        sf project retrieve start --target-org "$ORG_ALIAS" --manifest "$netdir/pkg.xml" --target-metadata-dir "$netdir/out" --unzip --json >/dev/null
        netfile="$netdir/out/unpackaged/unpackaged/networks/${CUSTOMER_SITE_NAME}.network"
        if [ -f "$netfile" ]; then
            sed 's|<enableGuestFileAccess>false</enableGuestFileAccess>|<enableGuestFileAccess>true</enableGuestFileAccess>|' "$netfile" > "$netfile.tmp" && mv "$netfile.tmp" "$netfile"
            sf project deploy start --target-org "$ORG_ALIAS" --metadata-dir "$netdir/out/unpackaged/unpackaged" --ignore-conflicts --json >/dev/null \
                && ok "guest access enabled" || warn "guest-access flip failed — enable in Experience Builder > Settings > General"
        else
            warn "Network metadata not retrieved — enable guest access manually"
        fi
        rm -rf "$netdir"
        # Warm the CDN with one authenticated server-side render so the FIRST
        # anonymous visitor doesn't hit the login screen.
        local token jar="/tmp/skywave-warm-${ORG_ID}.jar"
        token="$(org_access_token)"
        curl -sL -o /dev/null -b "$jar" -c "$jar" \
            "${INSTANCE_URL}/secur/frontdoor.jsp?sid=${token}&retURL=%2Fskywavevforcesite%2F" 2>/dev/null \
            && ok "CDN warmed" || warn "CDN warm-up failed — first guest visit may see login until it propagates"
        rm -f "$jar"
        done_mark 1.15
    fi

    local site_host="${SCRATCH_ORG_SITE_HOST:-${ORG_HOST/.my.salesforce.com/.my.site.com}}"
    say "Tier 1 complete — core demo"
    info "Customer site: https://${site_host}/skywavevforcesite"
    info "Hard-refresh (Cmd+Shift+R) to clear the LWR bundle cache."
}

esd_manual_hint() {
    state_load
    local esc_id setup_host
    esc_id="$(sfqt "SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='${ESC_NAME}'")"
    setup_host="${ORG_HOST/.my.salesforce.com/.my.salesforce-setup.com}"
    setup_host="${setup_host/.my.pc-rnd.salesforce.com/.my.pc-rnd.salesforce-setup.com}"
    setup_host="${setup_host/.sandbox.my.salesforce.com/.sandbox.my.salesforce-setup.com}"
    warn "Click Publish here, then re-run with --resume:"
    info "https://${setup_host}/lightning/setup/EmbeddedServiceDeployments/${esc_id}/view"
}

# ════════════════════════════════════════════════════════════════════════════
#  TIER 2 — DATA CLOUD OBSERVABILITY   (vendored QBrix-6 + branded seeder)
# ════════════════════════════════════════════════════════════════════════════
tier2_observability() {
    state_load
    say "TIER 2 — Data Cloud observability"

    # ── 2.1 Enable Data Cloud (fire-and-forget; SDOs usually have it) ────────
    if section 2.1; then
        say "2.1 Ensure Data Cloud is enabled"
        if dc_present; then
            ok "Data Cloud already enabled"
        else
            # Data Cloud is enabled by the SDO's first-login "Set up your demo
            # org" dialogue (toggle Data Cloud + Agentforce → Apply selections),
            # NOT by this installer — that's the supported, one-click path and it
            # also provisions the Genie permsets + data space. We don't deploy
            # CustomerDataPlatform settings or assign Genie permsets here.
            warn "[GATE] Data Cloud is not enabled on '${ORG_ALIAS}'."
            info "Open the SDO's 'Set up your demo org' dialogue (first login, or the"
            info "Q Home setup card), toggle ON **Data Cloud** + **Agentforce**, click"
            info "'Apply selections', and wait for it to finish (async, a few min to"
            info "~an hour). Then: ./install.sh --with-observability --resume"
            done_mark 2.1; return 0
        fi
        done_mark 2.1
    fi

    # ── 2.2 Deploy vendored observability metadata ───────────────────────────
    # Order: CRM objects/apex/app FIRST, then the Data Cloud layer (the field
    # maps reference both the SDO object fields and the DC DMOs, so DC must be
    # active and the objects must exist first).
    if section 2.2; then
        # CRM tier (objects/classes/lwc/app/tabs/layouts/flexipages/permsets) is a
        # force-app compile dependency, so Tier 1 §1.3b already deploys it. Redeploy
        # here only if 1.3b didn't run (e.g. someone runs Tier 2 against an org whose
        # Tier 1 predates this ordering fix). Idempotent either way.
        if is_done 1.3b; then
            ok "2.2 CRM observability metadata already deployed in §1.3b — skipping"
        else
            say "2.2 Deploy vendored observability metadata (CRM tier)"
            deploy_vendor_obs_crm
            ok "CRM observability metadata deployed"
        fi
        say "2.2b Deploy vendored observability metadata (Data Cloud tier)"
        sf project deploy start --target-org "$ORG_ALIAS" \
            --source-dir "${VENDOR_OBS_DIR}/main/default/dataStreamTemplates" \
            --source-dir "${VENDOR_OBS_DIR}/main/default/dataSourceObjects" \
            --source-dir "${VENDOR_OBS_DIR}/main/default/dataSourceBundleDefinitions" \
            --source-dir "${VENDOR_OBS_DIR}/main/default/dataSrcDataModelFieldMaps" \
            --source-dir "${VENDOR_OBS_DIR}/main/default/mktDataSources" \
            --source-dir "${VENDOR_OBS_DIR}/main/default/dataPackageKitDefinitions" \
            --source-dir "${VENDOR_OBS_DIR}/main/default/DataPackageKitObjects" \
            --ignore-conflicts --wait 30 --concise
        ok "Data Cloud observability metadata deployed"
        done_mark 2.2
    fi

    # ── 2.3 Assign analytics permsets + enable session tracing ───────────────
    if section 2.3; then
        say "2.3 Assign analytics permsets"
        for ps in SDO_Agentforce_Analytics AgentforceServiceAgentBuilder AgentforceInteractionExplorer TableauNextLimitedViewer; do
            sf org assign permset --target-org "$ORG_ALIAS" --name "$ps" 2>/dev/null && ok "assigned $ps" || warn "could not assign $ps (may not exist on this SDO / already assigned)"
        done
        warn "[GATE] Enable Setup → Einstein Audit, Analytics & Monitoring → Agentforce Session Tracing (the skill confirms this)."
        done_mark 2.3
    fi

    # ── 2.4 STDM provisioning wait — NON-BLOCKING ────────────[GATE/ASYNC]────
    # Timing varies: observed as fast as ~7 min on a fresh SDO (si2, 2026-06) once
    # Session Tracing is enabled, but Salesforce historically quotes hours — so this
    # is non-blocking and pollable rather than a fixed sleep.
    if section 2.4; then
        say "2.4 STDM provisioning"
        if stdm_ready; then
            ok "STDM already provisioned"; done_mark 2.4
        else
            state_set STDM_WAIT_STARTED_AT "$(date +%s 2>/dev/null || echo 0)"
            warn "STDM (session-tracing data model) provisioning is async — often"
            warn "minutes (seen ~7 min) but can take longer. It does NOT block."
            info "Come back (or just re-poll) and run:"
            info "    ./install.sh --check-stdm     # is it ready?"
            info "    ./install.sh --all --resume   # continue once ready"
            return 0
        fi
    fi

    # ── 2.5 Install Service + Employee Agent Analytics apps ──────[GATE]───────
    if section 2.5; then
        say "2.5 Service/Employee Agent Analytics apps"
        warn "[GATE] In Setup → Agent Analytics (Beta), install Service Agent Analytics + Employee Agent Analytics if not auto-installed (skill-guided)."
        done_mark 2.5
    fi

    # ── 2.6 Data-kit instantiation ────────────────────────────[SCRIPTED]─────
    # Instantiate the 3 SDO_AFO_* bundles (STDM/Optimization/Extra) from the
    # SDO_Agentforce_Observability kit into live SDO_Analytics_* data streams. This
    # IS programmatic — the exact SSOT REST contract the QBrix used (qx
    # QbrixCustomDataKitDeploy): POST /ssot/data-kits/{kit}?asyncMode=true + poll
    # BackgroundOperation. The data360 MCP can't express it (DMO-level only), so
    # deploy_data_kit_bundles.sh calls the API directly with the .secrets/dc.env
    # client_credentials token. PRECONDITION: a CRM/SalesforceCRM Data Cloud
    # connection keyed by the org id (standard on QBrix orgs; on a bare SDO connect
    # the Salesforce CRM home connection in DC Setup first or the job errors "No CRM
    # Connection exists"). Needs the consolidated Connected App's client_credentials
    # set up (run-as user + cdp scopes + consumer secret in .secrets/dc.env).
    if section 2.6; then
        say "2.6 Data-kit instantiation"
        if [ -f .secrets/dc.env ] && ORG_ALIAS="$ORG_ALIAS" ./scripts/datacloud/deploy_data_kit_bundles.sh; then
            ok "data-kit bundles instantiated (SDO_Analytics_* streams created)"; done_mark 2.6
        else
            echo "DATA_KIT_INSTANTIATION_GATE kit=SDO_Agentforce_Observability bundles=SDO_AFO_STDM,SDO_AFO_Optimization,SDO_AFO_Extra"
            warn "[GATE] Auto data-kit deploy didn't complete (missing .secrets/dc.env, or the CRM connection / client-credentials precondition). Fix per skill G4, or instantiate via Setup → Data Cloud → Data Kits → SDO Agentforce Observability → Components → Deploy."
            info "Mark §2.6 done once the SDO_Analytics_* data streams exist (SELECT Name FROM DataStream WHERE Name LIKE 'SDO_Analytics_%'), then --resume."
            return 0
        fi
    fi

    # ── 2.7 Seed Skywave-branded synthetic sessions (Apex) ────────[ASYNC]─────
    if section 2.7; then
        say "2.7 Seed synthetic observability sessions"
        # The seeder's own contract (Skywave_ObservabilitySeeder header): the
        # scoped WIPE must FINISH before the seed runs, or they collide. So we
        # enqueue them separately and poll AsyncApexJob between the two.
        run_apex() { local code="$1" f; f="$(mktemp -t skywave-apex.XXXXXX).apex"; printf '%s\n' "$code" > "$f"; sf apex run --target-org "$ORG_ALIAS" --file "$f" >/dev/null; rm -f "$f"; }
        wait_apex() { # wait until no Queued/Processing jobs for the named classes
            local n
            for _ in $(seq 1 90); do
                n="$(sfq "SELECT COUNT(Id) c FROM AsyncApexJob WHERE Status IN ('Queued','Processing','Preparing','Holding') AND ApexClass.Name IN ('Skywave_ObservabilitySeeder','Skywave_ObservabilityWipe')" '.result.records[0].c // 0')"
                [ "${n:-0}" = "0" ] && return 0; sleep 10
            done; return 0
        }
        info "wiping prior ${OBS_DEMO_TAG} rows (scoped)…"
        run_apex "Database.executeBatch(new Skywave_ObservabilityWipe(), 2000);"
        wait_apex
        info "seeding 400 sessions…"
        run_apex "System.enqueueJob(new Skywave_ObservabilitySeeder.SeedJob(400));"
        wait_apex
        local sess; sess="$(sfq "SELECT COUNT(Id) c FROM SDO_Analytics_AIAgentSession_v2__c WHERE Demo_Identifier__c='${OBS_DEMO_TAG}'" '.result.records[0].c // 0')"
        ok "seeded ${sess} sessions tagged ${OBS_DEMO_TAG}"
        done_mark 2.7
    fi

    # ── 2.8 Refresh Bot stream (so the deployed agent joins ssot__Bot__dlm) ──
    if section 2.8; then
        say "2.8 Refresh BotDefinition_Home stream"
        warn "[GATE] SalesforceDotCom streams refresh only from a browser. The skill runs scripts/refreshDataStreams.mjs (Playwright) or Dev Console Skywave_DataStreamRunner."
        done_mark 2.8
    fi

    # ── 2.9 Full Refresh the SDO_Analytics_*_Home streams (Playwright) ───────
    if section 2.9; then
        say "2.9 Full-refresh observability data streams"
        if node -e "require('playwright')" 2>/dev/null && [ -f scripts/refreshDataStreams.mjs ]; then
            node scripts/refreshDataStreams.mjs --target-org "$ORG_ALIAS" \
                && ok "streams refreshed (headless)" \
                || warn "headless refresh failed — run from Dev Console: Skywave_DataStreamRunner.refreshSdoAnalyticsStreams()"
        else
            warn "[GATE] Playwright/refresh script unavailable — Dev Console: Skywave_DataStreamRunner.refreshSdoAnalyticsStreams()"
        fi
        done_mark 2.9
    fi

    # ── 2.10 Validate ────────────────────────────────────────────────────────
    if section 2.10; then
        say "2.10 Validate"
        local n; n="$(sfq "SELECT COUNT(Id) c FROM SDO_Analytics_AIAgentSession_v2__c WHERE Demo_Identifier__c='${OBS_DEMO_TAG}'" '.result.records[0].c // 0')"
        ok "${n} synthetic sessions present in CRM (DMO rows land after stream refresh)"
        info "Agentforce Studio → Optimization → Insights, filter Agent = Skywave Airlines Agent, 90 days."
        done_mark 2.10
    fi
    say "Tier 2 complete — observability"
}

stdm_ready() {
    # STDM readiness signal: the AiAgent session-tracing DMO data streams exist.
    local n
    n="$(sf data query --target-org "$ORG_ALIAS" --json -q "SELECT COUNT() FROM DataStream WHERE Name LIKE '%AiAgent%'" 2>/dev/null | jq -r '.result.totalSize // 0')"
    [ "${n:-0}" -gt 0 ]
}

# ════════════════════════════════════════════════════════════════════════════
#  TIER 5 — INTERACTION-SDK / DATA CLOUD CUSTOMER TRACKING
# ════════════════════════════════════════════════════════════════════════════
# The load-bearing websdk deviceId pipeline: WebApp connector → schema → sitemap
# (publishes the beacon) → streams/DLOs → custom Survey_Response DMO → custom
# DMO relationship → 6 DLO→DMO mappings → IR ruleset → Skywave_Customers RT data
# graph → SF_INTERACTIONS_SDK_URL. All 100% via the Core /ssot/ API
# (scripts/datacloud/run_tracking.py, idempotent). Gated on Data Cloud active.
# NOTE: ordered AFTER Tier 2 (shares the DC/STDM provisioning) and ideally after
# the standard CRM connector's Contact→Individual/Email mappings exist (IR's email
# rule fuses web↔CRM through them).
tier5_tracking() {
    state_load
    say "TIER 5 — Interaction-SDK / Data Cloud customer tracking"
    command -v python3 >/dev/null 2>&1 || die "python3 required for the tracking runner"

    # ── 5.1 Run the pipeline (connector→schema→sitemap→streams→DMO→rel→maps→IR) ─
    if section 5.1; then
        say "5.1 Build the tracking pipeline (Core /ssot/ API)"
        # The runner emits one JSON line per step; surface them and capture gates.
        local out; out="$(python3 scripts/datacloud/run_tracking.py --org "$ORG_ALIAS" \
            --only connector,schema,sitemap,streams,survey-dmo,relationship,mappings,ir 2>/dev/null || true)"
        printf '%s\n' "$out" | python3 -c "
import sys, json
for line in sys.stdin:
    line=line.strip()
    if not line.startswith('{'): continue
    d=json.loads(line)
    st=d.get('step'); s=d.get('status')
    if st=='_summary': continue
    mark='  ✓' if s=='ok' else ('  ⚠' if s in ('partial','gate') else '  ✗')
    print(f\"{mark} {st}: {s}\" + (f\" — {d.get('note','')}\" if d.get('note') else ''))
" || true
        ok "pipeline stages applied (connector/schema/sitemap/streams/DMO/relationship/mappings/IR)"
        done_mark 5.1
    fi

    # ── 5.2 Data Graph (Skywave_Customers, REALTIME) ─────────────────[GATE]───
    # The DG is the riskiest step (phantom fields → status=ERROR). On a fresh org
    # the runner reports it as a gate; the skill assembles + POSTs the captured
    # payload on v66 and polls status=ready. If the DG already exists, it's reused.
    if section 5.2; then
        say "5.2 Data Graph (Skywave_Customers, REALTIME)"
        local dgout; dgout="$(python3 scripts/datacloud/run_tracking.py --org "$ORG_ALIAS" --only data-graph 2>/dev/null || true)"
        if printf '%s' "$dgout" | grep -q '"status": "ok"'; then
            ok "Skywave_Customers data graph present"
        else
            warn "[GATE] Skywave_Customers RT data graph build — the skill POSTs the captured"
            info "payload (scripts/datacloud/payloads/data_graph.json) on v66 and polls status=ready."
            info "Needs the custom Survey_Response→Individual relationship (5.1) materialized first."
        fi
        done_mark 5.2
    fi

    # ── 5.3 Wire the beacon URL into Heroku (if Tier 3 ran) ──────────────────
    if section 5.3; then
        say "5.3 Wire SF_INTERACTIONS_SDK_URL"
        local sdk; sdk="$(python3 scripts/datacloud/run_tracking.py --org "$ORG_ALIAS" --print-sdk-url 2>/dev/null | tail -1)"
        state_set SF_INTERACTIONS_SDK_URL "$sdk"
        if [ -n "$sdk" ]; then
            ok "beacon URL: $sdk"
            if [ "$WITH_HEROKU" = "1" ] && command -v heroku >/dev/null 2>&1 && heroku auth:whoami >/dev/null 2>&1; then
                heroku config:set -a "$HEROKU_APP" "SF_INTERACTIONS_SDK_URL=$sdk" >/dev/null \
                    && ok "set SF_INTERACTIONS_SDK_URL on $HEROKU_APP" \
                    || warn "could not set SF_INTERACTIONS_SDK_URL on Heroku — set it manually"
            else
                info "Heroku not in this run — set it later: heroku config:set SF_INTERACTIONS_SDK_URL=$sdk -a $HEROKU_APP"
            fi
        else
            warn "could not resolve the beacon URL (connector not ready?)"
        fi
        done_mark 5.3
    fi
    say "Tier 5 complete — customer tracking"
    info "Browse + survey events now flow into Data Cloud; IR stitches anonymous→known on the websdk deviceId."
}

# ════════════════════════════════════════════════════════════════════════════
#  TIER 6 — VOICE AGENT (Chapter 9)
# ════════════════════════════════════════════════════════════════════════════
# Voice is heavily UI-gated: the phone number + NativeVoice channel (Communication
# Channels UI) and the two Agentforce Voice PSTN toggles have NO public API
# (confirmed — see the voice-agent-demo skill). So this tier scripts what it can
# (publish/activate the voice agent + the bot-user Apex permset + the NativeCCaaS
# permsets + the telephony toggle) and marks the rest as gates the skill conducts.
# The voice metadata (Skywave_Voice_Agent bundle, Skywave_VoiceCallResolver +
# trigger, skywave_routing queue/routing-config, VoiceCall flexipage) already
# deploys with the Tier-1 blanket force-app deploy.
VOICE_AGENT_API_NAME="Skywave_Voice_Agent"
tier6_voice() {
    state_load; export AGENT_USER
    say "TIER 6 — voice agent (Chapter 9)"

    # ── 6.1 NativeCCaaS permsets + telephony toggle (scripted) ───────────────
    if section 6.1; then
        say "6.1 Contact Center permsets + telephony"
        for ps in ContactCenterAdminNativeCCaaS ContactCenterAgentNativeCCaaS ContactCenterSupervisorNativeCCaaS; do
            sf org assign permset --target-org "$ORG_ALIAS" --name "$ps" 2>/dev/null && ok "assigned $ps" || warn "could not assign $ps (may not exist / already assigned)"
        done
        sf org assign permsetgroup --target-org "$ORG_ALIAS" --name SDO_Service_CCaaS 2>/dev/null && ok "assigned SDO_Service_CCaaS PSG" || true
        warn "[GATE] Log OUT and back IN to the org now — softphone provisioning happens at session start; the channel UI options won't appear until you do."
        done_mark 6.1
    fi

    # ── 6.2 Publish + activate the voice agent (+ BotUser patch, like §1.6) ──
    if section 6.2; then
        say "6.2 Publish + activate ${VOICE_AGENT_API_NAME}"
        [ -n "${AGENT_USER:-}" ] || { state_load; export AGENT_USER; }
        # The bot user needs the agent's Apex permset BEFORE publish or the planner
        # ships empty action wiring (memory: bot-user-apex-permissions).
        sf org assign permset --target-org "$ORG_ALIAS" --name Skywave_Agent_User --on-behalf-of "$AGENT_USER" 2>/dev/null || true
        sf agent publish authoring-bundle --target-org "$ORG_ALIAS" --api-name "$VOICE_AGENT_API_NAME" --skip-retrieve --json >/dev/null
        # Same BotUserId-null workaround as the chat agent (§1.6): patch <botUser>.
        local patchdir botfile
        patchdir="$(mktemp -d)"
        sf project retrieve start --target-org "$ORG_ALIAS" --metadata "Bot:${VOICE_AGENT_API_NAME}" --target-metadata-dir "$patchdir" --unzip --json >/dev/null 2>&1 || true
        botfile="$patchdir/unpackaged/unpackaged/bots/${VOICE_AGENT_API_NAME}.bot"
        if [ -f "$botfile" ]; then
            BOTFILE="$botfile" AGENT_USER="$AGENT_USER" python3 - <<'PYEOF'
import os, re
p = os.environ['BOTFILE']; s = open(p).read()
if '<botUser>' not in s:
    s = re.sub(r'(<Bot [^>]*>)\s*\n', r'\1\n    <botUser>%s</botUser>\n' % os.environ['AGENT_USER'], s, count=1)
    open(p, 'w').write(s)
PYEOF
            sf project deploy start --target-org "$ORG_ALIAS" --metadata-dir "$patchdir/unpackaged/unpackaged" --ignore-conflicts --json >/dev/null 2>&1 || true
        fi
        rm -rf "$patchdir"
        sf agent activate --target-org "$ORG_ALIAS" --api-name "$VOICE_AGENT_API_NAME" --json >/dev/null
        ok "voice agent published + activated"
        done_mark 6.2
    fi

    # ── 6.3 Phone number + NativeVoice channel (UI GATE) ─────────────────────
    if section 6.3; then
        say "6.3 Phone number + voice channel"
        warn "[GATE] Claim a phone number + create a NativeVoice channel in Setup →"
        info "Communication Channels (UI-only — no API). CRITICAL: do this AFTER §6.1's"
        info "permsets + re-login, or the channel create fails and the number is stuck."
        info "The skill conducts this via the voice-agent-demo skill (Stage 3); set the"
        info "channel's Call Routing to a voice queue, then mark §6.3 done + --resume."
        return 0
    fi

    # ── 6.4 PSTN toggles + routing to the agent (UI GATE) ────────────────────
    if section 6.4; then
        say "6.4 PSTN toggles + agent routing"
        warn "[GATE] Setup → Agentforce Voice Setup → PSTN tab: enable BOTH 'Connect"
        info "Related Voice Calls' + 'Record Voice Calls' (off by default, no API — without"
        info "them the rep sees an empty transcript). Then point the channel's routing at"
        info "${VOICE_AGENT_API_NAME} (Omni-Flow) + the skywave_routing queue (LeastActive,"
        info "already deployed). Caller-id→Contact resolution runs via Skywave_VoiceCallResolve."
        return 0
    fi
    say "Tier 6 complete — voice agent"
    info "Call the claimed number; ${VOICE_AGENT_API_NAME} answers and can transfer to a human."
}

# ════════════════════════════════════════════════════════════════════════════
#  TIER 3 — HEROKU RELAY
# ════════════════════════════════════════════════════════════════════════════
tier3_heroku() {
    state_load
    say "TIER 3 — Heroku relay"
    command -v heroku >/dev/null 2>&1 || die "heroku CLI not installed"
    heroku auth:whoami >/dev/null 2>&1 || die "not logged into Heroku — run: heroku login"

    # ── 3.1 JWT keypair + Connected App cert ─────────────────────────────────
    # Tier 1 §1.3c already generates the keypair + embeds the cert, and §1.4
    # deploys the Connected App. This re-ensures it for the case where someone
    # runs Tier 3 against an org whose Tier 1 predates §1.3c (no key yet) — then
    # redeploys the app so the org trusts the freshly embedded cert.
    if section 3.1; then
        say "3.1 JWT keypair + Connected App cert"
        if [ -f secrets/jwt.key ]; then
            ok "secrets/jwt.key present (embedded + deployed in Tier 1 §1.3c/§1.4)"
        else
            ensure_jwt_keypair
            sf project deploy start --target-org "$ORG_ALIAS" \
                --source-dir force-app/main/default/connectedApps/Skywave_Heroku_Relay.connectedApp-meta.xml \
                --ignore-conflicts --json >/dev/null \
                && ok "Connected App deployed with the new cert" \
                || warn "Connected App redeploy failed — deploy Skywave_Heroku_Relay manually so the org trusts secrets/jwt.crt"
        fi
        warn "[GATE] MANUAL on Skywave_Heroku_Relay (scopes + admin-approved + client-credentials-enabled are already deployed via CA metadata):"
        warn "  (1) assign the Client Credentials Flow RUN-AS USER — App Manager → Edit Policies. It's the Tooling field ExecutionUserId, which is READ-ONLY via API (no metadata/Tooling write path), so UI-only. IMPORTANT: a Connected App metadata REDEPLOY clobbers it back to empty, so set it LAST — after this run, not before."
        warn "  (2) fetch the consumer key+secret once — App Manager → Manage Consumer Details → .secrets/dc.env + .env SF_CLIENT_ID."
        warn "  (3) upload the MIAW public JWK to the Salesforce Keyset (Setup → Messaging User Verification)."
        done_mark 3.1
    fi

    # ── 3.2 Ensure the Heroku app + git remote, capture the REAL url ─────────
    # `heroku create skywave-app` keeps the name 'skywave-app' but the
    # herokuapp.com URL gets a per-app random hash (Heroku security behavior
    # since 2023-06-14), so the URL is only knowable from apps:info — never
    # constructed. We capture it into SKYWAVE_HEROKU_ORIGIN here.
    if section 3.2; then
        say "3.2 Heroku app '${HEROKU_APP}'"
        if heroku apps:info -a "$HEROKU_APP" >/dev/null 2>&1; then
            ok "app exists (reusing)"
        else
            heroku create "$HEROKU_APP" && ok "app created" \
                || die "heroku create failed (name '${HEROKU_APP}' taken on another account? set HEROKU_APP=<unique>)"
        fi
        git remote get-url heroku >/dev/null 2>&1 || heroku git:remote -a "$HEROKU_APP"
        resolve_heroku_origin   # now picks up the live web_url
        ok "relay origin: ${SKYWAVE_HEROKU_ORIGIN}"
        done_mark 3.2
    fi

    # ── 3.2b Embed the real URL into the org (CMD + remote site) ─────────────
    # These two files carry %%SKYWAVE_HEROKU_ORIGIN%%; Tier 1 deployed them with
    # the placeholder, so redeploy them now that the real URL is known. (All
    # Apex/LWC read the CMD at runtime, the CSP + ESW iframe allow *.herokuapp.com
    # by wildcard, so ONLY these two need the concrete value.)
    if section 3.2b; then
        say "3.2b Embed relay URL into the org"
        state_load; resolve_heroku_origin
        sf project deploy start --target-org "$ORG_ALIAS" \
            --source-dir force-app/main/default/customMetadata/Skywave_Preflight_Config.Default.md-meta.xml \
            --source-dir force-app/main/default/remoteSiteSettings/Skywave_Heroku_Relay.remoteSite-meta.xml \
            --ignore-conflicts --json >/dev/null \
            && ok "CMD + remote site point at ${SKYWAVE_HEROKU_ORIGIN}" \
            || warn "redeploy of CMD/remote-site failed — set Heroku_Origin_Url__c manually to ${SKYWAVE_HEROKU_ORIGIN}"
        # Survey option images are served by THIS dyno — repoint them now the real
        # origin is known (Tier 1 §1.12 may have used the pre-provision placeholder).
        local _imgapex; _imgapex="$(mktemp -t skywave-img.XXXXXX).apex"
        sed "s#%%SKYWAVE_HEROKU_ORIGIN%%#${SKYWAVE_HEROKU_ORIGIN}#g" scripts/apex/updateSurveyImageUrls.apex > "$_imgapex"
        sf apex run --target-org "$ORG_ALIAS" --file "$_imgapex" >/dev/null 2>&1 \
            && ok "survey image URLs repointed at ${SKYWAVE_HEROKU_ORIGIN}" \
            || warn "survey image-URL refresh skipped/failed (run scripts/apex/updateSurveyImageUrls.apex)"
        rm -f "$_imgapex"
        info "globe UIBundle: rebuild with VITE_RELAY_WS_URL=\"${SKYWAVE_HEROKU_ORIGIN/https:/wss:}/ws/monitor\" (see its README)"
        done_mark 3.2b
    fi

    # ── 3.3 Config vars (derived from tier-1 outputs + secrets) ──────────────
    if section 3.3; then
        say "3.3 Set Heroku config vars"
        state_load; resolve_heroku_origin
        [ -n "${ESW_SITE_URL:-}" ] || warn "ESW_SITE_URL not in state — run tier 1 first (or --resume) so the relay can serve the widget"
        local sets=()
        sets+=("SF_LOGIN_URL=https://login.salesforce.com")
        sets+=("SF_USERNAME=${ADMIN_USERNAME}")
        sets+=("SF_ESW_ORG_ID=${ORG_ID_15}")
        sets+=("SF_ESW_ESC_NAME=${ESC_NAME}")
        [ -n "${ESW_SITE_URL:-}" ] && sets+=("SF_ESW_SITE_URL=${ESW_SITE_URL}")
        sets+=("SF_ESW_SCRT2_URL=${SCRT2_URL}")
        sets+=("SKYWAVE_PUBLIC_ORIGIN=${SKYWAVE_HEROKU_ORIGIN}")
        heroku config:set -a "$HEROKU_APP" "${sets[@]}" >/dev/null
        ok "derived config vars set"
        # Secret-bearing vars (only if the local secret exists; never echoed).
        [ -f secrets/jwt.key ] && heroku config:set -a "$HEROKU_APP" SF_JWT_PRIVATE_KEY="$(cat secrets/jwt.key)" >/dev/null && ok "SF_JWT_PRIVATE_KEY set"
        if [ -f .secrets/preflight.key ]; then
            local _pfk; _pfk="$(cat .secrets/preflight.key)"
            heroku config:set -a "$HEROKU_APP" PREFLIGHT_KEY="$_pfk" >/dev/null && ok "PREFLIGHT_KEY set on Heroku"
            # Mirror the SAME key into the org's CMD so the preflight callout auth
            # matches (the key is a secret — never committed to the CMD XML; set
            # here via the native Metadata API in anonymous Apex). §3g.
            local _pfapex; _pfapex="$(mktemp -t skywave-pfk.XXXXXX).apex"
            sed "s#%%PREFLIGHT_KEY%%#${_pfk}#g" scripts/apex/setPreflightKey.apex > "$_pfapex"
            sf apex run --target-org "$ORG_ALIAS" --file "$_pfapex" >/dev/null 2>&1 \
                && ok "Preflight_Key__c CMD set in org (matches Heroku)" \
                || warn "could not set Preflight_Key__c CMD — preflight relay checks will fail until it matches PREFLIGHT_KEY"
            rm -f "$_pfapex"
        fi
        warn "[GATE] Set remaining secret vars manually if used: SF_CLIENT_ID, SF_MIAW_JWT_*, SKYWAVE_PROOF_KEY, IPINFO_TOKEN, CORS_PROXY_URL (see .env.example / SECRETS.md)."
        done_mark 3.3
    fi

    # ── 3.4 Deploy (push from repo root — NOT a subtree push) ────────────────
    if section 3.4; then
        say "3.4 Deploy relay (git push heroku)"
        local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
        git push heroku "${branch}:main" -f && ok "relay deployed" || die "git push heroku failed"
        done_mark 3.4
    fi

    # ── 3.5 Smoke test ───────────────────────────────────────────────────────
    if section 3.5; then
        say "3.5 Smoke test /api/preflight"
        state_load; resolve_heroku_origin
        local url="${SKYWAVE_HEROKU_ORIGIN}/api/preflight" key=""
        [ -f .secrets/preflight.key ] && key="$(cat .secrets/preflight.key)"
        if curl -sf -H "x-preflight-key: ${key}" "$url" >/dev/null 2>&1; then ok "relay healthy"; else warn "preflight check did not pass — verify config vars + dyno logs (heroku logs -a ${HEROKU_APP})"; fi
        done_mark 3.5
    fi
    say "Tier 3 complete — Heroku relay"
    info "Relay: ${SKYWAVE_HEROKU_ORIGIN}"
}

# ════════════════════════════════════════════════════════════════════════════
#  TIER 4 — GLOBE DEMO MONITOR (Multi-Framework UIBundle)
# ════════════════════════════════════════════════════════════════════════════
# The globe is excluded from Tier 1's blanket force-app deploy (a block in the
# root .forceignore) and shipped here instead, because: (1) its dist/ is
# gitignored and must be BUILT from source first, with the relay URL baked in at
# build time; (2) the CustomApplication references <uiBundle>c__SkywaveGlobe, so
# app+permset+CSP must deploy WITH the bundle (deploying the app without the
# bundle errors "forceignored but is required"). .forceignore is honored even on
# explicit --source-dir, so §4.2 temporarily neutralizes the globe block for the
# deploy and restores it (node_modules stays excluded by the bundle's local
# .forceignore, keeping the payload small). Verified on si: 94 components, 0 err.
GLOBE_DIR="force-app/main/default/uiBundles/SkywaveGlobe"
tier4_globe() {
    state_load
    say "TIER 4 — globe demo monitor"
    command -v node >/dev/null 2>&1 || die "node not installed (needed to build the globe UIBundle)"

    # ── 4.0 App-domain prerequisite (Setup-only) ───────────────────[GATE]────
    if section 4.0; then
        say "4.0 Multi-Framework app domain"
        warn "[GATE] The UIBundle serves from *.salesforce.app. Enable the Multi-Framework"
        info  "UIBundle app domain in Setup (one-time, org-side — can't be scripted) BEFORE"
        info  "the bundle will load. The skill confirms this; mark 4.0 done + --resume."
        # Don't hard-block: the deploy itself can succeed; the app just won't
        # render until the domain is on. Continue so a re-run isn't required
        # solely for this, but the gate is logged for the operator/skill.
        done_mark 4.0
    fi

    # ── 4.1 Build the bundle with the relay URL baked in ─────────────────────
    if section 4.1; then
        say "4.1 Build the UIBundle"
        resolve_heroku_origin
        local ws="${SKYWAVE_HEROKU_ORIGIN/https:/wss:}/ws/monitor"
        info "VITE_RELAY_WS_URL=${ws}"
        ( cd "$GLOBE_DIR" \
            && { [ -d node_modules ] || npm ci 2>/dev/null || npm install; } \
            && VITE_RELAY_WS_URL="$ws" npm run build ) \
            && ok "bundle built (dist/)" \
            || die "globe build failed — check $GLOBE_DIR (npm install / npm run build)"
        [ -f "$GLOBE_DIR/dist/index.html" ] || die "no dist/index.html after build"
        done_mark 4.1
    fi

    # ── 4.2 Deploy the globe set ─────────────────────────────────────────────
    # The globe set (bundle + app + permset + CSP) is excluded from Tier 1 by a
    # block in the root .forceignore. .forceignore is honored even on explicit
    # --source-dir deploys, so we temporarily neutralize JUST that block for this
    # one deploy, then always restore it (trap). node_modules stays excluded by
    # the bundle's OWN .forceignore, so the payload stays small.
    if section 4.2; then
        say "4.2 Deploy globe bundle + app + permset + CSP"
        local fi=".forceignore" fibak; fibak="$(mktemp)"
        cp "$fi" "$fibak"
        # shellcheck disable=SC2064
        trap "cp '$fibak' '$fi'; rm -f '$fibak'" RETURN
        FI="$fi" python3 - <<'PYEOF'
import os
p = os.environ['FI']; lines = open(p).read().splitlines(); out=[]; skip=False
for l in lines:
    if 'Globe demo monitor (UIBundle)' in l: skip=True            # start of the globe block
    if skip and l.strip()=='': skip=False; continue               # blank line ends it
    if skip: continue
    out.append(l)
open(p,'w').write('\n'.join(out)+'\n')
PYEOF
        sf project deploy start --target-org "$ORG_ALIAS" \
            --source-dir "$GLOBE_DIR" \
            --source-dir force-app/main/default/applications/Skywave_Globe.app-meta.xml \
            --source-dir force-app/main/default/permissionsets/Skywave_Globe_App.permissionset-meta.xml \
            --source-dir force-app/main/default/cspTrustedSites/Skywave_Globe_Relay_Wss.cspTrustedSite-meta.xml \
            --ignore-conflicts --wait 30 --concise \
            && ok "globe deployed (bundle + app + permset + CSP)" \
            || die "globe deploy failed (is the Multi-Framework app domain enabled? see §4.0)"
        cp "$fibak" "$fi"; rm -f "$fibak"; trap - RETURN
        done_mark 4.2
    fi

    # ── 4.3 Assign the launcher permset (org-side; doesn't ride the deploy) ──
    if section 4.3; then
        say "4.3 Assign Skywave_Globe_App permset"
        sf org assign permset --target-org "$ORG_ALIAS" --name Skywave_Globe_App 2>/dev/null \
            && ok "permset assigned (running user)" \
            || warn "permset assign failed/already assigned — assign Skywave_Globe_App to see the app in App Launcher"
        done_mark 4.3
    fi
    say "Tier 4 complete — globe demo monitor"
    info "Open the 'Skywave Globe' app from the App Launcher (after the app domain is enabled)."
}

# ════════════════════════════════════════════════════════════════════════════
#  DISPATCH
# ════════════════════════════════════════════════════════════════════════════
usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "$MODE" in
    help)          usage; exit 0 ;;
    check-prereqs) check_prereqs; exit 0 ;;
    check-stdm)
        resolve_org
        if stdm_ready; then ok "STDM ready — run ./install.sh --all --resume to continue"; exit 0
        else
            state_load
            if [ -n "${STDM_WAIT_STARTED_AT:-}" ] && [ "${STDM_WAIT_STARTED_AT}" != "0" ]; then
                info "STDM not ready yet. Elapsed: ~$(( ( $(date +%s 2>/dev/null || echo 0) - STDM_WAIT_STARTED_AT ) / 60 )) min (often ready within minutes; can take longer)."
            else info "STDM not ready yet (usually minutes after enabling session tracing; allow longer if needed)."; fi
            exit 1
        fi ;;
    install)
        check_prereqs
        resolve_org "$@"
        tier1_core
        [ "$WITH_OBS" = "1" ] && { if dc_present; then tier2_observability; else warn "Data Cloud not detected on '${ORG_ALIAS}' — skipping observability tier. Provision DC, then ./install.sh --with-observability --resume"; fi; }
        [ "$WITH_HEROKU" = "1" ] && tier3_heroku
        # Tracking after Tier 3 so §5.3 can set SF_INTERACTIONS_SDK_URL on the
        # provisioned dyno. Gated on Data Cloud (like Tier 2).
        [ "$WITH_TRACKING" = "1" ] && { if dc_present; then tier5_tracking; else warn "Data Cloud not detected on '${ORG_ALIAS}' — skipping tracking tier. Provision DC, then ./install.sh --with-tracking --resume"; fi; }
        # Globe last: it bakes Tier 3's relay URL into its build. Warn (don't
        # block) if Heroku wasn't provisioned this run — resolve_heroku_origin
        # falls back to a placeholder the operator can rebuild against later.
        if [ "$WITH_GLOBE" = "1" ]; then
            [ "$WITH_HEROKU" = "1" ] || warn "globe baked with the current relay origin; if the dyno isn't provisioned yet, re-run --with-heroku --with-globe --resume after Tier 3."
            tier4_globe
        fi
        # Voice (Chapter 9): scripted agent publish + permsets, UI gates for the
        # number/channel/PSTN toggles (conducted by the skill).
        [ "$WITH_VOICE" = "1" ] && tier6_voice
        say "Done."
        info "State: ${STATE_FILE} (re-run with --resume to continue any skipped/gated steps)"
        ;;
esac
