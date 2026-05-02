-- surveyor 1.0.0 — phone-form-factor selection editor.
--
-- Designed for the CC pocket computer (26 cells wide × 20 cells tall,
-- portrait). Every screen is a single-column stacked layout: title at
-- top, scrollable body, fat tappable buttons at the bottom. No
-- horizontal tables, no fine-grained controls — every button is at
-- least 3 cells tall so it's hittable on a touchscreen.
--
-- Data model:
--   * unison.lib.selection — Volume + Selection + persistence
--   * unison.lib.gps       — read player position
--   * unison.lib.home      — (later) for distance estimates
-- Backend is local for now (selections.json on the pocket itself).
-- A future commit wires the dispatcher RPC so the same selection
-- reaches a turtle.
--
-- Screens (one at a time):
--   LIST       — list saved selections + [+ NEW] button
--   DETAIL     — chosen selection's info + action buttons
--   AXIS       — axis picker (six buttons: +X -X +Y -Y +Z -Z)
--   NUM        — numeric input for delta / slice n
--   NAME       — text input for selection name
--   CONFIRM    — generic yes/no
-- A small router keeps a stack so back-button is trivial.

local sels = unison and unison.lib and unison.lib.selection
local gpsLib = unison and unison.lib and unison.lib.gps
local stdio = unison and unison.stdio
local gdi   = unison and unison.gdi

if not (sels and stdio and gdi) then
    if printError then printError("surveyor: missing unison.lib.selection / stdio / gdi") end
    return
end

----------------------------------------------------------------------
-- Layout helpers
----------------------------------------------------------------------

local W, H = stdio.size()       -- pocket: 26x20
local TITLE_H, FOOT_H = 1, 0    -- title bar; footer = sum of bottom buttons

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

local function title(text)
    bar(1, " " .. text, colors.white, colors.blue)
end

-- A fat button. Returns the rect {x,y,w,h, fg, bg, label, on_tap}.
-- Buttons are stored on the current screen and tested against taps.
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
        -- centred horizontally, middle row
        local s = b.label
        if #s > b.w - 2 then s = s:sub(1, b.w - 2) end
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

----------------------------------------------------------------------
-- GPS helpers
----------------------------------------------------------------------

local function readGps()
    if not gpsLib then return nil, "no gps lib" end
    local x, y, z, src = gpsLib.locate("self", { timeout = 2 })
    if not x then return nil, "no fix" end
    return { x = math.floor(x + 0.5),
             y = math.floor(y + 0.5),
             z = math.floor(z + 0.5),
             src = src }
end

----------------------------------------------------------------------
-- App state + navigation stack
----------------------------------------------------------------------

local app = {
    running   = true,
    stack     = {},      -- screen objects (top is current)
    selId     = nil,     -- active selection id (DETAIL screen + ops)
    pending   = nil,     -- temporary state for multi-step ops (axis+delta)
    flash     = nil,     -- last status message
    flash_ts  = 0,
}

local function flash(msg) app.flash = msg; app.flash_ts = os.epoch and os.epoch("utc") or 0 end

local function push(screen) app.stack[#app.stack + 1] = screen end
local function pop()
    if #app.stack > 1 then app.stack[#app.stack] = nil end
end
local function replace(screen) app.stack[#app.stack] = screen end
local function top() return app.stack[#app.stack] end

----------------------------------------------------------------------
-- Common: paint flash + body wrapper
----------------------------------------------------------------------

local function paintFlash()
    if not app.flash then return end
    local now = os.epoch and os.epoch("utc") or 0
    if (now - (app.flash_ts or 0)) > 4000 then app.flash = nil; return end
    bar(H, " " .. app.flash, colors.yellow, colors.black)
end

----------------------------------------------------------------------
-- LIST screen
----------------------------------------------------------------------

local screenList, screenDetail, screenAxis, screenNum, screenName, screenConfirm

screenList = function()
    local rows = sels.list()
    local activeId = sels.activeId()

    return {
        kind = "list",
        offset = 0,
        rows = rows,
        activeId = activeId,
        buttons = {},

        render = function(self)
            clear(colors.black)
            title("Selections (" .. #self.rows .. ")")

            -- Body: rows of "name [state] WxHxD" each ~ 3 cells tall.
            local rowH = 3
            local bodyTop = 3
            local bodyBottom = H - 4         -- leave 4 cells for + NEW
            local maxVisible = math.floor((bodyBottom - bodyTop + 1) / rowH)
            self.buttons = {}
            local ctx = gdi.screen()

            if #self.rows == 0 then
                ctx:drawText(2, bodyTop + 1, "(no selections)", colors.lightGray, colors.black)
                ctx:drawText(2, bodyTop + 3, "tap [+ NEW] below.", colors.lightGray, colors.black)
            else
                for i = 1, math.min(maxVisible, #self.rows - self.offset) do
                    local sel = self.rows[i + self.offset]
                    local s = sel:summary()
                    local y = bodyTop + (i - 1) * rowH
                    local active = sel.id == self.activeId
                    local bg = active and colors.gray or colors.lightGray
                    local fg = active and colors.white or colors.black
                    ctx:fillRect(1, y, W, rowH - 1, bg)
                    ctx:drawText(2, y,     ((s.name or ""):sub(1, W - 2)), fg, bg)
                    ctx:drawText(2, y + 1, ("[" .. s.state .. "]" ..
                        (s.dimensions and string.format(" %dx%dx%d",
                            s.dimensions[1], s.dimensions[2], s.dimensions[3]) or "")),
                        fg, bg)
                    table.insert(self.buttons, {
                        x = 1, y = y, w = W, h = rowH - 1,
                        kind = "row", id = sel.id,
                    })
                end
            end

            -- Bottom: + NEW (full-width fat button).
            local b = makeButton("+ NEW", 1, H - 3, W, 3,
                { bg = colors.green, fg = colors.white,
                  on_tap = function() push(screenName({ purpose = "new" })) end })
            table.insert(self.buttons, b)
            drawButton(b)

            paintFlash()
        end,

        on_tap = function(self, mx, my)
            local b = hitButton(self.buttons, mx, my)
            if not b then return end
            if b.kind == "row" then
                sels.setActive(b.id)
                app.selId = b.id
                push(screenDetail())
                return
            end
            if b.on_tap then b.on_tap() end
        end,

        on_event = function(self, ev)
            if ev[1] == "key" and ev[2] == keys.q then app.running = false end
        end,
    }
end

----------------------------------------------------------------------
-- DETAIL screen — actions for the active selection
----------------------------------------------------------------------

local function fmtPoint(p) return p and string.format("%d,%d,%d", p.x, p.y, p.z) or "—" end

screenDetail = function()
    return {
        kind = "detail",
        buttons = {},

        render = function(self)
            clear(colors.black)
            local sel = sels.load(app.selId)
            if not sel then pop(); return end
            local s = sel:summary()
            title(((s.name or ""):sub(1, W - 6)) .. "  ←")
            self.buttons = {}

            -- Top "back" hit-zone over the title text.
            table.insert(self.buttons, {
                x = W - 3, y = 1, w = 4, h = 1,
                kind = "back",
                on_tap = function() pop() end,
            })

            local ctx = gdi.screen()
            local y = 3
            ctx:drawText(1, y, "state: " .. s.state, colors.white, colors.black);  y = y + 1
            ctx:drawText(1, y, "p1:  " .. fmtPoint(sel.p1), colors.lightGray, colors.black); y = y + 1
            ctx:drawText(1, y, "p2:  " .. fmtPoint(sel.p2), colors.lightGray, colors.black); y = y + 1
            if s.volume then
                ctx:drawText(1, y, string.format("dim: %dx%dx%d",
                    s.dimensions[1], s.dimensions[2], s.dimensions[3]),
                    colors.white, colors.black); y = y + 1
                ctx:drawText(1, y, "blocks: " .. tostring(s.blocks),
                    colors.yellow, colors.black); y = y + 1
            else
                ctx:drawText(1, y, "(volume incomplete)", colors.orange, colors.black); y = y + 1
            end

            -- Action grid: 2 columns × 4 rows of fat buttons. Each
            -- button is 12 wide × 3 tall, fits under the body.
            local actY = 9
            local mkRow = function(row, b1, b2)
                table.insert(self.buttons, b1); drawButton(b1)
                if b2 then table.insert(self.buttons, b2); drawButton(b2) end
            end

            mkRow(0,
                makeButton("P1 HERE", 1, actY, 13, 3,
                    { bg = colors.cyan, fg = colors.black,
                      on_tap = function()
                          local p, err = readGps()
                          if not p then flash("gps: " .. tostring(err)); return end
                          sel:setP1(p); sel:save(); flash("p1 set")
                      end }),
                makeButton("P2 HERE", 14, actY, 13, 3,
                    { bg = colors.cyan, fg = colors.black,
                      on_tap = function()
                          local p, err = readGps()
                          if not p then flash("gps: " .. tostring(err)); return end
                          sel:setP2(p); sel:save(); flash("p2 set")
                      end })
            )
            mkRow(1,
                makeButton("EXPAND", 1, actY + 3, 13, 3,
                    { bg = colors.lime, fg = colors.black,
                      on_tap = function()
                          app.pending = { op = "expand", selId = sel.id }
                          push(screenAxis({ next = "num" }))
                      end }),
                makeButton("CONTRACT", 14, actY + 3, 13, 3,
                    { bg = colors.orange, fg = colors.black,
                      on_tap = function()
                          app.pending = { op = "contract", selId = sel.id }
                          push(screenAxis({ next = "num" }))
                      end })
            )
            mkRow(2,
                makeButton("SLICE", 1, actY + 6, 13, 3,
                    { bg = colors.purple, fg = colors.white,
                      on_tap = function()
                          app.pending = { op = "slice", selId = sel.id }
                          push(screenAxis({ next = "num" }))
                      end }),
                makeButton("QUEUE", 14, actY + 6, 13, 3,
                    { bg = colors.green, fg = colors.white,
                      on_tap = function()
                          if not sel.volume then flash("set p1+p2 first"); return end
                          sel:queue(); sel:save(); flash("queued")
                      end })
            )

            -- Bottom: dangerous actions on a separate row.
            mkRow(3,
                makeButton("CANCEL", 1, H - 3, 13, 3,
                    { bg = colors.gray, fg = colors.white,
                      on_tap = function()
                          sel:cancel(); sel:save(); flash("cancelled")
                      end }),
                makeButton("DELETE", 14, H - 3, 13, 3,
                    { bg = colors.red, fg = colors.white,
                      on_tap = function()
                          push(screenConfirm({
                              prompt = "Delete?",
                              ok = function()
                                  sel:remove(); pop(); pop()
                                  flash("deleted")
                              end,
                          }))
                      end })
            )

            paintFlash()
        end,

        on_tap = function(self, mx, my)
            local b = hitButton(self.buttons, mx, my)
            if b and b.on_tap then b.on_tap() end
        end,

        on_event = function(self, ev)
            if ev[1] == "key" then
                if ev[2] == keys.backspace then pop() end
                if ev[2] == keys.q then app.running = false end
            end
        end,
    }
end

----------------------------------------------------------------------
-- AXIS picker — six fat buttons in a 2x3 grid: +X +Y +Z / -X -Y -Z
----------------------------------------------------------------------

screenAxis = function(opts)
    return {
        kind = "axis",
        buttons = {},
        render = function(self)
            clear(colors.black)
            title("Axis  ←")
            self.buttons = {}
            table.insert(self.buttons, { x = W - 3, y = 1, w = 4, h = 1, on_tap = function() pop() end })

            local labels = { "+X", "+Y", "+Z", "-X", "-Y", "-Z" }
            local axes   = { "+x", "+y", "+z", "-x", "-y", "-z" }
            local colsW = math.floor(W / 3)
            local rowH  = 5
            for i, lab in ipairs(labels) do
                local row = math.floor((i - 1) / 3)
                local col = (i - 1) % 3
                local bg = (i <= 3) and colors.lime or colors.orange
                local fg = colors.black
                local b = makeButton(lab,
                    1 + col * colsW, 4 + row * rowH,
                    colsW, rowH,
                    { bg = bg, fg = fg,
                      on_tap = function()
                          app.pending.axis = axes[i]
                          if opts.next == "num" then
                              replace(screenNum({
                                  prompt = (app.pending.op or "delta") .. " " .. axes[i],
                                  default = (app.pending.op == "slice") and 1 or 5,
                              }))
                          else pop() end
                      end })
                table.insert(self.buttons, b); drawButton(b)
            end
            paintFlash()
        end,
        on_tap = function(self, mx, my)
            local b = hitButton(self.buttons, mx, my)
            if b and b.on_tap then b.on_tap() end
        end,
        on_event = function(self, ev)
            if ev[1] == "key" and ev[2] == keys.backspace then pop() end
        end,
    }
end

----------------------------------------------------------------------
-- NUM input — integer with +/- and 0..9 keys, big DONE button.
----------------------------------------------------------------------

screenNum = function(opts)
    local value = tostring(opts.default or 1)
    local self = {
        kind = "num",
        buttons = {},
    }
    self.render = function(self)
        clear(colors.black)
        title((opts.prompt or "value") .. "  ←")
        self.buttons = {}
        table.insert(self.buttons, { x = W - 3, y = 1, w = 4, h = 1, on_tap = function() pop() end })

        -- Display.
        local ctx = gdi.screen()
        ctx:fillRect(1, 3, W, 3, colors.lightGray)
        local s = value
        if #s > W - 2 then s = s:sub(-W + 2) end
        ctx:drawText(W - #s, 4, s, colors.black, colors.lightGray)

        -- Numeric keypad: 3x4 (0..9, +/-, BS).
        local keys_ = {
            "1","2","3",
            "4","5","6",
            "7","8","9",
            "+/-","0","BS",
        }
        local kw = math.floor(W / 3); local kh = 3
        for i, label in ipairs(keys_) do
            local r = math.floor((i - 1) / 3)
            local c = (i - 1) % 3
            local b = makeButton(label,
                1 + c * kw, 7 + r * kh, kw, kh,
                { bg = colors.gray, fg = colors.white,
                  on_tap = function()
                      if label == "BS" then
                          value = value:sub(1, -2); if value == "" or value == "-" then value = "0" end
                      elseif label == "+/-" then
                          if value:sub(1, 1) == "-" then value = value:sub(2)
                          elseif value ~= "0" then value = "-" .. value end
                      else
                          if value == "0" then value = label
                          else value = value .. label end
                      end
                  end })
            table.insert(self.buttons, b); drawButton(b)
        end

        -- DONE.
        local n = tonumber(value) or 0
        local done = makeButton("DONE (" .. tostring(n) .. ")", 1, H - 3, W, 3,
            { bg = colors.green, fg = colors.white,
              on_tap = function()
                  local sel = sels.load(app.pending.selId)
                  if not sel then flash("selection gone"); pop(); return end
                  local op = app.pending.op
                  if op == "expand"   then sel:expand(app.pending.axis, n)
                  elseif op == "contract" then sel:contract(app.pending.axis, n)
                  elseif op == "slice"    then sel:slice(app.pending.axis, n)
                  end
                  sel:save()
                  app.pending = nil
                  pop()  -- pop NUM, return to DETAIL
                  flash(op .. " " .. tostring(n))
              end })
        table.insert(self.buttons, done); drawButton(done)

        paintFlash()
    end
    self.on_tap = function(self, mx, my)
        local b = hitButton(self.buttons, mx, my)
        if b and b.on_tap then b.on_tap() end
    end
    self.on_event = function(self, ev)
        if ev[1] == "key" and ev[2] == keys.backspace then pop() end
        if ev[1] == "char" and ev[2]:match("[%d]") then
            if value == "0" then value = ev[2] else value = value .. ev[2] end
        end
    end
    return self
end

----------------------------------------------------------------------
-- NAME input — uses CC `read()` because pocket has a keyboard.
----------------------------------------------------------------------

screenName = function(opts)
    return {
        kind = "name",
        buttons = {},
        render = function(self)
            clear(colors.black)
            title("New selection  ←")
            self.buttons = {}
            table.insert(self.buttons, { x = W - 3, y = 1, w = 4, h = 1, on_tap = function() pop() end })

            local ctx = gdi.screen()
            ctx:drawText(1, 3, "Name:", colors.white, colors.black)
            ctx:fillRect(1, 5, W, 1, colors.lightGray)

            -- Block out an interactive read prompt right here. We
            -- exit the render loop and do the read inline; once the
            -- user hits enter we resume.
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
-- CONFIRM dialog
----------------------------------------------------------------------

screenConfirm = function(opts)
    return {
        kind = "confirm",
        buttons = {},
        render = function(self)
            clear(colors.black)
            title("Confirm")
            local ctx = gdi.screen()
            ctx:drawText(1, 4, opts.prompt or "Sure?", colors.white, colors.black)

            self.buttons = {}
            local yes = makeButton("YES", 1, H - 6, W, 3,
                { bg = colors.red, fg = colors.white,
                  on_tap = function()
                      pop()
                      if opts.ok then opts.ok() end
                  end })
            local no  = makeButton("NO",  1, H - 3, W, 3,
                { bg = colors.gray, fg = colors.white,
                  on_tap = function() pop() end })
            table.insert(self.buttons, yes); drawButton(yes)
            table.insert(self.buttons, no);  drawButton(no)
            paintFlash()
        end,
        on_tap = function(self, mx, my)
            local b = hitButton(self.buttons, mx, my)
            if b and b.on_tap then b.on_tap() end
        end,
        on_event = function(self, ev)
            if ev[1] == "key" and ev[2] == keys.backspace then pop() end
        end,
    }
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------

push(screenList())

local function render() local s = top(); if s then s:render() end end

render()
while app.running do
    local ev = { os.pullEventRaw() }
    if ev[1] == "terminate" then break end
    local s = top(); if not s then break end

    if ev[1] == "mouse_click" or ev[1] == "monitor_touch" then
        local mx, my = ev[3], ev[4]
        if s.on_tap then s:on_tap(mx, my) end
    elseif ev[1] == "mouse_up" then
        -- ignore
    else
        if s.on_event then s:on_event(ev) end
    end
    render()
end

clear(colors.black)
stdio.setCursor(1, 1)
stdio.setColor(colors.white, colors.black)
stdio.print("surveyor: bye.")
