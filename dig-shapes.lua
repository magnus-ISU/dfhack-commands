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
local DEBUG = true
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
    return s == SH.EMPTY or s == SH.FLOOR
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

-- is pos a wall? natural/completed wall (WALL shape) OR a placed (even in-progress) wall
-- construction whose tile may still read as EMPTY.
local function is_wall_tile(pos)
    if shape_of(pos) == SH.WALL and material_of(pos) ~= TM.TREE then return true end
    local b = dfhack.buildings.findAtTile(pos)
    if b and b:getType() == df.building_type.Construction and b.type == CT.Wall then return true end
    return false
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

-- is this a gap in a wall line? walls on both opposite orthogonal sides (E&W or N&S). Such a
-- tile should be a WALL (completing the line) even with air below, not a cantilevered floor.
local function between_walls(pos)
    return (is_wall_tile({x = pos.x - 1, y = pos.y, z = pos.z}) and is_wall_tile({x = pos.x + 1, y = pos.y, z = pos.z}))
        or (is_wall_tile({x = pos.x, y = pos.y - 1, z = pos.z}) and is_wall_tile({x = pos.x, y = pos.y + 1, z = pos.z}))
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
local function designate_smooth(pos)
    if not SMOOTHABLE[material_of(pos)] then return end
    local blk = block_of(pos); if not blk then return end
    blk.designation[pos.x % 16][pos.y % 16].smooth = 1
    blk.flags.designated = true
end

-- place a REAL construction (dwarves build it with any available material) -- not a blueprint
local function construct_real(pos, subtype)
    if dfhack.buildings.findAtTile(pos) then log('  construct SKIP occupied @' .. fmt(pos)); return end
    local ok, bld = pcall(dfhack.buildings.constructBuilding,
        {type = df.building_type.Construction, subtype = subtype, pos = pos})
    local b = (type(bld) == 'table') and bld[1] or bld
    local njobs = (ok and b) and #b.jobs or -1
    local susp = (njobs and njobs > 0) and tostring(b.jobs[0].flags.suspend) or 'n/a'
    log(('  construct %s @%s ok=%s bld=%s jobs=%s suspend=%s'):format(
        df.construction_type[subtype], fmt(pos), tostring(ok), tostring(b ~= nil), tostring(njobs), susp))
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
        if construction_here(pos) then
            log('  stair SKIP (already a construction) @' .. fmt(pos))
        elseif is_diggable_wall(pos) then
            set_dig(pos, dig_val)
            log(('  stair CARVE dig=%s @%s'):format(df.tile_dig_designation[dig_val], fmt(pos)))
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
    -- walls/floors only when the footprint is 1 tile thick in a horizontal axis (a 1xNxN or
    -- Nx1xN plane, or a thin line) -- a 2xNxN or thicker footprint is rejected
    local thick = dx > 1 and dy > 1
    if #opens > 0 and thick then
        log(('  -> SKIP build: %dx%dx%d footprint thicker than 1 (walls need 1xNxN / Nx1xN)'):format(dx, dy, dz))
    else
        -- a single 1x1 click on an open tile flanked by exactly 2 orthogonal walls is a doorway
        -- -> build a DOOR instead of a wall; any other 1x1 stays a wall/floor
        local single = dx == 1 and dy == 1 and dz == 1
        -- build bottom-up so each course sees the (just-placed) one below it
        table.sort(opens, function(p, q) return p.z < q.z end)
        for _, p in ipairs(opens) do
            clear_dig(p)
            if single and ortho_wall_count(p) == 2 then
                construct_door(p)
            else
                local sub = (has_wall_below(p) or between_walls(p)) and CT.Wall or CT.Floor
                construct_real(p, sub)
            end
            did = true
        end
    end
    for _, p in ipairs(trees) do set_dig(p, DV.Default); log('  CHOP tree @' .. fmt(p)); did = true end

    -- a flat rock ROOM dig -> also queue SMOOTHING of the whole room + a 1-tile-wider border
    -- (the mined-out floor and the surrounding walls). dig+smooth coexist, so interior tiles
    -- smooth after they are dug; border walls smooth once the room exposes their faces.
    if z1 == z2 and dx > 1 and dy > 1 and #rocks > 0 then
        for x = x1 - 1, x2 + 1 do for y = y1 - 1, y2 + 1 do
            designate_smooth({x = x, y = y, z = z1})
        end end
        log(('  SMOOTH room+border (%d,%d)->(%d,%d)'):format(x1 - 1, y1 - 1, x2 + 1, y2 + 1))
        did = true
    end
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
    if dig_tool_active() and sr.start_z >= 0 then
        self.corner = self.corner or {x = sr.start_x, y = sr.start_y, z = sr.start_z}
        local mp = dfhack.gui.getMousePos()
        if mp then self.last = mp end
    elseif self.corner then
        local aa, bb = self.corner, self.last
        self.corner, self.last = nil, nil
        if aa and bb then
            dfhack.timeout(1, 'frames', function() pcall(convert_dig_box, aa, bb) end)
        end
    end
end

-- Right-click on the open map -> enter mining. We must CONSUME the click to enter mining (an
-- unconsumed right-click on dwarfmode/Default is cancelled by DF). So we yield (return false,
-- letting DF/dwarf-rts handle it) whenever the cursor is over UI: the dwarf-rts right-side band,
-- an announcement alert, another overlay, a DF hover element, or off the exposed map.
function DigShapes:onInput(keys)
    if keys._MOUSE_R and (dfhack.gui.getCurFocus(true)[1] or '') == 'dwarfmode/Default' then
        local mp = dfhack.gui.getMousePos()
        local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
        local m = mi()
        local hit = {}
        local ooo = over_other_overlay(mx, my, hit)
        local in_band = mx >= df.global.gps.dimx - WINDOW_COLS   -- dwarf-rts squads band
        -- DF sets current_hover_left_x to the left edge of whatever UI element the cursor is
        -- over (the alert reads 4); it stays 0 over the open map. Non-zero => over UI, don't mine.
        local on_ui = m.current_hover_left_x ~= 0
        -- explicit never-mine zone: the left 2 columns everywhere + the top-left 4x4 corner
        local in_zone = mx < 2 or (mx < 4 and my < 4)
        log(('RCLICK gps=%d,%d | mp=%s hover=%d alert=%s over=%s[%s] band=%s on_ui=%s(lx%d) zone=%s'):format(
            mx, my, tostring(mp ~= nil), m.current_hover, tostring(m.current_hover_alert),
            tostring(ooo), table.concat(hit, ','), tostring(in_band),
            tostring(on_ui), m.current_hover_left_x, tostring(in_zone)))
        if mp and m.current_hover == -1 and not m.current_hover_alert and not ooo
            and not in_band and not on_ui and not in_zone then
            enter_mining()
            return true
        end
    end
    return false   -- yield: dwarf-rts / DF / alerts handle the right-click
end

OVERLAY_WIDGETS = {watcher = DigShapes}

if dfhack_flags.module then return end

local args = {...}
if args[1] == 'debug' then
    print('dig-shapes: set DEBUG in the source; logging to ' .. LOGFILE)
    return
end

require('plugins.overlay').rescan()
print('dig-shapes: right-click=mining; shaped digs=stairs/walls/chop/remove. DEBUG log: ' .. LOGFILE)
