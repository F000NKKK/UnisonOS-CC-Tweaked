-- /disk/startup.lua for the UnisonOS-Installer floppy.
-- Logic is intentionally minimal:
--   * If UnisonOS is already installed (boot.lua present), boot it. Updates
--     are handled by the OS itself via os-updater, so the disk never needs
--     to upgrade.
--   * Otherwise run the installer from disk and reboot.

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

if fs.exists("/unison/boot.lua") then
    -- Already installed; let the local /startup.lua boot UnisonOS.
    print("[disk] UnisonOS already installed, booting...")
    if fs.exists("/startup.lua") then
        shell.run("/startup.lua")
    elseif fs.exists("/startup") then
        shell.run("/startup")
    else
        shell.run("/unison/boot.lua")
    end
    return
end

local DISK_ROOT = findDiskRoot()
if not DISK_ROOT then
    -- nothing to do — fall through to wherever the BIOS goes next
    return
end

print("[disk] UnisonOS is not installed on this device.")
print("[disk] Run installer from " .. DISK_ROOT .. "?  (yes / no)")
write("> ")
local answer = read()
if answer ~= "yes" and answer ~= "y" and answer ~= "YES" and answer ~= "Y" then
    print("[disk] aborted; falling through to local boot.")
    return
end

shell.run(DISK_ROOT .. "/installer.lua")
print("[disk] Install complete. Reboot now? (yes / no)")
write("> ")
local rb = read()
if rb == "yes" or rb == "y" or rb == "YES" or rb == "Y" then
    sleep(1)
    os.reboot()
end
