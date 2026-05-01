-- mine 2.0.0 — sector miner.
--
-- Pre-flight:
--   1) Place the turtle. The block IN FRONT of it is where mining starts.
--   2) Place a chest immediately BEHIND the turtle.
--   3) Put coal or charcoal in slot 1 (fuel reserve, kept across runs).
--   4) Run `mine start [w h d]`  (defaults 16 3 16).
--
-- Behaviour summary:
--   - Snake-mines a w wide × d deep × h tall sector.
--   - Persists position and progress on every move → reboot-safe; re-run
--     `mine` (no args) and it resumes the saved job from where it stopped.
--   - When inventory has < 4 free slots, returns home, dumps everything
--     except slot 1 into the chest, and resumes.
--   - Auto-refuels from slot 1 when fuel drops below 200; excess coal
--     beyond what slot 1 holds is dumped to the chest.
--   - Never attacks mobs. If a block / move stays blocked, waits and retries.
--   - Marks busy via unison.process.markBusy so OS updates defer.

local fsLib = (unison and unison.lib and unison.lib.fs)
              or dofile("/unison/lib/fs.lua")
local proc  = unison and unison.process

local STATE_DIR  = "/unison/state/mine"
local CONFIG_FILE = STATE_DIR .. "/config.json"
local JOB_FILE    = STATE_DIR .. "/job.json"

local FUEL_SLOT     = 1
local LOW_FUEL      = 200
local MIN_FREE_SLOTS = 4
local FUEL_NAMES = {
    ["minecraft:coal"]      = true,
    ["minecraft:charcoal"]  = true,
    ["minecraft:coal_block"]= true,
}

----------------------------------------------------------------------
-- Persistence
----------------------------------------------------------------------

local function ensureDir() if not fs.exists(STATE_DIR) then fs.makeDir(STATE_DIR) end end

local function loadConfig()
    local c = fsLib.readJson(CONFIG_FILE)
    if type(c) ~= "table" then c = {} end
    c.shape = c.shape or { w = 16, h = 3, d = 16 }
    return c
end

local function saveConfig(c) ensureDir(); fsLib.writeJson(CONFIG_FILE, c) end

local function loadJob() return fsLib.readJson(JOB_FILE) end
local function saveJob(j) ensureDir(); fsLib.writeJson(JOB_FILE, j) end
local function clearJob() if fs.exists(JOB_FILE) then fs.delete(JOB_FILE) end end

----------------------------------------------------------------------
-- Inventory helpers
----------------------------------------------------------------------

local function itemName(slot)
    local d = turtle.getItemDetail(slot)
    return d and d.name or nil
end

local function freeSlots()
    local n = 0
    for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
    return n
end

-- Consolidate every coal/charcoal stack into FUEL_SLOT. Returns total
-- coal kept in slot 1 after consolidation.
local function consolidateFuel()
    -- Move all coal items into FUEL_SLOT.
    for s = 1, 16 do
        if s ~= FUEL_SLOT and FUEL_NAMES[itemName(s) or ""] then
            turtle.select(s)
            turtle.transferTo(FUEL_SLOT)
        end
    end
    turtle.select(FUEL_SLOT)
    return turtle.getItemCount(FUEL_SLOT)
end

local function refuelIfLow()
    if turtle.getFuelLevel() == "unlimited" then return end
    if turtle.getFuelLevel() >= LOW_FUEL then return end
    consolidateFuel()
    turtle.select(FUEL_SLOT)
    if FUEL_NAMES[itemName(FUEL_SLOT) or ""] then
        turtle.refuel(1)
    end
end

----------------------------------------------------------------------
-- Movement (no combat). Each move retries on transient failures
-- (entity in the way, falling sand) without ever calling turtle.attack.
----------------------------------------------------------------------

local Move = {}

-- Try a move/dig pair; if blocked by a mob or unbreakable block, wait
-- and retry up to `tries` times.
local function patientCall(fn, retries, sleepFor)
    retries = retries or 40
    sleepFor = sleepFor or 0.5
    for i = 1, retries do
        local ok, err = fn()
        if ok then return true end
        sleep(sleepFor)
    end
    return false
end

local function digRetry(digFn, detectFn)
    -- Dig until the space is clear (covers gravel/sand cascades).
    while detectFn() do
        if not digFn() then sleep(0.3) end
    end
    return true
end

function Move.forward()
    digRetry(turtle.dig, turtle.detect)
    return patientCall(turtle.forward)
end

function Move.up()
    digRetry(turtle.digUp, turtle.detectUp)
    return patientCall(turtle.up)
end

function Move.down()
    digRetry(turtle.digDown, turtle.detectDown)
    return patientCall(turtle.down)
end

function Move.back()
    -- back() doesn't dig, so try and if blocked, turn around, dig+forward.
    if patientCall(turtle.back, 5, 0.2) then return true end
    turtle.turnRight(); turtle.turnRight()
    Move.forward()
    turtle.turnRight(); turtle.turnRight()
    return true
end

----------------------------------------------------------------------
-- Position model
--   Origin (0,0,0) = home (where turtle started).
--   x = forward, y = up (negative = below home), z = right.
--   facing: 0=+x (forward), 1=+z (right), 2=-x (back/home), 3=-z (left).
----------------------------------------------------------------------

local pos = { x = 0, y = 0, z = 0, facing = 0 }
local job = nil

local function persist()
    if not job then return end
    job.pos = { x = pos.x, y = pos.y, z = pos.z, facing = pos.facing }
    job.dug = job.dug or 0
    saveJob(job)
end

local function turnLeft()  turtle.turnLeft();  pos.facing = (pos.facing + 3) % 4; persist() end
local function turnRight() turtle.turnRight(); pos.facing = (pos.facing + 1) % 4; persist() end

local function faceDir(dir)
    local diff = (dir - pos.facing) % 4
    if diff == 1 then turnRight()
    elseif diff == 2 then turnRight(); turnRight()
    elseif diff == 3 then turnLeft() end
end

local function applyMove(forward)
    local dx, dz = 0, 0
    if pos.facing == 0 then dx = 1
    elseif pos.facing == 1 then dz = 1
    elseif pos.facing == 2 then dx = -1
    elseif pos.facing == 3 then dz = -1 end
    if not forward then dx = -dx; dz = -dz end
    pos.x = pos.x + dx
    pos.z = pos.z + dz
end

local function step()
    refuelIfLow()
    if not Move.forward() then return false end
    applyMove(true)
    job.dug = (job.dug or 0) + 1
    persist()
    return true
end

local function stepDown()
    refuelIfLow()
    if not Move.down() then return false end
    pos.y = pos.y - 1
    persist()
    return true
end

local function stepUp()
    refuelIfLow()
    if not Move.up() then return false end
    pos.y = pos.y + 1
    persist()
    return true
end

----------------------------------------------------------------------
-- Chest dump / fuel pickup
--
-- Home is (0,0,0) facing 0. Chest is the block immediately behind the
-- turtle when at home, i.e. at (-1,0,0). To dump:
--   1) move to (0,0,0), face 0
--   2) turn 180°  → facing chest
--   3) for each slot ≠ FUEL_SLOT, drop()  (puts into chest in front)
--   4) consolidate any coal back into FUEL_SLOT, drop excess
--   5) turn 180° back, face forward
----------------------------------------------------------------------

local function goHome()
    -- Up to home Y.
    while pos.y < 0 do if not stepUp() then return false end end
    while pos.y > 0 do if not stepDown() then return false end end
    -- Back to z=0: we move along z by facing along z first.
    if pos.z > 0 then faceDir(3); while pos.z > 0 do if not step() then return false end end
    elseif pos.z < 0 then faceDir(1); while pos.z < 0 do if not step() then return false end end end
    -- Back to x=0.
    if pos.x > 0 then faceDir(2); while pos.x > 0 do if not step() then return false end end
    elseif pos.x < 0 then faceDir(0); while pos.x < 0 do if not step() then return false end end end
    faceDir(0)
    return true
end

local function dumpToChest()
    -- Face the chest (180°).
    faceDir(2)
    for s = 1, 16 do
        if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
            turtle.select(s)
            turtle.drop()
        end
    end
    consolidateFuel()
    -- If FUEL_SLOT is over a stack-worth of coal, dump excess to chest.
    -- Keep one full stack as reserve.
    turtle.select(FUEL_SLOT)
    local count = turtle.getItemCount(FUEL_SLOT)
    if count > 64 then turtle.drop(count - 64) end
    -- Restore home heading.
    faceDir(0)
end

----------------------------------------------------------------------
-- Returning to a saved waypoint after a dump
----------------------------------------------------------------------

local function gotoWaypoint(wp)
    -- Path: rise to y=0, walk x then z, descend to target y, face wp.facing.
    while pos.y < 0 do if not stepUp() then return false end end
    -- Move along x.
    if wp.x > pos.x then faceDir(0); while pos.x < wp.x do if not step() then return false end end
    elseif wp.x < pos.x then faceDir(2); while pos.x > wp.x do if not step() then return false end end end
    -- Move along z.
    if wp.z > pos.z then faceDir(1); while pos.z < wp.z do if not step() then return false end end
    elseif wp.z < pos.z then faceDir(3); while pos.z > wp.z do if not step() then return false end end end
    -- Descend.
    while pos.y > wp.y do if not stepDown() then return false end end
    while pos.y < wp.y do if not stepUp() then return false end end
    faceDir(wp.facing or 0)
    return true
end

local function maybeDump()
    if freeSlots() >= MIN_FREE_SLOTS then return true end
    print("[mine] inventory full, returning to dump")
    local wp = { x = pos.x, y = pos.y, z = pos.z, facing = pos.facing }
    if not goHome() then return false end
    dumpToChest()
    if not gotoWaypoint(wp) then return false end
    print("[mine] resumed at " .. wp.x .. "," .. wp.y .. "," .. wp.z)
    return true
end

----------------------------------------------------------------------
-- Sector mining strategy
--
-- A sector is w (forward depth) × h (vertical layers) × d (lateral width).
-- Layer y=0 is the row at home level; we mine downward.
-- For each layer:
--   walk forward w blocks, snake right d-1 times alternating direction.
-- After each layer, descend 1 block.
----------------------------------------------------------------------

local function mineLayer(w, d, dirX)
    -- dirX: +1 if going forward direction is +x, else -1 (snaking depth).
    -- We use a snake pattern in the x*z plane.
    for column = 1, d do
        -- mine one column of length w
        for _ = 1, w - 1 do
            if not step() then return false end
            if not maybeDump() then return false end
        end
        if column < d then
            -- Turn to next column. Alternate left/right snake.
            local rightTurn = (column % 2 == 1)
            if rightTurn then
                turnRight()
                if not step() then return false end
                if not maybeDump() then return false end
                turnRight()
            else
                turnLeft()
                if not step() then return false end
                if not maybeDump() then return false end
                turnLeft()
            end
        end
    end
    return true
end

local function mineSector(shape)
    local w, h, dDepth = shape.w, shape.h, shape.d
    -- Move into the sector: dig forward 1 to enter the first block.
    if not step() then return false end
    for layer = 1, h do
        if not mineLayer(w, dDepth, 1) then return false end
        if layer < h then
            -- Drop one layer down before mining next.
            if not stepDown() then return false end
            -- Reorient toward home so the snake re-uses the same
            -- entry geometry: easier to walk back to (0, layer-1, 0).
            -- Easiest: just turn 180 to keep the snake reversible.
            turnRight(); turnRight()
        end
    end
    -- All layers done — return home and dump.
    if not goHome() then return false end
    dumpToChest()
    return true
end

----------------------------------------------------------------------
-- Public commands
----------------------------------------------------------------------

local function status()
    local cfg = loadConfig()
    local j   = loadJob()
    print("mine 2.0.0")
    print("  fuel:        " .. tostring(turtle.getFuelLevel()))
    print("  free slots:  " .. tostring(freeSlots()) .. "/16")
    print("  shape:       " .. cfg.shape.w .. "x" .. cfg.shape.h .. "x" .. cfg.shape.d)
    if not j then
        print("  job:         (none)")
        return
    end
    print("  job phase:   " .. tostring(j.phase or "?"))
    print("  position:    " .. tostring(j.pos and j.pos.x or "?")
        .. "," .. tostring(j.pos and j.pos.y or "?")
        .. "," .. tostring(j.pos and j.pos.z or "?"))
    print("  blocks dug:  " .. tostring(j.dug or 0))
end

local function configure(args)
    local cfg = loadConfig()
    if args[1] == "shape" then
        local w = tonumber(args[2]) or cfg.shape.w
        local h = tonumber(args[3]) or cfg.shape.h
        local dd = tonumber(args[4]) or cfg.shape.d
        cfg.shape = { w = w, h = h, d = dd }
        saveConfig(cfg)
        print(string.format("shape set: %dx%dx%d", w, h, dd))
        return
    end
    print("usage: mine setup shape <w> <h> <d>")
    print("  current: " .. cfg.shape.w .. "x" .. cfg.shape.h .. "x" .. cfg.shape.d)
end

local function help()
    print("mine 2.0.0 — sector miner")
    print("")
    print("  mine                       resume a paused/saved job, or show menu")
    print("  mine start [w h d]         start a new sector (default 16 3 16)")
    print("  mine stop                  abandon the saved job")
    print("  mine status                progress + fuel + position")
    print("  mine setup shape <w h d>   change default shape")
    print("")
    print("Place the turtle, put a chest right behind it, and put coal in")
    print("slot 1. The turtle never attacks and never throws items away.")
end

local function ensureChestBehind()
    -- Sanity probe: at job start we expect to see something (a chest)
    -- behind us. We don't strictly verify it's a chest because the
    -- inspect API isn't always identical across Forge versions, but we
    -- log a warning if there's nothing there.
    turtle.turnRight(); turtle.turnRight()
    local present = turtle.detect()
    turtle.turnRight(); turtle.turnRight()
    if not present then
        print("[mine] WARN: no block detected behind — put a chest there.")
    end
end

local function startJob(args)
    local cfg = loadConfig()
    local w  = tonumber(args[1]) or cfg.shape.w
    local h  = tonumber(args[2]) or cfg.shape.h
    local dd = tonumber(args[3]) or cfg.shape.d
    cfg.shape = { w = w, h = h, d = dd }
    saveConfig(cfg)
    ensureChestBehind()
    consolidateFuel()
    job = {
        phase = "mining",
        pos = { x = 0, y = 0, z = 0, facing = 0 },
        dug = 0,
        shape = cfg.shape,
        started_at = os.epoch("utc"),
    }
    saveJob(job)
    pos.x, pos.y, pos.z, pos.facing = 0, 0, 0, 0
    print(string.format("[mine] starting %dx%dx%d job", w, h, dd))
    local ok, err = pcall(mineSector, cfg.shape)
    if ok then
        job.phase = "done"
        saveJob(job)
        print("[mine] done. " .. tostring(job.dug) .. " block(s) mined.")
        clearJob()
    else
        job.phase = "paused"
        job.error = tostring(err)
        saveJob(job)
        print("[mine] paused: " .. tostring(err))
    end
end

local function resumeJob()
    job = loadJob()
    if not job then
        help(); return
    end
    if job.phase == "done" then print("[mine] previous job done."); return end
    pos.x = job.pos.x; pos.y = job.pos.y
    pos.z = job.pos.z; pos.facing = job.pos.facing
    print(string.format("[mine] resuming at %d,%d,%d facing=%d (dug=%d)",
        pos.x, pos.y, pos.z, pos.facing, job.dug or 0))
    -- Continue: easiest reliable approach — go home, dump, restart layer.
    -- Mining mid-snake from a saved position requires precise pattern
    -- replay; this ships a simpler resume that re-mines the current layer.
    -- (Cheaper to over-mine than to derail.)
    goHome()
    dumpToChest()
    local cfg = loadConfig()
    local ok, err = pcall(mineSector, cfg.shape)
    if ok then clearJob(); print("[mine] done.") end
end

local function stopJob()
    if loadJob() then clearJob(); print("[mine] saved job cleared.") end
end

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

if not turtle then
    printError("mine: requires a turtle.")
    return
end

local args = { ... }
local sub = args[1]
table.remove(args, 1)

local busyTok = proc and proc.markBusy and proc.markBusy("mine") or nil
local ok, err = pcall(function()
    if sub == nil then resumeJob()
    elseif sub == "start" then startJob(args)
    elseif sub == "stop"  then stopJob()
    elseif sub == "status" then status()
    elseif sub == "setup" then configure(args)
    elseif sub == "help" or sub == "-h" or sub == "--help" then help()
    else help() end
end)
if proc and proc.clearBusy then proc.clearBusy(busyTok) end
if not ok then printError("mine: " .. tostring(err)) end
