-- RTS map interactions: right-click -> mining; shaped Dig boxes -> stairs / walls / chop / remove.
--@module = true
--[[
RIGHT-CLICK on the exposed map (dwarfmode/Default) -> enter mining (Dig) mode. Routed through
map_pos_if_clear() so a click on a panel/notification/other overlay is NOT hijacked.

SHAPED DIG BOXES are reclassified on completion:
  * 1x1xN single column                 -> STAIRCASE (carve stairs in rock, construct in air).
  * selection through OPEN-AIR tiles     -> constructed WALLS/FLOORS, bottom-up (wall if the tile
                                            below is a wall -- natural or a placed wall -- else floor).
  * selection of ONLY constructions/ramps (air allowed) -> designate them for REMOVAL.
  * tree tiles                            -> CHOP.
  * natural rock                          -> left as ordinary dig (mining).

DEBUG: set DEBUG=true to append a trace to the log file (read by the maintainer while testing).
Toggle live with:  dig-shapes debug on|off
]]

local overlay = require('plugins.overlay')
local buildingplan = require('plugins.buildingplan')
local utils = require('utils')

local DV = df.tile_dig_designation
local CT = df.construction_type
local SH = df.tiletype_shape
local TM = df.tiletype_material
local sr = df.global.selection_rect

-- ---- debug log --------------------------------------------------------------
local LOGFILE = '/tmp/claude-1000/-home-mag-Downloads-code-dfhack-commands/d7187ea9-db68-452e-893b-e9108000916e/scratchpad/dig-shapes.log'
local DEBUG = false
local function log(msg)
    if not DEBUG then return end
    local fh = io.open(LOGFILE, 'a')
    if fh then fh:write(msg .. '\n'); fh:close() end
end
local function fmt(p) return ('%d,%d,z%d'):format(p.x, p.y, p.z) end

local function mi() return df.global.game.main_interface end
local function enter_mining() mi().main_designation_selected = df.main_designation_type.DIG_DIG end

local WINDOW_COLS = 28   -- dwarf-rts's right-side squads window band; yield right-clicks there

-- signature of the native announcement/alert state; if it changes across an unconsumed
-- right-click, the click hit (and dismissed) an alert -> we must NOT then enter mining.
local function alert_sig()
    local ok, n = pcall(function() return #mi().announcements.stack.children end)
    return ok and n or -1
end

-- ---- map-click UI guard -----------------------------------------------------

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

-- cursor over some OTHER visible overlay (a notification, etc.)? optionally names it into `hit`.
local function over_other_overlay(mx, my, hit)
    local vs = dfhack.gui.getDFViewscreen(true)
    local fullw, fullh = df.global.gps.dimx - 1, df.global.gps.dimy - 1
    for name, e in pairs(overlay.get_state().db) do
        if name ~= 'dig-shapes.watcher' then
            local w = e.widget
            local r = w.frame_rect
            if r and mx >= r.x1 and mx <= r.x2 and my >= r.y1 and my <= r.y2
                and not (r.x1 <= 0 and r.y1 <= 0 and r.x2 >= fullw and r.y2 >= fullh)
                and widget_on_screen(w, vs)
            then
                local ok, vis = pcall(function() return utils.getval(w.visible) end)
                if ok and vis then if hit then hit[#hit + 1] = name end return true end
            end
        end
    end
    return false
end

local function map_pos_if_clear()
    local pos = dfhack.gui.getMousePos()
    if not pos then return nil end
    local m = mi()
    if m.current_hover ~= -1 then return nil end
    if m.current_hover_alert then return nil end   -- over a native DF notification/alert
    if over_other_overlay(df.global.gps.mouse_x, df.global.gps.mouse_y) then return nil end
    return pos
end

-- ---- tile classification ----------------------------------------------------

local function tt_of(pos) return dfhack.maps.getTileType(pos) end
local function shape_of(pos) local tt = tt_of(pos); return tt and df.tiletype.attrs[tt].shape end
local function material_of(pos) local tt = tt_of(pos); return tt and df.tiletype.attrs[tt].material end

local function is_empty(pos) return shape_of(pos) == SH.EMPTY end
-- a tile we can build a wall/floor/stair ON: open air OR an existing (natural) floor
local function is_buildable_open(pos)
    local s = shape_of(pos)
    -- EMPTY air, a FLOOR, a floor strewn with rock (PEBBLES / BOULDER), or a floor with a plant
    -- on it (SAPLING / SHRUB -- dead saplings and harvestable plants). Building there just clears
    -- whatever's on the floor.
    return s == SH.EMPTY or s == SH.FLOOR or s == SH.PEBBLES or s == SH.BOULDER
        or s == SH.SAPLING or s == SH.SHRUB
end
local function is_tree(pos) return material_of(pos) == TM.TREE end
-- completed OR in-progress construction on this tile?
local function construction_here(pos)
    if dfhack.constructions.findAtTile(pos) then return true end
    local b = dfhack.buildings.findAtTile(pos)
    return b and b:getType() == df.building_type.Construction or false
end
-- a natural ramp/slope (not a tree-slope, not a constructed ramp)
local function is_natural_ramp(pos)
    return shape_of(pos) == SH.RAMP and material_of(pos) ~= TM.TREE and material_of(pos) ~= TM.CONSTRUCTION
        and not construction_here(pos)
end
-- a natural, minable rock/soil wall
local function is_diggable_wall(pos)
    return shape_of(pos) == SH.WALL and material_of(pos) ~= TM.TREE and material_of(pos) ~= TM.CONSTRUCTION
        and not construction_here(pos)
end
-- a tile that already has an up-stair carved into it (a staircase continuing up from below)
local function is_up_stair(pos) return shape_of(pos) == SH.STAIR_UP end
-- a natural floor (incl. rock-strewn / plant-covered) that a DOWN stair can be CARVED into --
-- DF digs down through a floor natively, no construction or materials needed
local function is_carveable_floor(pos)
    local s = shape_of(pos)
    if s ~= SH.FLOOR and s ~= SH.PEBBLES and s ~= SH.BOULDER
        and s ~= SH.SAPLING and s ~= SH.SHRUB then return false end
    local m = material_of(pos)
    return m ~= TM.TREE and m ~= TM.CONSTRUCTION and not construction_here(pos)
end

-- is pos a wall? natural/completed wall (WALL shape) OR a placed (even in-progress) wall
-- construction whose tile may still read as EMPTY.
local function is_wall_tile(pos)
    if shape_of(pos) == SH.WALL and material_of(pos) ~= TM.TREE then return true end
    local b = dfhack.buildings.findAtTile(pos)
    if b and b:getType() == df.building_type.Construction and b.type == CT.Wall then return true end
    return false
end

-- does this tile already have a floor on its own layer? -> a real FLOOR tile, a planned/built
-- floor construction here, OR the walkable TOP of a wall directly below (a wall implies a floor
-- one layer up). If so we build a WALL on it; if there's NO floor, we build a FLOOR.
local function has_floor_here(pos)
    local s = shape_of(pos)
    -- ground: a plain floor, a floor strewn with rock (pebbles/boulder), or a floor with a plant
    if s == SH.FLOOR or s == SH.PEBBLES or s == SH.BOULDER or s == SH.SAPLING or s == SH.SHRUB then return true end
    local b = dfhack.buildings.findAtTile(pos)
    if b and b:getType() == df.building_type.Construction and b.type == CT.Floor then return true end
    return is_wall_tile({x = pos.x, y = pos.y, z = pos.z - 1})
end

local function has_wall_below(pos)
    return is_wall_tile({x = pos.x, y = pos.y, z = pos.z - 1})
end

-- how many of the 4 orthogonal neighbors are walls (for door / doorway detection)
local function ortho_wall_count(pos)
    local n = 0
    for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
        if is_wall_tile({x = pos.x + d[1], y = pos.y + d[2], z = pos.z}) then n = n + 1 end
    end
    return n
end

-- ---- designation / construction primitives ----------------------------------

local function block_of(pos) return dfhack.maps.getTileBlock(pos) end
local function set_dig(pos, val)
    local blk = block_of(pos); if not blk then return end
    blk.designation[pos.x % 16][pos.y % 16].dig = val
    blk.flags.designated = true
end
local function clear_dig(pos)
    local blk = block_of(pos); if not blk then return end
    blk.designation[pos.x % 16][pos.y % 16].dig = DV.No
end

local SMOOTHABLE = {}
for _, n in ipairs({'STONE', 'MINERAL', 'LAVA_STONE', 'FEATURE'}) do
    if TM[n] then SMOOTHABLE[TM[n]] = true end
end
-- designate smoothing on a natural-stone tile (ignored on soil/air/constructions). dig+smooth
-- coexist, so an interior tile being mined smooths itself into a smooth floor after it's dug.
-- CRITICAL: skip tiles that are ALREADY smooth -- smooth=1 on an already-smooth wall carves a
-- FORTIFICATION and on an already-smooth floor ENGRAVES it (that is how DF designates those).
local function designate_smooth(pos)
    if not SMOOTHABLE[material_of(pos)] then return end
    local tt = dfhack.maps.getTileType(pos)
    if tt and df.tiletype.attrs[tt].special == df.tiletype_special.SMOOTH then return end
    local blk = block_of(pos); if not blk then return end
    blk.designation[pos.x % 16][pos.y % 16].smooth = 1
    blk.flags.designated = true
end

-- place a construction via BUILDINGPLAN, so it uses whatever material/quality the player has
-- configured for that construction type (e.g. obsidian blocks for walls) rather than "any
-- material". buildingplan applies the per-type filter and reserves matching items.
local function construct_real(pos, subtype)
    if dfhack.buildings.findAtTile(pos) then return end
    local ok, bld = pcall(dfhack.buildings.constructBuilding,
        {type = df.building_type.Construction, subtype = subtype, pos = pos})
    if not ok or not bld then log('  construct FAILED @' .. fmt(pos)); return end
    local b = (type(bld) == 'table') and bld[1] or bld
    if b then buildingplan.addPlannedBuilding(b) end
    log(('  construct %s (buildingplan) @%s'):format(df.construction_type[subtype], fmt(pos)))
end

-- build a Door via buildingplan (a door is built from a crafted door ITEM, which buildingplan
-- reserves per its filters). Needs a doorway -- constructBuilding returns nil without adjacent walls.
local function construct_door(pos)
    if dfhack.buildings.findAtTile(pos) then return end
    local ok, bld = pcall(dfhack.buildings.constructBuilding, {type = df.building_type.Door, pos = pos})
    if not ok or not bld then log('  door FAILED @' .. fmt(pos)); return end
    local b = (type(bld) == 'table') and bld[1] or bld
    if not b then return end
    buildingplan.addPlannedBuilding(b)
    log('  DOOR (buildingplan) @' .. fmt(pos))
end

local function remove_here(pos)
    -- completed/in-progress construction -> constructions API; natural ramp -> mine it away
    if construction_here(pos) then
        local ok = pcall(dfhack.constructions.designateRemove, pos)
        if not ok then ok = pcall(dfhack.constructions.designateRemove, pos.x, pos.y, pos.z) end
        log(('  remove construction @%s ok=%s'):format(fmt(pos), tostring(ok)))
    else
        set_dig(pos, DV.Default)
        log(('  remove ramp (dig=Default) @%s'):format(fmt(pos)))
    end
end

-- ---- conversions ------------------------------------------------------------

local function make_staircase(x, y, z1, z2)
    for z = z1, z2 do
        local pos = {x = x, y = y, z = z}
        local dig_val, con_sub
        if z == z2 then dig_val, con_sub = DV.DownStair, CT.DownStair
        elseif z == z1 then dig_val, con_sub = DV.UpStair, CT.UpStair
        else dig_val, con_sub = DV.UpDownStair, CT.UpDownStair end
        -- if the bottom of the column already has an up-stair carved (a staircase continues below),
        -- carve an up/DOWN stair here instead of a plain up-stair so the new column connects down.
        if z == z1 and is_up_stair(pos) then dig_val = DV.UpDownStair end
        if construction_here(pos) then
            log('  stair SKIP (already a construction) @' .. fmt(pos))
        elseif is_up_stair(pos) then
            -- existing carved up-stair: re-designate to extend the stairway downward
            set_dig(pos, dig_val)
            log(('  stair EXTEND (was up-stair) dig=%s @%s'):format(df.tile_dig_designation[dig_val], fmt(pos)))
        elseif is_diggable_wall(pos) then
            set_dig(pos, dig_val)
            log(('  stair CARVE dig=%s @%s'):format(df.tile_dig_designation[dig_val], fmt(pos)))
        elseif is_carveable_floor(pos) and z > z1 then
            -- a natural FLOOR in the column (usually the tile you stand on when digging DOWN):
            -- carve a DOWN stair into it -- DF digs through floors natively. This used to fall
            -- through to the constructed-stair path, which demanded building materials (and a
            -- build job) for what a miner can simply dig, so "dig down from here" never carved.
            -- The up-connection comes from the tile below being carved up/up-down. The column's
            -- BOTTOM tile (z == z1) is excluded: a down stair there would dig deeper than asked;
            -- a floor at the bottom still needs a constructed up stair to climb out of.
            set_dig(pos, DV.DownStair)
            log(('  stair CARVE floor dig=DownStair @%s'):format(fmt(pos)))
        elseif is_tree(pos) then
            set_dig(pos, DV.Default); log('  stair CHOP tree @' .. fmt(pos))
        elseif is_buildable_open(pos) then
            clear_dig(pos); construct_real(pos, con_sub)
        else
            log('  stair SKIP (other) @' .. fmt(pos))
        end
    end
end

-- classify a completed dig box and act. returns true if it did anything.
function convert_dig_box(a, b)
    local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
    local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
    local z1, z2 = math.min(a.z, b.z), math.max(a.z, b.z)
    local dx, dy, dz = x2 - x1 + 1, y2 - y1 + 1, z2 - z1 + 1
    log(('convert_dig_box %dx%dx%d  (%d,%d,%d)->(%d,%d,%d)'):format(dx, dy, dz, x1, y1, z1, x2, y2, z2))

    if dx == 1 and dy == 1 and dz > 1 then
        log('  -> STAIRCASE (1x1xN column)')
        make_staircase(x1, y1, z1, z2)
        return true
    end

    local cons, ramps, trees, rocks, opens = {}, {}, {}, {}, {}
    for z = z1, z2 do for y = y1, y2 do for x = x1, x2 do
        local pos = {x = x, y = y, z = z}
        if construction_here(pos) then cons[#cons + 1] = pos
        elseif is_natural_ramp(pos) then ramps[#ramps + 1] = pos
        elseif is_tree(pos) then trees[#trees + 1] = pos
        elseif is_buildable_open(pos) then opens[#opens + 1] = pos
        elseif is_diggable_wall(pos) then rocks[#rocks + 1] = pos end
    end end end
    log(('  scan: cons=%d ramps=%d trees=%d rocks=%d opens=%d'):format(
        #cons, #ramps, #trees, #rocks, #opens))

    -- selection is ONLY removables (constructions/ramps), open tiles allowed -> designate removal
    if (#cons + #ramps) > 0 and #trees == 0 and #rocks == 0 then
        log('  -> REMOVE (constructions/ramps)')
        for _, p in ipairs(cons) do remove_here(p) end
        for _, p in ipairs(ramps) do remove_here(p) end
        return true
    end

    local did = false
    -- Geometry rules for build-intent selections (every tile open, no rock/dig tile):
    --   * a WALL must be 1xNxM -- 1 tile thick in a horizontal axis (a vertical plane), any
    --     vertical span. A footprint thicker than 1 in BOTH horizontal axes is a "thick" box.
    --   * a FLOOR slab may be NxMx1 -- any horizontal footprint but a SINGLE z-level -- but only
    --     when the ENTIRE area would be floor (no tile in it would become a wall).
    -- A tile becomes a WALL when has_floor_here(p) (something to stand a wall on), else a FLOOR.
    local thick = dx > 1 and dy > 1
    local all_floor = true
    for _, p in ipairs(opens) do if has_floor_here(p) then all_floor = false; break end end
    local floor_slab = all_floor and dz == 1   -- an NxMx1 all-floor slab is allowed even when thick
    if #opens > 0 and #rocks == 0 and (not thick or floor_slab) then
        -- a single 1x1 click on an open tile flanked by exactly 2 orthogonal walls is a doorway
        -- -> build a DOOR instead of a wall
        local single = dx == 1 and dy == 1 and dz == 1
        table.sort(opens, function(p, q) return p.z < q.z end)
        for _, p in ipairs(opens) do
            clear_dig(p)
            if single and ortho_wall_count(p) == 2 then
                construct_door(p)
            else
                -- WALL where the tile already has a floor to stand a wall on (real/planned floor,
                -- or the top of a wall below); FLOOR where there's no floor on this layer
                construct_real(p, has_floor_here(p) and CT.Wall or CT.Floor)
            end
            did = true
        end
    end
    for _, p in ipairs(trees) do set_dig(p, DV.Default); log('  CHOP tree @' .. fmt(p)); did = true end
    -- (room smoothing removed -- the implementation was wrong; nothing is designated for smoothing)
    return did
end

-- ---- overlay ----------------------------------------------------------------

DigShapes = defclass(DigShapes, overlay.OverlayWidget)
DigShapes.ATTRS{
    desc = 'Right-click enters mining; shaped Dig boxes become stairs/walls/chop/removal.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

local function dig_tool_active()
    return mi().main_designation_selected == df.main_designation_type.DIG_DIG
end

function DigShapes:overlay_onupdate()
    local active = dig_tool_active() and sr.start_z >= 0
    if active then
        if not self.corner then                 -- drag just began: start fresh (clear any stale cancel)
            self.corner = {x = sr.start_x, y = sr.start_y, z = sr.start_z}
            self.cancelled = false
        end
        local mp = dfhack.gui.getMousePos()
        if mp then self.last = mp end
    elseif self.corner then
        -- The drag ended: convert the shape unless it was cancelled. We do NOT try to infer a
        -- cancel from the mouse-button state -- DF box designations commit with the left button
        -- STILL HELD (the box commits on the second click, not on release), so a "left-still-down
        -- means cancelled" heuristic wrongly discarded every COMPLETED chop/wall/stair. And the
        -- right button is our "enter mining" gesture, so a right-press poll can't mean cancel
        -- either. So cancellation is signalled ONLY by onInput (Escape / right-click while a drag
        -- is pending), and a plain completed box always converts.
        local aa, bb, cancelled = self.corner, self.last, self.cancelled
        self.corner, self.last, self.cancelled = nil, nil, nil
        log(('drag ended: cancelled=%s'):format(tostring(cancelled)))
        if aa and bb and not cancelled then
            dfhack.timeout(1, 'frames', function() pcall(convert_dig_box, aa, bb) end)
        end
    end
end

-- Right-click on the open map -> enter mining. We must CONSUME the click to enter mining (an
-- unconsumed right-click on dwarfmode/Default is cancelled by DF). So we yield (return false,
-- letting DF/dwarf-rts handle it) whenever the cursor is over UI: the dwarf-rts right-side band,
-- an announcement alert, another overlay, a DF hover element, or off the exposed map.
function DigShapes:onInput(keys)
    -- Cancelling an IN-PROGRESS dig drag (right-click or Escape) must not be treated as
    -- completing the box. Flag it so overlay_onupdate discards the pending selection, and let
    -- DF process the cancel natively (a right-click here never falls through to enter mining).
    if self.corner and (keys._MOUSE_R or keys.LEAVESCREEN) then
        self.cancelled = true
        return false
    end

    if keys._MOUSE_R then
        local focus = dfhack.gui.getCurFocus(true)[1] or ''
        -- Enter mining on a right-click over the open map, from the normal view ONLY. On the
        -- open squads screen a map right-click belongs to dwarf-rts (deselect, then close);
        -- mining from there goes through the bottom toolbar instead (orders survive and the
        -- panel reopens when the tool is put away -- dwarf-rts's designation close-guard).
        if focus == 'dwarfmode/Default' then
            local mp = dfhack.gui.getMousePos()
            local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
            local m = mi()
            local ooo = over_other_overlay(mx, my)
            local in_band = mx >= df.global.gps.dimx - WINDOW_COLS   -- dwarf-rts squads band
            -- DF sets current_hover_left_x to the left edge of whatever UI element the cursor is
            -- over (the alert reads 4); it stays 0 over the open map. Non-zero => over UI.
            local on_ui = m.current_hover_left_x ~= 0
            -- explicit never-mine zone: the left 2 columns everywhere + the top-left 4x4 corner
            local in_zone = mx < 2 or (mx < 4 and my < 4)
            if mp and m.current_hover == -1 and not m.current_hover_alert and not ooo
                and not in_band and not on_ui and not in_zone then
                enter_mining()
                return true
            end
        end
    end
    return false   -- yield: dwarf-rts / DF / alerts handle the right-click
end

OVERLAY_WIDGETS = {watcher = DigShapes}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dig-shapes: right-click=mining; shaped digs=stairs/walls/chop/remove.')
