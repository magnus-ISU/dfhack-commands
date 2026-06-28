-- Drag designate / drag remove for designation & build tools, plus right-click-to-cancel.
--@module = true
--[[
right-click-cancel

Mouse helpers for DF's designation and construction tools (overlay "right-click-cancel.cancel"):

  * LEFT-DRAG a box (in "box select" / rectangle mode) APPLIES the designation across the box
    in one gesture: the game places the first corner on mouse-down (so its selection box
    renders as you drag) and we auto-place the second corner on release. Works for dig and
    its sub-types (channel / ramps / up,down,up-down stairs), woodcutting (chop), plant
    gathering -- whatever designation tool is active. The game does the actual designating,
    so validity, marker mode, priority, etc. all match exactly.
  * LEFT single-click is left entirely to the game (placed on mouse-down), so the normal
    click-click designation and its live selection box are unchanged.
  * RIGHT-DRAG a box REMOVES everything designated in it (dig/chop/gather designations and
    in-progress buildings).
  * RIGHT single-click cancels whatever is designated under the cursor (a dig designation, a
    tree/plant marked for chop/gather, or an in-progress construction/building); a right
    click on an empty tile passes through (the game's normal "leave the tool").

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

-- un-mark a tree/plant designated for chop/gather
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

local function for_box(a, b, cb)
    local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
    local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
    for x = x1, x2 do for y = y1, y2 do cb(x, y, a.z) end end
end

local function cancel_box(a, b)
    for_box(a, b, function(x, y, z) cancel_at({x = x, y = y, z = z}) end)
end

-- ============================================================================
-- DESIGNATE side (left-drag): let the GAME designate -- it places the first corner on
-- mouse-down (drawing its selection box); we just auto-place the second corner on release.
-- ============================================================================

-- left-drag completion is active only in "box select" (rectangle) mode while a designation
-- tool is up. (In paint mode the game already drags; single clicks need no help.)
local function left_drag_active()
    local mi = df.global.game.main_interface
    return mi.main_designation_doing_rectangles and mi.main_designation_selected ~= MD.NONE
end

-- ============================================================================
-- overlay: watch both mouse buttons
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
    -- LEFT button: NOT swallowed -- the game handles mouse-down (places corner 1, renders its
    -- selection box). On a drag, re-dispatch a click on release to place corner 2 (the game
    -- then applies the box and clears its anchor). A single click is left entirely to the game.
    local ld = df.global.enabler.mouse_lbut_down
    if ld == 1 and self.lbut ~= 1 then
        self.lpress = left_drag_active() and dfhack.gui.getMousePos() or nil
    elseif ld ~= 1 and self.lbut == 1 then
        if self.lpress then
            local rel = dfhack.gui.getMousePos()
            if rel and not same(self.lpress, rel) and left_drag_active() then
                self:passthrough('_MOUSE_L')
            end
        end
        self.lpress = nil
    end
    self.lbut = ld

    -- RIGHT button: swallowed in onInput; click = cancel under cursor (else pass through),
    -- drag = remove the boxed area.
    local rd = df.global.enabler.mouse_rbut_down
    if rd == 1 and self.rbut ~= 1 then
        self.rpress = in_cancel_mode() and dfhack.gui.getMousePos() or nil
    elseif rd ~= 1 and self.rbut == 1 then
        if self.rpress then
            local rel = dfhack.gui.getMousePos()
            if rel then
                if same(self.rpress, rel) then
                    if not cancel_at(rel) then self:passthrough('_MOUSE_R') end
                else
                    cancel_box(self.rpress, rel)
                end
            end
        end
        self.rpress = nil
    end
    self.rbut = rd
end

function RightClickCancel:onInput(keys)
    if self.pass then return false end   -- our own re-dispatched click
    -- only the RIGHT button is intercepted (resolved on release by the poller). The LEFT
    -- button is left to the game so its native selection box renders. Don't swallow panel
    -- clicks (getMousePos is nil off the map).
    if keys._MOUSE_R and in_cancel_mode() and dfhack.gui.getMousePos() then return true end
    return false
end

OVERLAY_WIDGETS = {cancel = RightClickCancel}

if not dfhack_flags.module then
    require('plugins.overlay').rescan()
    dfhack.run_command('overlay', 'enable', 'right-click-cancel.cancel')
    print('right-click-cancel: overlay enabled.')
    print('  left-drag = box designate (the game renders the box), left-click = normal click')
    print('  right-drag = box remove, right-click = cancel under cursor')
end
