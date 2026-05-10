-- UnisonOS thin agent.
--
-- Один процесс, один WebSocket, один цикл. Что делает:
--   1. Подключается к gateway по WS, шлёт {type="auth", id, world_id, role, ...}.
--   2. Принимает {id, type="call", path, args} → резолвит "turtle.forward" как
--      _G.turtle.forward, делает table.unpack(args) и pcall, отвечает
--      {id, type="result", values=[...]} либо {id, type="error", error=...}.
--   3. Принимает {id, type="eval", source} → loadstring + pcall.
--   4. Принимает {type="subscribe"/"unsubscribe", events=[...]} → меняет
--      фильтр и (если ещё не запущен) стартует параллельный поллер событий.
--   5. Резолвит спецпути: __readFile, __writeFile, __appendFile, __httpFetch,
--      __display.text/bar/chart/clear.
--
-- Зависимости: только CC globals (textutils, fs, http, parallel, peripheral),
-- никакого старого unison/lib. Это намеренно: после переходного релиза
-- большую часть unison/lib мы тоже сносим, но agent должен жить.

-- Защитная самоочистка: если на устройстве остались legacy-каталоги
-- (hijacker не доработал, миграция оборвалась посередине, etc.) —
-- сносим их при каждом старте агента. Дёшево: одни fs.exists.
do
    local legacy = {
        "apps","crypto","kernel","lib","logs","net","pm","rpc",
        "services","services.d","cron.d","shell","ui","state",
    }
    for _, name in ipairs(legacy) do
        local p = "/unison/" .. name
        if fs.exists(p) then pcall(fs.delete, p) end
    end
    for _, p in ipairs({
        "/unison.staging", "/unison/.version", "/unison/.pending-commit",
        "/unison/boot.lua", "/unison/config.lua", "/unison/config.lua.example",
    }) do
        if fs.exists(p) then pcall(fs.delete, p) end
    end
end

local display = dofile("/unison/agent/display.lua")

local CONFIG_PATH = "/unison/agent/config.lua"

local function loadConfig()
    if not fs.exists(CONFIG_PATH) then
        error("agent config missing: " .. CONFIG_PATH)
    end
    local fn, err = loadfile(CONFIG_PATH)
    if not fn then error("agent config load: " .. err) end
    local ok, c = pcall(fn)
    if not ok or type(c) ~= "table" then error("agent config invalid") end
    if not c.gateway_url then error("agent config: gateway_url required") end
    return c
end

local function detectRole()
    if turtle then return "turtle" end
    if pocket then return "pocket" end
    return "computer"
end

local function detectCapabilities()
    local caps = {}
    if turtle           then caps[#caps + 1] = "turtle"   end
    if redstone         then caps[#caps + 1] = "redstone" end
    if commands         then caps[#caps + 1] = "commands" end
    if peripheral       then caps[#caps + 1] = "peripheral" end
    if http.websocket   then caps[#caps + 1] = "websocket" end
    return caps
end

-- ---------------------------------------------------------------------------
-- Path resolution: "turtle.forward" → _G.turtle.forward.
-- Возвращает callable + строку "ok"/"missing".
-- ---------------------------------------------------------------------------

local function resolvePath(path)
    local cur = _ENV or _G
    for seg in string.gmatch(path, "[^.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[seg]
        if cur == nil then return nil end
    end
    return cur
end

-- ---------------------------------------------------------------------------
-- Special handlers (paths starting with "__" — gateway-defined helpers).
-- ---------------------------------------------------------------------------

local specials = {}

specials["__readFile"] = function(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local data = h.readAll()
    h.close()
    return data
end

specials["__writeFile"] = function(path, data)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local h, err = fs.open(path, "w")
    if not h then return false, err end
    h.write(data or "")
    h.close()
    return true
end

specials["__appendFile"] = function(path, data)
    local h, err = fs.open(path, "a")
    if not h then return false, err end
    h.write(data or "")
    h.close()
    return true
end

specials["__httpFetch"] = function(req)
    -- req: {url, method, body, headers, binary}
    if not http then return { ok = false, error = "http disabled" } end
    local url = req.url
    local method = (req.method or "GET"):upper()
    local body = req.body
    local headers = req.headers or {}
    local r, err
    if method == "GET" then
        r = http.get(url, headers)
        if not r then err = "request failed" end
    else
        r = http.post(url, body or "", headers)
        if not r then err = "request failed" end
    end
    if not r then return { ok = false, code = 0, body = "", headers = {}, error = err or "fail" } end
    local code = r.getResponseCode and r.getResponseCode() or 200
    local respHeaders = r.getResponseHeaders and r.getResponseHeaders() or {}
    local respBody = r.readAll() or ""
    r.close()
    return { ok = code < 400, code = code, body = respBody, headers = respHeaders }
end

for k, v in pairs(display.specials) do specials[k] = v end

-- ---------------------------------------------------------------------------
-- Dispatch one inbound message. Returns an outbound message table or nil.
-- ---------------------------------------------------------------------------

local function dispatch(msg)
    if msg.type == "call" then
        local path = msg.path or ""
        local args = msg.args or {}
        local fn = specials[path]
        if not fn then fn = resolvePath(path) end
        if type(fn) ~= "function" then
            return { id = msg.id, type = "error", error = "unknown path: " .. tostring(path) }
        end
        local ok, results = false, nil
        local function call() return { fn(table.unpack(args, 1, #args)) } end
        ok, results = pcall(call)
        if not ok then
            return { id = msg.id, type = "error", error = tostring(results) }
        end
        return { id = msg.id, type = "result", values = results }
    elseif msg.type == "eval" then
        local chunk, err = load(msg.source or "", "agent_eval", "t", _ENV)
        if not chunk then return { id = msg.id, type = "error", error = err } end
        local ok, results = pcall(function() return { chunk() } end)
        if not ok then return { id = msg.id, type = "error", error = tostring(results) } end
        return { id = msg.id, type = "result", values = results }
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Main loop with reconnect.
-- ---------------------------------------------------------------------------

local function runOnce(cfg)
    print("[agent] connecting " .. cfg.gateway_url)
    local headers = {}
    if cfg.token then headers["Authorization"] = "Bearer " .. cfg.token end
    local socket, openErr = http.websocket(cfg.gateway_url, headers)
    if not socket then
        print("[agent] connect failed: " .. tostring(openErr))
        return false
    end

    local id = cfg.device_id or tostring(os.getComputerID())
    local label = os.getComputerLabel() or ""

    socket.send(textutils.serialiseJSON({
        type = "auth",
        id = id,
        world_id = cfg.world_id or "default",
        token = cfg.token,
        role = detectRole(),
        label = label,
        version = cfg.version or "agent-0.1",
        capabilities = detectCapabilities(),
    }))

    local subscribed = false
    local filter = {}            -- set: event_name -> true; empty == all when subscribed

    local outbox = {}            -- array of pending outbound JSON strings

    local function enqueue(t)
        outbox[#outbox + 1] = textutils.serialiseJSON(t)
    end

    local function flush()
        while #outbox > 0 do
            local s = table.remove(outbox, 1)
            socket.send(s)
        end
    end

    local readerLive = true

    local function reader()
        while readerLive do
            local raw, isBinary
            local ok = pcall(function()
                raw, isBinary = socket.receive(15)
            end)
            if not ok then readerLive = false return end
            if raw == nil then
                -- timeout — отправим heartbeat для liveness
                enqueue({ type = "heartbeat", metrics = {} })
                flush()
            else
                local msg = textutils.unserialiseJSON(raw)
                if type(msg) == "table" then
                    if msg.type == "ready" then
                        -- handshake complete
                    elseif msg.type == "subscribe" then
                        subscribed = true
                        filter = {}
                        for _, e in ipairs(msg.events or {}) do filter[e] = true end
                    elseif msg.type == "unsubscribe" then
                        subscribed = false
                        filter = {}
                    elseif msg.type == "queue_event" then
                        os.queueEvent(msg.event, table.unpack(msg.args or {}))
                    elseif msg.type == "call" or msg.type == "eval" then
                        local out = dispatch(msg)
                        if out then enqueue(out) end
                        flush()
                    end
                end
            end
        end
    end

    local function eventPump()
        while readerLive do
            local ev = { os.pullEventRaw() }
            if subscribed then
                local name = ev[1]
                local pass = next(filter) == nil or filter[name]
                if pass then
                    local args = {}
                    for i = 2, #ev do args[#args + 1] = ev[i] end
                    enqueue({ type = "event", event = name, args = args, ts = os.epoch("utc") })
                    flush()
                end
            end
            if ev[1] == "terminate" then
                readerLive = false
            end
        end
    end

    local ok, err = pcall(parallel.waitForAny, reader, eventPump)
    pcall(function() socket.close() end)
    if not ok then
        print("[agent] loop error: " .. tostring(err))
    else
        print("[agent] disconnected, reconnecting...")
    end
    return true
end

local function main()
    local cfg = loadConfig()
    local backoff = 2
    while true do
        local ok = runOnce(cfg)
        sleep(ok and 1 or backoff)
        if not ok then
            backoff = math.min(backoff * 2, 60)
        else
            backoff = 2
        end
    end
end

main()
