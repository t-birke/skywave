#!/usr/bin/env bash
# Generate a self-signed RSA 2048 keypair for the Skywave_Heroku_Relay
# Connected App's JWT-bearer flow. Idempotent — refuses to overwrite
# an existing key without --force.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets"
KEY_FILE="${SECRETS_DIR}/jwt.key"
CRT_FILE="${SECRETS_DIR}/jwt.crt"
SUBJECT="/C=US/ST=CA/L=San Francisco/O=Skywave/OU=Interactive/CN=skywave-heroku-relay"

force=0
for arg in "$@"; do
    case "$arg" in
        --force|-f) force=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

mkdir -p "${SECRETS_DIR}"

if [ -f "${KEY_FILE}" ] && [ "${force}" -ne 1 ]; then
    echo "Refusing to overwrite ${KEY_FILE}. Pass --force to regenerate." >&2
    echo "Regenerating means re-uploading the new ${CRT_FILE} to the" >&2
    echo "Skywave_Heroku_Relay Connected App and updating Heroku config." >&2
    exit 1
fi

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${KEY_FILE}" \
    -out "${CRT_FILE}" \
    -days 3650 \
    -subj "${SUBJECT}" \
    >/dev/null 2>&1

chmod 600 "${KEY_FILE}"
chmod 644 "${CRT_FILE}"

echo "Generated:"
echo "  ${KEY_FILE}  (private key, gitignored, 600)"
echo "  ${CRT_FILE}  (public cert, safe to commit inside Connected App metadata)"
echo
echo "Next steps:"
echo "  1) Embed the public cert in the Connected App metadata:"
echo "     base64 -i ${CRT_FILE} | pbcopy   # then paste into the .connectedApp-meta.xml certificate field"
echo "  2) Push the private key to Heroku as a config var:"
echo "     heroku config:set SF_JWT_PRIVATE_KEY=\"\$(cat ${KEY_FILE})\" -a skywave-app"
echo "  3) Never commit ${KEY_FILE}."
