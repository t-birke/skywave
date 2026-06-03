#!/bin/bash
# Redeploys, republishes, and activates Skywave_Airlines_Agent after edits.
# Use this during demo iteration: edit the .agent / Apex files, then run this
# script to push the changes and bump to a new active version.
#
# Looks up AGENT_USER from the org (created by orgInit.sh) so this script
# works on any scratch org without remembering the username hash.

set -euo pipefail

AGENT_API_NAME="Skywave_Airlines_Agent"
AGENT_FILE="force-app/main/default/aiAuthoringBundles/${AGENT_API_NAME}/${AGENT_API_NAME}.agent"

# AGENT_USER must be exported: sfdx-project.json declares a replaceWithEnv
# replacement (skywaveserviceagent@example.com -> $AGENT_USER) that runs at
# deploy AND publish time, and errors if the var is unset — even though the
# .agent file already carries the real default_agent_user once deployed.
echo "─── Resolving agent user ───"
# 1) Authoritative source: the default_agent_user already in the .agent file.
AGENT_USER=$(sed -n 's/.*default_agent_user: *"\([^"]*\)".*/\1/p' "$AGENT_FILE" | head -1)

# 2) If the file still holds the placeholder (fresh checkout), query the org
#    for the active Einstein Agent User.
if [ -z "$AGENT_USER" ] || [ "$AGENT_USER" = "skywaveserviceagent@example.com" ]; then
  AGENT_USER=$(sf data query --json \
    -q "SELECT Username FROM User WHERE Profile.Name = 'Einstein Agent User' AND IsActive = true ORDER BY CreatedDate DESC LIMIT 1" \
    | jq -r '.result.records[0].Username // empty')
fi

if [ -z "$AGENT_USER" ]; then
  echo "ERROR: Could not resolve the Einstein Agent User (not in $AGENT_FILE and none active in org). Has orgInit.sh been run?" >&2
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
