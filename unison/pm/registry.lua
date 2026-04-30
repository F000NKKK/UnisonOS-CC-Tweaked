-- Local registry of installed UPM packages. Persisted as a Lua return-table
-- at /unison/pm/installed.lua.

local fsLib = dofile("/unison/lib/fs.lua")

local M = {}

local STATE_FILE = "/unison/pm/installed.lua"

function M.load()
    return fsLib.readLua(STATE_FILE) or {}
end

function M.save(state)
    return fsLib.writeLua(STATE_FILE, state)
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
