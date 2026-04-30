-- unison.lib.semver — minimal semver compare (handles "0.7.6", "1.0.0").

local M = {}

function M.parse(v)
    local out = {}
    if type(v) ~= "string" then return { 0, 0, 0 } end
    for n in v:gmatch("(%d+)") do out[#out + 1] = tonumber(n) end
    while #out < 3 do out[#out + 1] = 0 end
    return out
end

-- Returns -1 / 0 / 1 like the C strcmp idiom.
function M.compare(a, b)
    local pa, pb = M.parse(a), M.parse(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x < y then return -1 elseif x > y then return 1 end
    end
    return 0
end

function M.gte(a, b) return M.compare(a, b) >= 0 end
function M.lte(a, b) return M.compare(a, b) <= 0 end
function M.gt(a, b)  return M.compare(a, b) >  0 end
function M.lt(a, b)  return M.compare(a, b) <  0 end
function M.eq(a, b)  return M.compare(a, b) == 0 end

return M
