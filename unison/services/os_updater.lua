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
local BUSY_RECHECK   = 30           -- seconds to wait while a user app is running
local VERSION_FILE = "/unison/.version"
local STAGING_DIR  = "/unison.staging"
local PENDING_MARKER = "/unison/.pending-commit"

-- Returns a short label of what's keeping the device busy, or nil if idle.
-- Reboots & file replacement during long jobs (mining, farming, scanning) are
-- disruptive — we postpone updates until every user job releases its busy
-- token (markBusy/clearBusy in unison.process) or its scheduler proc exits.
local function busyReason()
    local proc = unison and unison.process
    if proc and proc.busyJobs then
        local jobs = proc.busyJobs()
        if jobs[1] then return jobs[1].name end
    end
    local sched = unison and unison.kernel and unison.kernel.scheduler
    if sched and sched.list then
        for _, p in ipairs(sched.list()) do
            if p.group == "user" then return p.name end
        end
    end
    return nil
end

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

function M.applyManifest(manifest, opts)
    opts = opts or {}
    if type(manifest) ~= "table" or not manifest.version then
        return false, "invalid manifest"
    end
    if not opts.force then
        local why = busyReason()
        if why then
            log.info("os-updater", "deferred — busy: " .. tostring(why))
            return false, "busy: " .. tostring(why)
        end
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
        -- Skip the network check entirely if the device is mid-job; the
        -- short BUSY_RECHECK cadence picks the update back up the moment
        -- the user process exits.
        local why = busyReason()
        if why then
            log.debug("os-updater", "idle — busy: " .. tostring(why))
            sleep(BUSY_RECHECK)
        else
            local ok, err = pcall(M.checkOnce)
            if not ok then log.warn("os-updater", "tick error: " .. tostring(err)) end
            sleep(CHECK_INTERVAL)
        end
    end
end

return M
