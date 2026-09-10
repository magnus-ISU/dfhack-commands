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
for when breaking the tangle matters more than the stone, and `--material` (with `--item` for the
form) overrides both -- for when the material a wall is carrying is itself the mistake.

    fort/rewall                 redraw every planned construction
    fort/rewall -n              report what it would redraw, change nothing
    fort/rewall --suspended     only the suspended ones -- the deadlocked ones
    fort/rewall --any-material  let the new jobs take whatever is nearest, choice and all
    fort/rewall --no-clear      leave items lying on the building sites where they are
    fort/rewall --material INORGANIC:CONGLOMERATE [--item BLOCKS]
                                redraw everything asking for THAT instead of what it had
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
  deadlocked -- run fort/rewall" -- and it counts ONE shape: a suspended construction with an
  item on its tile that ANOTHER construction job has claimed. That tile cannot be built while
  the item sits on it, and the item cannot be hauled while a job holds it, so nothing in the
  fort ever undoes it. A wall suspended because another wall goes first is NOT counted: that is
  the fort working, and a warning that fires every season is one you stop reading. Clicking the
  line walks you through the tiles. `magnus-scripts` turns it on.

WHAT IT COSTS

  Any material already hauled to the site is released. That is the point -- the reservation is
  the deadlock -- but it does mean the block goes back to being loose stock for a moment, and
  a hauler may carry it somewhere else before the new job claims it. The wall is not lost,
  only the trip.

  Priorities set per designation are DF's own and ride on the building, so they go with it.
]]

local buildingplan = require('plugins.buildingplan')

local dry, verbose, suspended_only, any_material, no_clear = false, false, false, false, false
local forced_mat, forced_item = nil, nil     -- --material / --item

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
--
-- `--material` / `--item` OVERRIDE BOTH the pin and the old filter, which is what you want when
-- the material a wall is carrying is itself the mistake: a fort that decided on conglomerate
-- blocks should not keep rebuilding the sandstone somebody's earlier pass left behind.
local function filters_for(job)
    if forced_mat or forced_item then
        local one = {flags2 = {building_material = true}}
        if forced_mat then one.mat_type, one.mat_index = forced_mat.type, forced_mat.index end
        if forced_item then one.item_type, one.item_subtype = forced_item, -1 end
        local name = forced_mat and forced_mat:toString() or nil
        if forced_item then
            name = ('%s %s'):format(name or 'any', (df.item_type[forced_item] or ''):lower())
        end
        return {one}, name
    end
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
local function redraw(pos, ctype, filters, item)
    local args = {type = df.building_type.Construction, subtype = ctype, pos = pos}
    -- an explicit item beats a filter: DF attaches it at creation, so the job starts with its
    -- material in hand rather than going shopping for one
    if item then args.items = {item} else args.filters = filters end
    local ok, bld = pcall(dfhack.buildings.constructBuilding, args)
    if not ok or not bld then
        if item then       -- that item would not take; fall back to the filter
            args.items, args.filters = nil, filters
            ok, bld = pcall(dfhack.buildings.constructBuilding, args)
        end
    end
    if ok and bld then return true end
    -- last resort, so a removed designation is never simply lost
    if dfhack.constructions.designateNew(pos, ctype, -1, -1) then return true, 'filter reset' end
    return false
end

-- ---- reachability, site clutter, and picking a block that is already there ----
--
-- WHY A REDRAWN WALL GETS STUCK AGAIN. A construction cannot be built while there are loose
-- items on its tile, and an item only leaves a tile if a hauler has somewhere to take it. A fort
-- with no stockpile that accepts stone, blocks or bars has nowhere -- so the blocks dropped along
-- a wall line sit exactly where the wall goes, forever, and every redraw hands the job back the
-- same blocked tile. Measured here: 16 of 42 planned constructions blocked that way, tiles
-- carrying up to five loose items each.
--
-- Two answers, and this does both:
--
--   * BUILD OUT OF WHAT IS ALREADY THERE. If a loose item on the tile is the material the job
--     wants, that item becomes the job's material outright -- attached at creation rather than
--     left for DF to choose. The job starts unsuspended with nothing to fetch, and the tile
--     loses a blocker instead of gaining one. (Measured: a blocked site redrawn this way came
--     back "not suspended", one item attached, no hauling trip at all.)
--   * MOVE THE REST OUT OF THE WAY. Whatever is left on the tile is put down on the nearest
--     reachable tile that is not itself a building site -- one hauler's worth of work that no
--     hauler will ever be given, because there is no stockpile to give it to. `--no-clear`
--     leaves them where they are.
--
-- And a site NOBODY CAN REACH is not redrawn at all -- a pocket sealed by walls already built,
-- or a floor designated out over open air with nothing to build it from. No material and no
-- ordering fixes either, and naming them beats churning them on every run.
local NEIGHBOURS8 = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}}
local CLUTTER_RADIUS = 12       -- how far to look for somewhere to put what is in the way

local function fort_groups()
    local groups = {}
    for _, unit in ipairs(dfhack.units.getCitizens(true)) do
        local g = dfhack.maps.getWalkableGroup(unit.pos)
        if g and g ~= 0 then groups[g] = true end
    end
    return groups
end

local function reachable(groups, pos)
    if not next(groups) then return true end        -- nobody to judge by: allow
    if groups[dfhack.maps.getWalkableGroup(pos)] then return true end
    for _, d in ipairs(NEIGHBOURS8) do
        if groups[dfhack.maps.getWalkableGroup({x = pos.x + d[1], y = pos.y + d[2], z = pos.z})] then
            return true
        end
    end
    return false
end

-- loose items lying on a tile: on the ground, nobody's job, not forbidden, not an artifact
local function loose_items_on(pos)
    local out = {}
    local block = dfhack.maps.getTileBlock(pos)
    if not block then return out end
    for _, id in ipairs(block.items) do
        local item = df.item.find(id)
        if item and item.flags.on_ground and not item.flags.in_job and not item.flags.forbid
                and not item.flags.artifact
                and item.pos.x == pos.x and item.pos.y == pos.y and item.pos.z == pos.z then
            out[#out + 1] = item
        end
    end
    return out
end

local function item_matches(item, filters)
    for _, f in ipairs(filters or {}) do
        local ok = true
        if (f.item_type or -1) ~= -1 and item:getType() ~= f.item_type then ok = false end
        if ok and (f.item_subtype or -1) ~= -1 and item:getSubtype() ~= f.item_subtype then ok = false end
        if ok and (f.mat_type or -1) ~= -1 then
            if item:getMaterial() ~= f.mat_type then ok = false
            elseif (f.mat_index or -1) ~= -1 and item:getMaterialIndex() ~= f.mat_index then ok = false end
        end
        if ok then return true end
    end
    return false
end

-- somewhere to put what is in the way: the nearest reachable tile that is not a building site
local function clutter_destination(groups, from)
    local seen, queue, head = {[('%d,%d'):format(from.x, from.y)] = true}, {{from.x, from.y, 0}}, 1
    while head <= #queue do
        local t = queue[head]
        head = head + 1
        if t[3] > 0 then
            local pos = {x = t[1], y = t[2], z = from.z}
            if groups[dfhack.maps.getWalkableGroup(pos)] and not dfhack.buildings.findAtTile(pos) then
                return pos
            end
        end
        if t[3] < CLUTTER_RADIUS then
            for _, d in ipairs(NEIGHBOURS8) do
                local x, y = t[1] + d[1], t[2] + d[2]
                local k = ('%d,%d'):format(x, y)
                if not seen[k] then
                    seen[k] = true
                    -- walk only over tiles a dwarf could walk, so the drop is somewhere real
                    if groups[dfhack.maps.getWalkableGroup({x = x, y = y, z = from.z})] then
                        queue[#queue + 1] = {x, y, t[3] + 1}
                    end
                end
            end
        end
    end
end

-- ---- the deadlock, as a question anything can ask ---------------------------
--
-- THE WARNING IS FOR ONE SHAPE ONLY, and it is narrow on purpose.
--
-- A suspended construction is not news. Most of them are suspendmanager sequencing walls that
-- would block each other, which resolves itself as the neighbours go up -- 28 of this fort's 44
-- suspensions were exactly that. Warning about those is warning about the fort working, and a
-- warning that fires every season is one you stop reading.
--
-- The shape worth waking somebody for is the one nothing in the fort will ever undo: a loose item
-- on the construction's tile that ANOTHER construction job has claimed. The tile cannot be built
-- while the item sits on it, the item cannot be hauled off while a job holds it, and the job
-- holding it is usually blocked in its own turn. No hauler, no stockpile and no amount of waiting
-- clears that; releasing the claim does, which is what this tool is for.
--
-- Items with NO claim on them are a different problem with a different answer -- a stockpile that
-- accepts them, or the redraw's own site clearing -- and they are handled quietly.
local function construction_job_claims()
    local claims = {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and job.job_type == df.job_type.ConstructBuilding then
            for _, ji in ipairs(job.items) do
                if ji.item then claims[ji.item.id] = job.id end
            end
        end
        link = link.next
    end
    return claims
end

function stuck_constructions()
    local out = {}
    local claims = construction_job_claims()
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bld:getType() == df.building_type.Construction and bld.construction_stage == 0
                and not buildingplan.isPlannedBuilding(bld) then
            local job = bld.jobs[0]
            if job and job.flags.suspend and not dfhack.job.getWorker(job) then
                local pos = {x = bld.x1, y = bld.y1, z = bld.z}
                local block = dfhack.maps.getTileBlock(pos)
                for _, id in ipairs(block and block.items or {}) do
                    local item = df.item.find(id)
                    if item and item.flags.on_ground and item.flags.in_job
                            and item.pos.x == pos.x and item.pos.y == pos.y and item.pos.z == pos.z
                            and claims[id] and claims[id] ~= job.id then
                        out[#out + 1] = pos
                        break
                    end
                end
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
    dry, verbose, suspended_only, any_material, no_clear = false, false, false, false, false
    forced_mat, forced_item = nil, nil
    local args, i = {...}, 1
    while i <= #args do
        local a = args[i]
        if a == '-n' or a == '--dry-run' then dry = true
        elseif a == '-v' or a == '--verbose' then verbose = true
        elseif a == '--suspended' then suspended_only = true
        elseif a == '--any-material' then any_material = true
        elseif a == '--no-clear' then no_clear = true
        elseif a == '--material' then
            i = i + 1
            local token = args[i] or qerror('--material needs a material token, e.g. INORGANIC:CONGLOMERATE')
            forced_mat = dfhack.matinfo.find(token)
                or qerror('no such material: ' .. token)
        elseif a == '--item' then
            i = i + 1
            local name = (args[i] or ''):upper()
            forced_item = df.item_type[name]
            if not forced_item then qerror('no such item type: ' .. tostring(args[i])) end
        else qerror('unknown argument: ' .. a) end
        i = i + 1
    end
    if not dfhack.isMapLoaded() then qerror('fort/rewall needs a loaded fort') end

local targets, working, part_built, planned, sealed = {}, 0, 0, 0, {}
    local groups = fort_groups()

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
                local pos = {x = bld.x1, y = bld.y1, z = bld.z}
                if not reachable(groups, pos) then
                    -- nobody can stand on it or beside it: a pocket sealed by walls already
                    -- built, or a floor designated out over open air with nothing to build it
                    -- from. No material and no ordering fixes either.
                    sealed[#sealed + 1] = ('%s at %d,%d,%d'):format(
                        df.construction_type[bld.type] or '?', pos.x, pos.y, pos.z)
                    goto continue
                end
                local filters, material = filters_for(job)
                targets[#targets + 1] = {
                    pos = {x = bld.x1, y = bld.y1, z = bld.z},
                    ctype = bld.type,
                    suspended = job and job.flags.suspend or false,
                    held = job and #job.items or 0,
                    filters = filters,
                    material = material,
                }
                ::continue::
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

local redrawn, failed, freed, from_site, cleared = 0, {}, 0, 0, 0

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
            -- Build out of what is lying there, if what is lying there is what the job wants:
            -- the tile loses a blocker instead of gaining one, and nothing has to be fetched.
            local on_site = nil
            for _, item in ipairs(loose_items_on(t.pos)) do
                if item_matches(item, t.filters) then on_site = item break end
            end
            local ok, note = redraw(t.pos, t.ctype, t.filters, on_site)
            if ok and on_site then from_site = from_site + 1 end
            -- and move whatever else is in the way somewhere a wall is not going
            if ok and not no_clear then
                for _, item in ipairs(loose_items_on(t.pos)) do
                    local dest = clutter_destination(groups, t.pos)
                    if dest and dfhack.items.moveToGround(item, dest) then
                        cleared = cleared + 1
                    end
                end
            end
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
    if pinned > 0 and (forced_mat or forced_item) then
        act('  %d %s redrawn asking for %s.', pinned, pinned == 1 and 'was' or 'were',
            targets[1] and targets[1].material or 'the material you named')
    elseif pinned > 0 then
        act('  %d %s redrawn asking for the same material again.', pinned,
            pinned == 1 and 'was' or 'were')
    elseif any_material then
        act('  --any-material: the new jobs will take whatever is nearest.')
    end
end
if from_site > 0 then
    act('  %d built out of a block already lying on the site -- nothing to fetch.', from_site)
end
if cleared > 0 then
    act('  %d item%s moved off a building site; nothing else was ever going to move %s.',
        cleared, cleared == 1 and '' or 's', cleared == 1 and 'it' or 'them')
end
if working > 0 then
    print(('  %d left alone: a dwarf is building %s right now.'):format(
        working, working == 1 and 'it' or 'them'))
end
if #sealed > 0 then
    print(('  %d unreachable -- nothing can stand on or beside %s, so no redraw helps:'):format(
        #sealed, #sealed == 1 and 'it' or 'them'))
    for i, w in ipairs(sealed) do
        if i <= 5 then print('    ' .. w) end
    end
    if #sealed > 5 then print(('    ... and %d more'):format(#sealed - 5)) end
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
    entry.desc = 'Warns when a planned construction is deadlocked: an item on its tile is '
        .. 'claimed by another construction job, so nothing will ever move it. Click to step '
        .. 'through them; fort/rewall releases the claims.'
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
