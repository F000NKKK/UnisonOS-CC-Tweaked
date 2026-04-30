return {
    name = "pilot",
    version = "1.0.0",
    description = "Remote control: type commands on a master, a turtle drives",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    permissions = { "rpc", "turtle", "fuel", "inventory" },
    -- needs unison.rpc.on (added in 0.5.10)
    min_platform = "0.5.10",
    entry = "main.lua",
    files = { "main.lua" },
}
