#!/bin/bash

sf org delete scratch --no-prompt --target-org skywave-scratch 2>/dev/null || true
sf org create scratch --definition-file config/project-scratch-def.json --alias skywave-scratch --duration-days 7 --set-default

ORG_INFO=$(sf org display --json)
ORG_ID=$(echo "$ORG_INFO" | grep -m1 '"id"' | sed 's/.*: *"//;s/".*//')
ADMIN_USERNAME=$(echo "$ORG_INFO" | grep -m1 '"username"' | sed 's/.*: *"//;s/".*//')
DOMAIN=$(echo "$ORG_INFO" | grep -m1 '"instanceUrl"' | sed 's/.*https:\/\///;s/\.my\.salesforce\.com.*//')
AGENT_USER="skywaveagent@${ORG_ID}.ext"
ADMIN_USER_ID=$(sf data query --json -q "SELECT Id FROM User WHERE Username = '${ADMIN_USERNAME}'" | grep -m1 '"Id"' | sed 's/.*"Id": *"//;s/".*//')
sf data update record -s User -i "$ADMIN_USER_ID" -v "UserPermissionsKnowledgeUser=true"

PROFILE_ID=$(sf data query --json -q "SELECT Id FROM Profile WHERE Name = 'Einstein Agent User'" | grep -m1 '"Id"' | sed 's/.*"Id": *"//;s/".*//')
sf data create record -s User -v "Username='${AGENT_USER}' Email='skywaveagent@example.com' Alias='skyagent' LastName='Skywave Agent' TimeZoneSidKey='America/Los_Angeles' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' ProfileId='${PROFILE_ID}' LanguageLocaleKey='en_US'"
sf org assign permset --name AgentforceServiceAgentUser --on-behalf-of "$AGENT_USER"
sf org assign permset --name Skywave_Agent_User --on-behalf-of "$AGENT_USER"
sf org assign permset --name sfdc_aiplanner_service_permset --on-behalf-of "$AGENT_USER"
sf org assign permset --name sfdc_chatbot_service_permset --on-behalf-of "$AGENT_USER"

sf project deploy start --ignore-conflicts
sf org assign permset --name Demo
sf apex run --file scripts/apex/createSampleData.apex

#scripts/deploy-agent.sh
#sf agent publish authoring-bundle --api-name Skywave_Airlines_Agent
#sf agent activate --api-name Skywave_Airlines_Agent

#scripts/create-miaw-stack.sh
#sf apex run --file scripts/apex/demoSetup.apex

sf org open
