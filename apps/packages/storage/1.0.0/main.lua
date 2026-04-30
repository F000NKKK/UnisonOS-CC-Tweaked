-- storage — turn every inventory peripheral on the local wired-modem
-- network into a single addressable item pool.
--
-- Run on a stationary computer with a wired modem connected to chests /
-- barrels / Item Vaults. By default every detected inventory is part of
-- the pool except the configured buffer (where pulls land and pushes
-- come from).
--
-- REPL commands:
--   list [pat]         show item totals (optional substring filter)
--   find <pat>         show slot-level locations of items matching pat
--   pull <pat> [N] [tgt]  move up to N items matching pat into tgt
--                          (default tgt = configured buffer)
--   push [src]         sweep src (default = buffer) into the pool
--   chests             list managed inventories with item counts
--   buffer <name>      set the buffer inventory
--   refresh            re-scan peripherals
--   help / q / quit
--
-- Plus a rpc handler for remote queries:
--   { type="storage_query", action="list"|"find", pattern? }
--   { type="storage_pull",  pattern, count?, target? }

local fsLib   = unison.lib.fs
local jsonLib = unison.lib.json

local STATE_FILE = "/unison/state/storage.json"

----------------------------------------------------------------------
-- State (persisted)
----------------------------------------------------------------------

local state = fsLib.readJson(STATE_FILE) or { buffer = nil, ignore = {} }
state.ignore = state.ignore or {}

local function saveState()
    fsLib.writeJson(STATE_FILE, state)
end

local function isInventory(name)
    -- Anything that exposes 'list' is treated as an inventory.
    if not peripheral.isPresent(name) then return false end
    local meths = peripheral.getMethods(name) or {}
    for _, m in ipairs(meths) do if m == "list" then return true end end
    return false
end

local function inventoryNames()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if isInventory(name) and not state.ignore[name] then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

local function poolNames()
    local out = {}
    for _, name in ipairs(inventoryNames()) do
        if name ~= state.buffer then out[#out + 1] = name end
    end
    return out
end

----------------------------------------------------------------------
-- Indexing
----------------------------------------------------------------------

local function shortName(item)
    return (item.name or "?"):gsub("^minecraft:", "")
end

-- Returns array of { chest, slot, count, name, displayName }
local function index(invs)
    local rows = {}
    for _, name in ipairs(invs or poolNames()) do
        local ok, list = pcall(peripheral.call, name, "list")
        if ok and type(list) == "table" then
            for slot, item in pairs(list) do
                rows[#rows + 1] = {
                    chest = name,
                    slot = slot,
                    count = item.count or 0,
                    name = item.name or "?",
                    nbt = item.nbt,
                }
            end
        end
    end
    return rows
end

local function totals(rows)
    local agg = {}
    for _, r in ipairs(rows) do
        agg[r.name] = (agg[r.name] or 0) + r.count
    end
    return agg
end

local function matchesFilter(item, pat)
    if not pat or pat == "" then return true end
    return item:lower():find(pat:lower(), 1, true) ~= nil
end

----------------------------------------------------------------------
-- Movements
----------------------------------------------------------------------

-- Pull up to `need` items matching pattern into `target`. Returns moved.
local function pullByPattern(pattern, need, target)
    if not target then return 0, "no target" end
    if not isInventory(target) then return 0, "target is not an inventory" end
    need = need or 64
    local moved = 0
    for _, r in ipairs(index()) do
        if moved >= need then break end
        if matchesFilter(r.name, pattern) then
            local want = math.min(need - moved, r.count)
            local ok, n = pcall(peripheral.call, r.chest, "pushItems", target, r.slot, want)
            if ok and type(n) == "number" then
                moved = moved + n
            end
        end
    end
    return moved
end

-- Sweep every item out of `src` into the pool (any chest with room).
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
                moved = moved + n
                remaining = remaining - n
            end
        end
    end
    return moved
end

----------------------------------------------------------------------
-- REPL
----------------------------------------------------------------------

local function printList(filter)
    local agg = totals(index())
    local rows = {}
    for k, v in pairs(agg) do
        if matchesFilter(k, filter) then rows[#rows + 1] = { k, v } end
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    print(string.format("%-40s %s", "ITEM", "COUNT"))
    if #rows == 0 then print("  (nothing matches)") end
    for _, r in ipairs(rows) do
        print(string.format("%-40s %d", shortName({ name = r[1] }):sub(1, 40), r[2]))
    end
end

local function printFind(pattern)
    local rows = {}
    for _, r in ipairs(index()) do
        if matchesFilter(r.name, pattern) then rows[#rows + 1] = r end
    end
    table.sort(rows, function(a, b) return a.count > b.count end)
    print(string.format("%-30s %-22s %-4s %s", "ITEM", "CHEST", "SLOT", "COUNT"))
    if #rows == 0 then print("  (nothing matches)") end
    for _, r in ipairs(rows) do
        print(string.format("%-30s %-22s %-4d %d",
            shortName(r):sub(1, 30), r.chest:sub(1, 22), r.slot, r.count))
    end
end

local function printChests()
    local invs = inventoryNames()
    print(string.format("%-22s %-7s %s", "NAME", "ROLE", "ITEMS"))
    for _, n in ipairs(invs) do
        local role = (n == state.buffer) and "BUFFER" or "pool"
        local count = 0
        local ok, list = pcall(peripheral.call, n, "list")
        if ok and type(list) == "table" then
            for _, it in pairs(list) do count = count + (it.count or 0) end
        end
        print(string.format("%-22s %-7s %d", n:sub(1, 22), role, count))
    end
end

local function help()
    print("storage commands:")
    print("  list [pat]            item totals")
    print("  find <pat>            slot-level locations")
    print("  pull <pat> [N] [tgt]  move N items into tgt (default = buffer)")
    print("  push [src]            sweep src into pool (default = buffer)")
    print("  chests                managed inventories")
    print("  buffer <name>         set buffer inventory")
    print("  refresh               re-scan peripherals")
    print("  q / quit / help")
end

----------------------------------------------------------------------
-- Optional RPC handlers
----------------------------------------------------------------------

local function setupRpc()
    if not (unison and unison.rpc and unison.rpc.on) then return end
    unison.rpc.off("storage_query")
    unison.rpc.off("storage_pull")

    unison.rpc.on("storage_query", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local resp = { type = "storage_reply", from = tostring(unison.id) }
        if msg.action == "list" then
            local agg = totals(index())
            local rows = {}
            for k, v in pairs(agg) do
                if matchesFilter(k, msg.pattern) then rows[#rows + 1] = { name = k, count = v } end
            end
            resp.ok = true; resp.items = rows
        elseif msg.action == "find" then
            local rows = {}
            for _, r in ipairs(index()) do
                if matchesFilter(r.name, msg.pattern) then rows[#rows + 1] = r end
            end
            resp.ok = true; resp.slots = rows
        else
            resp.ok = false; resp.err = "unknown action"
        end
        unison.rpc.send(from, resp)
    end)

    unison.rpc.on("storage_pull", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local moved, err = pullByPattern(msg.pattern, msg.count or 64,
            msg.target or state.buffer)
        unison.rpc.send(from, {
            type = "storage_reply",
            from = tostring(unison.id),
            ok = (moved > 0) or (not err),
            moved = moved,
            err = err,
        })
    end)
end

----------------------------------------------------------------------
-- Entry
----------------------------------------------------------------------

local function repl()
    setupRpc()
    print("storage online. type 'help' for commands.")
    print("buffer: " .. tostring(state.buffer or "(unset — run 'buffer <name>')"))
    print("pool:   " .. #poolNames() .. " inventories")

    while true do
        write("storage> ")
        local line = read()
        if not line then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        local parts = {}
        for w in line:gmatch("%S+") do parts[#parts + 1] = w end
        local cmd = parts[1]

        if not cmd or cmd == "" then
            -- noop
        elseif cmd == "q" or cmd == "quit" or cmd == "exit" then break
        elseif cmd == "help" or cmd == "?" then help()
        elseif cmd == "list" then printList(parts[2])
        elseif cmd == "find" then
            if not parts[2] then printError("usage: find <pat>") else printFind(parts[2]) end
        elseif cmd == "pull" then
            if not parts[2] then printError("usage: pull <pat> [N] [tgt]");
            else
                local n = tonumber(parts[3] or 64) or 64
                local target = parts[4] or state.buffer
                local moved, err = pullByPattern(parts[2], n, target)
                if err then printError("pull: " .. err)
                else print("moved " .. moved .. " into " .. tostring(target)) end
            end
        elseif cmd == "push" then
            local src = parts[2] or state.buffer
            local moved, err = pushFrom(src)
            if err then printError("push: " .. err)
            else print("swept " .. moved .. " items from " .. tostring(src)) end
        elseif cmd == "chests" then printChests()
        elseif cmd == "buffer" then
            if not parts[2] then printError("usage: buffer <name>")
            elseif not isInventory(parts[2]) then printError("not an inventory: " .. parts[2])
            else state.buffer = parts[2]; saveState(); print("buffer = " .. parts[2]) end
        elseif cmd == "refresh" then
            print("re-scan: " .. #inventoryNames() .. " inventories")
        else
            printError("unknown command: " .. cmd)
        end
    end

    if unison and unison.rpc and unison.rpc.off then
        unison.rpc.off("storage_query")
        unison.rpc.off("storage_pull")
    end
    print("bye.")
end

repl()
