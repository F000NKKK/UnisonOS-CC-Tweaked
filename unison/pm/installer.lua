-- UPM installer: fetches a package from configured sources and lays out
-- /unison/apps/<name>/<files>.

local sources = dofile("/unison/pm/sources.lua")
local registry = dofile("/unison/pm/registry.lua")
local role_lib = dofile("/unison/kernel/role.lua")
local log = dofile("/unison/kernel/log.lua")

local M = {}

local APPS_DIR = "/unison/apps"

local function ensureDir(p) if not fs.exists(p) then fs.makeDir(p) end end

local function writeFile(p, content)
    local d = fs.getDir(p)
    if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(p, "w")
    if not h then return false end
    h.write(content)
    h.close()
    return true
end

local function parseManifest(raw)
    local loader = load or loadstring
    local fn, err = loader(raw, "manifest", "t")
    if not fn then
        -- some Lua envs don't accept the mode argument
        fn, err = loader(raw, "manifest")
    end
    if not fn then return nil, err end
    local ok, t = pcall(fn)
    if not ok or type(t) ~= "table" then return nil, "manifest is not a table" end
    if not (t.name and t.version and t.entry and type(t.files) == "table") then
        return nil, "manifest missing required fields"
    end
    return t
end

function M.fetchRegistry()
    local raw, src = sources.fetchRegistry()
    if not raw then return nil, src end
    local ok, t = pcall(textutils.unserializeJSON, raw)
    if not ok or type(t) ~= "table" then return nil, "bad registry" end
    return t, src
end

function M.search(query)
    local reg, err = M.fetchRegistry()
    if not reg then return nil, err end
    local pkgs = reg.packages or {}
    if not query or query == "" then return pkgs end
    local out = {}
    local q = query:lower()
    for name, info in pairs(pkgs) do
        local hay = (name .. " " .. (info.description or "")):lower()
        if hay:find(q, 1, true) then out[name] = info end
    end
    return out
end

function M.info(name)
    local reg, err = M.fetchRegistry()
    if not reg then return nil, err end
    local entry = reg.packages and reg.packages[name]
    if not entry then return nil, "not in registry" end
    local manifestRaw, src = sources.fetchManifest(name, entry.latest)
    if not manifestRaw then return nil, src end
    local m, perr = parseManifest(manifestRaw)
    if not m then return nil, perr end
    return { registry = entry, manifest = m, source = src }
end

function M.install(name, version)
    local reg, err = M.fetchRegistry()
    if not reg then return false, "registry: " .. tostring(err) end
    local entry = reg.packages and reg.packages[name]
    if not entry then return false, "package '" .. name .. "' not in registry" end
    version = version or entry.latest
    local manifestRaw, src = sources.fetchManifest(name, version)
    if not manifestRaw then return false, "manifest: " .. tostring(src) end
    local m, perr = parseManifest(manifestRaw)
    if not m then return false, "manifest: " .. tostring(perr) end

    local role = role_lib.detect(unison and unison.config or {})
    if m.roles and #m.roles > 0 then
        local ok = false
        for _, r in ipairs(m.roles) do if r == role or r == "any" then ok = true end end
        if not ok then
            return false, "role '" .. role .. "' not supported by package (allowed: " ..
                table.concat(m.roles, ", ") .. ")"
        end
    end

    local target = APPS_DIR .. "/" .. name
    if fs.exists(target) then fs.delete(target) end
    ensureDir(APPS_DIR)
    ensureDir(target)

    local writeManifest = "return " .. textutils.serialize(m)
    if not writeFile(target .. "/manifest.lua", writeManifest) then
        return false, "failed writing manifest"
    end

    for _, file in ipairs(m.files) do
        local body, ferr = sources.fetchPackageFile(name, version, file)
        if not body then
            return false, "fetch " .. file .. ": " .. tostring(ferr)
        end
        if not writeFile(target .. "/" .. file, body) then
            return false, "write " .. file
        end
    end

    registry.put(name, {
        version = version,
        files = m.files,
        entry = m.entry,
        installed_at = os.epoch("utc"),
        source = src,
    })

    log.info("upm", "installed " .. name .. "@" .. version)
    return true, m
end

function M.remove(name)
    local entry = registry.get(name)
    if not entry then return false, "not installed" end
    local target = APPS_DIR .. "/" .. name
    if fs.exists(target) then fs.delete(target) end
    registry.remove(name)
    log.info("upm", "removed " .. name)
    return true
end

function M.update(name)
    local installed = registry.get(name)
    if not installed then return false, "not installed" end
    local reg, err = M.fetchRegistry()
    if not reg then return false, "registry: " .. tostring(err) end
    local entry = reg.packages and reg.packages[name]
    if not entry then return false, "no longer in registry" end
    if entry.latest == installed.version then return false, "up to date" end
    return M.install(name, entry.latest)
end

function M.updateAll()
    local results = {}
    for name in pairs(registry.load()) do
        local ok, info = M.update(name)
        results[name] = { ok = ok, info = info }
    end
    return results
end

return M
