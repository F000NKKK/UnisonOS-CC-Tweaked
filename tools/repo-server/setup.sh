#!/usr/bin/env bash
# One-shot installer for the UnisonOS package + OS mirror on a Debian/Ubuntu VPS.
# No nginx/Caddy: just python3 + systemd, HTTP on 9273, HTTPS on 9274.
#
# Usage (as root):
#     export UNISON_DOMAIN=apps.example.com   # optional, only used for self-signed CN
#     curl -fsSL https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/tools/repo-server/setup.sh | bash
#
# Replace the cert at /etc/unison/server.{crt,key} with your real one if you
# have it. Otherwise this script generates a self-signed cert valid for 10 y.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo bash setup.sh)" >&2
    exit 1
fi

DOMAIN="${UNISON_DOMAIN:-unison.local}"
REPO_RAW="${UNISON_REPO_RAW:-https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/tools/repo-server}"

echo "[1/6] installing system packages..."
apt-get update -y
apt-get install -y python3 git curl openssl ca-certificates

echo "[2/6] creating user, dirs and self-signed cert..."
id -u unison >/dev/null 2>&1 || useradd --system --home /srv/unison --shell /usr/sbin/nologin unison
install -d -o unison -g unison -m 0755 /srv/unison
install -d -o root   -g unison -m 0750 /etc/unison

if [ ! -f /etc/unison/server.crt ] || [ ! -f /etc/unison/server.key ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/unison/server.key \
        -out    /etc/unison/server.crt \
        -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1
    chown root:unison /etc/unison/server.{crt,key}
    chmod 0640 /etc/unison/server.{crt,key}
    echo "  -> generated self-signed cert for CN=${DOMAIN}"
else
    echo "  -> reusing existing cert at /etc/unison/server.crt"
fi

echo "[3/6] downloading server scripts..."
curl -fsSL "$REPO_RAW/serve.py"               -o /usr/local/bin/unison-serve.py
curl -fsSL "$REPO_RAW/unison-sync.sh"         -o /usr/local/bin/unison-sync.sh
curl -fsSL "$REPO_RAW/unison-server.service"  -o /etc/systemd/system/unison-server.service
curl -fsSL "$REPO_RAW/unison-sync.service"    -o /etc/systemd/system/unison-sync.service
curl -fsSL "$REPO_RAW/unison-sync.timer"      -o /etc/systemd/system/unison-sync.timer
chmod +x /usr/local/bin/unison-serve.py /usr/local/bin/unison-sync.sh

echo "[4/6] opening ports in ufw (if installed)..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 9273/tcp || true
    ufw allow 9274/tcp || true
fi

echo "[5/6] enabling services..."
systemctl daemon-reload
systemctl enable --now unison-sync.timer
systemctl enable --now unison-server.service

echo "[6/6] running first sync..."
sudo -u unison /usr/local/bin/unison-sync.sh || {
    echo "first sync failed — check 'journalctl -u unison-sync.service'" >&2
    exit 1
}
systemctl restart unison-server.service

IP="$(curl -fsSL https://api.ipify.org || echo '<server-ip>')"
echo
echo "Done."
echo "  HTTP:  http://${IP}:9273/manifest.json"
echo "  HTTPS: https://${IP}:9274/manifest.json   (self-signed; replace at /etc/unison/)"
echo
echo "  In CC:Tweaked:"
echo "      wget run http://${IP}:9273/installer.lua"
echo
echo "  Logs:    journalctl -fu unison-server"
echo "  Sync:    journalctl -u  unison-sync"
