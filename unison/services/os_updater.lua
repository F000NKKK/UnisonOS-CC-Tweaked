-- OS self-updater: polls upstream manifest.json, and if its version differs
-- from /unison/.version, re-downloads every file listed for this device's
-- role and the common pool, then reboots.

local log = dofile("/unison/kernel/log.lua")
local role_lib = dofile("/unison/kernel/role.lua")

local M = {}

local CHECK_INTERVAL = 120
local RAW_BASE = "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master"
local MANIFEST_URL = RAW_BASE .. "/manifest.json"
local VERSION_FILE = "/unison/.version"

local function fetch(url)
    if not http then return nil, "http disabled" end
    local sep = url:find("?", 1, true) and "&" or "?"
    local bust = url .. sep .. "_=" .. tostring(os.epoch("utc"))
    local headers = {
        ["Cache-Control"] = "no-cache",
        ["Pragma"] = "no-cache",
    }
    local r, err = http.get(bust, headers)
    if not r then return nil, "http error: " .. tostring(err) end
    local code = r.getResponseCode and r.getResponseCode() or 200
    if code >= 400 then
        r.close()
        return nil, "http " .. code
    end
    local body = r.readAll()
    r.close()
    return body
end

local function readFile(p)
    if not fs.exists(p) then return nil end
    local h = fs.open(p, "r")
    local s = h.readAll()
    h.close()
    return s
end

local function writeFile(p, content)
    local dir = fs.getDir(p)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local h = fs.open(p, "w")
    if not h then return false end
    h.write(content)
    h.close()
    return true
end

local function currentVersion()
    return readFile(VERSION_FILE)
end

local function fetchManifest()
    local raw, err = fetch(MANIFEST_URL)
    if not raw then return nil, err end
    local m = textutils.unserializeJSON(raw)
    if type(m) ~= "table" then return nil, "bad manifest" end
    return m
end

local function downloadAll(manifest)
    local role = role_lib.detect(unison and unison.config or {})
    local files = {}
    for _, f in ipairs((manifest.roles and manifest.roles.common) or {}) do files[#files + 1] = f end
    for _, f in ipairs((manifest.roles and manifest.roles[role]) or {}) do files[#files + 1] = f end

    local failed = 0
    for i, rel in ipairs(files) do
        write(string.format("  [%2d/%2d] %s ... ", i, #files, rel))
        local body, err = fetch(RAW_BASE .. "/" .. rel)
        if body then
            if writeFile("/" .. rel, body) then
                print("ok")
            else
                print("write fail")
                failed = failed + 1
                log.warn("os-updater", "write failed: " .. rel)
            end
        else
            print("fail (" .. tostring(err) .. ")")
            failed = failed + 1
            log.warn("os-updater", "fetch failed: " .. rel .. " (" .. tostring(err) .. ")")
        end
    end
    return failed
end

function M.checkOnce(verbose)
    local function vprint(s) if verbose then print(s) end end
    vprint("manifest: " .. MANIFEST_URL)
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
        log.debug("os-updater", "up to date (" .. tostring(installed) .. ")")
        return false, "up to date"
    end
    log.info("os-updater", "update available: " .. tostring(installed) .. " -> " .. manifest.version)
    print("")
    print(">>> UnisonOS update " .. tostring(installed) .. " -> " .. manifest.version .. " <<<")

    local failed = downloadAll(manifest)
    if failed > 0 then
        log.warn("os-updater", failed .. " files failed; aborting reboot")
        return false, failed .. " files failed"
    end

    writeFile(VERSION_FILE, manifest.version)
    log.info("os-updater", "files updated, rebooting in 5s")
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
