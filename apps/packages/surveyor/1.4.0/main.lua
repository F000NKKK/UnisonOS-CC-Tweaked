-- surveyor 1.4.0 — phone-form-factor selection editor.
--
-- 1.4.0:
--   • Explicit back chip [<] in the top-left corner — replaces the
--     hard-to-spot UTF-8 arrow hidden in the title text. 3x1 hit area.
--   • Manual coordinate entry: P1 EDIT / P2 EDIT buttons walk through
--     a 3-step numeric keypad (X then Y then Z).
--   • Scrollable action list on DETAIL: 10 actions in a single column,
--     scrolled with [^] / [v] arrows on the right edge plus mouse
--     wheel and arrow keys.
-- 1.3.0: progress display per sector
-- 1.2.0: dispatcher discovery + state sync
-- 1.1.0: live GPS strip
--
-- Designed for the CC pocket computer (26x20, portrait).

local sels = unison and unison.lib and unison.lib.selection
local gpsLib = unison and unison.lib and unison.lib.gps
local disc = unison and unison.lib and unison.lib.discovery
local stdio = unison and unison.stdio
local gdi   = unison and unison.gdi

local function dispatcherId()
    local cfg = unison and unison.config and unison.config.dispatcher_id
    if cfg then return cfg end
    if disc then return disc.lookup("dispatcher") end
    return nil
end

if not (sels and stdio and gdi) then
    if printError then printError("surveyor: missing unison.lib.selection / stdio / gdi") end
    return
end

----------------------------------------------------------------------
-- Layout helpers
----------------------------------------------------------------------

local W, H = stdio.size()

local function clear(bg)
    local ctx = gdi.screen()
    ctx:fillRect(1, 1, W, H, bg or colors.black)
    ctx:setCursor(1, 1)
end

local function bar(y, label, fg, bg)
    local ctx = gdi.screen()
    ctx:fillRect(1, y, W, 1, bg or colors.gray)
    if label then
        local s = label
        if #s > W then s = s:sub(1, W) end
        ctx:drawText(1, y, s, fg or colors.white, bg or colors.gray)
    end
end

-- Title bar with optional [<] back chip on the left. The chip is
-- ASCII-only (no UTF-8) so CC's font renders it cleanly and the hit
-- area is unambiguous.
local function title(text, withBack)
    local ctx = gdi.screen()
    ctx:fillRect(1, 1, W, 1, colors.blue)
    if withBack then
        ctx:fillRect(1, 1, 3, 1, colors.cyan)
        ctx:drawText(1, 1, "[<]", colors.black, colors.cyan)
        local body = " " .. (text or "")
        if #body > W - 4 then body = body:sub(1, W - 4) end
        ctx:drawText(4, 1, body, colors.white, colors.blue)
    else
        local body = " " .. (text or "")
        if #body > W then body = body:sub(1, W) end
        ctx:drawText(1, 1, body, colors.white, colors.blue)
    end
end

local function makeButton(label, x, y, w, h, opts)
    opts = opts or {}
    return {
        x = x, y = y, w = w, h = h,
        label = label,
        fg = opts.fg or colors.white,
        bg = opts.bg or colors.blue,
        on_tap = opts.on_tap,
        kind = opts.kind or "btn",
    }
end

local function drawButton(b)
    local ctx = gdi.screen()
    ctx:fillRect(b.x, b.y, b.w, b.h, b.bg)
    if b.label then
        local s = b.label
        if #s > b.w - 1 then s = s:sub(1, b.w - 1) end
        local lx = b.x + math.floor((b.w - #s) / 2)
        local ly = b.y + math.floor((b.h - 1) / 2)
        ctx:drawText(lx, ly, s, b.fg, b.bg)
    end
end

local function hitButton(buttons, mx, my)
    for _, b in ipairs(buttons) do
        if mx >= b.x and mx < b.x + b.w
           and my >= b.y and my < b.y + b.h then
            return b
        end
    end
end

local function addBackButton(buttons, fn)
    table.insert(buttons, {
        x = 1, y = 1, w = 3, h = 1,
        kind = "back",
        on_tap = fn,
    })
end

----------------------------------------------------------------------
-- GPS
----------------------------------------------------------------------

local function readGps(timeout)
    if not gpsLib then return nil, "no gps lib" end
    local x, y, z, src = gpsLib.locate("self", { timeout = timeout or 2 })
    if not x then return nil, "no fix" end
    return { x = math.floor(x + 0.5),
             y = math.floor(y + 0.5),
             z = math.floor(z + 0.5),
             src = src }
end

local GPS_POLL_INTERVAL = 0.25
local GPS_POLL_TIMEOUT  = 0.2

local liveGps = nil
local gpsTimer = nil

local function refreshLiveGps()
    local p = readGps(GPS_POLL_TIMEOUT)
    if p then liveGps = p else liveGps = nil end
end

local function liveGpsLine()
    if liveGps then return string.format("%d,%d,%d", liveGps.x, liveGps.y, liveGps.z) end
    return "no gps"
end

local function paintGpsStrip()
    local ctx = gdi.screen()
    ctx:fillRect(1, 2, W, 1, colors.black)
    ctx:drawText(1, 2, " " .. liveGpsLine(), colors.lime, colors.black)
end

----------------------------------------------------------------------
-- App state + nav stack
----------------------------------------------------------------------

local app = {
    running   = true,
    stack     = {},
    selId     = nil,
    pending   = nil,
    flash     = nil,
    flash_ts  = 0,
}

local function flash(msg) app.flash = msg; app.flash_ts = os.epoch and os.epoch("utc") or 0 end

local function push(screen) app.stack[#app.stack + 1] = screen end
local function pop()
    if #app.stack > 1 then app.stack[#app.stack] = nil end
end
local function replace(screen) app.stack[#app.stack] = screen end
local function top() return app.stack[#app.stack] end

local function paintFlash()
    if not app.flash then return end
    local now = os.epoch and os.epoch("utc") or 0
    if (now - (app.flash_ts or 0)) > 4000 then app.flash = nil; return end
    bar(H, " " .. app.flash, colors.yellow, colors.black)
end

local screenList, screenDetail, screenAxis, screenNum, screenCoord, screenName, screenConfirm

----------------------------------------------------------------------
-- LIST
----------------------------------------------------------------------

screenList = function()
    local self = {
        kind = "list",
        offset = 0,
        rows = sels.list(),
        activeId = sels.activeId(),
        buttons = {},
    }

    self.render = function(s)
        clear(colors.black)
        title("Selections (" .. #s.rows .. ")", false)
        paintGpsStrip()

        local rowH = 3
        local bodyTop = 4
        local bodyBottom = H - 4
        local maxVisible = math.floor((bodyBottom - bodyTop + 1) / rowH)
        s.buttons = {}
        local ctx = gdi.screen()

        if #s.rows == 0 then
            ctx:drawText(2, bodyTop + 1, "(no selections)", colors.lightGray, colors.black)
            ctx:drawText(2, bodyTop + 3, "tap [+ NEW] below.", colors.lightGray, colors.black)
        else
            for i = 1, math.min(maxVisible, #s.rows - s.offset) do
                local sel = s.rows[i + s.offset]
                local sm = sel:summary()
                local y = bodyTop + (i - 1) * rowH
                local active = sel.id == s.activeId
                local bg = active and colors.gray or colors.lightGray
                local fg = active and colors.white or colors.black
                ctx:fillRect(1, y, W, rowH - 1, bg)
                ctx:drawText(2, y, ((sm.name or ""):sub(1, W - 2)), fg, bg)
                local stateLabel = "[" .. sm.state .. "]"
                if sm.parts_total and sm.parts_total > 1 then
                    stateLabel = string.format("[%s %d/%d]",
                        sm.state, sm.parts_done or 0, sm.parts_total)
                end
                ctx:drawText(2, y + 1, (stateLabel ..
                    (sm.dimensions and string.format(" %dx%dx%d",
                        sm.dimensions[1], sm.dimensions[2], sm.dimensions[3]) or "")),
                    fg, bg)
                table.insert(s.buttons, {
                    x = 1, y = y, w = W, h = rowH - 1,
                    kind = "row", id = sel.id,
                })
            end
        end

        local b = makeButton("+ NEW", 1, H - 3, W, 3,
            { bg = colors.green, fg = colors.white,
              on_tap = function() push(screenName({ purpose = "new" })) end })
        table.insert(s.buttons, b); drawButton(b)

        paintFlash()
    end

    self.on_tap = function(s, mx, my)
        local b = hitButton(s.buttons, mx, my)
        if not b then return end
        if b.kind == "row" then
            sels.setActive(b.id)
            app.selId = b.id
            push(screenDetail())
            return
        end
        if b.on_tap then b.on_tap() end
    end

    self.on_event = function(s, ev)
        if ev[1] == "key" and ev[2] == keys.q then app.running = false end
    end
    return self
end

----------------------------------------------------------------------
-- DETAIL — scrollable action list
----------------------------------------------------------------------

local function fmtPoint(p) return p and string.format("%d,%d,%d", p.x, p.y, p.z) or "-" end

local function dispatchSelectionRpc(sel)
    local rpc = unison and unison.rpc
    local did = dispatcherId()
    if rpc and did then
        local res = rpc.send(did, { type = "selection_queue", selection = sel:toTable() })
        if res and res.ok ~= false then return "queued -> " .. did end
        return "queued (rpc failed)"
    end
    return "queued (local only)"
end

screenDetail = function()
    local self = {
        kind = "detail",
        scroll = 0,
        buttons = {},
    }

    self.actions = function(sel)
        return {
            { "P1 HERE", colors.cyan, colors.black, function()
                local p = liveGps or readGps(2)
                if not p then flash("gps: no fix"); return end
                sel:setP1({ x = p.x, y = p.y, z = p.z }); sel:save(); flash("p1 set")
            end },
            { "P1 EDIT", colors.lightBlue, colors.black, function()
                push(screenCoord({
                    title = "P1",
                    initial = sel.p1 or liveGps,
                    ok = function(p)
                        sel:setP1({ x = p.x, y = p.y, z = p.z })
                        sel:save(); flash("p1 set")
                    end,
                }))
            end },
            { "P2 HERE", colors.cyan, colors.black, function()
                local p = liveGps or readGps(2)
                if not p then flash("gps: no fix"); return end
                sel:setP2({ x = p.x, y = p.y, z = p.z }); sel:save(); flash("p2 set")
            end },
            { "P2 EDIT", colors.lightBlue, colors.black, function()
                push(screenCoord({
                    title = "P2",
                    initial = sel.p2 or liveGps,
                    ok = function(p)
                        sel:setP2({ x = p.x, y = p.y, z = p.z })
                        sel:save(); flash("p2 set")
                    end,
                }))
            end },
            { "EXPAND", colors.lime, colors.black, function()
                app.pending = { op = "expand", selId = sel.id }
                push(screenAxis({ next = "num" }))
            end },
            { "CONTRACT", colors.orange, colors.black, function()
                app.pending = { op = "contract", selId = sel.id }
                push(screenAxis({ next = "num" }))
            end },
            { "SLICE", colors.purple, colors.white, function()
                app.pending = { op = "slice", selId = sel.id }
                push(screenAxis({ next = "num" }))
            end },
            { "QUEUE", colors.green, colors.white, function()
                if not sel.volume then flash("set p1+p2 first"); return end
                sel:queue(); sel:save()
                flash(dispatchSelectionRpc(sel))
            end },
            { "CANCEL JOB", colors.gray, colors.white, function()
                sel:cancel(); sel:save()
                local rpc = unison and unison.rpc
                local did = dispatcherId()
                if rpc and did then
                    pcall(rpc.send, did, { type = "selection_cancel", id = sel.id })
                end
                flash("cancelled")
            end },
            { "DELETE", colors.red, colors.white, function()
                push(screenConfirm({
                    prompt = "Delete?",
                    ok = function() sel:remove(); pop(); pop(); flash("deleted") end,
                }))
            end },
        }
    end

    self.render = function(s)
        clear(colors.black)
        local sel = sels.load(app.selId)
        if not sel then pop(); return end
        local sm = sel:summary()
        title(sm.name or "", true)
        paintGpsStrip()
        s.buttons = {}
        addBackButton(s.buttons, function() pop() end)

        local ctx = gdi.screen()

        local y = 4
        ctx:drawText(1, y, "state: " .. sm.state, colors.white, colors.black);  y = y + 1
        if sm.parts_total and sm.parts_total > 1 then
            ctx:drawText(1, y, string.format("parts: %d/%d%s",
                sm.parts_done or 0, sm.parts_total,
                (sm.parts_failed and sm.parts_failed > 0)
                    and (" (" .. sm.parts_failed .. " fail)") or ""),
                colors.yellow, colors.black); y = y + 1
        end
        ctx:drawText(1, y, ("p1:" .. fmtPoint(sel.p1) .. "  p2:" .. fmtPoint(sel.p2)):sub(1, W),
            colors.lightGray, colors.black); y = y + 1
        if sm.volume and sm.dimensions then
            ctx:drawText(1, y, string.format("dim:%dx%dx%d  blk:%d",
                sm.dimensions[1], sm.dimensions[2], sm.dimensions[3], sm.blocks),
                colors.white, colors.black); y = y + 1
        else
            ctx:drawText(1, y, "(volume incomplete)", colors.orange, colors.black); y = y + 1
        end

        -- Scrollable action list. Each action: 1 button, 2 rows tall.
        local listTop = y + 1
        local listBottom = H - 1
        local listH = listBottom - listTop + 1
        local rowH = 2
        local visibleCount = math.floor(listH / rowH)
        local actions = s.actions(sel)
        local maxScroll = math.max(0, #actions - visibleCount)
        if s.scroll > maxScroll then s.scroll = maxScroll end
        if s.scroll < 0 then s.scroll = 0 end

        local arrowW = 3
        local listW = W - arrowW

        for i = 1, math.min(visibleCount, #actions - s.scroll) do
            local act = actions[i + s.scroll]
            local by = listTop + (i - 1) * rowH
            local b = makeButton(act[1], 1, by, listW, rowH,
                { bg = act[2], fg = act[3], on_tap = act[4] })
            table.insert(s.buttons, b); drawButton(b)
        end

        -- Scroll arrows on the right edge.
        local upH = math.floor(listH / 2)
        local dnH = listH - upH
        local upBg = s.scroll > 0 and colors.gray or colors.lightGray
        local dnBg = s.scroll < maxScroll and colors.gray or colors.lightGray
        local up = makeButton("^", listW + 1, listTop, arrowW, upH,
            { bg = upBg, fg = colors.white,
              on_tap = function() s.scroll = math.max(0, s.scroll - 1) end })
        local dn = makeButton("v", listW + 1, listTop + upH, arrowW, dnH,
            { bg = dnBg, fg = colors.white,
              on_tap = function() s.scroll = math.min(maxScroll, s.scroll + 1) end })
        table.insert(s.buttons, up); drawButton(up)
        table.insert(s.buttons, dn); drawButton(dn)

        paintFlash()
    end

    self.on_tap = function(s, mx, my)
        local b = hitButton(s.buttons, mx, my)
        if b and b.on_tap then b.on_tap() end
    end

    self.on_event = function(s, ev)
        if ev[1] == "key" then
            if ev[2] == keys.backspace then pop() end
            if ev[2] == keys.q then app.running = false end
            if ev[2] == keys.up   then s.scroll = math.max(0, (s.scroll or 0) - 1) end
            if ev[2] == keys.down then s.scroll = (s.scroll or 0) + 1 end
        elseif ev[1] == "mouse_scroll" then
            s.scroll = (s.scroll or 0) + ev[2]
        end
    end
    return self
end

----------------------------------------------------------------------
-- AXIS picker
----------------------------------------------------------------------

screenAxis = function(opts)
    local self = { kind = "axis", buttons = {} }
    self.render = function(s)
        clear(colors.black)
        title("Axis", true)
        s.buttons = {}
        addBackButton(s.buttons, function() pop() end)

        local labels = { "+X", "+Y", "+Z", "-X", "-Y", "-Z" }
        local axes   = { "+x", "+y", "+z", "-x", "-y", "-z" }
        local colsW = math.floor(W / 3)
        local rowH  = 5
        for i, lab in ipairs(labels) do
            local row = math.floor((i - 1) / 3)
            local col = (i - 1) % 3
            local bg = (i <= 3) and colors.lime or colors.orange
            local b = makeButton(lab,
                1 + col * colsW, 4 + row * rowH,
                colsW, rowH,
                { bg = bg, fg = colors.black,
                  on_tap = function()
                      app.pending.axis = axes[i]
                      if opts.next == "num" then
                          replace(screenNum({
                              prompt = (app.pending.op or "delta") .. " " .. axes[i],
                              default = (app.pending.op == "slice") and 1 or 5,
                          }))
                      else pop() end
                  end })
            table.insert(s.buttons, b); drawButton(b)
        end
        paintFlash()
    end
    self.on_tap = function(s, mx, my)
        local b = hitButton(s.buttons, mx, my)
        if b and b.on_tap then b.on_tap() end
    end
    self.on_event = function(s, ev)
        if ev[1] == "key" and ev[2] == keys.backspace then pop() end
    end
    return self
end

----------------------------------------------------------------------
-- Numeric keypad helper (used by NUM and COORD)
----------------------------------------------------------------------

local function drawNumKeypad(parent, valueRef, onCommit, opts)
    -- valueRef: { value = "5" } so the closure can mutate it.
    -- onCommit(newValue, done): called on each tap; done=true on DONE.
    opts = opts or {}
    local y0 = opts.y0 or 6
    local ctx = gdi.screen()

    -- Display row above keypad.
    ctx:fillRect(1, y0 - 3, W, 3, colors.lightGray)
    local s = valueRef.value
    if #s > W - 2 then s = s:sub(-W + 2) end
    ctx:drawText(W - #s, y0 - 2, s, colors.black, colors.lightGray)

    local keys_ = { "1","2","3","4","5","6","7","8","9","+/-","0","BS" }
    local kw = math.floor(W / 3); local kh = 3
    for i, label in ipairs(keys_) do
        local r = math.floor((i - 1) / 3)
        local c = (i - 1) % 3
        local b = makeButton(label,
            1 + c * kw, y0 + r * kh, kw, kh,
            { bg = colors.gray, fg = colors.white,
              on_tap = function()
                  local v = valueRef.value
                  if label == "BS" then
                      v = v:sub(1, -2)
                      if v == "" or v == "-" then v = "0" end
                  elseif label == "+/-" then
                      if v:sub(1, 1) == "-" then v = v:sub(2)
                      elseif v ~= "0" then v = "-" .. v end
                  else
                      if v == "0" then v = label
                      else v = v .. label end
                  end
                  valueRef.value = v
                  onCommit(v, false)
              end })
        table.insert(parent.buttons, b); drawButton(b)
    end

    local n = tonumber(valueRef.value) or 0
    local doneLabel = (opts.doneLabel and opts.doneLabel(n)) or ("DONE (" .. n .. ")")
    local done = makeButton(doneLabel, 1, H - 2, W, 3,
        { bg = colors.green, fg = colors.white,
          on_tap = function() onCommit(valueRef.value, true) end })
    table.insert(parent.buttons, done); drawButton(done)
end

----------------------------------------------------------------------
-- NUM (single value, used by EXPAND / CONTRACT / SLICE)
----------------------------------------------------------------------

screenNum = function(opts)
    local valueRef = { value = tostring(opts.default or 1) }
    local self = { kind = "num", buttons = {} }
    self.render = function(s)
        clear(colors.black)
        title(opts.prompt or "value", true)
        s.buttons = {}
        addBackButton(s.buttons, function() pop() end)

        drawNumKeypad(s, valueRef, function(newVal, done)
            if done then
                local n = tonumber(newVal) or 0
                local sel = sels.load(app.pending.selId)
                if not sel then flash("selection gone"); pop(); return end
                local op = app.pending.op
                if op == "expand"   then sel:expand(app.pending.axis, n)
                elseif op == "contract" then sel:contract(app.pending.axis, n)
                elseif op == "slice"    then sel:slice(app.pending.axis, n)
                end
                sel:save()
                app.pending = nil
                pop()
                flash(op .. " " .. tostring(n))
            else
                s:render()
            end
        end, { y0 = 6 })

        paintFlash()
    end
    self.on_tap = function(s, mx, my)
        local b = hitButton(s.buttons, mx, my)
        if b and b.on_tap then b.on_tap() end
    end
    self.on_event = function(s, ev)
        if ev[1] == "key" and ev[2] == keys.backspace then pop() end
        if ev[1] == "char" and ev[2]:match("[%d]") then
            if valueRef.value == "0" then valueRef.value = ev[2]
            else valueRef.value = valueRef.value .. ev[2] end
            s:render()
        end
    end
    return self
end

----------------------------------------------------------------------
-- COORD — 3-step (X, Y, Z) entry for manual P1 / P2
----------------------------------------------------------------------

screenCoord = function(opts)
    local axis = "x"
    local result = {
        x = opts.initial and opts.initial.x or 0,
        y = opts.initial and opts.initial.y or 64,
        z = opts.initial and opts.initial.z or 0,
    }
    local valueRef = { value = tostring(result[axis]) }

    local self = { kind = "coord", buttons = {} }

    local function nextAxis(s)
        if axis == "x" then
            axis = "y"; valueRef.value = tostring(result.y); s:render()
        elseif axis == "y" then
            axis = "z"; valueRef.value = tostring(result.z); s:render()
        else
            opts.ok(result)
            pop()
        end
    end

    self.render = function(s)
        clear(colors.black)
        title((opts.title or "Coord") .. " " .. axis:upper(), true)
        s.buttons = {}
        addBackButton(s.buttons, function() pop() end)

        local ctx = gdi.screen()
        ctx:drawText(1, 3,
            string.format(" X=%d  Y=%d  Z=%d",
                result.x, result.y, result.z):sub(1, W),
            colors.lightGray, colors.black)

        drawNumKeypad(s, valueRef, function(newVal, done)
            if done then
                result[axis] = tonumber(newVal) or 0
                nextAxis(s)
            else
                s:render()
            end
        end, {
            y0 = 7,
            doneLabel = function(n)
                if axis == "z" then return "DONE (" .. n .. ")"
                else return "NEXT > " .. (axis == "x" and "Y" or "Z") .. " (" .. n .. ")"
                end
            end,
        })

        paintFlash()
    end
    self.on_tap = function(s, mx, my)
        local b = hitButton(s.buttons, mx, my)
        if b and b.on_tap then b.on_tap() end
    end
    self.on_event = function(s, ev)
        if ev[1] == "key" and ev[2] == keys.backspace then pop() end
        if ev[1] == "char" and ev[2]:match("[%d]") then
            if valueRef.value == "0" then valueRef.value = ev[2]
            else valueRef.value = valueRef.value .. ev[2] end
            s:render()
        end
    end
    return self
end

----------------------------------------------------------------------
-- NAME
----------------------------------------------------------------------

screenName = function(opts)
    return {
        kind = "name",
        buttons = {},
        render = function(s)
            clear(colors.black)
            title("New selection", true)
            s.buttons = {}
            addBackButton(s.buttons, function() pop() end)

            local ctx = gdi.screen()
            ctx:drawText(1, 3, "Name:", colors.white, colors.black)
            ctx:fillRect(1, 5, W, 1, colors.lightGray)

            stdio.setColor(colors.black, colors.lightGray)
            stdio.setCursor(1, 5)
            local name = stdio.read(nil, nil, nil, "kvas")
            stdio.setColor(colors.white, colors.black)
            if name and name ~= "" then
                local sel = sels.new({ name = name, owner = "pocket" })
                sel:save(); sels.setActive(sel.id)
                app.selId = sel.id
                replace(screenDetail())
            else
                pop()
            end
        end,
        on_tap = function() end,
        on_event = function() end,
    }
end

----------------------------------------------------------------------
-- CONFIRM
----------------------------------------------------------------------

screenConfirm = function(opts)
    return {
        kind = "confirm",
        buttons = {},
        render = function(s)
            clear(colors.black)
            title("Confirm", true)
            s.buttons = {}
            addBackButton(s.buttons, function() pop() end)

            local ctx = gdi.screen()
            ctx:drawText(1, 4, opts.prompt or "Sure?", colors.white, colors.black)

            local yes = makeButton("YES", 1, H - 6, W, 3,
                { bg = colors.red, fg = colors.white,
                  on_tap = function() pop(); if opts.ok then opts.ok() end end })
            local no  = makeButton("NO",  1, H - 3, W, 3,
                { bg = colors.gray, fg = colors.white,
                  on_tap = function() pop() end })
            table.insert(s.buttons, yes); drawButton(yes)
            table.insert(s.buttons, no);  drawButton(no)
            paintFlash()
        end,
        on_tap = function(s, mx, my)
            local b = hitButton(s.buttons, mx, my)
            if b and b.on_tap then b.on_tap() end
        end,
        on_event = function(s, ev)
            if ev[1] == "key" and ev[2] == keys.backspace then pop() end
        end,
    }
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------

push(screenList())

local function render() local s = top(); if s then s:render() end end

local SYNC_INTERVAL = 5
local syncTimer = nil

local function syncFromDispatcher()
    local rpc = unison and unison.rpc; if not rpc then return end
    local did = dispatcherId(); if not did then return end
    local ok, reply = pcall(rpc.send, did, { type = "selection_list" })
    if not (ok and reply and type(reply) == "table") then return end
    local list = reply.selections or (reply.msg and reply.msg.selections)
    if type(list) ~= "table" then return end
    for _, t in ipairs(list) do
        if t.id then
            local local_ = sels.load(t.id)
            if local_ and local_.state ~= t.state then
                local_.state = t.state; local_:save()
            end
        end
    end
end

refreshLiveGps()

if unison and unison.rpc and unison.rpc.subscribe then
    unison.rpc.subscribe("dispatcher_announce", function() end)
end

render()
gpsTimer  = os.startTimer(GPS_POLL_INTERVAL)
syncTimer = os.startTimer(SYNC_INTERVAL)

while app.running do
    local ev = { os.pullEventRaw() }
    if ev[1] == "terminate" then break end
    local s = top(); if not s then break end

    if ev[1] == "timer" and ev[2] == gpsTimer then
        refreshLiveGps()
        gpsTimer = os.startTimer(GPS_POLL_INTERVAL)
        render()
    elseif ev[1] == "timer" and ev[2] == syncTimer then
        pcall(syncFromDispatcher)
        syncTimer = os.startTimer(SYNC_INTERVAL)
        render()
    elseif ev[1] == "mouse_click" or ev[1] == "monitor_touch" then
        local mx, my = ev[3], ev[4]
        if s.on_tap then s:on_tap(mx, my) end
        render()
    elseif ev[1] == "mouse_up" then
        -- ignore
    else
        if s.on_event then s:on_event(ev) end
        render()
    end
end

clear(colors.black)
stdio.setCursor(1, 1)
stdio.setColor(colors.white, colors.black)
stdio.print("surveyor: bye.")
