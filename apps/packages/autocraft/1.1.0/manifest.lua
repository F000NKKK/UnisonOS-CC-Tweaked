return {
    name = "autocraft",
    version = "1.1.0",
    description = "Recipe orchestrator on a crafty turtle; talks to storage/mine/farm",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "rpc", "turtle", "inventory", "fs", "term", "peripheral" },
    min_platform = "0.9.4",
    entry = "main.lua",
    files = { "main.lua" },
}
