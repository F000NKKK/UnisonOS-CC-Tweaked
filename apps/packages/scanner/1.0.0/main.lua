-- scanner — turtle area scanner. Walks a rectangular area in a snake
-- pattern, inspects the blocks below / front / above at every step, and
-- records anything interesting into the local map and (optionally) atlas.
--
-- Usage:
--   scanner area <length> [<width>]      one-shot scan; default 1xN
--   scanner listen                       run scanner_order RPCs
--
-- Output:
--   Local map at /unison/state/scanner-map.json:
--     { "<x>,<y>,<z>": { name="minecraft:diamond_ore", ts=... }, ... }
--   Atlas marks (kind="block"): pushed via atlas_mark over the bus when
--   ATLAS_MARK_KINDS matches the block name (default: ores + chests).
--
-- Requires GPS (a beacon network in your world) for absolute positioning.
-- Without GPS the scan still records relative coords (origin = start).

local fsLib   = unison.lib.fs
local jsonLib = unison.lib.json

local MAP_FILE = "/unison/state/scanner-map.json"

local map = fsLib.readJson(MAP_FILE) or {}
local function saveMap() fsLib.writeJson(MAP_FILE, map) end

local ATLAS_MARK_KINDS = {
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

local busy = false

----------------------------------------------------------------------
-- Position tracking
----------------------------------------------------------------------

-- We track relative offsets from start; if GPS is available we anchor
-- to absolute coordinates and detect facing by walking.
local pos = { x = 0, y = 0, z = 0, dx = 0, dz = -1 }   -- default facing north
local origin = { x = 0, y = 0, z = 0 }
local hasGps = false

local function gpsHere()
    if not gps then return nil end
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z } end
    return nil
end

local function calibrate()
    local before = gpsHere()
    if not before then return false end
    -- try to step forward to detect facing; if blocked, dig + try
    local ok = turtle.forward()
    if not ok then
        if not turtle.dig() then return false end
        ok = turtle.forward()
        if not ok then return false end
    end
    local after = gpsHere()
    if not after then return false end
    pos = { x = after.x, y = after.y, z = after.z,
            dx = after.x - before.x, dz = after.z - before.z }
    origin = { x = before.x, y = before.y, z = before.z }
    -- step back to start
    turtle.back()
    pos.x = before.x; pos.y = before.y; pos.z = before.z
    hasGps = true
    return true
end

local function turnLeft()
    turtle.turnLeft()
    pos.dx, pos.dz = pos.dz, -pos.dx
end

local function turnRight()
    turtle.turnRight()
    pos.dx, pos.dz = -pos.dz, pos.dx
end

local function moveForward()
    if not turtle.forward() then return false end
    pos.x = pos.x + pos.dx; pos.z = pos.z + pos.dz
    return true
end

local function moveUp()    if turtle.up()   then pos.y = pos.y + 1; return true end; return false end
local function moveDown()  if turtle.down() then pos.y = pos.y - 1; return true end; return false end

----------------------------------------------------------------------
-- Inspection
----------------------------------------------------------------------

local function recordBlock(x, y, z, name)
    if not name or name == "minecraft:air" or name == "minecraft:cave_air" then return end
    local key = string.format("%d,%d,%d", x, y, z)
    map[key] = { name = name, ts = os.epoch("utc") }

    local kind = ATLAS_MARK_KINDS[name]
    if kind and unison.rpc and unison.rpc.send then
        unison.rpc.send("broadcast", {
            type = "atlas_mark",
            from = tostring(unison.id),
            name = string.format("%s-%d-%d-%d", kind, x, y, z),
            kind = kind,
            x = x, y = y, z = z,
            tags = { "scanner", name },
        })
    end
end

local function scanAround()
    -- inspect down, front, up
    local present, info
    present, info = turtle.inspectDown()
    if present then recordBlock(pos.x, pos.y - 1, pos.z, info and info.name) end

    present, info = turtle.inspectUp()
    if present then recordBlock(pos.x, pos.y + 1, pos.z, info and info.name) end

    present, info = turtle.inspect()
    if present then recordBlock(pos.x + pos.dx, pos.y, pos.z + pos.dz, info and info.name) end
end

----------------------------------------------------------------------
-- Pattern walker
----------------------------------------------------------------------

local function scanArea(length, width)
    if busy then return false, "busy" end
    busy = true
    length = math.max(1, tonumber(length) or 8)
    width  = math.max(1, tonumber(width) or 1)

    local found = 0
    local before = 0; for _ in pairs(map) do before = before + 1 end

    for col = 1, width do
        for row = 1, length do
            scanAround()
            if row < length then
                if not moveForward() then
                    busy = false; saveMap()
                    return false, "blocked at row " .. row .. " col " .. col
                end
            end
        end
        if col < width then
            -- snake turn
            if col % 2 == 1 then
                turnRight(); moveForward(); turnRight()
            else
                turnLeft(); moveForward(); turnLeft()
            end
        end
    end

    -- final scan
    scanAround()
    saveMap()

    local after = 0; for _ in pairs(map) do after = after + 1 end
    found = after - before
    busy = false
    return true, found
end

----------------------------------------------------------------------
-- RPC
----------------------------------------------------------------------

local function setupRpc()
    if not (unison.rpc and unison.rpc.on) then return end
    unison.rpc.off("scanner_order"); unison.rpc.off("scanner_status")

    unison.rpc.on("scanner_order", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        if not hasGps then calibrate() end
        local ok, info = scanArea(msg.length, msg.width)
        unison.rpc.send(from, {
            type = "scanner_reply", from = tostring(unison.id),
            in_reply_to = env and env.id,
            ok = ok or false,
            blocks_added = ok and info or 0,
            err = (not ok) and info or nil,
        })
    end)

    unison.rpc.on("scanner_status", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local total = 0; for _ in pairs(map) do total = total + 1 end
        unison.rpc.send(from, {
            type = "scanner_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = true,
            busy = busy, recorded = total,
            position = { pos.x, pos.y, pos.z },
            facing = { pos.dx, pos.dz },
        })
    end)
end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------

if not turtle then print("scanner: must run on a turtle"); return end

local args = { ... }
local mode = args[1]

if mode == "listen" then
    setupRpc()
    print("scanner listening as turtle " .. tostring(unison.id))
    print("press Q to stop")
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "char" and (p1 == "q" or p1 == "Q") then break end
        if ev == "key" and p1 == keys.q then break end
    end
    if unison.rpc and unison.rpc.off then
        unison.rpc.off("scanner_order"); unison.rpc.off("scanner_status")
    end
    print("stopping scanner listener.")
elseif mode == "area" then
    if not calibrate() then
        print("scanner: GPS calibrate failed; using relative coords (origin=start)")
    else
        print(string.format("scanner: anchored at %d,%d,%d facing dx=%d dz=%d",
            pos.x, pos.y, pos.z, pos.dx, pos.dz))
    end
    local ok, info = scanArea(args[2], args[3])
    if ok then print("scanned, new blocks recorded: " .. info)
    else printError("scanner: " .. tostring(info)) end
else
    print("usage:")
    print("  scanner area <length> [<width>]    one-shot scan")
    print("  scanner listen                     subscribe to bus")
end
