-- scanner 1.3.0
-- Spherical scanner with robust obstacle handling.
--
-- Performance fix vs 1.2.x: kvstore.set() rewrites the whole JSON file
-- on every call, so a 400k-block scan was O(N²) on disk. We now use
-- kvstore.setNoSave + periodic flush() (every BATCH_FLUSH records),
-- keeping disk cost roughly linear.
--
-- Filter: only ATLAS_KIND blocks (ores, chests, ancient debris) are
-- persisted by default — saves space and avoids a huge json.
-- Pass `scanner sphere <r> all` (or scanner_order { all=true }) to
-- record every non-air block instead.

if not turtle then print("scanner: must run on a turtle"); return end

local lib   = unison.lib
local app   = lib.app
local store = lib.kvstore.open("scanner-map")

local ATLAS_KIND = {
    ["minecraft:diamond_ore"]            = "diamond",
    ["minecraft:deepslate_diamond_ore"]  = "diamond",
    ["minecraft:iron_ore"]               = "iron",
    ["minecraft:deepslate_iron_ore"]     = "iron",
    ["minecraft:gold_ore"]               = "gold",
    ["minecraft:deepslate_gold_ore"]     = "gold",
    ["minecraft:redstone_ore"]           = "redstone",
    ["minecraft:deepslate_redstone_ore"] = "redstone",
    ["minecraft:lapis_ore"]              = "lapis",
    ["minecraft:deepslate_lapis_ore"]    = "lapis",
    ["minecraft:emerald_ore"]            = "emerald",
    ["minecraft:deepslate_emerald_ore"]  = "emerald",
    ["minecraft:copper_ore"]             = "copper",
    ["minecraft:deepslate_copper_ore"]   = "copper",
    ["minecraft:coal_ore"]               = "coal",
    ["minecraft:deepslate_coal_ore"]     = "coal",
    ["minecraft:ancient_debris"]         = "ancient_debris",
    ["minecraft:chest"]                  = "chest",
    ["minecraft:trapped_chest"]          = "chest",
    ["minecraft:barrel"]                 = "barrel",
}

local DIR = {
    [0] = { dx = 1,  dz = 0 },
    [1] = { dx = 0,  dz = 1 },
    [2] = { dx = -1, dz = 0 },
    [3] = { dx = 0,  dz = -1 },
}

local MOVE_RETRIES = 6
local MOVE_SLEEP = 0.15

local pos = { x = 0, y = 0, z = 0, dir = 0 }
local hasGps = false
local busy = false
local origin = nil

local function facing()
    local d = DIR[pos.dir]
    return d.dx, d.dz
end

local function nameFromInspect(info)
    if type(info) == "table" then return info.name or "unknown:block" end
    if type(info) == "string" and info ~= "" then return info end
    return "unknown:block"
end

local function gpsHere()
    local x, y, z = unison.lib.gps.locate("self")
    if not x then return nil end
    return { x = x, y = y, z = z }
end

local function turnLeft()
    turtle.turnLeft()
    pos.dir = (pos.dir + 3) % 4
end

local function turnRight()
    turtle.turnRight()
    pos.dir = (pos.dir + 1) % 4
end

local function faceDir(target)
    target = (target % 4 + 4) % 4
    local diff = (target - pos.dir) % 4
    if diff == 0 then return end
    if diff == 1 then
        turnRight()
    elseif diff == 2 then
        turnRight(); turnRight()
    else
        turnLeft()
    end
end

-- Persist-strategy state. recordAll=false (default) means only
-- ATLAS_KIND blocks land in the local store; everything else is
-- counted in stats but not stored. Hot-loop write avoids the O(N²)
-- save by using setNoSave + a periodic flush.
local recordAll = false
local pendingFlush = 0
local BATCH_FLUSH = 256

local function maybeFlush()
    if pendingFlush >= BATCH_FLUSH then
        store:flush()
        pendingFlush = 0
    end
end

local function record(x, y, z, name)
    local wx, wy, wz = x, y, z
    if origin then
        wx, wy, wz = origin.x + x, origin.y + y, origin.z + z
    end
    name = name or "unknown:block"
    if name == "minecraft:air" or name == "minecraft:cave_air" then return end

    local kind = ATLAS_KIND[name]
    if recordAll or kind then
        local key = string.format("%d,%d,%d", wx, wy, wz)
        store:setNoSave(key, { name = name, ts = os.epoch("utc") })
        pendingFlush = pendingFlush + 1
        maybeFlush()
    end

    if kind and unison.rpc and unison.rpc.send then
        unison.rpc.send("broadcast", {
            type = "atlas_mark",
            from = tostring(unison.id),
            name = string.format("%s-%d-%d-%d", kind, wx, wy, wz),
            kind = kind, x = wx, y = wy, z = wz,
            tags = { "scanner", name },
        })
    end
end

local function tryForward()
    local dx, dz = facing()
    local tx, ty, tz = pos.x + dx, pos.y, pos.z + dz
    local lastName = nil
    for _ = 1, MOVE_RETRIES do
        if turtle.forward() then
            pos.x, pos.z = tx, tz
            return true
        end
        local present, info = turtle.inspect()
        if present then
            lastName = nameFromInspect(info)
            record(tx, ty, tz, lastName)
        end
        turtle.attack()
        sleep(MOVE_SLEEP)
    end
    return false, string.format("blocked by %s at %d,%d,%d", tostring(lastName or "unknown:block"), tx, ty, tz)
end

local function tryUp()
    local tx, ty, tz = pos.x, pos.y + 1, pos.z
    local lastName = nil
    for _ = 1, MOVE_RETRIES do
        if turtle.up() then
            pos.y = ty
            return true
        end
        local present, info = turtle.inspectUp()
        if present then
            lastName = nameFromInspect(info)
            record(tx, ty, tz, lastName)
        end
        turtle.attackUp()
        sleep(MOVE_SLEEP)
    end
    return false, string.format("blocked above by %s at %d,%d,%d", tostring(lastName or "unknown:block"), tx, ty, tz)
end

local function tryDown()
    local tx, ty, tz = pos.x, pos.y - 1, pos.z
    local lastName = nil
    for _ = 1, MOVE_RETRIES do
        if turtle.down() then
            pos.y = ty
            return true
        end
        local present, info = turtle.inspectDown()
        if present then
            lastName = nameFromInspect(info)
            record(tx, ty, tz, lastName)
        end
        turtle.attackDown()
        sleep(MOVE_SLEEP)
    end
    return false, string.format("blocked below by %s at %d,%d,%d", tostring(lastName or "unknown:block"), tx, ty, tz)
end

local function goTo(x, y, z)
    while pos.y < y do local ok, err = tryUp();      if not ok then return false, err end end
    while pos.y > y do local ok, err = tryDown();    if not ok then return false, err end end
    while pos.x < x do faceDir(0); local ok, err = tryForward(); if not ok then return false, err end end
    while pos.x > x do faceDir(2); local ok, err = tryForward(); if not ok then return false, err end end
    while pos.z < z do faceDir(1); local ok, err = tryForward(); if not ok then return false, err end end
    while pos.z > z do faceDir(3); local ok, err = tryForward(); if not ok then return false, err end end
    return true
end

local function inspectAndRecordForward()
    local dx, dz = facing()
    local present, info = turtle.inspect()
    if present then record(pos.x + dx, pos.y, pos.z + dz, nameFromInspect(info)) end
end

local function scanAround()
    local present, info
    present, info = turtle.inspectDown(); if present then record(pos.x, pos.y - 1, pos.z, nameFromInspect(info)) end
    present, info = turtle.inspectUp();   if present then record(pos.x, pos.y + 1, pos.z, nameFromInspect(info)) end

    inspectAndRecordForward()           -- front
    turnLeft(); inspectAndRecordForward(); turnRight()      -- left
    turnRight(); inspectAndRecordForward(); turnLeft()      -- right
    turnRight(); turnRight(); inspectAndRecordForward(); turnRight(); turnRight() -- back
end

local function calibrate()
    local before = gpsHere()
    if not before then return false end

    local ok, err = tryForward()
    if not ok then return false, err end

    local after = gpsHere()
    if not after then return false, "gps locate failed after calibration step" end

    local fx, fz = after.x - before.x, after.z - before.z
    local dir = nil
    if fx == 1 and fz == 0 then dir = 0
    elseif fx == 0 and fz == 1 then dir = 1
    elseif fx == -1 and fz == 0 then dir = 2
    elseif fx == 0 and fz == -1 then dir = 3
    else return false, "gps heading calibration failed" end

    faceDir((dir + 2) % 4)
    local okBack, errBack = tryForward()
    if not okBack then return false, "failed to return after calibration: " .. tostring(errBack) end
    faceDir(dir)

    origin = before
    pos = { x = 0, y = 0, z = 0, dir = dir }
    hasGps = true
    return true
end

local function scanSphere(radius)
    if busy then return false, "busy" end
    busy = true

    radius = math.max(1, math.floor(tonumber(radius) or 6))
    local r2 = radius * radius
    local before = store:size()
    local startDir = pos.dir
    local skipped = 0

    -- Estimate sphere cell count for the progress line.
    local total = 0
    for y = -radius, radius do
        for z = -radius, radius do
            for x = -radius, radius do
                if x*x + y*y + z*z <= r2 then total = total + 1 end
            end
        end
    end
    print(string.format("scanner: sphere r=%d ≈ %d cells", radius, total))
    local visited = 0
    local nextReport = 0

    local function finish(ok, info)
        goTo(0, 0, 0)
        faceDir(startDir)
        scanAround()
        store:flush()                 -- final persistence
        pendingFlush = 0
        busy = false
        if ok then
            return true, { added = store:size() - before, skipped = skipped }
        end
        return false, info
    end

    for y = -radius, radius do
        for z = -radius, radius do
            local xFrom, xTo, step = -radius, radius, 1
            if ((y + z) % 2) ~= 0 then xFrom, xTo, step = radius, -radius, -1 end
            local x = xFrom
            while true do
                if x * x + y * y + z * z <= r2 then
                    local ok, err = goTo(x, y, z)
                    if not ok then
                        skipped = skipped + 1
                    else
                        scanAround()
                    end
                    visited = visited + 1
                    if visited >= nextReport then
                        local pct = math.floor(100 * visited / math.max(1, total))
                        print(string.format("  %d/%d cells (%d%%)  found=%d skipped=%d",
                            visited, total, pct, store:size() - before, skipped))
                        nextReport = visited + math.max(10, math.floor(total / 20))
                    end
                end
                if x == xTo then break end
                x = x + step
            end
        end
    end
    return finish(true)
end

local args = { ... }
local mode = args[1]

if mode == "listen" then
    app.runService({
        intro = "scanner listening as turtle " .. tostring(unison.id) .. "  (Q to stop)",
        outro = "stopping scanner listener.",
        busy_on_handler = true,
        handlers = {
            scanner_order = function(msg, env)
                if not hasGps then calibrate() end
                recordAll = msg.all and true or false
                local radius = msg.radius or msg.r or msg.length or 6
                local ok, info = scanSphere(radius)
                unison.rpc.reply(env, {
                    type = "scanner_reply",
                    ok = ok and true or false,
                    blocks_added = ok and (info.added or 0) or 0,
                    skipped = ok and (info.skipped or 0) or 0,
                    err = (not ok) and info or nil,
                    radius = math.max(1, math.floor(tonumber(radius) or 6)),
                })
            end,
            scanner_status = function(_, env)
                local dx, dz = facing()
                local abs = origin and { origin.x + pos.x, origin.y + pos.y, origin.z + pos.z } or nil
                unison.rpc.reply(env, {
                    type = "scanner_reply", ok = true,
                    busy = busy, recorded = store:size(),
                    position = { pos.x, pos.y, pos.z },
                    position_abs = abs,
                    facing = { dx, dz },
                })
            end,
        },
    })
elseif mode == "sphere" or mode == "area" then
    -- Optional `all` flag: scanner sphere 30 all
    for i = 3, #args do
        if args[i] == "all" or args[i] == "--all" or args[i] == "-a" then
            recordAll = true
        end
    end
    local okCal, errCal = calibrate()
    if not okCal then
        print("scanner: GPS calibrate failed; using relative coords (origin=start)")
        if errCal then print("  reason: " .. tostring(errCal)) end
        origin = nil
        pos = { x = 0, y = 0, z = 0, dir = 0 }
    else
        local dx, dz = facing()
        print(string.format("scanner: anchored at %d,%d,%d facing dx=%d dz=%d",
            origin.x, origin.y, origin.z, dx, dz))
    end
    print("scanner: persistence = " .. (recordAll and "all blocks" or "ores+chests only"))
    local ok, info = scanSphere(args[2])
    if ok then
        print(string.format("scanned sphere: new blocks=%d skipped=%d",
            info.added or 0, info.skipped or 0))
    else printError("scanner: " .. tostring(info)) end
else
    print("usage:")
    print("  scanner sphere <radius> [all]   ores+chests by default; 'all' to keep every block")
    print("  scanner area <radius> [all]     (alias)")
    print("  scanner listen")
end
