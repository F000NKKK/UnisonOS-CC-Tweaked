-- Hijacker boot.lua — выжигает всё legacy в /unison/, оставляя только
-- /unison/agent/* + /startup.lua. Идемпотентен: если что-то пошло не
-- так, на следующем boot'е добьёт остатки. Самоудаляется только когда
-- /unison/ реально чист.

local function safeDel(p)
    if not fs.exists(p) then return true end
    local ok = pcall(fs.delete, p)
    return ok and not fs.exists(p)
end

-- 1. /startup.lua → агент.
do
    local want = [[shell.run("/unison/agent/init.lua")]]
    local ok, h = pcall(fs.open, "/startup.lua", "r")
    local cur = (ok and h) and h.readAll() or ""
    if h then h.close() end
    if cur ~= want then
        if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
        local w = fs.open("/startup.lua", "w")
        w.write(want); w.close()
    end
end

-- 2. Если своего конфига нет — копируем пример (в репо лежит уже с реальным URL).
if not fs.exists("/unison/agent/config.lua") and fs.exists("/unison/agent/config.lua.example") then
    fs.copy("/unison/agent/config.lua.example", "/unison/agent/config.lua")
end

-- 3. Сжигаем всё под /unison/, кроме agent/ и самого boot.lua.
local clean = true
if fs.exists("/unison") then
    for _, e in ipairs(fs.list("/unison")) do
        if e ~= "agent" and e ~= "boot.lua" then
            if not safeDel("/unison/" .. e) then clean = false end
        end
    end
end

-- 4. Хвосты вне /unison/.
for _, p in ipairs({"/unison.staging", "/unison/.version", "/unison/.pending-commit"}) do
    if not safeDel(p) then clean = false end
end

if not clean then
    print("[transition] partial cleanup; will retry on next boot")
    return
end

-- 5. Всё чисто — самоуничтожение и перезагрузка в новый мир.
print("[transition] hijacker done, rebooting in 2s")
fs.delete("/unison/boot.lua")
sleep(2)
os.reboot()
