#!/bin/bash
# finalize.sh — phase 2 of scratch-org setup, run after the user creates a
# Messaging Channel + Embedded Service Deployment via the Setup wizard.
#
# Validates that the manual step produced the expected records, extracts the
# three deployment values (org ID 15-char, channel developer name, ESW site
# URL), bakes them into a staged copy of the skywaveAirlinesHome LWC, deploys
# that copy, and republishes the LWR site. Idempotent — safe to re-run.

set -euo pipefail
trap 'echo "FAILED at line $LINENO (exit $?): $BASH_COMMAND" >&2' ERR

echo ""
echo "Verifying manual Setup-wizard output..."
echo ""

# 1. EmbeddedServiceConfig deployment. NB: the 2nd arg to
# embeddedservice_bootstrap.init() is the ESC DeveloperName (not the
# MessagingChannel's). The scrt2 /embedded-service-config endpoint looks
# this up as esConfigName and returns 400 if it doesn't match an ESC.
ESC_JSON=$(sf data query --use-tooling-api --json -q "SELECT Id, DeveloperName, IsEnabled FROM EmbeddedServiceConfig WHERE DeploymentFeature = 'EmbeddedMessaging' AND IsEnabled = true")
ESC_COUNT=$(echo "$ESC_JSON" | jq -r '.result.totalSize')
if [ "$ESC_COUNT" = "0" ]; then
    echo "ERROR: No enabled EmbeddedServiceConfig deployment found."
    echo "  Go to Setup → Embedded Service Deployments, create a new 'Messaging"
    echo "  for In-App and Web' deployment tied to your messaging channel."
    exit 1
fi
ESC_NAME=$(echo "$ESC_JSON" | jq -r '.result.records[0].DeveloperName')
echo "  ✓ EmbeddedServiceConfig: $ESC_NAME"

# 2. Auto-provisioned ESW bootstrap site.
ESW_JSON=$(sf data query --json -q "SELECT Id, UrlPathPrefix FROM Site WHERE UrlPathPrefix LIKE 'ESW%' ORDER BY CreatedDate DESC LIMIT 1")
ESW_COUNT=$(echo "$ESW_JSON" | jq -r '.result.totalSize')
if [ "$ESW_COUNT" = "0" ]; then
    echo "ERROR: No ESW bootstrap Site found. The deployment wizard didn't"
    echo "  complete successfully — Salesforce should auto-provision a Site"
    echo "  with UrlPathPrefix beginning with 'ESW' when the deployment saves."
    exit 1
fi
ESW_PREFIX=$(echo "$ESW_JSON" | jq -r '.result.records[0].UrlPathPrefix')
echo "  ✓ ESW bootstrap site: $ESW_PREFIX"

# Derive the remaining values.
ORG_INFO=$(sf org display --json)
ORG_ID_18=$(echo "$ORG_INFO" | jq -r '.result.id')
# Embedded Messaging init() requires the 15-char, case-sensitive org ID.
ORG_ID_15="${ORG_ID_18:0:15}"
ORG_HOST=$(echo "$ORG_INFO" | jq -r '.result.instanceUrl' | sed -E 's|https?://||; s|/.*||')
SITE_HOST="${ORG_HOST/.my.salesforce.com/.my.site.com}"
SITE_HOST="${SITE_HOST/.my.pc-rnd.salesforce.com/.my.pc-rnd.site.com}"
SITE_HOST="${SITE_HOST/.sandbox.my.salesforce.com/.sandbox.my.site.com}"
SCRT2_HOST="${ORG_HOST/salesforce.com/salesforce-scrt.com}"
SITE_URL="https://${SITE_HOST}/${ESW_PREFIX}"
SCRT2_URL="https://${SCRT2_HOST}"

echo ""
echo "Baking values into skywaveAirlinesHome LWC:"
echo "    orgId      = $ORG_ID_15"
echo "    esConfig   = $ESC_NAME"
echo "    siteUrl    = $SITE_URL"
echo "    scrt2Url   = $SCRT2_URL"
echo ""

# Stage a copy of the LWC with the tokens replaced, then deploy that copy.
# The source file keeps the __PLACEHOLDER__ tokens so the script stays
# idempotent and the repo stays clean.
REDEPLOY_DIR=$(mktemp -d)
trap 'rm -rf "$REDEPLOY_DIR" 2>/dev/null || true' EXIT

mkdir -p "$REDEPLOY_DIR/lwc/skywaveAirlinesHome"
cp -r force-app/main/default/lwc/skywaveAirlinesHome/* "$REDEPLOY_DIR/lwc/skywaveAirlinesHome/"

LWC_JS="$REDEPLOY_DIR/lwc/skywaveAirlinesHome/skywaveAirlinesHome.js"
# Use Python for the string replacement — avoids sed escaping headaches with URLs.
python3 - <<PYEOF
p = '$LWC_JS'
s = open(p).read()
s = s.replace('__ESW_ORG_ID__', '$ORG_ID_15')
s = s.replace('__ESW_ESC_NAME__', '$ESC_NAME')
s = s.replace('__ESW_SITE_URL__', '$SITE_URL')
s = s.replace('__ESW_SCRT2_URL__', '$SCRT2_URL')
open(p, 'w').write(s)
PYEOF

cat > "$REDEPLOY_DIR/package.xml" <<PKG_EOF
<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    <types><members>skywaveAirlinesHome</members><name>LightningComponentBundle</name></types>
    <version>66.0</version>
</Package>
PKG_EOF

sf project deploy start --metadata-dir "$REDEPLOY_DIR" --ignore-conflicts --json > /dev/null

# Republish so the LWR site serves the refreshed LWC bundle.
sf community publish --name "skywave website" --json > /dev/null || true

cat <<BANNER

────────────────────────────────────────────────────────────────────
  finalize.sh complete.

  Reload the LWR site with a hard-refresh (Cmd+Shift+R) to clear the
  LWR bundle cache. The messaging widget should now render instantly
  and connect to the Agentforce agent.
────────────────────────────────────────────────────────────────────
BANNER
