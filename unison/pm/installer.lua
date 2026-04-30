-- UPM installer: fetches a package from configured sources and lays out
-- /unison/apps/<name>/<files>.

local sources  = dofile("/unison/pm/sources.lua")
local registry = dofile("/unison/pm/registry.lua")
local role_lib = dofile("/unison/kernel/role.lua")
local log      = dofile("/unison/kernel/log.lua")
local fsLib    = dofile("/unison/lib/fs.lua")
local jsonLib  = dofile("/unison/lib/json.lua")
local semver   = dofile("/unison/lib/semver.lua")

local M = {}

local APPS_DIR = "/unison/apps"

local function parseManifest(raw)
    local loader = load or loadstring
    local fn, err = loader(raw, "manifest", "t")
    if not fn then fn, err = loader(raw, "manifest") end
    if not fn then return nil, err end
    local ok, t = pcall(fn)
    if not ok or type(t) ~= "table" then return nil, "manifest is not a table" end
    if not (t.name and t.version and t.entry and type(t.files) == "table") then
        return nil, "manifest missing required fields"
    end
    return t
end

local function platformVersion()
    return (UNISON and UNISON.version) or "0.0.0"
end

local function checkPlatformGate(m)
    if not m.min_platform then return true end
    if semver.gte(platformVersion(), m.min_platform) then return true end
    return false, string.format(
        "package requires UnisonOS >= %s (you have %s). Run 'upm upgrade' first.",
        m.min_platform, platformVersion())
end

function M.fetchRegistry()
    local raw, src = sources.fetchRegistry()
    if not raw then return nil, src end
    local t = jsonLib.decode(raw)
    if not t then return nil, "bad registry" end
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

local function installInternal(name, version, seen)
    seen = seen or {}
    if seen[name] then return true, "(already in dep set)" end
    seen[name] = true
    local reg, err = M.fetchRegistry()
    if not reg then return false, "registry: " .. tostring(err) end
    local entry = reg.packages and reg.packages[name]
    if not entry then return false, "package '" .. name .. "' not in registry" end
    version = version or entry.latest
    local manifestRaw, src = sources.fetchManifest(name, version)
    if not manifestRaw then return false, "manifest: " .. tostring(src) end
    local m, perr = parseManifest(manifestRaw)
    if not m then return false, "manifest: " .. tostring(perr) end

    -- Resolve declared dependencies first.
    if m.requires then
        for _, dep in ipairs(m.requires) do
            local depName, depVer = dep:match("^([^@]+)@(.+)$")
            if not depName then depName = dep end
            local already = registry.get(depName)
            if not already then
                log.info("upm", "installing dep " .. depName .. " (required by " .. name .. ")")
                local ok, derr = installInternal(depName, depVer, seen)
                if not ok then return false, "dep " .. depName .. ": " .. tostring(derr) end
            end
        end
    end

    local role = role_lib.detect(unison and unison.config or {})
    if m.roles and #m.roles > 0 then
        local ok = false
        for _, r in ipairs(m.roles) do if r == role or r == "any" then ok = true end end
        if not ok then
            return false, "role '" .. role .. "' not supported by package (allowed: " ..
                table.concat(m.roles, ", ") .. ")"
        end
    end

    local platOk, platErr = checkPlatformGate(m)
    if not platOk then return false, platErr end

    local target = APPS_DIR .. "/" .. name
    fsLib.deleteIf(target)
    fsLib.ensureDir(APPS_DIR)
    fsLib.ensureDir(target)

    if not fsLib.writeLua(target .. "/manifest.lua", m) then
        return false, "failed writing manifest"
    end

    for _, file in ipairs(m.files) do
        local body, ferr = sources.fetchPackageFile(name, version, file)
        if not body then return false, "fetch " .. file .. ": " .. tostring(ferr) end
        if not fsLib.write(target .. "/" .. file, body) then return false, "write " .. file end
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

function M.install(name, version)
    return installInternal(name, version, {})
end

-- Inspect every installed package's manifest and return the names that
-- require <name>. Used so `upm remove` can refuse to leave orphans.
function M.dependents(name)
    local out = {}
    for installedName, _ in pairs(registry.load()) do
        if installedName ~= name then
            local mf = APPS_DIR .. "/" .. installedName .. "/manifest.lua"
            local fn = loadfile(mf)
            if fn then
                local ok, m = pcall(fn)
                if ok and type(m) == "table" and m.requires then
                    for _, dep in ipairs(m.requires) do
                        local depName = dep:match("^([^@]+)") or dep
                        if depName == name then
                            out[#out + 1] = installedName; break
                        end
                    end
                end
            end
        end
    end
    return out
end

function M.remove(name, opts)
    opts = opts or {}
    local entry = registry.get(name)
    if not entry then return false, "not installed" end
    if not opts.force then
        local users = M.dependents(name)
        if #users > 0 then
            return false, "package required by: " .. table.concat(users, ", ") ..
                " (use force=true to remove anyway)"
        end
    end
    fsLib.deleteIf(APPS_DIR .. "/" .. name)
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
