return {
    name = "autocraft",
    version = "1.2.0",
    description = "Recipe orchestrator on a crafty turtle; markBusy on craft_order so OS upgrades defer",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = {},
    permissions = { "rpc", "turtle", "inventory", "fs", "term", "peripheral" },
    min_platform = "0.9.4",
    entry = "main.lua",
    files = { "main.lua" },
}
