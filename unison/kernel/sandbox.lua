-- Sandbox builder.
--
-- Given a list of permission strings (from a package manifest), return an
-- _ENV table with only those capabilities exposed.  The base set always
-- includes pure-Lua stdlib, sleep, and minimal os/term so apps can do
-- something useful without explicit permission.
--
-- Recognised permissions:
--   turtle           - the turtle global (mining, movement, blocks)
--   fuel             - alias for turtle (fuel ops live on the turtle global)
--   inventory        - alias for turtle (inventory ops on turtle global)
--   peripheral       - peripheral.* (any peripheral)
--   modem            - peripheral, restricted to modem peripherals
--   redstone         - rs / redstone globals
--   gps              - gps global
--   fs               - read+write fs
--   fs.read          - read-only fs
--   http             - http global (full)
--   rpc              - unison.rpc client (HTTP message bus)
--   shell            - shell.run, shell.openTab
--   term             - full term API (default exposes a safe subset)
--   all              - everything (no sandbox; use sparingly)

local M = {}

local function readonlyTable(t)
    local mt = { __index = t, __newindex = function() end, __metatable = false }
    return setmetatable({}, mt)
end

-- Guarantee a printError fallback. CC's BIOS defines it as a global, but in
-- some sandbox/coroutine paths it's been seen missing — falling back to a
-- coloured plain print keeps apps from crashing.
local function _printErr(...)
    if printError then return printError(...) end
    if term and term.setTextColor then
        local prev = term.getTextColor and term.getTextColor() or colors.white
        term.setTextColor(colors.red)
        print(...)
        term.setTextColor(prev)
    else
        print(...)
    end
end

local function buildBase()
    local env = {
        print = print, write = write, read = read,
        printError = printError or _printErr,
        tostring = tostring, tonumber = tonumber,
        ipairs = ipairs, pairs = pairs, next = next, select = select,
        type = type, error = error, assert = assert,
        pcall = pcall, xpcall = xpcall,
        setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen,
        table = table, string = string, math = math,
        coroutine = coroutine,
        textutils = textutils,
        colors = colors, colours = colours, keys = keys,
        sleep = sleep,
        unpack = table.unpack or unpack,
    }

    env.os = {
        time = os.time, date = os.date, clock = os.clock,
        epoch = os.epoch, sleep = os.sleep,
        getComputerID = os.getComputerID,
        computerID = os.computerID,
        getComputerLabel = os.getComputerLabel,
        pullEvent = os.pullEvent, pullEventRaw = os.pullEventRaw,
        queueEvent = os.queueEvent,
        startTimer = os.startTimer, cancelTimer = os.cancelTimer,
        version = os.version,
    }

    env.term = {
        write = term.write, blit = term.blit,
        clear = term.clear, clearLine = term.clearLine,
        setCursorPos = term.setCursorPos, getCursorPos = term.getCursorPos,
        setCursorBlink = term.setCursorBlink, getCursorBlink = term.getCursorBlink,
        getSize = term.getSize, scroll = term.scroll,
        setTextColor = term.setTextColor, setTextColour = term.setTextColour,
        setBackgroundColor = term.setBackgroundColor,
        setBackgroundColour = term.setBackgroundColour,
        getTextColor = term.getTextColor, getTextColour = term.getTextColour,
        getBackgroundColor = term.getBackgroundColor,
        getBackgroundColour = term.getBackgroundColour,
        isColor = term.isColor, isColour = term.isColour,
    }

    return env
end

local function readOnlyFs()
    return {
        list = fs.list, exists = fs.exists, isDir = fs.isDir,
        getDir = fs.getDir, getName = fs.getName, getSize = fs.getSize,
        combine = fs.combine, complete = fs.complete,
        open = function(path, mode)
            if mode and (mode:find("[wWaA]") or mode:find("[+]")) then
                error("fs.open: write modes not permitted (request 'fs')")
            end
            return fs.open(path, mode)
        end,
    }
end

local function modemPeripheral()
    -- peripheral wrapper that only exposes modem peripherals.
    return {
        getNames = peripheral.getNames,
        getType = peripheral.getType,
        isPresent = peripheral.isPresent,
        wrap = function(side)
            if peripheral.getType(side) ~= "modem" then
                error("peripheral.wrap: only modems are exposed (request 'peripheral')")
            end
            return peripheral.wrap(side)
        end,
        find = function(kind, fn)
            if kind ~= "modem" then
                error("peripheral.find: only modem allowed (request 'peripheral')")
            end
            return peripheral.find(kind, fn)
        end,
    }
end

local function lazy(loader)
    local cached
    return setmetatable({}, {
        __index = function(_, k)
            if not cached then cached = loader() end
            local v = cached[k]
            if type(v) == "function" then
                return function(...) return v(...) end
            end
            return v
        end,
    })
end

local _libCache
local function libModule()
    if not _libCache then _libCache = dofile("/unison/lib/init.lua") end
    return _libCache
end

local function appUnison()
    local u = {
        role = unison and unison.role,
        node = unison and unison.node,
        id = unison and unison.id,
        version = (UNISON and UNISON.version),
        log = unison and unison.kernel and unison.kernel.log,
        ipc = unison and unison.kernel and unison.kernel.ipc,
    }
    -- Read-only handles to kernel services, useful for app dashboards.
    u.kernel = {
        services = unison and unison.kernel and unison.kernel.services,
        process  = unison and unison.kernel and unison.kernel.process,
        async    = unison and unison.kernel and unison.kernel.async,
    }
    -- Top-level shortcuts so apps don't have to spell out unison.kernel.process.
    u.process = u.kernel.process
    u.async   = u.kernel.async
    -- Common utility library — fs/http/json/semver/path. Available to every
    -- app regardless of permissions; capabilities (like raw http) are still
    -- gated separately, lib.* just provides convenience wrappers.
    u.lib = libModule()
    -- UI framework, lazy-loaded so apps that don't draw don't pay the cost.
    u.ui = {
        buffer  = lazy(function() return dofile("/unison/ui/buffer.lua") end),
        wm      = lazy(function() return dofile("/unison/ui/wm.lua") end),
        widgets = lazy(function() return dofile("/unison/ui/widgets.lua") end),
    }
    return u
end

-- Build a sandbox _ENV for an app launched with the given permission list.
function M.build(permissions, opts)
    permissions = permissions or {}
    opts = opts or {}

    local has = {}
    for _, p in ipairs(permissions) do has[p] = true end

    if has.all then
        -- explicit escape hatch for trusted system-level apps.
        return _G
    end

    local env = buildBase()
    env._ENV = env
    env._G = env

    env.unison = appUnison()

    -- turtle, fuel, inventory all unlock the same global on a turtle.
    if (has.turtle or has.fuel or has.inventory) and turtle then
        env.turtle = turtle
    end

    if has.peripheral and peripheral then
        env.peripheral = peripheral
    elseif has.modem and peripheral then
        env.peripheral = modemPeripheral()
    end

    if has.redstone then
        env.rs = rs
        env.redstone = redstone
    end

    if has.gps and gps then
        env.gps = gps
    end

    if has.fs then
        env.fs = fs
    elseif has["fs.read"] then
        env.fs = readOnlyFs()
    end

    if has.http and http then
        env.http = http
    end

    if has.shell and shell then
        env.shell = shell
    end

    if has.term then
        env.term = term
    end

    if has.rpc and unison and unison.rpc then
        env.unison.rpc = unison.rpc
    end

    -- Restricted dofile: lets apps load OS modules under /unison/* so they
    -- can pull in helpers like /unison/ui/wm.lua without giving them full
    -- filesystem reach. The loaded module runs in the *real* global env,
    -- which is fine for trusted OS code.
    env.dofile = function(path)
        if type(path) ~= "string" or path:sub(1, 7) ~= "/unison" then
            error("dofile: only /unison/* paths permitted in sandbox", 2)
        end
        if not fs.exists(path) then error("dofile: not found: " .. path, 2) end
        return dofile(path)
    end

    -- Snapshot of what the app has been granted, in case it wants to check.
    env.unison.permissions = readonlyTable(has)

    return env
end

-- Run a Lua source file in a fresh sandbox with the given permissions.
function M.execFile(path, permissions, ...)
    local env = M.build(permissions)
    local fn, err = loadfile(path, "t", env)
    if not fn then
        fn, err = loadfile(path, nil, env)
    end
    if not fn then return false, "load: " .. tostring(err) end
    return pcall(fn, ...)
end

return M
