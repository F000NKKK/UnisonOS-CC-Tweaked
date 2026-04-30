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

local activeWs = nil

function M.on(msgType, fn)
    handlers[msgType] = handlers[msgType] or {}
    table.insert(handlers[msgType], fn)
end

local function dispatch(envelope)
    local msg = envelope.msg or {}
    local list = handlers[msg.type or "*"] or handlers["*"]
    if not list then
        log.debug("rpcd", "no handler for type=" .. tostring(msg.type))
        return
    end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, msg, envelope)
        if not ok then log.warn("rpcd", "handler error: " .. tostring(err)) end
    end
end

local function collectMetrics()
    local metrics = {
        uptime = math.floor((os.epoch("utc") - (UNISON.boot_time or 0)) / 1000),
    }
    if turtle then
        metrics.fuel = turtle.getFuelLevel()
        local used = 0
        for i = 1, 16 do if turtle.getItemCount(i) > 0 then used = used + 1 end end
        metrics.inventory_used = used
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
            ts = os.epoch("utc"),
        })
    end)

    M.on("exec", function(msg, env)
        if not msg.command then return end
        log.info("rpcd", "remote exec: " .. tostring(msg.command))
        local ok, err = pcall(shell.run, msg.command)
        client.send(env.from or msg.from or "broadcast", {
            type = "exec_reply",
            in_reply_to = env.id,
            ok = ok,
            err = err and tostring(err),
        })
    end)

    local sched = unison.kernel.scheduler
    sched.spawn(wsLoop, "rpcd-ws")
    sched.spawn(pollLoop, "rpcd-poll")
    sched.spawn(heartbeatLoop, "rpcd-hb")
end

return M
