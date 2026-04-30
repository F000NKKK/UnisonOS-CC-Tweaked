-- sshd — keep unison.lib.ssh serving in the background on every device.
-- Subscribers (e.g. the web console) can connect any time over the bus
-- without any manual `ssh server` step.

local M = {}

function M.run()
    local lib = unison and unison.lib
    if not (lib and lib.ssh) then
        local log = unison and unison.kernel and unison.kernel.log
        if log then log.warn("sshd", "lib.ssh missing — service idle") end
        while true do sleep(60) end
    end
    lib.ssh.serve()
end

return M
