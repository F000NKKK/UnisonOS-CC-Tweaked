#!/usr/bin/env bash
# Issues / renews a real Let's Encrypt cert for the UnisonOS mirror via the
# Cloudflare DNS-01 challenge. CC:Tweaked trusts Let's Encrypt out of the box,
# so this gets HTTPS working on port 9274 even though Cloudflare proxy can't
# forward arbitrary ports.
#
# Prerequisites: a Cloudflare API token with "Zone:DNS:Edit" + "Zone:Zone:Read"
# permissions for your zone, written to /etc/unison/cloudflare.token (chmod 0600).

set -euo pipefail

DOMAIN="${UNISON_DOMAIN:?must export UNISON_DOMAIN}"
TOKEN_FILE="${UNISON_TOKEN_FILE:-/etc/unison/cloudflare.token}"
CERT="/etc/unison/server.crt"
KEY="/etc/unison/server.key"

if [ ! -f "$TOKEN_FILE" ]; then
    echo "missing token at $TOKEN_FILE" >&2
    exit 1
fi

export CF_Token
CF_Token="$(cat "$TOKEN_FILE")"

if [ ! -d /root/.acme.sh ]; then
    echo "[cert] installing acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="acme@${DOMAIN}"
fi

ACME=/root/.acme.sh/acme.sh
"$ACME" --set-default-ca --server letsencrypt

if "$ACME" --list | awk 'NR>1{print $1}' | grep -qx "$DOMAIN"; then
    echo "[cert] renewing $DOMAIN"
    "$ACME" --renew -d "$DOMAIN" --force --dns dns_cf || true
else
    echo "[cert] issuing $DOMAIN"
    "$ACME" --issue -d "$DOMAIN" --dns dns_cf
fi

"$ACME" --install-cert -d "$DOMAIN" \
    --key-file       "$KEY" \
    --fullchain-file "$CERT" \
    --reloadcmd      "systemctl restart unison-server.service"

chown root:unison "$CERT" "$KEY"
chmod 0640 "$CERT" "$KEY"
echo "[cert] installed for $DOMAIN"
