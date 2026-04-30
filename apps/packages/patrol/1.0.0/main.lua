-- patrol — turtle route runner. Routes are saved sequences of moves; you
-- can record one by piloting the turtle, then replay or loop it.
--
-- Move tokens (case insensitive):
--   f n         move forward n (default 1)
--   b n         move back
--   u n         move up
--   d n         move down
--   l           turn left
--   r           turn right
--   dig         dig forward
--   digup / digdown
--   place / placeup / placedown
--   wait n      sleep n seconds
--   sel n       select inventory slot n
--
-- REPL:
--   list                       routes saved
--   record <name>              start interactive recording
--   show <name>                print steps
--   run <name> [loops]         play (default 1 loop)
--   delete <name>
--   help / q
--
-- RPC:
--   patrol_run    -> { name, loops? } -> patrol_reply { ok, steps, loops, err? }
--   patrol_list   -> {} -> patrol_reply { ok, routes }

local fsLib = unison.lib.fs

local STATE_FILE = "/unison/state/patrol.json"

local data = fsLib.readJson(STATE_FILE) or { routes = {} }
data.routes = data.routes or {}
local function save() fsLib.writeJson(STATE_FILE, data) end

local busy = false

----------------------------------------------------------------------
-- Move executor
----------------------------------------------------------------------

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
    f       = function(n) return tryN(turtle.forward, n, turtle.attack) end,
    fwd     = function(n) return tryN(turtle.forward, n, turtle.attack) end,
    forward = function(n) return tryN(turtle.forward, n, turtle.attack) end,
    b       = function(n) return tryN(turtle.back, n) end,
    back    = function(n) return tryN(turtle.back, n) end,
    u       = function(n) return tryN(turtle.up, n, turtle.attackUp) end,
    up      = function(n) return tryN(turtle.up, n, turtle.attackUp) end,
    d       = function(n) return tryN(turtle.down, n, turtle.attackDown) end,
    down    = function(n) return tryN(turtle.down, n, turtle.attackDown) end,
    l       = function() return turtle.turnLeft() end,
    left    = function() return turtle.turnLeft() end,
    r       = function() return turtle.turnRight() end,
    right   = function() return turtle.turnRight() end,
    dig     = function() return turtle.dig() end,
    digup   = function() return turtle.digUp() end,
    digdown = function() return turtle.digDown() end,
    place   = function() return turtle.place() end,
    placeup = function() return turtle.placeUp() end,
    placedown = function() return turtle.placeDown() end,
    wait    = function(n) sleep(tonumber(n) or 1); return true end,
    sel     = function(n) return turtle.select(tonumber(n) or 1) end,
}

local function parseStep(line)
    local toks = {}
    for w in line:gmatch("%S+") do toks[#toks + 1] = w end
    if #toks == 0 then return nil end
    return { cmd = toks[1]:lower(), arg = tonumber(toks[2]) }
end

local function runStep(step)
    local fn = STEPS[step.cmd]
    if not fn then return false, "unknown step: " .. tostring(step.cmd) end
    return fn(step.arg), nil
end

local function runRoute(name, loops)
    if busy then return false, "busy" end
    local route = data.routes[name]
    if not route then return false, "no such route" end
    loops = math.max(1, math.min(tonumber(loops) or 1, 1000))
    busy = true
    local total = 0
    for loop = 1, loops do
        for _, step in ipairs(route.steps) do
            local ok, err = runStep(step)
            if not ok then busy = false; return false, err end
            total = total + 1
        end
    end
    busy = false
    return true, total
end

----------------------------------------------------------------------
-- Recording
----------------------------------------------------------------------

local function recordRoute(name)
    if not name then printError("usage: record <name>"); return end
    print("recording route '" .. name .. "'.")
    print("type steps one per line; '.' to finish, '!' to abort.")
    local steps = {}
    while true do
        write(string.format("[%02d] step> ", #steps + 1))
        local line = read()
        if line == nil or line == "!" then print("aborted"); return end
        if line == "." then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local s = parseStep(line)
            if not s or not STEPS[s.cmd] then
                printError("unknown step (try 'help' for list)")
            else
                steps[#steps + 1] = s
            end
        end
    end
    data.routes[name] = { steps = steps, ts = os.epoch("utc") }
    save()
    print("saved '" .. name .. "' with " .. #steps .. " step(s).")
end

----------------------------------------------------------------------
-- RPC
----------------------------------------------------------------------

local function setupRpc()
    if not (unison.rpc and unison.rpc.on) then return end
    unison.rpc.off("patrol_run"); unison.rpc.off("patrol_list")

    unison.rpc.on("patrol_run", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local ok, info = runRoute(msg.name, msg.loops)
        unison.rpc.send(from, {
            type = "patrol_reply", from = tostring(unison.id),
            in_reply_to = env and env.id,
            ok = ok or false, steps = ok and info or 0,
            err = (not ok) and info or nil,
        })
    end)

    unison.rpc.on("patrol_list", function(msg, env)
        local from = env and env.msg and env.msg.from or "?"
        local out = {}
        for k in pairs(data.routes) do out[#out + 1] = k end
        table.sort(out)
        unison.rpc.send(from, {
            type = "patrol_reply", from = tostring(unison.id),
            in_reply_to = env and env.id, ok = true, routes = out,
        })
    end)
end

----------------------------------------------------------------------
-- REPL
----------------------------------------------------------------------

local function help()
    print("patrol commands:")
    print("  list                      saved routes")
    print("  record <name>             record interactively")
    print("  show <name>               print steps")
    print("  run <name> [loops]        replay (default 1 loop)")
    print("  delete <name>             remove a route")
    print("step tokens: f/b/u/d <n>, l/r, dig[up|down], place[up|down],")
    print("             wait <s>, sel <n>")
end

local function listRoutes()
    local keys = {}
    for k in pairs(data.routes) do keys[#keys + 1] = k end
    table.sort(keys)
    print(string.format("%-20s %s", "ROUTE", "STEPS"))
    if #keys == 0 then print("  (none — use 'record')") end
    for _, k in ipairs(keys) do
        print(string.format("%-20s %d", k, #data.routes[k].steps))
    end
end

local function showRoute(name)
    local r = data.routes[name]
    if not r then printError("no such route"); return end
    for i, s in ipairs(r.steps) do
        print(string.format("  %02d  %s%s", i, s.cmd, s.arg and (" " .. s.arg) or ""))
    end
end

if not turtle then print("patrol: must run on a turtle"); return end

setupRpc()

local args = { ... }
if args[1] == "listen" then
    print("patrol listening as turtle " .. tostring(unison.id))
    print("press Q to stop")
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "char" and (p1 == "q" or p1 == "Q") then break end
        if ev == "key" and p1 == keys.q then break end
    end
    if unison.rpc and unison.rpc.off then
        unison.rpc.off("patrol_run"); unison.rpc.off("patrol_list")
    end
    print("stopping patrol listener.")
    return
end

print("patrol online. " .. (function()
    local n = 0; for _ in pairs(data.routes) do n = n + 1 end; return n
end)() .. " route(s) saved.")

while true do
    write("patrol> ")
    local line = read()
    if not line then break end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts + 1] = w end
    local cmd = parts[1]
    if not cmd or cmd == "" then
    elseif cmd == "q" or cmd == "quit" or cmd == "exit" then break
    elseif cmd == "help" or cmd == "?" then help()
    elseif cmd == "list" then listRoutes()
    elseif cmd == "show" then showRoute(parts[2])
    elseif cmd == "record" then recordRoute(parts[2])
    elseif cmd == "delete" then
        if not parts[2] then printError("usage: delete <name>")
        else data.routes[parts[2]] = nil; save(); print("removed " .. parts[2]) end
    elseif cmd == "run" then
        if not parts[2] then printError("usage: run <name> [loops]")
        else
            local ok, info = runRoute(parts[2], parts[3])
            if ok then print("ran " .. info .. " step(s)")
            else printError("run: " .. tostring(info)) end
        end
    else printError("unknown: " .. cmd) end
end

if unison.rpc and unison.rpc.off then
    unison.rpc.off("patrol_run"); unison.rpc.off("patrol_list")
end
print("bye.")
