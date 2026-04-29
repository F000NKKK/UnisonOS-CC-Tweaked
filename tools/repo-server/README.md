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

## Real HTTPS via Cloudflare DNS-01 (Let's Encrypt)

CC:Tweaked validates HTTPS against Java's truststore — Cloudflare Origin CA
won't work, but **Let's Encrypt does**. The kit ships an `acme.sh` flow that
solves the DNS-01 challenge through your Cloudflare API token, so you don't
need to expose port 80 or use Cloudflare's proxy:

1. In the Cloudflare dashboard create an API token with:
   - **Permissions:** `Zone : DNS : Edit` and `Zone : Zone : Read`.
   - **Zone resources:** include the zone for your domain.
2. On the VPS:
   ```bash
   sudo install -d -m 0750 -o root -g unison /etc/unison
   echo "<your-token>" | sudo tee /etc/unison/cloudflare.token >/dev/null
   sudo chmod 600 /etc/unison/cloudflare.token
   sudo UNISON_DOMAIN=upm.hush-vp.ru /usr/local/bin/unison-cert-issue.sh
   ```
3. The certificate is installed to `/etc/unison/server.{crt,key}` and the
   server is restarted. A weekly `unison-cert.timer` keeps it renewed.

`setup.sh` will run this automatically if the token file exists at install
time.

If you'd rather drop your own cert in, place it at
`/etc/unison/server.crt` / `server.key` (`chown root:unison`, `chmod 0640`)
and `systemctl restart unison-server`.

## Pointing UnisonOS at your server

UnisonOS already defaults to `http://upm.hush-vp.ru:9273` with GitHub raw
as a fallback. To override, add to `/unison/config.lua`:

```lua
pm_sources = {
    "https://upm.hush-vp.ru:9274",                                                       -- after Let's Encrypt
    "http://upm.hush-vp.ru:9273",
    "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
},
```

The OS-updater, disk-updater, and installer try each source in order and
use the first that responds.

## Files in this directory

| File                       | Where it lands                                  |
|----------------------------|-------------------------------------------------|
| `serve.py`                 | `/usr/local/bin/unison-serve.py`                |
| `unison-server.service`    | `/etc/systemd/system/unison-server.service`     |
| `unison-sync.sh`           | `/usr/local/bin/unison-sync.sh`                 |
| `unison-sync.service`      | `/etc/systemd/system/unison-sync.service`       |
| `unison-sync.timer`        | `/etc/systemd/system/unison-sync.timer`         |
| `setup.sh`                 | run once via `curl | bash` as root              |
| `unison-cert-issue.sh`     | `/usr/local/bin/unison-cert-issue.sh`           |
| `unison-cert.service`      | `/etc/systemd/system/unison-cert.service`       |
| `unison-cert.timer`        | `/etc/systemd/system/unison-cert.timer`         |

## Useful commands

```bash
systemctl status unison-server    # listener
journalctl -fu unison-server      # live access log
journalctl -u  unison-sync        # last sync runs
sudo -u unison /usr/local/bin/unison-sync.sh   # force a sync now
```
