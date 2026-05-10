#!/usr/bin/env bash
# UnisonOS server self-update.
#
# Запуск: bash tools/server/update.sh
# Обычно — из systemd timer (см. unison-update.service / .timer).
#
# Алгоритм:
#   1. git fetch + сравнить HEAD с origin/master.
#   2. Если совпадает — выйти (exit 0), ничего не делать.
#   3. Иначе: pull, pnpm install, build только @unison/proto + @unison/shared
#      + @unison/gateway, рестарт unison-gateway.service.
#   4. Логи в journald через systemd unit + локально в /var/log/unison-update.log.

set -euo pipefail

REPO="${UNISON_REPO:-/opt/unison}"
SERVICE="${UNISON_SERVICE:-unison-gateway.service}"
LOG="/var/log/unison-update.log"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

cd "$REPO"

git fetch --quiet origin master

LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/master)

if [[ "$LOCAL" == "$REMOTE" ]]; then
  log "up-to-date at $LOCAL"
  exit 0
fi

log "updating $LOCAL -> $REMOTE"

git reset --hard origin/master >> "$LOG" 2>&1

# pnpm install захватит новые зависимости, если они появились.
pnpm install --silent --prod=false >> "$LOG" 2>&1

# Собираем только то, что нужно gateway'ю.
pnpm --filter @unison/proto --filter @unison/shared --filter @unison/gateway build >> "$LOG" 2>&1

log "rebuilt; restarting $SERVICE"
systemctl restart "$SERVICE"
log "done"
