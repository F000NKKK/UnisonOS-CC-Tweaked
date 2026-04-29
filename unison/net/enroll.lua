local hmac = dofile("/unison/crypto/hmac.lua")
local auth = dofile("/unison/net/auth.lua")
local protocol = dofile("/unison/net/protocol.lua")
local log = dofile("/unison/kernel/log.lua")

local M = {}

local STATE_DIR = "/unison/state"
local PENDING_FILE = STATE_DIR .. "/enroll_pending.lua"
local CODE_FILE = STATE_DIR .. "/enroll_code"

local function ensureDir(p) if not fs.exists(p) then fs.makeDir(p) end end

local function readTable(path)
    if not fs.exists(path) then return {} end
    local h = fs.open(path, "r")
    local raw = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserialize, raw)
    return (ok and type(t) == "table") and t or {}
end

local function writeTable(path, t)
    ensureDir(STATE_DIR)
    local h = fs.open(path, "w")
    h.write(textutils.serialize(t))
    h.close()
end

local function genCode()
    local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    local out = {}
    for i = 1, 8 do
        local idx = math.random(1, #alphabet)
        out[i] = alphabet:sub(idx, idx)
    end
    return table.concat(out)
end

local function bootstrapKey(code)
    return hmac.bytes(code, "unison/enroll/bootstrap-v1")
end

local function bytesToHex(s)
    local out = {}
    for i = 1, #s do out[i] = string.format("%02x", s:byte(i)) end
    return table.concat(out)
end

local function hexToBytes(h)
    local out = {}
    for i = 1, #h, 2 do
        out[#out + 1] = string.char(tonumber(h:sub(i, i + 1), 16))
    end
    return table.concat(out)
end

function M.ensureNodeCode()
    ensureDir(STATE_DIR)
    if fs.exists(CODE_FILE) then
        local h = fs.open(CODE_FILE, "r")
        local code = h.readAll(); h.close()
        return code
    end
    local code = genCode()
    local h = fs.open(CODE_FILE, "w")
    h.write(code); h.close()
    return code
end

function M.clearNodeCode()
    if fs.exists(CODE_FILE) then fs.delete(CODE_FILE) end
end

function M.buildRequest(fromId, code, role)
    return protocol.new({
        from = fromId,
        to = "*",
        type = protocol.TYPES.ENROLL_REQ,
        payload = {
            code_hash = bytesToHex(hmac.bytes(code, "code-id")),
            role = role,
            computer_id = os.getComputerID(),
        },
    })
end

function M.masterAddPending(pkt)
    local pending = readTable(PENDING_FILE)
    pending[pkt.payload.code_hash] = {
        from = pkt.from,
        role = pkt.payload.role,
        computer_id = pkt.payload.computer_id,
        received_at = os.epoch("utc"),
    }
    writeTable(PENDING_FILE, pending)
end

function M.masterListPending()
    return readTable(PENDING_FILE)
end

function M.masterApprove(code, masterSecret)
    local pending = readTable(PENDING_FILE)
    local hash = bytesToHex(hmac.bytes(code, "code-id"))
    local entry = pending[hash]
    if not entry then return nil, "no pending request for this code" end

    local nodeKey = auth.deriveNodeKey(masterSecret, entry.from)
    auth.saveMasterKnownKey(entry.from, nodeKey)

    local bk = bootstrapKey(code)
    local nonce = protocol.nonce()
    local cipher = hmac.streamXor(bk, nonce, nodeKey)

    local pkt = protocol.new({
        from = "master",
        to = entry.from,
        type = protocol.TYPES.ENROLL_ACK,
        payload = {
            code_hash = hash,
            cipher = bytesToHex(cipher),
            stream_nonce = nonce,
        },
    })
    auth.sign(pkt, bk)

    pending[hash] = nil
    writeTable(PENDING_FILE, pending)

    return entry, pkt
end

function M.applyAck(pkt, code)
    local bk = bootstrapKey(code)
    local ok, err = auth.verify(pkt, bk)
    if not ok then return false, "ack signature invalid: " .. tostring(err) end

    local p = pkt.payload
    local hash = bytesToHex(hmac.bytes(code, "code-id"))
    if p.code_hash ~= hash then return false, "code hash mismatch" end

    local cipher = hexToBytes(p.cipher)
    local nodeKey = hmac.streamXor(bk, p.stream_nonce, cipher)

    auth.saveOwnKey(nodeKey)
    M.clearNodeCode()
    return true
end

return M
