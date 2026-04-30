# UnisonOS

Distributed operating system for the CC:Tweaked stack (Minecraft 1.21.1).
Runs on Computers, Turtles, Pocket Computers, and drives Monitors.

Network is built around a master node, with rednet over a mix of
ender-modems (long range, e.g. turtles) and wireless modems (local nodes).

## Status

**Phase 3 — Unison Packet Manager (UPM).** OS now ships only OS primitives
plus UPM. Apps (including `mine`) are fetched from a configurable list of
HTTP sources (default: VPS at `upm.hush-vp.ru`, GitHub raw as fallback).

| Phase | Scope                                              | Status      |
|-------|----------------------------------------------------|-------------|
| 1     | Installer, kernel, IPC, log, shell                 | done        |
| 2     | Crypto, transport, signed protocol                 | done        |
| 3     | UPM, package layout, mine migrated as a package    | done        |
| 4     | Service manager (systemd-style units, supervision) | done        |
| 5.1   | HTTP-RPC via VPS message bus                       | done        |
| 5.2   | Sandboxed apps (permissions enforced)              | done        |
| 5.3   | TUI framework (windows, widgets)                   | done        |
| 6.0   | OS / packages decoupled (min_platform gate)        | done        |
| 6.1   | Cron / scheduled tasks                             | pending     |
| 6.2   | Login + accounts                                   | pending     |

## Network

UnisonOS runs a daemon (`netd`) at boot. It opens every attached modem
(wireless and ender) on channel 4717 and exchanges packets in the
following format:

```
{ v=1, id, from, to, ts, nonce, type, payload, sig }
```

Signatures are HMAC-SHA256 over a canonical serialization of every field
except `sig`. Replays are rejected by a per-sender nonce cache and a
configurable timestamp window (default ±60s).

### Enrollment flow

1. A fresh non-master node generates an enrollment code (8 chars) and shows
   it on screen at boot. It broadcasts an unsigned `ENROLL_REQ` carrying a
   hashed copy of the code every 3 seconds.
2. On master, the admin reads the code from the node's screen and runs
   `enroll <code>`. Master derives `node_key = HMAC(master_secret, node_id)`
   and sends an `ENROLL_ACK` signed with `bootstrap_key = HMAC(code, "...")`.
   The ACK carries `node_key` XOR-streamed against the bootstrap key.
3. The node verifies the ACK signature and decrypts `node_key`, then saves
   it locally. From then on every packet is signed with `node_key`.

`master.secret` (in `/unison/config.lua`) must be set on master before
the first boot.

## Installer disk (auto-updating)

UnisonOS can keep a labelled installer floppy in sync automatically.

1. On any UnisonOS device, attach a Disk Drive (any side) and insert a
   floppy. Set its label to `UnisonOS-Installer` via:

   ```
   label set <side> UnisonOS-Installer
   ```

2. From an existing UnisonOS shell run `diskupdate`, or wait up to 60s for
   the background `disk-updater` service to detect it. The disk is
   populated with `installer.lua`, `manifest.json`, and a smart
   `startup.lua`.
3. The smart `startup.lua` checks the locally installed version against the
   disk's manifest and **only runs the installer when versions differ**, so
   leaving the disk in the drive no longer causes a reinstall loop.

## Install

On a fresh device, paste the contents of `installer.lua` into a Pastebin and
run it. Then on the device:

```
pastebin run <ID>
```

Or, if `wget` is enabled in your CC config:

```
wget run https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/installer.lua
```

The installer will:

1. Fetch `manifest.json`.
2. Detect the device role (turtle / pocket / computer).
3. Download the files needed for that role into `/unison/`.
4. Copy `config.lua.example` to `config.lua` if missing.
5. Write `/startup.lua` so the OS boots automatically.

Reboot to enter UnisonOS.

## Configuration

Edit `/unison/config.lua` after the first install:

- `is_master = true` for exactly one device on the network.
- `node_name` to override the default `<role>-<id>` name.
- `master.secret` — change before the first boot of master.
- `log_level`, `log_to_master`, `auto_update` — sensible defaults are set.

See `unison/config.lua.example` for the full schema.

## Shell

After boot you get a prompt:

```
[turtle-3]$ help
```

Built-in commands (Phase 1):

| Command   | Description                          |
|-----------|--------------------------------------|
| `help`    | List commands or describe one        |
| `version` | Show UnisonOS version and node info  |
| `ps`      | List running processes               |
| `run`     | Run an installed app or .lua file    |
| `kill`    | Terminate a process by PID           |
| `clear`   | Clear the screen                     |
| `reboot`  | Reboot the device                    |
| `netstat` | Modem/transport state, neighbors     |
| `update`  | Check / apply OS update              |
| `diskupdate` | Refresh attached installer disk now |
| `displays` | Manage attached monitors             |
| `upm`     | Install/manage packages              |
| `service` | Manage system services               |
| `devices` | List devices on the message bus      |
| `rsend`   | Send a typed message to a device     |
| `rexec`   | Run a shell command on a remote device |

## Packages (UPM)

UnisonOS ships with `upm`, a tiny HTTP-based package manager. Sources are
defined per device in `/unison/config.lua`:

```lua
pm_sources = {
    "http://upm.hush-vp.ru:9273",
    "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
},
```

Each source serves the registry at `<base>/apps/registry.json` and packages
at `<base>/apps/packages/<name>/<version>/...`. Sources are tried in order;
the first that responds wins.

| Command                  | Effect                                |
|--------------------------|---------------------------------------|
| `upm search <q>`         | search the registry                   |
| `upm info <name>`        | show package details                  |
| `upm install <name>[@v]` | download into `/unison/apps/<name>/`  |
| `upm list`               | installed packages                    |
| `upm remove <name>`      | uninstall                             |
| `upm update [<name>]`    | refresh one or all                    |
| `upm sources`            | show configured sources               |

Run an installed app with `run <name> [args...]`. Apps live in
`/unison/apps/<name>/main.lua` (or whatever `entry` is in their manifest).

### OS vs. package independence

UnisonOS itself and the package catalogue live side-by-side in this repo
but are **versioned and updated independently**:

* `manifest.json` — OS file list, role mapping, OS version. Changes here
  (and only here) ship through `upm upgrade`.
* `apps/registry.json` + `apps/packages/<name>/<ver>/...` — packages.
  Changes here ship through `upm install` / `upm update <name>`. They
  never touch `/unison/*` system code and never trigger a reboot.

Each package manifest may declare `min_platform = "X.Y.Z"`. UPM refuses
to install a package whose `min_platform` is newer than the running OS
and tells the user to `upm upgrade` first. So you can publish app
updates as often as you like without bumping the OS, and the OS only
gets bumped for actual platform changes.

### Sandbox / permissions

Packages run inside a sandbox `_ENV` built from their manifest's
`permissions` list. Without explicit permission, an app only sees the pure-
Lua stdlib, `sleep`, a safe subset of `term`, and `unison.{log, role, node,
id, version, permissions}`. Recognised permissions:

| Permission   | Grants                                              |
|--------------|-----------------------------------------------------|
| `turtle`     | the turtle global (movement, mining, blocks)        |
| `fuel`       | alias for `turtle`                                  |
| `inventory`  | alias for `turtle`                                  |
| `peripheral` | full `peripheral.*`                                 |
| `modem`      | `peripheral.*`, restricted to modems                |
| `redstone`   | `rs` and `redstone` globals                         |
| `gps`        | `gps`                                               |
| `fs`         | full filesystem (`fs.*`)                            |
| `fs.read`    | read-only filesystem                                |
| `http`       | `http.*` (raw HTTP)                                 |
| `rpc`        | `unison.rpc` (the message bus client)               |
| `shell`      | `shell.run`, `shell.openTab`                        |
| `term`       | full `term.*`                                       |
| `all`        | escape hatch — full host environment                |

Ad-hoc Lua files passed to `run /path/to/foo.lua` keep full access (the user
typed them). Sandbox only kicks in for packaged apps.

## Repo layout

See `docs/` for protocol, app format, and security model
(populated as later phases land).

```
installer.lua          # bootstrap (also goes on Pastebin)
manifest.json          # which files belong to which role
unison/
  boot.lua             # entry point
  config.lua.example   # config template
  kernel/              # scheduler, IPC, log, role detection
  shell/               # REPL and built-in commands
  ...                  # net/, crypto/, pm/, metrics/, dashboard/, master/, apps/
```
