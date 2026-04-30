-- unison.lib.fs — small filesystem helpers used across the OS and exposed
-- to sandboxed apps. Pure wrappers over CC's fs module; no privileged side
-- effects beyond what `fs` already provides.

local M = {}

function M.read(path)
    if not fs.exists(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local s = h.readAll()
    h.close()
    return s
end

function M.write(path, content)
    local d = fs.getDir(path)
    if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(path, "w")
    if not h then return false end
    h.write(content)
    h.close()
    return true
end

function M.append(path, content)
    local d = fs.getDir(path)
    if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(path, "a")
    if not h then return false end
    h.write(content)
    h.close()
    return true
end

function M.ensureDir(path)
    if path and path ~= "" and not fs.exists(path) then fs.makeDir(path) end
end

function M.deleteIf(path)
    if fs.exists(path) then fs.delete(path) end
end

function M.list(dir)
    if not fs.exists(dir) or not fs.isDir(dir) then return {} end
    return fs.list(dir)
end

-- Recursive listing of every file (not directory) under prefix.
function M.listAll(prefix)
    local out = {}
    local function walk(dir)
        if not fs.exists(dir) then return end
        for _, entry in ipairs(fs.list(dir)) do
            local p = dir .. "/" .. entry
            if fs.isDir(p) then walk(p) else out[#out + 1] = p end
        end
    end
    walk(prefix)
    return out
end

function M.readJson(path)
    local raw = M.read(path)
    if not raw then return nil end
    local ok, t = pcall(textutils.unserializeJSON, raw)
    return ok and t or nil
end

function M.writeJson(path, data)
    return M.write(path, textutils.serializeJSON(data))
end

function M.readLua(path)
    if not fs.exists(path) then return nil end
    local fn = loadfile(path)
    if not fn then return nil end
    local ok, t = pcall(fn)
    return ok and t or nil
end

function M.writeLua(path, value)
    return M.write(path, "return " .. textutils.serialize(value))
end

return M
