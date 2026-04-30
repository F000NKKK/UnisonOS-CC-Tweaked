-- unison.lib.scrollback — capture print/printError/write into a ring buffer
-- so the user can scroll back through everything that scrolled off the
-- top of the terminal. Used by the shell and by lib.cli REPLs.

local M = {}

local DEFAULT_MAX = 800

local lines = {}
local partial = ""
local maxLines = DEFAULT_MAX

local function pushLine(s)
    lines[#lines + 1] = s or ""
    while #lines > maxLines do table.remove(lines, 1) end
end

local function flushPartial()
    if partial ~= "" then pushLine(partial); partial = "" end
end

local function captureWrite(s)
    s = tostring(s or "")
    local last = 1
    while true do
        local nl = s:find("\n", last, true)
        if not nl then partial = partial .. s:sub(last); return end
        partial = partial .. s:sub(last, nl - 1)
        flushPartial()
        last = nl + 1
    end
end

local function captureLine(s)
    flushPartial(); pushLine(tostring(s or ""))
end

local installed = false
local origPrint, origPrintError, origWrite

function M.install(opts)
    if installed then return end
    if opts and opts.max then maxLines = opts.max end
    origPrint = _G.print
    origPrintError = _G.printError
    origWrite = _G.write
    _G.print = function(...)
        local n = select("#", ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring((select(i, ...))) end
        captureLine(table.concat(parts, "\t"))
        return origPrint(...)
    end
    _G.printError = function(s)
        captureLine("[err] " .. tostring(s))
        return origPrintError(s)
    end
    _G.write = function(s)
        captureWrite(s)
        return origWrite(s)
    end
    installed = true
end

function M.uninstall()
    if not installed then return end
    _G.print = origPrint
    _G.printError = origPrintError
    _G.write = origWrite
    installed = false
end

function M.push(s) captureLine(s) end
function M.appendPartial(s) captureWrite(s) end
function M.lines() return lines end
function M.size() return #lines end
function M.clear() lines = {}; partial = "" end

----------------------------------------------------------------------
-- Full-screen pager. Uses pullEvent for keys + mouse wheel; draws the
-- buffer with a scroll offset; q to leave.
----------------------------------------------------------------------

function M.pager(opts)
    opts = opts or {}
    flushPartial()
    local total = #lines
    local _, h = term.getSize()
    local viewH = math.max(1, h - 1)
    local maxOffset = math.max(0, total - viewH)
    local offset = maxOffset

    local function render()
        local w, _ = term.getSize()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        for i = 1, viewH do
            local idx = offset + i
            local line = lines[idx] or ""
            term.setCursorPos(1, i)
            if #line > w then line = line:sub(1, w) end
            term.write(line)
        end
        term.setCursorPos(1, h)
        term.setTextColor(colors.gray)
        term.write(string.format(" %d/%d   PgUp/PgDn  Home/End  q close",
            math.min(total, offset + viewH), total))
        term.setTextColor(colors.white)
    end

    render()
    while true do
        local ev, p1 = os.pullEvent()
        local moved = false
        if ev == "key" then
            if p1 == keys.q then break
            elseif p1 == keys.pageUp then offset = math.max(0, offset - viewH); moved = true
            elseif p1 == keys.pageDown then offset = math.min(maxOffset, offset + viewH); moved = true
            elseif p1 == keys.up then offset = math.max(0, offset - 1); moved = true
            elseif p1 == keys.down then offset = math.min(maxOffset, offset + 1); moved = true
            elseif p1 == keys.home then offset = 0; moved = true
            elseif p1 == keys["end"] then offset = maxOffset; moved = true
            end
        elseif ev == "mouse_scroll" then
            offset = math.max(0, math.min(maxOffset, offset + p1 * 3))
            moved = true
        elseif ev == "char" and (p1 == "q" or p1 == "Q") then
            break
        end
        if moved then render() end
    end
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
end

return M
