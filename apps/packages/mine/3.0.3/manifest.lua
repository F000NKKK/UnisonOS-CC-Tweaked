return {
    name = "mine",
    version = "3.0.3",
    description = "Sector miner + worker daemon. Auto-home, slot blacklist, fuel-help courier protocol",
    min_platform = "0.27.0",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "turtle", "fuel", "inventory", "rpc", "fs", "http" },
    entry = "main.lua",
    files = { "main.lua" },
}
