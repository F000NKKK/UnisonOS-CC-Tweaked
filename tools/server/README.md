# Server bootstrap

Файлы для развёртывания UnisonOS-сервера на Ubuntu/Debian.

## Установка

Один раз:

```bash
# репо
git clone https://github.com/F000NKKK/UnisonOS-CC-Tweaked.git /opt/unison
cd /opt/unison

# Node + pnpm
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs nginx
npm i -g pnpm

# зависимости + сборка
pnpm install
pnpm --filter @unison/proto --filter @unison/shared --filter @unison/gateway build

# nginx (статика для миграционных манифестов на :9273)
cat > /etc/nginx/sites-available/unison-static <<'EOF'
server {
  listen 9273 default_server;
  root /opt/unison;
  add_header Cache-Control "no-cache" always;
  location / { autoindex off; }
}
EOF
ln -sf /etc/nginx/sites-available/unison-static /etc/nginx/sites-enabled/unison-static
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# systemd: gateway + auto-update
install -m644 tools/server/unison-gateway.service /etc/systemd/system/
install -m644 tools/server/unison-update.service /etc/systemd/system/
install -m644 tools/server/unison-update.timer   /etc/systemd/system/
chmod +x tools/server/update.sh

systemctl daemon-reload
systemctl enable --now unison-gateway.service
systemctl enable --now unison-update.timer
```

## Что слушает

| Порт | Назначение |
|------|------------|
| 9273 | nginx — `manifest.json` и unison/* для миграции старых ПК |
| 9275 | WS — агенты подключаются сюда |
| 9280 | HTTP — веб-дашборд (`http://host:9280/`) |
| 9290 | gRPC — внешний код |

## Авто-обновления

`unison-update.timer` каждые 5 мин запускает `update.sh`:
* `git fetch`; если HEAD = origin/master — exit;
* иначе `git reset --hard`, `pnpm install`, `pnpm build`, `systemctl restart unison-gateway`.

Лог: `/var/log/unison-update.log` + `journalctl -u unison-update`.

Чтобы выкатить на сервер новую версию — просто пуш в master, через
≤5 минут оно поднимется само. Чтобы запустить вручную сразу:

```bash
systemctl start unison-update
```

## Проверка

```bash
ss -tlnp | grep -E ':(9273|9275|9280|9290)\b'
journalctl -u unison-gateway -n 30 --no-pager
journalctl -u unison-update -n 30 --no-pager
curl -sI http://localhost:9280/                  # дашборд
curl -s   http://localhost:9280/api/devices      # JSON
curl -s   http://localhost:9273/manifest.json | grep version
```
