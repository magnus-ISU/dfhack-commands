-- Paint walls to be mined out and rebuilt as constructed walls, using your buildingplan settings.
--@module = true
--[[
MIT License

Copyright (c) 2026 Little Fern Studio
Copyright (c) 2026 the dfhack-commands authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]
--[[
fort/dig-replace-walls

A rewrite of Little Fern Studio's "Replace Wall" for this repo:
  <https://github.com/LittleFernStudio/replace-wall>
The idea, the two-phase plan/hand-off design and the manager loop are theirs; the material
handling, the wall/furniture rules and the control scheme below are this repo's.

WHAT IT DOES. Paint walls. Each painted tile is remembered, taken down, and -- once the tile
is actually clear -- handed to DFHack's `buildingplan` plugin as a planned constructed wall.
So you get "this rock wall should be a smooth block wall" as one gesture, and buildingplan
waits for the material like it does for anything else.

Two kinds of wall are accepted:
  * a NATURAL wall (rock/soil) is designated for MINING;
  * a CONSTRUCTED wall is designated for REMOVAL, so it can be rebuilt out of something else.

Both are the same designation underneath. A finished construction is not a building at all --
DF drops the building once it is built and keeps only the tile's construction record -- and
`constructions.designateRemove` on one just sets `designation.dig`, the very flag a natural wall
uses. So one rule covers both, including how the player takes the work back off again.

A CONSTRUCTED WALL THAT ALREADY MATCHES THE FILTER IS LEFT ALONE. Taking down a conglomerate
block wall to build a conglomerate block wall costs a mining job, a hauling trip and a hole in
the meantime, and gains nothing, so painting over one does nothing and says so. Judged against
buildingplan's own filter -- the item form against its blocks/logs/boulders/bars toggles, the
material against the category mask and the named materials -- so "turn these boulder walls into
block walls" still works with no material chosen at all. A filter carrying a heat-safety
requirement or a special is not judged, and those walls are replaced as before.

Anything else on the tile is LEFT ALONE. A door, a hatch, a statue, a workshop, a floor --
none of them are walls, so none of them are taken down; those tiles are skipped and counted.
A constructed wall carrying a MASTERWORK engraving is skipped too, the same rule
`fort/dig-shapes` removal follows: taking it down destroys the masterpiece, and unlike a
natural wall nothing forces the issue.

MATERIALS ARE BUILDINGPLAN'S, NOT OURS. The upstream script keeps its own material and item
form and forces them into buildingplan's filter for each hand-off. This one does not keep any
material state at all: the wall is planned with buildingplan's own stored Construction/Wall
filter, so it builds out of exactly what placing a wall by hand would build out of. The two
controls in the window are buildingplan's own, editing buildingplan's own settings:

  f  Set/Edit filter     buildingplan's filter dialog for a wall -- the same dialog, on the
                         same stored filter, as pressing `f` while placing a wall.
  b/l/o/r  Blocks / Logs / Boulders / Bars
                         buildingplan's global "generic materials" toggles.

Change either here and you have changed it for building walls generally, and vice versa.

CONTROLS (the repo's map gesture scheme -- see `fort/right-click-cancel`):
  * LEFT-DRAG            box-select: paint every wall in the box.
  * LEFT-CLICK in place  places one corner; the next click completes the box (DF's own
                         click-and-second-click selection).
  * RIGHT-DRAG           box-unselect: drop the plans in the box and take their
                         designations back off.
  * RIGHT-CLICK in place unselects the tile under the cursor; on a tile with nothing painted
                         (or with a corner pending) it backs out instead, and closes.
  * Esc                  close.

Only clicks on the MAP itself are gestures. A click on a panel -- this tool's own window, the
buildingplan filter dialog it opens, a DF menu or notification, another DFHack overlay -- is
left to whatever was clicked, and never becomes a selection corner.

A plan lasts only as long as the work does. CANCELLING THE DIG CANCELS THE REPLACEMENT: take the
designation off a painted tile by any means -- DF's eraser, `fort/right-click-cancel`, this tool's
own right-drag -- and the plan goes with it, and is never re-designated behind you. (A tile with
no designation but a mining job posted on it has NOT been cancelled: DF clears the designation the
moment it posts the job.) At the other end, the plan drops itself the moment the replacement wall
is handed to buildingplan, so nothing lingers once the tile is spoken for.

Pending tiles are marked on the map by overlay `fort/dig-replace-walls.pending`, drawn through
DF's own map layer rather than stamped over the finished frame. The mark goes the moment the
work does, not when the manager next gets a turn.

The painter is an OVERLAY, not a screen -- `fort/dig-replace-walls.panel`, shown only while
painting, movable with `gui/overlay`. Nothing is opened or torn down when it comes and goes, so
closing it does not make DF blank and redraw the screen the way dismissing any DFHack dialog
does. While it is up DF's own designation tool is disarmed, so neither DF nor the repo's other
map tools act on the clicks it is taking.

Usually reached from the `fort/dig-building` picker ("Replace wall", in the custom-tool band
at the bottom; the picker hides itself while the painter is up). `dig-replace-walls` opens the painter; `dig-replace-walls status`
reports the plan count; `dig-replace-walls resume` re-designates anything that lost its
designation; `dig-replace-walls clear` forgets every plan.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')
local widgets = require('gui.widgets')
local guidm = require('gui.dwarfmode')
local buildingplan = require('plugins.buildingplan')

local DV = df.tile_dig_designation
local SH = df.tiletype_shape
local TM = df.tiletype_material

local PERSIST_KEY = 'dig-replace-walls'
-- How often the manager re-checks the pending tiles, in FRAMES rather than game ticks.
-- Deliberate: a tick timeout does not fire while the game is PAUSED, and designating (and
-- cancelling) is mostly done paused. On ticks, a plan the player had just cancelled kept its
-- map marker until they unpaused -- the manager reconciling the list was simply not running.
local CYCLE_FRAMES = 100
local MAX_HANDOFFS = 50        -- planned walls created per cycle, so a big job can't stall a frame
local MAX_BOX_TILES = 10000    -- refuse an absurd drag rather than freeze the main thread
local WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM = df.building_type.Construction, df.construction_type.Wall, -1
local FILTER_IDX = 1           -- 1-based, the way buildingplan's own dialog is indexed

-- ---- tiles ------------------------------------------------------------------

local function pos(x, y, z) return {x = x, y = y, z = z} end
local function key(p) return ('%d,%d,%d'):format(p.x, p.y, p.z) end
local function same(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

local function attrs(p)
    local tt = dfhack.maps.getTileType(p)
    return tt and df.tiletype.attrs[tt] or nil
end

local function building_at(p)
    local ok, b = pcall(dfhack.buildings.findAtTile, p)
    return ok and b or nil
end

local function is_wall_construction(b)
    return b ~= nil and b:getType() == df.building_type.Construction
        and b:getSubtype() == df.construction_type.Wall
end

-- a natural, minable rock/soil wall (not a construction, not a tree)
local function is_natural_wall(p)
    local a = attrs(p)
    return a ~= nil and a.shape == SH.WALL
        and a.material ~= TM.CONSTRUCTION and a.material ~= TM.TREE
        and dfhack.constructions.findAtTile(p) == nil
end

-- a completed constructed wall
local function is_constructed_wall(p)
    if dfhack.constructions.findAtTile(p) == nil then return false end
    local a = attrs(p)
    return a ~= nil and a.shape == SH.WALL
end

-- the tile has been cleared and a wall can be planned on it again
local function is_clear(p)
    local a = attrs(p)
    if not a then return false end
    return a.shape == SH.FLOOR or a.shape == SH.PEBBLES or a.shape == SH.BOULDER
        or a.shape == SH.SAPLING or a.shape == SH.SHRUB or a.shape == SH.EMPTY
end

-- ALREADY WHAT YOU ASKED FOR.
--
-- A constructed wall that already satisfies buildingplan's wall filter has nothing to gain from
-- being taken down and put back: the replacement would be the same wall, bought with a mining
-- job, a hauling trip and a stretch of open hole in the meantime. So painting over one does
-- nothing and says so.
--
-- The test is the finished construction's own record -- it keeps the item type and the material
-- it was built from -- against the same three things buildingplan's dialog shows:
--
--   * the ITEM FORM, against buildingplan's global blocks/logs/boulders/bars toggles, which is
--     what makes "turn these boulder walls into block walls" work even with no material chosen;
--   * the MATERIAL CATEGORY mask (stone, wood, metal, ...);
--   * the NAMED MATERIALS, which only narrow anything while a category mask is set -- the same
--     rule `filter_summary` prints by.
--
-- A filter this cannot judge is never called satisfied: a heat-safety requirement or a special
-- (artifact, and the like) means the wall gets replaced as before, because proving a given stone
-- magma-safe is not something to guess at.
local FORM_SETTING = {
    [df.item_type.BLOCKS] = 'blocks',
    [df.item_type.WOOD] = 'logs',
    [df.item_type.BOULDER] = 'boulders',
    [df.item_type.BAR] = 'bars',
}

function matches_filter(p)
    local con = dfhack.constructions.findAtTile(p)
    if not con then return false end
    local ok, verdict = pcall(function()
        if buildingplan.getHeatSafetyFilter(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM) ~= 0 then
            return false
        end
        if next(buildingplan.getSpecials(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM)) then return false end

        local setting = FORM_SETTING[con.item_type]
        local globals = buildingplan.getGlobalSettings()
        if not setting or not globals[setting] then return false end

        local idx = FILTER_IDX - 1
        local cats = buildingplan.getMaterialMaskFilter(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM, idx)
        if not cats or cats.unset then return true end        -- any material: the form decided it

        local mat = dfhack.matinfo.decode(con.mat_type, con.mat_index)
        local name = mat and mat:toString()
        local filter = buildingplan.getMaterialFilter(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM, idx) or {}
        local props = name and filter[name]
        if not props or not cats[props.category] then return false end
        -- named materials narrow the mask only when at least one inside it is enabled
        local narrowed = false
        for _, other in pairs(filter) do
            if other.enabled == 'true' and cats[other.category] then narrowed = true break end
        end
        return not narrowed or props.enabled == 'true'
    end)
    return ok and verdict or false
end

-- MASTERWORK ENGRAVINGS ARE NOT TAKEN DOWN. Same rule as fort/dig-shapes' removal boxes:
-- only a SMOOTH tile can carry an engraving at all, so that cheap tiletype test gates the
-- (linear) engraving lookup and it is normally never reached.
local function has_masterwork_engraving(p)
    local a = attrs(p)
    if not a or a.special ~= df.tiletype_special.SMOOTH then return false end
    for _, e in ipairs(df.global.world.event.engravings) do
        if e.pos.x == p.x and e.pos.y == p.y and e.pos.z == p.z then
            return e.quality >= df.item_quality.Masterful
        end
    end
    return false
end

local function set_dig(p, val)
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return false end
    blk.designation[p.x % 16][p.y % 16].dig = val
    blk.flags.designated = true
    return true
end

local function dig_val(p)
    local blk = dfhack.maps.getTileBlock(p)
    if not blk then return DV.No end
    return blk.designation[p.x % 16][p.y % 16].dig
end

-- ---- persistent plan list ---------------------------------------------------
--
-- One record per painted tile: {x, y, z, con=true when it was a CONSTRUCTED wall we
-- designated for removal}. Records live only until the tile is clear and the planned wall
-- has been handed to buildingplan -- after that buildingplan owns it and we forget it.

local function load_plans()
    if not dfhack.isSiteLoaded() then return {} end
    local data = dfhack.persistent.getSiteData(PERSIST_KEY, {plans = {}})
    if type(data) ~= 'table' or type(data.plans) ~= 'table' then return {} end
    return data.plans
end

local function save_plans(plans)
    if not dfhack.isSiteLoaded() then return end
    dfhack.persistent.saveSiteData(PERSIST_KEY, {plans = plans})
end

function plan_count() return #load_plans() end

-- set of "x,y,z" strings for everything currently painted (for the map marker and for
-- deciding whether a right-click has anything to unselect)
function planned_keys()
    local set = {}
    for _, r in ipairs(load_plans()) do set[key(r)] = true end
    return set
end

-- ---- taking a wall down -----------------------------------------------------

-- Cancel a queued construction removal, but ONLY while no dwarf has taken the job. Pulling a
-- job out from under the unit holding it frees a struct DF is still pointing at, and that is a
-- crash this fort has already seen -- so a removal already being worked is left to finish and
-- the caller is told.
-- Take the pending removal back off a tile. A completed construction is taken down by a dig
-- designation (see `stale`), so this is the same gesture for both kinds of wall: clear it. Only
-- an unbuilt construction is a building, and there the queued job is what has to go -- but
-- never one a dwarf is already holding, since freeing a job DF is still pointing at is a crash
-- this fort has seen.
local function cancel_removal(p)
    local b = building_at(p)
    if b then
        for _, j in ipairs(b.jobs) do
            if j.job_type == df.job_type.DestroyBuilding then
                if dfhack.job.getWorker(j) then return false end
                return (pcall(dfhack.job.removeJob, j))
            end
        end
    end
    set_dig(p, DV.No)
    return true
end

-- ---- reading back what the player has done ----------------------------------
--
-- CANCELLING THE DIG CANCELS THE REPLACEMENT. A plan is only a plan for as long as the tile is
-- actually on its way to becoming a floor, so when the player takes the designation back off
-- (DF's eraser, fort/right-click-cancel, anything) the plan goes with it, and we never
-- re-designate behind them.
--
-- "The tile has no dig designation" is NOT on its own evidence of that: DF CLEARS the
-- designation the moment it posts the mining job, and from then on the job is the only record
-- that the tile was ever designated. So a plan is cancelled only when there is neither.

local MINING_JOB = {}
for _, n in ipairs({'Dig', 'CarveUpwardStaircase', 'CarveDownwardStaircase',
                    'CarveUpDownStaircase', 'CarveRamp', 'DigChannel',
                    -- taking a CONSTRUCTED wall down posts one of these instead
                    'RemoveConstruction', 'DestroyBuilding'}) do
    MINING_JOB[df.job_type[n]] = true
end

-- every tile with a mining job posted on it, as a position-key set. Built ONCE per cycle: the
-- job list is walked per plan otherwise, which is a list scan times a plan count.
local function mining_jobs()
    local set = {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and MINING_JOB[job.job_type] then set[key(job.pos)] = true end
        link = link.next
    end
    return set
end

-- is this construction still queued for removal?
local function removal_pending(b)
    for _, j in ipairs(b.jobs) do
        if j.job_type == df.job_type.DestroyBuilding then return true end
    end
    return false
end

-- Has this plan stopped being live -- because the player cancelled the work, or because the
-- replacement has already been handed to buildingplan? One predicate, used by the manager to
-- drop the record AND by the map marker to decide whether to draw it, so what you see on the
-- map can never disagree with what the manager is about to do.
function stale(rec, digging)
    local p = pos(rec.x, rec.y, rec.z)
    local b = building_at(p)
    if b and is_wall_construction(b) then
        if buildingplan.isPlannedBuilding(b) then return true end   -- replacement planned
        return rec.con and not removal_pending(b)                   -- removal cancelled
    end
    -- THE WALL IS STILL STANDING, AND BOTH KINDS COME DOWN THE SAME WAY: a completed
    -- construction is not a building at all (DF drops the building the moment it is built and
    -- keeps only the tile's construction record), and `constructions.designateRemove` on one
    -- just sets `designation.dig` -- the very flag a natural wall uses. So a constructed wall
    -- is cancelled exactly like a natural one: no designation left, and no job posted.
    --
    -- Getting this wrong is what left every constructed-wall plan in the fort stuck forever:
    -- the old test looked for a building that a finished construction never has, found none,
    -- and concluded the plan was still live no matter what the player did to the designation.
    if is_natural_wall(p) or is_constructed_wall(p) then
        return dig_val(p) == DV.No and not digging[key(p)]
    end
    return false
end

-- ---- the manager ------------------------------------------------------------
--
-- A tile is watched until it is clear, then handed to buildingplan and forgotten. `generation`
-- invalidates the timeout chain when the map unloads or the cycle is restarted.

running = running or false
generation = generation or 0

-- plan a constructed wall here, with buildingplan's OWN stored wall filter. Nothing about
-- the filter is touched: an unmodified getFiltersByType + addPlannedBuilding is exactly what
-- buildingplan's own placement overlay does, so this wall is built from whatever placing a
-- wall by hand would have built it from.
function plan_wall(p)
    local filters = dfhack.buildings.getFiltersByType({}, WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM)
    if not filters or not filters[1] then return nil, 'no wall construction filters' end
    local bld, err = dfhack.buildings.constructBuilding{
        pos = pos(p.x, p.y, p.z),
        type = WALL_TYPE, subtype = WALL_SUBTYPE, custom = WALL_CUSTOM,
        filters = filters,
    }
    if not bld then return nil, 'constructBuilding failed: ' .. tostring(err) end
    local ok, res = pcall(buildingplan.addPlannedBuilding, bld)
    if not ok then return nil, 'addPlannedBuilding failed: ' .. tostring(res) end
    if res == false or not buildingplan.isPlannedBuilding(bld) then
        return nil, 'buildingplan did not take the wall'
    end
    buildingplan.scheduleCycle()
    return bld
end

-- 'wait' = still coming down, 'done' = handed off or gone, 'drop' = give up (with a reason)
local function inspect(rec, digging)
    local p = pos(rec.x, rec.y, rec.z)
    local b = building_at(p)
    if stale(rec, digging) then return 'drop' end   -- cancelled, or already handed off
    if b then
        if is_wall_construction(b) then return 'wait' end
        return 'drop', 'another building was placed here'
    end
    if is_natural_wall(p) then return 'wait' end
    if is_constructed_wall(p) then return 'wait' end
    if not is_clear(p) then return 'drop', 'the tile is neither a wall nor clear ground' end
    local bld, err = plan_wall(p)
    if bld then return 'done' end
    return 'wait', err
end

function cycle(gen)
    if gen ~= generation or not dfhack.isMapLoaded() then return end
    local plans = load_plans()
    local keep, handoffs, changed = {}, 0, false
    local digging = mining_jobs()
    for _, rec in ipairs(plans) do
        local action, err = 'wait', nil
        if handoffs < MAX_HANDOFFS then action, err = inspect(rec, digging) end
        if action == 'done' then
            handoffs, changed = handoffs + 1, true
        elseif action == 'drop' then
            changed = true
            -- a cancel carries no reason: it is what the player asked for, not a failure
            if err then
                dfhack.printerr(('dig-replace-walls (%d,%d,%d): %s'):format(rec.x, rec.y, rec.z, err))
            end
        else
            keep[#keep + 1] = rec
            if err then
                dfhack.printerr(('dig-replace-walls (%d,%d,%d): %s'):format(rec.x, rec.y, rec.z, err))
            end
        end
    end
    if changed then save_plans(keep) end
    if #keep == 0 then running = false return end
    dfhack.timeout(CYCLE_FRAMES, 'frames', function() cycle(gen) end)
end

-- Start (or restart) the manager. It does NOT bail when `running` is already set, and must not:
-- `running` survives a script reload while the timeout chain that set it does not, so trusting
-- it left the flag stuck on with nothing actually scheduled -- the manager silently stopped
-- reconciling, and cancelled plans kept their markers until something else kicked it. Bumping
-- the generation invalidates whatever chain was live, so restarting is always safe and there is
-- never more than one.
function start()
    if not dfhack.isMapLoaded() then return end
    running = true
    generation = generation + 1
    local gen = generation
    dfhack.timeout(1, 'frames', function() cycle(gen) end)
end

function stop()
    generation = generation + 1
    running = false
end

-- re-apply anything that lost its designation (a cancelled dig, a reloaded save) and get the
-- cycle going again
-- Pick the plan list back up (map load, script reload). This used to re-apply any designation
-- that had gone missing, which is precisely wrong now: a missing designation is how the player
-- cancels, and re-applying it put the designation straight back. So resume only DROPS what has
-- been cancelled and restarts the cycle; the cycle does the rest.
function resume()
    if not dfhack.isMapLoaded() then return end
    local plans = load_plans()
    local digging = mining_jobs()
    local keep = {}
    for _, rec in ipairs(plans) do
        if not stale(rec, digging) then keep[#keep + 1] = rec end
    end
    if #keep ~= #plans then save_plans(keep) end
    if #keep > 0 then start() end
end

function clear()
    local n = 0
    for _, rec in ipairs(load_plans()) do
        local p = pos(rec.x, rec.y, rec.z)
        if is_natural_wall(p) then set_dig(p, DV.No) end
        if rec.con then pcall(cancel_removal, p) end
        n = n + 1
    end
    save_plans({})
    stop()
    return n
end

-- ---- painting ---------------------------------------------------------------

local function for_box(a, b, cb)
    local x1, x2 = math.min(a.x, b.x), math.max(a.x, b.x)
    local y1, y2 = math.min(a.y, b.y), math.max(a.y, b.y)
    if (x2 - x1 + 1) * (y2 - y1 + 1) > MAX_BOX_TILES then return false end
    for x = x1, x2 do for y = y1, y2 do cb(pos(x, y, a.z)) end end
    return true
end

-- Paint the box. Returns counts: painted, skipped (something that is not a wall, a masterwork,
-- or a wall that is already what the filter asks for), already (already painted), and the
-- number that were left because they already match.
function paint_box(a, b)
    local plans = load_plans()
    local have = {}
    for _, r in ipairs(plans) do have[key(r)] = true end
    local painted, skipped, already, correct = 0, 0, 0, 0
    local ok = for_box(a, b, function(p)
        local k = key(p)
        if have[k] then already = already + 1 return end
        -- DOORS, HATCHES, FURNITURE, WORKSHOPS: not walls, so never taken down. Only a
        -- constructed WALL is a building we are willing to remove.
        local bld = building_at(p)
        if bld and not is_wall_construction(bld) then skipped = skipped + 1 return end
        if is_natural_wall(p) then
            if not set_dig(p, DV.Default) then skipped = skipped + 1 return end
            have[k] = true
            plans[#plans + 1] = {x = p.x, y = p.y, z = p.z}
            painted = painted + 1
        elseif is_constructed_wall(p) then
            if matches_filter(p) then correct = correct + 1 skipped = skipped + 1 return end
            if has_masterwork_engraving(p) then skipped = skipped + 1 return end
            if not pcall(dfhack.constructions.designateRemove, p) then skipped = skipped + 1 return end
            have[k] = true
            plans[#plans + 1] = {x = p.x, y = p.y, z = p.z, con = true}
            painted = painted + 1
        else
            skipped = skipped + 1
        end
    end)
    if not ok then return 0, 0, 0, 'selection too large' end
    if painted > 0 then
        save_plans(plans)
        start()
    end
    return painted, skipped, already, nil, correct
end

-- Unselect: forget the plans in the box and take their designations back off. Returns the
-- number dropped and the number that could not be taken back (a removal a dwarf already holds).
function erase_box(a, b)
    local plans = load_plans()
    local drop, stuck = {}, 0
    local ok = for_box(a, b, function(p) drop[key(p)] = true end)
    if not ok then return 0, 0 end
    local keep, dropped = {}, 0
    for _, rec in ipairs(plans) do
        local p = pos(rec.x, rec.y, rec.z)
        if drop[key(rec)] then
            if cancel_removal(p) then dropped = dropped + 1
            else keep[#keep + 1] = rec; stuck = stuck + 1 end
        else
            keep[#keep + 1] = rec
        end
    end
    if dropped > 0 then save_plans(keep) end
    return dropped, stuck
end

-- ---- the map marker overlay -------------------------------------------------

ReplaceWallMarks = defclass(ReplaceWallMarks, overlay.OverlayWidget)
ReplaceWallMarks.ATTRS{
    desc = 'Marks the walls painted for replacement by fort/dig-replace-walls.',
    default_enabled = true,
    viewscreens = 'dwarfmode',
    -- A PURE MAP PAINTER: no screen footprint at all, so it is never positioned, never
    -- hovered, and has no cell of its own for the overlay framework to manage or repaint.
    -- It used to declare a 1x1 frame parked at a default_pos while painting somewhere else
    -- entirely, which is what made removing it repaint the whole screen black.
    frame = {w = 0, h = 0},
    overlay_onupdate_max_freq_seconds = 0.25,
}

function ReplaceWallMarks:init() self.marks = {} end

-- Read the plan list on the SLOW update, never per frame: it is a persistent-data
-- round trip and this widget renders on every frame of the map.
--
-- A record is NOT drawn just because it is still in the list. The manager is what removes
-- records, and it runs on a timer -- so between the player cancelling a designation and the
-- next pass there is a window where the list still holds tiles that are no longer going
-- anywhere. This update fires on a wall-clock timer (it runs while the game is paused, which is
-- when designating mostly happens), so it re-tests each record and simply does not draw a stale
-- one. The mark disappears when the designation does, not when the manager next gets a turn.
function ReplaceWallMarks:overlay_onupdate()
    self.marks = {}
    if not dfhack.isMapLoaded() or not dfhack.isSiteLoaded() then return end
    local plans = load_plans()
    if #plans == 0 then return end
    local digging = mining_jobs()
    for _, r in ipairs(plans) do
        if not stale(r, digging) then self.marks[#self.marks + 1] = pos(r.x, r.y, r.z) end
    end
end

-- Drawn THROUGH DF'S OWN MAP LAYER, not painted over the finished screen.
--
-- `dfhack.screen.paintTile` stamps onto the composed frame, so the marks are something laid on
-- top that has to be taken back off again -- and taking them off (the overlay being disabled,
-- the last mark going away) is what flashed the whole screen black.
--
-- `gps.main_viewport.screentexpos_interface` is the layer DF renders the building-placement
-- hologram in: alpha-blended over the map, and NOT recoloured the way the designation layer is,
-- so the sprite keeps its own look. DF rebuilds the layer every frame, so writing into it means
-- there is never anything of ours left to erase -- the marks simply stop being written and the
-- next frame is already correct. Cells DF has drawn in are left alone, so a placement hologram
-- or anything else DF puts there still wins.
local MARK_TILE = dfhack.screen.findGraphicsTile('CURSORS', 3, 0)
PAINT_TILE = dfhack.screen.findGraphicsTile('CURSORS', 1, 0) or MARK_TILE
ERASE_TILE = dfhack.screen.findGraphicsTile('CURSORS', 3, 0)

function ReplaceWallMarks:onRenderFrame(dc, rect)
    if #self.marks == 0 or not MARK_TILE then return end
    local vp = guidm.Viewport.get()
    if not vp then return end
    local gvp = df.global.gps.main_viewport
    local dimx, dimy = gvp.dim_x, gvp.dim_y
    if dimx <= 0 or dimy <= 0 then return end
    local arr, arr_old = gvp.screentexpos_interface, gvp.screentexpos_interface_old
    for _, p in ipairs(self.marks) do
        if p.z == vp.z then
            local vx, vy = p.x - vp.x1, p.y - vp.y1
            if vx >= 0 and vy >= 0 and vx < dimx and vy < dimy then
                local at = vx * dimy + vy
                if arr[at] == 0 then arr[at], arr_old[at] = MARK_TILE, MARK_TILE end
            end
        end
    end
end

-- ---- buildingplan's own filter dialog, for a wall ----------------------------
--
-- buildingplan's filter UI reads the building being placed out of df.global.buildreq. We are
-- not placing anything, so point buildreq at Construction/Wall for the life of the dialog and
-- put it back afterwards -- then the dialog edits exactly the filter that placing a wall by
-- hand would edit. (Its own FilterSelectionScreen is not reused: that one restores
-- bottom_mode_selected to BUILDING_PLACEMENT on dismiss, which is wrong off the build screen.)

-- THE BLACK FLASH ON CLOSING. gui.Screen:dismiss() asks DF for a full-screen refresh
-- (`Screen.request_full_screen_refresh`, which the next renderParent turns into
-- `gps.force_full_display_count = 1`) -- DF then blanks the screen and redraws it from scratch.
-- That blank frame is the flash. It exists to clear leftovers from screens that stamp onto the
-- composed frame; nothing we draw needs it. The window sits over the map, which DF repaints
-- every frame regardless, and the pending marks go into DF's own map layer, which it rebuilds
-- from scratch each frame. So the request is withdrawn as soon as it is made.
local function no_full_refresh()
    gui.Screen.request_full_screen_refresh = false
end

-- What buildingplan's wall filter currently comes to, in the words buildingplan itself uses:
-- the same sentence its dialog prints as "Current filter:". Rebuilt here rather than read off
-- the dialog because the dialog only exists while it is open.
--
-- Not cheap -- getMaterialFilter walks every material in the world -- so it is computed when
-- the panel opens and again whenever the filter dialog closes, never per frame. The b/l/o/r
-- toggles are buildingplan's global generic-material settings, not part of this filter, so they
-- do not change it.
function filter_summary()
    local ok, out = pcall(function()
        local idx = FILTER_IDX - 1
        local filters = dfhack.buildings.getFiltersByType({}, WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM)
        local desc = filters and filters[FILTER_IDX] and buildingplan.get_desc(filters[FILTER_IDX])
            or 'Building material'
        local heat = buildingplan.getHeatSafetyFilter(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM)
        local text = (heat >= 2 and 'Magma safe ' or heat == 1 and 'Fire safe ' or 'Any ') .. desc
        local specials = buildingplan.getSpecials(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM)
        if next(specials) then
            local list = {}
            for name in pairs(specials) do list[#list + 1] = name end
            table.sort(list)
            text = text .. ' [' .. table.concat(list, ', ') .. ']'
        end
        -- named materials only count while a category mask is actually set
        local cats = buildingplan.getMaterialMaskFilter(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM, idx)
        local names = {}
        if cats and not cats.unset then
            for name, props in pairs(
                buildingplan.getMaterialFilter(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM, idx) or {}
            ) do
                if props.enabled == 'true' and cats[props.category] then names[#names + 1] = name end
            end
        end
        if #names > 0 then
            table.sort(names)
            text = text .. (' of %s'):format(table.concat(names, ', '))
        end
        return text
    end)
    return ok and out or 'Any building material'
end

WallFilterScreen = defclass(WallFilterScreen, gui.ZScreen)
WallFilterScreen.ATTRS{
    focus_path = 'dig-replace-walls/filter',
    defocusable = false,
    on_close = DEFAULT_NIL,
}

function WallFilterScreen:init()
    local filterselection = require('plugins.buildingplan.filterselection')
    local uibs = df.global.buildreq
    self.saved = {uibs.building_type, uibs.building_subtype, uibs.custom_type}
    uibs.building_type, uibs.building_subtype, uibs.custom_type = WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM
    local filters = dfhack.buildings.getFiltersByType({}, WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM)
    local desc = filters and filters[FILTER_IDX] and buildingplan.get_desc(filters[FILTER_IDX])
        or 'Building material'
    self:addviews{filterselection.FilterSelection{index = FILTER_IDX, desc = desc}}
end

function WallFilterScreen:onDismiss()
    local uibs = df.global.buildreq
    uibs.building_type, uibs.building_subtype, uibs.custom_type =
        self.saved[1], self.saved[2], self.saved[3]
    if self.on_close then self.on_close() end
end

function WallFilterScreen:dismiss()
    WallFilterScreen.super.dismiss(self)
    no_full_refresh()
end

-- ---- the painter ------------------------------------------------------------

-- NOT A ZSCREEN, ON PURPOSE. Every DFHack screen forces a full-screen refresh when it closes:
-- the C++ teardown sets `gps.force_full_display_count` a frame or two after dismissal, DF blanks
-- the screen and redraws it, and that blank frame is the black flash. It is not something the
-- lua side can withdraw -- clearing `Screen.request_full_screen_refresh` and even zeroing the
-- counter by hand both get overwritten, and a bare do-nothing ZScreen reproduces it exactly. So
-- the painter is an OVERLAY instead: it is created once and only shown and hidden, no viewscreen
-- is ever built or torn down, and there is nothing to flash. It also means the gesture poller
-- keeps running while the game is paused, which is when designating mostly happens.

painting = painting or false

local SETTINGS = {
    {view_id = 'blocks',   key = 'CUSTOM_B', label = 'Blocks'},
    {view_id = 'logs',     key = 'CUSTOM_L', label = 'Logs'},
    {view_id = 'boulders', key = 'CUSTOM_O', label = 'Boulders'},
    {view_id = 'bars',     key = 'CUSTOM_R', label = 'Bars'},
}

ReplaceWallPanel = defclass(ReplaceWallPanel, overlay.OverlayWidget)
ReplaceWallPanel.ATTRS{
    desc = 'The Replace Wall painter (fort/dig-replace-walls).',
    default_pos = {x = 7, y = 9},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 38, h = 13},
    frame_style = gui.FRAME_MEDIUM,
    frame_title = 'Replace Wall',
    frame_background = dfhack.pen.parse{ch = ' ', fg = COLOR_BLACK, bg = COLOR_BLACK},
    overlay_onupdate_max_freq_seconds = 0,
    visible = function() return painting end,
}

function ReplaceWallPanel:init()
    self.summary = filter_summary()
    local subs = {
        -- what walls will actually be built out of, in buildingplan's own words
        widgets.Label{frame = {l = 0, t = 0}, text = 'Filter:'},
        widgets.WrappedLabel{
            frame = {l = 0, t = 1, h = 3, r = 0},
            text_pen = COLOR_LIGHTCYAN,
            text_to_wrap = function() return self.summary end,
            auto_height = false,
        },
        widgets.HotkeyLabel{
            frame = {l = 0, t = 5},
            key = 'CUSTOM_F',
            label = function()
                return buildingplan.hasFilter(WALL_TYPE, WALL_SUBTYPE, WALL_CUSTOM, FILTER_IDX - 1)
                    and 'Edit filter' or 'Set filter'
            end,
            on_activate = self:callback('edit_filter'),
        },
    }
    for i, s in ipairs(SETTINGS) do
        subs[#subs + 1] = widgets.ToggleHotkeyLabel{
            view_id = s.view_id,
            frame = {l = 0, t = i + 6},
            key = s.key,
            label = s.label,
            label_width = 9,
            on_change = function(val) self:set_setting(s.view_id, val) end,
        }
    end
    self:addviews(subs)
    self:cancel_drag()
end

-- ---- opening and closing ----------------------------------------------------

function ReplaceWallPanel:open()
    self.summary = filter_summary()
    self:refresh_settings()
    self:cancel_drag()
    -- DISARM DF'S DESIGNATION TOOL for as long as we are up, and put it back on the way out.
    --
    -- The painter is normally opened from fort/dig-building's picker while the Dig tool is
    -- selected, and that tool stays armed on the map underneath. Our own clicks are swallowed
    -- here -- but the repo's map tools poll the mouse buttons straight from the overlay pump,
    -- with no idea another tool has the map. fort/right-click-cancel does exactly that, and on
    -- the release that ended a paint drag it completed a dig box with a synthetic click of its
    -- own, leaving a designation on the last tile of the drag. With no designation tool
    -- selected there is nothing for any of them -- or for DF -- to act on.
    local mi = df.global.game.main_interface
    self.saved_tool = mi.main_designation_selected
    mi.main_designation_selected = df.main_designation_type.NONE
    -- the click that OPENED us is still held: account for it, so it is not read as a fresh press
    self.lbut, self.rbut = df.global.enabler.mouse_lbut_down, df.global.enabler.mouse_rbut_down
    painting = true
end

function ReplaceWallPanel:close()
    painting = false
    self:cancel_drag()
    if self.saved_tool then
        df.global.game.main_interface.main_designation_selected = self.saved_tool
        self.saved_tool = nil
    end
end

-- read buildingplan's global settings into the toggles
function ReplaceWallPanel:refresh_settings()
    local ok, settings = pcall(buildingplan.getGlobalSettings)
    if not ok or not settings then return end
    for _, s in ipairs(SETTINGS) do
        local w = self.subviews[s.view_id]
        if w and settings[s.view_id] ~= nil then w:setOption(settings[s.view_id]) end
    end
end

function ReplaceWallPanel:set_setting(name, val)
    pcall(buildingplan.setSetting, name, val)
    self:refresh_settings()
end

function ReplaceWallPanel:edit_filter()
    self:cancel_drag()
    WallFilterScreen{on_close = function()
        self.summary = filter_summary()
        self:refresh_settings()
    end}:show()
end

-- ---- what counts as a click on the map ---------------------------------------
--
-- `dfhack.gui.getMousePos()` answers "which map tile is under the cursor", and it answers that
-- just as happily when the cursor is over a panel drawn ON TOP of the map. Taken at face value
-- it turned every click on a piece of interface into a selection corner. So presses are routed
-- through this, the same guard fort/dig-shapes and fort/right-click-cancel use.

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

-- Is the cursor over some other overlay drawn above the map?
--
-- A widget's frame_rect is only its MAXIMUM extent, not proof it drew anything at this cell --
-- several stock toolbars declare a tooltip-sized frame and paint a small icon inside it -- so
-- first confirm something is actually rendered there. Map tiles are graphics (ch == 0); panel
-- text is not.
--
-- OUR OWN MAP MARKERS ARE NOT INTERFACE. They are drawn onto map tiles, so the "something is
-- rendered here" test would call every wall we have already painted a piece of UI -- making
-- exactly those tiles impossible to right-click and unselect. We know which tiles are ours, so
-- they are judged as map, which is what they are.
local function over_other_overlay(mx, my, marked)
    if marked then return false end
    local ok0, t = pcall(dfhack.screen.readTile, mx, my)
    if not ok0 or not t or not t.ch or t.ch <= 32 then return false end
    local vs = dfhack.gui.getDFViewscreen(true)
    local fullw, fullh = df.global.gps.dimx - 1, df.global.gps.dimy - 1
    for name, e in pairs(overlay.get_state().db) do
        if name ~= 'fort/dig-replace-walls.pending' and name ~= 'fort/dig-replace-walls.panel' then
            local w = e.widget
            local r = w and w.frame_rect
            if r and mx >= r.x1 and mx <= r.x2 and my >= r.y1 and my <= r.y2
                and not (r.x1 <= 0 and r.y1 <= 0 and r.x2 >= fullw and r.y2 >= fullh)
                and widget_on_screen(w, vs) then
                local ok, vis = pcall(function() return require('utils').getval(w.visible) end)
                if ok and vis then return true end
            end
        end
    end
    return false
end

function ReplaceWallPanel:map_pos_if_clear()
    local p = dfhack.gui.getMousePos()
    if not p then return nil end
    if self:getMouseFramePos() then return nil end                   -- our own panel
    local m = df.global.game.main_interface
    if m.current_hover ~= -1 then return nil end                     -- a DF hover element
    if m.current_hover_alert then return nil end                     -- a DF notification/alert
    local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
    if over_other_overlay(mx, my, planned_keys()[key(p)]) then return nil end
    return p
end

-- ---- gestures ---------------------------------------------------------------
-- The repo's map gesture scheme (fort/right-click-cancel): drag a box to apply, right-drag a
-- box to take it back, and a click in place is one corner of a click-and-second-click box.
-- Both buttons are resolved on RELEASE, read off DF's own button state.

function ReplaceWallPanel:cancel_drag()
    self.press, self.mode, self.corner = nil, nil, nil
end

-- the box a gesture would act on right now: from the pending click-click corner if there is
-- one, else from where the button went down
function ReplaceWallPanel:anchor()
    return self.corner or self.press
end

function ReplaceWallPanel:apply(a, b, mode)
    if mode == 'erase' then
        local dropped, stuck = erase_box(a, b)
        if stuck > 0 then
            dfhack.gui.showAnnouncement(
                ('%d wall%s already being taken down -- left to finish.')
                    :format(stuck, stuck == 1 and '' or 's'), COLOR_YELLOW)
        end
        return dropped
    end
    local painted, skipped, _, err, correct = paint_box(a, b)
    if err then
        dfhack.gui.showAnnouncement('Replace wall: ' .. err, COLOR_LIGHTRED)
    elseif painted == 0 and (correct or 0) > 0 then
        dfhack.gui.showAnnouncement(
            ('Replace wall: %d wall%s already built to that filter -- nothing to replace.')
            :format(correct, correct == 1 and ' is' or 's are'), COLOR_YELLOW)
    elseif painted == 0 and skipped > 0 then
        dfhack.gui.showAnnouncement('Replace wall: nothing there but floors, doors and furniture.',
            COLOR_YELLOW)
    end
    return painted
end

function ReplaceWallPanel:on_release(rel, mode)
    local a = self:anchor()
    if not a or not rel or a.z ~= rel.z then self:cancel_drag() return end
    local dragged = not same(self.press, rel)
    if dragged then                       -- a drag: the box is press..release
        self:apply(a, rel, mode)
        self:cancel_drag()
    elseif self.corner then               -- second click of a click-click box: complete it
        self:apply(self.corner, rel, mode)
        self:cancel_drag()
    else                                  -- first click in place: hold the corner
        self.corner, self.mode = rel, mode
        self.press = nil
    end
end

-- Are we the thing the player is actually looking at? A ZScreen of ours (the buildingplan
-- filter dialog) sits above the map with its own focus path; while one is up the map is not
-- being clicked on, and the buttons must not be read.
local function on_map_screen()
    local foc = dfhack.gui.getCurFocus(true)[1] or ''
    return foc:sub(1, 9) == 'dwarfmode'
end

function ReplaceWallPanel:overlay_onupdate()
    if not painting then return end
    local e = df.global.enabler
    local l, r = e.mouse_lbut_down, e.mouse_rbut_down
    if not on_map_screen() then
        -- something of ours is on top: read nothing, but keep tracking the hardware state so
        -- the click that dismisses it cannot come back to us as a stray release
        self.lbut, self.rbut = l, r
        self:cancel_drag()
        return
    end

    if l == 1 and self.lbut ~= 1 then
        -- a left press during a right-drag cancels the erase instead of painting
        if self.mode == 'erase' and self.press then self:cancel_drag(); self.ate = true
        else self.ate = false; self.press = self:map_pos_if_clear(); self.mode = 'paint' end
    elseif l ~= 1 and self.lbut == 1 then
        if not self.ate and self.press then self:on_release(dfhack.gui.getMousePos(), 'paint') end
        self.ate = false
    end
    self.lbut = l

    if r == 1 and self.rbut ~= 1 then
        -- a right press while anything is pending BACKS THAT OUT (a half-placed
        -- click-click corner, or a left-drag in progress) and does not start an erase
        if self:anchor() and self.mode ~= 'erase' then self:cancel_drag(); self.rate = true
        else self.rate = false; self.press = self:map_pos_if_clear(); self.mode = 'erase' end
    elseif r ~= 1 and self.rbut == 1 then
        if not self.rate and self.press then
            local rel = dfhack.gui.getMousePos()
            if rel and same(self.press, rel) and not self.corner then
                -- right-click in place: unselect the tile under the cursor if something is
                -- painted there; on a bare tile it means "done", and closes.
                self:cancel_drag()
                if planned_keys()[key(rel)] then erase_box(rel, rel) else self:close() end
            else
                self:on_release(rel, 'erase')
            end
        end
        self.rate = false
    end
    self.rbut = r
end

function ReplaceWallPanel:onInput(keys)
    if not painting then return false end
    if keys.LEAVESCREEN then
        if self:anchor() then self:cancel_drag() return true end
        self:close()
        return true
    end
    -- clicks on the panel itself belong to the panel (its hotkey labels and toggles)
    if (keys._MOUSE_L or keys._MOUSE_R) and self:getMouseFramePos() then
        return ReplaceWallPanel.super.onInput(self, keys)
    end
    -- swallow clicks on the MAP (both buttons are resolved on release in overlay_onupdate); a
    -- click on any interface -- DF's, another overlay's -- is passed straight through
    if keys._MOUSE_L or keys._MOUSE_R then
        return self:map_pos_if_clear() ~= nil
    end
    if ReplaceWallPanel.super.onInput(self, keys) then return true end
    -- a letter typed at the map while we are up must not also drive DF's own map hotkeys
    return reqscript('internal/typed-keys').swallows(keys)
end

function ReplaceWallPanel:onRenderFrame(dc, rect)
    ReplaceWallPanel.super.onRenderFrame(self, dc, rect)
    local a = self:anchor()
    if not a then return end
    local cur = dfhack.gui.getMousePos()
    if not cur or cur.z ~= a.z then return end
    local vp = guidm.Viewport.get()
    if not vp or vp.z ~= a.z then return end
    local tile = self.mode == 'erase' and ERASE_TILE or PAINT_TILE
    if not tile then return end
    -- same map layer as the pending marks: written into DF's own frame, never stamped on top
    local gvp = df.global.gps.main_viewport
    local dimx, dimy = gvp.dim_x, gvp.dim_y
    if dimx <= 0 or dimy <= 0 then return end
    local arr, arr_old = gvp.screentexpos_interface, gvp.screentexpos_interface_old
    for_box(a, cur, function(p)
        local vx, vy = p.x - vp.x1, p.y - vp.y1
        if vx >= 0 and vy >= 0 and vx < dimx and vy < dimy then
            local at = vx * dimy + vy
            arr[at], arr_old[at] = tile, tile
        end
    end)
end

-- the painter is a single overlay widget, so opening it is just switching it on
function show()
    if not dfhack.isMapLoaded() then qerror('a fortress map must be loaded') end
    local w = overlay.get_state().db['fort/dig-replace-walls.panel']
    if not w or not w.widget then qerror('the fort/dig-replace-walls.panel overlay is not loaded') end
    w.widget:open()
end

function hide()
    local w = overlay.get_state().db['fort/dig-replace-walls.panel']
    if w and w.widget then w.widget:close() else painting = false end
end

-- ---- lifecycle & command ----------------------------------------------------

dfhack.onStateChange[PERSIST_KEY] = function(code)
    if code == SC_MAP_LOADED then dfhack.timeout(1, 'frames', resume)
    elseif code == SC_MAP_UNLOADED then stop() end
end

-- a reload does not re-emit SC_MAP_LOADED for a map that is already open
if dfhack.isMapLoaded() then resume() end

OVERLAY_WIDGETS = {pending = ReplaceWallMarks, panel = ReplaceWallPanel}

if dfhack_flags.module then return end

local cmd = ({...})[1]
if not cmd or cmd == 'paint' then
    show()
elseif cmd == 'status' then
    print(('dig-replace-walls: %d wall%s pending, manager %s')
        :format(plan_count(), plan_count() == 1 and '' or 's', running and 'running' or 'idle'))
elseif cmd == 'resume' then
    resume()
    print(('dig-replace-walls: %d pending.'):format(plan_count()))
elseif cmd == 'clear' then
    print(('dig-replace-walls: forgot %d pending wall(s).'):format(clear()))
else
    qerror('unknown dig-replace-walls command: ' .. tostring(cmd))
end
