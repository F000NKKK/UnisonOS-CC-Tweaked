-- unison.lib.app — small lifecycle helpers reused across packages.
-- Eliminates the boilerplate `while true do pullEvent for q done` loop and
-- the standard "off()+on() for every handler then off again on exit" dance.

local M = {}

-- listenLoop: blocks until the user presses Q (char or key event), then
-- returns. Hooks: opts.intro / opts.outro print messages, opts.onEvent
-- gets every event and may return "exit" to break early.
function M.listenLoop(opts)
    opts = opts or {}
    if opts.intro then print(opts.intro) end
    while true do
        local ev = { os.pullEvent() }
        local name = ev[1]; local a = ev[2]
        if name == "char" and (a == "q" or a == "Q") then break end
        if name == "key"  and a == keys.q then break end
        if opts.onEvent then
            local res = opts.onEvent(table.unpack(ev))
            if res == "exit" then break end
        end
    end
    if opts.outro then print(opts.outro) end
end

-- subscribeAll: register a table of {type = handler}. Returns an
-- unsubscribe closure that removes them on shutdown. No-op without rpc.
function M.subscribeAll(handlers)
    local rpc = unison and unison.rpc
    if not (rpc and rpc.subscribe) then return function() end end
    for typ, fn in pairs(handlers) do rpc.subscribe(typ, fn) end
    return function()
        if not rpc.off then return end
        for typ in pairs(handlers) do rpc.off(typ) end
    end
end

-- run a listen-mode app: subscribe handlers, wait for Q, unsubscribe.
function M.runService(opts)
    opts = opts or {}
    local unsubscribe = M.subscribeAll(opts.handlers or {})
    M.listenLoop({
        intro = opts.intro,
        outro = opts.outro,
        onEvent = opts.onEvent,
    })
    unsubscribe()
end

return M
