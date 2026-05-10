-- UnisonOS thin-agent installer.
-- Usage:
--   pastebin run <ID>
--   wget run https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/installer.lua
--
-- Скачивает /unison/agent/* с указанного источника, прописывает /startup.lua
-- и подсказывает заполнить /unison/agent/config.lua.

local SOURCES = {
    "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
}

-- Файлы, которые тащим с источника (1:1 с layout репо).
local FILES = {
    "unison/agent/init.lua",
    "unison/agent/display.lua",
    "unison/agent/config.lua.example",
}

local function info(m) print("[install] " .. m) end
local function err(m)  printError("[install] " .. m) end

local function fetch(url)
    local sep = url:find("?", 1, true) and "&" or "?"
    local r = http.get(url .. sep .. "_=" .. os.epoch("utc"),
                       { ["Cache-Control"] = "no-cache" })
    if not r then return nil end
    local code = r.getResponseCode and r.getResponseCode() or 200
    if code >= 400 then r.close() return nil end
    local b = r.readAll()
    r.close()
    return b
end

local function fetchRel(rel)
    for _, base in ipairs(SOURCES) do
        local body = fetch(base .. "/" .. rel)
        if body then return body end
    end
    return nil
end

if not http then err("CC http API disabled — включи в config.") return end

for _, rel in ipairs(FILES) do
    info("downloading " .. rel)
    local body = fetchRel(rel)
    if not body then err("failed: " .. rel) return end
    local dst = "/" .. rel
    local dir = fs.getDir(dst)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    if fs.exists(dst) then fs.delete(dst) end
    local h = fs.open(dst, "w")
    h.write(body)
    h.close()
end

if not fs.exists("/unison/agent/config.lua") then
    fs.copy("/unison/agent/config.lua.example", "/unison/agent/config.lua")
    info("config: отредактируй /unison/agent/config.lua перед запуском")
end

if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
local h = fs.open("/startup.lua", "w")
h.write([[shell.run("/unison/agent/init.lua")]])
h.close()

info("done. Edit /unison/agent/config.lua, then reboot.")
