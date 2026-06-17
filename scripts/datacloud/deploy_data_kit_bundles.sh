#!/usr/bin/env bash
# Instantiate the SDO_Agentforce_Observability data-kit bundles
# (SDO_AFO_STDM / SDO_AFO_Optimization / SDO_AFO_Extra) into live Data Cloud data
# streams — programmatically, via the SSOT REST API. This is the exact contract the
# Q-Branch QBrix used (qx-framework QbrixCustomDataKitDeploy.synchronous_data_bundle_deploy):
#   POST /ssot/data-kits/{kit}?asyncMode=true&dataspace=default
#     {"components":[{"type":"DataStreamBundle","config":{"connectorType":"CRM",
#       "bundleName":"<bundle>","forceNoRefresh":true,"bundleConfig":{"orgId":"<id>"}}}]}
#   → {"jobId":...}; poll BackgroundOperation until Complete.
# The data360 MCP's d360_datakit_deploy CANNOT express this (DMO-level only), so we
# call the API directly with the client_credentials token from .secrets/dc.env.
#
# PRECONDITION: a Data Cloud connection of connector type CRM/SalesforceCRM keyed by
# the org id must exist, or each job fails "No CRM Connection exists for
# externalRecordId: <orgId>". (Standard on QBrix target orgs; on a bare SDO you may
# need to connect the Salesforce CRM home connection in Data Cloud Setup first.)
#
# Usage: ORG_ALIAS=si2 ./scripts/datacloud/deploy_data_kit_bundles.sh
# Env:   DC_ENV (default .secrets/dc.env), KIT (default SDO_Agentforce_Observability),
#        BUNDLES (default the 3 AFO bundles), MAX_POLLS (default 30, 30s apart).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
ORG_ALIAS="${ORG_ALIAS:-si}"
DC_ENV="${DC_ENV:-.secrets/dc.env}"
KIT="${KIT:-SDO_Agentforce_Observability}"
API_VERSION="66.0"
MAX_POLLS="${MAX_POLLS:-30}"
read -r -a BUNDLES <<< "${BUNDLES:-SDO_AFO_STDM SDO_AFO_Optimization SDO_AFO_Extra}"

[ -f "$DC_ENV" ] || { echo "❌ $DC_ENV not found — populate the data360/Data Cloud client_credentials creds (see SECRETS.md)"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$DC_ENV"; set +a
: "${DC_LOGIN_URL:?}"; : "${DC_INSTANCE_URL:?}"; : "${DC_CONSUMER_KEY:?}"; : "${DC_CONSUMER_SECRET:?}"

ORG_ID="$(sf org display --target-org "$ORG_ALIAS" --json | jq -r '.result.id')"
TOKEN="$(curl -s -X POST "${DC_LOGIN_URL}/services/oauth2/token" \
    -d grant_type=client_credentials -d "client_id=${DC_CONSUMER_KEY}" -d "client_secret=${DC_CONSUMER_SECRET}" \
    | jq -r '.access_token // empty')"
[ -n "$TOKEN" ] || { echo "❌ client_credentials token request failed (check the run-as user + consumer secret on the Connected App)"; exit 1; }
INST="${DC_INSTANCE_URL%/}"

status_of() { # bundle -> prints status.code (empty if componentDetails empty / not deployed)
    curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
        "$INST/services/data/v${API_VERSION}/ssot/data-kits/${KIT}/components/$1/deployment-status" \
        | jq -r 'if (.componentDetails|length)>0 then (.status.code // "") else (.status.code // "") end' 2>/dev/null
}

deploy_one() {
    local bundle="$1" code resp jobid poll st
    code="$(status_of "$bundle")"
    if [ "$code" = "ACTIVE" ]; then echo "✅ $bundle already ACTIVE — skipping"; return 0; fi
    echo "🚀 deploying $bundle (current status: ${code:-none})"
    resp="$(curl -s -X POST "$INST/services/data/v${API_VERSION}/ssot/data-kits/${KIT}?asyncMode=true&dataspace=default" \
        -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" -H "Content-Type: application/json" \
        -d "{\"components\":[{\"type\":\"DataStreamBundle\",\"config\":{\"connectorType\":\"CRM\",\"bundleName\":\"${bundle}\",\"forceNoRefresh\":true,\"bundleConfig\":{\"orgId\":\"${ORG_ID}\"}}}]}")"
    jobid="$(echo "$resp" | jq -r '.jobId // empty')"
    [ -n "$jobid" ] || { echo "❌ no jobId for $bundle — response: $resp"; return 1; }
    echo "   jobId=$jobid — polling BackgroundOperation…"
    for poll in $(seq 1 "$MAX_POLLS"); do
        sleep 30
        st="$(sf data query --target-org "$ORG_ALIAS" --json -q "SELECT Status, Error FROM BackgroundOperation WHERE Id='${jobid}'" 2>/dev/null | jq -r '.result.records[0].Status // "?"')"
        echo "   poll $poll/$MAX_POLLS: $st"
        case "$st" in
            Complete) echo "✅ $bundle deployed"; return 0 ;;
            Error|Canceled)
                err="$(sf data query --target-org "$ORG_ALIAS" --json -q "SELECT Error FROM BackgroundOperation WHERE Id='${jobid}'" 2>/dev/null | jq -r '.result.records[0].Error // ""')"
                echo "❌ $bundle $st: $err"; return 1 ;;
        esac
    done
    echo "⏱️  $bundle still running after $MAX_POLLS polls (not failed — re-run to resume)"; return 1
}

rc=0
for b in "${BUNDLES[@]}"; do deploy_one "$b" || rc=1; done
exit $rc
