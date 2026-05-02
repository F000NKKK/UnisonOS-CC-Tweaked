return {
    name = "dispatcher",
    description = "Mining-job dispatcher: matches queued selections to idle worker turtles",
    -- Opt-in: only the master node has this enabled in /unison/config.lua
    -- (config.dispatcher = true). Other roles skip start.
    enabled = true,
    roles = { "any" },
    deps = { "rpcd" },
    restart = "on-failure",
    restart_sec = 10,

    pre_start = function(cfg)
        if not (cfg and cfg.dispatcher) then return end
        local d = dofile("/unison/services/dispatcher.lua")
        unison.dispatcher = d
        d.start(cfg)
        if unison.kernel and unison.kernel.scheduler then
            local sch = unison.kernel.scheduler
            if d.tickLoop then sch.spawn(d.tickLoop, "dispatcher-tick", { group = "system" }) end
            if d.announceLoop then sch.spawn(d.announceLoop, "dispatcher-announce", { group = "system" }) end
        end
    end,

    main = nil,
}
