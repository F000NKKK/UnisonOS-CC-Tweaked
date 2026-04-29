local M = {}

local mailboxes = {}
local subscribers = {}

function M.register(pid)
    mailboxes[pid] = mailboxes[pid] or {}
end

function M.unregister(pid)
    mailboxes[pid] = nil
end

function M.send(pid, msg)
    local box = mailboxes[pid]
    if not box then return false end
    box[#box + 1] = msg
    os.queueEvent("unison_ipc", pid)
    return true
end

function M.broadcast(topic, msg)
    local subs = subscribers[topic]
    if not subs then return 0 end
    local n = 0
    for pid in pairs(subs) do
        if M.send(pid, { topic = topic, data = msg }) then n = n + 1 end
    end
    return n
end

function M.subscribe(pid, topic)
    subscribers[topic] = subscribers[topic] or {}
    subscribers[topic][pid] = true
end

function M.unsubscribe(pid, topic)
    if subscribers[topic] then subscribers[topic][pid] = nil end
end

function M.recv(pid, timeout)
    local box = mailboxes[pid]
    if not box then return nil, "no_mailbox" end
    local deadline = nil
    if timeout then deadline = os.clock() + timeout end
    while true do
        if #box > 0 then
            return table.remove(box, 1)
        end
        if deadline then
            local remaining = deadline - os.clock()
            if remaining <= 0 then return nil, "timeout" end
            local timer = os.startTimer(remaining)
            while true do
                local ev, a = os.pullEvent()
                if ev == "unison_ipc" and a == pid then break end
                if ev == "timer" and a == timer then return nil, "timeout" end
            end
        else
            while true do
                local ev, a = os.pullEvent("unison_ipc")
                if a == pid then break end
            end
        end
    end
end

function M.peek(pid)
    local box = mailboxes[pid]
    return box and #box or 0
end

return M
