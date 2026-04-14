#!/bin/bash

sf org create scratch --definition-file config/project-scratch-def.json --alias skywave-scratch --duration-days 7 --set-default

ADMIN_USER_ID=$(sf data query -q "SELECT Id FROM User WHERE Username = '$(sf org display --json | jq -r '.result.username')'" --json | jq -r '.result.records[0].Id')
sf data update record -s User -i "$ADMIN_USER_ID" -v "UserPermissionsKnowledgeUser=true"

ORG_ID=$(sf org display --json | jq -r '.result.id')
PROFILE_ID=$(sf data query -q "SELECT Id FROM Profile WHERE Name = 'Einstein Agent User'" --json | jq -r '.result.records[0].Id')
sf data create record -s User -v "Username='einsteinagent@${ORG_ID}.ext' Email='einsteinagent@example.com' Alias='einagent' LastName='Einstein Agent' TimeZoneSidKey='America/Los_Angeles' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' ProfileId='${PROFILE_ID}' LanguageLocaleKey='en_US'"
sf org assign permset --name AgentforceServiceAgentUser --on-behalf-of "einsteinagent@${ORG_ID}.ext"

sf project deploy start --ignore-conflicts
sf org assign permset --name Demo
sf org open
