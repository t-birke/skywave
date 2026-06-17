#!/usr/bin/env bash
# Generate a self-signed RSA 2048 keypair for the Skywave_Heroku_Relay
# Connected App's JWT-bearer flow. Idempotent — refuses to overwrite
# an existing key without --force.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets"
KEY_FILE="${SECRETS_DIR}/jwt.key"
CRT_FILE="${SECRETS_DIR}/jwt.crt"
APP_META="${REPO_ROOT}/force-app/main/default/connectedApps/Skywave_Heroku_Relay.connectedApp-meta.xml"
SUBJECT="/C=US/ST=CA/L=San Francisco/O=Skywave/OU=Interactive/CN=skywave-heroku-relay"

force=0
embed=1   # by default, embed the public cert into the Connected App metadata
for arg in "$@"; do
    case "$arg" in
        --force|-f)    force=1 ;;
        --no-embed)    embed=0 ;;
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

# Embed the public cert into the Connected App metadata's <certificate> field.
# The field wants the PEM body with the BEGIN/END lines + all newlines stripped.
if [ "${embed}" -eq 1 ]; then
    if [ ! -f "${APP_META}" ]; then
        echo "WARN: ${APP_META} not found — skipping embed (run with --no-embed to silence)." >&2
    else
        cert_body="$(grep -v 'CERTIFICATE-----' "${CRT_FILE}" | tr -d '\n')"
        CERT_BODY="${cert_body}" APP_META="${APP_META}" python3 - <<'PYEOF'
import os, re
p = os.environ['APP_META']; body = os.environ['CERT_BODY']
s = open(p).read()
new, n = re.subn(r'<certificate>[^<]*</certificate>',
                 '<certificate>%s</certificate>' % body, s, count=1)
if n == 0:
    raise SystemExit('no <certificate> element found in %s' % p)
open(p, 'w').write(new)
print('  embedded public cert into', os.path.relpath(p, os.environ.get('PWD', '.')))
PYEOF
    fi
fi
echo
echo "Next steps:"
echo "  1) Deploy the Connected App so the org gets the new cert:"
echo "     sf project deploy start --source-dir \"${APP_META}\""
echo "  2) Push the private key to Heroku as a config var (Tier 3 does this):"
echo "     heroku config:set SF_JWT_PRIVATE_KEY=\"\$(cat ${KEY_FILE})\" -a <app>"
echo "  3) Never commit ${KEY_FILE} (it's gitignored)."
