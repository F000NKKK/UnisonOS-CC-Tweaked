-- mine — vertical mining shaft.
--
-- Usage:
--   mine [depth]         one-shot dig of `depth` blocks downward (default 64)
--   mine listen          subscribe to bus, accept mine_order RPCs
--
-- Layout: chest LEFT of the turtle, anything on the right (PC etc.) is
-- ignored. Slot 1 holds fuel (coal / charcoal); turtle.refuel() is auto.
--
-- Bus protocol: see docs/ECOSYSTEM.md
--   mine_order  -> { depth?, kind? } -> reply { ok, dug, ts }
--   mine_status -> {} -> reply { ok, busy, dug, fuel, inventory_used }

local CHEST_SIDE = "left"
local FUEL_SLOT  = 1
local KEEP_FREE  = 4

local busy = false
local lastDug = 0

local function log(msg) print("[mine] " .. msg) end

local function usedSlots()
    local n = 0
    for i = 1, 16 do if turtle.getItemCount(i) > 0 then n = n + 1 end end
    return n
end

local function refuel()
    if turtle.getFuelLevel() == "unlimited" then return true end
    if turtle.getFuelLevel() > 0 then return true end
    local old = turtle.getSelectedSlot()
    turtle.select(FUEL_SLOT)
    local ok = turtle.refuel(1)
    turtle.select(old)
    if not ok then log("No fuel! Put coal in slot " .. FUEL_SLOT); return false end
    return true
end

local function dumpToChest()
    log("Dumping loot into chest...")
    turtle.turnLeft()
    for i = 1, 16 do
        if i ~= FUEL_SLOT then
            turtle.select(i)
            local d = turtle.getItemDetail(i)
            if d then
                local n = d.name
                if n ~= "minecraft:coal" and n ~= "minecraft:charcoal" then
                    turtle.drop()
                end
            end
        end
    end
    turtle.select(1)
    turtle.turnRight()
end

local function digDownSafe()
    while turtle.detectDown() do turtle.digDown(); sleep(0.4) end
end
local function digUpSafe()
    while turtle.detectUp() do turtle.digUp(); sleep(0.4) end
end
local function goDown()
    digDownSafe()
    while not turtle.down() do turtle.digDown(); turtle.attackDown(); sleep(0.2) end
end
local function goUp()
    digUpSafe()
    while not turtle.up() do turtle.digUp(); turtle.attackUp(); sleep(0.2) end
end

local function runDig(depth)
    if busy then return false, "busy" end
    busy = true
    log("Depth: " .. depth .. ". Fuel: " .. tostring(turtle.getFuelLevel()))
    if not refuel() then busy = false; return false, "no fuel" end
    local dug = 0
    for i = 1, depth do
        if not refuel() then break end
        goDown()
        dug = dug + 1
        if dug % 5 == 0 then log("Dug: " .. dug) end
        if 16 - usedSlots() <= KEEP_FREE then
            log("Inventory almost full, returning")
            for j = 1, dug do goUp() end
            dumpToChest()
            for j = 1, dug do goDown() end
        end
    end
    log("Returning to surface")
    for i = 1, dug do goUp() end
    dumpToChest()
    log("Done. Dug: " .. dug)
    lastDug = dug
    busy = false
    return true, dug
end

local function setupRpc()
    if not (unison.rpc and unison.rpc.on) then return end
    unison.rpc.off("mine_order"); unison.rpc.off("mine_status")

    unison.rpc.on("mine_order", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local depth = tonumber(msg.depth) or 32
        local ok, info = runDig(depth)
        unison.rpc.send(from, {
            type = "mine_reply", from = tostring(unison.id),
            in_reply_to = env and env.id,
            ok = ok or false,
            dug = ok and info or 0,
            err = (not ok) and info or nil,
            ts = os.epoch("utc"),
        })
    end)

    unison.rpc.on("mine_status", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local used = usedSlots()
        unison.rpc.send(from, {
            type = "mine_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = true,
            busy = busy, dug = lastDug,
            fuel = turtle.getFuelLevel(),
            inventory_used = used,
        })
    end)
end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------

local args = { ... }
local mode = args[1]

if not turtle then print("mine: must run on a turtle"); return end

if mode == "listen" then
    setupRpc()
    print("mine listening as turtle " .. tostring(unison.id))
    print("press Q to stop")
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "char" and (p1 == "q" or p1 == "Q") then break end
        if ev == "key" and p1 == keys.q then break end
    end
    if unison.rpc and unison.rpc.off then
        unison.rpc.off("mine_order"); unison.rpc.off("mine_status")
    end
    print("stopping mine listener.")
else
    local depth = tonumber(mode) or 64
    runDig(depth)
end
