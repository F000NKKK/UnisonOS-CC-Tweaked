-- /disk/startup.lua для UnisonOS install floppy.
-- Если агент уже стоит — просто бутим. Если нет — запускаем installer.

local function diskRoot()
    if fs.exists("/disk/installer.lua") then return "/disk" end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then
            local mp = peripheral.call(name, "getMountPath")
            if mp and fs.exists("/" .. mp .. "/installer.lua") then
                return "/" .. mp
            end
        end
    end
    return nil
end

if fs.exists("/unison/agent/init.lua") then
    if fs.exists("/startup.lua") then
        shell.run("/startup.lua")
    else
        shell.run("/unison/agent/init.lua")
    end
    return
end

local root = diskRoot()
if not root then return end

print("[disk] UnisonOS не установлен. Запустить installer? (yes/no)")
write("> ")
local a = read()
if a == "yes" or a == "y" then
    shell.run(root .. "/installer.lua")
    sleep(1)
    os.reboot()
end
