local M = {
    desc = "GPS diagnostic + locate. Tries vanilla CC GPS, then HTTP bus.",
    usage = "gps               : full diagnostic (modems, locate, towers)\n"
         .. "gps locate [target]: locate self / <id> / <name> via lib.gps\n"
         .. "gps test [timeout] : verbose vanilla gps.locate with details",
}

local gpsLib = dofile("/unison/lib/gps.lua")
local fsLib  = dofile("/unison/lib/fs.lua")

local function listModems()
    local out = {}
    if not peripheral then return out end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, wireless = pcall(peripheral.call, name, "isWireless")
            out[#out + 1] = {
                name = name,
                wireless = ok and wireless or false,
                open = (rednet and rednet.isOpen(name)) or false,
            }
        end
    end
    return out
end

local function ensureModemsOpen()
    if not (peripheral and rednet) then return 0 end
    local opened = 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local ok, wireless = pcall(peripheral.call, name, "isWireless")
            if ok and wireless and not rednet.isOpen(name) then
                if pcall(rednet.open, name) then opened = opened + 1 end
            end
        end
    end
    return opened
end

local function diagnose()
    print("=== GPS diagnostic ===")
    print("computer id: " .. tostring(os.getComputerID()))
    print("turtle:      " .. tostring(turtle ~= nil)
        .. "  pocket: " .. tostring(pocket ~= nil))

    local modems = listModems()
    if #modems == 0 then
        printError("no modems attached. Need at least one wireless modem.")
        return
    end
    print("modems (" .. #modems .. "):")
    local hasWireless = false
    for _, m in ipairs(modems) do
        local kind = m.wireless and "wireless" or "wired"
        print(string.format("  %-12s  %-8s  %s",
            m.name, kind, m.open and "rednet open" or "rednet closed"))
        if m.wireless then hasWireless = true end
    end

    if not hasWireless then
        printError("no wireless modems found. gps.locate needs a wireless modem.")
        return
    end

    local opened = ensureModemsOpen()
    if opened > 0 then print("opened " .. opened .. " modem(s) on rednet") end

    -- Local tower coords (if this device is a tower).
    local saved = fsLib.readJson("/unison/state/gps-host.json")
    if saved and saved.x then
        print(string.format("this device is a TOWER at %d,%d,%d (%s)",
            saved.x, saved.y, saved.z, tostring(saved.source or "manual")))
    end

    print("")
    print("trying gps.locate (5s timeout)...")
    if gpsLib.resetGpsCache then gpsLib.resetGpsCache() end
    local x, y, z, src
    if gps then
        x, y, z = gps.locate(5, true)   -- second arg = debug print
        if x then src = "gps" end
    end
    if not x then
        print("  vanilla gps.locate: NO FIX")
        print("  (need to hear from at least 4 non-coplanar towers in radio range)")
        if saved and saved.x then
            print("  NOTE: this device is itself a tower — towers can't")
            print("  triangulate themselves. Try `gps test` on a NON-tower")
            print("  device (turtle / pocket / a spare PC) within range.")
        end
    else
        print(string.format("  vanilla gps.locate: %d,%d,%d  (source=%s)", x, y, z, src))
    end

    print("")
    print("HTTP bus self position (gpsnet)...")
    local bx, by, bz, bsrc = gpsLib.locate("self", { http_only = true })
    if bx then
        print(string.format("  bus: %d,%d,%d  (source=%s)", bx, by, bz, tostring(bsrc)))
    else
        print("  bus: " .. tostring(by or "unavailable"))
    end

    print("")
    print("known towers on the bus:")
    local devices, err = gpsLib.devices()
    if not devices then print("  unavailable: " .. tostring(err)); return end
    local towers = {}
    for _, d in ipairs(devices) do
        if d.source == "tower" or d.source == "host" then
            print(string.format("  %s  %s  %d,%d,%d  (%s)",
                d.id, d.name or "-", d.x, d.y, d.z, d.source or "?"))
            towers[#towers + 1] = d
        end
    end
    if #towers == 0 then
        print("  (none — at least one tower needs to register on the bus)")
        return
    end

    -- Coplanarity sanity check — if towers' Y spread is too small, the
    -- trilateration solver is ill-conditioned and returns nil even when
    -- all 4 towers are heard. This bites users almost every fresh setup.
    if #towers >= 4 then
        local xs, ys, zs = {}, {}, {}
        for _, t in ipairs(towers) do
            xs[#xs + 1] = t.x; ys[#ys + 1] = t.y; zs[#zs + 1] = t.z
        end
        local function spread(a)
            local lo, hi = a[1], a[1]
            for _, v in ipairs(a) do if v < lo then lo = v end; if v > hi then hi = v end end
            return hi - lo
        end
        local sx, sy, sz = spread(xs), spread(ys), spread(zs)
        print("")
        print(string.format("tower spread: x=%d  y=%d  z=%d", sx, sy, sz))
        if sy < 10 then
            print("  WARN: y spread is " .. sy .. " — towers are nearly coplanar.")
            print("  CC GPS won't lock in this configuration even if all 4 are")
            print("  heard. Move 1-2 towers to a much different height (>30")
            print("  blocks of y range is reliable).")
        end
        if sx < 10 or sz < 10 then
            print("  WARN: small x/z spread reduces accuracy near the towers' centre.")
        end
    elseif #towers > 0 and #towers < 4 then
        print("")
        print("  WARN: only " .. #towers .. " tower(s) on bus, need 4.")
    end
end

local function testLocate(timeoutArg)
    local timeout = tonumber(timeoutArg) or 5
    print("gps.locate(" .. timeout .. ", debug=true)...")
    if not gps then printError("no gps API"); return end
    if gpsLib.resetGpsCache then gpsLib.resetGpsCache() end
    ensureModemsOpen()
    local x, y, z = gps.locate(timeout, true)
    if x then
        print(string.format("FIX: %d,%d,%d", x, y, z))
    else
        printError("no fix.")
        print("Common causes:")
        print("  - fewer than 4 GPS towers in radio range")
        print("  - towers placed coplanar (need varied heights)")
        print("  - wireless modem on this device too far from towers")
        print("  - rednet not open on this modem (now opened automatically)")
    end
end

local function locateBus(target)
    target = target or "self"
    local x, y, z, src = gpsLib.locate(target)
    if not x then printError("gps: " .. tostring(y or src or "no fix")); return end
    print(string.format("%s: %d,%d,%d (%s)", tostring(target), x, y, z, tostring(src or "http")))
end

function M.run(ctx, args)
    local sub = args[1]
    if sub == nil then return diagnose() end
    if sub == "test" or sub == "-t" then return testLocate(args[2]) end
    if sub == "locate" or sub == "-l" then return locateBus(args[2]) end
    if sub == "-h" or sub == "--help" or sub == "help" then
        print(M.usage); return
    end
    -- Default: backward-compatible shorthand `gps <target>` → bus locate.
    return locateBus(sub)
end

return M
