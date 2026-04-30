local M = {
    desc = "Share or connect to a terminal over the Unison bus",
    usage = "ssh server | ssh <device-id> | ssh whoami",
}

function M.run(ctx, args)
    local ssh = unison and unison.lib and unison.lib.ssh
    if not ssh then
        printError("ssh: unison.lib.ssh missing")
        return
    end

    local mode = args[1]

    if mode == "server" or mode == "serve" or mode == "listen" then
        print("ssh: serving terminal — Q to stop.")
        local proc = unison.process.spawn(function() ssh.serve() end, "ssh-server",
            { priority = -5, group = "system" })
        while true do
            local ev, p = os.pullEvent()
            if ev == "char" and (p == "q" or p == "Q") then break end
            if ev == "key"  and p == keys.q then break end
        end
        ssh.stop()
        if proc and proc.wait then proc:wait(2) end
        print("ssh: server stopped.")
        return
    end

    if mode == "whoami" or mode == "subs" then
        local installed = ssh.installed and ssh.installed() or false
        print("ssh server installed: " .. tostring(installed))
        local snap = ssh.snapshot and ssh.snapshot()
        if snap then
            print(string.format("buffered terminal: %dx%d cursor=%d,%d",
                snap.w, snap.h, snap.cursor.x, snap.cursor.y))
        else
            print("(no buffer — sshd is not capturing this terminal)")
        end
        local subs = ssh.subscribers and ssh.subscribers() or {}
        local n = 0
        print("active subscribers:")
        for id in pairs(subs) do print("  " .. tostring(id)); n = n + 1 end
        if n == 0 then print("  (none)") end
        return
    end

    if mode and mode ~= "help" then
        print("ssh: connecting to " .. mode .. "  (Esc to leave)")
        sleep(0.3)
        local ok, err = ssh.connect(mode)
        if not ok then printError("ssh: " .. tostring(err)) end
        return
    end

    print("usage: " .. M.usage)
    print("  sshd runs by default; web console can connect anytime.")
end

return M
