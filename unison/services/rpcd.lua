-- RPC daemon. Tries to maintain a WebSocket connection to the VPS for
-- real-time message delivery; falls back to HTTP polling if the WS
-- handshake fails. Heartbeats and outbound sends use the same transport
-- when WS is up, otherwise plain HTTP.
--
-- Heavy lifting lives in:
--   * /unison/lib/rpcd/acl.lua      — per-message-type firewall
--   * /unison/lib/rpcd/metrics.lua  — heartbeat snapshot builder
-- This file is the orchestrator: handler registry, dispatch, the four
-- worker loops (ws/poll/heartbeat) and the built-in handlers (ping,
-- redstone_set, exec).

local log     = dofile("/unison/kernel/log.lua")
local client  = dofile("/unison/rpc/client.lua")
local Acl     = dofile("/unison/lib/rpcd/acl.lua")
local Metrics = dofile("/unison/lib/rpcd/metrics.lua")

local M = {}

local handlers = {}
local handlerSeq = 0
local activeWs = nil

local POLL_INTERVAL      = 3
local HEARTBEAT_INTERVAL = 20
local WS_RECONNECT_SEC   = 5

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function senderId(env, msg)
    return tostring(
        (env and env.msg and env.msg.from)
        or (env and env.from)
        or (msg and msg.from)
        or ""
    )
end

local function runHandler(fn, msg, envelope)
    local ok, err = pcall(fn, msg, envelope)
    if not ok then log.warn("rpcd", "handler error: " .. tostring(err)) end
end

----------------------------------------------------------------------
-- Subscription registry
----------------------------------------------------------------------

function M.on(msgType, fn)
    handlers[msgType] = handlers[msgType] or {}
    table.insert(handlers[msgType], fn)
end

local function dispatch(envelope)
    local msg = envelope.msg or {}
    local msgType = tostring(msg.type or "*")
    local from = senderId(envelope, msg)

    if not Acl.allowed(msgType, from) then
        log.warn("rpcd", "acl denied type=" .. msgType .. " from=" .. from)
        local replyType = Acl.replyTypeFor(msgType)
        if replyType and unison and unison.rpc and unison.rpc.reply then
            unison.rpc.reply(envelope,
                { type = replyType, ok = false, err = "acl denied" })
        end
        return
    end

    local list = handlers[msgType] or handlers["*"]
    if not list then
        log.debug("rpcd", "no handler for type=" .. tostring(msgType))
        return
    end

    -- Each handler runs in its own scheduler coroutine so a slow one
    -- can't block the dispatch path.
    local sched = unison and unison.kernel and unison.kernel.scheduler
    for _, fn in ipairs(list) do
        if sched and sched.spawn then
            handlerSeq = handlerSeq + 1
            local workerName = string.format("rpc-%s-%d", msgType, handlerSeq)
            sched.spawn(function() runHandler(fn, msg, envelope) end,
                workerName, { priority = -2, group = "system" })
        else
            runHandler(fn, msg, envelope)
        end
    end
end

----------------------------------------------------------------------
-- Worker loops
----------------------------------------------------------------------

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
        local m = Metrics.collect()
        if activeWs then
            client.wsHeartbeat(activeWs, m)
        else
            local _, err = client.heartbeat(m)
            if err then log.debug("rpcd", "heartbeat error: " .. tostring(err)) end
        end
        sleep(HEARTBEAT_INTERVAL)
    end
end

-- Wraps client.send so messages go through WS when available. Falls
-- back to client.httpSend (which wireClientApi sets up as an alias for
-- the original HTTP `send`). NOT `client.send` — that's now this very
-- wrapper, so calling it would recurse until the stack blows. The bug
-- ate every reply when WS was either unavailable or wsSend returned
-- false (so dashboard exec/cron/log queries timed out even though the
-- handler ran fine on the node).
local function wsAwareSend(target, msg)
    if activeWs then
        local ok = client.wsSend(activeWs, target, msg)
        if ok then return { ok = true } end
        -- WS send failed; fall through to HTTP.
    end
    return client.httpSend(target, msg)
end

local function wsLoop()
    while true do
        sleep(0)   -- yield once per iteration
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

----------------------------------------------------------------------
-- Built-in handlers (ping / redstone_set / exec)
----------------------------------------------------------------------

local function installBuiltinHandlers()
    M.on("ping", function(msg, env)
        client.send(env.from or msg.from or "broadcast", {
            type = "pong",
            from = tostring(os.getComputerID()),
            in_reply_to = env.id,
            client_ts = msg.ts,        -- echo so caller can compute RTT
            ts = os.epoch("utc"),
        })
    end)

    -- Remote redstone control. Drives Create train stations, motors, and
    -- item drains from the dashboard via { side, value } payloads.
    M.on("redstone_set", function(msg, env)
        if not (redstone and redstone.setAnalogOutput) then
            client.reply(env, { type = "redstone_reply", ok = false,
                                err = "no redstone" })
            return
        end
        local side = msg.side
        local val = tonumber(msg.value)
        if not (side and val) then
            client.reply(env, { type = "redstone_reply", ok = false,
                                err = "side+value required" })
            return
        end
        val = math.max(0, math.min(15, math.floor(val)))
        local ok, err = pcall(redstone.setAnalogOutput, side, val)
        client.reply(env, {
            type = "redstone_reply",
            ok = ok and true or false,
            err = (not ok) and tostring(err) or nil,
            side = side, value = val,
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

        -- Capture print/printError lines emitted while the command runs.
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
end

----------------------------------------------------------------------
-- Wire up the rpc client API + spawn the loops.
----------------------------------------------------------------------

local function wireClientApi()
    client.on  = M.on
    client.off = function(msgType) handlers[msgType] = nil end
    -- Idempotent register: drops stale handlers first, then on().
    -- Apps used to call off()+on() everywhere; this folds it.
    client.subscribe = function(msgType, fn)
        handlers[msgType] = nil
        M.on(msgType, fn)
    end
    -- Typed reply. Fills `from` and `in_reply_to`.
    client.reply = function(env, payload)
        local from = env and env.msg and env.msg.from
                  or env and env.from
                  or "broadcast"
        local out = { from = tostring(os.getComputerID()) }
        if env and env.id then out.in_reply_to = env.id end
        for k, v in pairs(payload or {}) do out[k] = v end
        return client.send(from, out)
    end
    -- ACL helper for apps.
    client.allowed = function(msgType, env)
        return Acl.allowed(msgType, senderId(env))
    end
    -- WS-aware send; HTTP send still accessible via httpSend.
    client.httpSend = client.send
    client.send = wsAwareSend
    unison.rpc = client
end

function M.run()
    log.info("rpcd", "registering with VPS...")
    local _, err = client.register()
    if err then log.warn("rpcd", "register failed: " .. tostring(err))
    else log.info("rpcd", "registered as " .. tostring(os.getComputerID())) end

    wireClientApi()
    installBuiltinHandlers()

    local sched = unison.kernel.scheduler
    sched.spawn(wsLoop,        "rpcd-ws",   { group = "system" })
    sched.spawn(pollLoop,      "rpcd-poll", { group = "system" })
    sched.spawn(heartbeatLoop, "rpcd-hb",   { group = "system" })
end

return M
