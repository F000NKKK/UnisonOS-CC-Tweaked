-- ssh — terminal sharing CLI on top of unison.lib.ssh.
--
-- Usage:
--   ssh server                 start sharing this terminal locally
--   ssh <device-id>            connect to a remote device's terminal
--   ssh whoami                 show subscribers currently watching us
--
-- The sshd service keeps a server running on every device by default,
-- so 'ssh server' is mostly redundant — but kept for ad-hoc setups.
-- Transport is the regular Unison bus (HTTP/WebSocket), so this works
-- through firewalls that block port 22.

local ssh = unison and unison.lib and unison.lib.ssh
if not ssh then
    printError("ssh: unison.lib.ssh missing — OS upgrade required (>= 0.10.3).")
    return
end

local args = { ... }
local mode = args[1]

if mode == "server" or mode == "serve" or mode == "listen" then
    print("ssh: serving terminal — waiting for subscribers, Q to stop.")
    local proc = unison.process.spawn(function() ssh.serve() end, "ssh-server",
        { priority = -5, group = "system" })
    while true do
        local ev, p = os.pullEvent()
        if ev == "char" and (p == "q" or p == "Q") then break end
        if ev == "key"  and p == keys.q then break end
    end
    ssh.stop()
    proc:wait(2)
    print("ssh: server stopped.")
elseif mode == "whoami" or mode == "subs" then
    local subs = ssh.subscribers and ssh.subscribers() or {}
    local n = 0
    print("active ssh subscribers:")
    for id in pairs(subs) do print("  " .. tostring(id)); n = n + 1 end
    if n == 0 then print("  (none — sshd runs by default; nobody is watching)") end
elseif mode and mode ~= "help" then
    print("ssh: connecting to " .. mode .. "  (Esc to leave)")
    sleep(0.3)
    local ok, err = ssh.connect(mode)
    if not ok then printError("ssh: " .. tostring(err)) end
else
    print("usage:")
    print("  ssh server         start sharing this terminal manually")
    print("  ssh <device>       connect to <device>'s terminal")
    print("  ssh whoami         list current subscribers")
    print("(sshd is enabled by default; web console can connect anytime.)")
end
