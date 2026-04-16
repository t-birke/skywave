#!/bin/bash
set -e

# ─── DELETE EXISTING SCRATCH ORG ───
sf org delete scratch --no-prompt --target-org skywave-scratch 2>/dev/null || true

# ─── CREATE SCRATCH ORG ───
sf org create scratch --definition-file config/project-scratch-def.json --alias skywave-scratch --duration-days 7 --set-default

# ─── GATHER ORG INFO ───
ADMIN_USERNAME=$(sf org display --json | jq -r '.result.username')

# Extract domain prefix (e.g., "ability-flow-9061-dev-ed.scratch" or "ability-flow-9061-dev-ed")
# Handle both *.scratch.my.salesforce.com and *.my.salesforce.com patterns
DOMAIN=$(echo "$INSTANCE_URL" | sed 's|https://||; s|\.my\.salesforce\.com||')
SITE_BASE="https://${DOMAIN}.my.site.com"
SCRT2_URL="https://${DOMAIN}.my.salesforce-scrt.com"

echo "Org ID:    $ORG_ID"
echo "Domain:    $DOMAIN"
echo "Site Base: $SITE_BASE"
echo "SCRT2:     $SCRT2_URL"

# ─── ENABLE KNOWLEDGE FOR ADMIN ───
ADMIN_USER_ID=$(sf data query -q "SELECT Id FROM User WHERE Username = '${ADMIN_USERNAME}'" --json | jq -r '.result.records[0].Id')
sf data update record -s User -i "$ADMIN_USER_ID" -v "UserPermissionsKnowledgeUser=true"

# ─── CREATE EINSTEIN AGENT USER ───
#PROFILE_ID=$(sf data query -q "SELECT Id FROM Profile WHERE Name = 'Einstein Agent User'" --json | jq -r '.result.records[0].Id')
#sf data create record -s User -v "Username='einsteinagent@${ORG_ID}.ext' Email='einsteinagent@example.com' Alias='einagent' LastName='Einstein Agent' TimeZoneSidKey='America/Los_Angeles' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' ProfileId='${PROFILE_ID}' LanguageLocaleKey='en_US'"

# ─── UPDATE ORG-SPECIFIC VALUES IN SOURCE FILES ───
AGENT_FILE="force-app/main/default/aiAuthoringBundles/Skywave_Airlines_Agent/Skywave_Airlines_Agent.agent"
VF_PAGE="force-app/main/default/pages/SkyWaveAirlines.page"

# Agent: update default_agent_user
#sed -i '' "s|default_agent_user: \"einsteinagent@.*\"|default_agent_user: \"einsteinagent@${ORG_ID}.ext\"|" "$AGENT_FILE"
#echo "Updated default_agent_user"

# VF Page: update embedded messaging snippet (org ID, site URL, SCRT2 URL)
#sed -i '' "s|embeddedservice_bootstrap.init(|embeddedservice_bootstrap.init(|" "$VF_PAGE"
#sed -i '' "s|'[A-Za-z0-9]\{18\}',|'${ORG_ID}',|" "$VF_PAGE"
#sed -i '' "s|'https://[^']*\.my\.site\.com/[^']*'|'${SITE_BASE}/ESWSkywaveMIAW'|g" "$VF_PAGE"
#sed -i '' "s|scrt2URL: 'https://[^']*\.my\.salesforce-scrt\.com'|scrt2URL: '${SCRT2_URL}'|" "$VF_PAGE"
#sed -i '' "s|src=\"https://[^\"]*\.my\.site\.com/[^\"]*/assets/js/bootstrap.min.js\"|src=\"${SITE_BASE}/ESWSkywaveMIAW/assets/js/bootstrap.min.js\"|" "$VF_PAGE"
#echo "Updated VF page MIAW snippet"

# Network: update emailSenderAddress
#NETWORK_FILE="force-app/main/default/networks/ESW_Skywave_MIAW.network-meta.xml"
#sed -i '' "s|<emailSenderAddress>[^<]*</emailSenderAddress>|<emailSenderAddress>${ADMIN_USERNAME}</emailSenderAddress>|" "$NETWORK_FILE"

# Site: update siteAdmin and siteGuestRecordDefaultOwner
#SITE_FILE="force-app/main/default/sites/ESW_Skywave_MIAW.site-meta.xml"
#sed -i '' "s|<siteAdmin>[^<]*</siteAdmin>|<siteAdmin>${ADMIN_USERNAME}</siteAdmin>|" "$SITE_FILE"
#sed -i '' "s|<siteGuestRecordDefaultOwner>[^<]*</siteGuestRecordDefaultOwner>|<siteGuestRecordDefaultOwner>${ADMIN_USERNAME}</siteGuestRecordDefaultOwner>|" "$SITE_FILE"
#echo "Updated Network and Site metadata"

# ─── DEPLOY PHASE 1: Everything except EmbeddedServiceConfig ───
# EmbeddedServiceConfig needs the picasso site that auto-creates from Network deploy
#echo "Deploy Phase 1: Core metadata..."
#echo "force-app/main/default/EmbeddedServiceConfig/" >> .forceignore
sf project deploy start --ignore-conflicts

# ─── PUBLISH EXPERIENCE SITE ───
# The site assets (bootstrap.min.js etc.) aren't accessible until the Experience site is published
#NETWORK_ID=$(sf data query --json -q "SELECT Id FROM Network WHERE Name = 'ESW_Skywave_MIAW'" | jq -r '.result.records[0].Id')
#echo "Publishing Experience site (Network ID: $NETWORK_ID)..."
#sf api request rest --method POST "/services/data/v66.0/connect/communities/${NETWORK_ID}/publish" --body '{}' 2>&1
#echo "Experience site published"

# ─── PUBLISH + ACTIVATE AGENT ───
# Must happen before MessagingChannel can reference it (if not already linked)
#echo "Publishing agent..."
#sf agent publish authoring-bundle --json --api-name Skywave_Airlines_Agent
#echo "Activating agent..."
#sf agent activate --json --api-name Skywave_Airlines_Agent

# ─── ACTIVATE MESSAGING CHANNEL ───
# MessagingChannel deploys as inactive; must activate before Embedded Service can publish
#CHANNEL_ID=$(sf data query --json -q "SELECT Id FROM MessagingChannel WHERE DeveloperName = 'Skywave_MIAW'" | jq -r '.result.records[0].Id')
#sf data update record --json -s MessagingChannel -i "$CHANNEL_ID" -v "IsActive=true"
#echo "Messaging channel activated"

# ─── DEPLOY PHASE 2: EmbeddedServiceConfig ───
# Picasso site now exists from Network deploy in Phase 1
#echo "Deploy Phase 2: EmbeddedServiceConfig..."
#sf project deploy start --source-dir force-app/main/default/EmbeddedServiceConfig --ignore-conflicts

# ─── PUBLISH EMBEDDED SERVICE DEPLOYMENT ───
# This generates the bootstrap.min.js SDK on the picasso site
#echo "Publishing Embedded Service deployment..."
#sf org open -p /lightning/setup/EmbeddedServiceDeployment/home --url-only 2>&1
#echo "NOTE: Embedded Service deployment may need manual publish from Setup > Embedded Service Deployments"

# ─── ASSIGN PERMISSION SETS ───
sf org assign permset --name AgentforceServiceAgentUser --on-behalf-of "einsteinagent@${ORG_ID}.ext"
sf org assign permset --name Skywave_Agent_User --on-behalf-of "einsteinagent@${ORG_ID}.ext"
sf org assign permset --name Demo

# ─── CREATE SAMPLE DATA ───
echo "Creating sample data..."
sf apex run --file scripts/apex/createSampleData.apex

# ─── DONE ───
echo ""
echo "========================================="
echo "Org setup complete!"
echo "========================================="
echo ""
echo "VF Page: ${INSTANCE_URL}/apex/SkyWaveAirlines"
echo ""

sf org open
