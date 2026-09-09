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

Two kinds of wall are accepted, and they come down differently:
  * a NATURAL wall (rock/soil) is designated for MINING;
  * a CONSTRUCTED wall is designated for REMOVAL, so it can be rebuilt out of something else.

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

Pending tiles are marked on the map by overlay `fort/dig-replace-walls.pending`.

Usually reached from the `fort/dig-building` picker ("Replace wall", in the custom-tool band
at the bottom; the picker hides itself while this screen is up). `dig-replace-walls` opens the painter; `dig-replace-walls status`
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
local CYCLE_TICKS = 100        -- how often the manager re-checks the pending tiles
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
    -- No job we can take back. Either the removal was never queued, or it has already
    -- happened -- in which case the wall is gone and the plan is moot either way. But if the
    -- wall is STILL STANDING and we found nothing to cancel, say so rather than report a
    -- removal taken back that was not.
    return not is_constructed_wall(p)
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
local function inspect(rec)
    local p = pos(rec.x, rec.y, rec.z)
    local b = building_at(p)
    if b then
        -- our own planned wall, or the old constructed wall still standing: either way
        -- there is nothing for us to do on this tile yet.
        if is_wall_construction(b) then
            return buildingplan.isPlannedBuilding(b) and 'done' or 'wait'
        end
        return 'drop', 'another building was placed here'
    end
    if is_natural_wall(p) or is_constructed_wall(p) then return 'wait' end
    if not is_clear(p) then return 'drop', 'the tile is neither a wall nor clear ground' end
    local bld, err = plan_wall(p)
    if bld then return 'done' end
    return 'wait', err
end

function cycle(gen)
    if gen ~= generation or not dfhack.isMapLoaded() then return end
    local plans = load_plans()
    local keep, handoffs, changed = {}, 0, false
    for _, rec in ipairs(plans) do
        local action, err = 'wait', nil
        if handoffs < MAX_HANDOFFS then action, err = inspect(rec) end
        if action == 'done' then
            handoffs, changed = handoffs + 1, true
        elseif action == 'drop' then
            changed = true
            dfhack.printerr(('dig-replace-walls (%d,%d,%d): %s'):format(rec.x, rec.y, rec.z, err))
        else
            keep[#keep + 1] = rec
            if err then
                dfhack.printerr(('dig-replace-walls (%d,%d,%d): %s'):format(rec.x, rec.y, rec.z, err))
            end
        end
    end
    if changed then save_plans(keep) end
    if #keep == 0 then running = false return end
    dfhack.timeout(CYCLE_TICKS, 'ticks', function() cycle(gen) end)
end

function start()
    if running or not dfhack.isMapLoaded() then return end
    running = true
    generation = generation + 1
    local gen = generation
    dfhack.timeout(1, 'ticks', function() cycle(gen) end)
end

function stop()
    generation = generation + 1
    running = false
end

-- re-apply anything that lost its designation (a cancelled dig, a reloaded save) and get the
-- cycle going again
function resume()
    if not dfhack.isMapLoaded() then return end
    local plans = load_plans()
    for _, rec in ipairs(plans) do
        local p = pos(rec.x, rec.y, rec.z)
        if is_natural_wall(p) and dig_val(p) == DV.No then set_dig(p, DV.Default) end
        if rec.con and is_constructed_wall(p) then
            pcall(dfhack.constructions.designateRemove, p)
        end
    end
    if #plans > 0 then start() end
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

-- Paint the box. Returns counts: painted, skipped (something that is not a wall, or a
-- masterwork), already (already painted).
function paint_box(a, b)
    local plans = load_plans()
    local have = {}
    for _, r in ipairs(plans) do have[key(r)] = true end
    local painted, skipped, already = 0, 0, 0
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
    return painted, skipped, already
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
            if rec.con then
                if cancel_removal(p) then dropped = dropped + 1
                else keep[#keep + 1] = rec; stuck = stuck + 1 end
            else
                if is_natural_wall(p) then set_dig(p, DV.No) end
                dropped = dropped + 1
            end
        else
            keep[#keep + 1] = rec
        end
    end
    if dropped > 0 then save_plans(keep) end
    return dropped, stuck
end

-- ---- the map marker overlay -------------------------------------------------

local PENDING_PEN = dfhack.pen.parse{ch = 'X', fg = COLOR_LIGHTCYAN, keep_lower = true,
    tile = dfhack.screen.findGraphicsTile('CURSORS', 3, 0)}

ReplaceWallMarks = defclass(ReplaceWallMarks, overlay.OverlayWidget)
ReplaceWallMarks.ATTRS{
    desc = 'Marks the walls painted for replacement by fort/dig-replace-walls.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0.25,
}

function ReplaceWallMarks:init() self.marks = {} end

-- Read the plan list on the SLOW update, never per frame: it is a persistent-data
-- round trip and this widget renders on every frame of the map.
function ReplaceWallMarks:overlay_onupdate()
    self.marks = {}
    if not dfhack.isMapLoaded() or not dfhack.isSiteLoaded() then return end
    for _, r in ipairs(load_plans()) do self.marks[#self.marks + 1] = pos(r.x, r.y, r.z) end
end

function ReplaceWallMarks:onRenderFrame(dc, rect)
    if #self.marks == 0 then return end
    local vp = guidm.Viewport.get()
    if not vp then return end
    for _, p in ipairs(self.marks) do
        if p.z == vp.z and vp:isVisible(p) then
            local s = vp:tileToScreen(p)
            dfhack.screen.paintTile(PENDING_PEN, s.x, s.y, nil, nil, true)
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

-- ---- the painter ------------------------------------------------------------

local PAINT_PEN = dfhack.pen.parse{ch = 'X', fg = COLOR_LIGHTGREEN, keep_lower = true,
    tile = dfhack.screen.findGraphicsTile('CURSORS', 3, 0)}
local ERASE_PEN = dfhack.pen.parse{ch = 'X', fg = COLOR_LIGHTRED, keep_lower = true,
    tile = dfhack.screen.findGraphicsTile('CURSORS', 3, 0)}

ReplaceWallScreen = defclass(ReplaceWallScreen, gui.ZScreen)
ReplaceWallScreen.ATTRS{
    focus_path = 'dig-replace-walls/paint',
    pass_movement_keys = true,
    pass_mouse_clicks = false,
}

local SETTINGS = {
    {view_id = 'blocks',   key = 'CUSTOM_B', label = 'Blocks'},
    {view_id = 'logs',     key = 'CUSTOM_L', label = 'Logs'},
    {view_id = 'boulders', key = 'CUSTOM_O', label = 'Boulders'},
    {view_id = 'bars',     key = 'CUSTOM_R', label = 'Bars'},
}

function ReplaceWallScreen:init()
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
    self:addviews{
        widgets.Window{
            view_id = 'window',
            frame = {l = 6, t = 8, w = 38, h = 15, xalign = 0, yalign = 0},
            frame_title = 'Replace Wall',
            subviews = subs,
        },
    }
    self:refresh_settings()
    self:cancel_drag()
    -- SEED THE BUTTON STATE FROM DF, don't start from nil. The painter is opened BY a click
    -- (the "Replace wall" entry in fort/dig-building's picker), so the left button is still
    -- physically down when this screen appears. Starting at nil makes the very next onIdle
    -- read that held button as a fresh press and take the map tile under the picker entry as
    -- a selection corner -- which is how clicking the entry started painting the tile behind
    -- its own label. Seeded, the press is already accounted for and only the NEXT one counts.
    self.lbut, self.rbut = df.global.enabler.mouse_lbut_down, df.global.enabler.mouse_rbut_down
end

-- read buildingplan's global settings into the toggles (also picks up a change made in
-- buildingplan's own dialog while we were in it)
function ReplaceWallScreen:refresh_settings()
    local ok, settings = pcall(buildingplan.getGlobalSettings)
    if not ok or not settings then return end
    for _, s in ipairs(SETTINGS) do
        local w = self.subviews[s.view_id]
        if w and settings[s.view_id] ~= nil then w:setOption(settings[s.view_id]) end
    end
end

function ReplaceWallScreen:set_setting(name, val)
    pcall(buildingplan.setSetting, name, val)
    self:refresh_settings()
end

function ReplaceWallScreen:edit_filter()
    self:cancel_drag()
    WallFilterScreen{on_close = function() self.summary = filter_summary() end}:show()
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
-- OUR OWN MAP MARKERS ARE NOT INTERFACE. They are painted onto map tiles with a visible glyph,
-- so the "something is rendered here" test sees them and would call every wall we have already
-- painted a piece of UI -- making exactly those tiles impossible to right-click and unselect.
-- We know which tiles are ours, so they are judged as map, which is what they are.
local function over_other_overlay(mx, my, marked)
    if marked then return false end
    local ok0, t = pcall(dfhack.screen.readTile, mx, my)
    if not ok0 or not t or not t.ch or t.ch <= 32 then return false end
    local vs = dfhack.gui.getDFViewscreen(true)
    local fullw, fullh = df.global.gps.dimx - 1, df.global.gps.dimy - 1
    for name, e in pairs(overlay.get_state().db) do
        if name ~= 'fort/dig-replace-walls.pending' then
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

function ReplaceWallScreen:map_pos_if_clear()
    local p = dfhack.gui.getMousePos()
    if not p then return nil end
    if self.subviews.window:getMouseFramePos() then return nil end   -- our own window
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
-- Both buttons are resolved on RELEASE, read off DF's own button state -- release events are
-- not reliably delivered to a screen that is passing clicks through.

function ReplaceWallScreen:cancel_drag()
    self.press, self.mode, self.corner = nil, nil, nil
end

-- the box a gesture would act on right now: from the pending click-click corner if there is
-- one, else from where the button went down
function ReplaceWallScreen:anchor()
    return self.corner or self.press
end

function ReplaceWallScreen:apply(a, b, mode)
    if mode == 'erase' then
        local dropped, stuck = erase_box(a, b)
        if stuck > 0 then
            dfhack.gui.showAnnouncement(
                ('%d wall%s already being taken down -- left to finish.')
                    :format(stuck, stuck == 1 and '' or 's'), COLOR_YELLOW)
        end
        return dropped
    end
    local painted, skipped, _, err = paint_box(a, b)
    if err then
        dfhack.gui.showAnnouncement('Replace wall: ' .. err, COLOR_LIGHTRED)
    elseif painted == 0 and skipped > 0 then
        dfhack.gui.showAnnouncement('Replace wall: nothing there but floors, doors and furniture.',
            COLOR_YELLOW)
    end
    return painted
end

function ReplaceWallScreen:on_release(rel, mode)
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

function ReplaceWallScreen:onIdle()
    ReplaceWallScreen.super.onIdle(self)
    local e = df.global.enabler
    local l, r = e.mouse_lbut_down, e.mouse_rbut_down

    -- ANOTHER SCREEN IS ON TOP -- our own buildingplan filter dialog, say. This poller keeps
    -- running underneath it, and a click meant for that screen is not a click on the map. So
    -- read nothing while it is up, and keep tracking the hardware state so the click that
    -- dismisses it cannot come back to us as a stray release.
    if not self:hasFocus() then
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
                if planned_keys()[key(rel)] then erase_box(rel, rel) else self:dismiss() end
            else
                self:on_release(rel, 'erase')
            end
        end
        self.rate = false
    end
    self.rbut = r
end

function ReplaceWallScreen:onInput(keys)
    if keys.LEAVESCREEN then
        if self:anchor() then self:cancel_drag() return true end
        self:dismiss()
        return true
    end
    -- clicks on the window itself belong to the window
    if (keys._MOUSE_L or keys._MOUSE_R) and self.subviews.window:getMouseFramePos() then
        return ReplaceWallScreen.super.onInput(self, keys)
    end
    -- swallow clicks on the MAP (both buttons are resolved on release in onIdle); a click on
    -- any interface -- ours, DF's, another overlay's -- is passed straight through
    if keys._MOUSE_L or keys._MOUSE_R then
        return self:map_pos_if_clear() ~= nil
    end
    return ReplaceWallScreen.super.onInput(self, keys)
end

function ReplaceWallScreen:onRenderFrame(dc, rect)
    self:refresh_settings()
    ReplaceWallScreen.super.onRenderFrame(self, dc, rect)
    local a = self:anchor()
    if not a then return end
    local cur = dfhack.gui.getMousePos()
    if not cur or cur.z ~= a.z then return end
    local vp = guidm.Viewport.get()
    if not vp or vp.z ~= a.z then return end
    local pen = self.mode == 'erase' and ERASE_PEN or PAINT_PEN
    for_box(a, cur, function(p)
        if vp:isVisible(p) then
            local s = vp:tileToScreen(p)
            dfhack.screen.paintTile(pen, s.x, s.y, nil, nil, true)
        end
    end)
end

function show()
    if not dfhack.isMapLoaded() then qerror('a fortress map must be loaded') end
    ReplaceWallScreen{}:show()
end

-- ---- lifecycle & command ----------------------------------------------------

dfhack.onStateChange[PERSIST_KEY] = function(code)
    if code == SC_MAP_LOADED then dfhack.timeout(1, 'ticks', resume)
    elseif code == SC_MAP_UNLOADED then stop() end
end

-- a reload does not re-emit SC_MAP_LOADED for a map that is already open
if dfhack.isMapLoaded() then resume() end

OVERLAY_WIDGETS = {pending = ReplaceWallMarks}

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
