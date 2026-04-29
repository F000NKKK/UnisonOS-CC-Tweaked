return {
    name = "netd",
    description = "Network daemon (signed rednet protocol)",
    enabled = true,
    roles = { "any" },
    deps = {},
    restart = "on-failure",
    restart_sec = 5,

    pre_start = function(cfg)
        local netd = dofile("/unison/net/netd.lua")
        unison.netd = netd
        netd.start()
    end,

    -- netd manages its own background loops via kernel.spawn inside start();
    -- there is no main loop to keep alive at the service level.
    main = nil,
}
