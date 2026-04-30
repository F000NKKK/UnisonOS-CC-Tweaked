-- unison.lib.fmt — common formatting helpers shared by shell commands and
-- packages so we don't reimplement the same age / size / duration logic
-- in every TUI list view.

local M = {}

function M.age(epoch_ms)
    if not epoch_ms then return "-" end
    local s = math.floor((os.epoch("utc") - epoch_ms) / 1000)
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    if s < 86400 then return math.floor(s / 3600) .. "h" end
    return math.floor(s / 86400) .. "d"
end

function M.duration(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return string.format("%dm %ds", seconds / 60, seconds % 60) end
    if seconds < 86400 then return string.format("%dh %dm", seconds / 3600, (seconds % 3600) / 60) end
    return string.format("%dd %dh", seconds / 86400, (seconds % 86400) / 3600)
end

function M.bytes(n)
    if not n then return "-" end
    if n < 1024 then return n .. " B" end
    if n < 1024 * 1024 then return string.format("%.1f K", n / 1024) end
    if n < 1024 * 1024 * 1024 then return string.format("%.1f M", n / 1024 / 1024) end
    return string.format("%.2f G", n / 1024 / 1024 / 1024)
end

-- Strip a leading "minecraft:" namespace.
function M.shortItem(name)
    return (name or ""):gsub("^minecraft:", "")
end

-- Truncate / pad to exact width.
function M.fit(s, w, align)
    s = tostring(s or "")
    if #s > w then return s:sub(1, w) end
    if align == "right" then return string.rep(" ", w - #s) .. s end
    return s .. string.rep(" ", w - #s)
end

return M
