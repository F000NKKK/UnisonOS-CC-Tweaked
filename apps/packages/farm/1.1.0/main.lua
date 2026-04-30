-- farm 1.1.0 — UniAPI rewrite. Same harvest+replant logic; uses
-- unison.lib.app.runService for listen mode + lib.kvstore for state.

if not turtle then print("farm: must run on a turtle"); return end

local lib   = unison.lib
local app   = lib.app
local store = lib.kvstore.open("farm", {
    last_run = nil, harvested_total = 0, replanted_total = 0,
})

local CROPS = {
    ["minecraft:wheat"]    = { age = 7, seed = "minecraft:wheat_seeds" },
    ["minecraft:carrots"]  = { age = 7, seed = "minecraft:carrot" },
    ["minecraft:potatoes"] = { age = 7, seed = "minecraft:potato" },
    ["minecraft:beetroots"]= { age = 3, seed = "minecraft:beetroot_seeds" },
}

local busy = false

local function findSeedSlot(seed)
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and d.name == seed then turtle.select(slot); return slot end
    end
end

local function harvestOne()
    local present, info = turtle.inspectDown()
    if not present then return false end
    local rec = CROPS[info and info.name or ""]
    if not rec then return false end
    local age = info.state and info.state.age
    if not age or age < rec.age then return false end
    turtle.digDown()
    if findSeedSlot(rec.seed) and turtle.placeDown() then return true, true end
    return true, false
end

local function harvestRow(length)
    length = math.max(1, tonumber(length) or 8)
    local h, r = 0, 0
    for i = 1, length do
        local ok, replanted = harvestOne()
        if ok then h = h + 1 end
        if replanted then r = r + 1 end
        if i < length then
            for _ = 1, 5 do
                if turtle.forward() then break end
                turtle.attack(); sleep(0.3)
            end
        end
    end
    turtle.turnLeft(); turtle.turnLeft()
    for _ = 1, length - 1 do
        for _ = 1, 5 do
            if turtle.forward() then break end
            turtle.attack(); sleep(0.3)
        end
    end
    turtle.turnLeft(); turtle.turnLeft()
    return h, r
end

local function runOnce(length)
    if busy then return false, "busy" end
    busy = true
    local h, r = harvestRow(length)
    store:set("last_run", os.epoch("utc"))
    store:set("harvested_total", store:get("harvested_total", 0) + h)
    store:set("replanted_total", store:get("replanted_total", 0) + r)
    busy = false
    return true, h, r
end

local args = { ... }
local mode = args[1]

if mode == "listen" then
    app.runService({
        intro = "farm listening as turtle " .. tostring(unison.id) .. "  (Q to stop)",
        outro = "stopping farm listener.",
        handlers = {
            farm_harvest = function(msg, env)
                local ok, h, r = runOnce(msg.length)
                unison.rpc.reply(env, {
                    type = "farm_reply",
                    ok = ok or false,
                    harvested = h, replanted = r,
                    err = (not ok) and h or nil,
                })
            end,
            farm_status = function(msg, env)
                unison.rpc.reply(env, {
                    type = "farm_reply", ok = true,
                    busy = busy,
                    last_run = store:get("last_run"),
                    harvested_total = store:get("harvested_total", 0),
                    replanted_total = store:get("replanted_total", 0),
                })
            end,
        },
    })
else
    local length = tonumber(mode) or 8
    print("farm: harvesting row of " .. length)
    local ok, h, r = runOnce(length)
    if ok then print(string.format("done: harvested=%d replanted=%d", h, r))
    else printError(tostring(h)) end
end
