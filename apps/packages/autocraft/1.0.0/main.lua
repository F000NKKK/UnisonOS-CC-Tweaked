-- autocraft — recipe orchestrator on a crafty turtle.
--
-- Recipes live in /unison/state/autocraft-recipes.json:
--   {
--     "minecraft:stick": {
--       "kind": "shaped",
--       "pattern": ["P_", "P_"],         -- 1..3 lines, length 1..3 each
--       "key": { "P": "minecraft:oak_planks" },
--       "output": 4
--     }
--   }
--
-- Crafty turtle layout (slots 1-16):
--   1  2  3  4
--   5  6  7  8         crafting grid = 1,2,3 / 5,6,7 / 9,10,11
--   9 10 11 12         remaining slots are ingredient buffer.
--   13 14 15 16
--
-- Required: a wired-modem-attached chest in front (or any side) acting as
-- the "supply" inventory. We pull ingredients from it, and the result
-- lands back in our inventory; you can drop into the same chest with
-- `autocraft drop`.
--
-- REPL:
--   recipes              show known recipes
--   add <name>           interactive add
--   craft <name> [N]     craft N (default 1)
--   drop                 dump output back into supply
--   supply <name>        set supply inventory peripheral name
--   help / q
--
-- RPC: craft_order / recipe_list / recipe_add (see docs/ECOSYSTEM.md).

local fsLib = unison.lib.fs

local STATE_FILE   = "/unison/state/autocraft.json"
local RECIPES_FILE = "/unison/state/autocraft-recipes.json"

local config = fsLib.readJson(STATE_FILE) or { supply = nil }
local recipes = fsLib.readJson(RECIPES_FILE) or {}

local function saveConfig()  fsLib.writeJson(STATE_FILE, config) end
local function saveRecipes() fsLib.writeJson(RECIPES_FILE, recipes) end

local function shortName(s) return (s or ""):gsub("^minecraft:", "") end

----------------------------------------------------------------------
-- Inventory helpers
----------------------------------------------------------------------

-- Crafty turtle craft area: 9 grid slots arranged 3x3 in slots 1,2,3 / 5,6,7 / 9,10,11.
local GRID_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local BUFFER_SLOTS = { 4, 8, 12, 13, 14, 15, 16 }

local function clearGrid()
    for _, slot in ipairs(GRID_SLOTS) do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            -- push back to supply if configured, else just drop
            if config.supply then
                pcall(peripheral.call, config.supply, "pullItems",
                    "self", slot, turtle.getItemCount(slot))
            else
                turtle.dropDown()
            end
        end
    end
end

local function slotIndex(row, col) -- row,col 1..3
    return ({1,2,3,5,6,7,9,10,11})[(row-1)*3 + col]
end

-- Pull `count` of `name` from supply into a specific turtle slot.
local function pullToSlot(name, slot, count)
    if not config.supply then return false, "no supply set" end
    if not peripheral.isPresent(config.supply) then
        return false, "supply not present"
    end
    local list = peripheral.call(config.supply, "list") or {}
    local remaining = count
    for srcSlot, item in pairs(list) do
        if remaining <= 0 then break end
        if item.name == name then
            local ok, n = pcall(peripheral.call, config.supply, "pushItems",
                "self", srcSlot, math.min(remaining, item.count), slot)
            if ok and type(n) == "number" then remaining = remaining - n end
        end
    end
    if remaining > 0 then
        return false, string.format("need %d more of %s", remaining, shortName(name))
    end
    return true
end

----------------------------------------------------------------------
-- Crafting
----------------------------------------------------------------------

local function placeShaped(recipe, batch)
    local pattern = recipe.pattern or {}
    local key = recipe.key or {}
    for r = 1, #pattern do
        local row = pattern[r]
        for c = 1, #row do
            local k = row:sub(c, c)
            if k ~= " " and k ~= "_" and k ~= "." then
                local item = key[k]
                if not item then return false, "unknown pattern key '" .. k .. "'" end
                local slot = slotIndex(r, c)
                local ok, err = pullToSlot(item, slot, batch)
                if not ok then return false, err end
            end
        end
    end
    return true
end

local function craftBatch(name, batch)
    local recipe = recipes[name]
    if not recipe then return false, "unknown recipe" end
    if not turtle.craft then return false, "this device isn't a crafty turtle" end
    clearGrid()
    local ok, err = placeShaped(recipe, batch)
    if not ok then clearGrid(); return false, err end
    if not turtle.craft() then
        clearGrid()
        return false, "turtle.craft failed (bad recipe?)"
    end
    return true, batch * (recipe.output or 1)
end

local function craft(name, count)
    count = count or 1
    local recipe = recipes[name]
    if not recipe then return false, "unknown recipe" end
    local outPer = recipe.output or 1
    local batches = math.ceil(count / outPer)
    local crafted = 0
    for i = 1, batches do
        -- One batch produces (output) items; if recipe makes 4-per-craft we
        -- can craft up to 64 outputs in a single turtle.craft call (still
        -- limited by stack size in the slots).
        local thisBatch = math.min(64, math.ceil((count - crafted) / outPer))
        local ok, made = craftBatch(name, thisBatch)
        if not ok then return false, made end
        crafted = crafted + made
        if crafted >= count then break end
    end
    return true, crafted
end

local function dropSupply()
    if not config.supply then return 0 end
    local moved = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            local ok, n = pcall(peripheral.call, config.supply, "pullItems",
                "self", slot, turtle.getItemCount(slot))
            if ok and type(n) == "number" then moved = moved + n end
        end
    end
    return moved
end

----------------------------------------------------------------------
-- Interactive recipe add
----------------------------------------------------------------------

local function interactiveAdd(name)
    if not name then printError("usage: add <recipe-name>"); return end
    print("Enter pattern lines (1..3), use single chars; blank to finish.")
    local pattern = {}
    while #pattern < 3 do
        write("row " .. (#pattern + 1) .. "> ")
        local line = read()
        if line == nil or line == "" then break end
        pattern[#pattern + 1] = line:sub(1, 3)
    end
    if #pattern == 0 then print("aborted"); return end

    local seen, key = {}, {}
    for _, row in ipairs(pattern) do
        for c = 1, #row do
            local k = row:sub(c, c)
            if k ~= " " and k ~= "_" and k ~= "." and not seen[k] then
                seen[k] = true; key[#key + 1] = k
            end
        end
    end

    local mapping = {}
    for _, k in ipairs(key) do
        write("item for '" .. k .. "' (e.g. minecraft:oak_planks)> ")
        local item = read()
        if item == "" then print("aborted"); return end
        mapping[k] = item
    end

    write("output count per craft (default 1)> ")
    local n = tonumber(read() or "1") or 1

    recipes[name] = { kind = "shaped", pattern = pattern, key = mapping, output = n }
    saveRecipes()
    print("recipe '" .. name .. "' saved.")
end

----------------------------------------------------------------------
-- RPC
----------------------------------------------------------------------

local function setupRpc()
    if not (unison.rpc and unison.rpc.on) then return end
    unison.rpc.off("craft_order"); unison.rpc.off("recipe_list"); unison.rpc.off("recipe_add")

    unison.rpc.on("craft_order", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local ok, n_or_err = craft(msg.name, msg.count or 1)
        unison.rpc.send(from, {
            type = "craft_reply", from = tostring(unison.id),
            in_reply_to = env and env.id,
            ok = ok or false,
            crafted = ok and n_or_err or 0,
            err = (not ok) and n_or_err or nil,
        })
    end)

    unison.rpc.on("recipe_list", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local out = {}
        for k, _ in pairs(recipes) do out[#out + 1] = k end
        table.sort(out)
        unison.rpc.send(from, {
            type = "craft_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = true, recipes = out,
        })
    end)

    unison.rpc.on("recipe_add", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local ok = msg.name and msg.pattern and msg.key
        if ok then
            recipes[msg.name] = {
                kind = "shaped",
                pattern = msg.pattern,
                key = msg.key,
                output = msg.output or 1,
            }
            saveRecipes()
        end
        unison.rpc.send(from, {
            type = "craft_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = ok or false,
            err = (not ok) and "missing fields" or nil,
        })
    end)
end

----------------------------------------------------------------------
-- REPL
----------------------------------------------------------------------

local function help()
    print("autocraft commands:")
    print("  recipes              list known recipes")
    print("  add <name>           interactive recipe entry")
    print("  craft <name> [N]     craft N (default 1)")
    print("  drop                 push everything from inventory into supply")
    print("  supply <name>        set the supply chest peripheral")
    print("  help / q")
end

local function listRecipes()
    local keys = {}
    for k in pairs(recipes) do keys[#keys + 1] = k end
    table.sort(keys)
    print(string.format("%-30s %s", "RECIPE", "OUT/CRAFT"))
    if #keys == 0 then print("  (none — use 'add' to define one)") end
    for _, k in ipairs(keys) do
        print(string.format("%-30s %d", k:sub(1, 30), recipes[k].output or 1))
    end
end

setupRpc()
print("autocraft online. " .. (function()
    local n = 0; for _ in pairs(recipes) do n = n + 1 end; return n
end)() .. " recipes; supply=" .. tostring(config.supply or "(unset)"))

while true do
    write("autocraft> ")
    local line = read()
    if not line then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts + 1] = w end
    local cmd = parts[1]
    if not cmd or cmd == "" then
    elseif cmd == "q" or cmd == "quit" or cmd == "exit" then break
    elseif cmd == "help" or cmd == "?" then help()
    elseif cmd == "recipes" or cmd == "list" then listRecipes()
    elseif cmd == "add" then interactiveAdd(parts[2])
    elseif cmd == "craft" then
        if not parts[2] then printError("usage: craft <name> [N]")
        else
            local n = tonumber(parts[3] or 1) or 1
            local ok, r = craft(parts[2], n)
            if ok then print("crafted " .. r .. " of " .. parts[2])
            else printError("craft: " .. tostring(r)) end
        end
    elseif cmd == "drop" then
        local n = dropSupply(); print("dropped " .. n .. " items into supply")
    elseif cmd == "supply" then
        if not parts[2] then printError("usage: supply <name>")
        else config.supply = parts[2]; saveConfig(); print("supply = " .. parts[2]) end
    else printError("unknown: " .. cmd) end
end

if unison.rpc and unison.rpc.off then
    unison.rpc.off("craft_order"); unison.rpc.off("recipe_list"); unison.rpc.off("recipe_add")
end
print("bye.")
