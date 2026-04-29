-- UnisonOS installer
-- Usage on a fresh CC:Tweaked device:
--   pastebin run <ID>
-- Or directly:
--   wget run https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master/installer.lua

local SOURCES = {
    "http://upm.hush-vp.ru:9273",
    "https://raw.githubusercontent.com/F000NKKK/UnisonOS-CC-Tweaked/master",
}

local function fetchUrl(url)
    local sep = url:find("?", 1, true) and "&" or "?"
    local bust = url .. sep .. "_=" .. tostring(os.epoch("utc"))
    local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
    local r = http.get(bust, headers)
    if not r then return nil end
    local code = r.getResponseCode and r.getResponseCode() or 200
    if code >= 400 then r.close(); return nil end
    local body = r.readAll()
    r.close()
    return body
end

local function fetchRel(rel)
    for _, base in ipairs(SOURCES) do
        local body = fetchUrl(base .. "/" .. rel)
        if body then return body, base end
    end
    return nil
end

local function info(msg) print("[unison-install] " .. msg) end
local function err(msg) printError("[unison-install] " .. msg) end

if not http then
    err("HTTP API is disabled in the CC:Tweaked config. Enable http.enabled.")
    return
end

info("Fetching manifest...")
local raw, source = fetchRel("manifest.json")
if not raw then
    err("Failed to fetch manifest from any of: " .. table.concat(SOURCES, ", "))
    return
end
info("source: " .. source)

local ok, manifest = pcall(textutils.unserializeJSON, raw)
if not ok or type(manifest) ~= "table" then
    err("Manifest is not valid JSON")
    return
end

info("UnisonOS " .. tostring(manifest.version) .. " (phase " .. tostring(manifest.phase) .. ")")

local function detectRole()
    if turtle then return "turtle" end
    if pocket then return "pocket" end
    return "computer"
end

local role = detectRole()
info("Detected role: " .. role)

local files = {}
for _, f in ipairs(manifest.roles.common or {}) do files[#files + 1] = f end
for _, f in ipairs(manifest.roles[role] or {}) do files[#files + 1] = f end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function download(rel)
    local body = fetchRel(rel)
    if not body then return false, "all sources failed" end
    local target = "/" .. rel
    ensureDir(target)
    local h = fs.open(target, "w")
    if not h then return false, "fs.open failed" end
    h.write(body)
    h.close()
    return true
end

info("Downloading " .. #files .. " files...")
local failed = 0
for i, rel in ipairs(files) do
    write(string.format("  [%2d/%2d] %s ... ", i, #files, rel))
    local ok2, why = download(rel)
    if ok2 then
        print("OK")
    else
        print("FAIL (" .. tostring(why) .. ")")
        failed = failed + 1
    end
end

if failed > 0 then
    err(failed .. " files failed to download. Aborting.")
    return
end

if not fs.exists("/unison/config.lua") and fs.exists("/unison/config.lua.example") then
    fs.copy("/unison/config.lua.example", "/unison/config.lua")
    info("Created /unison/config.lua from template")
end

local startup = "/startup.lua"
local stub = 'shell.run("/unison/boot.lua")\n'
local h = fs.open(startup, "w")
h.write(stub)
h.close()
info("Wrote " .. startup)

info("Manifest version saved")
local mh = fs.open("/unison/.version", "w")
mh.write(manifest.version)
mh.close()

info("Install complete. Reboot to start UnisonOS (or run /unison/boot.lua).")
