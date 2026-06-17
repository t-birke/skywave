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

INSTANCE_URL=$(sf org display "${ORG_TARGET_ARG[@]}" --json | jq -r '.result.instanceUrl')
# Newer sf CLI REDACTS accessToken from `sf org display --json` (prints
# "[REDACTED] Use 'sf org auth show-access-token'…"), which would send a bogus
# Bearer header → INVALID_AUTH_HEADER → a JSON *array* error body that crashes the
# `.records[0]` jq below. Use the supported token command instead.
ACCESS_TOKEN=$(sf org auth show-access-token "${ORG_TARGET_ARG[@]}" --no-prompt --json | jq -r '.result.accessToken')
[ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ] || { echo "ERROR: could not obtain an access token for the target org" >&2; exit 1; }

# Skip if already exists. `// empty` on BOTH the array index AND a possible error
# body ([{errorCode:…}] has no .records) so a non-2xx response degrades to "create"
# instead of aborting the whole installer under `set -e`.
EXISTING=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    "${INSTANCE_URL}/services/data/v66.0/tooling/query?q=SELECT+Id+FROM+EmbeddedServiceConfig+WHERE+DeveloperName='${DEPLOYMENT_NAME}'" \
    | jq -r 'if type=="object" then (.records[0].Id // "") else "" end')

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
