-- unison.lib.json — safe wrapper around textutils JSON helpers.

local M = {}

function M.encode(value)
    return textutils.serializeJSON(value)
end

function M.decode(s)
    if type(s) ~= "string" or s == "" then return nil end
    local ok, t = pcall(textutils.unserializeJSON, s)
    if not ok then return nil end
    return t
end

return M
