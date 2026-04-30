return {
    name = "pilot",
    version = "1.0.4",
    description = "Remote control: type commands on a master, a turtle drives",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    permissions = { "rpc", "turtle", "fuel", "inventory" },
    -- 0.8.0 introduced unison.lib (UniAPI) which the controller now uses
    -- to persist per-target command history.
    min_platform = "0.8.0",
    entry = "main.lua",
    files = { "main.lua" },
}
