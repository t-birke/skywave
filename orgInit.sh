#!/bin/bash

# Create scratch org
sf org create scratch --definition-file config/project-scratch-def.json --alias skywave-scratch --duration-days 7 --set-default

# Create Einstein Agent User
ORG_ID=$(sf org display --json | jq -r '.result.id')
PROFILE_ID=$(sf data query -q "SELECT Id FROM Profile WHERE Name = 'Einstein Agent User'" --json | jq -r '.result.records[0].Id')
sf data create record -s User -v "Username='einsteinagent@${ORG_ID}.ext' Email='einsteinagent@example.com' Alias='einagent' LastName='Einstein Agent' TimeZoneSidKey='America/Los_Angeles' LocaleSidKey='en_US' EmailEncodingKey='UTF-8' ProfileId='${PROFILE_ID}' LanguageLocaleKey='en_US'"

# Assign permsets
sf org assign permset --name AgentforceServiceAgentUser --on-behalf-of "einsteinagent@${ORG_ID}.ext"
sf org assign permset --name Demo

# Deploy and open
sf project deploy start --ignore-conflicts
sf org open
