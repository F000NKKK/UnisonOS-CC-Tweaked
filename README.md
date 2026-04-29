# UnisonOS

Distributed operating system for the CC:Tweaked stack (Minecraft 1.21.1).
Runs on Computers, Turtles, Pocket Computers, and drives Monitors.

Network is built around a master node, with rednet over a mix of
ender-modems (long range, e.g. turtles) and wireless modems (local nodes).

## Status

**Phase 1 — Bootstrap & kernel.** A device can boot UnisonOS, detect its
role, run a cooperative scheduler, and provide a built-in shell. No network,
package manager, or metrics yet — those land in later phases.

| Phase | Scope                                              | Status      |
|-------|----------------------------------------------------|-------------|
| 1     | Installer, kernel, IPC, log, shell                 | in progress |
| 2     | Crypto, transport, signed protocol, enrollment     | pending     |
| 3     | Package manager (GitHub), `mine` app migration     | pending     |
| 4     | Metrics + monitor dashboard                        | pending     |
| 5     | Create-bridge (redstone/inventory) + RPC           | pending     |

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
