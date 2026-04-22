#!/bin/bash
# orgInit.sh — phase 1 of scratch-org setup.
#
# What this does:
#   - Recreates the skywave-scratch scratch org
#   - Creates the "skywave website" LWR Experience site
#   - Deploys all core metadata (Apex, LWC, objects, flows, agent bundle, CSPs,
#     queue + routing config, guest profile)
#   - Publishes + activates the Agentforce agent
#   - Flips the LWR site Network to Live and loads sample data
#
# What this does NOT do:
#   The Messaging Channel + Embedded Service Deployment must be created through
#   the Setup wizard — Salesforce doesn't expose a headless provisioning API for
#   the auto-generated ESW bootstrap site. After the wizard, run ./finalize.sh.

set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?): $BASH_COMMAND" >&2' ERR

export SF_SOURCE_MEMBER_POLLING_TIMEOUT=120

# Recreate scratch org.
sf org delete scratch --no-prompt --target-org skywave-scratch 2>/dev/null || true
sf org create scratch --definition-file config/project-scratch-def.json --alias skywave-scratch --duration-days 7 --set-default

ORG_INFO=$(sf org display --json)
ORG_ID=$(echo "$ORG_INFO" | jq -r '.result.id')
ADMIN_USERNAME=$(echo "$ORG_INFO" | jq -r '.result.username')
export ADMIN_USERNAME

ADMIN_USER_ID=$(sf data query --json -q "SELECT Id FROM User WHERE Username = '${ADMIN_USERNAME}'" | jq -r '.result.records[0].Id')
sf data update record -s User -i "$ADMIN_USER_ID" -v "UserPermissionsKnowledgeUser=true"

# Provision the agent user (username carries an appended GUID).
AGENT_USER=$(sf org create agent-user --first-name Skywave --last-name Agent --base-username "skywaveagent@${ORG_ID}.ext" --json | jq -r '.result.username')
export AGENT_USER

# Bootstrap the LWR Experience site. `sf community create` provisions the
# CustomSite + Network + SiteDotCom + standard Apex pages (CommunitiesLanding,
# etc.) that later metadata deploys depend on. Pure metadata deploys of
# ChatterNetwork-typed CustomSite/Network pairs fail in a fresh scratch org
# because the companion SiteDotCom doesn't exist yet.
echo "Creating LWR Experience site..."
# Note: Salesforce auto-appends "vforcesite" to the prefix in scratch orgs, so
# passing "skywave" here yields the final path /skywavevforcesite — still not
# bare /skywave, but the cleanest achievable via `sf community create`.
sf community create --name "skywave website" --template-name "Build Your Own (LWR)" --url-path-prefix "skywave" --json > /dev/null

echo "Waiting for site provisioning..."
for i in $(seq 1 30); do
    SITE_COUNT=$(sf data query --json -q "SELECT COUNT(Id) c FROM Site WHERE Name IN ('skywave_website', 'skywave_website1')" | jq -r '.result.records[0].c')
    if [ "$SITE_COUNT" = "2" ]; then
        echo "Site provisioned"
        break
    fi
    sleep 5
done

# ─── Phase 1: Core ──────────────────────────────────────────────────────────
sf project deploy start --manifest manifest/phase1-core.xml --ignore-conflicts

# ─── Phase 2: LWR site content + queues + guest profile ─────────────────────
sf project deploy start --manifest manifest/phase2-site.xml --ignore-conflicts

sf org assign permset --name Skywave_Agent_User --on-behalf-of "$AGENT_USER"

# Add the agent user to the routing queue (pre-req for the messaging channel
# wizard when it routes to a queue).
AGENT_USER_ID=$(sf data query --json -q "SELECT Id FROM User WHERE Username = '${AGENT_USER}'" | jq -r '.result.records[0].Id')
QUEUE_ID=$(sf data query --json -q "SELECT Id FROM Group WHERE DeveloperName = 'main_queue' AND Type = 'Queue'" | jq -r '.result.records[0].Id')
sf data create record -s GroupMember -v "GroupId=${QUEUE_ID} UserOrGroupId=${AGENT_USER_ID}" 2>/dev/null || true

# Assign the agent user to the default Omni-Channel presence configuration.
# Without this, enhanced Messaging for Web (v2) can't find an available routing
# target and the widget's SSE connection fails with HTTP 400.
PRESENCE_CONFIG_ID=$(sf data query --json -q "SELECT Id FROM PresenceUserConfig WHERE DeveloperName = 'default_presence_config'" | jq -r '.result.records[0].Id')
sf data create record -s PresenceUserConfigUser -v "PresenceUserConfigId=${PRESENCE_CONFIG_ID} UserId=${AGENT_USER_ID}" 2>/dev/null || true

# ─── Phase 3: Publish + activate the agent ──────────────────────────────────
sf agent publish authoring-bundle --api-name Skywave_Airlines_Agent --skip-retrieve --json > /dev/null

# Workaround: publish does not wire BotUser onto the generated Bot. Retrieve,
# inject <botUser>, and redeploy so BotDefinition.BotUserId is set before activate.
BOT_PATCH_DIR=$(mktemp -d)
trap 'rm -rf "$BOT_PATCH_DIR" 2>/dev/null || true' EXIT
sf project retrieve start --metadata "Bot:Skywave_Airlines_Agent" --target-metadata-dir "$BOT_PATCH_DIR" --unzip --json > /dev/null
BOT_FILE="$BOT_PATCH_DIR/unpackaged/unpackaged/bots/Skywave_Airlines_Agent.bot"
python3 -c "
import re, sys
p = '$BOT_FILE'
s = open(p).read()
if '<botUser>' not in s:
    s = re.sub(r'(<Bot [^>]*>)\s*\n', r'\1\n    <botUser>$AGENT_USER</botUser>\n', s, count=1)
    open(p, 'w').write(s)
"
sf project deploy start --metadata-dir "$BOT_PATCH_DIR/unpackaged/unpackaged" --ignore-conflicts --json > /dev/null

sf agent activate --api-name Skywave_Airlines_Agent --json > /dev/null

# Publish the LWR site so the customer-facing content goes live.
sf community publish --name "skywave website" --json > /dev/null || true

# Activate the Network: flip Status to Live so guest access works.
# (Publishing pushes draft content but doesn't toggle the admin "Live" flag.)
# The update races with the async publish job — retry briefly until the
# record is no longer locked.
net_id=$(sf data query --json -q "SELECT Id FROM Network WHERE Name = 'skywave website'" | jq -r '.result.records[0].Id')
for i in $(seq 1 10); do
    if sf data update record -s Network -i "$net_id" -v "Status=Live" 2>/dev/null | grep -q Success; then
        echo "Network activated"
        break
    fi
    sleep 5
done

sf org assign permset --name Demo
sf apex run --file scripts/apex/createSampleData.apex

# Compute the public LWR site URL so the banner can show it.
ORG_HOST=$(echo "$ORG_INFO" | jq -r '.result.instanceUrl' | sed -E 's|https?://||; s|/.*||')
SITE_HOST="${ORG_HOST/.my.salesforce.com/.my.site.com}"
SITE_HOST="${SITE_HOST/.my.pc-rnd.salesforce.com/.my.pc-rnd.site.com}"
SITE_HOST="${SITE_HOST/.sandbox.my.salesforce.com/.sandbox.my.site.com}"
LWR_SITE_URL="https://${SITE_HOST}/skywavevforcesite"
TRUSTED_ORIGIN="${SITE_HOST}"

cat <<BANNER

────────────────────────────────────────────────────────────────────
  orgInit.sh complete. Manual step before running finalize.sh:

  In the opened Setup tab:
    1. Click "New Channel"
    2. Channel type: "Messaging for In-App and Web"
    3. Choose any API name you like
    4. Route to queue: main_queue
    5. Session handler: Agentforce agent "Skywave_Airlines_Agent"
    6. Save, then Activate the channel.
    7. Setup → Embedded Service Deployments → New Deployment →
       Messaging for In-App/Web, pick the channel, Save.
    8. In the deployment, add this URL to the Trusted Domains list:

         ${TRUSTED_ORIGIN}

    9. ⚠ REQUIRED: Switch the deployment to Enhanced v2.
       (Open the deployment → "Enable Enhanced v2" / "Upgrade to v2".
       Without this, the widget won't connect to the agent.)

  LWR site URL (hit this after finalize.sh to see the widget):
    ${LWR_SITE_URL}

  Then run: ./finalize.sh
────────────────────────────────────────────────────────────────────

BANNER

sf org open --path /lightning/setup/LiveMessageSetup/home
