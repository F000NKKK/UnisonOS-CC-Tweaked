return {
    name = "mine",
    version = "3.0.0",
    description = "Sector miner: dispatcher integration (mine_assign RPC), home-aware return, worker_idle/busy reports",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "turtle", "fuel", "inventory", "rpc", "fs", "http" },
    min_platform = "0.26.0",
    entry = "main.lua",
    files = { "main.lua" },
}
