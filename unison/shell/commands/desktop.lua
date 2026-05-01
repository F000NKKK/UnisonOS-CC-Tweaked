local M = {
    desc = "Launch the Unison desktop environment (TUI)",
    usage = "desktop",
}

function M.run(ctx, args)
    local desktop = dofile("/unison/ui/desktop.lua")
    desktop.run({})
end

return M
