-- farm — turtle auto-harvester. Walks a configurable row above farmland,
-- harvests mature crops below, replants from inventory.
--
-- Usage on a turtle:
--   run farm [length]                   one-shot run; default length=8
--   run farm listen                     subscribe to bus, run on demand
--
-- Bus protocol: see docs/ECOSYSTEM.md
--   farm_harvest -> reply { ok, harvested, replanted }
--   farm_status  -> reply { ok, busy, last_run, harvested_total }

local fsLib   = unison.lib.fs
local STATE_FILE = "/unison/state/farm.json"

local state = fsLib.readJson(STATE_FILE) or {
    last_run = nil, harvested_total = 0, replanted_total = 0,
}
local function save() fsLib.writeJson(STATE_FILE, state) end

local CROPS = {
    -- block name -> { mature_age, seed_item }
    ["minecraft:wheat"]    = { age = 7, seed = "minecraft:wheat_seeds" },
    ["minecraft:carrots"]  = { age = 7, seed = "minecraft:carrot" },
    ["minecraft:potatoes"] = { age = 7, seed = "minecraft:potato" },
    ["minecraft:beetroots"]= { age = 3, seed = "minecraft:beetroot_seeds" },
}

local busy = false

local function isMatureCrop(detail, blockState)
    if not detail then return false end
    local rec = CROPS[detail.name]
    if not rec then return false end
    local age = blockState and blockState.age
    if age == nil then return false end
    return age >= rec.age, detail.name
end

local function findSeedSlot(seed)
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and d.name == seed then
            turtle.select(slot)
            return slot
        end
    end
    return nil
end

local function harvestOne()
    local present, info = turtle.inspectDown()
    if not present then return false end
    local detail = info or {}
    local mature, blockName = isMatureCrop(detail, detail.state or detail)
    if not mature then return false end
    -- Capture which crop we destroyed so we can replant it.
    local rec = CROPS[blockName]
    turtle.digDown()
    if rec and findSeedSlot(rec.seed) then
        if turtle.placeDown() then
            return true, true   -- harvested + replanted
        end
        return true, false
    end
    return true, false
end

local function harvestRow(length)
    length = tonumber(length) or 8
    local harvested, replanted = 0, 0
    for i = 1, length do
        local h, r = harvestOne()
        if h then harvested = harvested + 1 end
        if r then replanted = replanted + 1 end
        if i < length then
            -- Walk forward; if blocked (animal etc.) wait briefly.
            for _ = 1, 5 do
                if turtle.forward() then break end
                turtle.attack()
                sleep(0.3)
            end
        end
    end
    -- Walk back to start so the turtle ends where it began.
    turtle.turnLeft(); turtle.turnLeft()
    for _ = 1, length - 1 do
        for _ = 1, 5 do
            if turtle.forward() then break end
            turtle.attack()
            sleep(0.3)
        end
    end
    turtle.turnLeft(); turtle.turnLeft()
    return harvested, replanted
end

local function runOnce(length)
    if busy then return false, "busy" end
    busy = true
    local h, r = harvestRow(length)
    state.last_run = os.epoch("utc")
    state.harvested_total = state.harvested_total + h
    state.replanted_total = state.replanted_total + r
    save()
    busy = false
    return true, h, r
end

local function setupRpc()
    if not (unison.rpc and unison.rpc.on) then return end
    unison.rpc.off("farm_harvest"); unison.rpc.off("farm_status")

    unison.rpc.on("farm_harvest", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local ok, h, r = runOnce(msg.length)
        unison.rpc.send(from, {
            type = "farm_reply", from = tostring(unison.id),
            in_reply_to = env and env.id,
            ok = ok or false, harvested = h, replanted = r,
            err = (not ok) and h or nil,
        })
    end)

    unison.rpc.on("farm_status", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        unison.rpc.send(from, {
            type = "farm_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = true,
            busy = busy,
            last_run = state.last_run,
            harvested_total = state.harvested_total,
            replanted_total = state.replanted_total,
        })
    end)
end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------

local args = { ... }
local mode = args[1]

if not turtle then
    print("farm: must run on a turtle"); return
end

if mode == "listen" then
    setupRpc()
    print("farm listening as turtle " .. tostring(unison.id))
    print("press Q to stop")
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "char" and (p1 == "q" or p1 == "Q") then break end
        if ev == "key" and p1 == keys.q then break end
    end
    if unison.rpc and unison.rpc.off then
        unison.rpc.off("farm_harvest"); unison.rpc.off("farm_status")
    end
    print("stopping farm listener.")
else
    local length = tonumber(mode) or 8
    print("farm: harvesting row of " .. length)
    local ok, h, r = runOnce(length)
    if ok then print(string.format("done: harvested=%d replanted=%d", h, r))
    else printError(tostring(h)) end
end
