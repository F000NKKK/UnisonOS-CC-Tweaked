local M = {
    desc = "List directory entries",
    usage = "ls [path]",
}

local function resolve(ctx, p)
    if not p or p == "" then return ctx.cwd or "/" end
    if p:sub(1, 1) ~= "/" then p = fs.combine(ctx.cwd, p) end
    return "/" .. fs.combine("", p)
end

local function fmtSize(n)
    if n < 1024 then return n .. " B" end
    if n < 1024 * 1024 then return string.format("%.1f K", n / 1024) end
    return string.format("%.1f M", n / 1024 / 1024)
end

function M.run(ctx, args)
    local target = resolve(ctx, args[1])
    if not fs.exists(target) then printError("no such path: " .. target); return end
    if not fs.isDir(target) then
        print(target .. "  " .. fmtSize(fs.getSize(target)))
        return
    end
    local entries = fs.list(target)
    table.sort(entries)
    for _, name in ipairs(entries) do
        local full = fs.combine(target, name)
        if fs.isDir(full) then
            if term.isColor and term.isColor() then term.setTextColor(colors.lightBlue) end
            print(name .. "/")
            if term.setTextColor then term.setTextColor(colors.white) end
        else
            print(string.format("%-30s %s", name, fmtSize(fs.getSize(full))))
        end
    end
end

return M
