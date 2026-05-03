-- Read /unison/state/dispatcher-enabled.json so the `dispatcher enable`
-- shell command can toggle this without editing config.lua.
local STATE = "/unison/state/dispatcher-enabled.json"

local function stateEnabled()
    if not fs.exists(STATE) then return nil end
    local h = fs.open(STATE, "r"); if not h then return nil end
    local s = h.readAll(); h.close()
    local ok, t = pcall(textutils.unserializeJSON, s)
    if not ok or type(t) ~= "table" then return nil end
    return t.enabled and true or false
end

return {
    name = "dispatcher",
    description = "Mining-job dispatcher: matches queued selections to idle worker turtles",
    -- Opt-in: enabled via either config.lua (dispatcher = true) OR the
    -- runtime state file written by `dispatcher enable` shell command.
    -- The state file wins so a runtime toggle survives across reboots.
    enabled = true,
    roles = { "any" },
    deps = { "rpcd" },
    restart = "on-failure",
    restart_sec = 10,

    pre_start = function(cfg)
        local s = stateEnabled()
        local on
        if s ~= nil then on = s
        else on = (cfg and cfg.dispatcher) and true or false end
        if not on then return end
        local d = dofile("/unison/services/dispatcher.lua")
        unison.dispatcher = d
        d.start(cfg or {})
        if unison.kernel and unison.kernel.scheduler then
            local sch = unison.kernel.scheduler
            if d.tickLoop then sch.spawn(d.tickLoop, "dispatcher-tick", { group = "system" }) end
            if d.announceLoop then sch.spawn(d.announceLoop, "dispatcher-announce", { group = "system" }) end
        end
    end,

    main = nil,
}
