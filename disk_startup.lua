-- /disk/startup.lua for the UnisonOS-Installer floppy.
-- Runs at every boot when this disk is in an attached drive.
-- Behavior:
--   1) If UnisonOS is not installed or its version differs from the disk's
--      manifest, run the installer and reboot.
--   2) Otherwise, do nothing — let the local /startup.lua boot UnisonOS.

local DISK_LABEL = "UnisonOS-Installer"

local function findDiskRoot()
    if fs.exists("/disk/installer.lua") then return "/disk" end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then
            local label = peripheral.call(name, "getDiskLabel")
            if label == DISK_LABEL then
                local mount = peripheral.call(name, "getMountPath")
                if mount and fs.exists("/" .. mount .. "/installer.lua") then
                    return "/" .. mount
                end
            end
        end
    end
    return nil
end

local DISK_ROOT = findDiskRoot()
if not DISK_ROOT then
    -- no installer on disk, fall through to local boot
    return
end

local function readFile(p)
    if not fs.exists(p) then return nil end
    local h = fs.open(p, "r")
    local s = h.readAll()
    h.close()
    return s
end

local function localVersion()
    return readFile("/unison/.version")
end

local function diskVersion()
    -- The disk holds a frozen manifest copy.  Read disk-side manifest if present;
    -- otherwise fall back to the embedded installer pinning.
    local raw = readFile(DISK_ROOT .. "/manifest.json")
    if not raw then return nil end
    local m = textutils.unserializeJSON(raw)
    if type(m) ~= "table" then return nil end
    return m.version
end

local installed = localVersion()
local available = diskVersion()

if installed and available and installed == available then
    print("[disk] UnisonOS " .. installed .. " already installed, skipping installer.")
    return
end

print("[disk] UnisonOS install/upgrade required.")
print("[disk]   installed: " .. tostring(installed))
print("[disk]   available: " .. tostring(available))
print("[disk] Running installer in 2s. Eject disk to cancel.")
sleep(2)

shell.run(DISK_ROOT .. "/installer.lua")
print("[disk] Install complete. Rebooting in 3s...")
sleep(3)
os.reboot()
