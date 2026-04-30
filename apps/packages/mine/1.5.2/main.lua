-- mine 1.5.1
-- Turtle mining utility (legacy 'shaft' depth-only mode removed; sector
-- with a 1x1 footprint replaces it):
--   * sector      - mine a relative cuboid by coordinates
--   * sector-abs  - mine an absolute GPS cuboid
--   * ore         - tunnel + ore vein harvesting by ore filter
--   * cancel      - cancel current running job safely
--   * queue       - queue/list/flush jobs (RPC + local commands)
--   * listen      - RPC service mode (mine_order / mine_status / mine_cancel)

if not turtle then print("mine: must run on a turtle"); return end

local lib = unison.lib
local app = lib.app
local fmt = lib.fmt
local store = lib.kvstore.open("mine", {
    jobs_total = 0,
    blocks_total = 0,
    ore_total = {},
    last_job = nil,
    last_error = nil,
    anchor = nil,
    next_job_id = 1,
})

local KEEP_FREE_SLOTS = 3
local MAX_MOVE_RETRIES = 50
-- Auto-refuel from any inventory slot whenever fuel drops below this.
local MIN_FUEL_FLOOR = 500

-- Local frame:
--   +x = turtle forward direction at job start
--   +z = turtle right direction at job start
local DIR = {
    [0] = { x = 1,  z = 0,  label = "+x" },
    [1] = { x = 0,  z = 1,  label = "+z" },
    [2] = { x = -1, z = 0,  label = "-x" },
    [3] = { x = 0,  z = -1, label = "-z" },
}

local ORE_ALIASES = {
    coal = { "minecraft:coal_ore", "minecraft:deepslate_coal_ore" },
    iron = { "minecraft:iron_ore", "minecraft:deepslate_iron_ore" },
    copper = { "minecraft:copper_ore", "minecraft:deepslate_copper_ore" },
    gold = { "minecraft:gold_ore", "minecraft:deepslate_gold_ore", "minecraft:nether_gold_ore" },
    redstone = { "minecraft:redstone_ore", "minecraft:deepslate_redstone_ore" },
    lapis = { "minecraft:lapis_ore", "minecraft:deepslate_lapis_ore" },
    diamond = { "minecraft:diamond_ore", "minecraft:deepslate_diamond_ore" },
    emerald = { "minecraft:emerald_ore", "minecraft:deepslate_emerald_ore" },
    quartz = { "minecraft:nether_quartz_ore" },
    debris = { "minecraft:ancient_debris" },
    ancient_debris = { "minecraft:ancient_debris" },
}

local KNOWN_ORES = {}
for _, names in pairs(ORE_ALIASES) do
    for _, n in ipairs(names) do KNOWN_ORES[n] = true end
end

local busy = false
local activeNav = nil
local activeJob = nil
local unloading = false
local cancelJobId = nil
local cancelReason = nil
local queue = {}
local queueWorkerRunning = false

local function nowMs() return os.epoch("utc") end

local function iRound(n)
    n = tonumber(n) or 0
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function coordKey(x, y, z)
    return tostring(x) .. "," .. tostring(y) .. "," .. tostring(z)
end

local function shallowCopy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function usedSlots()
    local n = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then n = n + 1 end
    end
    return n
end

local function freeSlots()
    return 16 - usedSlots()
end

local function fuelNumber()
    local f = turtle.getFuelLevel()
    if f == "unlimited" then return math.huge end
    return tonumber(f) or 0
end

local function slotIsFuel(slot)
    if turtle.getItemCount(slot) <= 0 then return false end
    local old = turtle.getSelectedSlot()
    turtle.select(slot)
    local ok = turtle.refuel(0)
    turtle.select(old)
    return ok and true or false
end

local function tryRefuel(minLevel)
    minLevel = tonumber(minLevel) or 0
    if fuelNumber() >= minLevel then return true end
    local old = turtle.getSelectedSlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if turtle.refuel(0) then
                while turtle.getItemCount(slot) > 0 and fuelNumber() < minLevel do
                    if not turtle.refuel(1) then break end
                end
                if fuelNumber() >= minLevel then
                    turtle.select(old)
                    return true
                end
            end
        end
    end
    turtle.select(old)
    return fuelNumber() >= minLevel
end

local function distHome(nav)
    return math.abs(nav.x) + math.abs(nav.y) + math.abs(nav.z)
end

local function ensureFuel(nav, reserve)
    reserve = tonumber(reserve) or 8
    -- Always keep enough fuel for "go home" + a comfortable floor so the
    -- turtle isn't forced to top up every other step from random inventory.
    local need = math.max(distHome(nav) + reserve, MIN_FUEL_FLOOR)
    if fuelNumber() >= need then return true end
    if tryRefuel(need) then return true end
    return false, string.format("low fuel (%d < %d)", fuelNumber(), need)
end

local function log(msg)
    print("[mine] " .. tostring(msg))
end

local function isCancelled(job)
    if not job then return false end
    if cancelJobId and job.id == cancelJobId then
        return true, cancelReason or "cancelled"
    end
    return false
end

local function requestCancel(reason, jobId)
    local why = tostring(reason or "cancel requested")

    if jobId ~= nil then
        local id = tonumber(jobId)
        if not id then return false, "bad job_id" end
        id = iRound(id)

        if busy and activeJob and activeJob.id == id then
            cancelJobId = id
            cancelReason = why
            return true, cancelReason, id
        end

        local idx = findQueued(id)
        if idx then
            table.remove(queue, idx)
            return true, "removed queued job", id
        end
        return false, "job_id not found"
    end

    if busy and activeJob then
        cancelJobId = activeJob.id
        cancelReason = why
        return true, cancelReason, activeJob.id
    end

    if #queue > 0 then
        local q = table.remove(queue, #queue)
        return true, "removed queued job", q.job_id
    end

    return false, "not running"
end

local function clearCancelFor(job)
    if job and cancelJobId and job.id == cancelJobId then
        cancelJobId = nil
        cancelReason = nil
    end
end

local function reserveJobId()
    local id = store:get("next_job_id", 1)
    store:set("next_job_id", id + 1)
    return id
end

local function queuePreview(limit)
    limit = math.max(1, tonumber(limit) or 5)
    local out = {}
    for i = 1, math.min(#queue, limit) do
        local q = queue[i]
        out[#out + 1] = {
            job_id = q.job_id,
            mode = q.mode,
            queued_at = q.queued_at,
            from = q.from,
        }
    end
    return out
end

local function findQueued(jobId)
    for i, q in ipairs(queue) do
        if q.job_id == jobId then return i, q end
    end
    return nil, nil
end

local function flushQueue()
    local n = #queue
    queue = {}
    return n
end

local function noteOre(job, blockName)
    if not blockName or not KNOWN_ORES[blockName] then return end
    job.ores[blockName] = (job.ores[blockName] or 0) + 1
end

local function maybeDig(detectFn, inspectFn, digFn, job)
    if not detectFn or not detectFn() then return false end
    local blockName = nil
    if inspectFn then
        local ok, info = inspectFn()
        if ok and info and info.name then blockName = info.name end
    end
    local dug = digFn and digFn() or false
    if dug then
        job.blocks_dug = job.blocks_dug + 1
        noteOre(job, blockName)
    end
    return dug, blockName
end

local function turnLeft(nav)
    turtle.turnLeft()
    nav.dir = (nav.dir + 3) % 4
end

local function turnRight(nav)
    turtle.turnRight()
    nav.dir = (nav.dir + 1) % 4
end

local function face(nav, target)
    target = (target % 4 + 4) % 4
    local diff = (target - nav.dir) % 4
    if diff == 0 then return end
    if diff == 1 then
        turnRight(nav)
    elseif diff == 2 then
        turnRight(nav); turnRight(nav)
    else
        turnLeft(nav)
    end
end

local function stepForward(nav, job, opts)
    local okFuel, errFuel = ensureFuel(nav, (opts and opts.fuel_reserve) or 12)
    if not okFuel then return false, errFuel end
    local retries = 0
    while retries < MAX_MOVE_RETRIES do
        if not (opts and opts.ignore_cancel) then
            local stop, why = isCancelled(job)
            if stop then return false, why end
        end
        if turtle.forward() then
            local d = DIR[nav.dir]
            nav.x = nav.x + d.x
            nav.z = nav.z + d.z
            job.moves = job.moves + 1
            return true
        end
        retries = retries + 1
        maybeDig(turtle.detect, turtle.inspect, turtle.dig, job)
        turtle.attack()
        sleep(0.15)
    end
    return false, "blocked moving forward"
end

local function stepUp(nav, job, opts)
    local okFuel, errFuel = ensureFuel(nav, (opts and opts.fuel_reserve) or 12)
    if not okFuel then return false, errFuel end
    local retries = 0
    while retries < MAX_MOVE_RETRIES do
        if not (opts and opts.ignore_cancel) then
            local stop, why = isCancelled(job)
            if stop then return false, why end
        end
        if turtle.up() then
            nav.y = nav.y + 1
            job.moves = job.moves + 1
            return true
        end
        retries = retries + 1
        maybeDig(turtle.detectUp, turtle.inspectUp, turtle.digUp, job)
        turtle.attackUp()
        sleep(0.15)
    end
    return false, "blocked moving up"
end

local function stepDown(nav, job, opts)
    local okFuel, errFuel = ensureFuel(nav, (opts and opts.fuel_reserve) or 12)
    if not okFuel then return false, errFuel end
    local retries = 0
    while retries < MAX_MOVE_RETRIES do
        if not (opts and opts.ignore_cancel) then
            local stop, why = isCancelled(job)
            if stop then return false, why end
        end
        if turtle.down() then
            nav.y = nav.y - 1
            job.moves = job.moves + 1
            return true
        end
        retries = retries + 1
        maybeDig(turtle.detectDown, turtle.inspectDown, turtle.digDown, job)
        turtle.attackDown()
        sleep(0.15)
    end
    return false, "blocked moving down"
end

local function stepBack(nav, job, opts)
    if not (opts and opts.ignore_cancel) then
        local stop, why = isCancelled(job)
        if stop then return false, why end
    end
    local okFuel, errFuel = ensureFuel(nav, (opts and opts.fuel_reserve) or 12)
    if not okFuel then return false, errFuel end
    if turtle.back() then
        local d = DIR[nav.dir]
        nav.x = nav.x - d.x
        nav.z = nav.z - d.z
        job.moves = job.moves + 1
        return true
    end
    local dir0 = nav.dir
    turnRight(nav); turnRight(nav)
    local ok, err = stepForward(nav, job, opts)
    face(nav, dir0)
    return ok, err
end

local function dropInventoryToLeft()
    local old = turtle.getSelectedSlot()
    turtle.turnLeft()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 and not slotIsFuel(slot) then
            turtle.select(slot)
            turtle.drop()
        end
    end
    turtle.select(old)
    turtle.turnRight()
end

local function goTo(nav, target, job, opts)
    while nav.y < target.y do
        local ok, err = stepUp(nav, job, opts); if not ok then return false, err end
    end
    while nav.y > target.y do
        local ok, err = stepDown(nav, job, opts); if not ok then return false, err end
    end
    while nav.x ~= target.x do
        if nav.x < target.x then face(nav, 0) else face(nav, 2) end
        local ok, err = stepForward(nav, job, opts); if not ok then return false, err end
    end
    while nav.z ~= target.z do
        if nav.z < target.z then face(nav, 1) else face(nav, 3) end
        local ok, err = stepForward(nav, job, opts); if not ok then return false, err end
    end
    return true
end

local function checkpoint(nav, job, opts)
    local stop, why = isCancelled(job)
    if stop then return false, why end
    if not opts then return true end
    if opts.auto_dump == false then return true end
    if unloading then return true end
    if freeSlots() > KEEP_FREE_SLOTS then return true end

    unloading = true
    local snap = { x = nav.x, y = nav.y, z = nav.z, dir = nav.dir }
    log("inventory full, unloading at home")

    local ok, err = goTo(nav, { x = 0, y = 0, z = 0 }, job, { fuel_reserve = 8, auto_dump = false })
    if not ok then
        unloading = false
        return false, "failed to return home: " .. tostring(err)
    end

    dropInventoryToLeft()
    tryRefuel(distHome(snap) + 20)

    ok, err = goTo(nav, { x = snap.x, y = snap.y, z = snap.z }, job, { fuel_reserve = 8, auto_dump = false })
    if not ok then
        unloading = false
        return false, "failed to return to work point: " .. tostring(err)
    end
    face(nav, snap.dir)

    unloading = false
    if freeSlots() <= KEEP_FREE_SLOTS then
        return false, "inventory still full (check chest on turtle's left)"
    end
    return true
end

local function relNeighbor(absDir, rel)
    if rel == "front" then return absDir end
    if rel == "left" then return (absDir + 3) % 4 end
    if rel == "right" then return (absDir + 1) % 4 end
    if rel == "back" then return (absDir + 2) % 4 end
    return absDir
end

local function neighborPos(nav, rel)
    if rel == "up" then return nav.x, nav.y + 1, nav.z end
    if rel == "down" then return nav.x, nav.y - 1, nav.z end
    local ad = relNeighbor(nav.dir, rel)
    local d = DIR[ad]
    return nav.x + d.x, nav.y, nav.z + d.z
end

local function inspectRelative(nav, rel)
    if rel == "up" then return turtle.inspectUp() end
    if rel == "down" then return turtle.inspectDown() end
    local dir0 = nav.dir
    local target = relNeighbor(nav.dir, rel)
    face(nav, target)
    local ok, info = turtle.inspect()
    face(nav, dir0)
    return ok, info
end

local function mineVeinAround(nav, job, oreSet, limit, opts)
    if not oreSet then return true, 0 end
    limit = math.max(1, tonumber(limit) or 32)

    local visited = {}
    local mined = 0

    local function dfs()
        local stop, why = isCancelled(job)
        if stop then return false, why end
        if mined >= limit then return true end
        visited[coordKey(nav.x, nav.y, nav.z)] = true
        local dirs = { "front", "left", "right", "back", "up", "down" }
        for _, rel in ipairs(dirs) do
            if mined >= limit then break end

            local nx, ny, nz = neighborPos(nav, rel)
            local nk = coordKey(nx, ny, nz)
            if not visited[nk] then
                local present, info = inspectRelative(nav, rel)
                local blockName = info and info.name or nil
                if present and blockName and oreSet[blockName] then
                    local dir0 = nav.dir
                    local ok, err
                    if rel == "up" then
                        ok, err = stepUp(nav, job, opts)
                    elseif rel == "down" then
                        ok, err = stepDown(nav, job, opts)
                    else
                        face(nav, relNeighbor(dir0, rel))
                        ok, err = stepForward(nav, job, opts)
                    end
                    if not ok then
                        face(nav, dir0)
                        return false, err
                    end

                    mined = mined + 1
                    local okCheck, errCheck = checkpoint(nav, job, opts)
                    if not okCheck then
                        face(nav, dir0)
                        return false, errCheck
                    end

                    local okRec, errRec = dfs()
                    if not okRec then
                        face(nav, dir0)
                        return false, errRec
                    end

                    if rel == "up" then
                        ok, err = stepDown(nav, job, opts)
                    elseif rel == "down" then
                        ok, err = stepUp(nav, job, opts)
                    else
                        face(nav, (nav.dir + 2) % 4)
                        ok, err = stepForward(nav, job, opts)
                    end
                    if not ok then
                        face(nav, dir0)
                        return false, "failed to backtrack after vein move: " .. tostring(err)
                    end
                    face(nav, dir0)
                end
                visited[nk] = true
            end
        end
        return true
    end

    local ok, err = dfs()
    if not ok then return false, mined, err end
    return true, mined
end

local function normalizeBox(x1, y1, z1, x2, y2, z2)
    local minX, maxX = math.min(x1, x2), math.max(x1, x2)
    local minY, maxY = math.min(y1, y2), math.max(y1, y2)
    local minZ, maxZ = math.min(z1, z2), math.max(z1, z2)
    return {
        minX = minX, maxX = maxX,
        minY = minY, maxY = maxY,
        minZ = minZ, maxZ = maxZ,
        xLen = maxX - minX + 1,
        yLen = maxY - minY + 1,
        zLen = maxZ - minZ + 1,
    }
end

local function runOreTunnel(nav, job, params)
    local length = math.max(1, tonumber(params.length) or 64)
    log("ore tunnel length=" .. tostring(length))
    local okStart, _, errStart = mineVeinAround(nav, job, params.ore_set, params.vein_limit, params)
    if not okStart then return false, errStart end
    for _ = 1, length do
        local stop, why = isCancelled(job)
        if stop then return false, why end
        local ok, err = stepForward(nav, job, params)
        if not ok then return false, err end
        local okV, _, errV = mineVeinAround(nav, job, params.ore_set, params.vein_limit, params)
        if not okV then return false, errV end
        local okC, errC = checkpoint(nav, job, params)
        if not okC then return false, errC end
    end
    return true, { length = length }
end

local function runSector(nav, job, params)
    local box = normalizeBox(params.x1, params.y1, params.z1, params.x2, params.y2, params.z2)
    local cells = box.xLen * box.yLen * box.zLen
    log(string.format(
        "sector x=%d..%d y=%d..%d z=%d..%d (%d blocks)",
        box.minX, box.maxX, box.minY, box.maxY, box.minZ, box.maxZ, cells
    ))

    for y = box.maxY, box.minY, -1 do
        local stop, why = isCancelled(job)
        if stop then return false, why end
        local ok, err = goTo(nav, { x = box.minX, y = y, z = box.minZ }, job, params)
        if not ok then return false, err end
        face(nav, 0)
        local eastward = true

        local okV, _, errV = mineVeinAround(nav, job, params.ore_set, params.vein_limit, params)
        if not okV then return false, errV end

        for row = 1, box.zLen do
            local stopRow, whyRow = isCancelled(job)
            if stopRow then return false, whyRow end
            if eastward then face(nav, 0) else face(nav, 2) end
            for _ = 1, box.xLen - 1 do
                ok, err = stepForward(nav, job, params)
                if not ok then return false, err end
                local okVein, _, errVein = mineVeinAround(nav, job, params.ore_set, params.vein_limit, params)
                if not okVein then return false, errVein end
                local okC, errC = checkpoint(nav, job, params)
                if not okC then return false, errC end
            end
            if row < box.zLen then
                if eastward then
                    turnRight(nav)
                    ok, err = stepForward(nav, job, params)
                    if not ok then return false, err end
                    turnRight(nav)
                else
                    turnLeft(nav)
                    ok, err = stepForward(nav, job, params)
                    if not ok then return false, err end
                    turnLeft(nav)
                end
                eastward = not eastward
                local okVein, _, errVein = mineVeinAround(nav, job, params.ore_set, params.vein_limit, params)
                if not okVein then return false, errVein end
                local okC, errC = checkpoint(nav, job, params)
                if not okC then return false, errC end
            end
        end
    end
    return true, { cells = cells }
end

local function gpsFix(timeout)
    local x, y, z, err = lib.gps.locate("self", { timeout = timeout })
    if not x then return nil, "gps: " .. tostring(err or "no fix") end
    return { x = iRound(x), y = iRound(y), z = iRound(z) }
end

local function calibrateAnchor(nav)
    local before, err = gpsFix(2)
    if not before then return nil, err end

    local fakeJob = { blocks_dug = 0, moves = 0, ores = {} }
    local okStep, errStep = stepForward(nav, fakeJob, { fuel_reserve = 6, auto_dump = false })
    if not okStep then return nil, "cannot step forward for GPS calibration: " .. tostring(errStep) end

    local after, errAfter = gpsFix(2)
    local okBack, errBack = stepBack(nav, fakeJob, { fuel_reserve = 6, auto_dump = false })
    if not okBack then return nil, "failed to step back after calibration: " .. tostring(errBack) end
    if not after then return nil, errAfter end

    local fx = iRound(after.x - before.x)
    local fz = iRound(after.z - before.z)
    if math.abs(fx) + math.abs(fz) ~= 1 then
        return nil, "GPS heading calibration failed (noise or movement blocked)"
    end

    local anchor = {
        x = before.x, y = before.y, z = before.z,
        fx = fx, fz = fz,
        ts = nowMs(),
    }
    store:set("anchor", anchor)
    return anchor
end

local function worldToLocal(anchor, x, y, z)
    local wx = x - anchor.x
    local wz = z - anchor.z
    local rx = wx * anchor.fx + wz * anchor.fz
    local rightX, rightZ = -anchor.fz, anchor.fx
    local rz = wx * rightX + wz * rightZ
    local ry = y - anchor.y
    return { x = iRound(rx), y = iRound(ry), z = iRound(rz) }
end

local function localToWorld(anchor, x, y, z)
    local rightX, rightZ = -anchor.fz, anchor.fx
    return {
        x = iRound(anchor.x + x * anchor.fx + z * rightX),
        y = iRound(anchor.y + y),
        z = iRound(anchor.z + x * anchor.fz + z * rightZ),
    }
end

local function parseOreFilter(raw)
    if not raw or raw == "" or raw == "any" or raw == "*" then return nil, "any" end
    local lower = tostring(raw):lower()
    if lower == "all" then
        local set = {}
        for k in pairs(KNOWN_ORES) do set[k] = true end
        return set, "all"
    end

    local set = {}
    local labels = {}
    for token in tostring(raw):gmatch("[^,%s]+") do
        local t = token:lower()
        local alias = ORE_ALIASES[t]
        if alias then
            for _, full in ipairs(alias) do set[full] = true end
            labels[#labels + 1] = t
        else
            if not t:find(":", 1, true) then
                if t:find("_ore$", 1) or t == "ancient_debris" then
                    t = "minecraft:" .. t
                else
                    t = "minecraft:" .. t .. "_ore"
                end
            end
            set[t] = true
            labels[#labels + 1] = t
        end
    end
    if next(set) == nil then return nil, "any" end
    return set, table.concat(labels, ",")
end

local function parseRpcOreFilter(msg)
    if msg.ores ~= nil or msg.ore ~= nil then
        return parseOreFilter(msg.ores or msg.ore)
    end
    if msg.kind == nil then return nil, nil end
    local k = tostring(msg.kind):lower()
    if ORE_ALIASES[k] then return parseOreFilter(k) end
    if k:find(":", 1, true) or k:find("_ore$") or k == "ancient_debris" then
        return parseOreFilter(k)
    end
    -- Keep legacy behavior: arbitrary `kind` strings were informational only.
    return nil, nil
end

local function mergeOreTotals(src)
    local totals = shallowCopy(store:get("ore_total", {}))
    for k, v in pairs(src or {}) do
        totals[k] = (totals[k] or 0) + v
    end
    store:set("ore_total", totals)
end

local function finishJob(job, ok, err, extra)
    job.finished_at = nowMs()
    job.ok = ok and true or false
    if not ok then job.err = tostring(err or "error") end
    if extra then
        for k, v in pairs(extra) do job[k] = v end
    end

    store:set("jobs_total", (store:get("jobs_total", 0) or 0) + 1)
    store:set("blocks_total", (store:get("blocks_total", 0) or 0) + (job.blocks_dug or 0))
    mergeOreTotals(job.ores)
    store:set("last_job", job)
    store:set("last_error", (not ok) and job.err or nil)
end

local function runMission(mode, params, forcedJobId)
    if busy then return false, "busy" end
    busy = true

    local nav = { x = 0, y = 0, z = 0, dir = 0 }
    local jobId = forcedJobId or reserveJobId()
    local job = {
        id = jobId,
        mode = mode,
        started_at = nowMs(),
        blocks_dug = 0,
        moves = 0,
        ores = {},
        params = shallowCopy(params),
    }
    activeNav = nav
    activeJob = job
    cancelJobId = nil
    cancelReason = nil

    local ok, info
    if mode == "ore" then
        ok, info = runOreTunnel(nav, job, params)
    elseif mode == "sector" then
        ok, info = runSector(nav, job, params)
    else
        ok, info = false, "unknown mode: " .. tostring(mode)
    end

    local okReturn, errReturn = goTo(nav, { x = 0, y = 0, z = 0 }, job, {
        fuel_reserve = 6, auto_dump = false, ignore_cancel = true,
    })
    if not okReturn and ok then
        ok = false
        info = "failed to return home: " .. tostring(errReturn)
    end
    face(nav, 0)
    if params.auto_dump ~= false then dropInventoryToLeft() end

    if type(info) == "table" then
        finishJob(job, ok, nil, info)
    else
        finishJob(job, ok, (not ok) and info or nil)
    end
    clearCancelFor(job)

    activeNav = nil
    activeJob = nil
    busy = false
    if ok then return true, nil, job end
    return false, info, job
end

local function formatOreMap(oreMap)
    local names = {}
    for name, n in pairs(oreMap or {}) do
        names[#names + 1] = { name = name, n = n }
    end
    table.sort(names, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(#names, 8) do
        parts[#parts + 1] = names[i].name:gsub("^minecraft:", "") .. ":" .. names[i].n
    end
    if #parts == 0 then return "-" end
    return table.concat(parts, ", ")
end

local function currentStatus()
    local last = store:get("last_job")
    local nav = activeNav or { x = 0, y = 0, z = 0, dir = 0 }
    local st = {
        busy = busy,
        fuel = turtle.getFuelLevel(),
        inventory_used = usedSlots(),
        pos = { x = nav.x, y = nav.y, z = nav.z, dir = nav.dir, facing = DIR[nav.dir].label },
        jobs_total = store:get("jobs_total", 0),
        blocks_total = store:get("blocks_total", 0),
        ore_total = store:get("ore_total", {}),
        active_job = activeJob and {
            id = activeJob.id,
            mode = activeJob.mode,
            started_at = activeJob.started_at,
            params = activeJob.params,
        } or nil,
        queue_size = #queue,
        queue_preview = queuePreview(8),
        queue_worker_running = queueWorkerRunning,
        cancel_pending = cancelJobId and true or false,
        cancel_reason = cancelReason,
        last_job = last,
        last_error = store:get("last_error"),
        anchor = store:get("anchor"),
    }
    if st.anchor then
        st.pos_abs = localToWorld(st.anchor, nav.x, nav.y, nav.z)
    end
    return st
end

local function printStatus()
    local s = currentStatus()
    print(string.format(
        "mine: busy=%s fuel=%s inv=%d/16 pos=(%d,%d,%d) face=%s",
        tostring(s.busy), tostring(s.fuel), s.inventory_used,
        s.pos.x, s.pos.y, s.pos.z, s.pos.facing
    ))
    print(string.format("jobs=%d blocks=%d", s.jobs_total, s.blocks_total))
    print(string.format("queue=%d worker=%s", s.queue_size or 0, tostring(s.queue_worker_running)))
    if s.anchor and s.pos_abs then
        print(string.format(
            "gps anchor=%d,%d,%d forward=(%d,%d) now=%d,%d,%d",
            s.anchor.x, s.anchor.y, s.anchor.z,
            s.anchor.fx, s.anchor.fz,
            s.pos_abs.x, s.pos_abs.y, s.pos_abs.z
        ))
    end
    local last = s.last_job
    if s.active_job then
        print(string.format(
            "active: id=%d mode=%s age=%s",
            s.active_job.id, tostring(s.active_job.mode), fmt.age(s.active_job.started_at)
        ))
    end
    if (s.queue_size or 0) > 0 then
        for i, q in ipairs(s.queue_preview or {}) do
            print(string.format(
                "queue[%d]: id=%d mode=%s age=%s from=%s",
                i, q.job_id, tostring(q.mode), fmt.age(q.queued_at), tostring(q.from or "?")
            ))
        end
    end
    if last then
        print(string.format(
            "last: %s %s blocks=%d moves=%d age=%s",
            tostring(last.mode), last.ok and "ok" or "fail",
            last.blocks_dug or 0, last.moves or 0, fmt.age(last.finished_at)
        ))
        if not last.ok and last.err then print("  err: " .. tostring(last.err)) end
        print("  ores: " .. formatOreMap(last.ores))
    end
end

local function toInt(raw, label)
    local n = tonumber(raw)
    if not n then return nil, "bad " .. tostring(label) .. ": " .. tostring(raw) end
    return iRound(n)
end

local function parseSectorArgs(args, offset)
    local x1, err = toInt(args[offset], "x1"); if not x1 then return nil, err end
    local y1, err2 = toInt(args[offset + 1], "y1"); if not y1 then return nil, err2 end
    local z1, err3 = toInt(args[offset + 2], "z1"); if not z1 then return nil, err3 end
    local x2, err4 = toInt(args[offset + 3], "x2"); if not x2 then return nil, err4 end
    local y2, err5 = toInt(args[offset + 4], "y2"); if not y2 then return nil, err5 end
    local z2, err6 = toInt(args[offset + 5], "z2"); if not z2 then return nil, err6 end
    return { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 }
end

local function runSectorAbs(args)
    local params, err = parseSectorArgs(args, 2)
    if not params then return false, err end
    local oreSet, oreLabel = parseOreFilter(args[8])
    params.ore_set = oreSet
    params.ore_label = oreLabel
    params.vein_limit = tonumber(args[9]) or 32
    params.fuel_reserve = 16
    params.auto_dump = true

    local nav = { x = 0, y = 0, z = 0, dir = 0 }
    local anchor, errA = calibrateAnchor(nav)
    if not anchor then return false, errA end

    local a = worldToLocal(anchor, params.x1, params.y1, params.z1)
    local b = worldToLocal(anchor, params.x2, params.y2, params.z2)
    params.x1, params.y1, params.z1 = a.x, a.y, a.z
    params.x2, params.y2, params.z2 = b.x, b.y, b.z

    local ok, info, job = runMission("sector", params)
    if not ok then return false, info end
    print(string.format("done: sector-abs blocks=%d moves=%d ores=%s",
        job.blocks_dug, job.moves, formatOreMap(job.ores)))
    return true
end

-- Backwards-compat: a bare depth or `mine N` runs a sector job
-- (1x depth x 1) — replaces the old depth-only shaft mode.
local function runDepthSector(depth, oreSet, oreLabel, veinLimit)
    return runMission("sector", {
        x1 = 0, y1 = -depth + 1, z1 = 0,
        x2 = 0, y2 = 0,         z2 = 0,
        ore_set = oreSet, ore_label = oreLabel,
        vein_limit = veinLimit or 0,
        fuel_reserve = 16, auto_dump = true,
    })
end

local function runCli(args)
    local cmd = args[1]
    if not cmd or cmd == "" then
        local ok, info, job = runDepthSector(64)
        if not ok then return false, info end
        print(string.format("done: depth=%d blocks=%d moves=%d", 64, job.blocks_dug, job.moves))
        return true
    end

    local maybeDepth = tonumber(cmd)
    if maybeDepth then
        local ok, info, job = runDepthSector(maybeDepth)
        if not ok then return false, info end
        print(string.format("done: depth=%d blocks=%d moves=%d",
            maybeDepth, job.blocks_dug, job.moves))
        return true
    end

    if cmd == "help" or cmd == "-h" or cmd == "--help" then
        print("mine commands:")
        print("  mine [depth]                                  vertical 1x1xN sector")
        print("  mine ore <ores> [length] [vein_limit]")
        print("  mine sector <x1> <y1> <z1> <x2> <y2> <z2> [ores] [vein_limit]")
        print("  mine sector-abs <x1> <y1> <z1> <x2> <y2> <z2> [ores] [vein_limit]")
        print("  mine status")
        print("  mine cancel [reason]")
        print("  mine calibrate")
        print("  mine listen")
        print("")
        print("ore aliases: coal, iron, copper, gold, redstone, lapis, diamond, emerald, quartz, debris")
        return true
    end

    if cmd == "status" then
        printStatus()
        return true
    end

    if cmd == "calibrate" then
        local nav = { x = 0, y = 0, z = 0, dir = 0 }
        local anchor, err = calibrateAnchor(nav)
        if not anchor then return false, err end
        print(string.format(
            "anchor set: %d,%d,%d forward=(%d,%d)",
            anchor.x, anchor.y, anchor.z, anchor.fx, anchor.fz
        ))
        return true
    end

    if cmd == "cancel" or cmd == "stop" then
        local reason = args[2] or "manual cancel"
        local ok, info, id = requestCancel(reason)
        if not ok then return false, info end
        print(string.format("cancel requested for job #%d: %s", id, info))
        return true
    end

    if cmd == "ore" then
        local oreSet, oreLabel = parseOreFilter(args[2])
        if not oreSet then return false, "ore mode needs an ore filter" end
        local ok, info, job = runMission("ore", {
            ore_set = oreSet,
            ore_label = oreLabel,
            length = tonumber(args[3]) or 64,
            vein_limit = tonumber(args[4]) or 48,
            fuel_reserve = 16,
            auto_dump = true,
        })
        if not ok then return false, info end
        print(string.format("done: ore blocks=%d moves=%d ores=%s",
            job.blocks_dug, job.moves, formatOreMap(job.ores)))
        return true
    end

    if cmd == "sector" then
        local params, err = parseSectorArgs(args, 2)
        if not params then return false, err end
        local oreSet, oreLabel = parseOreFilter(args[8])
        params.ore_set = oreSet
        params.ore_label = oreLabel
        params.vein_limit = tonumber(args[9]) or 32
        params.fuel_reserve = 20
        params.auto_dump = true
        local ok, info, job = runMission("sector", params)
        if not ok then return false, info end
        print(string.format("done: sector blocks=%d moves=%d ores=%s",
            job.blocks_dug, job.moves, formatOreMap(job.ores)))
        return true
    end

    if cmd == "sector-abs" or cmd == "sector_abs" then
        return runSectorAbs(args)
    end

    if cmd == "listen" then
        return "listen"
    end

    return false, "unknown command: " .. tostring(cmd)
end

local function mineOrder(msg, env)
    local function aclAllowed(msgType)
        if not (unison.rpc and unison.rpc.allowed) then return true end
        return unison.rpc.allowed(msgType, env)
    end
    if not aclAllowed("mine_order") then
        unison.rpc.reply(env, { type = "mine_reply", ok = false, err = "acl denied", ts = nowMs() })
        return
    end
    if msg.cancel == true or msg.action == "cancel" then
        local okCancel, whyCancel, idCancel = requestCancel(msg.reason or "remote cancel")
        unison.rpc.reply(env, {
            type = "mine_reply",
            ok = okCancel and true or false,
            cancelled = okCancel and true or false,
            job_id = idCancel,
            err = (not okCancel) and whyCancel or nil,
            reason = okCancel and whyCancel or nil,
            ts = nowMs(),
        })
        return
    end

    local mode = tostring(msg.mode or "")
    if mode == "" then
        if msg.x1 and msg.y1 and msg.z1 and msg.x2 and msg.y2 and msg.z2 then mode = "sector"
        elseif msg.ores or msg.ore then mode = "ore"
        else mode = "depth" end
    end

    local ok, err, job
    if mode == "depth" or mode == "shaft" then
        -- Depth-only requests collapse to a 1x1xN sector.
        local depth = math.max(1, tonumber(msg.depth) or 32)
        local oreSet, oreLabel = parseRpcOreFilter(msg)
        ok, err, job = runMission("sector", {
            x1 = 0, y1 = -depth + 1, z1 = 0,
            x2 = 0, y2 = 0,         z2 = 0,
            ore_set = oreSet, ore_label = oreLabel,
            vein_limit = tonumber(msg.vein_limit) or 0,
            fuel_reserve = 16, auto_dump = true,
        })
    elseif mode == "ore" then
        local oreSet, oreLabel = parseRpcOreFilter(msg)
        if not oreSet then
            ok, err = false, "ore mode requires ore filter"
        else
            ok, err, job = runMission("ore", {
                ore_set = oreSet,
                ore_label = oreLabel,
                length = tonumber(msg.length) or tonumber(msg.depth) or 64,
                vein_limit = tonumber(msg.vein_limit) or 48,
                fuel_reserve = 16,
                auto_dump = true,
            })
        end
    elseif mode == "sector" then
        local oreSet, oreLabel = parseRpcOreFilter(msg)
        local p = {
            x1 = tonumber(msg.x1), y1 = tonumber(msg.y1), z1 = tonumber(msg.z1),
            x2 = tonumber(msg.x2), y2 = tonumber(msg.y2), z2 = tonumber(msg.z2),
            ore_set = oreSet,
            ore_label = oreLabel,
            vein_limit = tonumber(msg.vein_limit) or 32,
            fuel_reserve = 20,
            auto_dump = true,
        }
        if not (p.x1 and p.y1 and p.z1 and p.x2 and p.y2 and p.z2) then
            ok, err = false, "sector mode needs x1 y1 z1 x2 y2 z2"
        else
            p.x1, p.y1, p.z1 = iRound(p.x1), iRound(p.y1), iRound(p.z1)
            p.x2, p.y2, p.z2 = iRound(p.x2), iRound(p.y2), iRound(p.z2)

            if msg.absolute then
                local nav = { x = 0, y = 0, z = 0, dir = 0 }
                local anchor, errA = calibrateAnchor(nav)
                if not anchor then
                    ok, err = false, errA
                else
                    local a = worldToLocal(anchor, p.x1, p.y1, p.z1)
                    local b = worldToLocal(anchor, p.x2, p.y2, p.z2)
                    p.x1, p.y1, p.z1 = a.x, a.y, a.z
                    p.x2, p.y2, p.z2 = b.x, b.y, b.z
                    ok, err, job = runMission("sector", p)
                end
            else
                ok, err, job = runMission("sector", p)
            end
        end
    else
        ok, err = false, "unknown mine mode: " .. tostring(mode)
    end

    if ok and job then
        unison.rpc.reply(env, {
            type = "mine_reply",
            ok = true,
            mode = mode,
            job_id = job.id,
            dug = job.blocks_dug,
            moves = job.moves,
            ores = job.ores,
            ts = nowMs(),
        })
    else
        unison.rpc.reply(env, {
            type = "mine_reply",
            ok = false,
            mode = mode,
            err = tostring(err or "unknown error"),
            ts = nowMs(),
        })
    end
end

local function mineStatus(_, env)
    local function aclAllowed(msgType)
        if not (unison.rpc and unison.rpc.allowed) then return true end
        return unison.rpc.allowed(msgType, env)
    end
    if not aclAllowed("mine_status") then
        unison.rpc.reply(env, { type = "mine_reply", ok = false, err = "acl denied" })
        return
    end
    local s = currentStatus()
    local dug = 0
    if s.last_job and s.last_job.blocks_dug then dug = s.last_job.blocks_dug end
    unison.rpc.reply(env, {
        type = "mine_reply",
        ok = true,
        busy = s.busy,
        dug = dug,
        fuel = s.fuel,
        inventory_used = s.inventory_used,
        position = s.pos,
        position_abs = s.pos_abs,
        jobs_total = s.jobs_total,
        blocks_total = s.blocks_total,
        ore_total = s.ore_total,
        active_job = s.active_job,
        cancel_pending = s.cancel_pending,
        cancel_reason = s.cancel_reason,
        last_job = s.last_job,
        last_error = s.last_error,
    })
end

local function mineCancel(msg, env)
    local function aclAllowed(msgType)
        if not (unison.rpc and unison.rpc.allowed) then return true end
        return unison.rpc.allowed(msgType, env)
    end
    if not aclAllowed("mine_cancel") then
        unison.rpc.reply(env, { type = "mine_reply", ok = false, err = "acl denied" })
        return
    end
    local ok, why, id = requestCancel(msg and msg.reason or "remote cancel")
    unison.rpc.reply(env, {
        type = "mine_reply",
        ok = ok and true or false,
        cancelled = ok and true or false,
        job_id = id,
        err = (not ok) and why or nil,
        reason = ok and why or nil,
        ts = nowMs(),
    })
end

local args = { ... }
local cmdResult, cmdErr = runCli(args)

if cmdResult == "listen" then
    app.runService({
        intro = "mine listening as turtle " .. tostring(unison.id) .. " (Q to stop)",
        outro = "stopping mine listener.",
        handlers = {
            mine_order = mineOrder,
            mine_status = mineStatus,
            mine_cancel = mineCancel,
        },
    })
elseif not cmdResult then
    printError("mine: " .. tostring(cmdErr))
    print("try: mine help")
end
