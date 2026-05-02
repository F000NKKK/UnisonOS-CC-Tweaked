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
> dispatch a turtle there with `mine_assign`. Wait. Process logs into
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

### `mine` — sector miner + worker daemon (3.0.3)

**Direct mining (one-shot)**

* `mine_order`   — `{ xEnd, yEnd, zEnd }` (signed; sign chooses
                   forward/back/up/down/left/right). Reply
                   `{ ok, dug, ts, err? }`.
* `mine_status`  — `{}` → `{ ok, phase, pos, dug, shape, fuel }`
* `mine_abort`   — `{}` → `{ ok }`. Drops a flag file; the running
                   miner returns home, dumps, and exits at the next
                   safeStep tick.

**Worker daemon (dispatcher-driven)**

Auto-started by the `mine-worker` system service on every turtle that
has `mine` installed (no need to run `mine worker` by hand). The daemon:

1. Auto-snapshots its GPS as `home.set(... by="auto")` on first start
   if no home is set.
2. Announces itself via `worker_register` (with `kind`, `fuel`, `coal`,
   `position`, `home`).
3. On `mine_assign { selection_id, volume }`: parks at the volume's
   top-north-west corner via `nav.goTo`, faces +x, digs layer by layer.
4. On completion sends `mine_done { selection_id, ok=true }` and
   `worker_idle`. On failure: `mine_done { ok=false, err }` — the
   dispatcher retries the slice up to 3 times.

**Slot blacklist** (3.0.3): `dumpToChest` preserves slots listed in
`unison.config.mine.protected_slots = {2, 3}` or in the state file
`/unison/state/mine-config.json`. FUEL_SLOT (1) is always protected.

**Auto-fuel-help** (3.0.3): when the chest behind home is empty,
`waitForRefuel` calls `lib.fuel.requestHelp()` so any turtle on the
bus carrying coal can be courier-dispatched.

Mine writes to the atlas continuously: every dig logs an event
(`kind = "dig" | "dig_up" | "dig_down" | "job_start" | "job_done" |
"job_paused"`) with world coords.

### `dispatcher` — parallel selection orchestrator (built-in service)

Enable on one machine (`config.dispatcher = true`). The dispatcher
splits each queued selection across N idle workers along the longest
horizontal axis and assigns each sub-volume to one turtle.

**Splitting & assignment**

When a selection is queued, the dispatcher:

1. Counts idle, non-stale, kind-matching workers.
2. Splits the volume into `min(N, longestAxisLength)` slices (X-major
   if `dx ≥ dz`, else Z-major).
3. Estimates required fuel per slice as
   `(distToCorner + sliceVolume + corner→home) × 1.5 + 200`.
4. Filters out workers below the per-slice fuel estimate.
5. Sends `mine_assign` to each picked worker. Sub-selections are
   tracked with `parent_id`; the parent moves to `done` when all
   parts succeed, `partial` if any fail permanently.

**Retry**: on `mine_done { ok=false }` the sub-selection's `retries`
counter is bumped. Up to `MAX_RETRIES = 3` the slice is re-queued and
the next tick picks a different worker.

**Outbound (dispatcher → worker)**

* `mine_assign`   — `{ selection_id, volume:{min,max}, name, return_home }`.
                    Worker auto-parks and starts digging. Reply:
                    `mine_assign_reply { ok, err? }`.
* `mine_abort`    — `{}`. Abort current job; worker returns home.

**Inbound (worker → dispatcher)**

* `worker_register` — `{ kind, fuel, coal?, position, home, capabilities }`.
                       Called at worker start (or on `dispatcher_announce`).
* `worker_idle`     — `{ position, fuel, coal? }`. Worker finished or aborted.
* `worker_busy`     — `{ position, fuel, coal? }`. Worker started job.
* `mine_done`       — `{ selection_id, ok, err? }`. Triggers retry on failure.

**Inbound (surveyor / shell → dispatcher)**

* `selection_queue`  — `{ selection }` → `{ ok, id }`.
* `selection_cancel` — `{ id }` → `{ ok }`. Aborts all sub-selections.
* `selection_list`   — `{}` → `{ ok, selections, workers }`. Returns
                        top-level entries with `parts_total / parts_done /
                        parts_failed` aggregates per parent. Sub-selections
                        are not exposed individually.

**Fuel-help**

* `fuel_help_request` — point-to-point picks a courier with coal+fuel,
                         falls back to broadcast.
* `fuel_help_clear`   — worker self-rescued; drops the help entry.

**Broadcast (dispatcher → all)**

* `dispatcher_announce` — fire-and-forget every 30 s. Workers that miss
                           the initial register window self-register
                           on receipt.

### `fuel` — universal fuel-help courier (built-in service, every turtle)

Lives in `unison/services/fuel.lua` + `unison/services.d/fuel.lua`.
Independent of `mine` / `farm` / `patrol` — every turtle role runs it.
Backed by `lib.fuel`.

**Inbound (anyone → turtle)**

* `fuel_courier` — `{ target_pos, target_id?, amount }` →
                    `fuel_courier_reply { ok, err?, dropped? }`.
                    Turtle validates: own fuel ≥ `manhattan(self, target)
                    × 2 + 200`, own coal ≥ `amount`. If valid: `nav.goTo`
                    above target, `dropDown` coal items, return home.
                    If invalid: replies with `ok=false`.

**Outbound (any turtle → bus)**

* `fuel_help_request`  — `{ fuel, position, amount?, reason? }` →
                          `fuel_reply { ok }`. Broadcast when stranded.
                          Dispatcher (or any peer's fuel service) picks
                          the closest courier.
* `fuel_help_clear`    — `{}` → `fuel_reply { ok }`. Cancel a previous
                          request after self-rescue.

**Heartbeat fields used by the dispatcher's courier picker**

```json
{ "metrics": { "coal": 32, "fuel": 1234, "position": {...}, "home": {...} } }
```

`metrics.coal` is reported by **every** turtle (read by `lib.fuel.coalCount`).

### `surveyor` — pocket selection editor (1.3.0)

A standalone phone-form-factor app (26×20 cells, portrait).
Does not expose RPC handlers; sends `selection_queue` / `selection_cancel`
to the dispatcher found via discovery.

**Screens**

| Screen  | Purpose                                           |
|---------|---------------------------------------------------|
| LIST    | Named selections list + `[+ NEW]` button          |
| DETAIL  | P1/P2 coords, dimensions, volume, state, actions  |
| AXIS    | Six fat axis buttons (N/S/E/W/U/D) for expand etc.|
| NUM     | 10-key numpad + backspace + sign toggle           |
| NAME    | Inline text input for selection name              |
| CONFIRM | Yes/No confirmation (queue, cancel, delete)       |

**GPS integration**

A live GPS strip below the title bar shows current position (250 ms poll).
`[HERE]` buttons on the DETAIL screen set P1/P2 from the GPS cache
(blocking 2 s locate fallback when cache is stale). Requires GPS towers
in range or HTTP-GPS via the bus.

**Dispatcher sync**

Every 5 s surveyor calls `selection_list` from the dispatcher and merges
the returned states back into local storage (queued / in_progress / done /
partial). `dispatcher_announce` triggers an immediate sync nudge.

**Progress display (1.3.0)**: when the dispatcher splits a selection,
the surveyor LIST screen shows `[in_progress 2/4]` (parts_done /
parts_total) and the DETAIL screen adds a `parts: N/M done (K failed)`
line in yellow.

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

**Home point handlers (built-in)**

* `home_get`   — `{}` → `{ ok, home: {x,y,z,facing,label,explicit}? }`.
                 Returns the stored home point or `nil`.
* `home_set`   — `{ x, y, z, facing?, label?, explicit? }` → `{ ok }`.
                 Persists to `/unison/state/home.json`.
* `home_clear` — `{}` → `{ ok }`. Removes the home point.

Home data is also included in every heartbeat snapshot under `metrics.home`.

**Selection handlers (built-in via rpcd)**

Forwarded to `lib.selection`:

* `selection_queue`  — `{ selection }` → `{ ok, selectionId }` (if a
                        local dispatcher is not running; else forwarded).
* `selection_cancel` — `{ selectionId }` → `{ ok }`.
* `selection_list`   — `{}` → `{ ok, selections }`.

**Dispatcher announce (built-in via rpcd)**

* `dispatcher_announce` — fire-and-forget (no reply). rpcd calls
  `lib.discovery.announce("dispatcher", from)` on receipt, updating
  the local discovery cache so the next `discovery.lookup("dispatcher")`
  returns immediately.

## Library APIs

### `lib.home`

```lua
local home = require "unison.lib.home"

home.get()                         -- { x,y,z,facing,label,explicit } or nil
home.position()                    -- { x,y,z } or nil (no facing/label)
home.set(coord, opts)              -- coord={x,y,z,facing?}, opts={label?,explicit?}
home.setFromGps(opts)              -- capture GPS + facing; never overwrites explicit
home.clear()
home.isExplicit()                  -- true if set via home_set or home here
```

### `lib.selection`

```lua
local sel = require "unison.lib.selection"

-- Volume (AABB)
local v = sel.volume({x=0,y=64,z=0}, {x=15,y=80,z=15})
v:dimensions()          -- {x=16, y=17, z=16}
v:blockCount()          -- 4352
v:contains(x,y,z)
v:expand("u", 5)        -- grow up by 5 (in-place)
v:contract("d", 2)
v:shift("e", 3)
local slices = v:slice("y", 16)   -- returns list of sub-Volumes

-- Selection (named, persistent, state-machine)
local s = sel.Selection.new({ name="pit", owner="pocket-1" })
s:setP1(0, 64, 0)
s:setP2(15, 80, 15)
s:queue()               -- draft → queued
s:setState("in_progress")
s:save()                -- writes /unison/state/selections/<id>.json

sel.Selection.list()    -- { id, name, state, ... }[]
sel.Selection.load(id)
sel.Selection.active()  -- currently active selection or nil
sel.Selection.setActive(id)
```

### `lib.nav`

GPS-probe facing detection and axis-aligned movement for turtles.

```lua
local nav = require "unison.lib.nav"

-- Detect current world facing (0=+z, 1=-x, 2=-z, 3=+x)
local f = nav.facing()                  -- probes GPS, steps, compares, backs up

-- Turn to face a world axis
nav.faceAxis("+x")                      -- also accepts "-x", "+z", "-z"

-- Walk to target coords (axis-aligned: X → Z → Y)
nav.goTo({ x=100, y=64, z=-200 }, {
    dig    = true,   -- tunnel through blocks
    timeout = 60,    -- seconds
})
-- returns true, nil on success; false, err on failure
```

`nav.goTo` uses a cached facing value (updated by `nav.facing` and
every `turnLeft` / `turnRight`) so repeated calls don't re-probe GPS.

### `lib.fuel`

Universal fuel-help client + helpers. Available on every device but
most useful on turtles (the only ones with `turtle.getFuelLevel()`).

```lua
local fuel = require "unison.lib.fuel"

fuel.coalCount()                  -- total fuel items in inventory
fuel.firstFuelSlot()              -- slot index of first fuel item or nil

fuel.requestHelp({                -- broadcast fuel_help_request
    position = {x,y,z},           -- optional override
    amount   = 32,                -- optional, hint for couriers
    reason   = "shell",           -- optional, free-form
})

fuel.clearHelp()                  -- cancel a previous request

-- Manual courier delivery (used by services/fuel.lua):
local ok, dropped = fuel.deliver(targetPos, amount)
```

`fuel.FUEL_NAMES` lists item names treated as fuel (coal, charcoal,
coal_block).

### `lib.discovery`

Broadcast-based service discovery. Survives reboots via
`/unison/state/discovery.json`.

```lua
local disc = require "unison.lib.discovery"

-- Announce that this device provides a service
disc.announce("dispatcher", tostring(os.getComputerID()), { extra="data" })

-- Find the first live entry for a kind (stale threshold: 5 min)
local id = disc.lookup("dispatcher")   -- nil if no live entry

-- Find all live entries
local list = disc.list("dispatcher")   -- { {id, extra, ts}, ... }

disc.clear("dispatcher")               -- remove all entries for a kind
```

Workers call `disc.lookup("dispatcher")` at startup. If nil they wait
for `dispatcher_announce` via RPC. The dispatcher calls `disc.announce`
every 30 s (via `announceLoop`).

### `lib.stdio`

Lazy-resolved text I/O streams. The stream's term-target is resolved at
each call so it always writes through whichever target `term.current()`
points to at that moment (i.e. the display multiplex after `display.start`).

```lua
local stdio = require "unison.lib.stdio"

local out = stdio.stdout()      -- live stream
local err = stdio.stderr()      -- live stream, writes in red

out:write("hello ")
out:writeln("world")
out:printf("items: %d\n", n)

-- Anchored to a specific term-target (e.g. a monitor)
local mon = stdio.fromTarget(peripheral.wrap("monitor_0"))
mon:writeln("monitor output")
```

`Stream:print()` delegates to CC's native `print()` when live (so
native scroll handling applies). `Stream:isLive()` returns true when
no target is anchored.

### `lib.gdi`

GDI drawing primitives over any term-target.

```lua
local gdi = require "unison.lib.gdi"

-- Context from the live screen (follows display multiplex)
local ctx = gdi.screen()

-- Context from an explicit target
local ctx = gdi.fromTarget(peripheral.wrap("monitor_0"))

-- Off-screen bitmap (vertex buffer)
local bmp = gdi.bitmap(32, 16)
local bmpCtx = gdi.fromTarget(bmp:target())

-- Drawing (requires shapes + text extensions)
ctx:setPen(colors.white)
ctx:setBrush(colors.black)
ctx:fillRect(1, 1, 20, 10)
ctx:rect(1, 1, 20, 10)
ctx:hLine(1, 5, 20)
ctx:vLine(10, 1, 10)
ctx:drawText(2, 2, "Hello")
ctx:drawTextRect(2, 4, 18, 8, "wrapped long text", "left")

-- Blit off-screen bitmap onto screen
gdi.bitBlt(bmp, ctx, 5, 5)

-- State save/restore
ctx:save()
ctx:setPen(colors.red)
ctx:drawText(1, 1, "temp")
ctx:restore()

-- Context manager
ctx:with(function(c) c:drawText(1, 1, "scoped") end)
```

## Server-side atlas (HTTP, not RPC)

These are queries the dashboard and apps make against the VPS, not
device-to-device messages.

### Blocks

```
POST /api/atlas/blocks   { by, blocks: [{x,y,z,name}, ...] }
GET  /api/atlas/blocks?bbox=x1,y1,z1,x2,y2,z2&kinds=ore_diamond,...&name=&limit=
GET  /api/atlas/stats    → { total, top: [{name,count}, ...] }
```

Lua client: `unison.lib.atlas.recordBlock` / `recordBlocks` /
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
mine 3.0.1's `goHome()`.

### Storage

```
POST /api/atlas/storage   { by, items: [{name, count}, ...] }
GET  /api/atlas/storage?pattern=&device=&name=
```

`POST` replaces a device's entire snapshot atomically. `GET` returns
totals across devices PLUS per-device breakdown. Drives the
dashboard's Storage tab.

## Heartbeat snapshot

`rpcd` sends a heartbeat to `/api/heartbeat` every 5 s. Fields:

```json
{
  "id": "3",
  "role": "turtle",
  "version": "0.27.0",
  "metrics": {
    "fuel": 1234,
    "inventory_used": 4,
    "position": { "x": 100, "y": 64, "z": -200 },
    "mine": { "phase": "dig", "dug": 512 },
    "redstone": { "left": 0, "right": 7 },
    "home": { "x": 98, "y": 64, "z": -198, "facing": 0, "label": "base", "explicit": true },
    "kind": "mining",
    "busy": false
  }
}
```

`home`, `kind`, and `busy` are used by the dispatcher to select workers.

## Conventions

* `lib.app.runService({ busy_on_handler = true, handlers = ... })`
  wraps each handler in `process.markBusy / clearBusy` so OS upgrades
  defer for the duration of the call.
* `unison.rpc.subscribe(type, fn)` is idempotent (drops stale
  handlers first); use it instead of `off + on`.
* Long-running operations stream their progress via
  `lib.atlas.logEvent` rather than chatty replies.
* All terminal output goes through `lib.stdio` or `lib.gdi` — never
  call `term.*` directly from app code. This ensures exactly one source
  of truth through the display multiplex.
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

## End-to-end workflow: surveyor → dispatcher → N mine workers

```
Pocket PC               Computer (dispatcher)        N × Turtle (mine worker)
---------               ---------------------        -----------------------
run surveyor
  set P1, P2
  expand u 10
  [Queue]
   ─── selection_queue ──►
                          counts N idle workers
                          splits volume into N slices
                          (longest of X/Z axis)
                          filters by per-slice fuel
                          ─── mine_assign sub:1 ───► turtle A
                          ─── mine_assign sub:2 ───► turtle B
                          ─── mine_assign sub:N ───► turtle …
                                                      nav.goTo(corner)
                                                      nav.faceAxis("+x")
                                                      dig sector
                          ◄─── mine_done sub:1 ───── turtle A
                                                      (retry on failure ≤3)
                          ◄─── mine_done sub:N ───── turtle …
                          parent.parts_done == N → done

  (5s sync tick)
   ◄── selection_list ────  [done] / [partial K failed]
```

If a turtle runs out of coal in its chest (mine 3.0.3):

```
Stranded turtle X         Computer (dispatcher)      Idle turtle Y
-----------------         ---------------------      -------------
waitForRefuel:
  pullCoalFromChest → 0
  lib.fuel.requestHelp()
   ─── fuel_help_request ──►
                            scan workers w/ coal+fuel
                            ─── fuel_courier ──────► turtle Y
                                                      nav.goTo(above X)
                                                      dropDown coal
                                                      return home
  pullCoalFromChest → 64
  refuel → resume
   ─── fuel_help_clear ────►
```

No configuration of device IDs is required. The dispatcher is discovered
via `dispatcher_announce` broadcast. Worker capabilities (kind, fuel,
coal, home) are derived from the heartbeat. The pocket app never needs
to know which turtle will handle the job, and any turtle (any role) can
serve as a fuel courier.
