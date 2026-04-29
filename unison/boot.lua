local VERSION_FILE = "/unison/.version"
local VERSION_FALLBACK = "0.0.0"

local function readVersion()
    if not fs.exists(VERSION_FILE) then return VERSION_FALLBACK end
    local h = fs.open(VERSION_FILE, "r")
    local s = h.readAll()
    h.close()
    s = (s or ""):gsub("%s+$", "")
    if s == "" then return VERSION_FALLBACK end
    return s
end

local VERSION = readVersion()

local function loadConfig()
    if not fs.exists("/unison/config.lua") then
        printError("[boot] /unison/config.lua not found. Copy config.lua.example.")
        return nil
    end
    local fn, e = loadfile("/unison/config.lua")
    if not fn then
        printError("[boot] config load error: " .. tostring(e))
        return nil
    end
    local ok, cfg = pcall(fn)
    if not ok or type(cfg) ~= "table" then
        printError("[boot] config returned invalid value")
        return nil
    end
    return cfg
end

local cfg = loadConfig()
if not cfg then return end

_G.UNISON = {
    version = VERSION,
    config = cfg,
    boot_time = os.epoch("utc"),
}

local kernel = dofile("/unison/kernel/init.lua")
kernel.start(cfg)
