return {
    name = "mine",
    version = "3.0.2",
    description = "Sector miner: dispatcher worker daemon with GPS auto-parking and broadcast discovery",
    min_platform = "0.27.0",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "turtle", "fuel", "inventory", "rpc", "fs", "http" },
    entry = "main.lua",
    files = { "main.lua" },
}
