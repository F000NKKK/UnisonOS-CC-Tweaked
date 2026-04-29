-- Shared path-resolution helper for shell commands. Avoids CC's fs.combine
-- because its handling of leading slashes is inconsistent across forks; we
-- normalise relative paths against ctx.cwd ourselves.

local M = {}

function M.resolve(ctx, raw)
    if not raw or raw == "" or raw == "~" then return ctx.cwd or "/" end
    local s = raw
    local cwd = ctx.cwd or "/"

    if s:sub(1, 1) ~= "/" then
        if cwd == "/" then
            s = "/" .. s
        else
            s = cwd .. "/" .. s
        end
    end

    -- collapse repeated slashes, resolve . and ..
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

return M
