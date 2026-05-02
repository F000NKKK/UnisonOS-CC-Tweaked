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
    -- Top-level shortcuts for the new I/O layer. stdio is the single
    -- text-output entry point; gdi is the graphics primitives package.
    -- Both end up writing through term.current(), which (post display
    -- start) is the display multiplex → Shadow → monitors.
    unison.stdio = lib.stdio
    unison.gdi   = lib.gdi
else
    log.warn("kernel", "lib/init.lua failed: " .. tostring(lib))
end

local function banner(nodeName, nodeRole, version)
    local io = unison.stdio
    if not io then
        -- Fallback for the (theoretical) case where lib failed to load.
        term.clear(); term.setCursorPos(1, 1)
        print("UnisonOS " .. version); return
    end
    io.clear()
    io.setColor(colors.cyan)
    io.print("UnisonOS " .. version)
    io.setColor(colors.lightGray)
    io.print("  node: " .. nodeName)
    io.print("  role: " .. nodeRole)
    io.print("  id:   " .. tostring(os.getComputerID()))
    io.setColor(colors.white)
    io.print("")
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
