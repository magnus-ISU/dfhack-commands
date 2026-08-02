-- Stockpile view: drag to create an UNSELECTED pile; drag on a selected pile to expand it.
--@module = true
--[[
In the stockpile PLACEMENT view this replaces DF's native click handling with a
dig-shapes-style drag. Two states, keyed off whether a pile is selected:

  * NOTHING selected (focus `dwarfmode/Stockpile`):
        LEFT  drag  -> a NEW stockpile covering the box, left UNSELECTED.
        RIGHT drag  -> ERASE the box's tiles from ANY stockpile under it (pile-agnostic);
                       a pile left with no tiles is fully deleted.
        LEFT  click -> passed to DF (e.g. click an existing pile to select it).
        RIGHT click -> passed to DF (its normal right-click: leave the tool).

  * A pile selected (focus `dwarfmode/Stockpile/Some/Default`):
        LEFT  drag  -> EXPAND the selected pile to include the box's floor tiles.
        RIGHT drag  -> ERASE the box's tiles from THIS pile only; if it empties, it's deleted.
        LEFT  click -> passed to DF (select another pile, hit a config button, deselect).
        RIGHT click / Escape -> back out to place mode (deselect), NOT exit the tool.

The new pile is created UNSELECTED -- DF's own placement highlights the pile (its focus
becomes `dwarfmode/Stockpile/Some/...` and the config panel opens), which interrupts you
when laying down several piles in a row. We build the pile through the buildings API
instead, so nothing is selected and you stay in placement mode for the next drag.

How it works (mirrors dwarf-rts's selection-rect-free drag): stockpile placement does NOT
use `df.global.selection_rect` (only the Dig tool does), so we poll the raw mouse buttons
(`df.global.enabler.mouse_lbut_down` / `mouse_rbut_down`) every frame in overlay_onupdate --
press edge records the start tile, release edge commits -- and swallow the press in onInput
so DF's native handling never fires. The whole gesture resolves on mouse-UP, so a click and
a drag are told apart cleanly: a same-tile release is a click, a real box acts. A plain
click is re-dispatched to DF (dwarf-rts's `passthrough` trick) so it stays native; the one
exception is Escape / right-click on a selected pile, which we intercept to deselect back to
place mode (edit vs place is simply `stockpile.cur_bld` set vs nil) rather than let it exit
the tool -- a graceful back-out with no exit-then-reopen flicker.

Tiles with no storable floor (walls, open space, other buildings) are dropped from a new or
expanded pile automatically, matching native placement.

Registered as overlay `stockpile-place.watcher`. Joins the other stockpile helpers
(binnable-stockpile).
]]

local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')
local gui = require('gui')
local utils = require('utils')

local function mi() return df.global.game.main_interface end

-- the stockpile currently selected for editing (nil if none)
local function selected_pile()
    local sp = dfhack.gui.getSelectedStockpile(true)
    if sp then return sp end
    local b = df.global.world.selected_building
    if b and b:getType() == df.building_type.Stockpile then return b end
    return nil
end

-- Which drag behavior applies, or nil if we should stay out entirely:
--   'place' -- the bare placement view, nothing selected      -> a drag creates a new pile.
--   'edit'  -- a pile selected, on its base config view        -> a drag expands/erases it.
-- Restricted to the exact base focuses: a deeper sub-screen (e.g. the category Customize screen,
-- which binnable-stockpile owns) reports `.../Some/Customize`, where we must stay out so its own
-- clicks and Escape work normally.
local function active_mode()
    local focus = dfhack.gui.getCurFocus(true)[1] or ''
    if focus == 'dwarfmode/Stockpile' then return 'place' end
    if focus == 'dwarfmode/Stockpile/Some/Default' and selected_pile() then return 'edit' end
    return nil
end

local function same_tile(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

-- ---- map-click UI guard (same shape as dig-shapes) --------------------------
-- Only begin/keep a drag when the cursor is over the EXPOSED map -- never over the bottom
-- toolbar, a notification/alert, or another overlay -- so those keep their own clicks.

local function widget_on_screen(w, vs)
    local vss = w.viewscreens
    if type(vss) == 'string' then vss = {vss} end
    if type(vss) ~= 'table' then return false end
    for _, fs in ipairs(vss) do
        if type(fs) == 'string' then
            local ok, m = pcall(dfhack.gui.matchFocusString, fs, vs)
            if ok and m then return true end
        end
    end
    return false
end

local function over_other_overlay(mx, my)
    local vs = dfhack.gui.getDFViewscreen(true)
    local fullw, fullh = df.global.gps.dimx - 1, df.global.gps.dimy - 1
    for name, e in pairs(overlay.get_state().db) do
        if name ~= 'fort/stockpile-place.watcher' then
            local w = e.widget
            local r = w.frame_rect
            if r and mx >= r.x1 and mx <= r.x2 and my >= r.y1 and my <= r.y2
                and not (r.x1 <= 0 and r.y1 <= 0 and r.x2 >= fullw and r.y2 >= fullh)
                and widget_on_screen(w, vs)
            then
                local ok, vis = pcall(function() return utils.getval(w.visible) end)
                if ok and vis then return true end
            end
        end
    end
    return false
end

-- map tile under the cursor, but only if the cursor is over the clear map (nil otherwise)
local function map_pos_if_clear()
    local pos = dfhack.gui.getMousePos()
    if not pos then return nil end
    local m = mi()
    if m.current_hover ~= -1 then return nil end            -- over a DF hover element
    if m.current_hover_alert then return nil end            -- over a native alert
    if over_other_overlay(df.global.gps.mouse_x, df.global.gps.mouse_y) then return nil end
    return pos
end

-- ---- stockpile creation -----------------------------------------------------

local FLOOR = df.tiletype_shape_basic.Floor

local function is_floor(x, y, z)
    local tt = dfhack.maps.getTileType({x = x, y = y, z = z})
    if not tt then return false end
    return df.tiletype_shape.attrs[df.tiletype.attrs[tt].shape].basic_shape == FLOOR
end

-- a tile a NEW pile can occupy: a floor with no building already on it. DF trims unusable
-- tiles from the extents itself, but we pre-filter to get an accurate tile count (to skip an
-- all-invalid drag) and never spawn a phantom zero-tile pile.
local function tile_ok_new(x, y, z)
    return is_floor(x, y, z) and not dfhack.buildings.findAtTile({x = x, y = y, z = z})
end

-- a tile pile `bld` can grow INTO: a floor that is either free or already part of bld itself
-- (so an overlapping drag is idempotent rather than blocked)
local function tile_ok_expand(x, y, z, bld)
    if not is_floor(x, y, z) then return false end
    local b = dfhack.buildings.findAtTile({x = x, y = y, z = z})
    return (not b) or (b == bld)
end

-- Build a stockpile over the box [p1..p2] on p1's z-level. Extents mark exactly the storable
-- tiles (see tile_ok_new); constructBuilding preserves the extents we pass (it only trims
-- further), so the pile matches what native placement would make -- minus the auto-select.
local function create_pile(p1, p2)
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local z = p1.z
    local w, h = x2 - x1 + 1, y2 - y1 + 1
    local area = w * h
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', area))
    local ntiles = 0
    -- row-major, exactly as quickfort's make_extents: index = y_off*width + x_off
    for yo = 0, h - 1 do for xo = 0, w - 1 do
        local ok = tile_ok_new(x1 + xo, y1 + yo, z)
        extents[yo * w + xo] = ok and 1 or 0
        if ok then ntiles = ntiles + 1 end
    end end
    if ntiles == 0 then
        df.delete(extents)
        dfhack.gui.showAnnouncement('stockpile-place: no storable floor in that area.',
            COLOR_YELLOW, true)
        return
    end
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {
        type = df.building_type.Stockpile, abstract = true, pos = {x = x1, y = y1, z = z},
        width = w, height = h,
        fields = {room = {x = x1, y = y1, width = w, height = h, extents = extents}},
    })
    -- created UNSELECTED: constructBuilding never opens the pile's config, and we swallowed the
    -- native click so DF never highlights it -- we stay in placement mode for the next drag.
    if not ok or not bld then
        dfhack.gui.showAnnouncement('stockpile-place: could not place a pile there.',
            COLOR_YELLOW, true)
    end
end

-- Grow an existing pile to also cover the box [p1..p2] (must be on the pile's own z-level).
-- Stockpile membership lives in two places, both of which native placement maintains and which
-- we mirror: the building's `room.extents` grid (1 = tile belongs) over a bounding box, and each
-- member tile's map `occupancy.building = Passable`. We reallocate a bigger extents grid for the
-- UNION of the old bounds and the new box, copy the old membership across, add the new floor
-- tiles, then repaint occupancy. Union-only (we never drop tiles), so no occupancy needs clearing.
local function expand_pile(bld, p1, p2)
    local z = bld.z
    if p1.z ~= z then return end                       -- single-z pile: ignore a cross-z drag
    local nx1, nx2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local ny1, ny2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local ux1, uy1 = math.min(bld.x1, nx1), math.min(bld.y1, ny1)
    local ux2, uy2 = math.max(bld.x2, nx2), math.max(bld.y2, ny2)
    local uw, uh = ux2 - ux1 + 1, uy2 - uy1 + 1
    local newext = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', uw * uh))
    for i = 0, uw * uh - 1 do newext[i] = 0 end
    -- carry the pile's current membership into the (possibly shifted) new grid
    local old, ow, oh, ox, oy = bld.room.extents, bld.room.width, bld.room.height, bld.room.x, bld.room.y
    for yo = 0, oh - 1 do for xo = 0, ow - 1 do
        if old[yo * ow + xo] ~= 0 then
            newext[(oy + yo - uy1) * uw + (ox + xo - ux1)] = 1
        end
    end end
    -- add the dragged box's storable floor tiles
    for gy = ny1, ny2 do for gx = nx1, nx2 do
        if tile_ok_expand(gx, gy, z, bld) then
            newext[(gy - uy1) * uw + (gx - ux1)] = 1
        end
    end end
    -- apply new geometry, swap in the grid, free the old one, then repaint tile occupancy
    bld.x1, bld.y1, bld.x2, bld.y2 = ux1, uy1, ux2, uy2
    bld.room.x, bld.room.y, bld.room.width, bld.room.height = ux1, uy1, uw, uh
    bld.room.extents = newext
    df.delete(old)
    for yo = 0, uh - 1 do for xo = 0, uw - 1 do
        if newext[yo * uw + xo] ~= 0 then
            local gx, gy = ux1 + xo, uy1 + yo
            local blk = dfhack.maps.getTileBlock({x = gx, y = gy, z = z})
            if blk then blk.occupancy[gx % 16][gy % 16].building = df.tile_building_occ.Passable end
        end
    end end
end

-- Drop this pile out of the current selection so focus falls back to the bare placement view
-- (`dwarfmode/Stockpile`). Edit vs place mode is exactly cur_bld set vs nil (bottom mode stays
-- STOCKPILE), so clearing it is the whole graceful back-out -- no exit-then-reopen flicker.
local function deselect_to_place()
    mi().stockpile.cur_bld = nil
    df.global.world.selected_building = nil
end

-- Erase the box [p1..p2] from stockpiles: scoped to `only_bld` when a pile is selected, else
-- pile-agnostic (any pile in the box). Zeroing a tile is the inverse of expand -- clear its
-- extents cell and its map occupancy. A pile left with no tiles is fully deconstructed. Returns
-- a {[id]=true} set of the piles that were deleted, so the caller can drop a dangling selection.
local function erase_tiles(p1, p2, only_bld)
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local z = p1.z
    local emptied, deleted = {}, {}
    -- iterate the stockpile list (bounded -- never the whole map), not findAtTile: a tile can hold
    -- another overlapping building (e.g. the starting wagon) that findAtTile would return instead.
    for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
        if (not only_bld or b == only_bld) and b.z == z
            and not (b.x2 < x1 or b.x1 > x2 or b.y2 < y1 or b.y1 > y2)   -- bbox intersects the box
        then
            local ext, ox, oy, ow, oh = b.room.extents, b.room.x, b.room.y, b.room.width, b.room.height
            for gy = math.max(y1, b.y1), math.min(y2, b.y2) do
                for gx = math.max(x1, b.x1), math.min(x2, b.x2) do
                    local idx = (gy - oy) * ow + (gx - ox)
                    if idx >= 0 and idx < ow * oh and ext[idx] ~= 0 then
                        ext[idx] = 0
                        local blk = dfhack.maps.getTileBlock({x = gx, y = gy, z = z})
                        if blk then blk.occupancy[gx % 16][gy % 16].building = df.tile_building_occ.None end
                    end
                end
            end
            local any = false
            for i = 0, ow * oh - 1 do if ext[i] ~= 0 then any = true; break end end
            if not any then emptied[#emptied + 1] = b end
        end
    end
    -- deconstruct emptied piles from a separate list (never mutate the vector mid-iteration)
    for _, b in ipairs(emptied) do
        deleted[b.id] = true
        pcall(dfhack.buildings.deconstruct, b)
    end
    return deleted
end

-- ---- drag-box visual feedback ----------------------------------------------
-- Because we swallow the native click, DF draws no placement box -- so we paint our own on the
-- MAP grid (graphical map tiles differ in size from the text grid, so a text paint would be
-- scaled): guidm.Viewport tile->screen plus paintTile(..., map=true), exactly as dwarf-rts does.

local function fill_pen(color)
    return dfhack.pen.parse{ch = 250, fg = color, keep_lower = true,
        tile = dfhack.screen.findGraphicsTile('CURSORS', 1, 22)}
end
local FILL_PEN = {place = fill_pen(COLOR_YELLOW), edit = fill_pen(COLOR_LIGHTGREEN)}
local ERASE_PEN = fill_pen(COLOR_LIGHTRED)
local LABEL_PEN = {fg = COLOR_WHITE, bg = COLOR_BLACK}

local function draw_box(p1, p2, pen)
    local vp = guidm.Viewport.get()
    local z = df.global.window_z
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    for my = y1, y2 do for mx = x1, x2 do
        local pos = xyz2pos(mx, my, z)
        if vp:isVisible(pos) then
            local s = vp:tileToScreen(pos)
            dfhack.screen.paintTile(pen, s.x, s.y, nil, nil, true)
        end
    end end
    local label = ('%dx%d'):format(x2 - x1 + 1, y2 - y1 + 1)
    local lx = math.max(0, math.min(df.global.gps.mouse_x + 2, df.global.gps.dimx - #label))
    dfhack.screen.paintString(LABEL_PEN, lx, df.global.gps.mouse_y, label)
end

-- ---- overlay ----------------------------------------------------------------

StockpilePlace = defclass(StockpilePlace, overlay.OverlayWidget)
StockpilePlace.ATTRS{
    desc = 'Stockpile view: left-drag creates/expands piles (unselected), right-drag erases them.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Stockpile',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

-- Re-dispatch our own swallowed click to DF so it does the normal thing (select a pile, hit a
-- config button, exit the tool). The passthrough flag makes onInput let this replay through.
function StockpilePlace:redispatch(key)
    self.passthrough = true
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), key)
    self.passthrough = false
end

-- Poll BOTH raw mouse buttons (independent of who consumes the click event): a press edge records
-- the start tile + the mode we were in, a release edge resolves the whole gesture. Settling on
-- mouse-UP is what tells a click apart from a drag cleanly, so nothing fires mid-drag.
--   LEFT  drag -> create (place) / expand (edit);  click -> re-dispatch to DF.
--   RIGHT drag -> erase tiles (agnostic in place, the selected pile in edit); click -> graceful
--                 back-out in edit (deselect to place), else re-dispatch (DF's normal right-click).
function StockpilePlace:overlay_onupdate()
    local mode = active_mode()
    if not mode then
        self.press, self.press_mode, self.rpress, self.rpress_mode = nil, nil, nil, nil
        self.lbut, self.rbut = df.global.enabler.mouse_lbut_down, df.global.enabler.mouse_rbut_down
        return
    end
    -- ---- left button ----
    local down = df.global.enabler.mouse_lbut_down
    if down == 1 and self.lbut ~= 1 then
        self.press, self.press_mode = map_pos_if_clear(), mode
    elseif down ~= 1 and self.lbut == 1 then
        local start, pmode = self.press, self.press_mode
        self.press, self.press_mode = nil, nil
        if start then
            local rel = dfhack.gui.getMousePos()
            if rel and same_tile(start, rel) then
                self:redispatch('_MOUSE_L')
            elseif rel and rel.z == start.z then
                if pmode == 'edit' then
                    local bld = selected_pile()
                    if bld then expand_pile(bld, start, rel) end
                else
                    create_pile(start, rel)
                end
            end
        end
    end
    self.lbut = down
    -- ---- right button ----
    local rdown = df.global.enabler.mouse_rbut_down
    if rdown == 1 and self.rbut ~= 1 then
        self.rpress, self.rpress_mode = map_pos_if_clear(), mode
    elseif rdown ~= 1 and self.rbut == 1 then
        local start, pmode = self.rpress, self.rpress_mode
        self.rpress, self.rpress_mode = nil, nil
        if start then
            local rel = dfhack.gui.getMousePos()
            if rel and same_tile(start, rel) then
                -- a plain right-click: in edit mode back out to place mode (don't exit the tool);
                -- in place mode let DF do its usual right-click (leave the tool).
                if pmode == 'edit' then deselect_to_place() else self:redispatch('_MOUSE_R') end
            elseif rel and rel.z == start.z then
                -- a right drag: erase. Scope to the selected pile in edit mode, agnostic otherwise.
                local sel = (pmode == 'edit') and selected_pile() or nil
                local deleted = erase_tiles(start, rel, sel)
                if sel and deleted[sel.id] then deselect_to_place() end   -- selection just deleted
            end
        end
    end
    self.rbut = rdown
end

-- Swallow left/right presses on the open map so DF's native handling never fires mid-gesture --
-- overlay_onupdate resolves each on release. Escape with a pile selected backs out to place mode
-- instead of exiting the tool. Our own re-dispatched clicks (passthrough) pass through, as do
-- clicks/keys over the toolbar, config panel, or another overlay.
function StockpilePlace:onInput(keys)
    if self.passthrough then return false end               -- our own replayed click
    local mode = active_mode()
    if not mode then return false end
    if keys.LEAVESCREEN and mode == 'edit' then             -- Esc on a selected pile -> place mode
        deselect_to_place()
        return true
    end
    if (keys._MOUSE_L or keys._MOUSE_R) and map_pos_if_clear() then return true end
    return false
end

function StockpilePlace:render(dc)
    StockpilePlace.super.render(self, dc)
    if not active_mode() then return end
    -- left drag box (create/expand) or right drag box (erase), whichever button is held
    local start, pen
    if self.lbut == 1 and self.press then
        start, pen = self.press, (FILL_PEN[self.press_mode] or FILL_PEN.place)
    elseif self.rbut == 1 and self.rpress then
        start, pen = self.rpress, ERASE_PEN
    end
    if not start then return end
    local cur = dfhack.gui.getMousePos()
    if not cur or cur.z ~= start.z then return end
    if same_tile(start, cur) then return end                -- a click, not a box: draw nothing
    draw_box(start, cur, pen)
end

OVERLAY_WIDGETS = {watcher = StockpilePlace}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
-- default_enabled only applies on first discovery; once an off state has persisted, rescan alone
-- won't bring it back -- so running the script re-enables the overlay to be reliable.
dfhack.run_command('overlay', 'enable', 'fort/stockpile-place.watcher')
print('stockpile-place: drag a box in the stockpile view to create an UNSELECTED pile.')
