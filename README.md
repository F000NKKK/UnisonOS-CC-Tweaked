# UnisonOS

Distributed operating system for the CC:Tweaked stack (Minecraft 1.21.1).
Runs on Computers, Turtles, Pocket Computers, and drives Monitors. Devices
talk to each other through an HTTP/WebSocket message bus hosted on a
self-hostable VPS, and share a server-side world atlas (blocks, landmarks,
events, A* pathfinding) so the cluster behaves as one machine.

## Status (current: 0.31.1)

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
| 14    | GDI graphics layer + stdio I/O unification                  | done   |
| 15    | Home points, selection volumes, surveyor pocket app         | done   |
| 16    | Dispatcher service + mine worker daemon + auto-park         | done   |
| 17    | Parallel sector mining (split volume across N workers)      | done   |
| 18    | Universal fuel-help courier protocol (any turtle)           | done   |
| 19    | Dispatcher dashboard tab (queue / workers / fuel-help)      | done   |
| 20    | Cross-world isolation (X-World-Id namespacing on the bus)   | done   |

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

    master  = { secret = "CHANGE_ME" },

    -- Cross-world isolation. If multiple MC worlds talk to the same bus,
    -- give each a distinct id so devices don't see each other. Can also
    -- be set at runtime via the `world` shell command (state file at
    -- /unison/state/world.json overrides this config entry).
    -- world_id = "alpha",

    -- Dispatcher: enable on one machine to orchestrate mine workers
    dispatcher = false,
    -- dispatcher_id = "12",            -- override discovery; usually not needed
    -- kind = "mining",                 -- mine worker kind filter (on turtle)
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
| `home`        | Manage home point: `show / here / set X Y Z [F] [label] / label / clear` |
| `select`      | WorldEdit-style selection: `list/new/use/show/p1/p2/expand/contract/shift/slice/queue/cancel/rm` |
| `kind`        | Get / set this turtle's worker kind (`mining / farming / any / clear`) |
| `world`       | Get / set the bus world_id (cross-world isolation) — `world alpha` / `world clear` |
| `fuel`        | Inspect fuel + coal, broadcast fuel-help, manual courier deliver |
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

## Output pipeline (GDI + stdio)

UnisonOS separates three concerns that were previously entangled:

```
Physical hardware
  └─ display service        shadow-buffer multiplexer, letterbox, 20 Hz flush
       └─ GDI (lib/gdi)     drawing primitives over any term-target
            └─ stdio         text I/O — lazy-resolved, always hits the multiplex
```

**Display** (`unison/services/display.lua`) manages the physical monitors via
`term.redirect(multiplex)` and paints deltas at 20 Hz. Every other module
writes into the multiplex through GDI or stdio, never directly to `term`.

**GDI** (`unison/lib/gdi/`) is a portable drawing layer similar to Win32 GDI:

| Module          | Provides                                                  |
|-----------------|-----------------------------------------------------------|
| `gdi/context`   | `Context` object — pen/brush/cursor state, save/restore   |
| `gdi/shapes`    | `fillRect`, `rect`, `hLine`, `vLine`, `line` (Bresenham), `frame` |
| `gdi/text`      | `drawText`, `drawTextRect`, `drawBlit`, `measureText`     |
| `gdi/bitmap`    | Off-screen cell buffer; `blitTo(dstCtx, x, y)`           |
| `gdi/blit`      | `bitBlt(src, dstCtx, dstX, dstY)` — one blit call per row |
| `gdi/init`      | Entry: `gdi.screen()`, `gdi.fromTarget(t)`, `gdi.bitmap(w,h)` |

**stdio** (`unison/lib/stdio.lua`) provides `Stream` objects for text I/O.
A stream with `t = nil` is *live*: it resolves `term.current()` at each call
so it always writes to the active multiplex target. Streams can also be
anchored to an explicit target for off-screen rendering.

```lua
local out = stdio.stdout()   -- live stream, follows display.start redirect
out:writeln("hello")
out:printf("%d items", n)
```

The `buffer.lua`, `canvas.lua`, and all kernel/shell output modules write
through GDI or stdio — there is one source of truth and no render conflicts.

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

A package manifest can declare `min_platform = "0.27.0"` and UPM refuses
to install on older OSes. Push package updates as often as you like;
only bump the OS for real platform changes.

### Built-in apps

Default registry (`apps/registry.json`):

| Package     | Latest  | Notes                                               |
|-------------|---------|-----------------------------------------------------|
| `mine`      | 3.0.3   | Sector miner + worker daemon. Auto-home on first start, slot blacklist, fuel-help broadcast when stranded. `mine worker` subscribes to the dispatcher, auto-parks via `nav.goTo`, digs, returns home. (`mine-worker` service starts this automatically on every turtle.) |
| `surveyor`  | 1.3.0   | Pocket selection editor (26×20 portrait). Now shows per-sector progress `[in_progress 2/4]` for parallel-mining jobs. Auto-syncs from the dispatcher every 5 s. |
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

## Home points

Every device can record a *home point* — the position + facing it should
return to after finishing a job.

```
home                          # show current home point
home here                     # set to current GPS position
home set 100 64 -200 [F] [label]   # manual coordinates (F = 0..3)
home label "Sorting hub"      # rename without moving
home clear                    # remove
```

A home set via `home here` or `home set` is *explicit* and is never
automatically overwritten by packages. `mine worker` uses the home point to
park the turtle between assignments; if no home is set it falls back to the
GPS position at daemon start.

Home data is stored in `/unison/state/home.json` and exposed in the heartbeat
so the web console and dispatcher always know where each turtle lives.

## Selection volumes and the dispatcher

### WorldEdit-style selections

```
select new "north-pit"        # create a named draft selection
select p1                     # set corner 1 to current GPS position
select p2                     # set corner 2 to current GPS position
select expand u 5             # grow up by 5 blocks
select contract d 2           # shrink from below by 2
select shift e 3              # translate east by 3
select slice y 16             # subdivide into 16-block Y layers
select queue                  # send to dispatcher
select cancel                 # withdraw from the queue
select show                   # print dimensions and state
select list                   # list all saved selections
```

Selections persist to `/unison/state/selections/` as JSON. Each selection
tracks a state machine: `draft → queued → in_progress → done | cancelled`.
The full edit history (p1/p2 sets, expansions, shifts) is preserved.

### Dispatcher service

Enable the dispatcher on one machine (usually a stationary computer near
the mine):

```lua
-- /unison/config.lua
dispatcher = true
```

Then `service restart dispatcher` (or reboot). The dispatcher:

1. Watches the selection queue (via `selection_queue` RPC).
2. Discovers idle `mine worker` turtles via their heartbeat (kind, fuel,
   coal, position, home, busy flag).
3. **Splits each selection across N idle workers** along the longest
   horizontal axis — N turtles mine in parallel. Each gets `mine_assign`
   with its own sub-volume.
4. Filters workers by **estimated fuel cost** for their slice (manhattan
   to corner + slice volume + return-home, with a ×1.5 safety multiplier
   plus a 200-fuel floor). Underfuelled workers are skipped this tick.
5. **Retries failed sub-selections** up to 3 times with a different
   worker. Permanent failure marks the parent `partial`.
6. Broadcasts `dispatcher_announce` every 30 s so workers self-register
   without config.

Workers register with the dispatcher automatically on `dispatcher_announce`
or at daemon start. No manual ID wiring required.

### Auto-start, kind, and home on turtles

The OS ships three pieces to make this seamless:

* **`mine-worker` service** — auto-starts `mine worker` on every turtle
  that has `mine` installed. No need to run `mine worker` by hand.
* **`kind` shell command** — sets the turtle's kind tag persistently
  (`/unison/state/worker.json`):
  ```
  kind mining     # or "farming", "any"
  kind clear
  ```
* **Auto-home** — the worker daemon snapshots GPS at first start as
  `set_by="auto"` so dispatcher routing works without manual setup.
  `home here` on the turtle promotes it to an explicit (sticky) home.

### End-to-end workflow

1. **Mark volume** — open `surveyor` on a pocket computer, set P1/P2
   (GPS-here or manual), adjust with expand/slice, tap **Queue**.
2. **Dispatcher splits + assigns** — within ≤5 s the dispatcher counts
   N idle workers with enough fuel, splits the volume into N sectors,
   and sends `mine_assign` to each turtle in parallel. Surveyor shows
   `[in_progress 0/N]`.
3. **Each turtle parks and mines** — `mine worker` calls `nav.goTo` to
   auto-park at its sector's corner, aligns facing, digs layer by layer.
4. **Done** — each turtle reports `mine_done { ok=true }` and becomes
   idle. Surveyor counter advances `[in_progress N/N]` → `[done]`.
   Failed sectors are retried automatically (up to 3 attempts each).

### Universal fuel-help courier

Any turtle (mining, farming, patrol, scanner, or plain shell) can both
**request** fuel-help when stranded and **respond** as a courier. The
fuel-bus service runs on every turtle by default:

```
[turtle-3 /]$ fuel               # show local fuel + coal in inventory
fuel: 1234
coal in inventory: 64 items

[turtle-3 /]$ fuel help          # broadcast fuel_help_request
fuel_help_request broadcast.

[computer-0 /]$ fuel deliver 100 64 -200   # manual courier dispatch
fuel_courier broadcast → (100,64,-200). First idle turtle with coal will deliver.
```

When the dispatcher sees a `fuel_help_request`, it picks any idle turtle
with ≥16 coal and enough fuel for the round trip and sends a
point-to-point `fuel_courier`. If none qualifies, it broadcasts so any
turtle on the bus can self-elect. The courier flies above the target
(via `nav.goTo`), `dropDown`s the coal, and returns home.

`mine`'s `waitForRefuel` automatically calls `lib.fuel.requestHelp()`
when its chest is empty — no manual intervention needed.

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
| Dispatcher | Live queue (with parts progress + Cancel), workers (fuel/coal/position/home/stranded), fuel-help requests. Reads `metrics.dispatcher` from the dispatcher node's heartbeat. |
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
| `dispatcher`    | Selection dispatcher: splits queued volumes across N idle workers in parallel. Enabled only when `config.dispatcher = true`. |
| `mine-worker`   | Auto-starts `mine worker` on any turtle that has `mine` installed. |
| `fuel`          | Universal fuel-bus courier (any turtle): subscribes to `fuel_courier` RPC and ferries coal to stranded peers. |
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
0            computer   0.30.0  2s    computer-0
3            turtle     0.30.0  1s    turtle-3
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
atlas / home / selection / nav / discovery / fuel / stdio / gdi`. The TUI
framework (`unison.ui.{buffer,wm,widgets}`) is also unconditional but
lazy-loaded.

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
  lib/
    fs, http, json, semver, path, kvstore, cli, app, fmt,
    gps, scrollback, turtle, atlas, canvas
    stdio.lua            lazy-resolved text I/O streams
    home.lua             home point get/set/clear + GPS capture
    selection.lua        Volume + Selection AABB + state machine
    nav.lua              GPS-probe facing + axis-aligned goTo + dig tunneling
    discovery.lua        broadcast announce/lookup for service discovery
    fuel.lua             universal fuel-help (request/clear/coalCount/deliver)
    gdi/                 GDI graphics: context, shapes, text, bitmap, blit
  crypto/                sha256, hmac
  net/                   transport, protocol, auth, enroll, router, netd
  pm/                    UPM internals (sources, registry, installer)
  rpc/                   HTTP+WS bus client
  services/
    display.lua          monitor shadow-buffer service
    dispatcher.lua       parallel selection-splitter + worker dispatcher
    fuel.lua             universal fuel-bus courier (every turtle)
    rpcd.lua             HTTP/WS RPC daemon
    ...
  services.d/            declarative service unit files (dispatcher, fuel, mine-worker)
  cron.d/                cron unit drop directory (initially empty)
  ui/                    TUI buffer / window manager / widgets / desktop / apps
  shell/
    shell.lua            REPL
    commands/            built-in commands (incl. home, select, kind, fuel)
  state/
    home.json            home point (written by `home` command / lib.home)
    worker.json          kind override (written by `kind` command)
    mine-config.json     mine slot blacklist
    selections/          saved selection JSON files
    dispatcher.json      dispatcher queue + assignment + fuel-help state
    discovery.json       service discovery cache
tools/
  build-manifest.py      OS hash generator (run before commit)
  repo-server/           VPS-side server kit (HTTP/HTTPS/WS/WSS + atlas)
```

## License & contact

MIT-spirit; do whatever you want. Bug reports / PRs welcome at
[github.com/F000NKKK/UnisonOS-CC-Tweaked](https://github.com/F000NKKK/UnisonOS-CC-Tweaked).
