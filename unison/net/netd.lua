local transport = dofile("/unison/net/transport.lua")
local protocol = dofile("/unison/net/protocol.lua")
local auth = dofile("/unison/net/auth.lua")
local enroll = dofile("/unison/net/enroll.lua")
local router = dofile("/unison/net/router.lua")
local log = dofile("/unison/kernel/log.lua")

local M = {}

local handlers = {}
local outbound = {}

local function nodeId()
    return tostring(os.getComputerID())
end

local function isMaster()
    return unison and unison.role == "master"
end

local function masterSecret()
    return unison.config and unison.config.master and unison.config.master.secret
end

function M.send(pkt)
    if isMaster() then
        local key = auth.loadMasterKnownKey(pkt.to)
        if key then auth.sign(pkt, key) end
    else
        local key = auth.loadOwnKey()
        if key then auth.sign(pkt, key) end
    end
    local raw = protocol.encode(pkt)
    transport.broadcast(raw)
end

function M.broadcastUnsigned(pkt)
    local raw = protocol.encode(pkt)
    transport.broadcast(raw)
end

function M.on(pktType, fn)
    handlers[pktType] = handlers[pktType] or {}
    table.insert(handlers[pktType], fn)
end

local function dispatch(pkt, srcModem, distance)
    router.observeNeighbor(pkt.from, srcModem, distance)
    local list = handlers[pkt.type]
    if not list then
        log.debug("netd", "unhandled type=" .. tostring(pkt.type) .. " from=" .. tostring(pkt.from))
        return
    end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, pkt, srcModem, distance)
        if not ok then log.error("netd", "handler error: " .. tostring(err)) end
    end
end

local function verifyIncoming(pkt)
    if pkt.type == protocol.TYPES.ENROLL_REQ then return true end
    if pkt.type == protocol.TYPES.ENROLL_ACK then return true end

    if isMaster() then
        if router.isRevoked(pkt.from) then return false, "revoked" end
        local key = auth.loadMasterKnownKey(pkt.from)
        if not key then return false, "unknown sender " .. tostring(pkt.from) end
        local ok, err = auth.verify(pkt, key)
        if not ok then return false, err end
        local fresh, ferr = auth.checkFreshness(pkt, (unison.config.master and unison.config.master.nonce_window) or 60)
        if not fresh then return false, ferr end
        return true
    else
        local key = auth.loadOwnKey()
        if not key then return false, "no own key (not enrolled)" end
        local ok, err = auth.verify(pkt, key)
        if not ok then return false, err end
        return true
    end
end

local function handleIncoming(srcModem, raw, distance)
    local pkt = protocol.decode(raw)
    if not pkt then return end
    if pkt.from == nodeId() then return end
    if pkt.to ~= "*" and pkt.to ~= nodeId() then return end

    local ok, err = verifyIncoming(pkt)
    if not ok then
        log.warn("netd", "drop pkt type=" .. pkt.type .. " from=" .. tostring(pkt.from) .. " reason=" .. tostring(err))
        return
    end
    dispatch(pkt, srcModem, distance)
end

local function registerCoreHandlers()
    M.on(protocol.TYPES.HELLO, function(pkt)
        if isMaster() then
            local reply = protocol.new({
                from = nodeId(),
                to = pkt.from,
                type = protocol.TYPES.HELLO_ACK,
                payload = { master_id = nodeId() },
            })
            M.send(reply)
            router.touchNode(pkt.from)
        end
    end)

    M.on(protocol.TYPES.HELLO_ACK, function(pkt)
        log.info("netd", "master discovered: " .. tostring(pkt.from))
    end)

    M.on(protocol.TYPES.ENROLL_REQ, function(pkt)
        if not isMaster() then return end
        enroll.masterAddPending(pkt)
        log.info("netd", "ENROLL_REQ from " .. tostring(pkt.from) .. " (use 'enroll <code>' to approve)")
    end)

    M.on(protocol.TYPES.ENROLL_ACK, function(pkt)
        if isMaster() then return end
        if auth.hasOwnKey() then return end
        local code = enroll.ensureNodeCode()
        local ok, err = enroll.applyAck(pkt, code)
        if ok then
            log.info("netd", "enrollment complete, node key acquired")
            print("")
            print(">>> ENROLLMENT COMPLETE <<<")
            print("")
        else
            log.warn("netd", "ENROLL_ACK rejected: " .. tostring(err))
        end
    end)

    M.on(protocol.TYPES.HEARTBEAT, function(pkt)
        if isMaster() then router.touchNode(pkt.from) end
    end)
end

local function helloLoop()
    while true do
        local interval = (unison.config.network and unison.config.network.heartbeat_interval) or 5
        if isMaster() then
            local pkt = protocol.new({
                from = nodeId(),
                to = "*",
                type = protocol.TYPES.HELLO,
                payload = { role = "master" },
            })
            M.broadcastUnsigned(pkt)
        elseif auth.hasOwnKey() then
            local pkt = protocol.new({
                from = nodeId(),
                to = "master",
                type = protocol.TYPES.HEARTBEAT,
                payload = { uptime = math.floor((os.epoch("utc") - (UNISON.boot_time or 0)) / 1000) },
            })
            M.send(pkt)
        end
        sleep(interval)
    end
end

local function rxLoop()
    while true do
        local ev = { os.pullEvent("modem_message") }
        local _, side, ch, replyCh, msg, distance = table.unpack(ev)
        if ch == transport.channel() then
            if type(msg) == "string" then
                handleIncoming(side, msg, distance)
            end
        end
    end
end

function M.start()
    transport.start()
    router.load()
    registerCoreHandlers()

    if not isMaster() and not auth.hasOwnKey() then
        local code = enroll.ensureNodeCode()
        log.info("netd", "ENROLLMENT CODE: " .. code)
        print("")
        print(">>> ENROLLMENT CODE: " .. code .. " <<<")
        print(">>> Run 'enroll " .. code .. "' on master <<<")
        print("")
    end

    unison.kernel.scheduler.spawn(rxLoop,    "netd-rx",    { group = "system" })
    unison.kernel.scheduler.spawn(helloLoop, "netd-tx",    { group = "system" })

    if not isMaster() and not auth.hasOwnKey() then
        unison.kernel.scheduler.spawn(function()
            while not auth.hasOwnKey() do
                local pkt = enroll.buildRequest(nodeId(), enroll.ensureNodeCode(), unison.role)
                M.broadcastUnsigned(pkt)
                sleep(3)
            end
            log.info("netd", "node enrolled, key acquired")
        end, "netd-enroll", { group = "system" })
    end
end

return M
