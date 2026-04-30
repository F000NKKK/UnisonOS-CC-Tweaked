-- HTTP RPC client.
--
-- Talks to the UnisonOS message-bus API on the VPS:
--   POST /api/register                       (this device joins the bus)
--   POST /api/heartbeat                      (periodic, with metrics)
--   GET  /api/messages/<device>              (pull queued messages)
--   POST /api/messages/<device>              (send to another device)
--   POST /api/broadcast                      (send to everyone)
--   GET  /api/devices                        (list registered devices)
--
-- All calls go through one base URL — by default the first source from
-- /unison/pm/sources.lua. Token (if set on server) lives in
-- /unison/state/api_token.

local log = dofile("/unison/kernel/log.lua")
local sources = dofile("/unison/pm/sources.lua")

local M = {}

local STATE_DIR = "/unison/state"
local TOKEN_FILE = STATE_DIR .. "/api_token"

local function readFile(p)
    if not fs.exists(p) then return nil end
    local h = fs.open(p, "r")
    local s = h.readAll()
    h.close()
    return s
end

local function loadToken()
    local s = readFile(TOKEN_FILE)
    if not s then return nil end
    s = s:gsub("%s+$", "")
    if s == "" then return nil end
    return s
end

local function baseUrl()
    if unison and unison.config and unison.config.api_base then
        return unison.config.api_base
    end
    local list = sources.list()
    return list[1]
end

local function nodeId()
    return tostring(os.getComputerID())
end

local function buildHeaders()
    local h = {
        ["Content-Type"]  = "application/json",
        ["Cache-Control"] = "no-cache",
    }
    local token = loadToken()
    if token then h["Authorization"] = "Bearer " .. token end
    return h
end

local function decode(raw)
    if not raw then return nil end
    local ok, t = pcall(textutils.unserializeJSON, raw)
    if ok then return t end
    return nil
end

local function get(path)
    if not http then return nil, "http disabled" end
    local url = baseUrl() .. path
    local sep = url:find("?", 1, true) and "&" or "?"
    local bust = url .. sep .. "_=" .. tostring(os.epoch("utc"))
    local r, err = http.get(bust, buildHeaders())
    if not r then return nil, "http: " .. tostring(err) end
    local code = r.getResponseCode and r.getResponseCode() or 200
    local body = r.readAll()
    r.close()
    if code >= 400 then return nil, "http " .. code .. ": " .. body end
    return decode(body)
end

local function post(path, body)
    if not http then return nil, "http disabled" end
    local url = baseUrl() .. path
    local raw = textutils.serializeJSON(body or {})
    local r, err = http.post(url, raw, buildHeaders())
    if not r then return nil, "http: " .. tostring(err) end
    local code = r.getResponseCode and r.getResponseCode() or 200
    local resp = r.readAll()
    r.close()
    if code >= 400 then return nil, "http " .. code .. ": " .. resp end
    return decode(resp)
end

function M.setToken(token)
    if not fs.exists(STATE_DIR) then fs.makeDir(STATE_DIR) end
    local h = fs.open(TOKEN_FILE, "w")
    h.write(token or "")
    h.close()
end

function M.token() return loadToken() end

function M.register()
    return post("/api/register", {
        id = nodeId(),
        role = unison and unison.role,
        name = unison and unison.node,
        version = (UNISON and UNISON.version) or "?",
        registered_at = os.epoch("utc"),
    })
end

function M.heartbeat(metrics)
    return post("/api/heartbeat", {
        id = nodeId(),
        version = (UNISON and UNISON.version) or "?",
        metrics = metrics or {},
    })
end

function M.devices()
    return get("/api/devices")
end

function M.send(targetId, msg)
    return post("/api/messages/" .. tostring(targetId), msg)
end

function M.broadcast(msg)
    return post("/api/broadcast", msg)
end

function M.poll()
    return get("/api/messages/" .. nodeId())
end

-- ---- WebSocket transport -------------------------------------------------

local function wsBaseUrl()
    if unison and unison.config and unison.config.ws_url then
        return unison.config.ws_url
    end
    local b = baseUrl() or ""
    if b:sub(1, 7) == "https://" then return "wss://" .. b:sub(9):gsub(":(%d+)$", ":9276") end
    if b:sub(1, 7) == "http://"  then return "ws://"  .. b:sub(8):gsub(":(%d+)$", ":9275") end
    return "ws://" .. b
end

function M.wsConnect()
    if not http or not http.websocket then return nil, "no http.websocket" end
    local url = wsBaseUrl()
    local ws, err = http.websocket(url)
    if not ws then return nil, "ws connect: " .. tostring(err) end
    local hello = textutils.serializeJSON({
        type = "auth",
        id = nodeId(),
        token = loadToken(),
        role = unison and unison.role,
        name = unison and unison.node,
        version = (UNISON and UNISON.version) or "?",
    })
    ws.send(hello)
    -- Wait briefly for the 'ready' frame.
    local raw = ws.receive(5)
    if not raw then ws.close(); return nil, "ws auth timeout" end
    local resp = decode(raw)
    if not resp or resp.type ~= "ready" then
        ws.close()
        return nil, "ws auth failed: " .. tostring(raw)
    end
    return ws
end

local function safeSend(ws, payload)
    if not ws then return false, "no ws" end
    local ok, err = pcall(ws.send, payload)
    if not ok then return false, tostring(err) end
    return true
end

function M.wsSend(ws, target, msg)
    if not ws then return false end
    msg = msg or {}
    msg.from = msg.from or nodeId()
    return safeSend(ws, textutils.serializeJSON({
        type = "send", to = tostring(target), msg = msg,
    }))
end

function M.wsHeartbeat(ws, metrics)
    if not ws then return false end
    return safeSend(ws, textutils.serializeJSON({
        type = "heartbeat",
        metrics = metrics or {},
    }))
end

return M
