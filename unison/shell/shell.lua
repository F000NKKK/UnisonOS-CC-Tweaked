local COMMANDS_DIR = "/unison/shell/commands"

local function loadCommands()
    local cmds = {}
    if not fs.exists(COMMANDS_DIR) then return cmds end
    for _, f in ipairs(fs.list(COMMANDS_DIR)) do
        if f:sub(-4) == ".lua" then
            local name = f:sub(1, -5)
            local ok, mod = pcall(dofile, COMMANDS_DIR .. "/" .. f)
            if ok and type(mod) == "table" and mod.run then
                cmds[name] = mod
            else
                printError("[shell] failed to load command " .. name)
            end
        end
    end
    return cmds
end

local function tokenize(line)
    local toks = {}
    for w in line:gmatch("%S+") do toks[#toks + 1] = w end
    return toks
end

local function shortCwd(cwd)
    if cwd == "/" then return "/" end
    return cwd
end

local function prompt(ctx)
    local node = (unison and unison.node) or "node"
    if term.isColor and term.isColor() then term.setTextColor(colors.lightBlue) end
    write("[" .. node .. " " .. shortCwd(ctx.cwd) .. "]")
    if term.setTextColor then term.setTextColor(colors.white) end
    write("$ ")
end

return function()
    local cmds = loadCommands()
    local ctx = {
        commands = cmds,
        running = true,
        history = {},
        cwd = "/",
    }

    print("Type 'help' for available commands.")
    print("")

    while ctx.running do
        prompt(ctx)
        local line = read(nil, ctx.history)
        if line and line ~= "" then
            ctx.history[#ctx.history + 1] = line
            local toks = tokenize(line)
            local name = toks[1]
            table.remove(toks, 1)
            local cmd = cmds[name]
            if cmd then
                local ok, err = pcall(cmd.run, ctx, toks)
                if not ok then printError("error: " .. tostring(err)) end
            elseif name and fs.exists("/unison/apps/" .. name) and
                   fs.isDir("/unison/apps/" .. name) then
                -- Installed UPM packages are callable directly as commands.
                local runCmd = cmds["run"]
                if runCmd then
                    table.insert(toks, 1, name)
                    local ok, err = pcall(runCmd.run, ctx, toks)
                    if not ok then printError("error: " .. tostring(err)) end
                else
                    printError("run command missing")
                end
            else
                printError("unknown command: " .. tostring(name))
            end
        end
    end
end
