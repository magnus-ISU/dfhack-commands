-- Expand the item-description box on the item view sheet to use the empty vertical space.
--@ module = true
--[[
item-description

DF's item view sheet (dwarfmode/ViewSheets/ITEM) renders an item's description in a short,
fixed ~8-row box. Long descriptions -- artifacts, finely-decorated items, figurines, books,
engraved slabs -- get truncated to a handful of lines while the rest of the panel sits
empty. This overlay redraws the full description in place, using up to HALF the screen
height before it needs to scroll.

HELD ITEMS (pedestal, display case, workshop, container, worn -- anything with a location
line) get a bigger rework, because the native sheet is a mess for them: fort/statue-
redirect's [Remove] button lands ON the first description row, and the native
"In <icon> <building>  [View]" line floats far below the description. For those items
this overlay rebuilds the block:

    row D     [Remove]              <- statue-redirect's button, line cleared of text
    row D+2   In {icon} green Glass Pedestal   [View]   <- moved up from its native row
    row D+4+  the full description, scrollable (mouse wheel)

The location line is found GENERICALLY: any holder makes DF render the line with a
View-button pill in the lower texture layer, and the detector looks for that pill run --
no wording or holder-type enumeration, so new holder cases work unseen. If an item has a
holder but no line renders, the line step is skipped and the description starts under the
cleared Remove row. Offsets, tuned live against DF's padding: the moved line sits 1
column right of the panel bound and one row lower; description text pads 2 columns.

The native In-line is erased in place (text blanked, View-button pill patched out of the
lower texture layer, the 5x3 anchored icon sprite zeroed) and re-drawn under the Remove
row; clicking the moved [View] teleports the click to the native button so DF handles it.
Items NOT on display (on the ground, built, worn...) keep the plain behavior: expand only
when the description is longer than DF's box, drawn by the widget frame as before.

Layer map, measured live on a pedestal'd artifact bed (2026-08):
  * View button = screentexpos_lower pill, TWO rows tall (the In-line row and the row
    below); the rest of those rows' lower layer is a uniform background band -- the
    band's first column is also the panel's left bound.
  * Pedestal icon = screentexpos_anchored 5-wide x 3-tall block centered on the In-line
    row, with per-tile offsets in screentexpos_anchored_x/_y (move all three arrays or
    the sprite shreds).
  * Text = the plain text grid (readTile/paintTile), pens copied so colors survive. TEXT
    and the lower layer are redrawn by DF every frame; the ANCHORED layer is NOT (it is
    stamped on open/interaction). So the pill and icon cells are CAPTURED into the
    geometry cache the first time they are seen and re-stamped from that cache every
    frame -- re-reading the live buffers finds them already zeroed/patched and the art
    would evaporate after the first rescan.
Widget render order is alphabetical: fort/item-description.expand draws BEFORE
fort/statue-redirect.remove, so clearing the Remove row here cannot erase that button.

It is a standard DFHack overlay (name: "item-description.expand"): toggle or reposition it
with `gui/overlay` if it doesn't line up with your UI scale. magnus-scripts loads it (via
overlay rescan) so it's on every session.
]]

local overlay = require('plugins.overlay')

-- DF shows roughly this many rows in its own box; the plain path only steps in past
-- that, and the display path uses it as the count of native rows to cover.
local DF_VISIBLE_ROWS = 8
local SPAN_W = 57            -- native description/panel column span to clear or fill
local SCAN_MS = 500          -- geometry rescan cadence in display mode
-- shifts from the panel's left bound, matching DF's own padding (tuned live):
-- the moved location line lands at the bound itself, the description pads 2
local LINE_SHIFT, TEXT_SHIFT = 0, 2
local SHIFT_Y = 1            -- the moved line sits one extra row down
local ICON_LIFT = 2          -- the icon sprite stamps this many rows above the line
-- painting starts one column PAST the left bound: the bound column carries the
-- panel's border art, and covering it visibly cuts the border
local BORDER_PAD = 1

ItemDescriptionOverlay = defclass(ItemDescriptionOverlay, overlay.OverlayWidget)
ItemDescriptionOverlay.ATTRS{
    -- x is a RIGHT-edge inset (negative pos anchors frame.r), so narrowing w
    -- moves only the LEFT edge; the right edge stays put
    default_pos = {x = -40, y = 12},
    viewscreens = 'dwarfmode/ViewSheets/ITEM',
    frame = {w = 55, h = 34},
}

-- the wrapped description lines DF computed for the current item, or nil if not applicable
local function desc_lines()
    local vs = df.global.game.main_interface.view_sheets
    if vs.active_sheet ~= df.view_sheet_type.ITEM then return nil, vs end
    return vs.description.text, vs
end

-- true if anything HOLDS the viewed item -- building (pedestal, case, workshop),
-- container item, or unit. Any of these makes DF render a location line, and the
-- rebuilt block applies; where exactly that line is comes from the generic
-- View-pill detector in find_geometry, not from the ref type.
local function has_holder(vs)
    local item = df.item.find(vs.active_id)
    if not item then return false end
    for _, ref in ipairs(item.general_refs) do
        local t = ref:getType()
        if t == df.general_ref_type.BUILDING_HOLDER
                or t == df.general_ref_type.CONTAINED_IN_ITEM
                or t == df.general_ref_type.UNIT_HOLDER then
            return true
        end
    end
    return false
end

local function read_row_text(y)
    local gps = df.global.gps
    if y < 0 or y >= gps.dimy then return '' end
    local row = {}
    for x = 0, gps.dimx - 1 do
        local t = dfhack.screen.readTile(x, y)
        local ch = t and t.ch or 0
        row[x + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(row)
end

-- ---- display (pedestal) mode ------------------------------------------------

-- geometry cache; rebuilt on item / window change and every SCAN_MS.
-- {key, remove_row, in_row, left, right, band, pill, icon}
--   remove_row = first native description row (statue-redirect's Remove sits there)
--   in_row     = native "In <building>" row, left/right = its lower-layer band extent
--   band[dy]   = per-row background texpos of the pill rows (dy = 0, 1)
--   pill       = {{dx, dy, val}, ...} lower-layer button cells (both rows)
--   icon       = {{dx, dy, val, ax, ay}, ...} anchored sprite cells (3 rows)
-- pill/icon are CAPTURED once (DF does not refresh the anchored layer, and we patch
-- the pill out of the live buffer) and re-stamped from here every frame. A rescan
-- keeps the previous capture when the live buffers no longer hold the art.
local geo = nil
local scan_at = 0

local function find_geometry(vs)
    local gps = df.global.gps
    local dimy = gps.dimy
    -- anchor: the "Weight:" row (always present); description starts 3 below it
    -- and the panel's left bound sits a fixed 7 columns left of the "W"
    local weight_row, wcol
    for y = 0, math.min(dimy - 1, 20) do
        local c = read_row_text(y):find('Weight:', 1, true)
        if c then weight_row, wcol = y, c - 1 break end
    end
    if not weight_row then return nil end
    local remove_row = weight_row + 3
    local left = math.max(0, wcol - 7)
    local right = math.min(gps.dimx - 1, left + SPAN_W + 8)
    local g = {
        key = ('%d:%d:%d'):format(vs.active_id, gps.dimx, dimy),
        remove_row = remove_row, left = left, right = right,
        band = {}, pill = {}, icon = {},
    }
    -- GENERIC location-line detector: whatever holds the item (pedestal, workshop,
    -- container...), DF renders its line with a View-button pill in the lower
    -- texture layer -- a run of cells differing from that row's background band.
    -- No wording assumptions ("In ...", "Worn by ..." -- all the same to this).
    local lower = gps.screentexpos_lower
    local pill_rows = {}
    for y = remove_row + 6, math.min(remove_row + 16, dimy - 1) do
        local band = lower[(left + 5) * dimy + y]
        local run, best = 0, 0
        for x = left, right do
            local v = lower[x * dimy + y]
            if v ~= 0 and v ~= band then run = run + 1 else run = 0 end
            if run > best then best = run end
        end
        if best >= 6 then pill_rows[#pill_rows + 1] = y end
    end
    -- the line row is the pill row that carries the text (its caps rows don't)
    local in_row
    for _, y in ipairs(pill_rows) do
        if read_row_text(y):sub(left + 1, left + SPAN_W):match('%S') then in_row = y break end
    end
    if in_row then
        g.in_row = in_row
        -- capture the pill (3 rows: caps above and below the text row). One cell
        -- is EXCLUDED at each side: the band's own end-cap/border tiles also
        -- differ from the band value, and capturing them moved the panel border
        -- up with the line (and left the source rows borderless).
        local cap_l, cap_r = left + 1, left + SPAN_W + TEXT_SHIFT - 1
        for dy = -1, 1 do
            local y = in_row + dy
            if y >= 0 and y < dimy then
                g.band[dy] = lower[(left + 5) * dimy + y]
                for x = cap_l, math.min(cap_r, right) do
                    local v = lower[x * dimy + y]
                    if v ~= 0 and v ~= g.band[dy] then
                        g.pill[#g.pill + 1] = {dx = x - left, dy = dy, val = v}
                    end
                end
            end
        end
        -- capture the anchored icon cells. Every cell renders a FULL copy of the
        -- sprite (six visible copies when naively restamped), so only one -- the
        -- bottom-center cell -- is marked for display; the rest are only zeroed.
        local anch = gps.screentexpos_anchored
        local axb, ayb = gps.screentexpos_anchored_x, gps.screentexpos_anchored_y
        for dy = -1, 1 do
            local y = in_row + dy
            if y >= 0 and y < dimy then
                for x = left, right do
                    local i = x * dimy + y
                    if anch[i] ~= 0 then
                        g.icon[#g.icon + 1] =
                            {dx = x - left, dy = dy, val = anch[i], ax = axb[i], ay = ayb[i]}
                    end
                end
            end
        end
        if #g.icon > 0 then
            local maxdy = -2
            for _, c in ipairs(g.icon) do maxdy = math.max(maxdy, c.dy) end
            local bottom = {}
            for _, c in ipairs(g.icon) do
                if c.dy == maxdy then bottom[#bottom + 1] = c end
            end
            table.sort(bottom, function(a, b) return a.dx < b.dx end)
            bottom[(#bottom + 1) // 2].show = true
        end
    end
    -- the art may already be patched out of the live buffers by our own painting
    -- (and DF never redraws the anchored layer) -- inherit the previous capture
    if geo and geo.key == g.key then
        if not g.in_row then
            g.in_row, g.pill, g.icon, g.band = geo.in_row, geo.pill, geo.icon, geo.band
        else
            if #g.pill == 0 then g.pill = geo.pill end
            if #g.icon == 0 then g.icon = geo.icon end
            for dy = -1, 1 do
                if not g.band[dy] or g.band[dy] == 0 then g.band[dy] = geo.band[dy] end
            end
        end
    end
    return g
end

local BLANK = dfhack.pen.parse{ch = 32, fg = COLOR_WHITE, bg = COLOR_BLACK}
local TEXT_PEN = {fg = COLOR_WHITE, bg = COLOR_BLACK}

local function blank_span(y, x1, x2)
    for x = x1, x2 do dfhack.screen.paintTile(BLANK, x, y) end
end

-- move the native location line to target row ty (text re-copied every frame --
-- DF redraws it -- art re-stamped from the geometry capture; sources wiped)
local function move_in_line(g, ty)
    local gps = df.global.gps
    local dimy = gps.dimy
    -- the "In <building>" text sits 2 further right than the pill; the pill zone
    -- (and its "View" label) keeps LINE_SHIFT so the label stays on its button
    local pill_min
    for _, c in ipairs(g.pill) do
        if not pill_min or c.dx < pill_min then pill_min = c.dx end
    end
    -- text + pens, shifted; source blanked. Bounded to the panel INTERIOR --
    -- past cap_r sit the band cap and the panel border, which must stay put
    -- both at the source and at the target.
    local cap_r = g.left + SPAN_W + TEXT_SHIFT - 1
    for x = g.left + BORDER_PAD, cap_r do
        local dx = x - g.left
        local shift = (pill_min and dx >= pill_min - 1) and LINE_SHIFT or LINE_SHIFT + 2
        local p = dfhack.screen.readTile(x, g.in_row)
        if p and x + shift <= cap_r then
            p.tile = 0
            dfhack.screen.paintTile(p, x + shift, ty)
        end
        dfhack.screen.paintTile(BLANK, x, g.in_row)
    end
    -- flatten the moved rows to the panel's own gray: art layers cleared, the
    -- lower layer filled with the panel band. The gray is sampled from the row
    -- ABOVE the Remove row -- a row this overlay never paints -- because
    -- sampling a row we write to picks up our own leftovers (a zero sampled
    -- once perpetuates itself as a black stripe; measured live).
    local lower = gps.screentexpos_lower
    local gray = lower[(g.left + 5) * dimy + math.max(0, g.remove_row - 1)]
    for y = ty - 1, ty + 1 do
        if y >= 0 and y < dimy then
            for x = g.left + BORDER_PAD, cap_r do
                local i = x * dimy + y
                gps.screentexpos[i] = 0
                gps.screentexpos_top[i] = 0
                gps.screentexpos_anchored[i] = 0
                lower[i] = gray
            end
        end
    end
    -- View-button pill (3 rows): stamp the capture at the target, patch the
    -- source rows back to their plain band
    local lower = gps.screentexpos_lower
    for _, c in ipairs(g.pill) do
        local tx = g.left + c.dx + LINE_SHIFT
        local tyy = ty + c.dy
        if tx < gps.dimx and tyy >= 0 and tyy < dimy then
            lower[tx * dimy + tyy] = c.val
        end
        lower[(g.left + c.dx) * dimy + g.in_row + c.dy] = g.band[c.dy] or 0
    end
    -- anchored icon: every cell renders a full sprite copy, so only the marked
    -- bottom-center cell is stamped (lifted ICON_LIFT rows); ALL sources zeroed
    local anch = gps.screentexpos_anchored
    local ax, ay = gps.screentexpos_anchored_x, gps.screentexpos_anchored_y
    for _, c in ipairs(g.icon) do
        if c.show then
            local tyy = ty + c.dy - ICON_LIFT
            if tyy >= 0 then
                -- one column left of the line (tuned live)
                local ti = math.max(0, g.left + c.dx + LINE_SHIFT - 1) * dimy + tyy
                anch[ti], ax[ti], ay[ti] = c.val, c.ax, c.ay
            end
        end
        local si = (g.left + c.dx) * dimy + g.in_row + c.dy
        anch[si], ax[si], ay[si] = 0, 0, 0
    end
end

-- rebuilt block: cleared Remove row, moved location line, full description below.
-- Without a location line (nothing held/no pill found) the line step is skipped
-- and the description starts right under the cleared Remove row.
local function render_display_mode(lines, vs)
    local now = dfhack.getTickCount()
    local gps = df.global.gps
    if geo then
        local key = ('%d:%d:%d'):format(vs.active_id, gps.dimx, gps.dimy)
        if geo.key ~= key then geo, scan_at = nil, 0 end
    end
    if now >= scan_at then
        geo = find_geometry(vs) or geo
        scan_at = now + SCAN_MS
    end
    if not geo then return end
    local g = geo
    local paint_l = g.left + BORDER_PAD          -- border column stays untouched
    local span_r = g.left + SPAN_W + TEXT_SHIFT - 1
    local desc_top

    blank_span(g.remove_row, paint_l, span_r)
    if g.in_row then
        local in_target = g.remove_row + 1 + SHIFT_Y
        desc_top = in_target + 3
        -- clear the rows around the moved line (icon bleed + the gap row above
        -- the description) before the copy lands
        for y = in_target - 1, desc_top - 1 do
            if y ~= g.remove_row then blank_span(y, paint_l, span_r) end
        end
        move_in_line(g, in_target)
        g.moved_in_row = in_target
    else
        desc_top = g.remove_row + 3
        for y = g.remove_row + 1, desc_top - 1 do
            blank_span(y, paint_l, span_r)
        end
        g.moved_in_row = nil
    end

    -- description below, scrollable, up to half the screen
    local total = #lines
    local maxrows = math.max(1, math.floor(gps.dimy / 2))
    local n = math.min(total, maxrows)
    local scroll = math.max(0, math.min(vs.scroll_position_item, total - n))
    -- cover at least the native box so stale native rows never peek through
    local cover = math.max(n, DF_VISIBLE_ROWS)
    local pad = (' '):rep(TEXT_SHIFT - BORDER_PAD)
    for row = 0, cover - 1 do
        local y = desc_top + row
        if y >= gps.dimy then break end
        local s = pad .. (row < n and lines[scroll + row].value or '')
        local w = SPAN_W + TEXT_SHIFT - BORDER_PAD
        if #s < w then s = s .. (' '):rep(w - #s) else s = s:sub(1, w) end
        dfhack.screen.paintString(TEXT_PEN, paint_l, y, s)
    end
    -- remember the live rects for input handling
    g.desc_rect = {x1 = paint_l, x2 = span_r, y1 = desc_top, y2 = desc_top + n - 1}
    g.total, g.n = total, n
end

function ItemDescriptionOverlay:onRenderFrame(dc, rect)
    local ok, err = pcall(function()
        local lines, vs = desc_lines()
        if not lines then geo = nil return end
        if has_holder(vs) then
            render_display_mode(lines, vs)
        else
            geo = nil
        end
    end)
    if not ok then
        geo = nil
        last_error = err    -- env global: read via reqscript(...).last_error
    end
end

-- wheel-scroll our expanded description; teleport clicks on the moved In-line
-- back to the native row so DF's own View button handles them
function ItemDescriptionOverlay:onInput(keys)
    if not geo or not geo.desc_rect then return false end
    local g = geo
    local x, y = dfhack.screen.getMousePos()
    if not x then return false end
    -- the moved line (all three pill rows): teleport the click back to the
    -- native row/column so DF's own View button handles it
    if keys._MOUSE_L and g.moved_in_row and g.in_row
            and y >= g.moved_in_row - 1 and y <= g.moved_in_row + 1
            and x >= g.left + LINE_SHIFT and x <= g.right + LINE_SHIFT then
        local gps = df.global.gps
        local nx = x - LINE_SHIFT
        local ny = g.in_row + (y - g.moved_in_row)
        gps.mouse_x, gps.mouse_y = nx, ny
        gps.precise_mouse_x = nx * gps.tile_pixel_x + gps.tile_pixel_x // 2
        gps.precise_mouse_y = ny * gps.tile_pixel_y + gps.tile_pixel_y // 2
        return false    -- let DF process the click at the native button
    end
    local r = g.desc_rect
    if x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2 then
        local vs = df.global.game.main_interface.view_sheets
        local step = keys.CONTEXT_SCROLL_PAGEUP and -g.n or keys.CONTEXT_SCROLL_PAGEDOWN and g.n
            or keys.CONTEXT_SCROLL_UP and -3 or keys.CONTEXT_SCROLL_DOWN and 3
        if step then
            vs.scroll_position_item = math.max(0,
                math.min(vs.scroll_position_item + step, g.total - g.n))
            return true
        end
    end
    return false
end

-- plain path: items not on display keep the old behavior -- only long
-- descriptions are redrawn, inside the widget frame
function ItemDescriptionOverlay:onRenderBody(dc)
    local lines, vs = desc_lines()
    if not lines then return end
    if has_holder(vs) then return end              -- handled by onRenderFrame
    local total = #lines
    -- leave short descriptions to DF (it renders those fully already)
    if total <= DF_VISIBLE_ROWS then return end

    -- use up to half the screen height; scroll the rest with DF's own scroll position
    local maxrows = math.max(1, math.floor(df.global.gps.dimy / 2))
    local n = math.min(total, maxrows)
    local scroll = math.max(0, math.min(vs.scroll_position_item, total - n))

    -- size the frame to exactly the lines we draw, so nothing below them is occluded
    if self.frame.h ~= n then self.frame.h = n; self:updateLayout() end

    local w = self.frame.w
    local pen = {fg = COLOR_WHITE, bg = COLOR_BLACK}   -- opaque, to cover DF's short box
    for row = 0, n - 1 do
        local s = '  ' .. lines[scroll + row].value     -- DF indents the text two columns
        if #s < w then s = s .. (' '):rep(w - #s) else s = s:sub(1, w) end
        dc:seek(0, row):string(s, pen)
    end
end

OVERLAY_WIDGETS = {expand = ItemDescriptionOverlay}

-- running it directly just prints what it is (the overlay is registered via rescan)
if not dfhack_flags.module then
    print('item-description: overlay "item-description.expand" -- expands the item view-sheet')
    print('description; items on pedestals get the In-line moved up and a scrollable full text.')
    print('Manage it with gui/overlay.')
end
