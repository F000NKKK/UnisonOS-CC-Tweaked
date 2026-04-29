local M = {}

M.VERSION = 1

M.TYPES = {
    HELLO       = "HELLO",
    HELLO_ACK   = "HELLO_ACK",
    ENROLL_REQ  = "ENROLL_REQ",
    ENROLL_ACK  = "ENROLL_ACK",
    ACK         = "ACK",
    HEARTBEAT   = "HEARTBEAT",
    METRIC      = "METRIC",
    LOG         = "LOG",
    TASK        = "TASK",
    TASK_RESULT = "TASK_RESULT",
    RPC         = "RPC",
    RPC_REPLY   = "RPC_REPLY",
}

local function randomHex(n)
    local out = {}
    for i = 1, n do out[i] = string.format("%02x", math.random(0, 255)) end
    return table.concat(out)
end

function M.uuid()
    return randomHex(8) .. "-" .. randomHex(4) .. "-" .. randomHex(4) .. "-" .. randomHex(8)
end

function M.nonce()
    return randomHex(8)
end

function M.now()
    return os.epoch("utc")
end

local function sortedKeys(t)
    local k = {}
    for key in pairs(t) do k[#k + 1] = key end
    table.sort(k)
    return k
end

local function encodeValue(v)
    local t = type(v)
    if t == "nil" then return "n:" end
    if t == "boolean" then return v and "b:1" or "b:0" end
    if t == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return "i:" .. string.format("%d", v)
        end
        return "f:" .. tostring(v)
    end
    if t == "string" then return "s:" .. #v .. ":" .. v end
    if t == "table" then
        local parts = { "t:{" }
        for _, key in ipairs(sortedKeys(v)) do
            parts[#parts + 1] = encodeValue(key) .. "=" .. encodeValue(v[key]) .. ";"
        end
        parts[#parts + 1] = "}"
        return table.concat(parts)
    end
    error("cannot encode type " .. t)
end

function M.canonical(pkt)
    local copy = {}
    for k, v in pairs(pkt) do
        if k ~= "sig" then copy[k] = v end
    end
    return encodeValue(copy)
end

function M.new(opts)
    return {
        v     = M.VERSION,
        id    = opts.id or M.uuid(),
        from  = opts.from,
        to    = opts.to or "*",
        ts    = opts.ts or M.now(),
        nonce = opts.nonce or M.nonce(),
        type  = opts.type,
        payload = opts.payload or {},
    }
end

function M.encode(pkt)
    return textutils.serialize(pkt, { compact = true, allow_repetitions = false })
end

function M.decode(raw)
    if type(raw) ~= "string" then return nil end
    local ok, pkt = pcall(textutils.unserialize, raw)
    if not ok or type(pkt) ~= "table" then return nil end
    if pkt.v ~= M.VERSION then return nil end
    if not pkt.type or not pkt.from or not pkt.id then return nil end
    return pkt
end

return M
