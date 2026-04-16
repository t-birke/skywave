#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Skywave Airlines — Scratch Org Init Script                                ║
# ║                                                                            ║
# ║  INCREMENTAL VALIDATION:                                                   ║
# ║  Each phase below is commented out until validated by running the script    ║
# ║  and confirming the step works. Do NOT uncomment the next phase until the   ║
# ║  current one is confirmed working. This is intentional — many of these      ║
# ║  commands have never been run end-to-end successfully.                      ║
# ║                                                                            ║
# ║  DEPENDENCY CHAIN:                                                         ║
# ║  Phase 1  → Core metadata (agent authoring bundle, classes, flows, etc.)   ║
# ║  Phase 1b → Org-specific value updates (sed + git checkout restore)        ║
# ║  Phase 2  → Einstein Agent User + sf agent publish/activate                ║
# ║  Phase 3  → Agent-dependent metadata (messagingChannels, EmbeddedService)  ║
# ║  Phase 4  → Experience Site publish, messaging channel activate            ║
# ║                                                                            ║
# ║  .forceignore RELATIONSHIP:                                                ║
# ║  - bots/ and genAiPlannerBundles/ are PERMANENTLY ignored (runtime         ║
# ║    artifacts created by sf agent publish, never manually deployed)          ║
# ║  - messagingChannels/ and EmbeddedServiceConfig/ are ignored during        ║
# ║    Phase 1 but temporarily un-ignored by Phase 3 for targeted deploy       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -euo pipefail

AGENT_API_NAME="Skywave_Airlines_Agent"
SCRATCH_ALIAS="skywave-scratch"

# ── Phase 0: Create Scratch Org ── (VALIDATED)
sf org delete scratch --no-prompt --target-org "$SCRATCH_ALIAS" 2>/dev/null || true
sf org create scratch --definition-file config/project-scratch-def.json --alias "$SCRATCH_ALIAS" --duration-days 7 --set-default

# ── Phase 1b: Org Info + Org-Specific Value Updates ── (VALIDATED)
# Several source files contain org-specific values (org ID, domain URLs, admin email)
# that change with each new scratch org. Gather info, sed update, deploy, restore on exit.

AGENT_FILE="force-app/main/default/aiAuthoringBundles/${AGENT_API_NAME}/${AGENT_API_NAME}.agent"
BUNDLE_META="force-app/main/default/aiAuthoringBundles/${AGENT_API_NAME}/${AGENT_API_NAME}.bundle-meta.xml"
VF_PAGE="force-app/main/default/pages/SkyWaveAirlines.page"
NETWORK_FILE="force-app/main/default/networks/ESW_Skywave_MIAW.network-meta.xml"
SITE_FILE="force-app/main/default/sites/ESW_Skywave_MIAW.site-meta.xml"

# Restore all sed-modified files on exit (success or failure)
cleanup() {
  git checkout -- "$AGENT_FILE" "$BUNDLE_META" "$VF_PAGE" "$NETWORK_FILE" "$SITE_FILE" .forceignore 2>/dev/null
}
trap cleanup EXIT

# Gather org info
ORG_ID=$(sf org display --json | jq -r '.result.id')
ADMIN_USERNAME=$(sf org display --json | jq -r '.result.username')
INSTANCE_URL=$(sf org display --json | jq -r '.result.instanceUrl')
DOMAIN=$(echo "$INSTANCE_URL" | sed 's|https://||; s|\.my\.salesforce\.com||')
SITE_BASE="https://${DOMAIN}.my.site.com"
SCRT2_URL="https://${DOMAIN}.my.salesforce-scrt.com"

echo "Org ID:    $ORG_ID"
echo "Admin:     $ADMIN_USERNAME"
echo "Domain:    $DOMAIN"
echo "Site Base: $SITE_BASE"
echo "SCRT2:     $SCRT2_URL"

# bundle-meta.xml: remove <target> line (fresh org has no published version)
sed -i '' '/<target>/d' "$BUNDLE_META"

# .agent: update default_agent_user with new org ID
sed -i '' "s|default_agent_user: \"einsteinagent@.*\"|default_agent_user: \"einsteinagent@${ORG_ID}.ext\"|" "$AGENT_FILE"

# Network: update emailSenderAddress
sed -i '' "s|<emailSenderAddress>[^<]*</emailSenderAddress>|<emailSenderAddress>${ADMIN_USERNAME}</emailSenderAddress>|" "$NETWORK_FILE"

# Site: update siteAdmin + siteGuestRecordDefaultOwner
sed -i '' "s|<siteAdmin>[^<]*</siteAdmin>|<siteAdmin>${ADMIN_USERNAME}</siteAdmin>|" "$SITE_FILE"
sed -i '' "s|<siteGuestRecordDefaultOwner>[^<]*</siteGuestRecordDefaultOwner>|<siteGuestRecordDefaultOwner>${ADMIN_USERNAME}</siteGuestRecordDefaultOwner>|" "$SITE_FILE"

# VF Page: update MIAW bootstrap snippet (org ID, site URL, SCRT2 URL)
sed -i '' "s|'[A-Za-z0-9]\{18\}',|'${ORG_ID}',|" "$VF_PAGE"
sed -i '' "s|'https://[^']*\.my\.site\.com/[^']*'|'${SITE_BASE}/ESWSkywaveMIAW'|g" "$VF_PAGE"
sed -i '' "s|scrt2URL: 'https://[^']*\.my\.salesforce-scrt\.com'|scrt2URL: '${SCRT2_URL}'|" "$VF_PAGE"
sed -i '' "s|src=\"https://[^\"]*\.my\.site\.com/[^\"]*/assets/js/bootstrap.min.js\"|src=\"${SITE_BASE}/ESWSkywaveMIAW/assets/js/bootstrap.min.js\"|" "$VF_PAGE"

# Enable Knowledge for admin user
ADMIN_USER_ID=$(sf data query -q "SELECT Id FROM User WHERE Username = '${ADMIN_USERNAME}'" --json | jq -r '.result.records[0].Id')
sf data update record -s User -i "$ADMIN_USER_ID" -v "UserPermissionsKnowledgeUser=true"

# ── Phase 1: Deploy Core Metadata ── (VALIDATED)
# .forceignore blocks: bots, genAiPlannerBundles, messagingChannels, EmbeddedServiceConfig
sf project deploy start --ignore-conflicts
sf org assign permset --name Demo
sf apex run --file scripts/apex/createSampleData.apex

# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ PHASE 2: Einstein Agent User + Agent Publish/Activate                       │
# │ STATUS: NOT YET VALIDATED                                                   │
# │                                                                             │
# │ Creates the Einstein Agent User, assigns required permsets, then publishes  │
# │ and activates the agent. This creates the Bot + PlannerId that Phase 3      │
# │ metadata depends on.                                                        │
# │                                                                             │
# │ REQUIRES: Phase 1 + 1b completed successfully (both VALIDATED).             │
# └──────────────────────────────────────────────────────────────────────────────┘

# # Create Einstein Agent User
# PROFILE_ID=$(sf data query -q "SELECT Id FROM Profile WHERE Name = 'Einstein Agent User'" --json | jq -r '.result.records[0].Id')
# sf data create record -s User -v "Username='einsteinagent@${ORG_ID}.ext' Email='einsteinagent@example.com' Alias='einagent' LastName='Einstein Agent' TimeZoneSidKey='America/Los_Angeles' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' ProfileId='${PROFILE_ID}' LanguageLocaleKey='en_US'"

# # Assign permsets to agent user (AgentforceServiceAgentUser MUST be assigned before publish)
# sf org assign permset --name AgentforceServiceAgentUser --on-behalf-of "einsteinagent@${ORG_ID}.ext"
# sf org assign permset --name Skywave_Agent_User --on-behalf-of "einsteinagent@${ORG_ID}.ext"

# # Publish and activate agent
# echo "Publishing agent..."
# sf agent publish authoring-bundle --json --api-name "$AGENT_API_NAME"
# echo "Activating agent..."
# sf agent activate --json --api-name "$AGENT_API_NAME"

# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ PHASE 3: Deploy Agent-Dependent Metadata                                    │
# │ STATUS: NOT YET VALIDATED                                                   │
# │                                                                             │
# │ messagingChannels needs the Bot created by Phase 2.                         │
# │ EmbeddedServiceConfig needs the MessagingChannel.                           │
# │                                                                             │
# │ We temporarily remove these from .forceignore so --source-dir can find      │
# │ them. The trap in Phase 1b restores .forceignore on exit.                   │
# │                                                                             │
# │ REQUIRES: Phase 2 completed successfully (agent is published + active).     │
# └──────────────────────────────────────────────────────────────────────────────┘

# # Remove messagingChannels and EmbeddedServiceConfig from .forceignore
# sed -i '' '/\*\*\/messagingChannels\/\*\*/d' .forceignore
# sed -i '' '/\*\*\/EmbeddedServiceConfig\/\*\*/d' .forceignore

# # Deploy messagingChannels first (EmbeddedServiceConfig depends on it)
# echo "Deploying messagingChannels..."
# sf project deploy start --source-dir force-app/main/default/messagingChannels --ignore-conflicts

# # Deploy EmbeddedServiceConfig
# echo "Deploying EmbeddedServiceConfig..."
# sf project deploy start --source-dir force-app/main/default/EmbeddedServiceConfig --ignore-conflicts

# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ PHASE 4: Post-Deploy Activation                                             │
# │ STATUS: NOT YET VALIDATED                                                   │
# │                                                                             │
# │ Publish the Experience Site, activate the messaging channel, and finalize.  │
# │                                                                             │
# │ NOTE: The Embedded Service Deployment may require a manual publish step     │
# │ from Setup > Embedded Service Deployments. There may be no CLI equivalent.  │
# │                                                                             │
# │ REQUIRES: Phase 3 completed successfully.                                   │
# └──────────────────────────────────────────────────────────────────────────────┘

# # Publish Experience Site
# NETWORK_ID=$(sf data query --json -q "SELECT Id FROM Network WHERE Name = 'ESW_Skywave_MIAW'" | jq -r '.result.records[0].Id')
# echo "Publishing Experience site (Network ID: $NETWORK_ID)..."
# sf api request rest --method POST "/services/data/v66.0/connect/communities/${NETWORK_ID}/publish" --body '{}'

# # Activate Messaging Channel
# CHANNEL_ID=$(sf data query --json -q "SELECT Id FROM MessagingChannel WHERE DeveloperName = 'Skywave_MIAW'" | jq -r '.result.records[0].Id')
# sf data update record --json -s MessagingChannel -i "$CHANNEL_ID" -v "IsActive=true"

# ── Final Setup ──
# sf org assign permset --name Demo  # Move here once Phase 1b is validated (needs to happen after org-specific updates)
# sf apex run --file scripts/apex/createSampleData.apex  # Same — move here once Phase 1b is validated

sf org open
