local sha = dofile("/unison/crypto/sha256.lua")
local bxor = bit32.bxor

local BLOCK = sha.BLOCK_SIZE

local function xorPad(key, b)
    local out = {}
    for i = 1, BLOCK do
        out[i] = string.char(bxor(key:byte(i) or 0, b))
    end
    return table.concat(out)
end

local function normalizeKey(key)
    if #key > BLOCK then key = sha.bytes(key) end
    if #key < BLOCK then key = key .. string.rep("\0", BLOCK - #key) end
    return key
end

local M = {}

function M.bytes(key, msg)
    key = normalizeKey(key)
    local opad = xorPad(key, 0x5C)
    local ipad = xorPad(key, 0x36)
    return sha.bytes(opad .. sha.bytes(ipad .. msg))
end

function M.hex(key, msg)
    local raw = M.bytes(key, msg)
    local out = {}
    for i = 1, #raw do out[i] = string.format("%02x", raw:byte(i)) end
    return table.concat(out)
end

function M.streamXor(key, nonce, data)
    local out = {}
    local block = 0
    local stream = ""
    for i = 1, #data do
        if (i - 1) % sha.DIGEST_SIZE == 0 then
            stream = M.bytes(key, nonce .. ":" .. block)
            block = block + 1
        end
        local idx = ((i - 1) % sha.DIGEST_SIZE) + 1
        out[i] = string.char(bxor(data:byte(i), stream:byte(idx)))
    end
    return table.concat(out)
end

function M.equals(a, b)
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        if bxor(a:byte(i), b:byte(i)) ~= 0 then diff = diff + 1 end
    end
    return diff == 0
end

return M
