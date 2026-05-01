return {
    name = "pilot",
    version = "1.2.1",
    description = "Remote turtle control: CLI / dashboard D-pad. busy_on_handler defers OS upgrades while flying.",
    author = "F000NKKK",
    roles = { "any" },
    deps = {},
    requires = {},
    permissions = { "rpc", "turtle", "fuel", "inventory" },
    min_platform = "0.9.4",
    entry = "main.lua",
    files = { "main.lua" },
}
