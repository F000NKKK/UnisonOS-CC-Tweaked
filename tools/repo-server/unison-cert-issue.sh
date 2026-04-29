#!/usr/bin/env bash
# Issues / renews a real Let's Encrypt cert for the UnisonOS mirror via the
# Cloudflare DNS-01 challenge.

set -euo pipefail

DOMAIN="${UNISON_DOMAIN:?must export UNISON_DOMAIN}"
TOKEN_FILE="${UNISON_TOKEN_FILE:-/etc/unison/cloudflare.token}"
CERT="/etc/unison/server.crt"
KEY="/etc/unison/server.key"
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME="$ACME_HOME/acme.sh"
ACCOUNT_EMAIL="${UNISON_ACME_EMAIL:-acme@${DOMAIN}}"

if [ ! -f "$TOKEN_FILE" ]; then
    echo "missing token at $TOKEN_FILE" >&2
    exit 1
fi

export CF_Token
CF_Token="$(cat "$TOKEN_FILE")"
export HOME=/root

if [ ! -x "$ACME" ]; then
    echo "[cert] installing acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s "email=$ACCOUNT_EMAIL"
fi

# Force Let's Encrypt as the CA (avoids ZeroSSL registration friction).
"$ACME" --home "$ACME_HOME" --set-default-ca --server letsencrypt
"$ACME" --home "$ACME_HOME" --register-account -m "$ACCOUNT_EMAIL" --server letsencrypt 2>/dev/null || true

if "$ACME" --home "$ACME_HOME" --list | awk 'NR>1{print $1}' | grep -qx "$DOMAIN"; then
    echo "[cert] $DOMAIN already issued; checking renewal"
    if ! "$ACME" --home "$ACME_HOME" --cron; then
        echo "[cert] cron renewal returned non-zero; keeping current cert" >&2
    fi
else
    echo "[cert] issuing $DOMAIN"
    "$ACME" --home "$ACME_HOME" --issue -d "$DOMAIN" --dns dns_cf --server letsencrypt
fi

"$ACME" --home "$ACME_HOME" --install-cert -d "$DOMAIN" --ecc \
    --key-file       "$KEY" \
    --fullchain-file "$CERT" \
    --reloadcmd      "systemctl restart unison-server.service"

chown root:unison "$CERT" "$KEY"
chmod 0640 "$CERT" "$KEY"
echo "[cert] installed for $DOMAIN"
