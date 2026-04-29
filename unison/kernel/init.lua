local M = {}

local scheduler = dofile("/unison/kernel/scheduler.lua")
local ipc = dofile("/unison/kernel/ipc.lua")
local log = dofile("/unison/kernel/log.lua")
local role = dofile("/unison/kernel/role.lua")
local services = dofile("/unison/kernel/services.lua")

_G.unison = _G.unison or {}
unison.kernel = {
    scheduler = scheduler,
    ipc = ipc,
    log = log,
    role = role,
    services = services,
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

    local discovered = services.discover()
    log.info("kernel", "discovered " .. #discovered .. " unit(s)")

    -- Display unit must run pre_start before banner so output goes to all monitors.
    local order = services.startAll(cfg)
    log.info("kernel", "started services in order: " .. table.concat(order, ", "))

    banner(nodeName, nodeRole, version)

    scheduler.run()
end

return M
