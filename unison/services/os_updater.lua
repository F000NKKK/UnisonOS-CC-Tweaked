-- OS self-updater.
--
-- Algorithm (atomic):
--   1) fetch the upstream manifest
--   2) if installed == manifest.version: nothing to do
--   3) stream every file listed for this role+common into /unison.staging/
--   4) only after all downloads succeed:
--        - for each file in /unison that lives under a non-safe directory
--          and is NOT in the new manifest: delete (clears stale modules)
--        - for each staged file: replace the live copy
--        - bump /unison/.version
--        - drop the staging dir and reboot
--
-- Safe paths (never touched on upgrade): /unison/config.lua, /unison/.version,
-- /unison/state/, /unison/logs/, /unison/apps/, /unison/pm/installed.lua.

local log = dofile("/unison/kernel/log.lua")
local role_lib = dofile("/unison/kernel/role.lua")

local M = {}

local CHECK_INTERVAL = 120
local SOURCES = {
    "http://upm.hush-vp.ru:9273",
    "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
}
local VERSION_FILE = "/unison/.version"
local STAGING_DIR = "/unison.staging"

-- Files & directories the updater must NEVER overwrite or delete.
local SAFE_PATHS = {
    ["/unison/config.lua"]        = true,
    [VERSION_FILE]                = true,
    ["/unison/pm/installed.lua"]  = true,
}
local SAFE_PREFIXES = {
    "/unison/state",
    "/unison/logs",
    "/unison/apps",
}

local function isSafe(path)
    if SAFE_PATHS[path] then return true end
    for _, prefix in ipairs(SAFE_PREFIXES) do
        if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then
            return true
        end
    end
    return false
end

local function activeSources()
    if unison and unison.config and type(unison.config.pm_sources) == "table" then
        return unison.config.pm_sources
    end
    return SOURCES
end

local function fetchUrl(url)
    if not http then return nil, "http disabled" end
    local sep = url:find("?", 1, true) and "&" or "?"
    local bust = url .. sep .. "_=" .. tostring(os.epoch("utc"))
    local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
    local r, err = http.get(bust, headers)
    if not r then return nil, "http error: " .. tostring(err) end
    local code = r.getResponseCode and r.getResponseCode() or 200
    if code >= 400 then r.close(); return nil, "http " .. code end
    local body = r.readAll()
    r.close()
    return body
end

local function fetchRel(rel)
    local lastErr
    for _, base in ipairs(activeSources()) do
        local body, err = fetchUrl(base .. "/" .. rel)
        if body then return body, base end
        lastErr = err
        log.debug("os-updater", "src " .. base .. " failed for " .. rel .. ": " .. tostring(err))
    end
    return nil, lastErr or "all sources failed"
end

local function readFile(p)
    if not fs.exists(p) then return nil end
    local h = fs.open(p, "r")
    local s = h.readAll()
    h.close()
    return s
end

local function writeFile(p, content)
    local d = fs.getDir(p)
    if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
    local h = fs.open(p, "w")
    if not h then return false end
    h.write(content)
    h.close()
    return true
end

local function currentVersion() return readFile(VERSION_FILE) end

local function fetchManifest()
    local raw, srcOrErr = fetchRel("manifest.json")
    if not raw then return nil, srcOrErr end
    local m = textutils.unserializeJSON(raw)
    if type(m) ~= "table" then return nil, "bad manifest" end
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
    if fs.exists(STAGING_DIR) then fs.delete(STAGING_DIR) end
    fs.makeDir(STAGING_DIR)
    for i, rel in ipairs(files) do
        write(string.format("  [%2d/%2d] %s ... ", i, #files, rel))
        local body, err = fetchRel(rel)
        if not body then
            print("fail (" .. tostring(err) .. ")")
            return false, "fetch " .. rel .. ": " .. tostring(err)
        end
        local target = STAGING_DIR .. "/" .. rel
        if not writeFile(target, body) then
            print("write fail")
            return false, "write " .. target
        end
        print("ok")
    end
    return true
end

local function listAllUnder(prefix)
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

local function deleteObsolete(newFiles)
    local keep = {}
    for _, rel in ipairs(newFiles) do keep["/" .. rel] = true end

    for _, p in ipairs(listAllUnder("/unison")) do
        if not isSafe(p) and not keep[p] then
            log.info("os-updater", "removing obsolete " .. p)
            fs.delete(p)
        end
    end
end

local function commit(files)
    for _, rel in ipairs(files) do
        local src = STAGING_DIR .. "/" .. rel
        local dst = "/" .. rel
        if fs.exists(dst) then fs.delete(dst) end
        local d = fs.getDir(dst)
        if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
        fs.move(src, dst)
    end
    if fs.exists(STAGING_DIR) then fs.delete(STAGING_DIR) end
end

function M.checkOnce(verbose)
    local function vprint(s) if verbose then print(s) end end
    vprint("sources: " .. table.concat(activeSources(), ", "))

    local manifest, err = fetchManifest()
    if not manifest then
        log.debug("os-updater", "manifest fetch failed: " .. tostring(err))
        vprint("fetch failed: " .. tostring(err))
        return false, "fetch failed: " .. tostring(err)
    end

    local installed = currentVersion()
    vprint("installed: " .. tostring(installed))
    vprint("available: " .. tostring(manifest.version))

    if installed == manifest.version then
        return false, "up to date"
    end

    log.info("os-updater", "update " .. tostring(installed) .. " -> " .. manifest.version)
    print("")
    print(">>> UnisonOS update " .. tostring(installed) .. " -> " .. manifest.version .. " <<<")

    local files = manifestFiles(manifest)
    print("staging " .. #files .. " file(s)...")
    local ok, perr = stage(files)
    if not ok then
        log.warn("os-updater", "staging failed: " .. tostring(perr))
        if fs.exists(STAGING_DIR) then fs.delete(STAGING_DIR) end
        return false, perr
    end

    print("removing obsolete files...")
    deleteObsolete(files)

    print("committing staged files...")
    commit(files)

    writeFile(VERSION_FILE, manifest.version)
    log.info("os-updater", "applied " .. manifest.version)
    print(">>> Update applied, rebooting in 5s <<<")
    sleep(5)
    os.reboot()
    return true
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
