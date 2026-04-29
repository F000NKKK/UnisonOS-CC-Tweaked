local log = dofile("/unison/kernel/log.lua")

local M = {}

local CHANNEL = 4717
local REPLY_CHANNEL = 4717

local modems = {}
local started = false

local function findModems()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            local kind = "wireless"
            if m.isWireless then
                if m.isWireless() then
                    kind = m.getNamesRemote and "ender" or "wireless"
                else
                    kind = "wired"
                end
            end
            out[#out + 1] = { name = name, modem = m, kind = kind }
        end
    end
    return out
end

function M.start()
    if started then return end
    modems = findModems()
    if #modems == 0 then
        log.warn("net", "no modems attached, transport idle")
        return
    end
    for _, m in ipairs(modems) do
        m.modem.open(CHANNEL)
        log.info("net", "modem " .. m.name .. " (" .. m.kind .. ") opened on ch " .. CHANNEL)
    end
    started = true
end

function M.modems()
    return modems
end

function M.channel()
    return CHANNEL
end

function M.broadcast(raw)
    if not started then return 0 end
    local sent = 0
    for _, m in ipairs(modems) do
        m.modem.transmit(CHANNEL, REPLY_CHANNEL, raw)
        sent = sent + 1
    end
    return sent
end

function M.sendVia(modemName, raw)
    for _, m in ipairs(modems) do
        if m.name == modemName then
            m.modem.transmit(CHANNEL, REPLY_CHANNEL, raw)
            return true
        end
    end
    return false
end

function M.stop()
    for _, m in ipairs(modems) do pcall(m.modem.close, CHANNEL) end
    modems = {}
    started = false
end

function M.isStarted() return started end

return M
