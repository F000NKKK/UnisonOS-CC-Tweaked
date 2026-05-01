return {
    name = "mine",
    version = "2.3.2",
    description = "Sector miner: fixes early-bail row truncation after fuel refuel cycle",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "turtle", "fuel", "inventory", "rpc", "fs", "http" },
    min_platform = "0.16.0",
    entry = "main.lua",
    files = { "main.lua" },
}
