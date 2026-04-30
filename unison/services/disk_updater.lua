-- Disk auto-updater: every CHECK_INTERVAL seconds scans for an attached
-- floppy labelled "UnisonOS-Installer" and refreshes its installer.lua,
-- manifest.json, and startup.lua from the configured pm sources.

local log     = dofile("/unison/kernel/log.lua")
local httpLib = dofile("/unison/lib/http.lua")
local fsLib   = dofile("/unison/lib/fs.lua")
local sources_mod = dofile("/unison/pm/sources.lua")

local M = {}

local DISK_LABEL = "UnisonOS-Installer"
local CHECK_INTERVAL = 60

local FILES = {
    { remote = "installer.lua",    on_disk = "installer.lua" },
    { remote = "manifest.json",    on_disk = "manifest.json" },
    { remote = "disk_startup.lua", on_disk = "startup.lua"   },
}

local function fetch(rel)
    return httpLib.getFromSources(sources_mod.list(), rel)
end

local function findDisks()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then
            local label = peripheral.call(name, "getDiskLabel")
            if label == DISK_LABEL then
                local mount = peripheral.call(name, "getMountPath")
                if mount then out[#out + 1] = { drive = name, root = "/" .. mount } end
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
        local current = fsLib.read(target)
        if current ~= body then
            if fsLib.write(target, body) then
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
        if ok then total = total + (changed or 0) end
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
