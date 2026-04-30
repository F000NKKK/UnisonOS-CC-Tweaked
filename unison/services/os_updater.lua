-- OS self-updater (two-phase). Stages files into /unison.staging/ and
-- writes /unison/.pending-commit; the actual file replacement runs in
-- boot.lua before any /unison module is loaded.

local log      = dofile("/unison/kernel/log.lua")
local role_lib = dofile("/unison/kernel/role.lua")
local httpLib  = dofile("/unison/lib/http.lua")
local fsLib    = dofile("/unison/lib/fs.lua")
local jsonLib  = dofile("/unison/lib/json.lua")
local sources_mod = dofile("/unison/pm/sources.lua")

local M = {}

local CHECK_INTERVAL = 120
local VERSION_FILE = "/unison/.version"
local STAGING_DIR  = "/unison.staging"
local PENDING_MARKER = "/unison/.pending-commit"

local function fetchRel(rel)
    return httpLib.getFromSources(sources_mod.list(), rel)
end

local function fetchManifest()
    local raw, srcOrErr = fetchRel("manifest.json")
    if not raw then return nil, srcOrErr end
    local m = jsonLib.decode(raw)
    if not m then return nil, "bad manifest" end
    m._source = srcOrErr
    return m
end

local function manifestFiles(manifest)
    local role = role_lib.detect(unison and unison.config or {})
    local out = {}
    for _, f in ipairs((manifest.roles and manifest.roles.common) or {}) do out[#out + 1] = f end
    for _, f in ipairs((manifest.roles and manifest.roles[role]) or {}) do out[#out + 1] = f end
    return out
end

local function stage(files)
    fsLib.deleteIf(STAGING_DIR)
    fs.makeDir(STAGING_DIR)
    for i, rel in ipairs(files) do
        write(string.format("  [%2d/%2d] %s ... ", i, #files, rel))
        local body, err = fetchRel(rel)
        if not body then
            print("fail (" .. tostring(err) .. ")")
            return false, "fetch " .. rel .. ": " .. tostring(err)
        end
        if not fsLib.write(STAGING_DIR .. "/" .. rel, body) then
            print("write fail")
            return false, "write " .. STAGING_DIR .. "/" .. rel
        end
        print("ok")
    end
    return true
end

M.peekManifest = fetchManifest
M.currentVersion = function() return fsLib.read(VERSION_FILE) end

function M.applyManifest(manifest)
    if type(manifest) ~= "table" or not manifest.version then
        return false, "invalid manifest"
    end
    log.info("os-updater", "staging " .. tostring(manifest.version))
    print("")
    print(">>> UnisonOS upgrade -> " .. manifest.version .. " <<<")

    local files = manifestFiles(manifest)
    print("staging " .. #files .. " file(s)...")
    local ok, perr = stage(files)
    if not ok then
        log.warn("os-updater", "staging failed: " .. tostring(perr))
        fsLib.deleteIf(STAGING_DIR)
        return false, perr
    end

    fsLib.write(STAGING_DIR .. "/manifest.json", jsonLib.encode(manifest))
    fsLib.write(PENDING_MARKER, manifest.version)

    log.info("os-updater", "staged; rebooting to commit")
    print(">>> Update staged. Rebooting in 5s to apply <<<")
    sleep(5)
    os.reboot()
    return true
end

function M.checkOnce(verbose)
    local function vprint(s) if verbose then print(s) end end
    vprint("sources: " .. table.concat(sources_mod.list(), ", "))

    local manifest, err = fetchManifest()
    if not manifest then
        log.debug("os-updater", "manifest fetch failed: " .. tostring(err))
        vprint("fetch failed: " .. tostring(err))
        return false, "fetch failed: " .. tostring(err)
    end

    local installed = M.currentVersion()
    vprint("installed: " .. tostring(installed))
    vprint("available: " .. tostring(manifest.version))

    if installed == manifest.version then return false, "up to date" end
    return M.applyManifest(manifest)
end

function M.loop()
    if not (unison.config and unison.config.auto_update) then
        log.info("os-updater", "auto_update disabled in config; idle")
        return
    end
    log.info("os-updater", "started, interval=" .. CHECK_INTERVAL .. "s")
    while true do
        local ok, err = pcall(M.checkOnce)
        if not ok then log.warn("os-updater", "tick error: " .. tostring(err)) end
        sleep(CHECK_INTERVAL)
    end
end

return M
