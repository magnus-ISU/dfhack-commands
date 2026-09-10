-- Redraw every planned construction, to shake loose the ones deadlocked on a reserved item.
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
that for every planned construction in the fort, and puts back exactly what it took away:
the same construction type on the same tile, with the same item filter -- the item type,
subtype and material the designation was drawn with, so a wall you specified in green glass
stays a wall in green glass.

    fort/rewall                 redraw every planned construction
    fort/rewall -n              report what it would redraw, change nothing
    fort/rewall --suspended     only the suspended ones -- the deadlocked ones
    fort/rewall -v              name every construction touched

WHAT IT WILL NOT TOUCH

  * Anything a dwarf is actually building. A construction whose job has a worker is left
    alone: that one is not stuck, and taking a job out from under the dwarf holding it is
    how this repo has crashed DF before.
  * Anything already part-built (`construction_stage` above 0). Only designations that have
    never been started are redrawn -- a half-built wall is progress, not a deadlock.

WHAT IT COSTS

  Any material already hauled to the site is released. That is the point -- the reservation is
  the deadlock -- but it does mean the block goes back to being loose stock for a moment, and
  a hauler may carry it somewhere else before the new job claims it. The wall is not lost,
  only the trip.

  Priorities set per designation are DF's own and ride on the building, so they go with it.
]]

local args = {...}
local dry, verbose, suspended_only = false, false, false
for _, a in ipairs(args) do
    if a == '-n' or a == '--dry-run' then dry = true
    elseif a == '-v' or a == '--verbose' then verbose = true
    elseif a == '--suspended' then suspended_only = true
    else qerror('unknown argument: ' .. a) end
end

if not dfhack.isMapLoaded() then qerror('fort/rewall needs a loaded fort') end

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

-- ---- collect first, act afterwards -------------------------------------------
--
-- Redrawing a designation adds and removes entries in world.buildings.all, so the list is
-- snapshotted before a single one is touched.
local targets, working, part_built = {}, 0, 0

for _, bld in ipairs(df.global.world.buildings.all) do
    if bld:getType() == df.building_type.Construction then
        if bld.construction_stage > 0 then
            part_built = part_built + 1
        else
            local job = bld.jobs[0]
            if job and dfhack.job.getWorker(job) then
                working = working + 1
            elseif not (suspended_only and not (job and job.flags.suspend)) then
                targets[#targets + 1] = {
                    pos = {x = bld.x1, y = bld.y1, z = bld.z},
                    ctype = bld.type,
                    suspended = job and job.flags.suspend or false,
                    held = job and #job.items or 0,
                    filters = snapshot_filters(job),
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
            t.held > 0 and (', %d item held'):format(t.held) or '')
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
    act('  %d had a material already hauled to the site; that claim is released.', freed)
end
if working > 0 then
    print(('  %d left alone: a dwarf is building %s right now.'):format(
        working, working == 1 and 'it' or 'them'))
end
if part_built > 0 then
    print(('  %d left alone: already part-built.'):format(part_built))
end
if #failed > 0 then
    print(('  %d FAILED:'):format(#failed))
    for _, f in ipairs(failed) do print('    ' .. f) end
end
