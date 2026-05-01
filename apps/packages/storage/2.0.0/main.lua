-- storage 2.0.0 — Pool aggregator with Create-mod compatibility.
--
-- Works with anything exposing IItemHandler over wired-modem peripherals:
-- vanilla chests/barrels AND every Create block (`create:item_vault_X`,
-- toolboxes, drawers, etc.). They all implement list/getItemDetail/
-- pushItems/pullItems the same way.
--
-- Networked aggregation: every PUSH_INTERVAL seconds the device posts
-- its inventory snapshot to the server-side atlas via lib.atlas, so
-- the dashboard's Storage tab sees one merged item index across all
-- storage-running nodes.

local lib   = unison.lib
local cli   = lib.cli
local app   = lib.app
local fmt   = lib.fmt
local atlas = lib.atlas
local store = lib.kvstore.open("storage", { buffer = nil, ignore = {} })

local PUSH_INTERVAL = 30   -- seconds between snapshot uploads

local function isInventory(name)
    if not peripheral.isPresent(name) then return false end
    local meths = peripheral.getMethods(name) or {}
    for _, m in ipairs(meths) do if m == "list" then return true end end
    return false
end

local function inventoryNames()
    local out = {}
    local ignore = store:get("ignore", {})
    for _, name in ipairs(peripheral.getNames()) do
        if isInventory(name) and not ignore[name] then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

local function poolNames()
    local buf = store:get("buffer")
    local out = {}
    for _, name in ipairs(inventoryNames()) do
        if name ~= buf then out[#out + 1] = name end
    end
    return out
end

local function index(invs)
    local rows = {}
    for _, name in ipairs(invs or poolNames()) do
        local ok, list = pcall(peripheral.call, name, "list")
        if ok and type(list) == "table" then
            for slot, item in pairs(list) do
                rows[#rows + 1] = {
                    chest = name, slot = slot, count = item.count or 0,
                    name = item.name or "?", nbt = item.nbt,
                }
            end
        end
    end
    return rows
end

local function totals(rows)
    local agg = {}
    for _, r in ipairs(rows) do agg[r.name] = (agg[r.name] or 0) + r.count end
    return agg
end

local function matches(item, pat)
    if not pat or pat == "" then return true end
    return item:lower():find(pat:lower(), 1, true) ~= nil
end

local function pullByPattern(pattern, need, target)
    if not target then return 0, "no target (set buffer or pass tgt)" end
    if not isInventory(target) then return 0, "target is not an inventory" end
    need = need or 64
    local moved = 0
    for _, r in ipairs(index()) do
        if moved >= need then break end
        if matches(r.name, pattern) then
            local want = math.min(need - moved, r.count)
            local ok, n = pcall(peripheral.call, r.chest, "pushItems", target, r.slot, want)
            if ok and type(n) == "number" then moved = moved + n end
        end
    end
    return moved
end

-- Build the per-item totals for THIS device's pool — the wire format
-- expected by lib.atlas.pushStorage. Skips empty pools to avoid
-- erasing useful data on the server during a peripheral hot-plug.
local function snapshotItems()
    local agg = {}
    for _, name in ipairs(poolNames()) do
        local ok, list = pcall(peripheral.call, name, "list")
        if ok and type(list) == "table" then
            for _, item in pairs(list) do
                local n = item.name; if n then
                    agg[n] = (agg[n] or 0) + (item.count or 0)
                end
            end
        end
    end
    local out = {}
    for n, c in pairs(agg) do out[#out + 1] = { name = n, count = c } end
    return out
end

local function pushSnapshot()
    if not (atlas and atlas.pushStorage) then return end
    local items = snapshotItems()
    if #items == 0 then return end
    pcall(atlas.pushStorage, items)
end

-- Background coroutine: pushes a fresh snapshot every PUSH_INTERVAL.
local function snapshotLoop()
    while true do
        pcall(pushSnapshot)
        sleep(PUSH_INTERVAL)
    end
end

local function pushFrom(src)
    if not src then return 0, "no source" end
    if not isInventory(src) then return 0, "source not an inventory" end
    local pool = poolNames()
    local moved = 0
    local ok, list = pcall(peripheral.call, src, "list")
    if not ok or type(list) ~= "table" then return 0, "list failed" end
    for slot, item in pairs(list) do
        local remaining = item.count
        for _, target in ipairs(pool) do
            if remaining <= 0 then break end
            local mok, n = pcall(peripheral.call, src, "pushItems", target, slot, remaining)
            if mok and type(n) == "number" and n > 0 then
                moved = moved + n; remaining = remaining - n
            end
        end
    end
    return moved
end

----------------------------------------------------------------------
-- RPC
----------------------------------------------------------------------

local unsubscribe = app.subscribeAll({
    storage_query = function(msg, env)
        if msg.action == "list" then
            local agg = totals(index()); local rows = {}
            for k, v in pairs(agg) do
                if matches(k, msg.pattern) then rows[#rows + 1] = { name = k, count = v } end
            end
            unison.rpc.reply(env, { type = "storage_reply", ok = true, items = rows })
        elseif msg.action == "find" then
            local rows = {}
            for _, r in ipairs(index()) do
                if matches(r.name, msg.pattern) then rows[#rows + 1] = r end
            end
            unison.rpc.reply(env, { type = "storage_reply", ok = true, slots = rows })
        else
            unison.rpc.reply(env, { type = "storage_reply", ok = false, err = "unknown action" })
        end
    end,
    storage_pull = function(msg, env)
        local moved, err = pullByPattern(msg.pattern, msg.count or 64, msg.target or store:get("buffer"))
        unison.rpc.reply(env, {
            type = "storage_reply", ok = (moved > 0) or (not err),
            moved = moved, err = err,
        })
    end,
})

----------------------------------------------------------------------
-- CLI
----------------------------------------------------------------------

local function printList(filter)
    local agg = totals(index())
    local rows = {}
    for k, v in pairs(agg) do
        if matches(k, filter) then rows[#rows + 1] = { k, v } end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    print(string.format("%-40s %s", "ITEM", "COUNT"))
    if #rows == 0 then print("  (nothing matches)") end
    for _, r in ipairs(rows) do
        print(string.format("%-40s %d", fmt.shortItem(r[1]):sub(1, 40), r[2]))
    end
end

local function printFind(pattern)
    local rows = {}
    for _, r in ipairs(index()) do
        if matches(r.name, pattern) then rows[#rows + 1] = r end
    end
    table.sort(rows, function(a, b) return a.count > b.count end)
    print(string.format("%-30s %-22s %-4s %s", "ITEM", "CHEST", "SLOT", "COUNT"))
    for _, r in ipairs(rows) do
        print(string.format("%-30s %-22s %-4d %d",
            fmt.shortItem(r.name):sub(1, 30), r.chest:sub(1, 22), r.slot, r.count))
    end
end

local function printChests()
    local buf = store:get("buffer")
    print(string.format("%-22s %-7s %s", "NAME", "ROLE", "ITEMS"))
    for _, n in ipairs(inventoryNames()) do
        local role = (n == buf) and "BUFFER" or "pool"
        local count = 0
        local ok, list = pcall(peripheral.call, n, "list")
        if ok and type(list) == "table" then
            for _, it in pairs(list) do count = count + (it.count or 0) end
        end
        print(string.format("%-22s %-7s %d", n:sub(1, 22), role, count))
    end
end

-- Spawn the snapshot pusher as a kernel process so it runs alongside
-- the CLI loop and survives across cli.run iterations. Group=system so
-- it doesn't block OS upgrades.
local snapshotProc = nil
if unison and unison.process and unison.process.spawn then
    snapshotProc = unison.process.spawn(snapshotLoop,
        "storage-snapshot", { group = "system", priority = 5 })
end
-- Push one snapshot immediately so the dashboard reflects current
-- contents the moment storage starts.
pcall(pushSnapshot)

cli.run({
    intro = "storage online. buffer=" .. tostring(store:get("buffer") or "(unset)") ..
            "  pool=" .. #poolNames() .. " inventories.  snapshot pushed.",
    prompt = "storage",
    commands = {
        list = {
            desc = "item totals across the pool",
            args = { { name = "pat", default = "" } },
            run  = function(_, a) printList(a.pat) end,
        },
        find = {
            desc = "slot-level locations",
            args = { { name = "pat", required = true } },
            run  = function(_, a) printFind(a.pat) end,
        },
        pull = {
            desc = "move N items into target",
            args = {
                { name = "pat",    required = true },
                { name = "count",  type = "number", default = 64 },
                { name = "target", default = nil },
            },
            run = function(_, a)
                local moved, err = pullByPattern(a.pat, a.count, a.target or store:get("buffer"))
                if err then printError("pull: " .. err)
                else print("moved " .. moved .. " into " .. tostring(a.target or store:get("buffer"))) end
            end,
        },
        push = {
            desc = "sweep src into pool (default = buffer)",
            args = { { name = "src", default = nil } },
            run = function(_, a)
                local src = a.src or store:get("buffer")
                local moved, err = pushFrom(src)
                if err then printError("push: " .. err)
                else print("swept " .. moved .. " items from " .. tostring(src)) end
            end,
        },
        chests = { desc = "managed inventories", run = printChests },
        buffer = {
            desc = "set the buffer inventory",
            args = { { name = "name", required = true } },
            run = function(_, a)
                if not isInventory(a.name) then printError("not an inventory"); return end
                store:set("buffer", a.name); print("buffer = " .. a.name)
            end,
        },
        refresh = {
            desc = "re-scan peripherals",
            run = function() print("re-scan: " .. #inventoryNames() .. " inventories") end,
        },
        sync = {
            desc = "push current snapshot to the atlas server now",
            run = function()
                pushSnapshot()
                print("pushed snapshot of " .. #snapshotItems() .. " unique item(s)")
            end,
        },
    },
    on_exit = function()
        unsubscribe()
        if snapshotProc and snapshotProc.kill then pcall(snapshotProc.kill, snapshotProc) end
    end,
})
