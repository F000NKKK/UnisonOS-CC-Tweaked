-- ssh — terminal sharing app on top of unison.lib.ssh.
--
-- Usage:
--   ssh server                 start the server (listen for subscribers)
--   ssh <device-id>            connect to a remote device's terminal
--                              (Esc to disconnect locally)
--   ssh whoami                 show what's currently subscribed to us

local lib = unison.lib
local ssh = lib.ssh

local args = { ... }
local mode = args[1]

if mode == "server" or mode == "serve" or mode == "listen" then
    print("ssh: serving terminal — waiting for subscribers, Q to stop.")
    -- Run the server on a background process so we can also watch for Q.
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
    local subs = ssh.subscribers()
    local n = 0
    print("active ssh subscribers:")
    for id in pairs(subs) do print("  " .. id); n = n + 1 end
    if n == 0 then print("  (none — start with 'ssh server')") end
elseif mode and mode ~= "help" then
    -- Treat as a device id / name to connect to.
    print("ssh: connecting to " .. mode .. "  (Esc to leave)")
    sleep(0.3)
    local ok, err = ssh.connect(mode)
    if not ok then printError("ssh: " .. tostring(err)) end
else
    print("usage:")
    print("  ssh server         start sharing this terminal")
    print("  ssh <device>       connect to <device>'s terminal")
    print("  ssh whoami         list current subscribers")
end
