-- Redraw every planned construction, to shake loose the ones deadlocked on a reserved item.
--@module = true
--[[
fort/rewall

A wall that never gets built is usually not waiting on a mason. It is waiting on ITSELF.

The common shape: a hauler drops the block for one wall onto the tile of the NEXT one, that
tile is now occupied by an item another job has claimed, and DF suspends the job rather than
building over it. The claim never lapses, because the job holding it is suspended too, waiting
on a tile of its own. Nothing in the fort resolves that -- the walls sit "planned" with their
material lying right there, sometimes for years.

Redrawing the designation is what breaks it: the suspended job and its claim on the item go
away, and DF issues a fresh, unsuspended job that picks a material from scratch. This does
that for every planned construction in the fort, and puts back exactly what it took away: the
same construction type on the same tile, asking for the same material -- which, as the comment
on `pin_to_item` explains, means reading the item ALREADY HAULED to the site rather than the
job's filter, because that is where DF keeps the stone you chose. A wall that had conglomerate
waiting on it is redrawn asking for conglomerate. `--any-material` gives that up deliberately,
for when breaking the tangle matters more than the stone.

    fort/rewall                 redraw every planned construction
    fort/rewall -n              report what it would redraw, change nothing
    fort/rewall --suspended     only the suspended ones -- the deadlocked ones
    fort/rewall --any-material  let the new jobs take whatever is nearest, choice and all
    fort/rewall -v              name every construction touched
    fort/rewall register        load the deadlock warning only, and redraw nothing

WHAT IT WILL NOT TOUCH

  * Anything BUILDINGPLAN is holding. Its filter -- conglomerate blocks, magma-safe metal --
    lives in the plugin rather than in the building, so a redraw would throw the plan away and
    leave a plain construction that takes the nearest rock. Those are not deadlocked on an
    item claim anyway; they are waiting for stock.
  * Anything a dwarf is actually building. A construction whose job has a worker is left
    alone: that one is not stuck, and taking a job out from under the dwarf holding it is
    how this repo has crashed DF before.
  * Anything already part-built (`construction_stage` above 0). Only designations that have
    never been started are redrawn -- a half-built wall is progress, not a deadlock.

THE WARNING

  A deadlocked wall is invisible: it looks exactly like a wall waiting its turn, and the fort
  works around it, so nobody looks until a corridor has been open to the caverns for a season.
  `fort/rewall register` puts a line in DFHack's notification panel -- "7 constructions
  deadlocked -- run fort/rewall" -- counting the planned constructions that are suspended with
  their material already hauled and nobody working them, which is the signature this tool
  exists to clear. Clicking the line walks you through the tiles. `magnus-scripts` turns it on.

WHAT IT COSTS

  Any material already hauled to the site is released. That is the point -- the reservation is
  the deadlock -- but it does mean the block goes back to being loose stock for a moment, and
  a hauler may carry it somewhere else before the new job claims it. The wall is not lost,
  only the trip.

  Priorities set per designation are DF's own and ride on the building, so they go with it.
]]

local buildingplan = require('plugins.buildingplan')

local dry, verbose, suspended_only, any_material = false, false, false, false

local function act(fmt, ...)
    print((dry and '[dry] ' or '') .. fmt:format(...))
end

-- ---- what the designation was, in plain values -------------------------------
--
-- Everything needed to draw the same designation again, read off before anything is removed.
-- The FILTER is the part that matters and the part that is easy to lose -- the item type, the
-- subtype, the material, and the flags that say "any building material" or "no economic stone".
-- It is snapshotted into plain tables and handed straight back to `constructBuilding`.
--
-- Quantity is deliberately NOT carried over. On a job that already has its material it has
-- counted down, and a new job that needs nothing is a wall that never gets built; DF fills it
-- in for a fresh job anyway.
local FILTER_FIELDS = {'item_type', 'item_subtype', 'mat_type', 'mat_index', 'metal_ore',
                       'min_dimension', 'reaction_class', 'has_material_reaction_product'}
local FILTER_FLAGS = {'flags1', 'flags2', 'flags3'}

-- what DF uses for a construction drawn with no material chosen at all
local function default_filters()
    return {{flags2 = {building_material = true, non_economic = true}}}
end

local function snapshot_filters(job)
    if not job then return default_filters() end
    local out = {}
    for _, src in ipairs(job.job_items.elements) do
        local one = {}
        for _, f in ipairs(FILTER_FIELDS) do one[f] = src[f] end
        for _, fl in ipairs(FILTER_FLAGS) do
            local bits = {}
            for k, v in pairs(src[fl]) do if v == true then bits[k] = true end end
            one[fl] = bits
        end
        out[#out + 1] = one
    end
    if #out == 0 then return default_filters() end
    return out
end

-- THE MATERIAL YOU CHOSE IS NOT IN THE FILTER. It is in the ITEM.
--
-- When you pick a stone for a construction, DF does not narrow the job's filter -- that stays the
-- generic "any building material, nothing economic" it was born with. What it does is ATTACH the
-- item you picked to the job. So a redraw that keeps the filter and releases the item keeps the
-- half that says nothing and throws away the half that was your decision: walls that had
-- conglomerate reserved came back sandstone, which is exactly what happened the first time this
-- ran on a live fort.
--
-- So when a job has an item attached, the new filter is built FROM THAT ITEM -- its item type,
-- its subtype and its material -- and the fresh job goes looking for the same thing. The
-- non-economic flag is dropped along with it: that guard exists to stop DF spending economic
-- stone when anything would do, and this is no longer a case where anything would do.
local function pin_to_item(base, item)
    local one = {}
    for k, v in pairs(base or {}) do
        if k == 'flags1' or k == 'flags2' or k == 'flags3' then
            local bits = {}
            for bit, on in pairs(v) do bits[bit] = on end
            one[k] = bits
        else
            one[k] = v
        end
    end
    one.item_type = item:getType()
    one.item_subtype = item:getSubtype()
    one.mat_type = item:getMaterial()
    one.mat_index = item:getMaterialIndex()
    if one.flags2 then one.flags2.non_economic = nil end
    return one
end

-- filters for the redraw, and the material name if the choice was pinned
local function filters_for(job)
    local base = snapshot_filters(job)
    if any_material or not job or #job.items == 0 then return base, nil end
    local pinned, name = {}, nil
    for i, ji in ipairs(job.items) do
        pinned[#pinned + 1] = pin_to_item(base[i + 1] or base[1], ji.item)
        if not name then
            local mat = dfhack.matinfo.decode(ji.item)
            name = mat and mat:toString() or nil
        end
    end
    return pinned, name
end

-- Draw it again. `constructBuilding` rather than `constructions.designateNew`, and that is not
-- a preference: designateNew REFUSES a tile that already carries a finished construction, and a
-- wall queued on top of a constructed floor is an ordinary thing to want. Four of those were
-- removed and could not be put back the first time this ran. constructBuilding takes them, and
-- takes the filter verbatim into the bargain.
local function redraw(pos, ctype, filters)
    local ok, bld = pcall(dfhack.buildings.constructBuilding,
        {type = df.building_type.Construction, subtype = ctype, pos = pos, filters = filters})
    if ok and bld then return true end
    -- last resort, so a removed designation is never simply lost
    if dfhack.constructions.designateNew(pos, ctype, -1, -1) then return true, 'filter reset' end
    return false
end

-- ---- the deadlock, as a question anything can ask ---------------------------
--
-- A construction is stuck in the way this tool exists to fix when its job is SUSPENDED with a
-- material already hauled to it and nobody working it. That is the whole signature: the block is
-- there, the job will not run, and nothing in the fort will ever change its mind.
function stuck_constructions()
    local out = {}
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld:getType() == df.building_type.Construction and bld.construction_stage == 0
                and not buildingplan.isPlannedBuilding(bld) then
            local job = bld.jobs[0]
            if job and job.flags.suspend and #job.items > 0 and not dfhack.job.getWorker(job) then
                out[#out + 1] = {x = bld.x1, y = bld.y1, z = bld.z}
            end
        end
    end
    return out
end

-- ---- collect first, act afterwards -------------------------------------------
--
-- Redrawing a designation adds and removes entries in world.buildings.all, so the list is
-- snapshotted before a single one is touched.
function run(...)
    dry, verbose, suspended_only, any_material = false, false, false, false
    for _, a in ipairs({...}) do
        if a == '-n' or a == '--dry-run' then dry = true
        elseif a == '-v' or a == '--verbose' then verbose = true
        elseif a == '--suspended' then suspended_only = true
        elseif a == '--any-material' then any_material = true
        else qerror('unknown argument: ' .. a) end
    end
    if not dfhack.isMapLoaded() then qerror('fort/rewall needs a loaded fort') end

local targets, working, part_built, planned = {}, 0, 0, 0

for _, bld in ipairs(df.global.world.buildings.all) do
    if bld:getType() == df.building_type.Construction then
        if bld.construction_stage > 0 then
            part_built = part_built + 1
        elseif buildingplan.isPlannedBuilding(bld) then
            -- BUILDINGPLAN'S, NOT OURS. A wall it is holding is waiting for a material that
            -- matches ITS filter -- conglomerate blocks, magma-safe metal, whatever was set --
            -- and that filter lives in the plugin, not in the building. Redrawing one throws
            -- the plan away and leaves a plain construction that will take the nearest rock,
            -- which is a wall built out of the wrong thing rather than a wall unstuck.
            planned = planned + 1
        else
            local job = bld.jobs[0]
            if job and dfhack.job.getWorker(job) then
                working = working + 1
            elseif not (suspended_only and not (job and job.flags.suspend)) then
                local filters, material = filters_for(job)
                targets[#targets + 1] = {
                    pos = {x = bld.x1, y = bld.y1, z = bld.z},
                    ctype = bld.type,
                    suspended = job and job.flags.suspend or false,
                    held = job and #job.items or 0,
                    filters = filters,
                    material = material,
                }
            end
        end
    end
end

if #targets == 0 then
    print('fort/rewall: nothing to redraw -- no planned construction is waiting.')
    if working > 0 then
        print(('  (%d %s being built right now)'):format(working, working == 1 and 'is' or 'are'))
    end
    return
end

local redrawn, failed, freed = 0, {}, 0

for _, t in ipairs(targets) do
    local what = ('%s at %d,%d,%d'):format(df.construction_type[t.ctype] or '?',
                                           t.pos.x, t.pos.y, t.pos.z)
    if verbose then
        act('%s%s%s', what, t.suspended and ' -- suspended' or '',
            t.material and (', keeping ' .. t.material) or
            (t.held > 0 and (', %d item held'):format(t.held) or ''))
    end
    if not dry then
        local removed = dfhack.constructions.designateRemove(t.pos)
        if not removed then
            failed[#failed + 1] = what .. ' (could not be removed)'
        else
            local ok, note = redraw(t.pos, t.ctype, t.filters)
            if ok then
                redrawn = redrawn + 1
                if t.held > 0 then freed = freed + 1 end
                if note then
                    failed[#failed + 1] = what .. ' (redrawn, but its ' .. note .. ')'
                end
            else
                -- say so loudly and by name: the designation is GONE and only you can put it back
                failed[#failed + 1] = what .. ' (REMOVED AND COULD NOT BE REDRAWN -- redraw it by hand)'
            end
        end
    else
        redrawn = redrawn + 1
        if t.held > 0 then freed = freed + 1 end
    end
end

act('%d construction%s redrawn.', redrawn, redrawn == 1 and '' or 's')
local stuck = 0
for _, t in ipairs(targets) do if t.suspended then stuck = stuck + 1 end end
if stuck > 0 then
    act('  %d of them %s suspended -- those are the deadlocked ones.', stuck,
        stuck == 1 and 'was' or 'were')
end
if freed > 0 then
    local pinned = 0
    for _, t in ipairs(targets) do if t.material then pinned = pinned + 1 end end
    act('  %d had a material already hauled to the site; that claim is released.', freed)
    if pinned > 0 then
        act('  %d %s redrawn asking for the same material again.', pinned,
            pinned == 1 and 'was' or 'were')
    elseif any_material then
        act('  --any-material: the new jobs will take whatever is nearest.')
    end
end
if working > 0 then
    print(('  %d left alone: a dwarf is building %s right now.'):format(
        working, working == 1 and 'it' or 'them'))
end
if part_built > 0 then
    print(('  %d left alone: already part-built.'):format(part_built))
end
if planned > 0 then
    print(('  %d left alone: buildingplan is holding %s for a material of its own.'):format(
        planned, planned == 1 and 'it' or 'them'))
end
if #failed > 0 then
    print(('  %d FAILED:'):format(#failed))
    for _, f in ipairs(failed) do print('    ' .. f) end
end
end

-- ---------------------------------------------------------------------------
-- the notification: "these are deadlocked"
-- ---------------------------------------------------------------------------
--
-- A deadlocked wall is invisible. It looks exactly like a wall waiting its turn -- planned, with
-- a block beside it -- and the fort keeps working around it, so nobody looks until a corridor
-- has been open to the caverns for a season. This puts the count in DFHack's notification panel
-- and names the command that fixes it, and a click walks you to the tiles.
local NOTIFY_NAME = 'construction_deadlock'
local CACHE_MS = 3000        -- buildings.all is over a thousand entries; do not walk it per frame
local cache = {ms = -CACHE_MS, list = {}}
local zoom_cursor = 0

local function stuck_cached()
    local now = dfhack.getTickCount()
    if now - cache.ms >= CACHE_MS then
        cache.ms = now
        cache.list = dfhack.isMapLoaded() and stuck_constructions() or {}
    end
    return cache.list
end

function deadlock_message()
    local n = #stuck_cached()
    if n == 0 then return nil end
    return ('%d construction%s deadlocked -- run fort/rewall'):format(n, n == 1 and '' or 's')
end

local function zoom_to_stuck()
    local list = stuck_cached()
    if #list == 0 then return end
    zoom_cursor = zoom_cursor % #list + 1
    local pos = list[zoom_cursor]
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(pos.x, pos.y, pos.z), true, true)
end

local function register_notification()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok or not n then return end
    local entry = n.NOTIFICATIONS_BY_NAME[NOTIFY_NAME]
    if not entry then
        entry = {name = NOTIFY_NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NOTIFY_NAME] = entry
    end
    entry.desc = 'Warns when planned constructions are deadlocked -- suspended with their '
        .. 'material already hauled to the site. Click to step through them; fort/rewall fixes them.'
    entry.dwarf_fn = deadlock_message
    entry.on_click = zoom_to_stuck
    if n.config and n.config.data and not n.config.data[NOTIFY_NAME] then
        n.config.data[NOTIFY_NAME] = {enabled = true, version = 1}
    end
end

dfhack.onStateChange[NOTIFY_NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register_notification() end
end

register_notification()

if dfhack_flags and dfhack_flags.module then return end

-- `fort/rewall register` loads the warning and redraws NOTHING. The warning is only worth
-- anything before you have thought to run the tool, so it has to be loadable at startup --
-- and running the tool itself at startup would redraw every designation in the fort.
local first = ({...})[1]
if first == 'register' then
    print('fort/rewall: "construction_deadlock" registered -- '
        .. 'DFHack will warn when planned constructions are deadlocked.')
    print('Add `fort/rewall register` to dfhack-config/init/dfhack.init to load it every session.')
    return
end

run(...)
