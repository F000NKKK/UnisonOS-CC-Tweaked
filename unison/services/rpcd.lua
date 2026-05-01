-- RPC daemon. Tries to maintain a WebSocket connection to the VPS for
-- real-time message delivery; falls back to HTTP polling if the WS
-- handshake fails. Heartbeats and outbound sends use the same transport
-- when WS is up, otherwise plain HTTP.

local log = dofile("/unison/kernel/log.lua")
local client = dofile("/unison/rpc/client.lua")

local M = {}

local handlers = {}
local POLL_INTERVAL = 3
local HEARTBEAT_INTERVAL = 20
local WS_RECONNECT_SEC = 5
local GPS_STATE_FILE = "/unison/state/gpsnet.lua"

local activeWs = nil
local handlerSeq = 0

local function senderId(env, msg)
    return tostring(
        (env and env.msg and env.msg.from)
        or (env and env.from)
        or (msg and msg.from)
        or ""
    )
end

local function iRound(n)
    n = tonumber(n) or 0
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function loadGpsnetState()
    if not fs.exists(GPS_STATE_FILE) then return nil end
    local fn = loadfile(GPS_STATE_FILE)
    if not fn then return nil end
    local ok, t = pcall(fn)
    if not ok or type(t) ~= "table" then return nil end
    return t
end

local function listHas(list, value)
    if type(list) ~= "table" then return false end
    local s = tostring(value or "")
    for _, v in ipairs(list) do
        local x = tostring(v)
        if x == "*" or x == s then return true end
    end
    return false
end

local function aclAllowed(msgType, fromId)
    local cfg = unison and unison.config and unison.config.rpc_acl
    if type(cfg) ~= "table" then return true end
    local rule = cfg[msgType] or cfg["*"]
    if rule == nil then return true end
    if rule == true then return true end
    if rule == false then return false end
    local from = tostring(fromId or "")
    if type(rule) == "string" then
        return rule == "*" or rule == from
    end
    if type(rule) == "table" then
        if listHas(rule.deny, from) then return false end
        if rule.allow ~= nil then return listHas(rule.allow, from) end
        if #rule > 0 then return listHas(rule, from) end
        if rule.default ~= nil then return not not rule.default end
    end
    return true
end

local function runHandler(fn, msg, envelope)
    local ok, err = pcall(fn, msg, envelope)
    if not ok then log.warn("rpcd", "handler error: " .. tostring(err)) end
end

local function denyReplyType(msgType)
    if msgType == "exec" then return "exec_reply" end
    if msgType == "pilot" then return "pilot_reply" end
    if msgType == "craft_order" or msgType == "recipe_list" or msgType == "recipe_add" then
        return "craft_reply"
    end
    if msgType:match("^mine_") then return "mine_reply" end
    if msgType:match("^farm_") then return "farm_reply" end
    if msgType:match("^scanner_") then return "scanner_reply" end
    if msgType:match("^storage_") then return "storage_reply" end
    if msgType:match("^atlas_") then return "atlas_reply" end
    return nil
end

function M.on(msgType, fn)
    handlers[msgType] = handlers[msgType] or {}
    table.insert(handlers[msgType], fn)
end

local function dispatch(envelope)
    local msg = envelope.msg or {}
    local msgType = tostring(msg.type or "*")
    local from = senderId(envelope, msg)
    if not aclAllowed(msgType, from) then
        log.warn("rpcd", "acl denied type=" .. tostring(msgType) .. " from=" .. from)
        local replyType = denyReplyType(msgType)
        if replyType and unison and unison.rpc and unison.rpc.reply then
            unison.rpc.reply(envelope, {
                type = replyType,
                ok = false,
                err = "acl denied",
            })
        end
        return
    end

    local list = handlers[msgType] or handlers["*"]
    if not list then
        log.debug("rpcd", "no handler for type=" .. tostring(msgType))
        return
    end
    local sched = unison and unison.kernel and unison.kernel.scheduler
    for _, fn in ipairs(list) do
        if sched and sched.spawn then
            handlerSeq = handlerSeq + 1
            local workerName = string.format("rpc-%s-%d", tostring(msgType), handlerSeq)
            sched.spawn(function() runHandler(fn, msg, envelope) end, workerName, {
                priority = -2, group = "system",
            })
        else
            runHandler(fn, msg, envelope)
        end
    end
end

local function collectMetrics()
    local metrics = {
        uptime = math.floor((os.epoch("utc") - (UNISON.boot_time or 0)) / 1000),
        role = unison and unison.role or nil,
    }
    metrics.capabilities = {
        rpc = true,
        turtle = turtle and true or false,
        gps = gps and true or false,
        modem = peripheral and peripheral.find and (peripheral.find("modem") ~= nil) or false,
        monitor = peripheral and peripheral.find and (peripheral.find("monitor") ~= nil) or false,
    }
    if turtle then
        metrics.fuel = turtle.getFuelLevel()
        local used = 0
        for i = 1, 16 do if turtle.getItemCount(i) > 0 then used = used + 1 end end
        metrics.inventory_used = used
    end
    -- Surface mine app state if there's an active job, so the dashboard
    -- can render live progress without polling exec.
    if fs.exists("/unison/state/mine/job.json") then
        local lib = unison and unison.lib
        local j = lib and lib.fs and lib.fs.readJson("/unison/state/mine/job.json")
        if type(j) == "table" then
            metrics.mine = {
                phase = j.phase, dug = j.dug,
                pos = j.pos, shape = j.shape,
                started_at = j.started_at,
                error = j.error,
            }
        end
    end
    local state = loadGpsnetState() or {}
    local mode = state.mode == "host" and "host" or "auto"
    metrics.gpsnet = { mode = mode }
    metrics.capabilities.gps_http = true

    local hosted = mode == "host" and state.host
    if hosted and hosted.x and hosted.y and hosted.z then
        metrics.position = {
            x = iRound(hosted.x),
            y = iRound(hosted.y),
            z = iRound(hosted.z),
        }
        metrics.position_source = "host"
        metrics.gpsnet.host = true
        metrics.capabilities.gps_http_host = true
    else
        -- Use unison.lib.gps so we share its no-fix cache and don't block
        -- every heartbeat for a full GPS timeout when there are no towers.
        local lib = unison and unison.lib
        local gotFix = false
        if lib and lib.gps then
            local x, y, z, src = lib.gps.locate("self", { timeout = 0.5 })
            if x and src == "gps" then
                metrics.position = { x = iRound(x), y = iRound(y), z = iRound(z) }
                metrics.position_source = "gps"
                gotFix = true
            end
        end
        -- Tower fallback: a host configured via gps-tower has its coords
        -- saved locally even though it can't triangulate itself. Pick them
        -- up so the dashboard sees towers without an explicit gpsnet host.
        if not gotFix and lib and lib.fs and fs.exists("/unison/state/gps-host.json") then
            local saved = lib.fs.readJson("/unison/state/gps-host.json")
            if type(saved) == "table" and saved.x and saved.y and saved.z then
                metrics.position = {
                    x = iRound(saved.x), y = iRound(saved.y), z = iRound(saved.z),
                }
                metrics.position_source = "tower"
            end
        end
    end
    return metrics
end

local function pollLoop()
    while true do
        if not activeWs then
            local resp, err = client.poll()
            if resp and type(resp.messages) == "table" then
                for _, env in ipairs(resp.messages) do dispatch(env) end
            elseif err then
                log.debug("rpcd", "poll error: " .. tostring(err))
            end
        end
        sleep(POLL_INTERVAL)
    end
end

local function heartbeatLoop()
    while true do
        local metrics = collectMetrics()
        if activeWs then
            client.wsHeartbeat(activeWs, metrics)
        else
            local _, err = client.heartbeat(metrics)
            if err then log.debug("rpcd", "heartbeat error: " .. tostring(err)) end
        end
        sleep(HEARTBEAT_INTERVAL)
    end
end

-- Wraps client.send so messages go through WS when available.
local function wsAwareSend(target, msg)
    if activeWs then
        local ok = client.wsSend(activeWs, target, msg)
        if ok then return { ok = true } end
        -- WS send failed; fall through to HTTP
    end
    return client.send(target, msg)
end

local function wsLoop()
    while true do
        sleep(0)   -- guarantee a yield each iteration
        local ok, ws, err = pcall(client.wsConnect)
        if not ok then
            log.warn("rpcd", "wsConnect crash: " .. tostring(ws))
            sleep(WS_RECONNECT_SEC)
        elseif not ws then
            log.debug("rpcd", "ws unavailable: " .. tostring(err) .. "; using polling")
            sleep(WS_RECONNECT_SEC)
        else
            activeWs = ws
            log.info("rpcd", "ws connected")
            while true do
                local rok, raw = pcall(ws.receive)
                if not rok or not raw then break end
                local msg = textutils.unserializeJSON(raw)
                if msg and msg.type == "message" and msg.envelope then
                    dispatch(msg.envelope)
                end
                -- Yield AFTER dispatch so any reply ws.send has time to
                -- drain CC's per-socket pending queue before we read again.
                sleep(0.05)
            end
            activeWs = nil
            log.warn("rpcd", "ws closed; reconnecting in " .. WS_RECONNECT_SEC .. "s")
            pcall(ws.close)
            sleep(WS_RECONNECT_SEC)
        end
    end
end

function M.run()
    log.info("rpcd", "registering with VPS...")
    local _, err = client.register()
    if err then log.warn("rpcd", "register failed: " .. tostring(err))
    else log.info("rpcd", "registered as " .. tostring(os.getComputerID())) end

    -- Expose subscription + transport-aware send to apps.
    client.on  = M.on
    client.off = function(msgType) handlers[msgType] = nil end
    -- subscribe = idempotent register: drops stale handlers first, then on().
    -- Apps used to call off()+on() everywhere; this folds it into one call.
    client.subscribe = function(msgType, fn)
        handlers[msgType] = nil
        M.on(msgType, fn)
    end
    -- reply(env, payload) — sends a typed reply back to the message origin
    -- with from/in_reply_to filled in. payload is merged in.
    client.reply = function(env, payload)
        local from = env and env.msg and env.msg.from
                  or env and env.from
                  or "broadcast"
        local out = { from = tostring(os.getComputerID()) }
        if env and env.id then out.in_reply_to = env.id end
        for k, v in pairs(payload or {}) do out[k] = v end
        return client.send(from, out)
    end
    -- ACL helper for apps. Usage:
    --   if not unison.rpc.allowed("mine_order", env) then ... end
    client.allowed = function(msgType, env)
        return aclAllowed(msgType, senderId(env))
    end
    -- Replace send with WS-aware variant; original HTTP send still
    -- accessible via client.httpSend for fallback debugging.
    client.httpSend = client.send
    client.send = wsAwareSend
    unison.rpc = client

    -- Built-in handlers.
    M.on("ping", function(msg, env)
        client.send(env.from or msg.from or "broadcast", {
            type = "pong",
            from = tostring(os.getComputerID()),
            in_reply_to = env.id,
            client_ts = msg.ts,            -- echo so caller can compute RTT
            ts = os.epoch("utc"),
        })
    end)

    M.on("exec", function(msg, env)
        if not msg.command then return end
        log.info("rpcd", "remote exec: " .. tostring(msg.command))

        -- The CraftOS `shell` global is not in scope inside our rpcd
        -- coroutine, so route the line through our own shell-command
        -- loader, then fall back to /unison/apps/<name>/ for installed
        -- packages.
        local toks = {}
        for w in msg.command:gmatch("%S+") do toks[#toks + 1] = w end
        local name = toks[1]; table.remove(toks, 1)

        local function tryBuiltin()
            local p = "/unison/shell/commands/" .. tostring(name) .. ".lua"
            if not fs.exists(p) then return nil end
            local fn = loadfile(p); if not fn then return false, "load builtin failed" end
            local mod = fn(); if not (mod and mod.run) then return false, "bad builtin" end
            local ctx = { commands = {}, cwd = "/", running = true, history = {} }
            return pcall(mod.run, ctx, toks)
        end

        local function tryApp()
            local d = "/unison/apps/" .. tostring(name)
            if not (fs.exists(d) and fs.isDir(d)) then return nil end
            local fn = loadfile("/unison/shell/commands/run.lua")
            if not fn then return false, "run loader failed" end
            local mod = fn(); if not (mod and mod.run) then return false, "bad run module" end
            local ctx = { cwd = "/" }
            table.insert(toks, 1, name)
            return pcall(mod.run, ctx, toks)
        end

        -- Capture print/printError lines emitted while the command runs
        -- so the caller can see actual stdout in the reply.
        local captured = {}
        local origPrint = _G.print
        local origPrintError = _G.printError
        _G.print = function(...)
            local n = select("#", ...)
            local parts = {}
            for i = 1, n do parts[i] = tostring((select(i, ...))) end
            captured[#captured + 1] = table.concat(parts, "\t")
            return origPrint(...)
        end
        _G.printError = function(s)
            captured[#captured + 1] = "[err] " .. tostring(s)
            return origPrintError(s)
        end

        local ok, err = tryBuiltin()
        if ok == nil then ok, err = tryApp() end
        if ok == nil then ok, err = false, "unknown command: " .. tostring(name) end

        _G.print = origPrint
        _G.printError = origPrintError

        -- Cap output size so a runaway command can't blow up the bus.
        local MAX_LINES, MAX_LEN = 200, 2000
        if #captured > MAX_LINES then
            local trimmed = {}
            for i = #captured - MAX_LINES + 1, #captured do
                trimmed[#trimmed + 1] = captured[i]
            end
            captured = trimmed
        end
        local outStr = table.concat(captured, "\n")
        if #outStr > MAX_LEN * 50 then outStr = outStr:sub(-MAX_LEN * 50) end

        client.reply(env, {
            type = "exec_reply",
            ok = ok or false,
            err = (not ok) and tostring(err) or nil,
            output = outStr,
            command = msg.command,
        })
    end)

    local sched = unison.kernel.scheduler
    sched.spawn(wsLoop, "rpcd-ws")
    sched.spawn(pollLoop, "rpcd-poll")
    sched.spawn(heartbeatLoop, "rpcd-hb")
end

return M
