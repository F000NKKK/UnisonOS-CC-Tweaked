# UnisonOS App Ecosystem Protocol

All built-in apps speak to each other over the same `unison.rpc` bus.
Each app subscribes to a small set of message types and responds with a
standard reply envelope. A control script can sit on top, e.g.:

> "I need 64 sticks. Craft them. Crafter is short on planks. Ask
> storage for planks. Storage is short. Ask miner for oak logs. Wait.
> Process logs into planks. Resume crafting."

The skeleton below is the contract every app implements.

## Reply envelope

Every reply is `{ type = "<x>_reply", from = "<device-id>", in_reply_to = <id>, ok = bool, err? = string, ... }`.

## Apps and their messages

### `atlas` — landmark / location registry
Request types:
- `atlas_query`  — `{ kind?, name? }` → reply `{ ok, items = [{name, kind, x, y, z, tags}] }`
- `atlas_mark`   — `{ name, kind, x, y, z, tags? }` → reply `{ ok }`
- `atlas_remove` — `{ name }` → reply `{ ok }`

### `storage` — chest aggregator
- `storage_query` — `{ action="list"|"find", pattern? }` → reply `{ ok, items? | slots? }`
- `storage_pull`  — `{ pattern, count?, target? }` → reply `{ ok, moved }`

### `mine` — resource extraction (1.3.0+)
- `mine_order`  — supports mode-aware jobs:
  - shaft: `{ mode="shaft", depth?, ore?/ores?/kind?, vein_limit? }`
  - ore tunnel: `{ mode="ore", ore?/ores?/kind?, length?, vein_limit? }`
  - sector (relative): `{ mode="sector", x1,y1,z1,x2,y2,z2, ore?/ores?/kind?, vein_limit? }`
  - sector (absolute GPS): same as sector + `{ absolute=true }`
  reply: `{ ok, mode, dug, moves, ores?, ts, err? }`
- `mine_status` — `{}` → reply `{ ok, busy, fuel, inventory_used, position, jobs_total, blocks_total, ... }`

### `farm` — crop maintenance (1.0.0+)
- `farm_harvest` — `{ length? }` → reply `{ ok, harvested, replanted }`
- `farm_status`  — `{}` → reply `{ ok, busy, last_run, harvested_total }`

### `autocraft` — recipe orchestrator (1.0.0+)
- `craft_order`  — `{ name, count? }` → reply `{ ok, crafted, missing? }`
- `recipe_list`  — `{}` → reply `{ ok, recipes }`
- `recipe_add`   — `{ name, kind, pattern?, ingredients }` → reply `{ ok }`

## Common conventions

- All apps that subscribe call `unison.rpc.off("<type>")` first to drop
  stale handlers from a previous run.
- Long-running operations report progress via `unison.metric(name, value)`
  (heartbeat carries them) — keeps replies short.
- Apps live wherever makes physical sense (storage on a wired-modem
  hub, mine on turtles, etc.). The bus glues them together.
