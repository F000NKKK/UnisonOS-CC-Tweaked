-- patrol 1.1.0 — UniAPI rewrite. lib.cli for REPL, lib.kvstore for routes,
-- lib.app for RPC subscription, rpc.reply for outbound.

if not turtle then print("patrol: must run on a turtle"); return end

local lib   = unison.lib
local cli   = lib.cli
local app   = lib.app
local store = lib.kvstore.open("patrol", { routes = {} })
local routes = store:get("routes", {})
local function persist() store:set("routes", routes) end

local busy = false

local function tryN(fn, n, attackFn)
    n = n or 1
    for _ = 1, n do
        local ok = fn()
        if not ok then
            for _ = 1, 10 do
                if attackFn then attackFn() end
                if fn() then ok = true; break end
                sleep(0.2)
            end
            if not ok then return false end
        end
    end
    return true
end

local STEPS = {
    f = function(n) return tryN(turtle.forward, n, turtle.attack) end,
    fwd = function(n) return tryN(turtle.forward, n, turtle.attack) end,
    forward = function(n) return tryN(turtle.forward, n, turtle.attack) end,
    b = function(n) return tryN(turtle.back, n) end, back = function(n) return tryN(turtle.back, n) end,
    u = function(n) return tryN(turtle.up, n, turtle.attackUp) end,
    up = function(n) return tryN(turtle.up, n, turtle.attackUp) end,
    d = function(n) return tryN(turtle.down, n, turtle.attackDown) end,
    down = function(n) return tryN(turtle.down, n, turtle.attackDown) end,
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
    local total = 0
    for _ = 1, loops do
        for _, step in ipairs(route.steps) do
            local fn = STEPS[step.cmd]
            if not fn then busy = false; return false, "unknown step: " .. step.cmd end
            local ok = fn(step.arg)
            if not ok then busy = false; return false, "step failed: " .. step.cmd end
            total = total + 1
        end
    end
    busy = false
    return true, total
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
