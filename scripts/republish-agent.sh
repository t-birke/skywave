#!/bin/bash
# Redeploys, republishes, and activates Skywave_Airlines_Agent after edits.
# Use this during demo iteration: edit the .agent / Apex files, then run this
# script to push the changes and bump to a new active version.
#
# Looks up AGENT_USER from the org (created by orgInit.sh) so this script
# works on any scratch org without remembering the username hash.

set -euo pipefail

AGENT_API_NAME="Skywave_Airlines_Agent"

echo "─── Looking up agent user ───"
AGENT_USER=$(sf data query --json \
  -q "SELECT Username FROM User WHERE FirstName = 'Skywave' AND LastName = 'Agent' LIMIT 1" \
  | jq -r '.result.records[0].Username // empty')

if [ -z "$AGENT_USER" ]; then
  echo "ERROR: Could not find the Skywave Agent user. Has orgInit.sh been run?" >&2
  exit 1
fi
export AGENT_USER
echo "  AGENT_USER=$AGENT_USER"

echo "─── Deploying agent source (apex, permsets, bundle) ───"
sf project deploy start \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/permissionsets \
  --source-dir force-app/main/default/aiAuthoringBundles \
  --source-dir force-app/main/default/genAiPromptTemplates \
  --ignore-conflicts --wait 30 --concise

echo "─── Publishing agent bundle ───"
sf agent publish authoring-bundle --api-name "$AGENT_API_NAME" --skip-retrieve

echo "─── Activating latest version ───"
ACTIVATE_OUT=$(sf agent activate --api-name "$AGENT_API_NAME" --json)
ACTIVATED_VERSION=$(echo "$ACTIVATE_OUT" | jq -r '.result.version')
ACTIVATE_OK=$(echo "$ACTIVATE_OUT" | jq -r '.result.success')
if [ "$ACTIVATE_OK" != "true" ]; then
  echo "ERROR: agent activation failed:" >&2
  echo "$ACTIVATE_OUT" | jq -r '.message // .' >&2
  exit 1
fi
echo "  Activated version $ACTIVATED_VERSION"

echo "─── Done. Start a fresh preview session to pick up the new version: ───"
echo "  sf agent preview start --api-name $AGENT_API_NAME"
