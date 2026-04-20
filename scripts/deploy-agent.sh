#!/bin/bash
# Creates Einstein Agent User, assigns permsets, and deploys the agent bundle.
# Uses pattern-based sed replacement to inject default_agent_user dynamically.
# Requires ORG_ID (exported by setup-org.sh).

AGENT_USER="einsteinagent@${ORG_ID}.ext"

# Update the agent file with the correct default_agent_user email
# This replaces whatever email is currently in quotes after default_agent_user
sed -i '' 's/default_agent_user: ".*"/default_agent_user: "'"$AGENT_USER"'"/' \
  force-app/main/default/aiAuthoringBundles/Skywave_Airlines_Agent/Skywave_Airlines_Agent.agent

echo "Updated agent file with default_agent_user: $AGENT_USER"

# Create Einstein Agent User
PROFILE_ID=$(sf data query --json -q "SELECT Id FROM Profile WHERE Name = 'Einstein Agent User'" | grep -m1 '"Id"' | sed 's/.*"Id": *"//;s/".*//')
sf data create record -s User -v "Username='${AGENT_USER}' Email='einsteinagent@example.com' Alias='einagent' LastName='Einstein Agent' TimeZoneSidKey='America/Los_Angeles' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' ProfileId='${PROFILE_ID}' LanguageLocaleKey='en_US'"

# Assign permsets (AgentforceServiceAgentUser MUST be assigned before publish)
sf org assign permset --name AgentforceServiceAgentUser --on-behalf-of "$AGENT_USER"
sf org assign permset --name Skywave_Agent_User --on-behalf-of "$AGENT_USER"
sf org assign permset --name sfdc_aiplanner_service_permset --on-behalf-of "$AGENT_USER"
sf org assign permset --name sfdc_chatbot_service_permset --on-behalf-of "$AGENT_USER"

# Note: SF_AGENT_USER is already exported by orgInit.sh
# The agent bundle was already deployed by orgInit.sh with the correct email replacement
echo "Agent user $AGENT_USER created and permission sets assigned."
