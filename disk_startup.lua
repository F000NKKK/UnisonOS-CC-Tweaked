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

print("[disk] UnisonOS not installed. Running installer in 2s. Eject disk to cancel.")
sleep(2)
shell.run(DISK_ROOT .. "/installer.lua")
print("[disk] Install complete. Rebooting in 3s...")
sleep(3)
os.reboot()
