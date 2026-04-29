local hmac = dofile("/unison/crypto/hmac.lua")
local protocol = dofile("/unison/net/protocol.lua")
local log = dofile("/unison/kernel/log.lua")

local M = {}

local STATE_DIR = "/unison/state"
local KEY_FILE = STATE_DIR .. "/node_key"
local NONCE_CACHE_FILE = STATE_DIR .. "/nonce_cache"
local KEYS_DIR = STATE_DIR .. "/node_keys"

local function ensureDir(p) if not fs.exists(p) then fs.makeDir(p) end end

function M.deriveNodeKey(masterSecret, nodeId)
    return hmac.bytes(masterSecret, "node:" .. tostring(nodeId))
end

function M.saveOwnKey(keyBytes)
    ensureDir(STATE_DIR)
    local h = fs.open(KEY_FILE, "wb")
    for i = 1, #keyBytes do h.write(keyBytes:byte(i)) end
    h.close()
end

function M.loadOwnKey()
    if not fs.exists(KEY_FILE) then return nil end
    local h = fs.open(KEY_FILE, "rb")
    local bytes = {}
    while true do
        local b = h.read()
        if not b then break end
        bytes[#bytes + 1] = string.char(b)
    end
    h.close()
    return table.concat(bytes)
end

function M.hasOwnKey() return fs.exists(KEY_FILE) end

function M.saveMasterKnownKey(nodeId, keyBytes)
    ensureDir(KEYS_DIR)
    local p = KEYS_DIR .. "/" .. tostring(nodeId)
    local h = fs.open(p, "wb")
    for i = 1, #keyBytes do h.write(keyBytes:byte(i)) end
    h.close()
end

function M.loadMasterKnownKey(nodeId)
    local p = KEYS_DIR .. "/" .. tostring(nodeId)
    if not fs.exists(p) then return nil end
    local h = fs.open(p, "rb")
    local bytes = {}
    while true do
        local b = h.read()
        if not b then break end
        bytes[#bytes + 1] = string.char(b)
    end
    h.close()
    return table.concat(bytes)
end

function M.sign(pkt, key)
    local canonical = protocol.canonical(pkt)
    pkt.sig = hmac.hex(key, canonical)
    return pkt
end

function M.verify(pkt, key)
    if not pkt.sig then return false, "no sig" end
    local canonical = protocol.canonical(pkt)
    local expected = hmac.hex(key, canonical)
    if expected ~= pkt.sig then return false, "bad sig" end
    return true
end

local nonceCache = {}
local nonceOrder = {}
local NONCE_LIMIT = 1000

local function loadNonceCache()
    if not fs.exists(NONCE_CACHE_FILE) then return end
    local h = fs.open(NONCE_CACHE_FILE, "r")
    local raw = h.readAll()
    h.close()
    local ok, t = pcall(textutils.unserialize, raw)
    if ok and type(t) == "table" then
        nonceCache = t.cache or {}
        nonceOrder = t.order or {}
    end
end

local function saveNonceCache()
    ensureDir(STATE_DIR)
    local h = fs.open(NONCE_CACHE_FILE, "w")
    h.write(textutils.serialize({ cache = nonceCache, order = nonceOrder }))
    h.close()
end

loadNonceCache()

function M.checkFreshness(pkt, windowSec)
    windowSec = windowSec or 60
    local now = os.epoch("utc")
    local diff = math.abs(now - (pkt.ts or 0)) / 1000
    if diff > windowSec then
        return false, "ts skew " .. math.floor(diff) .. "s"
    end
    local key = tostring(pkt.from) .. ":" .. tostring(pkt.nonce)
    if nonceCache[key] then return false, "replay" end
    nonceCache[key] = now
    nonceOrder[#nonceOrder + 1] = key
    if #nonceOrder > NONCE_LIMIT then
        local victim = table.remove(nonceOrder, 1)
        nonceCache[victim] = nil
    end
    if #nonceOrder % 16 == 0 then pcall(saveNonceCache) end
    return true
end

function M.signAndCheck(pkt, key, windowSec)
    local ok, err = M.verify(pkt, key)
    if not ok then return false, err end
    return M.checkFreshness(pkt, windowSec)
end

return M
