-- mine 2.2.0 — sector miner driven by END-COORDINATES.
--
-- Pre-flight:
--   1) Place the turtle. Forward (the block IN FRONT) is +x.
--   2) Place a chest immediately BEHIND the turtle.
--   3) Put coal/charcoal in slot 1 (fuel reserve, kept across runs).
--   4) Run `mine <xEnd> <yEnd> <zEnd>`.
--
-- Coordinate model (relative to home):
--   +x  = forward (in front of the turtle's start facing)
--   +y  = up (layers stack above start; y=0 is start level)
--   +z  = right (the snake direction)
--
-- `mine 7 3 7` mines the rectangular volume 0..7 × 0..3 × 0..7,
-- which is 8 × 4 × 8 = 256 blocks (an 8×8 floor across 4 layers,
-- starting at the turtle's level and rising 3 blocks).
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
local proc  = unison and unison.process

local STATE_DIR  = "/unison/state/mine"
local CONFIG_FILE = STATE_DIR .. "/config.json"
local JOB_FILE    = STATE_DIR .. "/job.json"

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
    c.shape = c.shape or { xEnd = 15, yEnd = 2, zEnd = 15 }   -- default 16x3x16
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
-- Position model
--   pos.x +forward, pos.y +up, pos.z +right
--   facing: 0=+x, 1=+z, 2=-x, 3=-z
----------------------------------------------------------------------

local pos = { x = 0, y = 0, z = 0, facing = 0 }
local job = nil

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
    return true
end
local function stepUp()
    if not ensureFuel() then return "fuel" end
    if not moveUp() then return false end
    pos.y = pos.y + 1
    job.dug = (job.dug or 0) + 1
    persist()
    return true
end
local function stepDown()
    if not ensureFuel() then return "fuel" end
    if not moveDown() then return false end
    pos.y = pos.y - 1
    job.dug = (job.dug or 0) + 1
    persist()
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

local function goHome()
    while pos.y < 0 do if not stepUpBare()   then return false end end
    while pos.y > 0 do if not stepDownBare() then return false end end
    if pos.z > 0 then faceDir(3); while pos.z > 0 do if not stepBare() then return false end end
    elseif pos.z < 0 then faceDir(1); while pos.z < 0 do if not stepBare() then return false end end end
    if pos.x > 0 then faceDir(2); while pos.x > 0 do if not stepBare() then return false end end
    elseif pos.x < 0 then faceDir(0); while pos.x < 0 do if not stepBare() then return false end end end
    faceDir(0)
    return true
end

local function dumpToChest()
    faceDir(2)
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
    faceDir(2)
    for s = 1, 16 do
        if turtle.getItemCount(s) == 0 then
            turtle.select(s); turtle.suck(64)
        end
    end
    -- Drop non-fuel back.
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
local function lateralStep(zDir)
    local f = pos.facing
    local turnFn
    if (f == 0 and zDir > 0) or (f == 2 and zDir < 0) then
        turnFn = turnRight
    elseif (f == 0 and zDir < 0) or (f == 2 and zDir > 0) then
        turnFn = turnLeft
    else
        return false   -- not facing along x axis
    end
    turnFn()
    local r = step()
    if r ~= true then return r end
    turnFn()
    return true
end

local function mineRowForward(xCount)
    for _ = 1, xCount do
        local r = step()
        if r == "fuel" then return r end
        if r == false then return false end
        if not maybeDump() then return false end
    end
    return true
end

-- Mine all (zEnd+1) rows of one layer, snaking in zDir. xCount blocks
-- per row. Caller positions turtle at the start of the first row.
local function mineLayerSnake(xCount, zEnd, zDir)
    if not mineRowForward(xCount) then return false end
    for _ = 1, zEnd do
        local r = lateralStep(zDir)
        if r == "fuel" then return r end
        if r == false then return false end
        if not maybeDump() then return false end
        if not mineRowForward(xCount) then return false end
    end
    return true
end

local function mineSector(xEnd, yEnd, zEnd)
    if xEnd < 1 or zEnd < 0 or yEnd < 0 then
        print("[mine] dimensions too small.")
        return true
    end

    -- Layer 0: enter via stepForward so we don't try to mine home block.
    local r = step()
    if r == "fuel" then if not homeRefuelResume({x=0,y=0,z=0,facing=0}) then return false end; r = step() end
    if r ~= true then return false end
    -- We've mined (1, 0, 0). Mine remainder of row 0 (xEnd-1 more) + snake.
    if xEnd > 1 then
        if not mineRowForward(xEnd - 1) then return false end
    end
    if zEnd > 0 then
        for _ = 1, zEnd do
            local lr = lateralStep(1)
            if lr == "fuel" then
                if not homeRefuelResume({x=pos.x,y=pos.y,z=pos.z,facing=pos.facing}) then return false end
                lr = lateralStep(1)
            end
            if lr ~= true then return false end
            if not maybeDump() then return false end
            if not mineRowForward(xEnd) then return false end
        end
    end

    -- Layers 1..yEnd: stepUp, reverse facing, snake back.
    for layer = 1, yEnd do
        local r2 = stepUp()
        if r2 == "fuel" then
            if not homeRefuelResume({x=pos.x,y=pos.y,z=pos.z,facing=pos.facing}) then return false end
            r2 = stepUp()
        end
        if r2 ~= true then return false end
        turnRight(); turnRight()
        local zDir = (pos.z > 0) and -1 or 1
        if not mineLayerSnake(xEnd, zEnd, zDir) then return false end
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
    print("mine 2.2.0")
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
    print("mine 2.2.0 — sector miner (end-coord args)")
    print("")
    print("  mine <xEnd> <yEnd> <zEnd>    mine 0..xEnd × 0..yEnd × 0..zEnd")
    print("  mine -S <xEnd yEnd zEnd>     same as above (--sector)")
    print("  mine                         resume saved job")
    print("  mine -R                      same (--resume)")
    print("  mine -X | mine stop          abandon job")
    print("  mine -s | mine status        progress + fuel + position")
    print("  mine setup shape <x y z>     change defaults")
    print("")
    print("Coordinate model:")
    print("  +x = forward, +y = up, +z = right")
    print("  'mine 7 3 7' = 8x4x8 = 256 blocks (8 wide, 4 tall, 8 deep)")
    print("")
    print("Place chest BEHIND turtle, coal in slot 1. Never attacks/drops.")
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
    if xEnd < 1 or yEnd < 0 or zEnd < 0 then
        printError("xEnd >= 1, yEnd >= 0, zEnd >= 0 required."); return
    end
    cfg.shape = { xEnd = xEnd, yEnd = yEnd, zEnd = zEnd }
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
    print(string.format("[mine] starting end=%d,%d,%d (%dx%dx%d)",
        xEnd, yEnd, zEnd, xEnd + 1, yEnd + 1, zEnd + 1))
    local ok, err = pcall(mineSector, xEnd, yEnd, zEnd)
    if ok then
        job.phase = "done"; saveJob(job)
        print("[mine] done. " .. tostring(job.dug) .. " block(s) mined.")
        clearJob()
    else
        job.phase = "paused"; job.error = tostring(err)
        saveJob(job)
        print("[mine] paused: " .. tostring(err))
    end
end

local function resumeJob()
    job = loadJob()
    if not job then help(); return end
    if job.phase == "done" then print("[mine] previous job done."); return end
    pos.x = job.pos.x; pos.y = job.pos.y
    pos.z = job.pos.z; pos.facing = job.pos.facing
    print(string.format("[mine] resuming at %d,%d,%d facing=%d (dug=%d)",
        pos.x, pos.y, pos.z, pos.facing, job.dug or 0))
    -- Simplified resume: go home, dump, restart layer.
    goHome()
    dumpToChest()
    local s = job.shape or loadConfig().shape
    local ok, err = pcall(mineSector, s.xEnd, s.yEnd, s.zEnd)
    if ok then clearJob(); print("[mine] done.") end
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
