-- Drag to place many workshops/furniture at once during building-plan placement.
--@module = true
--[[
plan-tile

While you're placing a building (the buildingplan placement screen), LEFT-DRAG a box on the map to
lay down a whole GRID of that building in one gesture instead of clicking each one. The buildings are
tiled by their FOOTPRINT: a 1x1 statue every 1 tile, a 3x3 Carpenter's every 3 tiles, a 5x5 Trade
Depot every 5 tiles -- so they sit edge-to-edge without overlapping.

Placement is deferred to MOUSE-UP:
  * The mouse-down that would normally place a building is INTERCEPTED before buildingplan's
    planner sees it (overlay input order between widgets is arbitrary hash order, so we wrap the
    planner widget's own onInput rather than racing it). Nothing is placed while the button is
    held -- you only see ghosts. On release over the map the whole dragged box is placed at once
    (a plain click yields exactly one building, on release). Releasing over UI or on another
    z-level -- or cancelling placement with right-click mid-drag -- places nothing.
    Overlapping/blocked cells are silently skipped (constructBuilding refuses occupied tiles),
    so nothing double-places. The click is only ever intercepted when a drag could actually
    begin (planner on, clear map tile, no DF placement errors); otherwise the planner and DF
    handle it exactly as before.
  * It only engages for fixed-footprint buildings that have NO native area drag (workshops,
    furniture, machines...). Walls, floors, farm plots, bridges and the like already have DF's own
    build-more area UI, so `cur_building_has_no_area()` is false for them and this stays out of the
    way -- no conflict.
  * It stays out when buildingplan is in "choose items by hand" mode (the extra copies would have no
    hand-picked items), leaving you the normal one-at-a-time flow.

Each placed copy is registered with buildingplan (same material filters as the one you placed), so
they respect your filters and get suspended until materials are available, just like a normal plan.

Placement RULES are enforced per tile, mirroring DF's own placement errors (which
constructBuilding does NOT check -- it would happily create a plan DF can never build):
  * it doesn't engage at all when DF is showing placement errors at the mouse-down tile (the same
    gate buildingplan's planner uses -- if the first building can't go down, neither can a grid);
  * each fill cell must be buildable floor (unhidden, unoccupied, no deep liquid) and, for
    furniture DF requires indoors (beds / coffins / seats), not an outside tile. Cells that fail
    are skipped, and the drag preview paints them red instead of green.

While dragging, each grid cell previews a TRANSPARENT GHOST of the actual building: the live
placement hologram under the mouse is copied, within DF's own alpha-rendered hologram layer
(screentexpos_interface), onto every cell that will receive a building. Invalid cells show red;
if the hologram can't be captured the preview falls back to plain green tiles.

Loaded as an overlay (`plan-tile.tile` on the building-placement screen); auto-enabled on `overlay
rescan`.
]]

local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')
local utils = require('utils')

local uibs = df.global.buildreq          -- the live "building being placed" state
local MAX_BUILDINGS = 400                 -- safety cap on a single drag

-- ---- map-click guard (mirrors right-click-cancel / dwarf-rts) --------------
-- the map tile under the cursor, or nil if the cursor is over ANY UI (panels, the buildingplan
-- filter overlay, notifications, the protected top-left corner) so those clicks aren't hijacked.
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
        if name ~= 'fort/plan-tile.tile' then
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

local function map_pos_if_clear()
    local pos = dfhack.gui.getMousePos()
    if not pos then return nil end
    local m = df.global.game.main_interface
    if m.current_hover ~= -1 then return nil end
    if m.current_hover_alert then return nil end
    if m.current_hover_left_x ~= 0 then return nil end
    local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
    if mx < 2 or (mx < 4 and my < 4) then return nil end
    if over_other_overlay(mx, my) then return nil end
    return pos
end

-- ---- building-plan placement introspection --------------------------------

-- placement screen is up and a real building is selected?
local function placement_active()
    return df.global.game.main_interface.bottom_mode_selected == df.main_bottom_mode_type.BUILDING_PLACEMENT
        and uibs.building_type ~= -1
end

-- the current building's footprint (its natural size), min 1x1.
-- NB getCorrectSize returns is_flexible FIRST, then width/height -- reading width from
-- slot 1 gives you a boolean and silently collapses every workshop to fw=1 (the vertical
-- axis still looked right for square buildings, which hid the bug for a long time).
local function footprint()
    local ok, _flex, w, h = pcall(dfhack.buildings.getCorrectSize, 1, 1,
        uibs.building_type, uibs.building_subtype, uibs.custom_type, uibs.direction)
    if not ok then return 1, 1 end
    return math.max(1, w or 1), math.max(1, h or 1)
end

-- fixed-footprint building with no native area drag? (workshop / furniture / machine, NOT a
-- construction / farm plot / bridge / road, which have their own build-more UI). Mirrors
-- buildingplan's own cur_building_has_no_area().
local function has_no_area()
    if uibs.building_type == df.building_type.Construction then return false end
    local filters = dfhack.buildings.getFiltersByType({},
        uibs.building_type, uibs.building_subtype, uibs.custom_type)
    return filters and filters[1] and (not filters[1].quantity or filters[1].quantity > 0) and true or false
end

-- buildingplan in "choose items by hand" mode? (then we stay out)
local function choosing_items()
    local ok, v = pcall(function()
        return require('plugins.buildingplan').getChooseItems(
            uibs.building_type, uibs.building_subtype, uibs.custom_type)
    end)
    return ok and v and v ~= 0
end

-- should we handle drags right now?
local function engaged()
    return placement_active() and has_no_area() and not choosing_items()
end

-- read the on-screen characters of row `y` (left `w` columns), for finding the Planner toggle
local function readrow(y, w)
    local t = {}
    for x = 0, w - 1 do
        local ok, tile = pcall(dfhack.screen.readTile, x, y)
        t[#t + 1] = (ok and tile and tile.ch and tile.ch > 0) and string.char(tile.ch) or ' '
    end
    return table.concat(t)
end

-- is the buildingplan PLANNER actually on for this placement? Its filter panel shows a
-- "hide Planner" toggle when the planner is ON, "show Planner" when it's OFF (plain DF
-- placement). If it's off we must stay out -- otherwise we'd turn a normal building into a
-- row of *planned* ones. Only read at mouse-down (a full-panel scan), never per frame.
local function planner_on()
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do                 -- full-width scan (matches dig-building's planner_toggle)
        local s = readrow(y, gps.dimx)
        if s:find('hide Planner', 1, true) then return true end
        if s:find('show Planner', 1, true) then return false end
    end
    return false                              -- toggle not found: don't engage (the safe default)
end

-- ---- mouse-down interception ----------------------------------------------
-- Overlay input order between widgets is pairs() hash order -- there is no reliable way to
-- receive _MOUSE_L before buildingplan.planner does. So we wrap the planner WIDGET's own
-- onInput: when a plan-tile drag should begin, the wrapper swallows the click (the planner
-- never places its mouse-down building) and records the press for our onupdate. The wrap is
-- re-installed lazily because overlay rescans recreate the widget, and the check closure is
-- refreshed per module load (HOOK_TOKEN) so hot-reloads don't strand a stale upvalue.

local pending_press = nil     -- map pos of a swallowed mouse-down, awaiting onupdate
local HOOK_TOKEN = {}         -- fresh per module load

-- would a drag begin at this click? (cheap checks first; planner_on scans the screen)
local function want_press()
    if not engaged() then return nil end
    if #uibs.errors > 0 then return nil end        -- DF refuses placement here; so do we
    local pos = map_pos_if_clear()
    if not pos then return nil end
    if not planner_on() then return nil end        -- plain non-planner placement: stay out
    return pos
end

local function install_planner_hook()
    local ok, e = pcall(function() return overlay.get_state().db['buildingplan.planner'] end)
    if not (ok and e and e.widget) then return end
    local w = e.widget
    if w.plan_tile_token == HOOK_TOKEN then return end
    w.plan_tile_token = HOOK_TOKEN
    w.plan_tile_check = function(keys)
        if keys._MOUSE_L then
            local pos = want_press()
            if pos then
                pending_press = pos
                return true
            end
        end
        return false
    end
    if not w.plan_tile_wrapped then
        local orig = w.onInput
        w.onInput = function(wself, keys)
            if wself.plan_tile_check and wself.plan_tile_check(keys) then return true end
            return orig(wself, keys)
        end
        w.plan_tile_wrapped = true
    end
end

-- ---- per-tile placement validity ------------------------------------------
-- DF refuses some furniture outdoors ("must be built inside"): seen in 53.x for beds, coffins
-- and seats (quickfort's db only knows about beds -- it's stale on this). constructBuilding
-- enforces none of DF's placement rules, so the fill checks each tile the way quickfort's
-- build module does, plus the indoors rule where DF demands it.
local INSIDE_ONLY = utils.invert{
    df.building_type.Bed,
    df.building_type.Coffin,
    df.building_type.Chair,
}

local OK_SHAPES = utils.invert{
    df.tiletype_shape.FLOOR,
    df.tiletype_shape.BOULDER,
    df.tiletype_shape.PEBBLES,
    df.tiletype_shape.TWIG,
    df.tiletype_shape.SAPLING,
    df.tiletype_shape.SHRUB,
}

local function tile_ok(pos, need_inside)
    local flags, occ = dfhack.maps.getTileFlags(pos)
    if not flags or flags.hidden or occ.building ~= df.tile_building_occ.None then return false end
    if flags.flow_size > 1 or (flags.liquid_type == df.tile_liquid.Magma and flags.flow_size > 0) then
        return false
    end
    if need_inside and flags.outside then return false end
    local tt = dfhack.maps.getTileType(pos)
    return (tt and OK_SHAPES[df.tiletype.attrs[tt].shape]) and true or false
end

-- is every tile of the footprint cell at corner (cx, cy) placeable? memoized per drag, so the
-- per-frame preview doesn't re-read the map for cells it has already judged.
local function cell_ok(cap, cx, cy)
    local key = cx .. ',' .. cy
    local hit = cap.vcache[key]
    if hit ~= nil then return hit end
    local ok = true
    for ty = cy, cy + cap.fh - 1 do
        for tx = cx, cx + cap.fw - 1 do
            if not tile_ok(xyz2pos(tx, ty, cap.anchor.z), cap.need_inside) then ok = false; break end
        end
        if not ok then break end
    end
    cap.vcache[key] = ok
    return ok
end

-- ---- the grid ------------------------------------------------------------

-- top-left corners of every building in the grid, tiled FLUSH from the first building's corner
-- (ox, oy) toward the release tile, stepping by footprint. (0,0) is the first building itself.
local function grid_corners(ox, oy, fw, fh, rel)
    local ocx, ocy = ox + fw // 2, oy + fh // 2          -- first building's centre (~ mouse-down)
    local nx = math.floor(math.abs(rel.x - ocx) / fw)
    local ny = math.floor(math.abs(rel.y - ocy) / fh)
    while (nx + 1) * (ny + 1) > MAX_BUILDINGS do
        if nx >= ny then nx = nx - 1 else ny = ny - 1 end
    end
    local sx = (rel.x >= ocx) and 1 or -1
    local sy = (rel.y >= ocy) and 1 or -1
    local out = {}
    for i = 0, nx do for j = 0, ny do
        out[#out + 1] = {x = ox + i * fw * sx, y = oy + j * fh * sy, is_anchor = (i == 0 and j == 0)}
    end end
    return out
end

-- place every grid cell -- anchor included, since the mouse-down building was retracted.
local function place_grid(cap, rel)
    local fw, fh, z = cap.fw, cap.fh, cap.anchor.z
    local blds = {}
    for _, c in ipairs(grid_corners(cap.ox, cap.oy, fw, fh, rel)) do
        if cell_ok(cap, c.x, c.y) then
            local ok, bld = pcall(dfhack.buildings.constructBuilding, {pos = xyz2pos(c.x, c.y, z),
                type = cap.type, subtype = cap.subtype, custom = cap.custom,
                width = fw, height = fh, direction = cap.direction, filters = cap.filters})
            if ok and bld then
                for k in pairs(bld) do
                    if k == 'track_stop_info' then utils.assign(bld.track_stop_info, uibs.track_stop) end
                    if k == 'speed' then bld.speed = uibs.speed end
                    if k == 'plate_info' then utils.assign(bld.plate_info, uibs.plate_info) end
                end
                blds[#blds + 1] = bld
            end
        end
    end
    if #blds > 0 then
        local buildingplan = require('plugins.buildingplan')
        for _, bld in ipairs(blds) do buildingplan.addPlannedBuilding(bld) end
        buildingplan.scheduleCycle()
    end
    return #blds
end

-- ---- overlay -------------------------------------------------------------

PlanTile = defclass(PlanTile, overlay.OverlayWidget)
PlanTile.ATTRS{
    desc = 'Left-drag during building placement to lay a whole grid of that building at once.',
    default_pos = {x = -1, y = -1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Building/Placement',
    frame = {w = 1, h = 1},           -- invisible; onupdate/onRenderFrame still see map-wide input
    overlay_onupdate_max_freq_seconds = 0,
}

-- consume the press our planner hook swallowed; commit the grid on release.
function PlanTile:overlay_onupdate()
    install_planner_hook()             -- self-heals after overlay rescans / module reloads
    if not engaged() then
        pending_press, self.cap = nil, nil
        return
    end
    if pending_press then              -- drag begins: the planner never saw this click
        local pos = pending_press
        pending_press = nil
        local fw, fh = footprint()
        self.cap = {
            anchor = copyall(pos), fw = fw, fh = fh,
            need_inside = INSIDE_ONLY[uibs.building_type] or false, vcache = {},
            type = uibs.building_type, subtype = uibs.building_subtype,
            custom = uibs.custom_type, direction = uibs.direction,
            filters = dfhack.buildings.getFiltersByType({},
                uibs.building_type, uibs.building_subtype, uibs.custom_type),
            -- the same corner math the planner itself uses (cursor - footprint/2)
            ox = pos.x - fw // 2, oy = pos.y - fh // 2,
        }
    end
    if self.cap and df.global.enabler.mouse_lbut_down ~= 1 then   -- release: commit
        local rel = dfhack.gui.getMousePos()
        if rel and rel.z == self.cap.anchor.z then
            local n = place_grid(self.cap, rel)
            if n > 0 then
                print(('plan-tile: placed %d %s'):format(n,
                    n == 1 and 'building' or 'buildings'))
            end
        end
        self.cap = nil
    end
end

-- live preview: a transparent GHOST of the actual building on every grid cell.
--
-- DF draws the placement hologram (the see-through building under the mouse) into
-- gps.main_viewport.screentexpos_interface and renders that layer with alpha. paintTile
-- can't produce transparency, so instead we capture the hologram's texpos block from under
-- the mouse each frame and write copies into that same layer at every other grid cell --
-- DF's own renderer then draws true transparent ghosts of the actual building for us.
-- (Writes are re-done every frame because DF rebuilds the layer each frame; slots already
-- nonzero are left alone so we never overwrite DF's own drawings.)
--
-- Cells that fail the placement rules are painted red instead; if the hologram can't be
-- captured (mouse over UI, odd zoom edge cases) valid cells fall back to green tiles.
local ok_pens, bp_pens = pcall(require, 'plugins.buildingplan.pens')
local PREVIEW_PEN = (ok_pens and bp_pens and bp_pens.GOOD_TILE_PEN)
    or dfhack.pen.parse{ch = 'X', fg = COLOR_GREEN, keep_lower = true}
local BAD_PEN = (ok_pens and bp_pens and bp_pens.BAD_TILE_PEN)
    or dfhack.pen.parse{ch = 'X', fg = COLOR_RED, keep_lower = true}

function PlanTile:onRenderFrame(dc, rect)
    if not (self.cap and df.global.enabler.mouse_lbut_down == 1) then return end
    local cur = dfhack.gui.getMousePos()
    if not cur or cur.z ~= self.cap.anchor.z then return end
    local vp = guidm.Viewport.get()
    if vp.z ~= self.cap.anchor.z then return end
    local cap = self.cap
    local fw, fh, z = cap.fw, cap.fh, cap.anchor.z

    -- capture the live hologram: the fw x fh block of interface-layer texpos under the
    -- mouse. DF's anchoring of the hologram varies subtly with building size, so don't
    -- assume mouse-centering: search around the expected corner for a FULLY nonzero
    -- fw x fh block (a hologram covers its whole footprint) and take the closest match.
    local gvp = df.global.gps.main_viewport
    local arr = gvp.screentexpos_interface
    local dimx, dimy = gvp.dim_x, gvp.dim_y
    local gx, gy = cur.x - fw // 2 - vp.x1, cur.y - fh // 2 - vp.y1  -- expected corner
    local best, bestd
    for cx = gx - fw, gx + fw do
        for cy = gy - fh, gy + fh do
            if cx >= 0 and cy >= 0 and cx + fw <= dimx and cy + fh <= dimy then
                local full = true
                for i = 0, fw - 1 do
                    for j = 0, fh - 1 do
                        if arr[(cx + i) * dimy + (cy + j)] == 0 then full = false; break end
                    end
                    if not full then break end
                end
                if full then
                    local d = math.abs(cx - gx) + math.abs(cy - gy)
                    if not bestd or d < bestd then best, bestd = cx * dimy + cy, d end
                end
            end
        end
    end
    local ghost, captured = {}, best ~= nil
    if captured then
        local bx, by = best // dimy, best % dimy
        for i = 0, fw - 1 do
            for j = 0, fh - 1 do
                ghost[i * fh + j] = arr[(bx + i) * dimy + (by + j)]
            end
        end
    end

    for _, c in ipairs(grid_corners(cap.ox, cap.oy, fw, fh, cur)) do
        -- anchor cell included: the mouse-down building was retracted, so it's all ghosts
        local valid = cell_ok(cap, c.x, c.y)
        for i = 0, fw - 1 do
            for j = 0, fh - 1 do
                local pos = {x = c.x + i, y = c.y + j, z = z}
                if vp:isVisible(pos) then
                    local g = valid and captured and ghost[i * fh + j] or 0
                    if g ~= 0 then
                        local vx, vy = pos.x - vp.x1, pos.y - vp.y1
                        if vx >= 0 and vx < dimx and vy >= 0 and vy < dimy then
                            local dst = vx * dimy + vy
                            if arr[dst] == 0 then arr[dst] = g end
                        end
                    else
                        local s = vp:tileToScreen(pos)
                        dfhack.screen.paintTile(valid and PREVIEW_PEN or BAD_PEN,
                            s.x, s.y, nil, nil, true)
                    end
                end
            end
        end
    end
end

OVERLAY_WIDGETS = {tile = PlanTile}

if not dfhack_flags.module then
    require('plugins.overlay').rescan()
    dfhack.run_command('overlay', 'enable', 'plan-tile.tile')
    print('plan-tile: overlay enabled.')
    print('  During building placement, left-drag a box to place a grid of that building,')
    print('  tiled by its footprint (every 3 tiles for a 3x3 workshop, etc.).')
end
