-- Factory reset: wipe apps, logs and runtime state but keep credentials and
-- user config so the device rejoins the network without manual rebootstrap.

local M = {
    desc = "Wipe apps/logs/state, keep config and auth tokens, then reboot",
    usage = "hardreset [--yes]",
}

-- Files inside /unison/state that survive a hardreset.
local STATE_KEEP = {
    ["api_token"] = true,    -- VPS bearer token
    ["node_key"]  = true,    -- HMAC key from enrollment (own)
    ["node_keys"] = true,    -- master-side known keys directory
}

-- Top-level paths under /unison/ to nuke entirely.
local PURGE_TREE = {
    "/unison/apps",
    "/unison/logs",
    "/unison.staging",       -- aborted update leftovers
}

-- Specific files under /unison/ to nuke (don't blow away the whole pm/ since
-- it ships modules; we just drop the installed-packages registry).
local PURGE_FILES = {
    "/unison/pm/installed.lua",
}

local function purgeStateExceptKept()
    if not fs.exists("/unison/state") then return 0 end
    local removed = 0
    for _, entry in ipairs(fs.list("/unison/state")) do
        if not STATE_KEEP[entry] then
            fs.delete("/unison/state/" .. entry)
            removed = removed + 1
        end
    end
    return removed
end

local function purgeTrees()
    local removed = 0
    for _, p in ipairs(PURGE_TREE) do
        if fs.exists(p) then fs.delete(p); removed = removed + 1 end
    end
    return removed
end

local function purgeFiles()
    local removed = 0
    for _, p in ipairs(PURGE_FILES) do
        if fs.exists(p) then fs.delete(p); removed = removed + 1 end
    end
    return removed
end

local function preview()
    print("hardreset will REMOVE:")
    for _, p in ipairs(PURGE_TREE) do print("  rm -rf " .. p) end
    for _, p in ipairs(PURGE_FILES) do print("  rm     " .. p) end
    print("  /unison/state/* (except api_token, node_key, node_keys/)")
    print("")
    print("It KEEPS:")
    print("  /unison/config.lua")
    print("  /unison/state/api_token (VPS auth)")
    print("  /unison/state/node_key  (HMAC identity)")
    print("  /unison/state/node_keys/ (master key store)")
    print("  /unison/.version, kernel/, net/, crypto/, services/, services.d/, shell/")
end

function M.run(ctx, args)
    local confirmed = false
    for _, a in ipairs(args) do
        if a == "--yes" or a == "-y" then confirmed = true end
    end

    preview()
    print("")

    if not confirmed then
        write("Type 'YES' to confirm hardreset: ")
        local line = read()
        if line ~= "YES" then
            print("aborted.")
            return
        end
    end

    print("")
    print("[hardreset] purging trees...")
    purgeTrees()
    print("[hardreset] purging files...")
    purgeFiles()
    print("[hardreset] cleaning /unison/state (preserving auth)...")
    local n = purgeStateExceptKept()
    print("[hardreset] removed " .. n .. " state entries.")
    print("")
    print("rebooting in 3s...")
    sleep(3)
    os.reboot()
end

return M
