local VERSION_FILE = "/unison/.version"
local VERSION_FALLBACK = "0.0.0"
local PENDING_MARKER = "/unison/.pending-commit"
local STAGING_DIR = "/unison.staging"

local function readFile(p)
    if not fs.exists(p) then return nil end
    local h = fs.open(p, "r")
    local s = h.readAll()
    h.close()
    return s
end

local function readVersion()
    local s = readFile(VERSION_FILE)
    if not s then return VERSION_FALLBACK end
    s = s:gsub("%s+$", "")
    if s == "" then return VERSION_FALLBACK end
    return s
end

-- ----------------------------------------------------------------------
-- Pending-update commit phase.
-- This block is intentionally self-contained: it does NOT call into any
-- /unison/* module, because those are exactly the files we are about to
-- replace. All it depends on is CC's own globals (fs, textutils, etc.).
-- ----------------------------------------------------------------------

local SAFE_PATHS = {
    ["/unison/config.lua"]       = true,
    [VERSION_FILE]               = true,
    ["/unison/pm/installed.lua"] = true,
    [PENDING_MARKER]             = true,
}
local SAFE_PREFIXES = {
    "/unison/state",
    "/unison/logs",
    "/unison/apps",
}

local function isSafePath(p)
    if SAFE_PATHS[p] then return true end
    for _, prefix in ipairs(SAFE_PREFIXES) do
        if p == prefix or p:sub(1, #prefix + 1) == prefix .. "/" then return true end
    end
    return false
end

local function detectRole()
    if turtle then return "turtle" end
    if pocket then return "pocket" end
    return "computer"
end

local function listAllUnder(dir, acc)
    if not fs.exists(dir) then return end
    for _, e in ipairs(fs.list(dir)) do
        local p = dir .. "/" .. e
        if fs.isDir(p) then listAllUnder(p, acc) else acc[#acc + 1] = p end
    end
end

local function applyPendingUpdate()
    if not fs.exists(PENDING_MARKER) then return end
    print("[boot] staged update detected, committing...")

    local stagingManifest = STAGING_DIR .. "/manifest.json"
    if not fs.exists(stagingManifest) then
        print("[boot] staging/manifest.json missing; aborting commit.")
        fs.delete(PENDING_MARKER)
        if fs.exists(STAGING_DIR) then fs.delete(STAGING_DIR) end
        return
    end

    local manifest = textutils.unserializeJSON(readFile(stagingManifest) or "")
    if type(manifest) ~= "table" or not manifest.version then
        print("[boot] bad staging manifest; aborting commit.")
        fs.delete(PENDING_MARKER)
        fs.delete(STAGING_DIR)
        return
    end

    local role = detectRole()
    local files = {}
    for _, f in ipairs(manifest.roles and manifest.roles.common or {}) do files[#files + 1] = f end
    for _, f in ipairs(manifest.roles and manifest.roles[role] or {}) do files[#files + 1] = f end

    -- delete obsolete files
    local keep = {}
    for _, rel in ipairs(files) do keep["/" .. rel] = true end

    local existing = {}
    listAllUnder("/unison", existing)
    local removed = 0
    for _, p in ipairs(existing) do
        if not isSafePath(p) and not keep[p] then
            fs.delete(p); removed = removed + 1
        end
    end
    print("[boot] removed " .. removed .. " obsolete file(s)")

    -- commit staged files
    local committed = 0
    for _, rel in ipairs(files) do
        local src = STAGING_DIR .. "/" .. rel
        local dst = "/" .. rel
        if fs.exists(src) then
            if fs.exists(dst) then fs.delete(dst) end
            local d = fs.getDir(dst)
            if d ~= "" and not fs.exists(d) then fs.makeDir(d) end
            fs.move(src, dst)
            committed = committed + 1
        end
    end
    print("[boot] committed " .. committed .. " file(s)")

    if fs.exists(STAGING_DIR) then fs.delete(STAGING_DIR) end

    local vh = fs.open(VERSION_FILE, "w")
    vh.write(manifest.version); vh.close()

    fs.delete(PENDING_MARKER)
    print("[boot] update to " .. manifest.version .. " applied. Rebooting in 2s.")
    sleep(2)
    os.reboot()
end

applyPendingUpdate()

-- ----------------------------------------------------------------------
-- Normal boot from here on.
-- ----------------------------------------------------------------------

local VERSION = readVersion()

-- One-shot v0.5.5 config reset migration; runs once per device.
local function maybeResetConfig()
    local marker = "/unison/state/.config_reset_v0_5_5"
    if fs.exists(marker) then return end
    if not fs.exists("/unison/config.lua.example") then return end
    if fs.exists("/unison/config.lua") then fs.delete("/unison/config.lua") end
    fs.copy("/unison/config.lua.example", "/unison/config.lua")
    if not fs.exists("/unison/state") then fs.makeDir("/unison/state") end
    local h = fs.open(marker, "w")
    h.write(tostring(os.epoch("utc")))
    h.close()
    print("[boot] config.lua reset to defaults (v0.5.5 migration)")
end

maybeResetConfig()

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
