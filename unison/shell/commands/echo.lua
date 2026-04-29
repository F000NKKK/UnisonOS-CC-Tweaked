local M = {
    desc = "Print arguments to the terminal",
    usage = "echo [args...]",
}

function M.run(ctx, args)
    print(table.concat(args, " "))
end

return M
