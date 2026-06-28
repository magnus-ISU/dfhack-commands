-- Drag designate / drag remove for designation & build tools, plus right-click-to-cancel.
--@module = true
--[[
right-click-cancel

Mouse helpers for DF's designation and construction tools (overlay "right-click-cancel.cancel"):

  * LEFT-DRAG a box (in "box select" / rectangle mode) APPLIES the designation across the box
    immediately -- no two-click. Works for dig, the dig sub-types (channel / ramps / up,
    down & up-down stairs), woodcutting (chop), and plant gathering. Only diggable/valid
    tiles in the box are designated (same rules the game uses).
  * LEFT single-click (press & release on one tile) is passed through to the game unchanged,
    so the normal click-click designation still works for precise corners.
  * RIGHT-DRAG a box REMOVES everything designated in it (dig/chop/gather designations and
    in-progress buildings).
  * RIGHT single-click cancels whatever is designated under the cursor (a dig designation, a
    tree/plant marked for chop/gather, or an in-progress construction/building). A right
    click on an empty tile passes through (DF's normal "leave the tool").

Toggle or move it with gui/overlay; magnus-scripts enables it each session.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local MD = df.main_designation_type
local DV = df.tile_dig_designation

-- ============================================================================
-- CANCEL side (right-click / right-drag)
-- ============================================================================

-- designation tools in which right-click should cancel
local ACTIVE_DESIG = {}
for _, name in ipairs({
    'DIG_DIG', 'DIG_REMOVE_STAIRS_RAMPS', 'DIG_STAIR_UP', 'DIG_STAIR_UPDOWN', 'DIG_STAIR_DOWN',
    'DIG_RAMP', 'DIG_CHANNEL', 'DIG_FROM_MARKER', 'DIG_TO_MARKER',
    'CHOP', 'CHOP_FROM_MARKER', 'CHOP_TO_MARKER',
    'GATHER', 'GATHER_FROM_MARKER', 'GATHER_TO_MARKER',
    'SMOOTH', 'ENGRAVE', 'TRACK', 'FORTIFY', 'TOGGLE_ENGRAVING', 'SMOOTH_FROM_MARKER', 'SMOOTH_TO_MARKER',
    'ERASE',
}) do ACTIVE_DESIG[MD[name]] = true end

local DIG_JOB = {}
for _, name in ipairs({'Dig', 'CarveUpwardStaircase', 'CarveDownwardStaircase',
    'CarveUpDownStaircase', 'CarveRamp', 'DigChannel'}) do DIG_JOB[df.job_type[name]] = true end
local CHOP_JOB = {[df.job_type.FellTree] = true}
local GATHER_JOB = {[df.job_type.GatherPlants] = true}

local function remove_jobs_at(pos, typeset)
    local removed = false
    local link = df.global.world.jobs.list.next
    while link do
        local job, nxt = link.item, link.next
        if job and typeset[job.job_type]
            and job.pos.x == pos.x and job.pos.y == pos.y and job.pos.z == pos.z then
            dfhack.job.removeJob(job)
            removed = true
        end
        link = nxt
    end
    return removed
end

local function cancel_dig(pos)
    local blk = dfhack.maps.getTileBlock(pos)
    if not blk then return false end
    local lx, ly = pos.x % 16, pos.y % 16
    local des = blk.designation[lx][ly]
    local had = des.dig ~= DV.No
    if had then
        des.dig = DV.No
        blk.occupancy[lx][ly].dig_marked = false
        blk.flags.designated = true
    end
    if remove_jobs_at(pos, DIG_JOB) then had = true end
    return had
end

-- also un-mark a tree/plant designated for chop/gather (belt-and-suspenders with the job removal)
local function cancel_plant(pos)
    local plant = dfhack.maps.getPlantAtTile(pos)
    if plant and dfhack.designations.isPlantMarked(plant) and dfhack.designations.canUnmarkPlant(plant) then
        dfhack.designations.unmarkPlant(plant)
        return true
    end
    return false
end

local function under_construction(bld)
    if bld:getBuildStage() < bld:getMaxBuildStage() then return true end
    for _, j in ipairs(bld.jobs) do
        if j.job_type == df.job_type.ConstructBuilding then return true end
    end
    return false
end

local function cancel_building(pos)
    local bld = dfhack.buildings.findAtTile(pos)
    if bld and under_construction(bld) then
        dfhack.buildings.deconstruct(bld)
        return true
    end
    return false
end

local function cancel_at(pos)
    local did = cancel_dig(pos)
    if remove_jobs_at(pos, CHOP_JOB) then did = true end
    if remove_jobs_at(pos, GATHER_JOB) then did = true end
    if cancel_plant(pos) then did = true end
    if cancel_building(pos) then did = true end
    return did
end

local function in_cancel_mode()
    local mi = df.global.game.main_interface
    if ACTIVE_DESIG[mi.main_designation_selected] then return true end
    if mi.bottom_mode_selected == df.main_bottom_mode_type.BUILDING_PLACEMENT then return true end
    return false
end

-- ============================================================================
-- DESIGNATE side (left-drag) -- dig validity ported from quickfort's dig logic
-- ============================================================================

local TS, TM = df.tiletype_shape, df.tiletype_material
local function is_construction(a) return a.material == TM.CONSTRUCTION end
local function is_floor(a)         return a.shape == TS.FLOOR end
local function is_ramp(a)          return a.shape == TS.RAMP end
local function is_diggable_floor(a) return is_floor(a) or a.shape == TS.BOULDER or a.shape == TS.PEBBLES end
local function is_wall(a)          return a.shape == TS.WALL end
local function is_tree(a)          return a.material == TM.TREE end
local function is_fortification(a) return a.shape == TS.FORTIFICATION end
local function is_up_stair(a)      return a.shape == TS.STAIR_UP end
local function is_down_stair(a)    return a.shape == TS.STAIR_DOWN end
local function is_removable_shape(a) return is_ramp(a) or is_up_stair(a) or is_down_stair(a) end
local function is_gatherable(a)    return a.shape == TS.SHRUB end
local function is_sapling(a)       return a.shape == TS.SAPLING end

-- each returns a dig value to set, or nil if the tile shouldn't be designated for this op
local function do_mine(c)
    if c.on_map_edge then return nil end
    if not c.flags.hidden and (is_construction(c.a) or (not is_wall(c.a) and not is_fortification(c.a))) then return nil end
    return DV.Default
end
local function do_channel(c)
    if c.on_map_edge then return nil end
    if not c.flags.hidden and (is_construction(c.a) or is_tree(c.a) or
        (not is_wall(c.a) and not is_fortification(c.a) and not is_diggable_floor(c.a)
         and not is_down_stair(c.a) and not is_removable_shape(c.a) and not is_gatherable(c.a)
         and not is_sapling(c.a))) then return nil end
    return DV.Channel
end
local function do_up_stair(c)
    if c.on_map_edge then return nil end
    if not c.flags.hidden and (is_construction(c.a) or (not is_wall(c.a) and not is_fortification(c.a))) then return nil end
    return DV.UpStair
end
local function do_down_stair(c)
    if c.on_map_edge then return nil end
    if not c.flags.hidden and (is_construction(c.a) or is_tree(c.a) or
        (not is_wall(c.a) and not is_fortification(c.a) and not is_diggable_floor(c.a)
         and not is_removable_shape(c.a) and not is_gatherable(c.a) and not is_sapling(c.a))) then return nil end
    return DV.DownStair
end
local function do_up_down_stair(c)
    if c.on_map_edge then return nil end
    if not c.flags.hidden and (is_construction(c.a) or
        (not is_wall(c.a) and not is_fortification(c.a) and not is_diggable_floor(c.a)
         and not is_up_stair(c.a))) then return nil end
    if is_diggable_floor(c.a) then return DV.DownStair end
    return DV.UpDownStair
end
local function do_ramp(c)
    if c.on_map_edge then return nil end
    if not c.flags.hidden and (is_construction(c.a) or (not is_wall(c.a) and not is_fortification(c.a))) then return nil end
    return DV.Ramp
end

local MODE_DIG = {
    [MD.DIG_DIG] = do_mine, [MD.DIG_CHANNEL] = do_channel,
    [MD.DIG_STAIR_UP] = do_up_stair, [MD.DIG_STAIR_DOWN] = do_down_stair,
    [MD.DIG_STAIR_UPDOWN] = do_up_down_stair, [MD.DIG_RAMP] = do_ramp,
}

-- iterate the box on `a`'s z-level; cb(pos) per tile
local function for_box(a, b, cb)
    local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
    local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
    for x = x1, x2 do for y = y1, y2 do cb(x, y, a.z) end end
end

local function designate_dig_box(do_fn, marker, a, b)
    local mx, my = df.global.world.map.x_count - 1, df.global.world.map.y_count - 1
    for_box(a, b, function(x, y, z)
        local pos = {x = x, y = y, z = z}
        local blk = dfhack.maps.getTileBlock(pos)
        if not blk then return end
        local lx, ly = x % 16, y % 16
        local ctx = {
            flags = blk.designation[lx][ly],
            a = df.tiletype.attrs[dfhack.maps.getTileType(pos)],
            on_map_edge = (x == 0 or y == 0 or x == mx or y == my),
        }
        local val = do_fn(ctx)
        if val then
            ctx.flags.dig = val
            if marker then blk.occupancy[lx][ly].dig_marked = true end
            blk.flags.designated = true
        end
    end)
end

local function designate_plant_box(want, a, b)
    for_box(a, b, function(x, y, z)
        local pos = {x = x, y = y, z = z}
        local attrs = df.tiletype.attrs[dfhack.maps.getTileType(pos)]
        local match = (want == 'chop' and is_tree(attrs)) or (want == 'gather' and is_gatherable(attrs))
        if match then
            local plant = dfhack.maps.getPlantAtTile(pos)
            if plant and dfhack.designations.canMarkPlant(plant) then
                dfhack.designations.markPlant(plant)
            end
        end
    end)
end

-- left-drag designation is active only in "box select" (rectangle) mode, for the dig
-- sub-types and chop/gather. (In paint mode the game already drags, so we stay out.)
local function left_designate_active()
    local mi = df.global.game.main_interface
    if not mi.main_designation_doing_rectangles then return false end
    local m = mi.main_designation_selected
    return MODE_DIG[m] ~= nil or m == MD.CHOP or m == MD.GATHER
end

local function apply_left_box(a, b)
    local mi = df.global.game.main_interface
    local m = mi.main_designation_selected
    if MODE_DIG[m] then
        designate_dig_box(MODE_DIG[m], mi.designation.marker_only, a, b)
    elseif m == MD.CHOP then
        designate_plant_box('chop', a, b)
    elseif m == MD.GATHER then
        designate_plant_box('gather', a, b)
    end
end

local function cancel_box(a, b)
    for_box(a, b, function(x, y, z) cancel_at({x = x, y = y, z = z}) end)
end

-- ============================================================================
-- overlay: poll both mouse buttons; resolve each gesture on release
-- ============================================================================

RightClickCancel = defclass(RightClickCancel, overlay.OverlayWidget)
RightClickCancel.ATTRS{
    desc = 'Left-drag to box-designate, right-drag to box-remove, right-click to cancel.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},   -- invisible; onInput/onupdate still see map-wide mouse input
    overlay_onupdate_max_freq_seconds = 0,
}

function RightClickCancel:passthrough(key)
    self.pass = true
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), key)
    self.pass = false
end

local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

function RightClickCancel:overlay_onupdate()
    -- LEFT button: drag = designate box; click = pass through to the game
    local ld = df.global.enabler.mouse_lbut_down
    if ld == 1 and self.lbut ~= 1 then
        self.lpress = left_designate_active() and dfhack.gui.getMousePos() or nil
    elseif ld ~= 1 and self.lbut == 1 and self.lpress then
        local rel = dfhack.gui.getMousePos()
        if rel then
            if same(self.lpress, rel) then self:passthrough('_MOUSE_L')
            else apply_left_box(self.lpress, rel) end
        end
        self.lpress = nil
    end
    self.lbut = ld

    -- RIGHT button: drag = remove box; click = cancel under cursor (else pass through)
    local rd = df.global.enabler.mouse_rbut_down
    if rd == 1 and self.rbut ~= 1 then
        self.rpress = in_cancel_mode() and dfhack.gui.getMousePos() or nil
    elseif rd ~= 1 and self.rbut == 1 and self.rpress then
        local rel = dfhack.gui.getMousePos()
        if rel then
            if same(self.rpress, rel) then
                if not cancel_at(rel) then self:passthrough('_MOUSE_R') end
            else
                cancel_box(self.rpress, rel)
            end
        end
        self.rpress = nil
    end
    self.rbut = rd
end

function RightClickCancel:onInput(keys)
    if self.pass then return false end   -- our own re-dispatched click
    -- swallow map clicks we resolve on release (the poller above); leave panel clicks alone
    if keys._MOUSE_L and left_designate_active() and dfhack.gui.getMousePos() then return true end
    if keys._MOUSE_R and in_cancel_mode() and dfhack.gui.getMousePos() then return true end
    return false
end

OVERLAY_WIDGETS = {cancel = RightClickCancel}

if not dfhack_flags.module then
    require('plugins.overlay').rescan()
    dfhack.run_command('overlay', 'enable', 'right-click-cancel.cancel')
    print('right-click-cancel: overlay enabled.')
    print('  left-drag = box designate (dig/stairs/chop/gather), left-click = normal click')
    print('  right-drag = box remove, right-click = cancel under cursor')
end
