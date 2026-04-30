#!/usr/bin/env bash
# Pulls UnisonOS-CC-Tweaked and (optionally) UnisonOS-Apps into /srv/unison so
# Caddy can serve them as a mirror.  Idempotent — safe to run from cron/timer.

set -euo pipefail

ROOT="${UNISON_ROOT:-/srv/unison}"
OS_REMOTE="${UNISON_OS_REMOTE:-https://github.com/F000NKKK/UnisonOS-CC-Tweaked.git}"
APPS_REMOTE="${UNISON_APPS_REMOTE:-https://github.com/F000NKKK/UnisonOS-Apps.git}"
OS_BRANCH="${UNISON_OS_BRANCH:-master}"
APPS_BRANCH="${UNISON_APPS_BRANCH:-master}"

mkdir -p "$ROOT"

sync_repo() {
    local name="$1" remote="$2" branch="$3"
    local target="$ROOT/$name"
    if [ -d "$target/.git" ]; then
        git -C "$target" fetch --quiet origin "$branch"
        git -C "$target" reset --hard --quiet "origin/$branch"
    else
        rm -rf "$target"
        git clone --quiet --depth 1 --branch "$branch" "$remote" "$target"
    fi
}

sync_repo os "$OS_REMOTE" "$OS_BRANCH"

# apps repo is optional — skip silently if unreachable
if git ls-remote --quiet "$APPS_REMOTE" >/dev/null 2>&1; then
    sync_repo apps "$APPS_REMOTE" "$APPS_BRANCH"
fi

# Caddy expects /srv/unison/<repo>/<file> URLs to map directly.  We also expose
# a top-level manifest.json + installer.lua via a stable path for installers.
ln -sfn "$ROOT/os/manifest.json"    "$ROOT/manifest.json"
ln -sfn "$ROOT/os/installer.lua"    "$ROOT/installer.lua"
ln -sfn "$ROOT/os/disk_startup.lua" "$ROOT/disk_startup.lua"
ln -sfn "$ROOT/os/dashboard"        "$ROOT/dashboard"

echo "[unison-sync] $(date -Is) ok"
