# UnisonOS package & OS mirror server

A tiny self-hosted mirror that lets your CC:Tweaked devices fetch UnisonOS
and its packages without going through GitHub raw. No nginx, no Caddy —
just Python 3 + systemd.

* **HTTP** on port `9273`
* **HTTPS** on port `9274` (self-signed cert by default; bring your own)

## Quick install (Debian/Ubuntu VPS)

As root:

```bash
export UNISON_DOMAIN=apps.your-domain.tld   # optional, used as cert CN
curl -fsSL https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/tools/repo-server/setup.sh | bash
```

The script:

1. Installs `python3`, `git`, `openssl`.
2. Creates a system user `unison` and `/srv/unison`.
3. Generates a self-signed cert at `/etc/unison/server.{crt,key}` (10 years).
4. Drops `serve.py`, `unison-sync.sh`, plus three systemd units into place.
5. Opens 9273/9274 in `ufw` if you're using it.
6. Enables a 2-minute timer that pulls the latest UnisonOS-CC-Tweaked
   (and optionally UnisonOS-Apps) into `/srv/unison/{os,apps}` and exposes
   `/srv/unison/manifest.json`, `/srv/unison/installer.lua` as symlinks.
7. Starts the HTTP/HTTPS listener.

When it finishes you'll see something like:

```
HTTP:  http://1.2.3.4:9273/manifest.json
HTTPS: https://1.2.3.4:9274/manifest.json
```

## Bringing your own cert

If you have a real Let's Encrypt / DNS-validated cert, put it at
`/etc/unison/server.crt` and `/etc/unison/server.key` (`chown root:unison`,
`chmod 0640`) and `systemctl restart unison-server`. The handler reloads on
start.

## Pointing UnisonOS at your server

In `/unison/config.lua` on each device:

```lua
auto_update = true,

pm = {
    repos = {
        { name = "self",     url = "http://1.2.3.4:9273" },
        { name = "official", url = "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master" },
    },
},
```

CC:Tweaked validates HTTPS certs against Java's truststore, so for now
**use the HTTP port (9273) inside CC** unless you've installed a real cert.
The HTTPS port is fine for browsers and external tooling.

## Files in this directory

| File                       | Where it lands                                  |
|----------------------------|-------------------------------------------------|
| `serve.py`                 | `/usr/local/bin/unison-serve.py`                |
| `unison-server.service`    | `/etc/systemd/system/unison-server.service`     |
| `unison-sync.sh`           | `/usr/local/bin/unison-sync.sh`                 |
| `unison-sync.service`      | `/etc/systemd/system/unison-sync.service`       |
| `unison-sync.timer`        | `/etc/systemd/system/unison-sync.timer`         |
| `setup.sh`                 | run once via `curl | bash` as root              |

## Useful commands

```bash
systemctl status unison-server    # listener
journalctl -fu unison-server      # live access log
journalctl -u  unison-sync        # last sync runs
sudo -u unison /usr/local/bin/unison-sync.sh   # force a sync now
```
