local M = {
    desc = "Clear the terminal screen",
    usage = "clear",
}

function M.run(ctx, args)
    term.clear()
    term.setCursorPos(1, 1)
end

return M
