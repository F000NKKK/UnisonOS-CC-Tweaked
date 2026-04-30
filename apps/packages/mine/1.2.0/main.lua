-- mine 1.2.0 — UniAPI rewrite. Same vertical-shaft logic; uses
-- unison.lib.app.runService for the listen mode + rpc.reply.

local app = unison.lib.app

if not turtle then print("mine: must run on a turtle"); return end

local CHEST_SIDE = "left"
local FUEL_SLOT  = 1
local KEEP_FREE  = 4

local busy, lastDug = false, 0

local function log(m) print("[mine] " .. m) end

local function usedSlots()
    local n = 0
    for i = 1, 16 do if turtle.getItemCount(i) > 0 then n = n + 1 end end
    return n
end

local function refuel()
    if turtle.getFuelLevel() == "unlimited" then return true end
    if turtle.getFuelLevel() > 0 then return true end
    local old = turtle.getSelectedSlot(); turtle.select(FUEL_SLOT)
    local ok = turtle.refuel(1); turtle.select(old)
    if not ok then log("No fuel! Slot " .. FUEL_SLOT); return false end
    return true
end

local function dumpToChest()
    log("Dumping loot...")
    turtle.turnLeft()
    for i = 1, 16 do
        if i ~= FUEL_SLOT then
            turtle.select(i)
            local d = turtle.getItemDetail(i)
            if d and d.name ~= "minecraft:coal" and d.name ~= "minecraft:charcoal" then
                turtle.drop()
            end
        end
    end
    turtle.select(1); turtle.turnRight()
end

local function safeStep(detect, dig, attack, move)
    while detect() do dig(); sleep(0.4) end
    while not move() do dig(); attack(); sleep(0.2) end
end
local function goDown() safeStep(turtle.detectDown, turtle.digDown, turtle.attackDown, turtle.down) end
local function goUp()   safeStep(turtle.detectUp,   turtle.digUp,   turtle.attackUp,   turtle.up)   end

local function runDig(depth)
    if busy then return false, "busy" end
    busy = true
    log("Depth: " .. depth .. " fuel=" .. tostring(turtle.getFuelLevel()))
    if not refuel() then busy = false; return false, "no fuel" end
    local dug = 0
    for _ = 1, depth do
        if not refuel() then break end
        goDown(); dug = dug + 1
        if dug % 5 == 0 then log("Dug: " .. dug) end
        if 16 - usedSlots() <= KEEP_FREE then
            log("Inv full, returning")
            for _ = 1, dug do goUp() end
            dumpToChest()
            for _ = 1, dug do goDown() end
        end
    end
    log("Returning")
    for _ = 1, dug do goUp() end
    dumpToChest()
    log("Done. Dug: " .. dug)
    lastDug = dug; busy = false
    return true, dug
end

local args = { ... }
local mode = args[1]

if mode == "listen" then
    app.runService({
        intro = "mine listening as turtle " .. tostring(unison.id) .. "  (Q to stop)",
        outro = "stopping mine listener.",
        handlers = {
            mine_order = function(msg, env)
                local depth = tonumber(msg.depth) or 32
                local ok, info = runDig(depth)
                unison.rpc.reply(env, {
                    type = "mine_reply",
                    ok = ok or false, dug = ok and info or 0,
                    err = (not ok) and info or nil, ts = os.epoch("utc"),
                })
            end,
            mine_status = function(msg, env)
                unison.rpc.reply(env, {
                    type = "mine_reply", ok = true,
                    busy = busy, dug = lastDug,
                    fuel = turtle.getFuelLevel(),
                    inventory_used = usedSlots(),
                })
            end,
        },
    })
else
    runDig(tonumber(mode) or 64)
end
