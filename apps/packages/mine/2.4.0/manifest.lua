return {
    name = "mine",
    version = "2.4.0",
    description = "Sector miner with graceful 'mine abort' (return home and dump on signal)",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "turtle", "fuel", "inventory", "rpc", "fs", "http" },
    min_platform = "0.16.0",
    entry = "main.lua",
    files = { "main.lua" },
}
