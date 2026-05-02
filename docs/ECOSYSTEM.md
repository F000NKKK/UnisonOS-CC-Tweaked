# UnisonOS App Ecosystem Protocol

UnisonOS apps cooperate over two channels:

1. **The bus** — `unison.rpc` for direct device-to-device requests
   (subscribe / send / reply).
2. **The server-side world atlas** — `unison.lib.atlas` for shared,
   persistent state (block index, landmarks, events, item totals,
   A* paths). Apps push observations there and consumers query.

A control script can sit on top of either / both, e.g.:

> "I need 64 sticks. `craft_order` to autocraft. autocraft is short on
> planks. Pull planks from storage via `storage_pull`. Storage is empty.
> Look up nearest oak log in the atlas via `/api/atlas/blocks?kinds=log`,
> dispatch a turtle there with `mine_order`. Wait. Process logs into
> planks. Resume crafting."

## Reply envelope

Every RPC reply is

```
{ type = "<x>_reply",
  from = "<device-id>",
  in_reply_to = <message-id>,
  ok = bool,
  err? = string,
  ... }
```

`unison.rpc.reply(env, payload)` fills in `from` and `in_reply_to`
automatically.

## RPC message types

### `mine` — sector miner (2.5.0)

* `mine_order`   — `{ xEnd, yEnd, zEnd }` (signed; sign chooses
                   forward/back/up/down/left/right). Reply
                   `{ ok, dug, ts, err? }`.
* `mine_status`  — `{}` → `{ ok, phase, pos, dug, shape, fuel }`
* `mine_abort`   — `{}` → `{ ok }`. Drops a flag file; the running
                   miner returns home, dumps, and exits at the next
                   safeStep tick. Same effect as `mine -A` from the
                   shell.

Mine 2.5.0 also writes to the atlas continuously: every dig logs an
event (`kind = "dig" | "dig_up" | "dig_down" | "job_start" |
"job_done" | "job_paused"`) with world coords; each cleared cell is
recorded as `minecraft:air` so the server's A* knows it's traversable.

### `scanner` — sphere scanner (1.4.0)

* `scanner_order`  — `{ radius, ores_only? }` → `{ ok, blocks_added,
                     ores, skipped }`. Streams every observed block
                     (or only ATLAS_KIND if `ores_only=true`) to
                     `lib.atlas.recordBlock`.
* `scanner_status` — `{}` → `{ ok, busy, recorded, ores, position }`

### `farm` — crop maintenance (1.3.0)

* `farm_harvest` — `{ length? }` → `{ ok, harvested, replanted }`
* `farm_status`  — `{}` → `{ ok, busy, last_run, harvested_total,
                   replanted_total }`

### `patrol` — recorded route runner (1.3.0)

* `patrol_run`  — `{ name, loops? }` → `{ ok, steps, err? }`
* `patrol_list` — `{}` → `{ ok, routes }`

### `pilot` — remote-control (1.2.1)

* `pilot` — `{ action, slot?, amount? }` → `{ ok, fuel, inventory?,
            err? }`. Actions: `info`, `forward / back / up / down /
            left / right / around`, `dig / digup / digdown`, `place /
            placeup / placedown`, `suck / drop`, `sel`, `refuel`.
            Used by the dashboard's Pilot tab.

### `storage` — pool aggregator (2.0.0)

* `storage_query`  — `{ action="list"|"find", pattern? }` → `{ ok,
                     items? | slots? }`
* `storage_pull`   — `{ pattern, count?, target? }` → `{ ok, moved,
                     err? }`

Storage 2.0.0 ALSO posts a snapshot of its full pool to
`/api/atlas/storage` every 30 s, so the dashboard sees one merged
item index across the cluster. Compatible with vanilla chests/barrels
AND every Create block exposing IItemHandler (Item Vault, Toolbox,
Storage Drawers).

### `autocraft` — recipe orchestrator (1.2.0)

* `craft_order`  — `{ name, count? }` → `{ ok, crafted, missing?,
                   err? }`. The handler `markBusy`s the device for
                   the run so OS upgrades defer.
* `recipe_list`  — `{}` → `{ ok, recipes }`
* `recipe_add`   — `{ name, kind, pattern?, ingredients }` → `{ ok }`

### `redstone` — IO (built-in to OS)

* `redstone_set` — `{ side, value }` (0..15) → `{ ok, side, value,
                   err? }`. Drives Create stations / motors / item
                   drains from the dashboard. `getAnalogInput` and
                   `getAnalogOutput` are surfaced on every heartbeat
                   under `metrics.redstone`.

### Built-in OS handlers

* `ping` — `{ ts }` → `{ pong, client_ts, ts }`. The dashboard uses
           `client_ts` to compute true wall-clock RTT regardless of
           MC-server clock drift.
* `exec` — `{ command }` → `{ ok, output, err?, command }`. Routes
           through the shell-builtin loader, then `tryApp` for
           installed packages. ACL-gated per type via the `acl`
           shell command and `unison.config.rpc_acl`.

## Server-side atlas (HTTP, not RPC)

These are queries the dashboard and apps make against the VPS, not
device-to-device messages.

### Blocks

```
POST /api/atlas/blocks   { by, blocks: [{x,y,z,name}, ...] }
GET  /api/atlas/blocks?bbox=x1,y1,z1,x2,y2,z2&kinds=ore_diamond,...&name=&limit=
GET  /api/atlas/stats    → { total, top: [{name,count}, ...] }
```

Lua client: `unison.lib.atlas.recordBlock` /  `recordBlocks` /
`queryBlocks` / `stats`.

### Landmarks

```
GET    /api/atlas/landmarks         → { items: [{name,x,y,z,tags,by,ts}, ...] }
POST   /api/atlas/landmarks         { name, x, y, z, tags?, by? }
DELETE /api/atlas/landmarks/<name>
```

Lua client: `unison.lib.atlas.landmarks` / `addLandmark` /
`removeLandmark`.

### Events

```
POST /api/atlas/events   { by, events: [{kind, x, y, z, ts?, ...}, ...] }
GET  /api/atlas/events?since=<ts>&limit=<N>
```

Lua client: `unison.lib.atlas.logEvent` (batched outbound queue).
Powers the dashboard's Events tab.

### Pathfinding

```
GET /api/atlas/path?from=x,y,z&to=x,y,z
```

Server runs A* over known blocks, treating any cell with no record
or an `_air` name as passable. Returns waypoint list. Used by
mine 2.5.0's `goHome()`.

### Storage

```
POST /api/atlas/storage   { by, items: [{name, count}, ...] }
GET  /api/atlas/storage?pattern=&device=&name=
```

`POST` replaces a device's entire snapshot atomically. `GET` returns
totals across devices PLUS per-device breakdown. Drives the
dashboard's Storage tab.

## Conventions

* `lib.app.runService({ busy_on_handler = true, handlers = ... })`
  wraps each handler in `process.markBusy / clearBusy` so OS upgrades
  defer for the duration of the call.
* `unison.rpc.subscribe(type, fn)` is idempotent (drops stale
  handlers first); use it instead of `off + on`.
* Long-running operations stream their progress via
  `lib.atlas.logEvent` rather than chatty replies.
* Heartbeat (`/api/heartbeat` driven by rpcd) carries
  `metrics.{fuel, inventory_used, position, mine, redstone, ...}`
  so the dashboard never has to poll the device for live state.
* Apps live wherever makes physical sense (storage on a wired-modem
  hub, mine on turtles, etc.). The bus and the atlas glue them
  together.

## ACL

Every RPC type can be gated on the receiver. Static rules in
`unison.config.rpc_acl`, runtime overrides via the `acl` shell
command (writes `/unison/state/acl.json`). rpcd merges them with
the state-file winning. Examples:

```
acl set mine_order   allow 5 7      # only nodes 5 and 7 may dispatch
acl set exec         deny 4         # block PC 4 from rexec
acl set scanner_order any           # public scanning
acl set redstone_set deny *         # lock down all remote redstone
```

Format reference:

```lua
rpc_acl = {
    exec       = false,             -- deny everyone
    pilot      = true,              -- allow everyone (default)
    mine_order = "1",               -- allow only device "1"
    storage_pull = { allow = { "1", "2" } },
    redstone_set = { deny  = { "4" } },
}
```
