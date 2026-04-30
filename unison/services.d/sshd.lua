return {
    name = "sshd",
    description = "Always-on terminal share over the bus (lib.ssh.serve)",
    enabled = true,
    roles = { "any" },
    deps = { "rpcd" },
    restart = "always",
    restart_sec = 5,

    main = function(cfg)
        local svc = dofile("/unison/services/sshd.lua")
        unison.sshd = svc
        svc.run()
    end,
}
