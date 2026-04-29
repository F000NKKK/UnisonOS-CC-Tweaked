local M = {}

local LEVELS = { TRACE = 1, DEBUG = 2, INFO = 3, WARN = 4, ERROR = 5 }
local LOG_DIR = "/unison/logs"
local CURRENT_FILE = LOG_DIR .. "/current.log"

local state = {
    min_level = LEVELS.INFO,
    max_size = 16384,
    max_files = 5,
    sink = nil,
}

local function ts()
    local epoch = os.epoch("utc")
    local s = math.floor(epoch / 1000)
    local ms = epoch % 1000
    return string.format("%d.%03d", s, ms)
end

local function rotateIfNeeded()
    if not fs.exists(CURRENT_FILE) then return end
    local size = fs.getSize(CURRENT_FILE)
    if size < state.max_size then return end
    for i = state.max_files - 1, 1, -1 do
        local from = LOG_DIR .. "/log." .. i
        local to = LOG_DIR .. "/log." .. (i + 1)
        if fs.exists(from) then
            if fs.exists(to) then fs.delete(to) end
            fs.move(from, to)
        end
    end
    local first = LOG_DIR .. "/log.1"
    if fs.exists(first) then fs.delete(first) end
    fs.move(CURRENT_FILE, first)
end

local function ensureDir()
    if not fs.exists(LOG_DIR) then fs.makeDir(LOG_DIR) end
end

function M.configure(cfg)
    if cfg.log_level and LEVELS[cfg.log_level] then
        state.min_level = LEVELS[cfg.log_level]
    end
    if cfg.log_max_size then state.max_size = cfg.log_max_size end
    if cfg.log_max_files then state.max_files = cfg.log_max_files end
    ensureDir()
end

function M.setSink(fn)
    state.sink = fn
end

local function write(level, tag, msg)
    local lv = LEVELS[level] or LEVELS.INFO
    if lv < state.min_level then return end
    ensureDir()
    rotateIfNeeded()
    local line = string.format("[%s] %-5s %s: %s", ts(), level, tag or "-", msg)
    local h = fs.open(CURRENT_FILE, "a")
    if h then
        h.writeLine(line)
        h.close()
    end
    if state.sink then
        pcall(state.sink, level, tag, msg, line)
    end
end

function M.trace(tag, msg) write("TRACE", tag, msg) end
function M.debug(tag, msg) write("DEBUG", tag, msg) end
function M.info(tag, msg)  write("INFO",  tag, msg) end
function M.warn(tag, msg)  write("WARN",  tag, msg) end
function M.error(tag, msg) write("ERROR", tag, msg) end

function M.tail(n)
    n = n or 20
    if not fs.exists(CURRENT_FILE) then return {} end
    local h = fs.open(CURRENT_FILE, "r")
    local lines = {}
    while true do
        local line = h.readLine()
        if not line then break end
        lines[#lines + 1] = line
    end
    h.close()
    local start = math.max(1, #lines - n + 1)
    local out = {}
    for i = start, #lines do out[#out + 1] = lines[i] end
    return out
end

return M
