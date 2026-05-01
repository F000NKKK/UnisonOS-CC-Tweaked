#!/bin/sh
# Pull the latest server-side files from GitHub master and restart the
# systemd unit. Run on the VPS to update without touching anything else.
#
# Usage: sudo sh update-server.sh
set -e

BRANCH="${BRANCH:-master}"
RAW="https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/${BRANCH}/tools/repo-server"
DEST="${DEST:-/usr/local/bin}"
SERVICE="${SERVICE:-unison-server.service}"

echo "[unison] fetching from $RAW"
for f in serve.py atlas_store.py; do
    curl -fsSL "$RAW/$f" -o "$DEST/$f"
    echo "  ok: $DEST/$f"
done

# unison-serve.py is the historic name the service ExecStart points at;
# keep the symlink/alias so existing units keep working.
if [ ! -e "$DEST/unison-serve.py" ] || ! cmp -s "$DEST/serve.py" "$DEST/unison-serve.py"; then
    cp "$DEST/serve.py" "$DEST/unison-serve.py"
    echo "  alias: $DEST/unison-serve.py"
fi

if command -v systemctl >/dev/null 2>&1; then
    echo "[unison] restarting $SERVICE"
    systemctl restart "$SERVICE"
    sleep 1
    systemctl status "$SERVICE" --no-pager -n 10 || true
fi

echo
echo "[unison] testing /api/atlas/stats..."
TOKEN_FILE="${TOKEN_FILE:-/etc/unison/api.token}"
AUTH=""
if [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
    AUTH="-H 'Authorization: Bearer $TOKEN'"
fi
sh -c "curl -s $AUTH http://localhost:9273/api/atlas/stats" \
    || echo "(stats endpoint failed — check service logs)"
echo
echo "[unison] done."
