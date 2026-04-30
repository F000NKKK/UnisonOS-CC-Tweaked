-- unison.lib.kvstore — JSON-backed key/value storage for app state. Each
-- store maps to a file under /unison/state/<name>.json, so reset + reboot
-- preserves it (the upgrader's safe-paths list keeps /unison/state/).

local fsLib = dofile("/unison/lib/fs.lua")

local M = {}

local STATE_DIR = "/unison/state"

local Store = {}
Store.__index = Store

function Store:_path() return STATE_DIR .. "/" .. self._name .. ".json" end

function Store:reload()
    self._data = fsLib.readJson(self:_path()) or {}
end

function Store:save()
    fsLib.writeJson(self:_path(), self._data)
end

function Store:get(key, default)
    if key == nil then return self._data end
    local v = self._data[key]
    if v == nil then return default end
    return v
end

function Store:set(key, value)
    self._data[key] = value
    self:save()
    return value
end

function Store:update(key, fn, default)
    self._data[key] = fn(self._data[key] == nil and default or self._data[key])
    self:save()
    return self._data[key]
end

function Store:remove(key)
    self._data[key] = nil
    self:save()
end

function Store:keys()
    local out = {}
    for k in pairs(self._data) do out[#out + 1] = k end
    return out
end

function Store:size()
    local n = 0
    for _ in pairs(self._data) do n = n + 1 end
    return n
end

function Store:clear()
    self._data = {}
    self:save()
end

-- Build (or fetch a cached) store for the given name. The defaults table is
-- merged in if the file is empty / missing.
local cache = {}
function M.open(name, defaults)
    if cache[name] then return cache[name] end
    local s = setmetatable({ _name = name }, Store)
    s:reload()
    if defaults then
        for k, v in pairs(defaults) do
            if s._data[k] == nil then s._data[k] = v end
        end
        s:save()
    end
    cache[name] = s
    return s
end

return M
