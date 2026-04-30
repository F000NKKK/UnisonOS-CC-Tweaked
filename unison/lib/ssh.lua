-- unison.lib.ssh — kernel-level "SSH" library for sharing a device's
-- terminal over the Unison bus, plus piping input back. Not encrypted on
-- its own (the bus already gates by bearer token); the value is the
-- diff-based wire protocol and the integration with rpcd/term.
--
-- Wire messages (sent over unison.rpc):
--   ssh_subscribe   { ttl = 30 }
--   ssh_unsubscribe {}
--   ssh_input       { event = "char|key|key_up|paste|terminate",
--                     value = ..., held = bool, with_char = string }
--   ssh_frame { full=true,  frame = { w, h, cursor, rows[1..h] } }
--   ssh_frame { diff=true,  w, h, cursor, rows = { [y] = row, ... } }
--
-- Server side (M.serve(opts)) installs a shadow term buffer over the
-- current term, registers the rpc handlers, and streams frames at
-- IDLE_TICK / DIRTY_TICK rates. Clients (M.connect) speak the same
-- protocol — useful both for a CC-to-CC ssh tab and for the web
-- console.

local term_buffer = dofile("/unison/lib/term_buffer.lua")

local M = {}

local IDLE_TICK  = 1.0
local DIRTY_TICK = 0.05
local DEFAULT_TTL_S = 30

----------------------------------------------------------------------
-- Server state
----------------------------------------------------------------------

local subscribers = {}   -- [client_id] = { expires_ms, rows={[y]=hash}, cursor="", baseline=false }
local installed = false
local buffer = nil
local serverRunning = false
local dirty = true

local function nowMs() return os.epoch("utc") end

local function rowHash(r)
    return (r.chars or "") .. "|" .. (r.fg or "") .. "|" .. (r.bg or "")
end
local function curHash(c)
    return string.format("%d,%d,%d,%d", c.x or 0, c.y or 0, c.fg or 0, c.bg or 0)
end

local function install()
    if installed then return end
    buffer = term_buffer.create(term.current())
    term.redirect(buffer)
    installed = true
end

local function activeSubs()
    local out = {}
    local now = nowMs()
    for id, s in pairs(subscribers) do
        if s.expires and s.expires > now then out[#out + 1] = id
        else subscribers[id] = nil end
    end
    return out
end

local function snapshotTo(target, transport)
    if not buffer then return end
    transport = transport or unison.rpc
    if not (transport and transport.send) then return end
    local s = subscribers[target]; if not s then return end
    local frame = buffer.snapshot()
    local payload

    if not s.baseline then
        payload = {
            type = "ssh_frame", from = tostring(unison.id),
            full = true, frame = frame, ts = nowMs(),
        }
        s.rows = {}
        for y = 1, frame.h do s.rows[y] = rowHash(frame.rows[y]) end
        s.cursor = curHash(frame.cursor)
        s.baseline = true
    else
        local changed, hasChange = {}, false
        for y = 1, frame.h do
            local h = rowHash(frame.rows[y])
            if s.rows[y] ~= h then changed[y] = frame.rows[y]; s.rows[y] = h; hasChange = true end
        end
        local newCur = curHash(frame.cursor)
        local cursorMoved = newCur ~= s.cursor
        if not (hasChange or cursorMoved) then return end
        s.cursor = newCur
        payload = {
            type = "ssh_frame", from = tostring(unison.id),
            diff = true, w = frame.w, h = frame.h,
            cursor = frame.cursor, rows = changed, ts = nowMs(),
        }
    end

    transport.send(target, payload)
end

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

local function setupRpc(opts)
    if not (unison.rpc and unison.rpc.subscribe) then return end
    local log = unison and unison.kernel and unison.kernel.log

    unison.rpc.subscribe("ssh_subscribe", function(msg, env)
        install()
        local from = (env and env.msg and env.msg.from) or msg.from or "?"
        local ttl = tonumber(msg.ttl) or DEFAULT_TTL_S
        subscribers[tostring(from)] = {
            expires = nowMs() + ttl * 1000,
            rows = {}, cursor = "", baseline = false,
        }
        dirty = true
        snapshotTo(tostring(from))
        if log then log.info("ssh", "subscribe " .. tostring(from)) end
        if opts and opts.on_subscribe then pcall(opts.on_subscribe, tostring(from)) end
    end)

    unison.rpc.subscribe("ssh_unsubscribe", function(msg, env)
        local from = (env and env.msg and env.msg.from) or msg.from or "?"
        subscribers[tostring(from)] = nil
        if log then log.info("ssh", "unsubscribe " .. tostring(from)) end
        if opts and opts.on_unsubscribe then pcall(opts.on_unsubscribe, tostring(from)) end
    end)

    unison.rpc.subscribe("ssh_input", function(msg)
        injectEvent(msg)
        dirty = true
    end)
end

-- Public: start the server loop (blocking). opts.on_subscribe /
-- opts.on_unsubscribe are optional callbacks.
function M.serve(opts)
    setupRpc(opts)
    serverRunning = true
    while serverRunning do
        for _, sub in ipairs(activeSubs()) do snapshotTo(sub) end
        if dirty then dirty = false; sleep(DIRTY_TICK) else sleep(IDLE_TICK) end
    end
end

function M.stop() serverRunning = false end

function M.subscribers() return subscribers end
function M.snapshot() return buffer and buffer.snapshot() end
function M.installed() return installed end

----------------------------------------------------------------------
-- Client side: connect to a remote ssh server, render frames into a
-- given term-target, forward keyboard.
----------------------------------------------------------------------

local CC_PALETTE_COLOR = {
    [0]  = colors.white,    [1]  = colors.orange,   [2]  = colors.magenta,
    [3]  = colors.lightBlue,[4]  = colors.yellow,   [5]  = colors.lime,
    [6]  = colors.pink,     [7]  = colors.gray,     [8]  = colors.lightGray,
    [9]  = colors.cyan,     [10] = colors.purple,   [11] = colors.blue,
    [12] = colors.brown,    [13] = colors.green,    [14] = colors.red,
    [15] = colors.black,
}
local function ccColor(idx) return CC_PALETTE_COLOR[(idx or 0) % 16] or colors.white end

-- Paint a frame (full or diff) onto a target term. State is the table
-- the caller carries between calls so partial renders converge.
function M.paint(target, msg, state)
    target = target or term.current()
    state = state or {}

    local function paintRow(y, row)
        if not row then return end
        local chars = row.chars or ""
        local fg    = row.fg or ""
        local bg    = row.bg or ""
        for x = 1, #chars do
            target.setCursorPos(x, y)
            target.setTextColor(ccColor(tonumber(fg:sub(x, x), 16)))
            target.setBackgroundColor(ccColor(tonumber(bg:sub(x, x), 16)))
            target.write(chars:sub(x, x))
        end
    end

    if msg.full and msg.frame then
        target.setBackgroundColor(colors.black)
        target.clear()
        for y = 1, msg.frame.h do paintRow(y, msg.frame.rows[y]) end
        if msg.frame.cursor then target.setCursorPos(msg.frame.cursor.x, msg.frame.cursor.y) end
        state.dims = { w = msg.frame.w, h = msg.frame.h }
    elseif msg.diff then
        for y, row in pairs(msg.rows or {}) do paintRow(tonumber(y) or y, row) end
        if msg.cursor then target.setCursorPos(msg.cursor.x, msg.cursor.y) end
        state.dims = { w = msg.w, h = msg.h }
    end

    return state
end

-- Open an interactive ssh client to <target>, redirected to the current
-- term. Subscribes, renders frames, forwards keyboard events. Returns
-- when the user presses Ctrl+] (the local "exit shell" key).
function M.connect(target, opts)
    opts = opts or {}
    local rpc = unison.rpc
    if not rpc then return false, "no rpc client" end

    local active = true
    local state = {}

    local function send(payload) return rpc.send(target, payload) end

    rpc.subscribe("ssh_frame", function(msg, env)
        local from = env and env.msg and env.msg.from
        if from and tostring(from) ~= tostring(target) then return end
        M.paint(term.current(), msg, state)
    end)

    send({ type = "ssh_subscribe", ttl = 60 })

    local renewTimer = os.startTimer(30)

    -- Forward keyboard input to remote.
    while active do
        local ev = { os.pullEvent() }
        local name = ev[1]
        if name == "char" then
            send({ type = "ssh_input", event = "char", value = ev[2] })
        elseif name == "key" then
            -- Ctrl+] (key 22? actually 27 escape doesn't suit) — use Esc as
            -- the local close shortcut for the CLI client; web clients
            -- already have their own button.
            if ev[2] == keys.escape then active = false; break end
            send({ type = "ssh_input", event = "key", value = ev[2], held = ev[3] })
        elseif name == "key_up" then
            send({ type = "ssh_input", event = "key_up", value = ev[2] })
        elseif name == "paste" then
            send({ type = "ssh_input", event = "paste", value = ev[2] })
        elseif name == "terminate" then
            send({ type = "ssh_input", event = "terminate" })
        elseif name == "timer" and ev[2] == renewTimer then
            send({ type = "ssh_subscribe", ttl = 60 })
            renewTimer = os.startTimer(30)
        end
    end

    send({ type = "ssh_unsubscribe" })
    if rpc.off then rpc.off("ssh_frame") end
    return true
end

return M
