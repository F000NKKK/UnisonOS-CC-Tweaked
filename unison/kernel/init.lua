local M = {}

local scheduler = dofile("/unison/kernel/scheduler.lua")
local ipc = dofile("/unison/kernel/ipc.lua")
local log = dofile("/unison/kernel/log.lua")
local role = dofile("/unison/kernel/role.lua")
local services = dofile("/unison/kernel/services.lua")
local process = dofile("/unison/kernel/process.lua")
local async = dofile("/unison/kernel/async.lua")

_G.unison = _G.unison or {}
unison.kernel = {
    scheduler = scheduler,
    ipc = ipc,
    log = log,
    role = role,
    services = services,
    process = process,
    async = async,
}
-- Top-level shortcuts mirror sandbox.appUnison() so kernel-side code can
-- use the same `unison.process` / `unison.async` form as apps.
unison.process = process
unison.async = async

-- Shared utility library. Exposed globally so kernel services and shell
-- commands can use it the same way sandboxed apps do (apps still get a
-- per-sandbox copy via kernel/sandbox.lua).
local ok_lib, lib = pcall(dofile, "/unison/lib/init.lua")
if ok_lib and type(lib) == "table" then
    unison.lib = lib
else
    log.warn("kernel", "lib/init.lua failed: " .. tostring(lib))
end

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
