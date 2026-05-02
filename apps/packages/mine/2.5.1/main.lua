-- mine 2.3.0 — sector miner with signed end-coordinates (6 directions).
--
-- Pre-flight:
--   1) Place the turtle. The block IN FRONT is +x (turtle's facing).
--   2) Place the chest BEHIND the turtle (opposite the +x direction).
--      Chest stays at this position regardless of dig direction —
--      with negative xEnd the turtle digs the OTHER way.
--   3) Put coal/charcoal in slot 1.
--   4) Run `mine <xEnd> <yEnd> <zEnd>`. Each can be ± — sign picks
--      direction.
--
-- Coordinate model (relative to home, world-space axes):
--   +x = forward (turtle's start facing)    -x = back  (toward chest!)
--   +y = up                                 -y = down
--   +z = right (90° CW of facing)           -z = left
--
-- Volume = rectangular box 0..xEnd × 0..yEnd × 0..zEnd inclusive.
-- (|xEnd|+1) × (|yEnd|+1) × (|zEnd|+1) blocks total.
--
-- Examples:
--   mine  7  3  7    8x4x8 forward, up, right
--   mine  7 -3  7    8x4x8 forward, DOWN, right     (typical ore mine)
--   mine  7  3 -7    8x4x8 forward, up, LEFT
--   mine  7 -7  7    8x8x8 forward, deep down, right
--
-- WARNING: 'mine -X ...' digs INTO the chest. Don't do that.
--
-- Behaviour:
--   - Persistent state in /unison/state/mine — reboot-safe; just run
--     `mine` (no args) to resume.
--   - Inventory near-full → return home, dump, resume from waypoint.
--   - Fuel-home guard: keeps reserve = manhattan-home * 2 * 1.2 + 100.
--     If unmet, returns home, sucks coal from chest behind, refuels,
--     resumes. If chest empty: waits forever for manual refuel.
--   - Never attacks mobs / never throws items away.
--   - Marks busy via unison.process so OS updates defer.

local fsLib = (unison and unison.lib and unison.lib.fs)
              or dofile("/unison/lib/fs.lua")
local atlas = unison and unison.lib and unison.lib.atlas
local proc  = unison and unison.process

-- Optional GPS-anchored origin so atlas events use world coordinates,
-- not local (0,0,0)-based ones. Computed once at job start; nil → events
-- carry pos relative to home and consumers must combine with origin.
local origin = nil

-- Position model
--   pos.x +forward, pos.y +up, pos.z +right
--   facing: 0=+x, 1=+z, 2=-x, 3=-z
-- Declared up here (before logEvent / recordMinedHere) so those closures
-- pick up the local upvalue at parse time. Previously `local pos` lived
-- below — Lua then resolved `pos` inside logEvent as a global (which is
-- nil), exploding the very first time a GPS-anchored job logged an
-- event ("attempt to index global 'pos' (a nil value)").
local pos = { x = 0, y = 0, z = 0, facing = 0 }
local job = nil

local function logEvent(kind, extra)
    if not (atlas and atlas.logEvent) then return end
    local ev = { kind = kind, x = pos.x, y = pos.y, z = pos.z }
    if origin then
        ev.wx = origin.x + pos.x
        ev.wy = origin.y + pos.y
        ev.wz = origin.z + pos.z
    end
    if extra then for k, v in pairs(extra) do ev[k] = v end end
    atlas.logEvent(ev)
end

local function recordMinedHere(extra)
    -- The block we just stepped into is now air; mark it as such so
    -- the server's path planner knows it's traversable. extra may
    -- carry { name = "minecraft:stone" } captured from inspect before
    -- the dig — useful for ore-tracking.
    if not (atlas and atlas.recordBlock) then return end
    if not origin then return end   -- need world coords
    atlas.recordBlock({
        x = origin.x + pos.x,
        y = origin.y + pos.y,
        z = origin.z + pos.z,
        name = (extra and extra.name) or "minecraft:air",
    })
end

local STATE_DIR  = "/unison/state/mine"
local CONFIG_FILE = STATE_DIR .. "/config.json"
local JOB_FILE    = STATE_DIR .. "/job.json"
local ABORT_FILE  = STATE_DIR .. "/abort.flag"

-- Abort flag — drop a file to request a graceful stop. The next safeStep
-- detects it, returns the turtle home, dumps the load, and exits cleanly.
local function abortRequested() return fs.exists(ABORT_FILE) end
local function clearAbort()    if fs.exists(ABORT_FILE) then fs.delete(ABORT_FILE) end end
local function requestAbort()
    if not fs.exists(STATE_DIR) then fs.makeDir(STATE_DIR) end
    local h = fs.open(ABORT_FILE, "w")
    if h then h.write(tostring(os.epoch("utc"))); h.close() end
end

local FUEL_SLOT       = 1
local FUEL_BASE       = 100
local FUEL_PER_BLOCK  = 2     -- 1 fuel for the move + 1 budget for dig
local FUEL_MARGIN     = 0.20  -- + 20% safety
local FUEL_TOP_UP     = 5000
local MIN_FREE_SLOTS  = 4
local REFUEL_POLL_S   = 15
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
    if not c.shape then c.shape = { xEnd = 15, yEnd = 2, zEnd = 15 } end
    -- Migrate legacy 2.1.x shape { w, h, d } (dimensions) to 2.2.x
    -- { xEnd, yEnd, zEnd } (inclusive end-coords).
    if c.shape.w and not c.shape.xEnd then
        c.shape = {
            xEnd = (tonumber(c.shape.w) or 16) - 1,
            yEnd = (tonumber(c.shape.h) or 3)  - 1,
            zEnd = (tonumber(c.shape.d) or 16) - 1,
        }
    end
    return c
end
local function saveConfig(c) ensureDir(); fsLib.writeJson(CONFIG_FILE, c) end
local function loadJob() return fsLib.readJson(JOB_FILE) end
local function saveJob(j) ensureDir(); fsLib.writeJson(JOB_FILE, j) end
local function clearJob() if fs.exists(JOB_FILE) then fs.delete(JOB_FILE) end end

----------------------------------------------------------------------
-- Inventory
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
local function consolidateFuel()
    for s = 1, 16 do
        if s ~= FUEL_SLOT and FUEL_NAMES[itemName(s) or ""] then
            turtle.select(s); turtle.transferTo(FUEL_SLOT)
        end
    end
    turtle.select(FUEL_SLOT)
    return turtle.getItemCount(FUEL_SLOT)
end

----------------------------------------------------------------------
-- Position model — `pos` and `job` are declared near the top of the
-- file (above logEvent) so atlas closures resolve them as upvalues.
----------------------------------------------------------------------

local function persist()
    if not job then return end
    job.pos = { x = pos.x, y = pos.y, z = pos.z, facing = pos.facing }
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

----------------------------------------------------------------------
-- Fuel
----------------------------------------------------------------------

local function distanceHome()
    return math.abs(pos.x) + math.abs(pos.y) + math.abs(pos.z)
end
local function fuelReserve()
    return FUEL_BASE + math.ceil(distanceHome() * FUEL_PER_BLOCK * (1 + FUEL_MARGIN))
end
local function refuelOne()
    if turtle.getFuelLevel() == "unlimited" then return false end
    consolidateFuel()
    turtle.select(FUEL_SLOT)
    if not FUEL_NAMES[itemName(FUEL_SLOT) or ""] then return false end
    if turtle.getItemCount(FUEL_SLOT) == 0 then return false end
    return turtle.refuel(1) and true or false
end
local function refuelToTopUp()
    if turtle.getFuelLevel() == "unlimited" then return true end
    while turtle.getFuelLevel() < FUEL_TOP_UP do
        if not refuelOne() then break end
    end
    return turtle.getFuelLevel() >= fuelReserve()
end
local function ensureFuel()
    if turtle.getFuelLevel() == "unlimited" then return true end
    while turtle.getFuelLevel() < fuelReserve() do
        if not refuelOne() then return false end
    end
    return true
end

----------------------------------------------------------------------
-- Movement (no combat, dig clears falling sand/gravel)
----------------------------------------------------------------------

local function patientCall(fn, retries, sleepFor)
    retries = retries or 40
    for _ = 1, retries do
        if fn() then return true end
        sleep(sleepFor or 0.5)
    end
    return false
end
local function digRetry(digFn, detectFn)
    while detectFn() do if not digFn() then sleep(0.3) end end
end

local function moveForward() digRetry(turtle.dig,     turtle.detect);     return patientCall(turtle.forward) end
local function moveUp()      digRetry(turtle.digUp,   turtle.detectUp);   return patientCall(turtle.up)      end
local function moveDown()    digRetry(turtle.digDown, turtle.detectDown); return patientCall(turtle.down)    end

local function applyMove()
    local dx, dz = 0, 0
    if pos.facing == 0 then dx = 1
    elseif pos.facing == 1 then dz = 1
    elseif pos.facing == 2 then dx = -1
    elseif pos.facing == 3 then dz = -1 end
    pos.x = pos.x + dx
    pos.z = pos.z + dz
end

-- "fuel" return = soft fail (caller heads home and refuels)
local function step()
    if not ensureFuel() then return "fuel" end
    if not moveForward() then return false end
    applyMove()
    job.dug = (job.dug or 0) + 1
    persist()
    logEvent("dig"); recordMinedHere()
    return true
end
local function stepUp()
    if not ensureFuel() then return "fuel" end
    if not moveUp() then return false end
    pos.y = pos.y + 1
    job.dug = (job.dug or 0) + 1
    persist()
    logEvent("dig_up"); recordMinedHere()
    return true
end
local function stepDown()
    if not ensureFuel() then return "fuel" end
    if not moveDown() then return false end
    pos.y = pos.y - 1
    job.dug = (job.dug or 0) + 1
    persist()
    logEvent("dig_down"); recordMinedHere()
    return true
end

-- Bare versions: best-effort refuel from slot, but never refuse to move.
-- Used by goHome/gotoWaypoint which must work even when fuel is critical.
local function stepBare()      refuelOne(); if not moveForward() then return false end; applyMove(); persist(); return true end
local function stepUpBare()    refuelOne(); if not moveUp()      then return false end; pos.y = pos.y + 1; persist(); return true end
local function stepDownBare()  refuelOne(); if not moveDown()    then return false end; pos.y = pos.y - 1; persist(); return true end

----------------------------------------------------------------------
-- Chest
----------------------------------------------------------------------

-- Walk one cell toward `target` (world coords). Picks the right
-- stepBare variant based on the relative delta. Returns false on any
-- physical block we couldn't dig through.
local function stepTowardWorld(target)
    if not origin then return false end
    local dx = target.x - origin.x - pos.x
    local dy = target.y - origin.y - pos.y
    local dz = target.z - origin.z - pos.z
    if dy > 0  then return stepUpBare()  end
    if dy < 0  then return stepDownBare() end
    if dx == 0 and dz == 0 then return true end
    -- Face the cardinal direction we need.
    if     dx > 0 then faceDir(0)
    elseif dx < 0 then faceDir(2)
    elseif dz > 0 then faceDir(1)
    elseif dz < 0 then faceDir(3)
    end
    return stepBare()
end

-- A* via the server-side atlas. Returns true on success, false to make
-- the caller fall through to the linear walk.
local function goHomeViaPath()
    if not (origin and atlas and atlas.path) then return false end
    local from = { x = origin.x + pos.x, y = origin.y + pos.y, z = origin.z + pos.z }
    local to   = { x = origin.x,         y = origin.y,         z = origin.z }
    local ok, path = pcall(atlas.path, from, to)
    if not ok or type(path) ~= "table" or #path < 2 then return false end
    -- path[1] is the start, path[#path] is the goal. Walk each waypoint.
    for i = 2, #path do
        if not stepTowardWorld(path[i]) then return false end
    end
    faceDir(0)
    return true
end

local function goHome()
    -- Try the server's A* first when we have a GPS-anchored origin.
    -- Falls back to the deterministic linear walk if the server has
    -- no usable path or atlas is unavailable.
    if goHomeViaPath() then return true end
    while pos.y < 0 do if not stepUpBare()   then return false end end
    while pos.y > 0 do if not stepDownBare() then return false end end
    if pos.z > 0 then faceDir(3); while pos.z > 0 do if not stepBare() then return false end end
    elseif pos.z < 0 then faceDir(1); while pos.z < 0 do if not stepBare() then return false end end end
    if pos.x > 0 then faceDir(2); while pos.x > 0 do if not stepBare() then return false end end
    elseif pos.x < 0 then faceDir(0); while pos.x < 0 do if not stepBare() then return false end end end
    faceDir(0)
    return true
end

-- Chest is at the OPPOSITE side of the dig direction. For default xDir=+1
-- the turtle digs +x and the chest is at -x (faceDir(2)). For xDir=-1
-- the chest is at +x (faceDir(0)). We saved xDir into the job at start.
local function chestFacing()
    local xDir = (job and job.xDir) or 1
    return (xDir == 1) and 2 or 0
end

local function dumpToChest()
    faceDir(chestFacing())
    for s = 1, 16 do
        if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
            turtle.select(s); turtle.drop()
        end
    end
    consolidateFuel()
    turtle.select(FUEL_SLOT)
    if turtle.getItemCount(FUEL_SLOT) > 64 then
        turtle.drop(turtle.getItemCount(FUEL_SLOT) - 64)
    end
    faceDir(0)
end

local function pullCoalFromChest()
    faceDir(chestFacing())
    for s = 1, 16 do
        if turtle.getItemCount(s) == 0 then
            turtle.select(s); turtle.suck(64)
        end
    end
    for s = 1, 16 do
        if s ~= FUEL_SLOT and turtle.getItemCount(s) > 0 then
            local n = itemName(s) or ""
            if not FUEL_NAMES[n] then turtle.select(s); turtle.drop() end
        end
    end
    consolidateFuel()
    faceDir(0)
end

local function waitForRefuel()
    print("[mine] fuel low at home; pulling coal from chest first.")
    while true do
        pullCoalFromChest()
        refuelToTopUp()
        if turtle.getFuelLevel() == "unlimited"
           or turtle.getFuelLevel() >= math.max(FUEL_TOP_UP / 2, fuelReserve() * 4) then
            print("[mine] refueled to " .. tostring(turtle.getFuelLevel()))
            return true
        end
        print(string.format("[mine] need fuel — current %s. Add coal to slot 1 or chest. Retry %ds.",
            tostring(turtle.getFuelLevel()), REFUEL_POLL_S))
        sleep(REFUEL_POLL_S)
    end
end

local function gotoWaypoint(wp)
    while pos.y < wp.y do if not stepUpBare()   then return false end end
    while pos.y > wp.y do if not stepDownBare() then return false end end
    if wp.x > pos.x then faceDir(0); while pos.x < wp.x do if not stepBare() then return false end end
    elseif wp.x < pos.x then faceDir(2); while pos.x > wp.x do if not stepBare() then return false end end end
    if wp.z > pos.z then faceDir(1); while pos.z < wp.z do if not stepBare() then return false end end
    elseif wp.z < pos.z then faceDir(3); while pos.z > wp.z do if not stepBare() then return false end end end
    faceDir(wp.facing or 0)
    return true
end

local function maybeDump()
    if freeSlots() >= MIN_FREE_SLOTS then return true end
    print("[mine] inventory full → home")
    local wp = { x = pos.x, y = pos.y, z = pos.z, facing = pos.facing }
    if not goHome() then return false end
    dumpToChest()
    if not gotoWaypoint(wp) then return false end
    return true
end

local function homeRefuelResume(wp)
    print("[mine] fuel reserve broken → home")
    if not goHome() then return false end
    dumpToChest()
    waitForRefuel()
    if not gotoWaypoint(wp) then return false end
    return true
end

----------------------------------------------------------------------
-- Sector mining
--
-- Args: xEnd, yEnd, zEnd (inclusive end-coords).
-- Volume: (xEnd+1) × (yEnd+1) × (zEnd+1).
-- y axis goes UP (layer 0 = home level; layer y is y blocks above).
--
-- Algorithm: snake through (x, z) plane per layer; each layer's snake
-- naturally flips x-direction at every row. Between layers, step UP
-- and turn 180°, then snake back through z so the next layer covers
-- the same (x,z) range without doubling back over already-mined air.
----------------------------------------------------------------------

-- Move 1 block laterally in z direction (zDir = +1 or -1) and end up
-- facing the OPPOSITE x-direction. Mines the destination block.
-- Step variants that internally handle the "fuel" soft-fail by going
-- home, refuelling, and returning to the saved waypoint — then retry
-- the original step. Without this, a row that triggered refuel partway
-- through bailed early (the for-loop counter didn't include the
-- bailed-out steps), the caller did `if not r then return false end`
-- which evaluates `not "fuel"` as false (truthy string), so the
-- partial row was treated as success — shifting the rest of the
-- layer by N blocks. End result on a 16-wide job: x-axis ended up
-- 8 blocks short.
-- Sentinel raised by safeStep* when the abort flag is observed.
-- Caller can catch via pcall and treat as a clean stop request.
local ABORT_ERR = "__mine_abort__"

local function safeStep()
    if abortRequested() then error(ABORT_ERR, 0) end
    while true do
        local r = step()
        if r == true then return true end
        if r == false then return false end
        local wp = { x = pos.x, y = pos.y, z = pos.z, facing = pos.facing }
        if not homeRefuelResume(wp) then return false end
        if abortRequested() then error(ABORT_ERR, 0) end
    end
end
local function safeStepUp()
    if abortRequested() then error(ABORT_ERR, 0) end
    while true do
        local r = stepUp()
        if r == true then return true end
        if r == false then return false end
        local wp = { x = pos.x, y = pos.y, z = pos.z, facing = pos.facing }
        if not homeRefuelResume(wp) then return false end
        if abortRequested() then error(ABORT_ERR, 0) end
    end
end
local function safeStepDown()
    if abortRequested() then error(ABORT_ERR, 0) end
    while true do
        local r = stepDown()
        if r == true then return true end
        if r == false then return false end
        local wp = { x = pos.x, y = pos.y, z = pos.z, facing = pos.facing }
        if not homeRefuelResume(wp) then return false end
        if abortRequested() then error(ABORT_ERR, 0) end
    end
end

local function lateralStep(zDir)
    local f = pos.facing
    local turnFn
    if (f == 0 and zDir > 0) or (f == 2 and zDir < 0) then
        turnFn = turnRight
    elseif (f == 0 and zDir < 0) or (f == 2 and zDir > 0) then
        turnFn = turnLeft
    else
        return false
    end
    turnFn()
    if not safeStep() then return false end
    turnFn()
    return true
end

local function mineRowForward(xCount)
    for _ = 1, xCount do
        if not safeStep() then return false end
        if not maybeDump() then return false end
    end
    return true
end

local function mineLayerSnake(xCount, zEnd, zDir)
    if not mineRowForward(xCount) then return false end
    for _ = 1, zEnd do
        if not lateralStep(zDir) then return false end
        if not maybeDump() then return false end
        if not mineRowForward(xCount) then return false end
    end
    return true
end

-- Persist a checkpoint after each completed row. Resume will skip
-- forward to the saved layer/row without redigging the early ones.
local function checkpoint(layer, row)
    if not job then return end
    job.progress = { layer = layer, row = row }
    saveJob(job)
end

local function mineSector(xEnd, yEnd, zEnd, resumeFrom)
    if xEnd == 0 then
        print("[mine] xEnd cannot be 0 (need at least one block forward).")
        return true
    end

    local xDir = (xEnd > 0) and 1 or -1
    local yDir = (yEnd > 0) and 1 or (yEnd < 0 and -1 or 0)
    local zDir = (zEnd > 0) and 1 or (zEnd < 0 and -1 or 0)
    local xMag, yMag, zMag = math.abs(xEnd), math.abs(yEnd), math.abs(zEnd)

    if job then job.xDir = xDir; saveJob(job) end

    -- resumeFrom = { layer, row } indicates the LAST completed (layer,row).
    -- The next iteration starts immediately after it.
    local skipLayer = (resumeFrom and resumeFrom.layer) or -1
    local skipRow   = (resumeFrom and resumeFrom.row)   or -1
    local resuming  = (skipLayer >= 0)

    if not resuming then
        -- Fresh start: face the dig direction and step into the sector.
        if xDir == -1 then turnRight(); turnRight() end
        if not safeStep() then return false end
        if xMag > 1 then
            if not mineRowForward(xMag - 1) then return false end
        end
        checkpoint(0, 0)
    end

    -- Layer 0 snake. Each row mined ⇒ checkpoint(0, r).
    if zMag > 0 then
        local startR = (resuming and skipLayer == 0) and (skipRow + 1) or 1
        for r = startR, zMag do
            if not lateralStep(zDir) then return false end
            if not maybeDump() then return false end
            if not mineRowForward(xMag) then return false end
            checkpoint(0, r)
        end
    end

    -- Layers 1..yMag.
    for layer = 1, yMag do
        if not resuming or layer > skipLayer then
            -- Climb into the new layer.
            if yDir > 0 then
                if not safeStepUp() then return false end
            else
                if not safeStepDown() then return false end
            end
            turnRight(); turnRight()
            -- Mine the first row of this layer.
            if not mineRowForward(xMag) then return false end
            checkpoint(layer, 0)
        end

        local nextZDir = (pos.z == 0) and zDir or -zDir
        local startR
        if resuming and layer == skipLayer then
            startR = skipRow + 1
        else
            startR = 1
        end
        for r = startR, zMag do
            if not lateralStep(nextZDir) then return false end
            if not maybeDump() then return false end
            if not mineRowForward(xMag) then return false end
            checkpoint(layer, r)
        end
    end

    if not goHome() then return false end
    dumpToChest()
    return true
end

----------------------------------------------------------------------
-- Public
----------------------------------------------------------------------

local function status()
    local cfg = loadConfig()
    local j   = loadJob()
    print("mine 2.5.0")
    print(string.format("  fuel:        %s  reserve=%d", tostring(turtle.getFuelLevel()), fuelReserve()))
    print("  free slots:  " .. tostring(freeSlots()) .. "/16")
    local s = cfg.shape
    print(string.format("  default end: %d %d %d  (%dx%dx%d blocks)",
        s.xEnd, s.yEnd, s.zEnd, s.xEnd + 1, s.yEnd + 1, s.zEnd + 1))
    if not j then print("  job:         (none)"); return end
    print("  phase:       " .. tostring(j.phase or "?"))
    print(string.format("  position:    %s,%s,%s",
        j.pos and j.pos.x or "?", j.pos and j.pos.y or "?", j.pos and j.pos.z or "?"))
    print("  dug:         " .. tostring(j.dug or 0))
end

local function configure(args)
    local cfg = loadConfig()
    if args[1] == "shape" then
        cfg.shape = {
            xEnd = tonumber(args[2]) or cfg.shape.xEnd,
            yEnd = tonumber(args[3]) or cfg.shape.yEnd,
            zEnd = tonumber(args[4]) or cfg.shape.zEnd,
        }
        saveConfig(cfg)
        print(string.format("default end-coords: %d %d %d", cfg.shape.xEnd, cfg.shape.yEnd, cfg.shape.zEnd))
        return
    end
    print("usage: mine setup shape <xEnd yEnd zEnd>")
    print("  current: " .. cfg.shape.xEnd .. " " .. cfg.shape.yEnd .. " " .. cfg.shape.zEnd)
end

local function help()
    print("mine 2.5.0 — sector miner (signed end-coords)")
    print("")
    print("  mine <xEnd> <yEnd> <zEnd>    mine 0..xEnd × 0..yEnd × 0..zEnd")
    print("  mine -S <xEnd yEnd zEnd>     same (--sector)")
    print("  mine                         resume saved job")
    print("  mine -R                      resume saved job")
    print("  mine -X                      forget saved job (no return home)")
    print("  mine -A                      abort RUNNING miner (return home + dump)")
    print("  mine -s                      progress + fuel + position")
    print("  mine setup shape <x y z>     change defaults")
    print("")
    print("Direction = sign of each arg:")
    print("  +x forward / -x back     +y up / -y DOWN     +z right / -z LEFT")
    print("Examples:")
    print("  mine  7  3  7    8x4x8 floor going up")
    print("  mine  7 -3  7    8x4x8 going DOWN  (mine ore)")
    print("  mine  7 -7 -7    8x8x8 down-left")
    print("")
    print("Place chest behind turtle (or in front for xEnd<0), coal in slot 1.")
    print("Never attacks. Returns home & waits if fuel/inventory hits limits.")
end

local function ensureChestBehind()
    turtle.turnRight(); turtle.turnRight()
    local present = turtle.detect()
    turtle.turnRight(); turtle.turnRight()
    if not present then
        print("[mine] WARN: no block detected behind — put a chest there.")
    end
end

local function startJob(args)
    local cfg = loadConfig()
    local xEnd = tonumber(args[1]) or cfg.shape.xEnd
    local yEnd = tonumber(args[2]) or cfg.shape.yEnd
    local zEnd = tonumber(args[3]) or cfg.shape.zEnd
    if xEnd == 0 then
        printError("xEnd must be non-zero (need at least 1 block forward/back).")
        return
    end
    cfg.shape = { xEnd = xEnd, yEnd = yEnd, zEnd = zEnd }
    saveConfig(cfg)
    -- Wipe any stale abort flag from a prior run so we don't bail out
    -- immediately on the first step.
    clearAbort()
    ensureChestBehind()
    consolidateFuel()

    -- Try to anchor world coords via GPS so all atlas events / mined-
    -- block records are in world-space. Without a fix we still mine,
    -- just without atlas writes (events fall back to local coords).
    origin = nil
    local libGps = unison and unison.lib and unison.lib.gps
    if libGps and libGps.locate then
        local x, y, z = libGps.locate("self", { timeout = 1 })
        if x then origin = { x = x, y = y, z = z } end
    end
    if origin then
        print(string.format("[mine] gps anchor %d,%d,%d", origin.x, origin.y, origin.z))
    else
        print("[mine] no gps fix — atlas records will be skipped")
    end

    job = {
        phase = "mining",
        pos = { x = 0, y = 0, z = 0, facing = 0 },
        dug = 0,
        shape = cfg.shape,
        started_at = os.epoch("utc"),
        origin = origin,
    }
    saveJob(job)
    pos.x, pos.y, pos.z, pos.facing = 0, 0, 0, 0
    logEvent("job_start", { shape = cfg.shape })
    print(string.format("[mine] starting end=%d,%d,%d (%dx%dx%d)",
        xEnd, yEnd, zEnd, xEnd + 1, yEnd + 1, zEnd + 1))
    local ok, err = pcall(mineSector, xEnd, yEnd, zEnd)
    if atlas and atlas.flush then atlas.flush() end
    if ok then
        job.phase = "done"; saveJob(job)
        logEvent("job_done", { dug = job.dug })
        print("[mine] done. " .. tostring(job.dug) .. " block(s) mined.")
        clearJob()
    elseif tostring(err):find(ABORT_ERR, 1, true) then
        -- Graceful abort: walk home with bare steps (no fuel guard, no
        -- abort re-check) and dump. Drop the saved job so a later
        -- 'mine' won't auto-resume the cancelled run.
        print("[mine] abort signalled — heading home")
        local hOk = pcall(goHome)
        if hOk then pcall(dumpToChest) end
        clearAbort()
        clearJob()
        logEvent("job_aborted", { dug = job.dug })
        print("[mine] aborted at home. dug=" .. tostring(job.dug))
    else
        job.phase = "paused"; job.error = tostring(err)
        saveJob(job)
        logEvent("job_paused", { err = tostring(err) })
        print("[mine] paused: " .. tostring(err))
    end
end

local function resumeJob()
    job = loadJob()
    if not job then help(); return end
    if job.phase == "done" then print("[mine] previous job done."); return end
    pos.x = job.pos.x; pos.y = job.pos.y
    pos.z = job.pos.z; pos.facing = job.pos.facing
    origin = job.origin    -- restore world anchor for atlas events / A*

    local progress = job.progress
    if progress then
        print(string.format("[mine] resuming layer %d row %d (dug=%d)",
            progress.layer, progress.row, job.dug or 0))
    else
        print(string.format("[mine] resuming at %d,%d,%d facing=%d (dug=%d, no checkpoint)",
            pos.x, pos.y, pos.z, pos.facing, job.dug or 0))
    end

    -- We're already at the right physical position. Just continue.
    -- Don't goHome+dump first — the new mineSector skip-mode picks up
    -- where the checkpoint left off without redigging anything.
    clearAbort()
    local s = job.shape or loadConfig().shape
    local ok, err = pcall(mineSector, s.xEnd, s.yEnd, s.zEnd, progress)
    if atlas and atlas.flush then atlas.flush() end
    if ok then
        clearJob(); print("[mine] done.")
    elseif tostring(err):find(ABORT_ERR, 1, true) then
        print("[mine] abort signalled — heading home")
        pcall(goHome); pcall(dumpToChest)
        clearAbort(); clearJob()
        print("[mine] aborted at home.")
    else
        job.phase = "paused"; job.error = tostring(err); saveJob(job)
        print("[mine] paused: " .. tostring(err))
    end
end

local function stopJob()
    if loadJob() then clearJob(); print("[mine] saved job cleared.") end
end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------

if not turtle then printError("mine: requires a turtle."); return end

local args = { ... }
local sub = args[1]

-- Fast-path: abort signal. Just drops the flag file and exits, so this
-- can be invoked in parallel with a running mine instance (e.g. via
-- `exec mine abort` from the dashboard) — the running instance picks
-- up the flag in its next safeStep, walks home, dumps, and exits.
if sub == "-A" or sub == "--abort" or sub == "abort" then
    requestAbort()
    print("[mine] abort flag set; running miner will return home.")
    return
end

local function aliasStart(rest) return function() startJob(rest) end end

local route
if sub == nil then
    route = resumeJob
elseif tonumber(sub) then
    route = aliasStart({ sub, args[2], args[3] })
elseif sub == "-S" or sub == "--sector" or sub == "start" then
    route = aliasStart({ args[2], args[3], args[4] })
elseif sub == "-R" or sub == "--resume" then
    route = resumeJob
elseif sub == "-X" or sub == "--stop" or sub == "stop" then
    route = stopJob
elseif sub == "status" or sub == "-s" then
    route = status
elseif sub == "setup" then
    table.remove(args, 1)
    route = function() configure(args) end
elseif sub == "-h" or sub == "--help" or sub == "help" or sub == "-?" then
    route = help
else
    route = help
end

local busyTok = proc and proc.markBusy and proc.markBusy("mine") or nil
local ok, err = pcall(route)
if proc and proc.clearBusy then proc.clearBusy(busyTok) end
if not ok then printError("mine: " .. tostring(err)) end
