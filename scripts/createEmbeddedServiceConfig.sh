#!/bin/bash
# Creates the Skywave_MIAW_Deployment EmbeddedServiceConfig via the Tooling API
# (which supports `clientVersion=WebV2` on create — the Metadata API path does
# not and leaves the "Switch to Enhanced v2" manual click in Setup). Idempotent.
#
# Usage: ./scripts/createEmbeddedServiceConfig.sh

set -euo pipefail

DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-Skywave_MIAW_Deployment}"
CHANNEL_NAME="${CHANNEL_NAME:-Skywave_Channel}"
SITE_NAME="${SITE_NAME:-ESA_Deployment1}"

# Honor an explicit target org if the caller exports ORG_ALIAS (install.sh
# does); otherwise fall back to the CLI's default org (legacy behavior).
ORG_TARGET_ARG=()
[ -n "${ORG_ALIAS:-}" ] && ORG_TARGET_ARG=(--target-org "$ORG_ALIAS")

ORG_INFO=$(sf org display "${ORG_TARGET_ARG[@]}" --json)
ACCESS_TOKEN=$(echo "$ORG_INFO" | jq -r '.result.accessToken')
INSTANCE_URL=$(echo "$ORG_INFO" | jq -r '.result.instanceUrl')

# Skip if already exists.
EXISTING=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    "${INSTANCE_URL}/services/data/v66.0/tooling/query?q=SELECT+Id+FROM+EmbeddedServiceConfig+WHERE+DeveloperName='${DEPLOYMENT_NAME}'" \
    | jq -r '.records[0].Id // ""')

if [ -n "$EXISTING" ]; then
    echo "EmbeddedServiceConfig '$DEPLOYMENT_NAME' already exists ($EXISTING)"
    exit 0
fi

RESP=$(curl -s -X POST -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
    "${INSTANCE_URL}/services/data/v66.0/tooling/sobjects/EmbeddedServiceConfig" \
    -d "$(cat <<JSON
{
  "FullName": "${DEPLOYMENT_NAME}",
  "Metadata": {
    "masterLabel": "Skywave MIAW Deployment",
    "deploymentFeature": "EmbeddedMessaging",
    "deploymentType": "Web",
    "clientVersion": "WebV2",
    "isEnabled": true,
    "shouldHideAuthDialog": false,
    "isTermsAndConditionsEnabled": false,
    "isTermsAndConditionsRequired": false,
    "areGuestUsersAllowed": false,
    "site": "${SITE_NAME}",
    "embeddedServiceMessagingChannel": {
      "isEnabled": true,
      "messagingChannel": "${CHANNEL_NAME}",
      "shouldShowAgentforceTagline": false,
      "shouldShowDeliveryReceipts": false,
      "shouldShowEmojiSelection": false,
      "shouldShowReadReceipts": false,
      "shouldShowTypingIndicators": true,
      "shouldStartNewLineOnEnter": false
    }
  }
}
JSON
)")

if echo "$RESP" | jq -e '.success == true' > /dev/null 2>&1; then
    NEW_ID=$(echo "$RESP" | jq -r '.id')
    echo "Created EmbeddedServiceConfig '$DEPLOYMENT_NAME' ($NEW_ID)"
else
    echo "ERROR creating EmbeddedServiceConfig: $RESP" >&2
    exit 1
fi
