#!/bin/bash
# Gathers org info and enables Knowledge.
# Sourced by orgInit.sh — exports ORG_ID, ADMIN_USERNAME, DOMAIN.


ORG_INFO=$(sf org display --json)
export ORG_ID=$(echo "$ORG_INFO" | grep -m1 '"id"' | sed 's/.*: *"//;s/".*//')
export ADMIN_USERNAME=$(echo "$ORG_INFO" | grep -m1 '"username"' | sed 's/.*: *"//;s/".*//')
export DOMAIN=$(echo "$ORG_INFO" | grep -m1 '"instanceUrl"' | sed 's/.*https:\/\///;s/\.my\.salesforce\.com.*//')

echo "Org ID:  $ORG_ID"
echo "Admin:   $ADMIN_USERNAME"
echo "Domain:  $DOMAIN"

ADMIN_USER_ID=$(sf data query --json -q "SELECT Id FROM User WHERE Username = '${ADMIN_USERNAME}'" | grep -m1 '"Id"' | sed 's/.*"Id": *"//;s/".*//')
sf data update record -s User -i "$ADMIN_USER_ID" -v "UserPermissionsKnowledgeUser=true"
