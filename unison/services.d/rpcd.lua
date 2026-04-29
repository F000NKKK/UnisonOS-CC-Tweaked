return {
    name = "rpcd",
    description = "HTTP RPC daemon (registers with VPS, polls for messages)",
    enabled = true,
    roles = { "any" },
    deps = {},
    restart = "on-failure",
    restart_sec = 10,

    pre_start = function(cfg)
        local rpcd = dofile("/unison/services/rpcd.lua")
        unison.rpcd = rpcd
        rpcd.run()
    end,

    main = nil,
}
