local M = {
    desc = "HTTP-GPS utilities over Unison bus (host/locate/list)",
    usage = "gpsnet <status|up|host|auto|locate|list|pulse> ...",
}

local fsLib = dofile("/unison/lib/fs.lua")
local gpsLib = dofile("/unison/lib/gps.lua")
local fmt = dofile("/unison/lib/fmt.lua")

local STATE_FILE = "/unison/state/gpsnet.lua"

local function iRound(n)
    n = tonumber(n)
    if not n then return nil end
    if n >= 0 then return math.floor(n + 0.5) end
    return math.ceil(n - 0.5)
end

local function loadState()
    local t = fsLib.readLua(STATE_FILE)
    if type(t) ~= "table" then t = {} end
    if t.mode ~= "host" then t.mode = "auto" end
    return t
end

local function saveState(t)
    fsLib.writeLua(STATE_FILE, t)
end

local function getClient()
    return (unison and unison.rpc) or dofile("/unison/rpc/client.lua")
end

local function registerNow()
    local client = getClient()
    local _, err = client.register()
    if err then return false, err end
    return true
end

local function heartbeatNow()
    local client = getClient()
    local st = loadState()
    local metrics = {
        role = unison and unison.role or nil,
        gpsnet = { mode = st.mode },
    }
    if st.mode == "host" and st.host then
        metrics.position = {
            x = iRound(st.host.x),
            y = iRound(st.host.y),
            z = iRound(st.host.z),
        }
        metrics.position_source = "host"
    end
    local _, err = client.heartbeat(metrics)
    if err then return false, err end
    return true
end

local function locateHere(timeout)
    timeout = tonumber(timeout) or 2
    if gps then
        -- pcall to swallow any /rom/apis/gps.lua panics ("loop in
        -- gettable") originating in poisoned _ENV envs.
        local ok, x, y, z = pcall(gps.locate, timeout)
        if ok and x then return iRound(x), iRound(y), iRound(z), "gps" end
    end
    local x, y, z, srcOrErr = gpsLib.locate("self", { http_only = true })
    if x then return x, y, z, srcOrErr or "http" end
    -- Tower fallback: this device might BE a tower (set up via gps-tower)
    -- and so can't triangulate itself — read its own saved coords.
    local saved = fsLib.readJson("/unison/state/gps-host.json")
    if type(saved) == "table" and saved.x and saved.y and saved.z then
        return iRound(saved.x), iRound(saved.y), iRound(saved.z), "tower"
    end
    return nil, nil, nil, srcOrErr or "self locate failed"
end

local function printStatus()
    local st = loadState()
    print("gpsnet mode: " .. tostring(st.mode))
    if st.mode == "host" and st.host then
        print(string.format("host position: %d,%d,%d", st.host.x, st.host.y, st.host.z))
    end

    if gps then
        local ok, x, y, z = pcall(gps.locate, 1)
        if not ok then
            print("local gps: PANIC — " .. tostring(x))
        elseif x then
            print(string.format("local gps: %d,%d,%d", iRound(x), iRound(y), iRound(z)))
        else
            print("local gps: unavailable")
        end
    else
        print("local gps: api unavailable")
    end

    local x, y, z, src = gpsLib.locate("self", { http_only = true })
    if x then
        print(string.format("http gps self: %d,%d,%d (%s)", x, y, z, tostring(src or "http")))
    else
        print("http gps self: unavailable")
    end

    local client = getClient()
    local devices, err = client.devices()
    if not devices then
        print("bus self: unavailable (" .. tostring(err) .. ")")
        return
    end
    local selfId = tostring(os.getComputerID())
    if devices[selfId] then
        print("bus self: registered as " .. selfId)
    else
        print("bus self: not registered (run `gpsnet up`)")
    end
end

local function cmdHost(args)
    local x, y, z, source
    if args[2] == "here" then
        x, y, z, source = locateHere(args[3])
        if not x then
            printError("host here: " .. tostring(source))
            return
        end
    else
        x, y, z = iRound(args[2]), iRound(args[3]), iRound(args[4])
        if not (x and y and z) then
            printError("usage: gpsnet host <x> <y> <z> | gpsnet host here [timeout]")
            return
        end
        source = "manual"
    end
    local st = loadState()
    st.mode = "host"
    st.host = { x = x, y = y, z = z }
    st.updated_at = os.epoch("utc")
    saveState(st)
    print(string.format("gpsnet host set to %d,%d,%d (%s)", x, y, z, tostring(source)))
    local ok, err = heartbeatNow()
    if ok then print("heartbeat sent")
    else printError("heartbeat failed: " .. tostring(err)) end
end

local function cmdAuto()
    local st = loadState()
    st.mode = "auto"
    st.host = nil
    st.updated_at = os.epoch("utc")
    saveState(st)
    print("gpsnet switched to auto mode")
    local ok, err = heartbeatNow()
    if ok then print("heartbeat sent")
    else printError("heartbeat failed: " .. tostring(err)) end
end

local function cmdLocate(args)
    local target = args[2] or "self"
    local x, y, z, srcOrErr = gpsLib.locate(target)
    if not x then
        printError("locate: " .. tostring(y or srcOrErr))
        return
    end
    print(string.format("%s: %d,%d,%d (%s)", tostring(target), x, y, z, tostring(srcOrErr or "http")))
end

local function cmdList(args)
    local rows, err = gpsLib.devices()
    if not rows then
        printError("list: " .. tostring(err))
        return
    end
    print(string.format("%-8s %-12s %-7s %-7s %-7s %-7s %s",
        "ID", "NAME", "ROLE", "SEEN", "X", "Y", "Z"))
    if #rows == 0 then
        print("  (no devices with position)")
        return
    end
    for _, d in ipairs(rows) do
        print(string.format("%-8s %-12s %-7s %-7s %-7s %-7s %s",
            tostring(d.id):sub(1, 8),
            tostring(d.name or "-"):sub(1, 12),
            tostring(d.role or "-"):sub(1, 7),
            fmt.age(d.last_seen),
            tostring(d.x or "-"),
            tostring(d.y or "-"),
            tostring(d.z or "-")))
    end
end

local function printUsage()
    print("usage:")
    print("  gpsnet status")
    print("  gpsnet up                   # register on bus and send heartbeat now")
    print("  gpsnet host <x> <y> <z>     # publish static host position to HTTP bus")
    print("  gpsnet host here [timeout]  # detect local position and publish it")
    print("  gpsnet auto                 # use local gps.locate() (if available)")
    print("  gpsnet locate [id|name|self]")
    print("  gpsnet list")
    print("  gpsnet pulse                # send heartbeat now")
end

function M.run(ctx, args)
    local sub = args[1] or "status"
    if sub == "status" then return printStatus() end
    if sub == "up" or sub == "start" then
        local okReg, regErr = registerNow()
        if okReg then print("register: ok")
        else printError("register failed: " .. tostring(regErr)) end

        local okHb, hbErr = heartbeatNow()
        if okHb then print("heartbeat: ok")
        else printError("heartbeat failed: " .. tostring(hbErr)) end
        return
    end
    if sub == "host" then return cmdHost(args) end
    if sub == "auto" or sub == "clear" then return cmdAuto() end
    if sub == "locate" then return cmdLocate(args) end
    if sub == "list" then return cmdList(args) end
    if sub == "pulse" then
        local ok, err = heartbeatNow()
        if ok then print("heartbeat sent")
        else printError("heartbeat failed: " .. tostring(err)) end
        return
    end
    printUsage()
end

return M
