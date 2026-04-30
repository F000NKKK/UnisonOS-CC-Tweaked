# UnisonOS

Distributed operating system for the CC:Tweaked stack (Minecraft 1.21.1).
Runs on Computers, Turtles, Pocket Computers, and drives Monitors. Devices
talk to each other through an HTTP/WebSocket message bus hosted on a
self-hostable VPS.

## Status (current: 0.7.x)

| Phase   | Scope                                                   | Status   |
|---------|---------------------------------------------------------|----------|
| 1       | Installer, kernel, IPC, log, shell                      | done     |
| 2       | Crypto, transport, signed protocol                      | done     |
| 3       | UPM (package manager), `mine` migrated as a package     | done     |
| 4       | Service manager (systemd-style units, supervision)      | done     |
| 5.1     | HTTP-RPC over a VPS message bus                         | done     |
| 5.2     | Sandboxed apps with permission gating                   | done     |
| 5.3     | TUI framework (windows, widgets, monitor mirroring)     | done     |
| 6.0     | OS / packages decoupled (`min_platform`)                | done     |
| 6.1     | Cron / scheduled tasks                                  | done     |
| 6.2     | WebSocket transport (real-time bus, polling fallback)   | done     |
| 7.x     | Login + accounts, central state backup                  | pending  |

## Quick install

On a fresh CC:Tweaked computer / turtle / pocket:

```
wget run http://upm.hush-vp.ru:9273/installer.lua
reboot
```

(or `pastebin run hmQKeNia` if you keep the installer there).

The installer fetches `manifest.json` from the configured sources, picks
the file set for the device's role (turtle / pocket / computer), drops
everything into `/unison/`, copies `config.lua.example` to `config.lua`,
and writes `/startup.lua`. Reboot to enter UnisonOS.

After first boot edit `/unison/config.lua` (typically: `is_master`,
`master.secret`, optional `pm_sources`), then `reboot`.

## Configuration cheat sheet

`/unison/config.lua` (full schema in `unison/config.lua.example`):

```lua
return {
    is_master   = false,                  -- exactly one master per network
    node_name   = nil,                    -- override "<role>-<id>"
    log_level   = "INFO",                 -- TRACE/DEBUG/INFO/WARN/ERROR
    auto_update = false,                  -- OS upgrades only on `upm upgrade`

    pm_sources = {
        "http://upm.hush-vp.ru:9273",     -- custom VPS first
        "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
    },

    network = {
        protocol = "unison/1",
        heartbeat_interval = 5,
    },

    master = {
        secret = "CHANGE_ME_BEFORE_FIRST_BOOT",  -- HMAC root for enroll
    },

    displays = { mirror_all = true, monitors = {} },
}
```

## Shell

Prompt shows the node name and current working directory:

```
[turtle-3 /]$ help
```

| Command       | Description                                       |
|---------------|---------------------------------------------------|
| `help [c]`    | List commands or describe one                     |
| `version`     | OS version and node info                          |
| `ps`          | List kernel processes                             |
| `kill <pid>`  | Terminate a process                               |
| `cd / ls`     | Change / list directory                           |
| `cat <p>`     | Print a file                                      |
| `tail [-n][-f] <p>` | Tail (with optional follow) a log file      |
| `nano <p>`    | Edit a file with the built-in CC editor           |
| `echo <args>` | Print arguments                                   |
| `run <a>`     | Run an app or `.lua` path                         |
| `clear`       | Clear screen                                      |
| `reboot`      | Reboot                                            |
| `hardreset`   | Wipe apps/logs/state, keep auth tokens, reboot    |
| `netstat`     | Local rednet transport state                      |
| `displays`    | Manage attached monitors (mirror / scale / bg)    |
| `apitoken`    | `set/show/clear` the VPS API token                |
| `upm`         | Package manager (see below)                       |
| `service`     | Manage system services (`list/status/start/stop/restart`) |
| `cron`        | Manage scheduled tasks (`list/run/reload`)        |
| `devices`     | List devices on the VPS message bus               |
| `rsend <id> <type> [k=v]...` | Send a JSON message to a device    |
| `rexec <id> <cmd...>` | Run a shell command on a remote device    |

Installed packages also become callable as bare commands: `sysmon`, `pilot 0`,
`mine 64` — `run` is the explicit form for both packages and ad-hoc files.

### Multi-monitor

UnisonOS auto-discovers every attached monitor at boot and mirrors the
terminal output to all of them by default (the `display` service builds a
multiplexed `term`). Per-monitor settings persist in
`/unison/state/display.lua`:

```
displays list
displays disable monitor_1
displays scale monitor_2 0.5
displays bg monitor_0 black
```

## Packages (UPM)

`upm` is a tiny HTTP-based package manager. Apps live in a separate space
from OS code so they version independently:

```
upm search <q>            search the registry
upm info <name>           manifest, version list, min_platform, source
upm install <name>[@v]    download into /unison/apps/<name>/
upm list                  installed packages
upm remove <name>         uninstall
upm update [<name>]       refresh one or all installed packages
upm upgrade [-y]          check & apply an OS upgrade (with confirmation)
upm upgrade -d [-y]       refresh attached UnisonOS-Installer disk
upm sources               configured sources, in order
```

The OS upgrade is **two-phase**:

1. `upm upgrade` stages every file under `/unison.staging/` and writes a
   `/unison/.pending-commit` marker, then reboots.
2. `boot.lua` notices the marker, commits the staged files into `/unison/`,
   removes obsolete files, writes the new `/unison/.version`, removes the
   marker, and reboots one more time.

This avoids any "the OS is overwriting itself while running" hazard. Auth
tokens, logs, configs, installed apps, and the package registry under
`/unison/{state,logs,apps,config.lua,pm/installed.lua}` are preserved
across upgrades.

### `min_platform` gate

A package manifest can declare:

```lua
return {
    name = "pilot",
    version = "1.0.2",
    min_platform = "0.7.6",
    permissions = { "rpc", "turtle", "fuel", "inventory" },
    files = { "main.lua" },
    entry = "main.lua",
}
```

UPM refuses to install if the running OS is older. Push package updates as
often as you like; only bump the OS for real platform changes.

### UniAPI — `unison.*` exposed to apps

Packaged apps don't `dofile` OS internals; they call into a stable API
that the sandbox builds for them. The default surface (no special perms
required):

| Field                       | What                                       |
|-----------------------------|--------------------------------------------|
| `unison.role / .node / .id` | Device identity                            |
| `unison.version`            | OS version string                          |
| `unison.log`                | TRACE/DEBUG/INFO/WARN/ERROR logger         |
| `unison.ipc`                | Per-process mailboxes                      |
| `unison.kernel.services`    | Read-only service registry                 |
| `unison.ui.{buffer,wm,widgets}` | TUI framework (lazy-loaded)            |
| `unison.lib.fs`             | `read/write/append/ensureDir/deleteIf/list/listAll/readJson/writeJson/readLua/writeLua` |
| `unison.lib.http`           | `get` (cache-bust), `getFromSources`, `post` |
| `unison.lib.json`           | Safe `encode/decode`                       |
| `unison.lib.semver`         | `parse/compare/gte/lte/eq`                 |
| `unison.lib.path`           | `resolve(ctx, raw)` / `absolute(raw)`      |
| `unison.permissions`        | Read-only set of granted permissions       |
| `dofile("/unison/...")`     | Restricted to `/unison/*` paths            |

`unison.rpc` (the message bus client) is added to the table only when
the manifest requests the `rpc` permission; same goes for the rest of
the gated capabilities below.

### Sandbox / permissions

Packaged apps run inside a sandbox `_ENV` built from their `permissions`
list. Without an explicit permission an app only sees pure-Lua stdlib,
`sleep`, a safe subset of `term`/`os`, `printError`, the UniAPI table
above, and the restricted `dofile`.
Recognised permissions:

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
| `rpc`        | `unison.rpc` (the message bus client + `on`/`off`)  |
| `shell`      | `shell.run`, `shell.openTab`                        |
| `term`       | full `term.*`                                       |
| `all`        | escape hatch — full host environment                |

Ad-hoc Lua files passed to `run /path/to/foo.lua` keep full access (you
typed them).

A restricted `dofile` is available regardless: it can `dofile` any
`/unison/*` path so apps can pull in `/unison/ui/wm.lua` etc.

### Built-in apps

Available in `apps/registry.json` (default registry):

* **`mine`** (1.0.1) — vertical mining shaft for turtles.
* **`sysmon`** (1.0.2) — TUI dashboard with three panes: services,
  registered devices on the bus, and a live tail of `/unison/logs/current.log`.
* **`pilot`** (1.0.4) — remote-control a turtle from any computer over the
  bus (forward/back/up/down, dig, place, refuel, sel, info, …). Persists
  per-target command history under `/unison/state/pilot-history-<id>.json`
  via `unison.lib.fs.writeJson`.

## Services

Every background unit is declared in `/unison/services.d/<name>.lua` and
managed by the kernel service manager (similar to systemd):

```lua
return {
    name = "rpcd",
    description = "HTTP RPC daemon (registers with VPS, polls + WebSocket)",
    enabled = true,
    deps = {},
    restart = "on-failure",   -- no | on-failure | always
    restart_sec = 10,
    pre_start = function(cfg) ... end,    -- runs synchronously
    main = function(cfg) ... end,         -- spawned as a kernel coroutine
}
```

Built-in units that ship with the OS:

| Unit            | Purpose                                                      |
|-----------------|--------------------------------------------------------------|
| `display`       | Multi-monitor mirroring                                      |
| `netd`          | Optional local rednet/HMAC stack (legacy)                    |
| `disk-updater`  | Refresh `UnisonOS-Installer` floppies attached to the device |
| `os-updater`    | Periodic upstream-manifest check (idle by default)           |
| `rpcd`          | HTTP/WebSocket message-bus client                            |
| `crond`         | Scheduled tasks from `/unison/cron.d/<name>.lua`             |
| `shell`         | Interactive shell                                            |

`service list / status / start / stop / restart` operate on these.

## Cron

Drop a unit at `/unison/cron.d/<name>.lua`:

```lua
return {
    name = "ping-3",
    description = "Periodically poke turtle 3",
    enabled = true,
    every_seconds = 30,
    run_at_boot = true,
    command = "rsend 3 ping",   -- shell command, OR
    -- run = function() ... end, -- inline Lua
}
```

`cron list / run <name> / reload` from the shell.

## Message bus

`rpcd` registers the device with the VPS at boot. Once registered every
device shows up in `devices` and is reachable by its `os.getComputerID()`:

```
[mc-pc /]$ devices
ID           ROLE       VER     SEEN  NAME
0            computer   0.7.6   2s    computer-0
3            turtle     0.7.6   1s    turtle-3
```

Send a JSON message:

```
[mc-pc /]$ rsend 3 ping
[mc-pc /]$ rexec 3 mine 32
```

`rpcd` keeps a WebSocket open to the VPS (port 9275 / 9276) for real-time
delivery and falls back to HTTP polling automatically when the WS is down.
Apps subscribe via `unison.rpc.on(type, fn)` and send via
`unison.rpc.send(target, msg)`.

The bus token (shared with the VPS) is stored at
`/unison/state/api_token`. Manage with `apitoken set/show/clear`.

## Installer disk (auto-updating)

Any UnisonOS device with an attached Disk Drive holding a floppy labelled
`UnisonOS-Installer` will keep the disk in sync with upstream:

```
label set <side> UnisonOS-Installer
upm upgrade -d           # one-shot refresh, with confirmation
```

The smart `disk/startup.lua` only triggers an installer run on a *fresh*
device (no `/unison/boot.lua` present) and even then asks for an explicit
`yes` before installing or rebooting — leaving the disk in a drive never
loops.

## Self-hosted VPS server

`tools/repo-server/` ships everything needed to host the package and
message-bus endpoints on a Debian/Ubuntu VPS — no nginx, no Caddy, just
Python 3 + systemd:

* `serve.py` — HTTP on 9273, HTTPS on 9274, WebSocket on 9275/9276.
* `unison-sync.{sh,service,timer}` — git-pull the upstream repo into
  `/srv/unison/` every 2 minutes.
* `unison-cert-issue.sh` — Let's Encrypt cert via Cloudflare DNS-01
  (CC:Tweaked trusts LE out of the box, so HTTPS/WSS work end-to-end).
* `setup.sh` — one-shot installer.

```bash
export UNISON_DOMAIN=your.domain.tld
curl -fsSL https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/tools/repo-server/setup.sh | bash
```

API auth (optional): drop a token in `/etc/unison/api.token` and put the
same string into each device's `/unison/state/api_token` (via
`apitoken set <token>`).

See `tools/repo-server/README.md` for the long version.

## Repo layout

```
installer.lua            bootstrap installer (also pinned on Pastebin)
disk_startup.lua         smart /disk/startup.lua deployed to install floppies
manifest.json            OS file list and role mapping
apps/
  registry.json          package catalogue
  packages/<name>/<v>/   per-version files
unison/
  boot.lua               entry point + two-phase upgrade committer
  config.lua.example     config template
  kernel/                init, scheduler, ipc, log, role, services, sandbox
  crypto/                sha256, hmac
  net/                   transport, protocol, auth, enroll, router, netd
  pm/                    UPM internals (sources, registry, installer)
  rpc/                   HTTP+WS bus client
  services/              service implementations (rpcd, crond, ...)
  services.d/            declarative service unit files
  cron.d/                cron unit drop directory (initially empty)
  ui/                    TUI buffer / window manager / widgets
  shell/                 REPL and built-in commands
tools/
  repo-server/           VPS-side server kit
```

## License & contact

MIT-spirit; do whatever you want. Bug reports / PRs welcome at
[github.com/F000NKKK/UnisonOS-CC-Tweaked](https://github.com/F000NKKK/UnisonOS-CC-Tweaked).
