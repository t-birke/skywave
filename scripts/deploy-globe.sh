#!/usr/bin/env bash
# ============================================================================
# deploy-globe.sh — SINGLE SOURCE OF TRUTH for (re)building + deploying the
# Skywave 3D globe UIBundle (force-app/main/default/uiBundles/SkywaveGlobe) to
# the SDO. Use this for ANY globe change; install.sh Tier 4 delegates to it, so
# the two never drift.
#
# WHY A DEDICATED SCRIPT: the globe is a BUILT artifact. `npm run build` bakes
# two org-specific origins into the JS, and neither is committed:
#   • VITE_RELAY_WS_URL      — the live-feed relay WebSocket
#   • VITE_CONSUMER_SITE_URL — the origin the join-QR encodes (CORS-gated!)
# A plain `npm run build` (no env) SILENTLY drops both → the live feed dies and
# the QR points phones at the wrong origin (CORS 403 → survey re-runs, identity
# splits). And the deploy itself needs a .forceignore dance (the globe set is
# excluded from Tier 1's blanket deploy). This script encapsulates all of that.
#
# USAGE:
#   scripts/deploy-globe.sh              # resolve origins → build → deploy → assign
#   scripts/deploy-globe.sh build        # resolve origins → build only
#   scripts/deploy-globe.sh deploy       # deploy the already-built dist only
#   scripts/deploy-globe.sh --help
#
# ORIGIN RESOLUTION (highest priority wins; the chosen values are cached to the
# install state file so a later run needs neither Heroku nor manual env):
#   1. explicit env      VITE_RELAY_WS_URL / VITE_CONSUMER_SITE_URL
#   2. live Heroku       `heroku apps:info` web_url + `SKYWAVE_PUBLIC_ORIGIN`
#                        config on HEROKU_APP (authoritative; also refreshes the
#                        cache — the relay host CHANGES on an org/dyno refresh)
#   3. cached state      VITE_* from .deploy-tmp/install-state.env (warns: may be
#                        stale after a refresh — verify if the org was recreated)
#   4. derive consumer   from the relay host (wss→https) if still unset — matches
#                        consumerSite.ts's own fallback; warns (custom domain lost)
# If the relay URL can't be resolved at all, the script errors with guidance.
#
# CONFIG (override via env): ORG_ALIAS (default si), HEROKU_APP (default from the
# state file, else skywave-app).
# ============================================================================
set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?): $BASH_COMMAND" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GLOBE_DIR="force-app/main/default/uiBundles/SkywaveGlobe"
STATE_DIR="${REPO_ROOT}/.deploy-tmp"
STATE_FILE="${STATE_DIR}/install-state.env"
ORG_ALIAS="${ORG_ALIAS:-si}"

# ─── Tiny helpers (mirror install.sh) ───────────────────────────────────────
say()  { printf '\n\033[1m─── %s ───\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  \033[33m⚠ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$STATE_DIR"
[ -f "$STATE_FILE" ] || : > "$STATE_FILE"
# shellcheck disable=SC1090
state_load() { set -a; . "$STATE_FILE"; set +a; }
state_set()  { # upsert KEY=value into the state file (same format as install.sh)
    local k="$1" v="$2"
    grep -q "^${k}=" "$STATE_FILE" 2>/dev/null \
        && { grep -v "^${k}=" "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"; }
    printf '%s=%q\n' "$k" "$v" >> "$STATE_FILE"
}

# Resolve VITE_RELAY_WS_URL + VITE_CONSUMER_SITE_URL into the environment, by the
# priority documented in the header, and cache them to the state file.
resolve_origins() {
    # 1. Capture explicit caller-provided env FIRST — state_load sources the
    #    state file with `set -a`, which would otherwise clobber these with the
    #    cached values (breaking "explicit env wins").
    local relay="${VITE_RELAY_WS_URL:-}" consumer="${VITE_CONSUMER_SITE_URL:-}" src="env"
    local app_env="${HEROKU_APP:-}"
    state_load
    HEROKU_APP="${app_env:-${HEROKU_APP_STATE:-skywave-app}}"

    # 2. Live Heroku — authoritative; overrides the cache so a refreshed dyno's
    #    new host is picked up. Only when no explicit relay was passed.
    if [ -z "$relay" ] && command -v heroku >/dev/null 2>&1 && heroku auth:whoami >/dev/null 2>&1; then
        local web pub
        web="$(heroku apps:info -a "$HEROKU_APP" --json 2>/dev/null | jq -r '.app.web_url // empty' 2>/dev/null || true)"
        web="${web%/}"
        if [ -n "$web" ]; then
            relay="${web/https:/wss:}/ws/monitor"
            pub="$(heroku config:get SKYWAVE_PUBLIC_ORIGIN -a "$HEROKU_APP" 2>/dev/null || true)"
            pub="${pub%/}"
            consumer="${consumer:-${pub:-$web}}"   # don't override an explicit consumer
            src="heroku ($HEROKU_APP)"
            state_set HEROKU_APP_STATE "$HEROKU_APP"
        fi
    fi

    # 3. Cached state — last resort; may be stale after an org/dyno refresh.
    if [ -z "$relay" ] && [ -n "${VITE_RELAY_WS_URL:-}" ]; then
        relay="$VITE_RELAY_WS_URL"; consumer="${consumer:-${VITE_CONSUMER_SITE_URL:-}}"; src="cached state"
        warn "using CACHED origins ($STATE_FILE) — not verified against Heroku; if this org was refreshed, re-run with 'heroku login' or set VITE_RELAY_WS_URL/VITE_CONSUMER_SITE_URL."
    fi

    [ -n "$relay" ] || die "cannot resolve the relay origin. Either 'heroku login' (and set HEROKU_APP=$HEROKU_APP if the dyno is named differently) or pass VITE_RELAY_WS_URL='wss://<dyno>.herokuapp.com/ws/monitor' [VITE_CONSUMER_SITE_URL='https://<public-origin>']."

    # 4. Derive consumer from the relay host if still unset (consumerSite.ts does
    #    the same). A custom domain would be LOST here — hence the warning.
    if [ -z "$consumer" ]; then
        consumer="$(printf '%s' "$relay" | sed -E 's#^wss:#https:#; s#/ws/monitor$##')"
        warn "VITE_CONSUMER_SITE_URL not set — deriving the QR origin from the relay host ($consumer). If a custom domain (e.g. https://app.skywave.flights) fronts the site, pass VITE_CONSUMER_SITE_URL or the QR will 403."
    fi

    VITE_RELAY_WS_URL="$relay"; VITE_CONSUMER_SITE_URL="${consumer%/}"
    export VITE_RELAY_WS_URL VITE_CONSUMER_SITE_URL
    state_set VITE_RELAY_WS_URL "$VITE_RELAY_WS_URL"
    state_set VITE_CONSUMER_SITE_URL "$VITE_CONSUMER_SITE_URL"
    info "origin source : $src"
    info "VITE_RELAY_WS_URL      = $VITE_RELAY_WS_URL"
    info "VITE_CONSUMER_SITE_URL = $VITE_CONSUMER_SITE_URL"
}

do_build() {
    say "Build globe UIBundle"
    command -v node >/dev/null 2>&1 || die "node not installed (needed to build the globe UIBundle)"
    resolve_origins
    ( cd "$GLOBE_DIR" \
        && { [ -d node_modules ] || npm ci 2>/dev/null || npm install; } \
        && VITE_RELAY_WS_URL="$VITE_RELAY_WS_URL" VITE_CONSUMER_SITE_URL="$VITE_CONSUMER_SITE_URL" npm run build ) \
        || die "globe build failed — check $GLOBE_DIR (npm install / npm run build)"
    [ -f "$GLOBE_DIR/dist/index.html" ] || die "no dist/index.html after build"
    ok "bundle built (dist/)"
}

do_deploy() {
    say "Deploy globe set (bundle + app + icon + permset + CSP) → $ORG_ALIAS"
    [ -f "$GLOBE_DIR/dist/index.html" ] || die "no dist/index.html — run '$0 build' first (a plain build without baked origins is NOT valid)."

    # The globe set is excluded from Tier 1 by a block in the root .forceignore.
    # .forceignore is honored even on explicit --source-dir deploys, so we
    # temporarily neutralize JUST that block, then always restore it (trap fires
    # on RETURN and EXIT — a failed deploy calls exit, not return).
    local fi=".forceignore" fibak; fibak="$(mktemp)"
    cp "$fi" "$fibak"
    # shellcheck disable=SC2064
    trap "cp '$fibak' '$fi'; rm -f '$fibak'" RETURN EXIT
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
        --source-dir force-app/main/default/contentassets/Skywave_Globe_Icon.asset-meta.xml \
        --source-dir force-app/main/default/permissionsets/Skywave_Globe_App.permissionset-meta.xml \
        --source-dir force-app/main/default/cspTrustedSites/Skywave_Globe_Relay_Wss.cspTrustedSite-meta.xml \
        --ignore-conflicts --wait 30 --concise \
        || die "globe deploy failed — if it says 'Agentforce Vibe for MultiFramework feature gate is disabled', enable that feature in Setup (App Launcher › Agentforce Vibe), then retry."
    cp "$fibak" "$fi"; rm -f "$fibak"; trap - RETURN EXIT
    ok "globe deployed (bundle + app + icon + permset + CSP)"
}

do_assign() {
    say "Assign Skywave_Globe_App permset (running user)"
    sf org assign permset --target-org "$ORG_ALIAS" --name Skywave_Globe_App 2>/dev/null \
        && ok "permset assigned" \
        || warn "permset assign skipped (already assigned, or failed) — assign Skywave_Globe_App to see the app in App Launcher"
}

case "${1:-all}" in
    build)        do_build ;;
    deploy)       do_deploy ;;
    all|"")       do_build; do_deploy; do_assign
                  say "Done"
                  info "Open the 'Skywave Globe' app from the App Launcher on $ORG_ALIAS." ;;
    --help|-h)
        sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown arg '$1' (try: build | deploy | all | --help)" ;;
esac
