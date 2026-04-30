-- unison.lib.path — cwd-aware path resolver. Avoids CC's fs.combine because
-- its handling of leading slashes is inconsistent across forks.

local M = {}

function M.resolve(ctx, raw)
    local cwd = (ctx and ctx.cwd) or "/"
    if not raw or raw == "" or raw == "~" then return cwd end
    local s = raw

    if s:sub(1, 1) ~= "/" then
        if cwd == "/" then s = "/" .. s
        else s = cwd .. "/" .. s end
    end

    local parts = {}
    for seg in s:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    if #parts == 0 then return "/" end
    return "/" .. table.concat(parts, "/")
end

-- Convenience: resolve when ctx is nil → treat as / cwd.
function M.absolute(raw)
    return M.resolve(nil, raw)
end

return M
