# UnisonOS

Distributed operating system for the CC:Tweaked stack (Minecraft 1.21.1).
Runs on Computers, Turtles, Pocket Computers, and drives Monitors. Devices
talk to each other through an HTTP/WebSocket message bus hosted on a
self-hostable VPS, and share a server-side world atlas (blocks, landmarks,
events, A* pathfinding) so the cluster behaves as one machine.

## Status (current: 0.20.3)

| Phase | Scope                                                       | Status |
|-------|-------------------------------------------------------------|--------|
| 1     | Installer, kernel, IPC, log, shell                          | done   |
| 2     | Crypto, transport, signed protocol                          | done   |
| 3     | UPM (package manager), `mine` migrated as a package         | done   |
| 4     | Service manager (systemd-style units, supervision)          | done   |
| 5     | Bus (HTTP+WS), sandbox, TUI framework, monitor mirroring    | done   |
| 6     | OS / packages decoupled, cron, real-time WebSocket          | done   |
| 7     | Web console at `/dashboard/`                                | done   |
| 8     | UniAPI, ACL, lib.turtle, busy-guard, OS auto-updates        | done   |
| 9     | Server-side atlas (SQLite blocks + landmarks + A* + events) | done   |
| 10    | Display: shadow buffer + letterbox + monitor_touch + 20 Hz  | done   |
| 11    | Pixel desktop environment (`desktop` shell command)         | done   |
| 12    | Storage networked snapshots (Create-compatible)             | done   |
| 13    | Redstone / Create-bridge with dashboard control             | done   |

## Quick install

On a fresh CC:Tweaked computer / turtle / pocket:

```
wget run http://upm.hush-vp.ru:9273/installer.lua
reboot
```

The installer fetches `manifest.json`, picks the file set for the device's
role, drops everything into `/unison/`, copies `config.lua.example` to
`config.lua`, and writes `/startup.lua`. Reboot to enter UnisonOS.

After first boot edit `/unison/config.lua` (`pm_sources`, optional auth)
then `reboot`. To enable the bus:

```
apitoken set <bearer-token-from-VPS>
service restart rpcd
```

Verify with `devices` and the web console at `http://<vps>:9273/dashboard/`.

## Configuration

`/unison/config.lua` (full schema in `unison/config.lua.example`):

```lua
return {
    is_master   = false,                 -- exactly one master per network
    node_name   = nil,                   -- override "<role>-<id>"
    log_level   = "INFO",                -- TRACE/DEBUG/INFO/WARN/ERROR
    auto_update = false,                 -- OS upgrades only on `upm upgrade`

    pm_sources = {
        "http://upm.hush-vp.ru:9273",    -- VPS (preferred)
        "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
    },

    rpc_acl = {
        exec       = { "1" },            -- only device #1 can rexec here
        pilot      = { "1", "2" },
        mine_order = { "1", "2" },
    },

    master = { secret = "CHANGE_ME" },
    displays = { mirror_all = true, monitors = {} },
}
```

ACL can also be set/edited at runtime without rebooting via the `acl`
shell command (state file at `/unison/state/acl.json` overrides the
config; rpcd merges the two).

## Shell

```
[turtle-3 /]$ help
```

| Command       | Purpose                                                   |
|---------------|-----------------------------------------------------------|
| `help [c]`    | List commands or describe one                             |
| `version`     | OS version and node info                                  |
| `ps` / `top`  | List kernel processes (with priority / group)             |
| `kill <pid>`  | Terminate a process                                       |
| `cd / ls / pwd / cat / mkdir / rm / mv / cp / touch / tail / nano` | Standard FS ops                |
| `run <a>`     | Run an app or `.lua` path                                 |
| `clear`       | Clear screen                                              |
| `reboot [-f]` | Reboot (defers if a user job is busy unless `-f`)         |
| `hardreset`   | Wipe apps/logs/state, keep auth tokens, reboot            |
| `desktop`     | Launch the pixel-chromed TUI desktop environment          |
| `displays`    | Manage attached monitors (mirror / scale / bg)            |
| `apitoken`    | `set/show/clear` the VPS API token                        |
| `acl`         | Per-device RPC firewall: `list/set/clear/reset`           |
| `upm`         | Package manager (see below)                               |
| `service`     | Manage system services (`list/status/start/stop/restart`) |
| `cron`        | Manage scheduled tasks (cron-expr or interval)            |
| `devices`     | List devices on the VPS message bus                       |
| `gps`         | Diagnostic + locate (vanilla GPS + HTTP-bus fallback)     |
| `gps-tower`   | Configure this PC as a GPS tower                          |
| `gpsnet`      | HTTP-GPS over the bus (`status/up/host/auto/locate/list`) |
| `redstone`    | Read / set redstone IO (incl. Create stress via comparator)|
| `rsend / rexec` | Send / exec on a remote device                          |

## Desktop environment

```
[turtle-3 /]$ desktop
```

A pixel-chromed TUI shell built on the WM. Pure single-key navigation
(no Ctrl combos — CC doesn't expose modifier state). Top bar gradient,
launcher panel with per-app pixel icons, hint strip.

| Key       | Action                                       |
|-----------|----------------------------------------------|
| `Tab`     | Cycle window focus                           |
| `1..9`    | Fast-launch app by index                     |
| `Up/Dn`   | Navigate launcher                            |
| `Enter`   | Open selected app                            |
| `x`       | Close focused app                            |
| `q`       | Quit desktop, back to shell                  |

Built-in apps under `/unison/ui/apps/`:

| App        | Purpose                                          |
|------------|--------------------------------------------------|
| `files`    | Directory browser (Up/Dn/Enter/Backspace)        |
| `procs`    | Live `scheduler.list()` table (R refresh, Del kill) |
| `services` | Service status with state colors                 |
| `logs`     | Tail of `/unison/logs/current.log`               |
| `devices`  | Bus device list                                  |
| `mine`     | Live job progress bar (turtle only)              |
| `gps`      | Self position + bus tower list                   |

Drop a new file under `/unison/ui/apps/<name>.lua` returning
`{ id, title, roles, make(geom) -> window }` to add an app — no kernel
changes needed.

## Packages (UPM)

```
upm search <q>            search the registry
upm info <name>           manifest, version list, min_platform, source
upm install <name>[@v]    download into /unison/apps/<name>/
upm list                  installed packages
upm remove <name>         uninstall (refuses if a dependent is installed)
upm update [<name>]       refresh one or all installed packages
upm upgrade [-y] [-f]     check & apply an OS upgrade (-f: ignore busy)
upm upgrade -d [-y]       refresh attached UnisonOS-Installer disk
upm sources               configured sources, in order
```

### Two-phase upgrade

1. `upm upgrade` stages every CHANGED file under `/unison.staging/`
   and writes `/unison/.pending-commit`, then reboots.
2. `boot.lua` notices the marker, commits the staged files into
   `/unison/`, removes obsolete files, writes `/unison/.version`,
   removes the marker, and reboots once more.

Auth tokens, logs, configs, installed apps, and registry under
`/unison/{state,logs,apps,config.lua}` are preserved across upgrades.

### Incremental updates

`manifest.json` carries SHA-256 checksums per OS file (generated by
`tools/build-manifest.py`). The os-updater hashes each local file and
fetches **only** the ones whose hash differs or is missing. A typical
upgrade with one changed file downloads one file, not the full 100+ tree.

### `min_platform` gate

A package manifest can declare `min_platform = "0.17.0"` and UPM refuses
to install on older OSes. Push package updates as often as you like;
only bump the OS for real platform changes.

### Built-in apps

Default registry (`apps/registry.json`):

| Package     | Latest  | Notes                                               |
|-------------|---------|-----------------------------------------------------|
| `mine`      | 2.5.0   | Sector miner: signed end-coords (6-way), GPS-anchored, fuel/home guard, smart resume (no rework), A* goHome via server, `mine abort` (signal a running miner home), atlas event streaming. |
| `scanner`   | 1.4.0   | Sphere scanner: streams every block to the server-side atlas. |
| `farm`      | 1.3.0   | Auto-harvester: walks a row, harvests crops, replants. lib.turtle-based. |
| `patrol`    | 1.3.0   | Route runner with record/replay/loop. lib.turtle-based. |
| `pilot`     | 1.2.1   | Remote turtle control: shell REPL + dashboard D-pad. |
| `storage`   | 2.0.0   | Wired-modem inventory pool (Create-compatible: Item Vault, Toolbox, Drawers). Streams snapshots to the server-side atlas. |
| `autocraft` | 1.2.0   | Recipe orchestrator on a crafty turtle.             |
| `atlas`     | 1.1.1   | Legacy on-device landmark store (succeeded by server-side atlas). |
| `sysmon`    | 1.0.3   | TUI dashboard: services / devices / log tail.       |

Installed packages also become callable as bare commands: `mine 16 3 16`,
`scanner sphere 16`, `pilot 0`. Use `run <name>` for the explicit form.

## Server-side world atlas

The cluster shares one global world model on the VPS. Turtles stream
observations there; consumers query the API.

Endpoints (under `/api/atlas/`):

| Endpoint                                | Purpose                                  |
|-----------------------------------------|------------------------------------------|
| `POST /atlas/blocks` `{ by, blocks }`   | Bulk upsert                              |
| `GET  /atlas/blocks?bbox=&kinds=&name=` | Query                                    |
| `GET  /atlas/stats`                     | Top-N block names + total count          |
| `GET  /atlas/landmarks`, POST, DELETE   | Named locations with tags                |
| `POST /atlas/events` `{ by, events }`   | Movement / dig / job lifecycle log       |
| `GET  /atlas/events?since=&limit=`      | Recent events ring                       |
| `GET  /atlas/path?from=x,y,z&to=x,y,z`  | A* over passable cells, returns waypoint list |
| `POST /atlas/storage` `{ by, items }`   | Replace this device's storage snapshot   |
| `GET  /atlas/storage?pattern=`          | Aggregate items + per-device breakdown   |

Lua client: `unison.lib.atlas` (batched POST queues, bearer auth picked
up from `/unison/state/api_token`).

## Web console

`http://<vps>:9273/dashboard/` — the cluster's control plane.

| Tab        | Purpose                                                   |
|------------|-----------------------------------------------------------|
| Devices    | Live list with role / version / fuel / inventory / position. Selected-device pane with per-package action presets and a `logs` button that exec-tails `/unison/logs/current.log`. |
| Mine       | Live `mine` job progress per turtle (heartbeat-fed).      |
| Atlas      | Landmarks, indexed-block stats, add/remove via HTTP.      |
| Storage    | Cluster-wide inventory totals + per-device breakdown + per-row `pull 64` button. |
| Redstone   | Per-device IO pills + 0/15 toggle buttons (drives Create stress / motors / trains via `redstone_set` RPC). |
| Pilot      | D-pad remote control: forward/back/up/down/turn/around + dig/place/suck/drop/refuel + slot select. Reply pane shows fuel/inventory. |
| Map        | Top-down world map with device positions AND atlas-block overlay (ores/chests as colored dots). Drag to pan, wheel to zoom. |
| Events     | Live activity feed: every dig / move / job_start / job_done streamed from `/api/atlas/events`. |
| Cron       | Per-device cron units: list / add / run / rm.             |
| Logs       | Activity log + command bar with ↑/↓ history.              |

QoL:
* Toast notifications on key edges (mine done/paused, fuel low/zero).
* Selected device + active tab persisted in localStorage.
* Stale `console-*` entries auto-pruned by the server (5 min TTL).

## Services

Every background unit is declared in `/unison/services.d/<name>.lua`:

```lua
return {
    name = "rpcd",
    description = "HTTP RPC daemon (registers with VPS, polls + WebSocket)",
    enabled = true,
    deps = {},
    restart = "on-failure",   -- no | on-failure | always
    restart_sec = 10,
    pre_start = function(cfg) ... end,
    main      = function(cfg) ... end,
}
```

Built-in units:

| Unit            | Purpose                                                     |
|-----------------|-------------------------------------------------------------|
| `display`       | Shadow-buffer multiplexer, letterbox-paint to monitors at 20 Hz, monitor_touch → mouse_click. |
| `netd`          | Optional local rednet/HMAC stack (legacy).                  |
| `disk-updater`  | Refresh `UnisonOS-Installer` floppies attached to the device. |
| `os-updater`    | Periodic upstream-manifest check; skips if a user job is busy. |
| `rpcd`          | HTTP/WebSocket bus client + ACL gate + busy-defer for OS updates. |
| `gps-host`      | Auto-host GPS coordinates on stationary PCs; reads `gps-host.json`. |
| `crond`         | Scheduled tasks (cron-expr `*/5 * * * *` OR `every_seconds`). |
| `shell`         | Interactive shell.                                          |

`service list / status / start / stop / restart` operate on these.

## Cron

Drop a unit at `/unison/cron.d/<name>.lua`:

```lua
return {
    name = "ping-3",
    description = "Periodically poke turtle 3",
    enabled = true,
    cron = "*/5 * * * *",          -- 5-field cron expr (or every_seconds = 30)
    run_at_boot = true,
    command = "rsend 3 ping",      -- shell command, OR
    -- run = function() ... end,   -- inline Lua
}
```

Or manage from the shell:

```
cron list
cron add hb every:60 "gpsnet pulse"
cron add 5min "*/5 * * * *" "rsend 3 ping"
cron run hb
cron rm hb
```

State (last-run / runs) persisted to `/unison/state/crond.json` so a
reboot doesn't replay everything.

## Message bus

`rpcd` registers the device with the VPS at boot. Once registered every
device shows up in `devices` and is reachable by its `os.getComputerID()`:

```
[mc-pc /]$ devices
ID           ROLE       VER     SEEN  NAME
0            computer   0.20.3  2s    computer-0
3            turtle     0.20.3  1s    turtle-3
```

Send a JSON message:

```
rsend 3 ping
rexec 3 mine 32
```

`rpcd` keeps a WebSocket open to the VPS (port 9275 / 9276) for real-time
delivery and falls back to HTTP polling automatically when the WS is down.
Apps subscribe via `unison.rpc.on(type, fn)` and send via
`unison.rpc.send(target, msg)`.

The bus token (shared with the VPS) is stored at
`/unison/state/api_token`. Manage with `apitoken set/show/clear`.

## Sandbox / permissions

Packaged apps run inside a sandbox `_ENV` built from their `permissions`
list. Recognised permissions:

| Permission   | Grants                                              |
|--------------|-----------------------------------------------------|
| `turtle`     | the turtle global (movement, mining, blocks)        |
| `fuel`       | alias for `turtle`                                  |
| `inventory`  | alias for `turtle`                                  |
| `peripheral` | full `peripheral.*`                                 |
| `modem`      | `peripheral.*`, restricted to modem peripherals     |
| `redstone`   | `rs` and `redstone`                                 |
| `gps`        | `gps`                                               |
| `fs`         | full `fs.*`                                         |
| `fs.read`    | read-only filesystem                                |
| `http`       | `http.*` (raw HTTP)                                 |
| `rpc`        | `unison.rpc` (the message bus client + on/off)      |
| `shell`      | `shell.run`, `shell.openTab`                        |
| `term`       | full `term.*`                                       |
| `all`        | escape hatch — full host environment                |

UniAPI table (`unison.lib.*`) is unconditional: `fs / http / json / semver
/ path / kvstore / canvas / cli / app / fmt / gps / scrollback / turtle /
atlas`. The TUI framework (`unison.ui.{buffer,wm,widgets}`) is also
unconditional but lazy-loaded.

`unison.process.markBusy(name) / clearBusy(token)` lets long-running jobs
declare themselves so the OS-updater defers reboots until they finish.
`run` and most package RPC handlers do this automatically.

## GPS

UnisonOS supports both vanilla CC GPS (4 towers triangulating position
on the wireless rednet channel) AND HTTP-GPS over the bus (devices
publish their position in their heartbeat).

```
gps                          # full diagnostic on this device
gps probe                    # raw PING on ch 65534, list each tower reply
gps locate <id|name>         # bus-side locate
gps-tower <x> <y> <z>        # mark this PC as a tower (auto-syncs gpsnet)
service restart gps-host
```

Important: 4 towers must NOT be coplanar; spread their Y heights by
30+ blocks. The `gps` diagnostic prints the spread and warns when a
fix would be mathematically unstable.

## Self-hosted VPS server

`tools/repo-server/` ships everything needed on a Debian/Ubuntu VPS — no
nginx, no Caddy, just Python 3 + systemd:

* `serve.py` — HTTP on 9273, HTTPS on 9274, WebSocket on 9275 / 9276.
* `atlas_store.py` — SQLite-backed shared world atlas.
* `update-server.sh` — one-liner to pull both files from GitHub and
  restart the service:

```bash
sudo sh -c "$(curl -fsSL https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/tools/repo-server/update-server.sh)"
```

* `unison-cert-issue.sh` — Let's Encrypt cert via Cloudflare DNS-01
  (CC:Tweaked trusts LE out of the box, so HTTPS/WSS work end-to-end).
* `setup.sh` — initial installer.

API auth: drop a token in `/etc/unison/api.token` and put the same
string into each device's `/unison/state/api_token` (via `apitoken set
<token>`).

## Repo layout

```
installer.lua            bootstrap installer
disk_startup.lua         smart /disk/startup.lua deployed to install floppies
manifest.json            OS file list, role mapping, per-file SHA-256
apps/
  registry.json          package catalogue
  packages/<name>/<v>/   per-version files
dashboard/
  index.html             single-page web console
unison/
  boot.lua               entry point + two-phase upgrade committer
  config.lua.example     config template
  kernel/                init, scheduler, ipc, log, role, services, sandbox, process, async
  lib/                   UniAPI: fs, http, json, semver, path, kvstore, canvas, cli, app, fmt, gps, scrollback, turtle, atlas
  crypto/                sha256, hmac
  net/                   transport, protocol, auth, enroll, router, netd
  pm/                    UPM internals (sources, registry, installer)
  rpc/                   HTTP+WS bus client
  services/              service implementations
  services.d/            declarative service unit files
  cron.d/                cron unit drop directory (initially empty)
  ui/                    TUI buffer / window manager / widgets / desktop / apps
  shell/                 REPL and built-in commands
tools/
  build-manifest.py      OS hash generator (run before commit)
  repo-server/           VPS-side server kit (HTTP/HTTPS/WS/WSS + atlas)
```

## License & contact

MIT-spirit; do whatever you want. Bug reports / PRs welcome at
[github.com/F000NKKK/UnisonOS-CC-Tweaked](https://github.com/F000NKKK/UnisonOS-CC-Tweaked).
