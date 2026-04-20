#!/bin/bash
# Creates the full MIAW stack: Experience Site (Network), MessagingChannel,
# EmbeddedServiceConfig, and CORS whitelist origins.
# Requires DOMAIN (exported by setup-org.sh).

echo "========================================="
echo "Creating MIAW Stack for Skywave Airlines"
echo "========================================="

# 1. Create or verify Experience Site
echo ""
echo "Step 1: Creating Experience Site..."

# Check if site already exists
echo "Checking for existing site..."
EXISTING_SITE=$(sf data query \
  --query "SELECT Id, Name, Status FROM Network WHERE Name='ESW_Skywave_MIAW'" \
  --json 2>&1)
echo "Query output received"
# Use tr to remove newlines, then extract JSON
EXISTING_JSON=$(echo "$EXISTING_SITE" | tr -d '\n' | grep -o '{.*}' || echo '{"result":{"records":[]}}')
echo "JSON extracted successfully"
SITE_STATUS=$(echo "$EXISTING_JSON" | jq -r '.result.records[0].Status // empty' 2>/dev/null)
echo "Site status: '$SITE_STATUS'"

if [ "$SITE_STATUS" = "Live" ]; then
  echo "✓ Site already exists and is Live"
  JOB_ID=""
elif [ "$SITE_STATUS" = "UnderConstruction" ]; then
  echo "⚠ Site already exists but is UnderConstruction, waiting for completion..."
  # Find the most recent BackgroundOperation for this site
  BG_OP=$(sf data query \
    --query "SELECT Id, Status, Message FROM BackgroundOperation WHERE Type='CommunityCreate' ORDER BY CreatedDate DESC LIMIT 1" \
    --json 2>&1)
  BG_JSON=$(echo "$BG_OP" | tr -d '\n' | grep -o '{.*}' || echo '{"result":{"records":[]}}')
  JOB_ID=$(echo "$BG_JSON" | jq -r '.result.records[0].Id // empty' 2>/dev/null)
  
  if [ -z "$JOB_ID" ]; then
    echo "⚠ Could not find BackgroundOperation job, will activate site directly via API..."
    
    # Get the Network ID for activation
    NETWORK_QUERY=$(sf data query \
      --query "SELECT Id FROM Network WHERE Name='ESW_Skywave_MIAW'" \
      --json 2>&1)
    NETWORK_QUERY_JSON=$(echo "$NETWORK_QUERY" | tr -d '\n' | grep -o '{.*}' || echo '{"result":{"records":[]}}')
    COMMUNITY_ID=$(echo "$NETWORK_QUERY_JSON" | jq -r '.result.records[0].Id // empty' 2>/dev/null)
    
    if [ -z "$COMMUNITY_ID" ]; then
      echo "✗ Could not find Network ID to activate"
      exit 1
    fi
    
    echo "Attempting to activate site (Community ID: $COMMUNITY_ID)..."
    
    # Copy the Apex template and substitute the Network ID
    APEX_FILE=$(mktemp /tmp/activate-site.XXXXXX.apex)
    sed "s/NETWORK_ID_PLACEHOLDER/$COMMUNITY_ID/g" scripts/apex/activateSite.apex > "$APEX_FILE"
    
    echo "Running Apex activation script..."
    APEX_OUTPUT=$(sf apex run --file "$APEX_FILE" 2>&1 || true)
    rm -f "$APEX_FILE"
    
    echo "Apex output:"
    echo "$APEX_OUTPUT"
    
    # Verify the site status
    echo ""
    echo "Verifying site status..."
    VERIFY_OUTPUT=$(sf data query \
      --query "SELECT Status FROM Network WHERE Id='$COMMUNITY_ID'" \
      --json 2>&1)
    VERIFY_JSON=$(echo "$VERIFY_OUTPUT" | tr -d '\n' | grep -o '{.*}' || echo '{"result":{"records":[]}}')
    FINAL_STATUS=$(echo "$VERIFY_JSON" | jq -r '.result.records[0].Status // empty' 2>/dev/null)
    
    if [ "$FINAL_STATUS" = "Live" ]; then
      echo "✓ Site is now Live!"
    else
      echo "⚠ Site status is still: $FINAL_STATUS"
      echo ""
      echo "NOTE: The site may need manual activation."
      echo "To activate manually:"
      echo "  1. Go to Setup → Digital Experiences → All Sites"
      echo "  2. Find 'ESW_Skywave_MIAW' and click Activate"
      echo ""
      echo "Continuing with MIAW stack creation anyway..."
    fi
    JOB_ID=""  # Clear JOB_ID so we don't poll BackgroundOperation below
  fi
else
  # Site doesn't exist, create it
  SITE_OUTPUT=$(sf community create \
    --name "ESW_Skywave_MIAW" \
    --template-name "Build Your Own (LWR)" \
    --url-path-prefix "ESWSkywaveMIAW" \
    --description "Site for Embedded Messaging deployment: Skywave_MIAW." \
    --json 2>&1)

  # Extract only the JSON portion
  SITE_JSON=$(echo "$SITE_OUTPUT" | grep -o '{.*}' | head -1 || echo "")

  if [ -z "$SITE_JSON" ]; then
    echo "✗ Failed to parse site creation output"
    echo "Output was:"
    echo "$SITE_OUTPUT"
    exit 1
  fi

  # Check for errors in the response
  ERROR_CODE=$(echo "$SITE_JSON" | jq -r '.data.errorCode // .errorCode // empty' 2>/dev/null)
  if [ -n "$ERROR_CODE" ]; then
    ERROR_MSG=$(echo "$SITE_JSON" | jq -r '.message // .data.message // "Unknown error"' 2>/dev/null)
    echo "✗ Site creation failed: $ERROR_MSG - Error: $ERROR_CODE"
    exit 1
  fi

  # Get jobId from response
  JOB_ID=$(echo "$SITE_JSON" | jq -r '.result.jobId // empty' 2>/dev/null)
fi

# Poll for completion if we have a job ID
if [ -n "$JOB_ID" ]; then
  echo "Site creation in progress (Job ID: $JOB_ID)"
  echo "Polling for completion..."
  
  MAX_ATTEMPTS=60
  ATTEMPT=0
  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    STATUS_OUTPUT=$(sf data query \
      --query "SELECT Status, Message FROM BackgroundOperation WHERE Id='$JOB_ID'" \
      --json 2>/dev/null || echo '{"result":{"records":[]}}')
    
    STATUS=$(echo "$STATUS_OUTPUT" | jq -r '.result.records[0].Status // "Unknown"')
    
    if [ "$STATUS" = "Completed" ]; then
      echo "✓ Site creation completed successfully"
      break
    elif [ "$STATUS" = "Error" ] || [ "$STATUS" = "Failed" ]; then
      MESSAGE=$(echo "$STATUS_OUTPUT" | jq -r '.result.records[0].Message // "Unknown error"')
      echo "✗ Site creation failed: $MESSAGE"
      exit 1
    fi
    
    echo "  Status: $STATUS (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS)"
    sleep 5
    ATTEMPT=$((ATTEMPT + 1))
  done
  
  if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo "✗ Timeout waiting for site creation"
    exit 1
  fi
fi

# 2. Get Network ID
echo ""
echo "Step 2: Retrieving Network ID..."

# If we already have COMMUNITY_ID from activation, use it
if [ -n "${COMMUNITY_ID:-}" ]; then
  NETWORK_ID="$COMMUNITY_ID"
  echo "✓ Using Network ID from earlier: $NETWORK_ID"
else
  # Otherwise query by UrlPathPrefix
  NETWORK_OUTPUT=$(sf data query \
    --query "SELECT Id, Name FROM Network WHERE UrlPathPrefix='ESWSkywaveMIAW'" \
    --json 2>&1)

  # Extract JSON
  NETWORK_JSON=$(echo "$NETWORK_OUTPUT" | tr -d '\n' | grep -o '{.*}' || echo "")

  if [ -z "$NETWORK_JSON" ]; then
    echo "✗ Failed to parse network query output"
    echo "Output was:"
    echo "$NETWORK_OUTPUT"
    exit 1
  fi

  NETWORK_ID=$(echo "$NETWORK_JSON" | jq -r '.result.records[0].Id // empty' 2>/dev/null)

  if [ -z "$NETWORK_ID" ]; then
    echo "✗ Failed to retrieve Network ID"
    exit 1
  fi

  echo "✓ Network ID: $NETWORK_ID"
fi

# 3. Publish Experience Site
echo ""
echo "Step 3: Publishing Experience Site..."
PUBLISH_OUTPUT=$(sf community publish --name "ESW_Skywave_MIAW" --json 2>&1 || true)

# Extract JSON
PUBLISH_JSON=$(echo "$PUBLISH_OUTPUT" | grep -o '{.*}' | head -1 || echo "")

# Check if publish was async
if [ -n "$PUBLISH_JSON" ]; then
  PUBLISH_JOB_ID=$(echo "$PUBLISH_JSON" | jq -r '.result.jobId // empty' 2>/dev/null || echo "")
else
  PUBLISH_JOB_ID=""
fi

if [ -n "$PUBLISH_JOB_ID" ]; then
  echo "Publish started (Job ID: $PUBLISH_JOB_ID)"
  echo "Polling for completion..."
  
  MAX_ATTEMPTS=60
  ATTEMPT=0
  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    STATUS_OUTPUT=$(sf data query \
      --query "SELECT Status FROM BackgroundOperation WHERE Id='$PUBLISH_JOB_ID'" \
      --json 2>/dev/null || echo '{"result":{"records":[]}}')
    
    STATUS=$(echo "$STATUS_OUTPUT" | jq -r '.result.records[0].Status // "Unknown"')
    
    if [ "$STATUS" = "Completed" ]; then
      echo "✓ Site published successfully"
      break
    elif [ "$STATUS" = "Error" ] || [ "$STATUS" = "Failed" ]; then
      echo "✗ Site publish failed"
      exit 1
    fi
    
    echo "  Status: $STATUS (attempt $((ATTEMPT + 1))/$MAX_ATTEMPTS)"
    sleep 5
    ATTEMPT=$((ATTEMPT + 1))
  done
  
  if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    echo "⚠ Timeout waiting for publish, continuing anyway..."
  fi
else
  echo "✓ Site published"
fi

# 4. Create MessagingChannel
echo ""
echo "Step 4: Creating MessagingChannel..."
MSG_CHANNEL_OUTPUT=$(sf api request rest \
  --method POST \
  --url "/services/data/v66.0/tooling/sobjects/MessagingChannel" \
  --body '{
    "MasterLabel": "Skywave MIAW",
    "DeveloperName": "Skywave_MIAW",
    "MessageType": "EmbeddedMessaging",
    "SessionHandlerType": "AgentforceServiceAgent",
    "SessionHandlerAsa": "Skywave_Airlines_Agent",
    "SessionHandlerQueue": "Skywave_Messaging"
  }' 2>&1)

# Check for errors
if echo "$MSG_CHANNEL_OUTPUT" | grep -q '"errorCode"'; then
  echo "✗ MessagingChannel creation failed:"
  echo "$MSG_CHANNEL_OUTPUT" | jq '.'
  exit 1
fi

MSG_CHANNEL_ID=$(echo "$MSG_CHANNEL_OUTPUT" | jq -r '.id // empty')

if [ -z "$MSG_CHANNEL_ID" ]; then
  echo "✗ Failed to get MessagingChannel ID"
  exit 1
fi

echo "✓ MessagingChannel ID: $MSG_CHANNEL_ID"

# 5. Create EmbeddedServiceConfig
echo ""
echo "Step 5: Creating EmbeddedServiceConfig..."
ESW_CONFIG_OUTPUT=$(sf api request rest \
  --method POST \
  --url "/services/data/v66.0/tooling/sobjects/EmbeddedServiceConfig" \
  --body "{
    \"MasterLabel\": \"Skywave_MIAW\",
    \"DeveloperName\": \"Skywave_MIAW\",
    \"IsEnabled\": true,
    \"NetworkId\": \"$NETWORK_ID\",
    \"DeploymentType\": \"Web\",
    \"DeploymentFeature\": \"EmbeddedMessaging\",
    \"AreGuestUsersAllowed\": false,
    \"ClientVersion\": \"WebV2\"
  }" 2>&1)

# Check for errors
if echo "$ESW_CONFIG_OUTPUT" | grep -q '"errorCode"'; then
  echo "✗ EmbeddedServiceConfig creation failed:"
  echo "$ESW_CONFIG_OUTPUT" | jq '.'
  exit 1
fi

ESW_CONFIG_ID=$(echo "$ESW_CONFIG_OUTPUT" | jq -r '.id // empty')

if [ -z "$ESW_CONFIG_ID" ]; then
  echo "✗ Failed to get EmbeddedServiceConfig ID"
  exit 1
fi

echo "✓ EmbeddedServiceConfig ID: $ESW_CONFIG_ID"

# 6. Add CORS Origins
echo ""
echo "Step 6: Adding CORS whitelist origins..."

if [ -z "$DOMAIN" ]; then
  echo "⚠ DOMAIN variable not set, skipping CORS setup"
else
  # Add site domain
  CORS1_OUTPUT=$(sf api request rest \
    --method POST \
    --url "/services/data/v66.0/tooling/sobjects/CorsWhitelistOrigin" \
    --body "{\"UrlPattern\": \"https://${DOMAIN}.my.site.com\"}" 2>&1)
  
  if echo "$CORS1_OUTPUT" | grep -q '"errorCode"'; then
    echo "⚠ CORS origin 1 failed (may already exist):"
    echo "$CORS1_OUTPUT" | jq -r '.[] | "\(.errorCode): \(.message)"'
  else
    echo "✓ Added CORS origin: https://${DOMAIN}.my.site.com"
  fi
  
  # Add Salesforce domain
  CORS2_OUTPUT=$(sf api request rest \
    --method POST \
    --url "/services/data/v66.0/tooling/sobjects/CorsWhitelistOrigin" \
    --body "{\"UrlPattern\": \"https://${DOMAIN}.my.salesforce.com\"}" 2>&1)
  
  if echo "$CORS2_OUTPUT" | grep -q '"errorCode"'; then
    echo "⚠ CORS origin 2 failed (may already exist):"
    echo "$CORS2_OUTPUT" | jq -r '.[] | "\(.errorCode): \(.message)"'
  else
    echo "✓ Added CORS origin: https://${DOMAIN}.my.salesforce.com"
  fi
fi

echo ""
echo "========================================="
echo "✓ MIAW Stack Creation Complete!"
echo "========================================="
echo "Network ID:               $NETWORK_ID"
echo "MessagingChannel ID:      $MSG_CHANNEL_ID"
echo "EmbeddedServiceConfig ID: $ESW_CONFIG_ID"
echo "========================================="