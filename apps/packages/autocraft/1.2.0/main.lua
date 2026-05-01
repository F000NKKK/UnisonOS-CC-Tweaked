-- autocraft 1.1.0 — UniAPI rewrite. Recipe DB and config now in two
-- kvstore tables; lib.cli for REPL; lib.app.subscribeAll for RPC.

local lib = unison.lib
local cli = lib.cli
local app = lib.app

local config  = lib.kvstore.open("autocraft", { supply = nil })
local recipes = lib.kvstore.open("autocraft-recipes")

local function shortItem(s) return lib.fmt.shortItem(s) end

local GRID_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local function slotIndex(row, col) return GRID_SLOTS[(row - 1) * 3 + col] end

local function clearGrid()
    for _, slot in ipairs(GRID_SLOTS) do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            local supply = config:get("supply")
            if supply then
                pcall(peripheral.call, supply, "pullItems", "self", slot, turtle.getItemCount(slot))
            else
                turtle.dropDown()
            end
        end
    end
end

local function pullToSlot(name, slot, count)
    local supply = config:get("supply")
    if not supply then return false, "no supply set" end
    if not peripheral.isPresent(supply) then return false, "supply not present" end
    local list = peripheral.call(supply, "list") or {}
    local remaining = count
    for srcSlot, item in pairs(list) do
        if remaining <= 0 then break end
        if item.name == name then
            local ok, n = pcall(peripheral.call, supply, "pushItems", "self",
                srcSlot, math.min(remaining, item.count), slot)
            if ok and type(n) == "number" then remaining = remaining - n end
        end
    end
    if remaining > 0 then
        return false, string.format("need %d more of %s", remaining, shortItem(name))
    end
    return true
end

local function placeShaped(recipe, batch)
    local pattern, key = recipe.pattern or {}, recipe.key or {}
    for r = 1, #pattern do
        local row = pattern[r]
        for c = 1, #row do
            local k = row:sub(c, c)
            if k ~= " " and k ~= "_" and k ~= "." then
                local item = key[k]
                if not item then return false, "unknown key '" .. k .. "'" end
                local ok, err = pullToSlot(item, slotIndex(r, c), batch)
                if not ok then return false, err end
            end
        end
    end
    return true
end

local function craftBatch(name, batch)
    local recipe = recipes:get(name); if not recipe then return false, "unknown recipe" end
    if not turtle.craft then return false, "this device isn't a crafty turtle" end
    clearGrid()
    local ok, err = placeShaped(recipe, batch)
    if not ok then clearGrid(); return false, err end
    if not turtle.craft() then clearGrid(); return false, "turtle.craft failed" end
    return true, batch * (recipe.output or 1)
end

local function craft(name, count)
    count = count or 1
    local recipe = recipes:get(name); if not recipe then return false, "unknown recipe" end
    local outPer = recipe.output or 1
    local batches = math.ceil(count / outPer)
    local crafted = 0
    for _ = 1, batches do
        local thisBatch = math.min(64, math.ceil((count - crafted) / outPer))
        local ok, made = craftBatch(name, thisBatch)
        if not ok then return false, made end
        crafted = crafted + made
        if crafted >= count then break end
    end
    return true, crafted
end

local function dropSupply()
    local supply = config:get("supply"); if not supply then return 0 end
    local moved = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            local ok, n = pcall(peripheral.call, supply, "pullItems", "self", slot,
                turtle.getItemCount(slot))
            if ok and type(n) == "number" then moved = moved + n end
        end
    end
    return moved
end

local function interactiveAdd(name)
    print("Enter pattern lines (1..3), blank to finish:")
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
        write("item for '" .. k .. "'> ")
        local item = read()
        if item == "" then print("aborted"); return end
        mapping[k] = item
    end
    write("output count> "); local n = tonumber(read() or "1") or 1
    recipes:set(name, { kind = "shaped", pattern = pattern, key = mapping, output = n })
    print("recipe '" .. name .. "' saved.")
end

local unsubscribe = app.subscribeAll({
    craft_order = function(msg, env)
        local proc = unison and unison.process
        local tok = proc and proc.markBusy and proc.markBusy("craft_order") or nil
        local ok, n_or_err = craft(msg.name, msg.count or 1)
        if proc and proc.clearBusy then proc.clearBusy(tok) end
        unison.rpc.reply(env, {
            type = "craft_reply",
            ok = ok or false, crafted = ok and n_or_err or 0,
            err = (not ok) and n_or_err or nil,
        })
    end,
    recipe_list = function(msg, env)
        local out = recipes:keys(); table.sort(out)
        unison.rpc.reply(env, { type = "craft_reply", ok = true, recipes = out })
    end,
    recipe_add = function(msg, env)
        if not (msg.name and msg.pattern and msg.key) then
            return unison.rpc.reply(env, { type = "craft_reply", ok = false, err = "missing fields" })
        end
        recipes:set(msg.name, {
            kind = "shaped", pattern = msg.pattern, key = msg.key, output = msg.output or 1,
        })
        unison.rpc.reply(env, { type = "craft_reply", ok = true })
    end,
})

cli.run({
    intro = "autocraft online. " .. recipes:size() .. " recipe(s); supply=" ..
            tostring(config:get("supply") or "(unset)"),
    prompt = "autocraft",
    commands = {
        recipes = {
            desc = "list known recipes",
            run = function()
                local keys = recipes:keys(); table.sort(keys)
                print(string.format("%-30s %s", "RECIPE", "OUT/CRAFT"))
                if #keys == 0 then print("  (none)") end
                for _, k in ipairs(keys) do
                    print(string.format("%-30s %d", k:sub(1, 30), recipes:get(k).output or 1))
                end
            end,
        },
        add = {
            desc = "interactive recipe entry",
            args = { { name = "name", required = true } },
            run  = function(_, a) interactiveAdd(a.name) end,
        },
        craft = {
            desc = "craft N items",
            args = {
                { name = "name", required = true },
                { name = "n",    type = "number", default = 1 },
            },
            run = function(_, a)
                local ok, r = craft(a.name, a.n)
                if ok then print("crafted " .. r .. " of " .. a.name)
                else printError("craft: " .. tostring(r)) end
            end,
        },
        drop = {
            desc = "push everything from inventory back to supply",
            run = function() print("dropped " .. dropSupply() .. " items into supply") end,
        },
        supply = {
            desc = "set the supply chest peripheral",
            args = { { name = "name", required = true } },
            run = function(_, a) config:set("supply", a.name); print("supply = " .. a.name) end,
        },
    },
    on_exit = function() unsubscribe() end,
})
