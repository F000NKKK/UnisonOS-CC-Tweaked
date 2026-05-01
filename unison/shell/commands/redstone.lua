local M = {
    desc = "Read / control redstone (incl. Create stress via comparator)",
    usage = "redstone <read|set|watch|all> [side] [value]",
}

local SIDES = { "front", "back", "left", "right", "top", "bottom" }

local function help()
    print("redstone — IO on every side of this computer/turtle")
    print("")
    print("  redstone all                    print all 6 input + output values")
    print("  redstone read <side>            analog input 0..15")
    print("  redstone set  <side> <0..15>    analog output 0..15")
    print("  redstone watch <side> [secs]    print signal until secs elapse / Ctrl+T")
    print("")
    print("Create integration:")
    print("  Stress Gauge → comparator → side 'back' (or any) →")
    print("    redstone read back     # 0..15 = stress percentage band")
    print("  Train station / Motor → redstone input from this side:")
    print("    redstone set right 15  # full power")
end

local function each(fn)
    for _, side in ipairs(SIDES) do
        local ok, v = pcall(redstone.getAnalogInput, side)
        local ok2, o = pcall(redstone.getAnalogOutput, side)
        fn(side, ok and v or "?", ok2 and o or "?")
    end
end

local function cmdAll()
    print(string.format("%-8s %-5s %s", "SIDE", "IN", "OUT"))
    each(function(side, inp, outp)
        print(string.format("%-8s %-5s %s", side, tostring(inp), tostring(outp)))
    end)
end

local function cmdRead(side)
    if not side then printError("usage: redstone read <side>"); return end
    local ok, v = pcall(redstone.getAnalogInput, side)
    if not ok then printError("read " .. side .. ": " .. tostring(v)); return end
    print(side .. " = " .. tostring(v))
end

local function cmdSet(side, val)
    val = tonumber(val)
    if not (side and val) then printError("usage: redstone set <side> <0..15>"); return end
    val = math.max(0, math.min(15, math.floor(val)))
    local ok, err = pcall(redstone.setAnalogOutput, side, val)
    if not ok then printError("set " .. side .. ": " .. tostring(err)); return end
    print(side .. " ← " .. val)
end

local function cmdWatch(side, secs)
    if not side then printError("usage: redstone watch <side> [secs]"); return end
    secs = tonumber(secs) or 30
    local deadline = os.startTimer(secs)
    local last = -1
    print(string.format("watching %s for %ds (Q to stop)...", side, secs))
    while true do
        local ev, p = os.pullEvent()
        if ev == "timer" and p == deadline then break end
        if ev == "char" and (p == "q" or p == "Q") then break end
        local v = redstone.getAnalogInput(side)
        if v ~= last then
            print(string.format("  %s = %d", side, v))
            last = v
        end
        sleep(0.2)
    end
    print("watch ended.")
end

function M.run(ctx, args)
    if not redstone then printError("no redstone API"); return end
    local sub = args[1] or "all"
    if sub == "all" then cmdAll()
    elseif sub == "read" or sub == "in"   then cmdRead(args[2])
    elseif sub == "set"  or sub == "out"  then cmdSet(args[2], args[3])
    elseif sub == "watch" then cmdWatch(args[2], args[3])
    elseif sub == "help" or sub == "-h"   then help()
    else help() end
end

return M
