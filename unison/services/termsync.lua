-- unison.services.termsync — streams the device's terminal screen to
-- subscribed bus clients (typically the web console) and feeds keyboard
-- events received from them back into the local event queue, so a
-- subscriber sees a 1:1 mirror and can drive the shell remotely.

local log = unison.kernel.log
local term_buffer = dofile("/unison/lib/term_buffer.lua")

local M = {}

local SNAPSHOT_INTERVAL = 0.3   -- seconds between forced snapshots

local subscribers = {}    -- [device_id] = expires_ms (0 = unsubscribed)
local installed = false
local buffer = nil
local running = false

local function nowMs() return os.epoch("utc") end

local function install()
    if installed then return end
    buffer = term_buffer.create(term.current())
    term.redirect(buffer)
    installed = true
    -- Mirror the very first frame to the screen so writes that happened
    -- before subscribe still show as "current state".
end

local function snapshotTo(target)
    if not buffer then return end
    if not (unison.rpc and unison.rpc.send) then return end
    unison.rpc.send(target, {
        type = "term_frame",
        from = tostring(unison.id),
        frame = buffer.snapshot(),
        ts = nowMs(),
    })
end

local function activeSubscribers()
    local out = {}
    local now = nowMs()
    for id, expires in pairs(subscribers) do
        if expires and expires > now then out[#out + 1] = id
        else subscribers[id] = nil end
    end
    return out
end

-- Inject keyboard events from a remote client. CC's BIOS only sees these
-- when they go through os.queueEvent.
local function injectEvent(msg)
    local kind = msg.event or "char"
    local v = msg.value
    if kind == "char" and type(v) == "string" then
        for i = 1, #v do os.queueEvent("char", v:sub(i, i)) end
    elseif kind == "key" then
        os.queueEvent("key", tonumber(v) or 0, msg.held and true or false)
        if msg.with_char then os.queueEvent("char", tostring(msg.with_char)) end
    elseif kind == "key_up" then
        os.queueEvent("key_up", tonumber(v) or 0)
    elseif kind == "paste" then
        os.queueEvent("paste", tostring(v or ""))
    elseif kind == "terminate" then
        os.queueEvent("terminate")
    end
end

local function setupRpc()
    if not (unison.rpc and unison.rpc.subscribe) then return end

    unison.rpc.subscribe("term_subscribe", function(msg, env)
        install()
        local from = (env and env.msg and env.msg.from) or msg.from or "?"
        local ttl = tonumber(msg.ttl) or 30   -- subscriber must renew within ttl seconds
        subscribers[tostring(from)] = nowMs() + ttl * 1000
        snapshotTo(from)
        log.info("termsync", "subscribe " .. tostring(from))
    end)

    unison.rpc.subscribe("term_unsubscribe", function(msg, env)
        local from = (env and env.msg and env.msg.from) or msg.from or "?"
        subscribers[tostring(from)] = nil
        log.info("termsync", "unsubscribe " .. tostring(from))
    end)

    unison.rpc.subscribe("term_input", function(msg)
        injectEvent(msg)
    end)
end

function M.run()
    setupRpc()
    running = true
    while running do
        local subs = activeSubscribers()
        if #subs > 0 then
            for _, sub in ipairs(subs) do snapshotTo(sub) end
        end
        sleep(SNAPSHOT_INTERVAL)
    end
end

function M.stop() running = false end

return M
