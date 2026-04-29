local args = { ... }
local depth = tonumber(args[1]) or 64

local CHEST_SIDE = "left"
local FUEL_SLOT  = 1
local KEEP_FREE  = 4

local function log(msg)
    print("[mine] " .. msg)
end

local function usedSlots()
    local n = 0
    for i = 1, 16 do
        if turtle.getItemCount(i) > 0 then n = n + 1 end
    end
    return n
end

local function refuel()
    if turtle.getFuelLevel() == "unlimited" then return true end
    if turtle.getFuelLevel() > 0 then return true end
    local old = turtle.getSelectedSlot()
    turtle.select(FUEL_SLOT)
    local ok = turtle.refuel(1)
    turtle.select(old)
    if not ok then
        log("No fuel! Put coal in slot " .. FUEL_SLOT)
        return false
    end
    return true
end

local function dumpToChest()
    log("Dumping loot into chest...")
    turtle.turnLeft()
    for i = 1, 16 do
        if i ~= FUEL_SLOT then
            turtle.select(i)
            local detail = turtle.getItemDetail(i)
            if detail then
                local name = detail.name
                if name == "minecraft:coal" or name == "minecraft:charcoal" then
                else
                    turtle.drop()
                end
            end
        end
    end
    turtle.select(1)
    turtle.turnRight()
end

local function digDownSafe()
    while turtle.detectDown() do
        turtle.digDown()
        sleep(0.4)
    end
end

local function digUpSafe()
    while turtle.detectUp() do
        turtle.digUp()
        sleep(0.4)
    end
end

local function goDown()
    digDownSafe()
    while not turtle.down() do
        turtle.digDown()
        turtle.attackDown()
        sleep(0.2)
    end
end

local function goUp()
    digUpSafe()
    while not turtle.up() do
        turtle.digUp()
        turtle.attackUp()
        sleep(0.2)
    end
end

log("Depth: " .. depth .. " blocks. Fuel: " .. tostring(turtle.getFuelLevel()))

if not refuel() then return end

local dug = 0
for i = 1, depth do
    if not refuel() then
        log("Stopping at depth " .. dug)
        break
    end
    goDown()
    dug = dug + 1
    if dug % 5 == 0 then
        log("Dug: " .. dug)
    end
    if 16 - usedSlots() <= KEEP_FREE then
        log("Inventory almost full, returning to surface")
        for j = 1, dug do goUp() end
        dumpToChest()
        log("Going back down")
        for j = 1, dug do goDown() end
    end
end

log("Returning to surface")
for i = 1, dug do goUp() end

dumpToChest()

log("Done. Dug: " .. dug)
