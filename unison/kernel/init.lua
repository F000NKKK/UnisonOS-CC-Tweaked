local M = {}

local scheduler = dofile("/unison/kernel/scheduler.lua")
local ipc = dofile("/unison/kernel/ipc.lua")
local log = dofile("/unison/kernel/log.lua")
local role = dofile("/unison/kernel/role.lua")

_G.unison = _G.unison or {}
unison.kernel = {
    scheduler = scheduler,
    ipc = ipc,
    log = log,
    role = role,
}

local function banner(nodeName, nodeRole, version)
    term.clear()
    term.setCursorPos(1, 1)
    if term.isColor and term.isColor() then term.setTextColor(colors.cyan) end
    print("UnisonOS " .. version)
    if term.isColor and term.isColor() then term.setTextColor(colors.lightGray) end
    print("  node: " .. nodeName)
    print("  role: " .. nodeRole)
    print("  id:   " .. tostring(os.getComputerID()))
    if term.setTextColor then term.setTextColor(colors.white) end
    print("")
end

function M.start(cfg)
    log.configure(cfg or {})
    local nodeRole = role.detect(cfg)
    local nodeName = role.nodeName(cfg)
    local version = (UNISON and UNISON.version) or "0.0.0"

    unison.role = nodeRole
    unison.node = nodeName
    unison.id = os.getComputerID()
    unison.config = cfg

    log.info("kernel", "boot " .. version .. " role=" .. nodeRole .. " name=" .. nodeName)
    banner(nodeName, nodeRole, version)

    local netd_ok, netd = pcall(dofile, "/unison/net/netd.lua")
    if netd_ok and netd then
        unison.netd = netd
        local started_ok, err = pcall(netd.start)
        if not started_ok then log.error("kernel", "netd failed: " .. tostring(err)) end
    else
        log.warn("kernel", "net stack not available: " .. tostring(netd))
    end

    local du_ok, du = pcall(dofile, "/unison/services/disk_updater.lua")
    if du_ok and du then
        scheduler.spawn(du.loop, "disk-updater")
    else
        log.warn("kernel", "disk-updater not available: " .. tostring(du))
    end

    scheduler.spawn(function()
        local shell_main = dofile("/unison/shell/shell.lua")
        shell_main()
    end, "shell")

    scheduler.run()
end

return M
