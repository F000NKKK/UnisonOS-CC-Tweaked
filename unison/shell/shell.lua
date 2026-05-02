local COMMANDS_DIR = "/unison/shell/commands"
local scrollback = dofile("/unison/lib/scrollback.lua")

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

local function prompt(ctx)
    local node = (unison and unison.node) or "node"
    local io = unison and unison.stdio
    if io then
        if io.isColor() then io.setColor(colors.lightBlue) end
        io.write("[" .. node .. " " .. (ctx.cwd or "/") .. "]")
        io.setColor(colors.white)
        io.write("$ ")
    else
        write("[" .. node .. " " .. (ctx.cwd or "/") .. "]$ ")
    end
end

return function()
    local cmds = loadCommands()
    local ctx = {
        commands = cmds,
        running = true,
        history = {},
        cwd = "/",
    }

    -- Capture output into a ring buffer so the user can scroll back over
    -- everything that's been printed, even after it scrolled off the top.
    scrollback.install({ max = 1500 })
    ctx.scrollback = scrollback

    print("Type 'help' for available commands. Press Ctrl-S or type 'scroll' to read history.")
    print("")

    while ctx.running do
        prompt(ctx)
        local line = read(nil, ctx.history)
        if line and line ~= "" then
            ctx.history[#ctx.history + 1] = line
            scrollback.push("$ " .. line)

            -- 'scroll' / 's' is intercepted before command lookup so it
            -- works regardless of what other commands are installed.
            if line == "scroll" or line == "s" then
                scrollback.pager()
            else
                local toks = tokenize(line)
                local name = toks[1]
                table.remove(toks, 1)
                local cmd = cmds[name]
                if cmd then
                    local ok, err = pcall(cmd.run, ctx, toks)
                    if not ok then printError("error: " .. tostring(err)) end
                elseif name and fs.exists("/unison/apps/" .. name) and
                       fs.isDir("/unison/apps/" .. name) then
                    -- Installed UPM packages are callable as bare commands.
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
end
