-- Shift+click a row on the Work Details screen to toggle a whole run of dwarves at once.
--@module = true
--[[
fort/multiple-laborers

The Work Details screen assigns one dwarf per click. This adds the shift+click every list
has had since 1984: click one row, shift+click another, and every row between them (both
ends included) is toggled together. If all of them already have the detail, all of them
lose it; otherwise all of them get it. The plain click is still DF's.

    click Dastot, shift+click Edem   -> Dastot, Zuglar, Mebzuth, Inod, Dumed, Edem
                                        all become miners (or, if they all already
                                        were, all stop)

An overlay; on by default.

HOW IT WORKS, AND WHY THE TICK ON THE RIGHT IS DRAWN HERE
  The anchor is the list's own cursor (`widget_unit_list.cursor_idx`), which DF moves to
  whatever row you last clicked -- so "click one, shift+click another" needs no state of
  its own. The rows are read from the widget tree (`dfhack.gui.getWidget`): each row is a
  container whose portrait/name children carry the unit, in DISPLAY order, which is the
  order that `cursor_idx` counts in. (`entry_list` is a different, internal order, and
  indexing it with a display index names the wrong dwarf.)

  Assignment is written to the data DF reads, exactly as its own click does:
  `work_detail.assigned_units` plus `dfhack.units.setAutomaticProfessions`, so the labor
  takes effect at once. DF then redraws the little detail icons on the left of the row from
  that data -- but NOT the Selected button on the right: that sprite is baked into the row
  widget when the row is built and only DF's own click repaints it. So the rows this script
  toggled (those and no others) get their button repainted here every frame, from the data,
  with DF's own art: the on and off sprites are copied off rows DF built, so whatever tileset
  is in play draws the tick. In ASCII, or before both sprites have been seen, a text [X]
  stands in. Reopening the tab or switching detail rebuilds DF's rows, and the repainting
  stops with them.

  The selected detail is `widget_radio_rows.selected_idx` on the Details list, checked
  against the name in the header text box so a stale index cannot pick a different detail.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

-- ---- the widgets -------------------------------------------------------------------------

local function labor_ui() return df.global.game.main_interface.info.labor end

-- Work Details tab: labor -> Tabs -> Work Details
local function work_details_tab()
    local ok, w = pcall(dfhack.gui.getWidget, labor_ui(), 0, 0)
    return ok and w or nil
end

-- the Details radio list (left), the unit list and its row container (right)
local function lists()
    local tab = work_details_tab()
    if not tab then return end
    local ok, radio = pcall(dfhack.gui.getWidget, tab, 'Details')
    local ok2, ul = pcall(dfhack.gui.getWidget, tab, 'Right panel', 0, 3)
    if not ok or not ok2 or not radio or not ul or not df.widget_unit_list:is_instance(ul) then return end
    local ok3, rows = pcall(dfhack.gui.getWidget, ul, 'Unit List', 1)
    if not ok3 or not rows or not df.widget_scroll_rows:is_instance(rows) then return end
    return radio, ul, rows
end

-- the name DF shows in the header text box (Right panel -> container -> textbox)
local function header_name()
    local tab = work_details_tab()
    if not tab then return end
    local ok, box = pcall(dfhack.gui.getWidget, tab, 'Right panel', 0, 0)
    if ok and box then
        local ok2, s = pcall(function() return box.str end)
        if ok2 and type(s) == 'string' then return s end
    end
end

-- the work detail the screen is editing, or nil
function selected_detail()
    local radio = lists()
    if not radio then return end
    local wd = df.global.plotinfo.labor_info.work_details
    local idx = radio.selected_idx
    local name = header_name()
    if idx >= 0 and idx < #wd and (not name or wd[idx].name == name) then return wd[idx] end
    if name then                                   -- index and name disagree: the name wins
        for i = 0, #wd - 1 do if wd[i].name == name then return wd[i] end end
    end
end

local function row_unit(row)
    local ok, n = pcall(function() return #row.children end)
    if not ok then return end
    for i = 0, n - 1 do
        local ok2, c = pcall(dfhack.gui.getWidget, row, i)
        if ok2 and c then
            local ok3, u = pcall(function() return c.u end)
            if ok3 and u and df.unit:is_instance(u) then return u end
        end
    end
end

-- the row widget at display index i, if DF has built it
local function row_at(rows, i)
    if i < 0 or i >= #rows.children then return end
    local ok, row = pcall(dfhack.gui.getWidget, rows, i)
    return ok and row or nil
end

touched = touched or {}                          -- rows this script changed; see the overlay

-- ---- assignment ----------------------------------------------------------------------------

local function is_assigned(detail, unit)
    for _, id in ipairs(detail.assigned_units) do if id == unit.id then return true end end
    return false
end

local function set_assigned(detail, unit, on)
    if on then
        if not is_assigned(detail, unit) then detail.assigned_units:insert('#', unit.id) end
    else
        for i = #detail.assigned_units - 1, 0, -1 do
            if detail.assigned_units[i] == unit.id then detail.assigned_units:erase(i) end
        end
    end
    -- DF only applies a detail when its screen is clicked; this is what the click calls
    pcall(dfhack.units.setAutomaticProfessions, unit)
end

-- toggle rows a..b (display indices, either order) on the selected detail.
-- Returns how many were touched and whether they went on.
function toggle_range(a, b)
    local detail = selected_detail()
    local radio, ul, rows = lists()
    if not detail or not rows then return 0 end
    local lo, hi = math.min(a, b), math.max(a, b)
    local units, urows = {}, {}
    for i = lo, hi do
        local row = row_at(rows, i)
        local u = row and row_unit(row)
        if u then units[#units + 1] = u; urows[#urows + 1] = row end
    end
    if #units == 0 then return 0 end
    local all_on = true
    for _, u in ipairs(units) do if not is_assigned(detail, u) then all_on = false break end end
    for k, u in ipairs(units) do
        set_assigned(detail, u, not all_on)
        local _, a = df.sizeof(urows[k])
        touched[a] = {unit_id = u.id, detail = detail.name}   -- its button is ours to draw now
    end
    return #units, not all_on
end

-- ---- the overlay --------------------------------------------------------------------------

local ROW_H = 3                                  -- every unit row is three cells tall

MultipleLaborers = defclass(MultipleLaborers, overlay.OverlayWidget)
MultipleLaborers.ATTRS{
    desc = 'Shift+click on the Work Details screen toggles every row between the last click and this one.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/LABOR/WORK_DETAILS',
    frame = {w = 1, h = 1},                        -- invisible; input and painting are screen-wide
    version = 1,
}

local PEN_ON  = dfhack.pen.parse{fg = COLOR_LIGHTGREEN, bg = COLOR_BLACK, bold = true}
local PEN_OFF = dfhack.pen.parse{fg = COLOR_DARKGREY, bg = COLOR_BLACK}
local PEN_BG  = dfhack.pen.parse{fg = COLOR_BLACK, bg = COLOR_BLACK, ch = string.byte(' ')}

-- THE ROWS THIS SCRIPT CHANGED, and nothing else, get their button repainted. DF's own
-- clicks keep their button current, and a row that was never touched from here shows the
-- truth already; painting over every row would only replace DF's art with a copy of it.
-- Keyed by the row widget's address: if DF rebuilds the rows (reopening the tab, switching
-- detail) the addresses change and the stale entries simply stop matching.
--   touched[addr] = {unit_id=, detail=}
local last_frame = nil                           -- to notice the screen being left
local last_detail = nil

-- the button art, LEARNED from rows DF built: a row nobody has touched from here was built
-- with its button matching the data, so its sprite is the sprite for that state. Both
-- texpos layers make up the button (the plate on _lower, the mark on top); 4x3 cells each,
-- stored relative to the button's corner.
--   sprites[true|false] = {{dx=,dy=,top=,lower=}, ...}
local sprites = {}

local function addr_of(obj)
    local _, a = df.sizeof(obj)
    return a
end

-- the rows DF is drawing right now: {idx, row, unit, y1, y2}. A row is on screen when its
-- rectangle sits where the scroll position says it should; rows that scrolled off keep the
-- rectangle they last had, so the position is checked and not just the index.
local function visible_rows(rows)
    local out = {}
    local top, bottom = rows.rect.y1, rows.rect.y2
    for i = rows.scroll, rows.scroll + rows.num_visible + 1 do
        local row = row_at(rows, i)
        if not row then break end
        local y1, y2 = row.rect.y1, row.rect.y2
        if y1 == top + ROW_H * (i - rows.scroll) and y2 <= bottom then
            local u = row_unit(row)
            if u then out[#out + 1] = {idx = i, row = row, unit = u, y1 = y1, y2 = y2} end
        end
    end
    return out
end

-- the Selected button of a row: the child DF names 'Selected'; its rectangle is the button
local function button_rect(row)
    local ok, b = pcall(dfhack.gui.getWidget, row, 'Selected')
    if ok and b then return b.rect end
end

local function cell_index(x, y) return x * df.global.gps.dimy + y end

local function learn_sprite(r, on)
    local gps = df.global.gps
    local cells = {}
    for y = r.y1, r.y2 do
        for x = r.x1, r.x2 do
            local i = cell_index(x, y)
            cells[#cells + 1] = {dx = x - r.x1, dy = y - r.y1,
                                 top = gps.screentexpos[i], lower = gps.screentexpos_lower[i]}
        end
    end
    -- an all-zero block is not a button (ASCII mode, or a frame DF has not drawn yet)
    for _, c in ipairs(cells) do if c.top ~= 0 or c.lower ~= 0 then sprites[on] = cells return end end
end

local function paint_button(r, on)
    local art = sprites[on]
    if art and dfhack.screen.inGraphicsMode() then
        local gps = df.global.gps
        for _, c in ipairs(art) do
            local i = cell_index(r.x1 + c.dx, r.y1 + c.dy)
            gps.screentexpos[i], gps.screentexpos_lower[i] = c.top, c.lower
        end
        return
    end
    -- no art to copy yet: a plain text box says the same thing
    for y = r.y1, r.y2 do
        for x = r.x1, r.x2 do dfhack.screen.paintTile(PEN_BG, x, y) end
    end
    local cx, cy = (r.x1 + r.x2) // 2, (r.y1 + r.y2) // 2
    dfhack.screen.paintString(on and PEN_ON or PEN_OFF, cx - 1, cy, on and '[X]' or '[ ]')
end

function MultipleLaborers:render(dc)
    local detail = selected_detail()
    local radio, ul, rows = lists()
    if not detail or not rows then return end
    -- leaving the screen, or switching detail, rebuilds the rows: forget what was touched
    local now = dfhack.getTickCount()
    if (last_frame and now - last_frame > 1000) or last_detail ~= detail.name then touched = {} end
    last_frame, last_detail = now, detail.name
    local _, my = dfhack.screen.getMousePos()
    for _, v in ipairs(visible_rows(rows)) do
        local r = button_rect(v.row)
        if r then
            local on = is_assigned(detail, v.unit)
            local t = touched[addr_of(v.row)]
            if t and t.unit_id == v.unit.id then
                paint_button(r, on)
            elseif not sprites[on] and not (my and my >= v.y1 and my <= v.y2) then
                learn_sprite(r, on)                -- never from the row under the mouse: hover art
            end
        end
    end
end

function MultipleLaborers:onInput(keys)
    if not keys._MOUSE_L then return false end
    if not dfhack.internal.getModifiers().shift then return false end
    local radio, ul, rows = lists()
    if not rows then return false end
    local mx, my = dfhack.screen.getMousePos()
    if not mx then return false end
    local hit
    for _, v in ipairs(visible_rows(rows)) do
        if my >= v.y1 and my <= v.y2 and mx >= rows.rect.x1 and mx <= rows.rect.x2 then hit = v break end
    end
    if not hit then return false end
    local anchor = ul.cursor_idx
    if anchor < 0 or anchor >= #rows.children then anchor = hit.idx end
    local n, on = toggle_range(anchor, hit.idx)
    ul.cursor_idx = hit.idx                        -- the next shift+click ranges from here
    if n > 0 then
        local detail = selected_detail()
        dfhack.gui.showAnnouncement(('%d %s %s "%s"'):format(n, n == 1 and 'dwarf' or 'dwarves',
            on and 'added to' or 'removed from', detail and detail.name or '?'), COLOR_WHITE, false)
    end
    return true
end

OVERLAY_WIDGETS = {shift_click = MultipleLaborers}

if dfhack_flags and dfhack_flags.module then return end
print('fort/multiple-laborers is an overlay: shift+click rows on the Work Details screen.')
