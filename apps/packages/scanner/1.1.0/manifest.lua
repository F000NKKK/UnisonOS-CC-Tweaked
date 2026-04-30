return {
    name = "scanner",
    version = "1.1.0",
    description = "Turtle area scanner that populates atlas with discovered blocks",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    requires = { "atlas" },
    permissions = { "rpc", "turtle", "fuel", "fs", "gps", "term" },
    min_platform = "0.9.4",
    entry = "main.lua",
    files = { "main.lua" },
}
