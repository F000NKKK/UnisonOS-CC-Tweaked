return {
    name = "mine",
    version = "1.0.1",
    description = "Vertical mining shaft for turtles",
    author = "F000NKKK",
    roles = { "turtle" },
    deps = {},
    permissions = { "turtle", "fuel", "inventory" },
    -- Pure-turtle app, no UniAPI calls — but pinned to 0.8.0 baseline so
    -- new installations always get the platform with sandbox/printError
    -- fixes.
    min_platform = "0.8.0",
    entry = "main.lua",
    files = { "main.lua" },
}
