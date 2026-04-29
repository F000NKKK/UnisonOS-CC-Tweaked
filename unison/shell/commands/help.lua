local M = {
    desc = "List available commands or show help for a command",
    usage = "help [command]",
}

function M.run(ctx, args)
    if #args == 0 then
        local names = {}
        for name in pairs(ctx.commands) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local c = ctx.commands[name]
            print(string.format("  %-10s %s", name, c.desc or ""))
        end
        return
    end
    local target = args[1]
    local c = ctx.commands[target]
    if not c then
        printError("unknown command: " .. target)
        return
    end
    print(target .. " — " .. (c.desc or ""))
    if c.usage then print("  usage: " .. c.usage) end
end

return M
