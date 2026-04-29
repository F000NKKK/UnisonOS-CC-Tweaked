local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lshift, rshift = bit32.lshift, bit32.rshift
local rrotate = bit32.rrotate

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function preprocess(msg)
    local len = #msg
    local bits = len * 8
    local padded = msg .. "\128"
    local target = (len + 1) % 64
    local pad
    if target <= 56 then pad = 56 - target else pad = 120 - target end
    padded = padded .. string.rep("\0", pad)
    local hi = math.floor(bits / 0x100000000)
    local lo = bits % 0x100000000
    padded = padded .. string.char(
        band(rshift(hi, 24), 0xFF), band(rshift(hi, 16), 0xFF),
        band(rshift(hi,  8), 0xFF), band(hi, 0xFF),
        band(rshift(lo, 24), 0xFF), band(rshift(lo, 16), 0xFF),
        band(rshift(lo,  8), 0xFF), band(lo, 0xFF))
    return padded
end

local function readU32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return lshift(b1, 24) + lshift(b2, 16) + lshift(b3, 8) + b4
end

local function digest(msg)
    msg = preprocess(msg)

    local H = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }
    local W = {}

    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            W[i + 1] = readU32(msg, chunk + i * 4)
        end
        for i = 17, 64 do
            local w15 = W[i - 15]
            local w2  = W[i - 2]
            local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
            local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
            W[i] = band(W[i - 16] + s0 + W[i - 7] + s1, 0xFFFFFFFF)
        end

        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

        for i = 1, 64 do
            local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = band(h + S1 + ch + K[i] + W[i], 0xFFFFFFFF)
            local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local mj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = band(S0 + mj, 0xFFFFFFFF)
            h = g
            g = f
            f = e
            e = band(d + t1, 0xFFFFFFFF)
            d = c
            c = b
            b = a
            a = band(t1 + t2, 0xFFFFFFFF)
        end

        H[1] = band(H[1] + a, 0xFFFFFFFF)
        H[2] = band(H[2] + b, 0xFFFFFFFF)
        H[3] = band(H[3] + c, 0xFFFFFFFF)
        H[4] = band(H[4] + d, 0xFFFFFFFF)
        H[5] = band(H[5] + e, 0xFFFFFFFF)
        H[6] = band(H[6] + f, 0xFFFFFFFF)
        H[7] = band(H[7] + g, 0xFFFFFFFF)
        H[8] = band(H[8] + h, 0xFFFFFFFF)
    end

    return H
end

local function toHex(H)
    return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
        H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8])
end

local function toBytes(H)
    local out = {}
    for i = 1, 8 do
        local v = H[i]
        out[#out + 1] = string.char(
            band(rshift(v, 24), 0xFF),
            band(rshift(v, 16), 0xFF),
            band(rshift(v,  8), 0xFF),
            band(v, 0xFF))
    end
    return table.concat(out)
end

return {
    hex = function(msg) return toHex(digest(msg)) end,
    bytes = function(msg) return toBytes(digest(msg)) end,
    BLOCK_SIZE = 64,
    DIGEST_SIZE = 32,
}
