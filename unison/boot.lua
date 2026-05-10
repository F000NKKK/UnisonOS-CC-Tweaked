-- TRANSITIONAL hijacker boot.lua.
--
-- Запускается ОДИН раз — после того как старый upm применил staged-update,
-- который вычистил всю предыдущую систему (apps/, pm/, services.d/, kernel/,
-- lib/) и оставил только /unison/agent/* + этот файл.
--
-- Задачи:
--   1. Прописать /startup.lua, чтобы дальше грузился агент напрямую.
--   2. Скопировать пример конфига, если своего ещё нет.
--   3. Удалить себя и остатки переходного слоя — после следующей загрузки
--      этот boot.lua больше не понадобится.
--   4. Перезагрузиться.
--
-- После успеха устройство больше никогда не дёрнет старый upm (нет ни
-- pm/, ни os-updater сервиса), а будет обновляться только командами из
-- gateway (Fs.WriteFile + Os.Reboot или Eval).

local function info(m) print("[transition] " .. m) end

-- 1. /startup.lua — единая точка входа.
do
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    local h = fs.open("/startup.lua", "w")
    h.write([[shell.run("/unison/agent/init.lua")]])
    h.close()
    info("/startup.lua → agent")
end

-- 2. Базовый конфиг агента, если ещё нет своего.
if not fs.exists("/unison/agent/config.lua") then
    if fs.exists("/unison/agent/config.lua.example") then
        fs.copy("/unison/agent/config.lua.example", "/unison/agent/config.lua")
    end
    info("config: отредактируй /unison/agent/config.lua перед next reboot")
end

-- 3. Подчищаем за собой: остатки старой системы, на всякий случай.
local STALE = {
    "/unison/.version",
    "/unison/.pending-commit",
    "/unison/config.lua.example",
    "/unison/state",
    "/unison/logs",
    "/unison/apps",
    "/unison/pm",
    "/unison/lib",
    "/unison/kernel",
    "/unison/crypto",
    "/unison/ui",
    "/unison/services",
    "/unison/services.d",
    "/unison/cron.d",
    "/unison/shell",
    "/unison/rpc",
    "/unison/net",
    "/unison.staging",
}
for _, p in ipairs(STALE) do
    if fs.exists(p) then fs.delete(p) end
end

-- 4. Удаляем самого hijacker'а — больше не нужен.
fs.delete("/unison/boot.lua")
info("hijack done. Rebooting in 2s.")
sleep(2)
os.reboot()
