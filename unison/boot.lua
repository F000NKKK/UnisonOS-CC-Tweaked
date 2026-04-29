local VERSION = "0.2.5"

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
