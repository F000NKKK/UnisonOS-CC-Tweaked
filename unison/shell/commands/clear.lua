local M = {
    desc = "Clear the terminal screen",
    usage = "clear",
}

function M.run(ctx, args)
    if unison and unison.stdio then
        unison.stdio.clear()
    else
        term.clear(); term.setCursorPos(1, 1)
    end
end

return M
