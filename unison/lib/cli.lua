-- unison.lib.cli — tiny CLI framework. Define a command tree once and you
-- get tokenization, argument validation (types, required/optional, defaults,
-- varargs), built-in `help` and `q/quit/exit`, and a REPL loop.
--
-- Example:
--   cli.run({
--     prompt = "storage",
--     intro = "storage online.",
--     commands = {
--       list = {
--         desc = "show item totals",
--         args = { { name = "pat", type = "string", default = "" } },
--         run  = function(ctx, args) printList(args.pat) end,
--       },
--       pull = {
--         desc = "move N items into target",
--         args = {
--           { name = "pat",    type = "string", required = true },
--           { name = "count",  type = "number", default = 64 },
--           { name = "target", type = "string", default = nil },
--         },
--         run  = function(ctx, args) ... end,
--       },
--     },
--   })

local M = {}

----------------------------------------------------------------------
-- Tokenization (quoted strings supported)
----------------------------------------------------------------------

function M.tokenize(line)
    local out = {}
    local i = 1
    while i <= #line do
        local ch = line:sub(i, i)
        if ch:match("%s") then
            i = i + 1
        elseif ch == '"' or ch == "'" then
            local close = line:find(ch, i + 1, true)
            if not close then
                out[#out + 1] = line:sub(i + 1)
                break
            end
            out[#out + 1] = line:sub(i + 1, close - 1)
            i = close + 1
        else
            local space = line:find("%s", i)
            if not space then
                out[#out + 1] = line:sub(i); break
            end
            out[#out + 1] = line:sub(i, space - 1)
            i = space + 1
        end
    end
    return out
end

----------------------------------------------------------------------
-- Argument validation
----------------------------------------------------------------------

local function castOne(spec, raw)
    if raw == nil then
        if spec.default ~= nil then return spec.default end
        if spec.required then return nil, "missing arg '" .. spec.name .. "'" end
        return nil
    end
    if spec.type == "number" or spec.type == "int" then
        local n = tonumber(raw)
        if not n then return nil, "expected number for '" .. spec.name .. "'" end
        if spec.type == "int" then n = math.floor(n) end
        return n
    end
    if spec.type == "boolean" or spec.type == "bool" then
        local s = tostring(raw):lower()
        return s == "true" or s == "yes" or s == "y" or s == "1"
    end
    if spec.choices then
        for _, c in ipairs(spec.choices) do
            if raw == c then return raw end
        end
        return nil, "'" .. spec.name .. "' must be one of: " .. table.concat(spec.choices, ", ")
    end
    return tostring(raw)
end

function M.validate(cmd, raw)
    local args = {}
    local specs = cmd.args or {}
    for i, spec in ipairs(specs) do
        local v, err = castOne(spec, raw[i])
        if err then return nil, err end
        args[spec.name] = v
        args[i] = v
    end
    if #raw > #specs then
        if cmd.varargs then
            local extras = {}
            for i = #specs + 1, #raw do extras[#extras + 1] = raw[i] end
            args._varargs = extras
        else
            return nil, string.format("'%s' expects %d arg(s), got %d",
                cmd._name or "?", #specs, #raw)
        end
    end
    return args
end

function M.usage(cmd)
    local parts = { cmd._name or "?" }
    for _, a in ipairs(cmd.args or {}) do
        if a.required then parts[#parts + 1] = "<" .. a.name .. ">"
        else parts[#parts + 1] = "[" .. a.name .. "]" end
    end
    if cmd.varargs then parts[#parts + 1] = "[...]" end
    return table.concat(parts, " ")
end

----------------------------------------------------------------------
-- One-shot dispatcher (no prompt) — used by exec handlers, CI, etc.
----------------------------------------------------------------------

function M.dispatch(spec, line, ctx)
    ctx = ctx or { state = {}, cwd = "/" }
    local toks = M.tokenize(line)
    local name = table.remove(toks, 1)
    if not name or name == "" then return false, "empty command" end

    if name == "help" or name == "?" then
        M.printHelp(spec); return true
    end

    local cmd = (spec.commands or {})[name]
    if not cmd then return false, "unknown command: " .. name end

    cmd._name = name
    local args, err = M.validate(cmd, toks)
    if not args then return false, err end
    return pcall(cmd.run, ctx, args)
end

function M.printHelp(spec)
    if spec.intro then print(spec.intro) end
    print("commands:")
    local names = {}
    for k in pairs(spec.commands or {}) do names[#names + 1] = k end
    table.sort(names)
    for _, name in ipairs(names) do
        local c = spec.commands[name]
        c._name = name
        print(string.format("  %-22s %s", M.usage(c), c.desc or ""))
    end
    print(string.format("  %-22s %s", "scroll / s", "open the scrollback pager"))
    print(string.format("  %-22s %s", "help / ?", "show this listing"))
    print(string.format("  %-22s %s", "q / quit / exit", "leave"))
end

local scrollback = dofile("/unison/lib/scrollback.lua")

----------------------------------------------------------------------
-- Interactive REPL
----------------------------------------------------------------------

function M.run(spec)
    local ctx = { running = true, cwd = "/", state = spec.state or {} }
    scrollback.install()
    if spec.intro then print(spec.intro) end

    while ctx.running do
        local prefix = (spec.prompt or "")
        if prefix ~= "" then write(prefix) end
        write("> ")
        local line = read()
        if line == nil then break end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        scrollback.push((spec.prompt or "") .. "> " .. line)
        if line == "" then
        elseif line == "q" or line == "quit" or line == "exit" then break
        elseif line == "help" or line == "?" then M.printHelp(spec)
        elseif line == "scroll" or line == "s" then scrollback.pager()
        else
            local ok, err = M.dispatch(spec, line, ctx)
            if not ok then
                printError(err or "command error")
                local toks = M.tokenize(line)
                local cmd = spec.commands and spec.commands[toks[1]]
                if cmd then cmd._name = toks[1]; print("usage: " .. M.usage(cmd)) end
            end
        end
    end

    scrollback.uninstall()
    if spec.on_exit then pcall(spec.on_exit, ctx) end
end

M.pager = scrollback.pager
M.pushLine = scrollback.push

return M
