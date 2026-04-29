-- RPC daemon: registers this device with the VPS at startup, sends a
-- heartbeat every N seconds, and polls /api/messages/<id> for inbound
-- messages — dispatching them to handlers registered via M.on(type, fn).

local log = dofile("/unison/kernel/log.lua")
local client = dofile("/unison/rpc/client.lua")

local M = {}

local handlers = {}
local POLL_INTERVAL = 5
local HEARTBEAT_INTERVAL = 20

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

local function pollLoop()
    while true do
        local resp, err = client.poll()
        if resp and type(resp.messages) == "table" then
            for _, env in ipairs(resp.messages) do
                dispatch(env)
            end
        elseif err then
            log.debug("rpcd", "poll error: " .. tostring(err))
        end
        sleep(POLL_INTERVAL)
    end
end

local function heartbeatLoop()
    while true do
        local metrics = {
            uptime = math.floor((os.epoch("utc") - (UNISON.boot_time or 0)) / 1000),
            free_mem = (function()
                if collectgarbage then return collectgarbage("count") * 1024 end
                return -1
            end)(),
        }
        if turtle then
            metrics.fuel = turtle.getFuelLevel()
            local used = 0
            for i = 1, 16 do if turtle.getItemCount(i) > 0 then used = used + 1 end end
            metrics.inventory_used = used
        end
        local _, err = client.heartbeat(metrics)
        if err then log.debug("rpcd", "heartbeat error: " .. tostring(err)) end
        sleep(HEARTBEAT_INTERVAL)
    end
end

function M.run()
    log.info("rpcd", "registering with VPS...")
    local _, err = client.register()
    if err then log.warn("rpcd", "register failed: " .. tostring(err))
    else log.info("rpcd", "registered as " .. tostring(os.getComputerID())) end

    -- expose the client for apps and shell commands
    unison.rpc = client

    -- built-in handlers
    M.on("ping", function(msg, env)
        client.send(env.from or "broadcast", {
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
        client.send(env.from or "broadcast", {
            type = "exec_reply",
            in_reply_to = env.id,
            ok = ok,
            err = err and tostring(err),
        })
    end)

    local sched = unison.kernel.scheduler
    sched.spawn(pollLoop, "rpcd-poll")
    sched.spawn(heartbeatLoop, "rpcd-hb")
end

return M
