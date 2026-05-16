#!/usr/bin/env bash
# Smoke-test JWT-bearer auth into Salesforce using only openssl + curl.
# Confirms the Connected App + integration user + private key are wired
# correctly before we build the Heroku Node app on top.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "${REPO_ROOT}/.env" ] || { echo ".env missing — copy from .env.example and fill in" >&2; exit 1; }

set -a
. "${REPO_ROOT}/.env"
set +a

KEY_FILE="${REPO_ROOT}/${SF_JWT_PRIVATE_KEY_FILE:-secrets/jwt.key}"
[ -f "${KEY_FILE}" ] || { echo "Missing ${KEY_FILE} — run scripts/gen-jwt-keypair.sh" >&2; exit 1; }

# JWT header (alg=RS256, typ=JWT)
HEADER='{"alg":"RS256","typ":"JWT"}'

# JWT claims
NOW=$(date +%s)
EXP=$((NOW + 180))
CLAIMS=$(printf '{"iss":"%s","sub":"%s","aud":"%s","exp":%s}' \
    "${SF_CLIENT_ID}" "${SF_USERNAME}" "${SF_LOGIN_URL}" "${EXP}")

b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

H=$(printf '%s' "${HEADER}" | b64url)
C=$(printf '%s' "${CLAIMS}" | b64url)
SIG=$(printf '%s.%s' "${H}" "${C}" | openssl dgst -sha256 -sign "${KEY_FILE}" -binary | b64url)
JWT="${H}.${C}.${SIG}"

echo "Requesting access token from ${SF_LOGIN_URL}..."
RESP=$(curl -s -X POST "${SF_LOGIN_URL}/services/oauth2/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    -d "assertion=${JWT}")

echo
echo "Response:"
echo "${RESP}" | python3 -m json.tool

ACCESS_TOKEN=$(echo "${RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))")
INSTANCE_URL=$(echo "${RESP}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('instance_url',''))")

if [ -z "${ACCESS_TOKEN}" ]; then
    echo
    echo "FAILED — no access token returned" >&2
    exit 1
fi

echo
echo "OK — got access token. Calling /services/data/v66.0/sobjects/Demo_Session__c..."
curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    "${INSTANCE_URL}/services/data/v66.0/query/?q=SELECT+Id,Name,State__c+FROM+Demo_Session__c" \
    | python3 -m json.tool
