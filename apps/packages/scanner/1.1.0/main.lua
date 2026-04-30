-- scanner 1.1.0 — UniAPI rewrite. Same snake-pattern walker; uses
-- lib.app for listen, lib.kvstore for persisted map.

if not turtle then print("scanner: must run on a turtle"); return end

local lib   = unison.lib
local app   = lib.app
local store = lib.kvstore.open("scanner-map")   -- raw blocks dict

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

local pos = { x = 0, y = 0, z = 0, dx = 0, dz = -1 }
local hasGps = false
local busy = false

local function gpsHere()
    if not gps then return nil end
    local x, y, z = gps.locate(2)
    if x then return { x = x, y = y, z = z } end
end

local function calibrate()
    local before = gpsHere(); if not before then return false end
    if not turtle.forward() then
        if not turtle.dig() then return false end
        if not turtle.forward() then return false end
    end
    local after = gpsHere(); if not after then return false end
    pos = { x = after.x, y = after.y, z = after.z,
            dx = after.x - before.x, dz = after.z - before.z }
    turtle.back(); pos.x = before.x; pos.y = before.y; pos.z = before.z
    hasGps = true
    return true
end

local function turnLeft()  turtle.turnLeft();  pos.dx, pos.dz = pos.dz, -pos.dx end
local function turnRight() turtle.turnRight(); pos.dx, pos.dz = -pos.dz, pos.dx end
local function moveForward()
    if not turtle.forward() then return false end
    pos.x = pos.x + pos.dx; pos.z = pos.z + pos.dz
    return true
end

local function record(x, y, z, name)
    if not name or name == "minecraft:air" or name == "minecraft:cave_air" then return end
    local key = string.format("%d,%d,%d", x, y, z)
    store:set(key, { name = name, ts = os.epoch("utc") })

    local kind = ATLAS_KIND[name]
    if kind and unison.rpc and unison.rpc.send then
        unison.rpc.send("broadcast", {
            type = "atlas_mark",
            from = tostring(unison.id),
            name = string.format("%s-%d-%d-%d", kind, x, y, z),
            kind = kind, x = x, y = y, z = z,
            tags = { "scanner", name },
        })
    end
end

local function scanAround()
    local p, i
    p, i = turtle.inspectDown(); if p then record(pos.x, pos.y - 1, pos.z, i and i.name) end
    p, i = turtle.inspectUp();   if p then record(pos.x, pos.y + 1, pos.z, i and i.name) end
    p, i = turtle.inspect();     if p then record(pos.x + pos.dx, pos.y, pos.z + pos.dz, i and i.name) end
end

local function scanArea(length, width)
    if busy then return false, "busy" end
    busy = true
    length = math.max(1, tonumber(length) or 8)
    width  = math.max(1, tonumber(width) or 1)
    local before = store:size()
    for col = 1, width do
        for row = 1, length do
            scanAround()
            if row < length and not moveForward() then
                busy = false
                return false, "blocked at row " .. row .. " col " .. col
            end
        end
        if col < width then
            if col % 2 == 1 then turnRight(); moveForward(); turnRight()
            else                 turnLeft();  moveForward(); turnLeft() end
        end
    end
    scanAround()
    busy = false
    return true, store:size() - before
end

local args = { ... }
local mode = args[1]

if mode == "listen" then
    app.runService({
        intro = "scanner listening as turtle " .. tostring(unison.id) .. "  (Q to stop)",
        outro = "stopping scanner listener.",
        handlers = {
            scanner_order = function(msg, env)
                if not hasGps then calibrate() end
                local ok, info = scanArea(msg.length, msg.width)
                unison.rpc.reply(env, {
                    type = "scanner_reply",
                    ok = ok or false,
                    blocks_added = ok and info or 0,
                    err = (not ok) and info or nil,
                })
            end,
            scanner_status = function(msg, env)
                unison.rpc.reply(env, {
                    type = "scanner_reply", ok = true,
                    busy = busy, recorded = store:size(),
                    position = { pos.x, pos.y, pos.z },
                    facing = { pos.dx, pos.dz },
                })
            end,
        },
    })
elseif mode == "area" then
    if not calibrate() then
        print("scanner: GPS calibrate failed; using relative coords (origin=start)")
    else
        print(string.format("scanner: anchored at %d,%d,%d facing dx=%d dz=%d",
            pos.x, pos.y, pos.z, pos.dx, pos.dz))
    end
    local ok, info = scanArea(args[2], args[3])
    if ok then print("scanned, new blocks: " .. info)
    else printError("scanner: " .. tostring(info)) end
else
    print("usage:")
    print("  scanner area <length> [<width>]")
    print("  scanner listen")
end
