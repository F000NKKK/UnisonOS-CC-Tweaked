-- patrol 1.3.0 — lib.turtle-based movement. Same step DSL but the
-- retry/dig/attack semantics are now shared with the rest of the
-- turtle packages.

if not turtle then print("patrol: must run on a turtle"); return end

local lib   = unison.lib
local cli   = lib.cli
local app   = lib.app
local tlib  = lib.turtle
local store = lib.kvstore.open("patrol", { routes = {} })
local routes = store:get("routes", {})
local function persist() store:set("routes", routes) end

local busy = false

-- Repeat a single tlib move N times (default 1). Patrol traditionally
-- attacks mobs in the way; route authors can opt out per step (see
-- the `attack=false` step prefix in parseStep below) but default-on
-- preserves 1.x behaviour.
local function moveN(fn, n)
    n = math.max(1, tonumber(n) or 1)
    for _ = 1, n do
        if not fn({ attack = true }) then return false end
    end
    return true
end

local STEPS = {
    f = function(n) return moveN(tlib.forward, n) end,
    fwd = function(n) return moveN(tlib.forward, n) end,
    forward = function(n) return moveN(tlib.forward, n) end,
    b = function(n) return moveN(tlib.back, n) end, back = function(n) return moveN(tlib.back, n) end,
    u = function(n) return moveN(tlib.up, n) end,
    up = function(n) return moveN(tlib.up, n) end,
    d = function(n) return moveN(tlib.down, n) end,
    down = function(n) return moveN(tlib.down, n) end,
    l = function() return turtle.turnLeft() end, left = function() return turtle.turnLeft() end,
    r = function() return turtle.turnRight() end, right = function() return turtle.turnRight() end,
    dig = function() return turtle.dig() end,
    digup = function() return turtle.digUp() end, digdown = function() return turtle.digDown() end,
    place = function() return turtle.place() end,
    placeup = function() return turtle.placeUp() end, placedown = function() return turtle.placeDown() end,
    wait = function(n) sleep(tonumber(n) or 1); return true end,
    sel = function(n) return turtle.select(tonumber(n) or 1) end,
}

local function parseStep(line)
    local toks = {}; for w in line:gmatch("%S+") do toks[#toks + 1] = w end
    if #toks == 0 then return nil end
    return { cmd = toks[1]:lower(), arg = tonumber(toks[2]) }
end

local function runRoute(name, loops)
    if busy then return false, "busy" end
    local route = routes[name]; if not route then return false, "no such route" end
    loops = math.max(1, math.min(tonumber(loops) or 1, 1000))
    busy = true
    -- Mark busy at OS level too so updates defer while patrolling.
    local proc = unison and unison.process
    local busyTok = proc and proc.markBusy and proc.markBusy("patrol_run") or nil
    -- Wrap in pcall so a crash doesn't strand busy=true.
    local ok, result = pcall(function()
        local total = 0
        for _ = 1, loops do
            for _, step in ipairs(route.steps) do
                local fn = STEPS[step.cmd]
                if not fn then error("unknown step: " .. step.cmd, 0) end
                local rok = fn(step.arg)
                if not rok then error("step failed: " .. step.cmd, 0) end
                total = total + 1
            end
        end
        return total
    end)
    if proc and proc.clearBusy then proc.clearBusy(busyTok) end
    busy = false
    if not ok then return false, result end
    return true, result
end

local function recordRoute(name)
    print("recording '" .. name .. "'.   '.' to finish, '!' to abort.")
    local steps = {}
    while true do
        write(string.format("[%02d] step> ", #steps + 1))
        local line = read()
        if line == nil or line == "!" then print("aborted"); return end
        if line == "." then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local s = parseStep(line)
            if not s or not STEPS[s.cmd] then printError("unknown step")
            else steps[#steps + 1] = s end
        end
    end
    routes[name] = { steps = steps, ts = os.epoch("utc") }; persist()
    print("saved '" .. name .. "' with " .. #steps .. " step(s).")
end

local unsubscribe = app.subscribeAll({
    patrol_run = function(msg, env)
        local ok, info = runRoute(msg.name, msg.loops)
        unison.rpc.reply(env, {
            type = "patrol_reply",
            ok = ok or false, steps = ok and info or 0,
            err = (not ok) and info or nil,
        })
    end,
    patrol_list = function(msg, env)
        local out = {}; for k in pairs(routes) do out[#out + 1] = k end
        table.sort(out)
        unison.rpc.reply(env, { type = "patrol_reply", ok = true, routes = out })
    end,
})

local args = { ... }
if args[1] == "listen" then
    print("patrol listening as turtle " .. tostring(unison.id) .. "  (Q to stop)")
    lib.app.listenLoop()
    unsubscribe()
    print("stopping patrol listener.")
    return
end

cli.run({
    intro = "patrol online. " .. (function()
        local n = 0; for _ in pairs(routes) do n = n + 1 end; return n
    end)() .. " route(s) saved.",
    prompt = "patrol",
    commands = {
        list = {
            desc = "saved routes",
            run = function()
                local keys = {}; for k in pairs(routes) do keys[#keys + 1] = k end; table.sort(keys)
                print(string.format("%-20s %s", "ROUTE", "STEPS"))
                if #keys == 0 then print("  (none)") end
                for _, k in ipairs(keys) do print(string.format("%-20s %d", k, #routes[k].steps)) end
            end,
        },
        record = {
            desc = "record a new route",
            args = { { name = "name", required = true } },
            run = function(_, a) recordRoute(a.name) end,
        },
        show = {
            desc = "print steps of a route",
            args = { { name = "name", required = true } },
            run = function(_, a)
                local r = routes[a.name]; if not r then printError("no such route"); return end
                for i, s in ipairs(r.steps) do
                    print(string.format("  %02d  %s%s", i, s.cmd, s.arg and (" " .. s.arg) or ""))
                end
            end,
        },
        run = {
            desc = "play a route",
            args = {
                { name = "name", required = true },
                { name = "loops", type = "number", default = 1 },
            },
            run = function(_, a)
                local ok, info = runRoute(a.name, a.loops)
                if ok then print("ran " .. info .. " step(s)")
                else printError("run: " .. tostring(info)) end
            end,
        },
        delete = {
            desc = "remove a route",
            args = { { name = "name", required = true } },
            run = function(_, a) routes[a.name] = nil; persist(); print("removed " .. a.name) end,
        },
    },
    on_exit = function() unsubscribe() end,
})
