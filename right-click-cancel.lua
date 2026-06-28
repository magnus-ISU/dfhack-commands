-- Right-click to cancel a designation / construction while a designation or construct tool is up.
--@module = true
--[[
right-click-cancel

While a designation or construction tool is selected -- dig, woodcutting (chop), plant
gathering, engraving, erase, or placing a construction -- RIGHT-CLICKING a tile cancels what
is designated there, instead of just leaving the tool:
  * a dig designation is removed,
  * a tree marked for chopping is un-designated,
  * a plant marked for gathering is un-designated,
  * any building still being built -- a construction, furniture, screw pump, workshop,
    etc. -- is canceled (removed).

Right-clicking a tile with nothing to cancel is left alone, so DF's normal right-click
(back out of the tool / cancel the current rectangle) still works.

Registered as overlay "right-click-cancel.cancel"; toggle or move it with gui/overlay.
magnus-scripts enables it each session.
]]

local overlay = require('plugins.overlay')

-- the designation tools in which right-click should cancel (dig / chop / gather / engrave / erase)
local ACTIVE_DESIG = {}
for _, name in ipairs({
    'DIG_DIG', 'DIG_REMOVE_STAIRS_RAMPS', 'DIG_STAIR_UP', 'DIG_STAIR_UPDOWN', 'DIG_STAIR_DOWN',
    'DIG_RAMP', 'DIG_CHANNEL', 'DIG_FROM_MARKER', 'DIG_TO_MARKER',
    'CHOP', 'CHOP_FROM_MARKER', 'CHOP_TO_MARKER',
    'GATHER', 'GATHER_FROM_MARKER', 'GATHER_TO_MARKER',
    'SMOOTH', 'ENGRAVE', 'TRACK', 'FORTIFY', 'TOGGLE_ENGRAVING', 'SMOOTH_FROM_MARKER', 'SMOOTH_TO_MARKER',
    'ERASE',
}) do ACTIVE_DESIG[df.main_designation_type[name]] = true end

-- jobs spawned by a dig designation (removed along with the dig flag)
local DIG_JOB = {}
for _, name in ipairs({'Dig', 'CarveUpwardStaircase', 'CarveDownwardStaircase',
    'CarveUpDownStaircase', 'CarveRamp', 'DigChannel'}) do DIG_JOB[df.job_type[name]] = true end
-- chop / gather designations ARE jobs in this DF version, so removing the job cancels them
local CHOP_JOB = {[df.job_type.FellTree] = true}
local GATHER_JOB = {[df.job_type.GatherPlants] = true}

-- remove every job of the given types standing on `pos`; returns true if any were removed
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

-- clear a dig designation (and any dig job already on the tile)
local function cancel_dig(pos)
    local blk = dfhack.maps.getTileBlock(pos)
    if not blk then return false end
    local lx, ly = pos.x % 16, pos.y % 16
    local des = blk.designation[lx][ly]
    local had = des.dig ~= df.tile_dig_designation.No
    if had then
        des.dig = df.tile_dig_designation.No
        blk.occupancy[lx][ly].dig_marked = false
        blk.flags.designated = true     -- nudge DF to re-scan the block's designations
    end
    if remove_jobs_at(pos, DIG_JOB) then had = true end
    return had
end

-- is this building still being built (not finished)? works for any building type --
-- constructions, furniture, screw pumps, workshops, ... A finished building reports
-- getBuildStage() == getMaxBuildStage() even when it has work jobs running.
local function under_construction(bld)
    if bld:getBuildStage() < bld:getMaxBuildStage() then return true end
    for _, j in ipairs(bld.jobs) do
        if j.job_type == df.job_type.ConstructBuilding then return true end
    end
    return false
end

-- cancel ANY building that is still being built (placed but not yet finished)
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
    if cancel_building(pos) then did = true end
    return did
end

-- are we in a mode where right-click should cancel?
local function in_cancel_mode()
    local mi = df.global.game.main_interface
    if ACTIVE_DESIG[mi.main_designation_selected] then return true end
    -- placing any building (constructions, furniture, screw pumps, workshops, ...)
    if mi.bottom_mode_selected == df.main_bottom_mode_type.BUILDING_PLACEMENT then
        return true
    end
    return false
end

RightClickCancel = defclass(RightClickCancel, overlay.OverlayWidget)
RightClickCancel.ATTRS{
    desc = 'Right-click cancels the dig/chop/gather designation or construction under the cursor.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},   -- invisible; onInput still sees map-wide mouse input
}

function RightClickCancel:onInput(keys)
    if not keys._MOUSE_R then return false end
    if not in_cancel_mode() then return false end
    local pos = dfhack.gui.getMousePos()
    if not pos then return false end
    -- only swallow the click if we actually cancelled something; otherwise let DF do its
    -- normal right-click (back out of the tool / cancel the current rectangle).
    return cancel_at(pos)
end

OVERLAY_WIDGETS = {cancel = RightClickCancel}

if not dfhack_flags.module then
    require('plugins.overlay').rescan()
    dfhack.run_command('overlay', 'enable', 'right-click-cancel.cancel')
    print('right-click-cancel: overlay enabled. In a dig/chop/gather/engrave/erase/construct')
    print('tool, right-click a designation or in-progress construction to cancel it.')
end
