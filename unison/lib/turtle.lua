-- unison.lib.turtle — turtle movement & inventory helpers.
--
-- Folds the patient-retry / dig-clear / optional-attack pattern that
-- mine, farm, patrol and scanner each implemented separately. Use
-- M.forward/up/down for movement; pass {attack=true} to clear hostile
-- mobs in the way (off by default — most apps shouldn't fight).

local M = {}

if not turtle then return M end   -- callable from non-turtle role for safety

local DEFAULT_RETRIES = 40
local DEFAULT_SLEEP   = 0.3

-- Internal: try moveFn up to retries times. If digFn/detectFn given,
-- clear any block first (covers gravel/sand cascades). attackFn is
-- called once per failed attempt to clear an entity.
local function tryMove(moveFn, digFn, detectFn, attackFn, retries, sleepFor)
    retries  = retries  or DEFAULT_RETRIES
    sleepFor = sleepFor or DEFAULT_SLEEP
    for _ = 1, retries do
        if digFn and detectFn then
            while detectFn() do
                if not digFn() then sleep(0.3); break end
            end
        end
        if moveFn() then return true end
        if attackFn then attackFn() end
        sleep(sleepFor)
    end
    return false
end

-- opts:
--   dig    = false → don't dig blocks in the way (default: true)
--   attack = true  → call turtle.attack* on each retry (default: false)
--   retries, sleep
function M.forward(opts)
    opts = opts or {}
    return tryMove(turtle.forward,
        opts.dig ~= false and turtle.dig or nil,
        turtle.detect,
        opts.attack and turtle.attack or nil,
        opts.retries, opts.sleep)
end

function M.up(opts)
    opts = opts or {}
    return tryMove(turtle.up,
        opts.dig ~= false and turtle.digUp or nil,
        turtle.detectUp,
        opts.attack and turtle.attackUp or nil,
        opts.retries, opts.sleep)
end

function M.down(opts)
    opts = opts or {}
    return tryMove(turtle.down,
        opts.dig ~= false and turtle.digDown or nil,
        turtle.detectDown,
        opts.attack and turtle.attackDown or nil,
        opts.retries, opts.sleep)
end

-- Back up. turtle.back doesn't dig, so if blocked we turn around,
-- forward (with dig if allowed) and turn back.
function M.back(opts)
    opts = opts or {}
    if tryMove(turtle.back, nil, nil, nil, 5, 0.2) then return true end
    if opts.dig == false then return false end
    turtle.turnRight(); turtle.turnRight()
    local ok = M.forward(opts)
    turtle.turnRight(); turtle.turnRight()
    return ok
end

----------------------------------------------------------------------
-- Inventory
----------------------------------------------------------------------

function M.itemName(slot)
    local d = turtle.getItemDetail(slot)
    return d and d.name or nil
end

function M.freeSlots()
    local n = 0
    for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
    return n
end

function M.usedSlots() return 16 - M.freeSlots() end

function M.findItem(name)
    for s = 1, 16 do
        if M.itemName(s) == name then return s end
    end
    return nil
end

-- Squeeze every stack of the same item into lower-numbered slots.
function M.compact()
    for src = 16, 2, -1 do
        if turtle.getItemCount(src) > 0 then
            local n = M.itemName(src)
            if n then
                for dst = 1, src - 1 do
                    if M.itemName(dst) == n then
                        turtle.select(src)
                        turtle.transferTo(dst)
                        if turtle.getItemCount(src) == 0 then break end
                    end
                end
            end
        end
    end
end

-- Drop everything except the given slot numbers. Useful when returning
-- to a chest with a fuel reserve to keep.
function M.dropAllExcept(keepSet, dropFn)
    dropFn = dropFn or turtle.drop
    for s = 1, 16 do
        if not keepSet[s] and turtle.getItemCount(s) > 0 then
            turtle.select(s); dropFn()
        end
    end
end

return M
