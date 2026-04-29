-- Disk auto-updater: scans every N seconds for an attached disk drive holding
-- a floppy labelled "UnisonOS-Installer", refreshes its installer.lua,
-- manifest.json and startup.lua from the upstream raw URLs.

local log = dofile("/unison/kernel/log.lua")

local M = {}

local DISK_LABEL = "UnisonOS-Installer"
local CHECK_INTERVAL = 60
local SOURCES = {
    "http://upm.hush-vp.ru:9273",
    "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
}

local function activeSources()
    if unison and unison.config and type(unison.config.pm_sources) == "table" then
        return unison.config.pm_sources
    end
    return SOURCES
end

local FILES = {
    { remote = "installer.lua",    on_disk = "installer.lua" },
    { remote = "manifest.json",    on_disk = "manifest.json" },
    { remote = "disk_startup.lua", on_disk = "startup.lua"   },
}

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

local function fetch(rel)
    for _, base in ipairs(activeSources()) do
        local body, err = fetchUrl(base .. "/" .. rel)
        if body then return body end
        log.debug("disk-updater", "source " .. base .. " failed: " .. tostring(err))
    end
    return nil, "all sources failed"
end

local function readFile(p)
    if not fs.exists(p) then return nil end
    local h = fs.open(p, "r")
    local s = h.readAll()
    h.close()
    return s
end

local function writeFile(p, content)
    local h = fs.open(p, "w")
    if not h then return false end
    h.write(content)
    h.close()
    return true
end

local function findDisks()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then
            local label = peripheral.call(name, "getDiskLabel")
            if label == DISK_LABEL then
                local mount = peripheral.call(name, "getMountPath")
                if mount then
                    out[#out + 1] = { drive = name, root = "/" .. mount }
                end
            end
        end
    end
    return out
end

local function refreshDisk(disk)
    local changed = 0
    for _, f in ipairs(FILES) do
        local body, err = fetch(f.remote)
        if not body then
            log.warn("disk-updater", "fetch " .. f.remote .. " failed: " .. tostring(err))
            return false, err
        end
        local target = disk.root .. "/" .. f.on_disk
        local current = readFile(target)
        if current ~= body then
            if writeFile(target, body) then
                changed = changed + 1
                log.info("disk-updater", "updated " .. target)
            else
                log.warn("disk-updater", "write failed: " .. target)
            end
        end
    end
    return true, changed
end

function M.runOnce()
    local disks = findDisks()
    if #disks == 0 then return 0 end
    local total = 0
    for _, d in ipairs(disks) do
        local ok, changed = refreshDisk(d)
        if ok then total = total + changed end
    end
    return total
end

function M.loop()
    log.info("disk-updater", "started, label=" .. DISK_LABEL .. ", interval=" .. CHECK_INTERVAL .. "s")
    while true do
        local ok, err = pcall(M.runOnce)
        if not ok then log.warn("disk-updater", "tick error: " .. tostring(err)) end
        sleep(CHECK_INTERVAL)
    end
end

return M
