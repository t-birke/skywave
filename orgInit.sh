#!/bin/bash
# orgInit.sh — scripted scratch-org setup for Skywave Airlines + MIAW.
#
# Everything is automated except ONE click: "Publish" on the Embedded Service
# Deployment in Setup. Salesforce's public APIs don't expose a headless publish
# action today (confirmed internally — see PLATFORM_FEEDBACK.md #10). The script
# pauses for that click, then resumes automatically.
#
# Prior gotchas we removed by adopting the coral-cloud pattern:
#   - "New Channel" wizard click        — channel deployed as metadata, activated + wired via Apex
#   - "New Deployment" wizard click     — ESC created via Tooling API POST (scripts/createEmbeddedServiceConfig.sh)
#   - "Switch to Enhanced v2" click     — Tooling POST supports clientVersion=WebV2 on create
#   - ESW bootstrap site provisioning   — vendored as DigitalExperienceBundle in force-app

set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?): $BASH_COMMAND" >&2' ERR

ORG_ALIAS="${ORG_ALIAS:-skywave-scratch}"

echo "─── 1/12 Recreating scratch org: ${ORG_ALIAS} ───"
sf org delete scratch --no-prompt --target-org "$ORG_ALIAS" 2>/dev/null || true
sf org create scratch --definition-file config/project-scratch-def.json --alias "$ORG_ALIAS" --duration-days 7 --set-default

ORG_INFO=$(sf org display --json)
ORG_ID=$(echo "$ORG_INFO" | jq -r '.result.id')
ADMIN_USERNAME=$(echo "$ORG_INFO" | jq -r '.result.username')
export ADMIN_USERNAME

ADMIN_USER_ID=$(sf data query --json -q "SELECT Id FROM User WHERE Username = '${ADMIN_USERNAME}'" | jq -r '.result.records[0].Id')
sf data update record -s User -i "$ADMIN_USER_ID" -v "UserPermissionsKnowledgeUser=true"

echo "─── 2/12 Creating agent user ───"
AGENT_USER=$(sf org create agent-user --first-name Skywave --last-name Agent --base-username "skywaveagent@${ORG_ID}.ext" --json | jq -r '.result.username')
export AGENT_USER

echo "─── 3/12 Bootstrapping customer-facing LWR site (sf community create) ───"
# TODO: vendor skywave_website1 + its CustomSite/Network pair as source so this
# step can go away too (matches how coral-cloud handles its customer site).
sf community create --name "skywave website" --template-name "Build Your Own (LWR)" --url-path-prefix "skywave" --json > /dev/null
for i in $(seq 1 30); do
    SITE_COUNT=$(sf data query --json -q "SELECT COUNT(Id) c FROM Site WHERE Name IN ('skywave_website', 'skywave_website1')" | jq -r '.result.records[0].c')
    [ "$SITE_COUNT" = "2" ] && break
    sleep 5
done
echo "  customer site provisioned"

echo "─── 4/12 Deploying all metadata (pass 1, dummy routing IDs) ───"
# Single deploy: Apex/LWC/objects/flows/agent bundle, vendored ESW site bundle
# (DigitalExperienceBundle + CustomSite + Network + SNA static resource), CSP
# wildcards, CORS, CommunitiesLanding.page, MessagingChannel, queues,
# guest profile. Skywave_Route_to_Agent routing flow uses %%…%% placeholders
# that sfdx-project.json `replaceWithEnv` substitutes from these env vars.
# Pass 1 uses dummies because BotDefinition.Id doesn't exist yet; pass 2
# redeploys the flow once the real values are in hand (see step 7).
export SF_SKYWAVE_FLOW_AGENT_ID="DummyForInitialDeploy"
export SF_SKYWAVE_FLOW_CHANNEL_ID="DummyForInitialDeploy"
export SF_SKYWAVE_FLOW_QUEUE_ID="DummyForInitialDeploy"

# ESA_Deployment.site-meta.xml needs the scratch host baked into its
# siteIframeWhiteListUrls. Without these the iframe's CSP frame-ancestors lacks
# the subdomain wildcard and the widget's postMessage handshake fails silently,
# leaving no button on the page. (Matched by comparing vendored vs wizard ESW
# site CSP headers on pc-rnd.)
ORG_HOST_LOC=$(echo "$ORG_INFO" | jq -r '.result.instanceUrl' | sed -E 's|https?://||; s|/.*||')
# Site + VF host derivations cover multiple org URL shapes:
#   prod scratch:   innovation-dream-1827-dev-ed.scratch.my.salesforce.com
#                 → innovation-dream-1827-dev-ed.scratch.my.site.com
#                 → innovation-dream-1827-dev-ed--c.scratch.vf.force.com
#   pc-rnd scratch: butterpecan-orion-5791-dev-ed.test2.my.pc-rnd.salesforce.com
#                 → butterpecan-orion-5791-dev-ed.test2.my.pc-rnd.site.com
#                 → butterpecan-orion-5791-dev-ed--c.test2.vf.pc-rnd.force.com
VF_AND_SITE=$(python3 <<PYEOF
import re
h = '$ORG_HOST_LOC'
# Shape 1: prefix.cluster.my.region.salesforce.com   (pc-rnd, sandbox, etc.)
m = re.match(r'([^.]+)\.([^.]+)\.my\.(.+)\.salesforce\.com$', h)
if m:
    prefix, cluster, region = m.groups()
    print(f"{prefix}.{cluster}.my.{region}.site.com")
    print(f"{prefix}--c.{cluster}.vf.{region}.force.com")
else:
    # Shape 2: prefix.cluster.my.salesforce.com        (prod scratch)
    m = re.match(r'([^.]+)\.([^.]+)\.my\.salesforce\.com$', h)
    if m:
        prefix, cluster = m.groups()
        print(f"{prefix}.{cluster}.my.site.com")
        print(f"{prefix}--c.{cluster}.vf.force.com")
    else:
        # Shape 3: prefix.my.salesforce.com
        m = re.match(r'([^.]+)\.my\.salesforce\.com$', h)
        if m:
            print(f"{m.group(1)}.my.site.com")
            print(f"{m.group(1)}--c.vf.force.com")
        else:
            print("")
            print("")
PYEOF
)
export SCRATCH_ORG_SITE_HOST=$(echo "$VF_AND_SITE" | sed -n '1p')
export SCRATCH_ORG_VF_HOST=$(echo "$VF_AND_SITE" | sed -n '2p')
echo "  SCRATCH_ORG_SITE_HOST=$SCRATCH_ORG_SITE_HOST"
echo "  SCRATCH_ORG_VF_HOST=$SCRATCH_ORG_VF_HOST"

sf project deploy start --source-dir force-app --ignore-conflicts --wait 30 --concise

echo "─── 5/12 Assigning permsets, queue, presence ───"
sf org assign permset --name Skywave_Agent_User --on-behalf-of "$AGENT_USER"
AGENT_USER_ID=$(sf data query --json -q "SELECT Id FROM User WHERE Username = '${AGENT_USER}'" | jq -r '.result.records[0].Id')
QUEUE_ID=$(sf data query --json -q "SELECT Id FROM Group WHERE DeveloperName = 'main_queue' AND Type = 'Queue'" | jq -r '.result.records[0].Id')
sf data create record -s GroupMember -v "GroupId=${QUEUE_ID} UserOrGroupId=${AGENT_USER_ID}" 2>/dev/null || true
PRESENCE_CONFIG_ID=$(sf data query --json -q "SELECT Id FROM PresenceUserConfig WHERE DeveloperName = 'default_presence_config'" | jq -r '.result.records[0].Id')
sf data create record -s PresenceUserConfigUser -v "PresenceUserConfigId=${PRESENCE_CONFIG_ID} UserId=${AGENT_USER_ID}" 2>/dev/null || true

echo "─── 6/12 Publishing + activating agent ───"
sf agent publish authoring-bundle --api-name Skywave_Airlines_Agent --skip-retrieve --json > /dev/null

# Workaround: `sf agent publish` leaves BotDefinition.BotUserId null. Patch
# the Bot metadata with <botUser>, redeploy, then activate. See PLATFORM_FEEDBACK.md #1.
BOT_PATCH_DIR=$(mktemp -d)
trap 'rm -rf "$BOT_PATCH_DIR" 2>/dev/null || true' EXIT
sf project retrieve start --metadata "Bot:Skywave_Airlines_Agent" --target-metadata-dir "$BOT_PATCH_DIR" --unzip --json > /dev/null
BOT_FILE="$BOT_PATCH_DIR/unpackaged/unpackaged/bots/Skywave_Airlines_Agent.bot"
python3 -c "
import re
p = '$BOT_FILE'
s = open(p).read()
if '<botUser>' not in s:
    s = re.sub(r'(<Bot [^>]*>)\s*\n', r'\1\n    <botUser>$AGENT_USER</botUser>\n', s, count=1)
    open(p, 'w').write(s)
"
sf project deploy start --metadata-dir "$BOT_PATCH_DIR/unpackaged/unpackaged" --ignore-conflicts --json > /dev/null
sf agent activate --api-name Skywave_Airlines_Agent --json > /dev/null

echo "─── 7/12 Redeploying routing flow with real IDs (pass 2) ───"
SF_SKYWAVE_FLOW_AGENT_ID=$(sf data query --json -q "SELECT Id FROM BotDefinition WHERE DeveloperName='Skywave_Airlines_Agent'" | jq -r '.result.records[0].Id')
SF_SKYWAVE_FLOW_CHANNEL_ID=$(sf data query --json -q "SELECT Id FROM ServiceChannel WHERE DeveloperName='sfdc_livemessage'" | jq -r '.result.records[0].Id')
SF_SKYWAVE_FLOW_QUEUE_ID="$QUEUE_ID"
export SF_SKYWAVE_FLOW_AGENT_ID SF_SKYWAVE_FLOW_CHANNEL_ID SF_SKYWAVE_FLOW_QUEUE_ID
echo "  agent=$SF_SKYWAVE_FLOW_AGENT_ID  channel=$SF_SKYWAVE_FLOW_CHANNEL_ID  queue=$SF_SKYWAVE_FLOW_QUEUE_ID"
sf project deploy start --source-dir force-app/main/default/flows/Skywave_Route_to_Agent.flow-meta.xml --ignore-conflicts --wait 10 --concise

echo "─── 7b/12 Activating MessagingChannel ───"
sf apex run --file scripts/apex/activateMessagingChannel.apex

echo "─── 8/12 Publishing ESW bootstrap site ───"
sf community publish --name "ESA_Deployment" --json > /dev/null || true
# ESA_Deployment Network defaults to Live on create; nothing else needed.

echo "─── 9/12 Creating EmbeddedServiceConfig via Tooling API (v2/Enhanced) ───"
./scripts/createEmbeddedServiceConfig.sh

echo "─── 10/12 Publishing customer LWR site + sample data ───"
sf community publish --name "skywave website" --json > /dev/null || true
net_id=$(sf data query --json -q "SELECT Id FROM Network WHERE Name = 'skywave website'" | jq -r '.result.records[0].Id')
for i in $(seq 1 10); do
    result=$(sf data update record -s Network -i "$net_id" -v "Status=Live" 2>/dev/null || true)
    case "$result" in
        *Success*) break ;;
    esac
    sleep 5
done
sf org assign permset --name Demo
sf apex run --file scripts/apex/createSampleData.apex

# ─── ONE manual step remains ────────────────────────────────────────────────
ORG_HOST=$(echo "$ORG_INFO" | jq -r '.result.instanceUrl' | sed -E 's|https?://||; s|/.*||')
SITE_HOST="${ORG_HOST/.my.salesforce.com/.my.site.com}"
SITE_HOST="${SITE_HOST/.my.pc-rnd.salesforce.com/.my.pc-rnd.site.com}"
SITE_HOST="${SITE_HOST/.sandbox.my.salesforce.com/.sandbox.my.site.com}"
SCRT2_HOST="${ORG_HOST/salesforce.com/salesforce-scrt.com}"
SCRT2_URL="https://${SCRT2_HOST}"
SITE_URL="https://${SITE_HOST}/skywavevforcesite"
ORG_ID_15="${ORG_ID:0:15}"
# Deep-link straight to the deployment record page (the .salesforce-setup.com
# host is the Setup-only subdomain which loads faster than /lightning/setup/…).
ESC_ID=$(sf data query --use-tooling-api --json -q "SELECT Id FROM EmbeddedServiceConfig WHERE DeveloperName='Skywave_MIAW_Deployment'" | jq -r '.result.records[0].Id')
SETUP_HOST="${ORG_HOST/.my.salesforce.com/.my.salesforce-setup.com}"
SETUP_HOST="${SETUP_HOST/.my.pc-rnd.salesforce.com/.my.pc-rnd.salesforce-setup.com}"
SETUP_HOST="${SETUP_HOST/.sandbox.my.salesforce.com/.sandbox.my.salesforce-setup.com}"
DEPLOY_URL="https://${SETUP_HOST}/lightning/setup/EmbeddedServiceDeployments/${ESC_ID}/view"

echo "─── 10b/12 Publishing ESD (headless browser click) ───"
# Salesforce doesn't expose a public API for the Publish button on an Embedded
# Service Deployment (confirmed internally — see PLATFORM_FEEDBACK.md #10), so
# we drive a real Chromium via Playwright. One click, zero user interaction.
#
# If Playwright isn't installed (npm install was skipped) we fall back to
# prompting the user to click manually.
if [ -x node_modules/.bin/playwright ] || node -e "require('playwright')" 2>/dev/null; then
    node scripts/publishEmbeddedServiceDeployment.mjs \
        --target-org "$ORG_ALIAS" \
        --deployment-name Skywave_MIAW_Deployment
else
    cat <<BANNER

════════════════════════════════════════════════════════════════════
  Playwright isn't installed. Click Publish manually:

    ${DEPLOY_URL}

  Then press Enter to continue. (To skip this prompt in future runs,
  run: npm install && npx playwright install chromium)
════════════════════════════════════════════════════════════════════

BANNER
    sf org open --path "/lightning/setup/EmbeddedServiceDeployments/${ESC_ID}/view" > /dev/null 2>&1 || \
        sf org open --path "/lightning/setup/EmbeddedServiceDeployments/home" > /dev/null || true
    read -r -p "Press Enter after clicking Publish..." _
fi

echo "─── 11/12 Fetching published config + baking LWC ───"
# The scrt2 config endpoint is authoritative for the bootstrap siteUrl (the
# ESW CustomSite's UrlPathPrefix isn't the path the widget uses — scrt2 serves
# its own canonical URL after Publish).
ESW_SITE_URL=$(curl -s "${SCRT2_URL}/embeddedservice/v1/embedded-service-config?orgId=${ORG_ID_15}&esConfigName=Skywave_MIAW_Deployment&language=en_US" \
    | jq -r '.embeddedServiceConfig.siteUrl // ""')
if [ -z "$ESW_SITE_URL" ]; then
    echo "ERROR: scrt2 config endpoint did not return a siteUrl — did you click Publish?" >&2
    exit 1
fi
echo "  siteUrl (from scrt2): $ESW_SITE_URL"
REDEPLOY_DIR=$(mktemp -d)
trap 'rm -rf "$REDEPLOY_DIR" "$BOT_PATCH_DIR" 2>/dev/null || true' EXIT
mkdir -p "$REDEPLOY_DIR/lwc/skywaveAirlinesHome"
cp -r force-app/main/default/lwc/skywaveAirlinesHome/* "$REDEPLOY_DIR/lwc/skywaveAirlinesHome/"
LWC_JS="$REDEPLOY_DIR/lwc/skywaveAirlinesHome/skywaveAirlinesHome.js"
python3 - <<PYEOF
p = '$LWC_JS'
s = open(p).read()
s = s.replace('__ESW_ORG_ID__', '$ORG_ID_15')
s = s.replace('__ESW_ESC_NAME__', 'Skywave_MIAW_Deployment')
s = s.replace('__ESW_SITE_URL__', '$ESW_SITE_URL')
s = s.replace('__ESW_SCRT2_URL__', '$SCRT2_URL')
open(p, 'w').write(s)
PYEOF
cat > "$REDEPLOY_DIR/package.xml" <<PKG_EOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types><members>skywaveAirlinesHome</members><name>LightningComponentBundle</name></types>
    <version>66.0</version>
</Package>
PKG_EOF

# Retry loop: can race against the async site publish above on ORG_ADMIN_LOCKED.
for attempt in 1 2 3 4 5 6; do
    deploy_out=$(sf project deploy start --metadata-dir "$REDEPLOY_DIR" --ignore-conflicts --json 2>&1 || true)
    deploy_status=$(echo "$deploy_out" | jq -r '.result.status // "unknown"' 2>/dev/null || echo unknown)
    [ "$deploy_status" = "Succeeded" ] && { echo "  ✓ LWC deployed"; break; }
    err=$(echo "$deploy_out" | jq -r '.result.errorMessage // .message // ""' 2>/dev/null || echo "")
    case "$err" in
        *ORG_ADMIN_LOCKED*) sleep 15 ;;
        *) echo "ERROR deploying LWC: $err"; [ $attempt -eq 6 ] && exit 1 ;;
    esac
done

echo "─── 12/12 Republishing LWR site so it picks up the baked LWC ───"
sf community publish --name "skywave website" --json > /dev/null 2>&1 || true

echo "─── 12b/12 Enabling guest (public) access on the LWR site ───"
# `sf community publish` resets enableGuestFileAccess=false, so this has to
# run AFTER the final publish. Without it, anonymous visitors see the login
# page instead of the homepage.
NET_RETR=$(mktemp -d)
trap 'rm -rf "$REDEPLOY_DIR" "$BOT_PATCH_DIR" "$NET_RETR" 2>/dev/null || true' EXIT
cat > "$NET_RETR/pkg.xml" <<PKG_EOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types><members>skywave website</members><name>Network</name></types>
    <version>66.0</version>
</Package>
PKG_EOF
sf project retrieve start --manifest "$NET_RETR/pkg.xml" --target-metadata-dir "$NET_RETR/out" --unzip --json > /dev/null
NET_FILE="$NET_RETR/out/unpackaged/unpackaged/networks/skywave website.network"
if [ -f "$NET_FILE" ]; then
    sed -i '' 's|<enableGuestFileAccess>false</enableGuestFileAccess>|<enableGuestFileAccess>true</enableGuestFileAccess>|' "$NET_FILE"
    sf project deploy start --metadata-dir "$NET_RETR/out/unpackaged/unpackaged" --ignore-conflicts --json > /dev/null \
        && echo "  ✓ guest access enabled" \
        || echo "  ⚠ guest-access flip failed — enable manually in Experience Builder > Settings > General"
else
    echo "  ⚠ Network metadata not retrieved — enable guest access manually in Experience Builder > Settings > General"
fi

# Warm up the site's CDN by issuing an authenticated server-side render.
# Without this, anonymous visitors see the login screen until the first
# authenticated request passes through — which is why users who ran
# `sf org open` once before testing always saw the site working, but a
# fresh incognito/anonymous visit would fail. Triggers the same CDN-state
# refresh that frontdoor.jsp would. Non-fatal on failure.
curl -sL -o /dev/null -b "/tmp/skywave-warm-${ORG_ID}.jar" -c "/tmp/skywave-warm-${ORG_ID}.jar" \
    "${ORG_INFO_URL:-$(echo "$ORG_INFO" | jq -r '.result.instanceUrl')}/secur/frontdoor.jsp?sid=$(echo "$ORG_INFO" | jq -r '.result.accessToken')&retURL=%2Fskywavevforcesite%2F" \
    2>/dev/null \
    && echo "  ✓ CDN warmed for guest access" \
    || echo "  ⚠ CDN warm-up failed — first guest visit may see login screen until it propagates"
rm -f "/tmp/skywave-warm-${ORG_ID}.jar"

cat <<BANNER

────────────────────────────────────────────────────────────────────
  Complete.

  Customer site:  ${SITE_URL}

  Hard-refresh the URL (Cmd+Shift+R) to clear LWR bundle cache. The
  messaging widget should render bottom-right and route to the
  Skywave_Airlines_Agent.
────────────────────────────────────────────────────────────────────
BANNER
