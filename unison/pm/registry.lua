-- Local registry of installed UPM packages.
-- Persisted at /unison/pm/installed.lua as a Lua table:
--   { mine = { version = "1.0.0", files = {...}, installed_at = ... } }

local M = {}

local PM_DIR = "/unison/pm"
local STATE_FILE = PM_DIR .. "/installed.lua"

local function ensureDir() if not fs.exists(PM_DIR) then fs.makeDir(PM_DIR) end end

function M.load()
    if not fs.exists(STATE_FILE) then return {} end
    local fn = loadfile(STATE_FILE)
    if not fn then return {} end
    local ok, t = pcall(fn)
    return (ok and type(t) == "table") and t or {}
end

function M.save(state)
    ensureDir()
    local h = fs.open(STATE_FILE, "w")
    h.write("return " .. textutils.serialize(state))
    h.close()
end

function M.get(name)
    return M.load()[name]
end

function M.put(name, entry)
    local s = M.load()
    s[name] = entry
    M.save(s)
end

function M.remove(name)
    local s = M.load()
    s[name] = nil
    M.save(s)
end

function M.all()
    return M.load()
end

return M
