# UnisonOS — Agent era (1.x)

Однопроцессная архитектура, всё снаружи: CC-устройство держит **тонкий
агент**, всю логику пишет внешний код на любом языке через **gRPC**.

```
┌────────────────┐       gRPC        ┌──────────────────┐    WS+JSON    ┌───────────────┐
│  user code     │ ───────────────▶  │   gateway (Node) │ ────────────▶ │  CC agent     │
│  (TS/Py/Rust…) │ ◀───────────────  │   gRPC ↔ WS bus  │ ◀──────────── │  (Lua)        │
└────────────────┘                   └──────────────────┘               └───────────────┘
```

* **`packages/proto`** — `unison.proto`, единственный публичный контракт.
* **`packages/gateway`** — Node-шлюз, держит WS-пул агентов и переводит
  каждый gRPC-вызов в JSON-RPC по WebSocket.
* **`unison/agent`** — Lua-агент (~250 строк). Резолвит любую точку CC
  API (`turtle.forward`, `peripheral.call`, `fs.list`, …), выполняет в
  pcall, отдаёт результат. Подписки на `os.pullEventRaw` стримятся
  обратно как gRPC server-streaming.
* **`packages/clients`** — примеры на TypeScript и Python.

## Quick start

```bash
# 1. Поднять шлюз
pnpm install
pnpm dev:gateway     # gRPC :9290, WS :9275

# 2. На CC-устройстве — installer для свежих:
wget run https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/installer.lua
edit /unison/agent/config.lua    # gateway_url, world_id, token
reboot

# 3. Из любого языка — пример на TS:
cd packages/clients/ts
pnpm install
pnpm start 1                     # turtle.Forward на устройстве "1"
```

Старые установки переезжают автоматически через текущий upm — см.
[`docs/MIGRATION.md`](docs/MIGRATION.md). Релиз 1.0.0 — **последний**
через manifest. После него обновления приходят только через шлюз.

## Документация

* [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — gateway, WS-протокол, маршрутизация типизированных сервисов.
* [`docs/MIGRATION.md`](docs/MIGRATION.md) — переходный релиз и как удостовериться, что устройство пересобралось.
* `packages/proto/unison.proto` — полный gRPC-контракт.
