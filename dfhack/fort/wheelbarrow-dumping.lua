-- Dumping uses real wheelbarrows, several items a trip; other heavy hand-hauls go at barrow pace.
--@module = true
--@enable = true
--[[
fort/wheelbarrow-dumping

Vanilla uses a wheelbarrow for one thing: hauling to a stockpile that has one assigned.
Everything else heavy is carried by hand -- a boulder being dumped, a boulder fetched to
the smelter as flux, a block walked to a construction site, a stone bound for a pile with
no barrows -- and a 240-weight stone slows an ordinary dwarf to a quarter of walking pace,
so a designation of forty boulders becomes forty dwarves crawling across the fort for a
season, one stone each. Wheelbarrows exist to fix exactly this, and DF only reaches for
them on that one job. This is a house rule that reaches for them everywhere, two ways:

**1. DUMP JOBS GET A REAL WHEELBARROW, AND CARRY SEVERAL ITEMS A TRIP.** The moment DF
posts a dump job -- before any dwarf has claimed it -- the job is turned into the one kind
of job DF does push a barrow for: a stockpile haul, with the dump tile as its destination
and a free wheelbarrow attached as its vehicle. No stockpile is involved; the job only
needs a place to go. Up to ten more items marked for dumping within ten tiles of the
first are loaded into the same job, so a pile of designated rubble goes in one trip
instead of one dwarf per stone. The dwarf fetches the barrow, loads everything, pushes it
to the dump, and when the job completes each delivered item is forbidden and un-marked
exactly as DF's own dump does. (Tachytaenius' `wheelbarrow-dump` for 0.47 is the origin
of the job retype; the multi-item loading is the idea of Loire's *Multi-Hauling*.)

  * It happens when the job is worth a barrow: the item is over 75 (vanilla's own line
    for when a stockpile haul gets one) OR there is at least one more marked item to
    take along. A lone sock is dumped by hand as before.
  * Only an UNASSIGNED wheelbarrow is used -- one not belonging to any stockpile -- and
    only one a dwarf can walk to from the item. DF claims it for the job, so nobody
    shares it, and it is parked on the dump tile afterwards, where the next dump run
    finds it. Make a couple of spare barrows and leave them loose.
  * A dump zone over open space -- the ledge you throw things off, the magma pit -- is
    left to vanilla: a stockpile haul puts the item DOWN on the destination tile rather
    than over the edge, so those dumps keep their by-hand throw.
  * An item already lying on the dump tile is left to vanilla too (that job is a
    formality, not a haul).

**2. EVERY OTHER HEAVY HAND-HAUL GOES AT BARROW PACE, BY PRETENDING.** For any fort worker
carrying a job item by hand that weighs over 75 -- a smelter's flux, a building's block,
a stone bound for a barrowless pile, a dump that could not get a barrow -- while a free
wheelbarrow exists anywhere on the map, the item weighs nothing for the rest of the trip,
so the dwarf walks at full speed exactly as if pushing it. That barrow is spoken for until
the item is put down (the count of idle barrows is the count of such hauls at once, and
one is never lent to two people), and the item gets its real weight back the moment it
leaves the carrier's hands. Nothing is written to the barrow. DF's dump job and the rest
have no vehicle step to hook -- a barrow attached to them is dropped at pickup, tested --
which is why this half is pretended and the dump half is retyped.

    enable fort/wheelbarrow-dumping    turn it on for this fort (saved with the fort)
    disable fort/wheelbarrow-dumping   stop; anything mid-haul gets its weight back now
                                       (barrow runs already under way finish as they are)
    fort/wheelbarrow-dumping           status: barrow runs and pretend-hauls in progress

**This is a house rule.** Lives in the *house rules* column of `fort/magnus-scripts`: off
until you turn it on, untouched by the `[r]` / `[m]` master switches. No options: the 75
line is vanilla's, ten items and ten tiles are Multi-Hauling's defaults.

**How the pretending works.** DF caches an item's weight on the item (`item.weight`) and
weighs it lazily: a boulder nobody has touched sits at 0 until the first pickup, and
after that DF reads the cache -- it does not re-weigh mid-carry, and the carried weight
is what sets the dwarf's pace (measured: 37 ticks/tile at 240, 8-11 ticks/tile at 1, on
the same dwarf, mid-haul). So the cached weight is set to 1 at pickup and the real number
written back when the item leaves the inventory. A haul is spotted from the carrier's
side: every fort worker with a job, every item in their hands (inventory mode Hauled)
that belongs to that job and weighs over the line. A boulder riding in a real wheelbarrow
is inside the barrow, not in the hands, so barrow runs are never touched. Both kinds of
haul are tracked in the fort's saved data, so a save made mid-haul is put right on load.
]]

local eventful = require('plugins.eventful')
local utils = require('utils')

local GLOBAL_KEY = 'wheelbarrow-dumping'

-- vanilla's wheelbarrow line: a stockpile haul gets a barrow when the item is heavier
-- than 75. Same rule here, for both halves.
local HEAVY = 75
-- the weight a pretend-barrowed item shows while carried. Not 0: 0 is DF's "not weighed
-- yet" value and would invite a re-weigh at the next pickup-like moment.
local LIGHT = 1
-- how many more marked items a barrow run takes along, and from how far around the
-- first one. Multi-Hauling's defaults; DF never balked at a barrow holding ten.
local MAX_EXTRA = 10
local RADIUS = 10

-- rendered frames between pretend sweeps. A pickup is only missed for as long as one
-- gap, and a dwarf covers a tile or two in that time; per sweep this walks units.active.
local BEAT_FRAMES = 10

-- unit_inventory_item.mode: 0 = Hauled (in the hands for a job), 2 = Worn. The enum is
-- not exposed to Lua on this build, so the number is spelled out.
local MODE_HAULED = 0

enabled = enabled or false

-- PRETEND HAULS: item id -> {whole, fraction, wb = wheelbarrow id}, everything lightened.
tracked = tracked or {}
-- BARROW RUNS: job id -> {pos = {x,y,z}}, every dump job retyped and not yet finished.
runs = runs or {}
-- lifetime counters for the status line
stats = stats or {runs = 0, items = 0}

local function persist()
    local rows = {}
    for id, t in pairs(tracked) do
        rows[#rows + 1] = {id = id, whole = t.whole, fraction = t.fraction, wb = t.wb}
    end
    local jobs = {}
    for id, r in pairs(runs) do jobs[#jobs + 1] = {id = id, pos = r.pos} end
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY,
          {enabled = enabled, tracked = rows, runs = jobs, stats = stats})
end

local function is_heavy(item)
    local w = item.weight
    return w.whole > HEAVY or (w.whole == HEAVY and w.fraction > 0)
end

local function item_pos(item)
    local x, y, z = dfhack.items.getPosition(item)
    return x and xyz2pos(x, y, z) or nil
end

-- ---------------------------------------------------------------------------
-- 1. dump jobs: a real barrow, several items a trip
-- ---------------------------------------------------------------------------

-- a wheelbarrow DF itself would let a job claim: on the ground, no job on it, not
-- forbidden, and NOT assigned to any stockpile (that pile's own hauls own it); and one
-- the dwarf can actually reach from the item
local function claimable_wheelbarrow(from)
    for _, it in ipairs(df.global.world.items.other.TOOL) do
        local f = it.flags
        if it:isWheelbarrow() and it.stockpile.id == -1 and f.on_ground
                and not f.in_job and not f.forbid and not f.in_inventory
                and not f.garbage_collect and dfhack.maps.canWalkBetween(from, it.pos) then
            return it
        end
    end
    return nil
end

-- the tile a retyped job would put its load DOWN on has to be one you can put a thing
-- down on: a zone over open space (a ledge, a pit) is a throw, and stays vanilla
local function can_set_down(pos)
    local tt = dfhack.maps.getTileType(pos)
    if not tt then return false end
    local shape = df.tiletype.attrs[tt].shape
    return shape ~= df.tiletype_shape.EMPTY and shape ~= df.tiletype_shape.RAMP_TOP
end

-- other items marked for dumping near `first`, on the ground and unclaimed, reachable
-- from it, not already on the dump tile: the rest of the load. Walks the map blocks
-- under a RADIUS square, which is a handful of blocks.
local function nearby_marked(first, dest)
    local out = {}
    local p = first.pos
    local bx0, bx1 = (p.x - RADIUS) // 16, (p.x + RADIUS) // 16
    local by0, by1 = (p.y - RADIUS) // 16, (p.y + RADIUS) // 16
    for by = by0, by1 do
        for bx = bx0, bx1 do
            local block = dfhack.maps.getTileBlock(bx * 16, by * 16, p.z)
            if block then
                for _, id in ipairs(block.items) do
                    local o = df.item.find(id)
                    if o and o ~= first and o.flags.dump and o.flags.on_ground
                            and not o.flags.in_job and not o.flags.forbid
                            and not o:isWheelbarrow() and not dfhack.items.isRouteVehicle(o)
                            and math.abs(o.pos.x - p.x) <= RADIUS and math.abs(o.pos.y - p.y) <= RADIUS
                            and not same_xyz(o.pos, dest)
                            and dfhack.maps.canWalkBetween(p, o.pos) then
                        out[#out + 1] = o
                        if #out >= MAX_EXTRA then return out end
                    end
                end
            end
        end
    end
    return out
end

-- Turn a fresh, unclaimed dump job into a stockpile haul with a barrow. Everything DF
-- needs is already on the job: its destination (job.pos, the dump tile) and its item.
-- The retype is what makes DF run its vehicle step -- fetch the barrow, load, push --
-- and the labor field tells it who may take the job (StoreItemInStockpile reads
-- item_subtype as a unit_labor). Origin: Tachytaenius' wheelbarrow-dump (0.47).
local function convert(job)
    if job.job_type ~= df.job_type.DumpItem or runs[job.id] then return end
    if dfhack.job.getWorker(job) then return end       -- claimed: too late to retype
    local ji = job.items[0]
    local item = ji and ji.item
    if not item or not item.flags.dump or not item.flags.on_ground then return end
    if same_xyz(item.pos, job.pos) then return end     -- already on the dump tile
    if not can_set_down(job.pos) then return end
    local wb = claimable_wheelbarrow(item.pos)
    if not wb then return end
    local extra = nearby_marked(item, job.pos)
    -- a lone light item is not worth the walk to fetch the barrow. The weight cache
    -- reads 0 on an item nobody has lifted yet, which is most of what gets dumped, so
    -- a boulder counts as heavy by kind -- there is no light boulder -- and anything
    -- else by its cached weight.
    if #extra == 0 and not (item:getType() == df.item_type.BOULDER or is_heavy(item)) then
        return
    end
    for _, o in ipairs(extra) do
        dfhack.job.attachJobItem(job, o, df.job_role_type.Hauled, -1, -1)
    end
    if not dfhack.job.attachJobItem(job, wb, df.job_role_type.PushHaulVehicle, -1, -1) then
        return       -- extras stay on the plain dump job; DF releases them at pickup
    end
    job.job_type = df.job_type.StoreItemInStockpile
    job.item_subtype = df.unit_labor.HAUL_REFUSE
    runs[job.id] = {pos = {x = job.pos.x, y = job.pos.y, z = job.pos.z}}
    stats.runs = stats.runs + 1
    stats.items = stats.items + 1 + #extra
    persist()
end

-- The retyped job is over: everything it put down on the dump tile is forbidden and
-- un-marked, exactly as DF's own dump does. What is not on the tile (a cancelled run)
-- keeps its mark and gets dumped another day. This runs from JOB_COMPLETED, in the
-- same tick the job ends, so DF cannot post a fresh dump job for a delivered item
-- in between.
local function finish(job)
    local r = runs[job.id]
    if not r then return end
    for _, ji in ipairs(job.items) do
        local o = ji.item
        if o and ji.role == df.job_role_type.Hauled then
            local p = item_pos(o)
            if p and p.x == r.pos.x and p.y == r.pos.y and p.z == r.pos.z then
                o.flags.forbid = true
                o.flags.dump = false
            end
        end
    end
    runs[job.id] = nil
    persist()
end

-- a run whose job vanished without the event (a reload in between, say): sweep the tile
local function reconcile_runs()
    local live = {}
    for _, job in utils.listpairs(df.global.world.jobs.list) do live[job.id] = true end
    local changed = false
    for id, r in pairs(runs) do
        if not live[id] then
            local block = dfhack.maps.getTileBlock(r.pos.x, r.pos.y, r.pos.z)
            if block then
                for _, iid in ipairs(block.items) do
                    local o = df.item.find(iid)
                    if o and o.flags.dump and o.flags.on_ground and not o.flags.in_job
                            and o.pos.x == r.pos.x and o.pos.y == r.pos.y then
                        o.flags.forbid = true
                        o.flags.dump = false
                    end
                end
            end
            runs[id] = nil
            changed = true
        end
    end
    if changed then persist() end
end

-- ---------------------------------------------------------------------------
-- 2. other hand-hauls: pretend
-- ---------------------------------------------------------------------------

-- a wheelbarrow nobody is using: no job on it, not carried, not forbidden, not
-- already spoken for by one of our own pretend hauls. Stockpile-assigned barrows count
-- while idle, as vanilla lets any pile borrow them between hauls.
local function wheelbarrow_free(wb, reserved)
    local f = wb.flags
    return not f.in_job and not f.in_inventory and not f.forbid and not f.garbage_collect
        and not reserved[wb.id]
end

-- any free wheelbarrow on the map, or nil. Distance is deliberately not a factor: a
-- fort keeps its barrows at a stone pile or a tool stockpile, rarely near whatever is
-- being carried. items.other.TOOL is every tool on the map, a fine size for a scan.
local function free_wheelbarrow(reserved)
    for _, it in ipairs(df.global.world.items.other.TOOL) do
        if it:isWheelbarrow() and wheelbarrow_free(it, reserved) then return it end
    end
    return nil
end

-- Every heavy item currently in a fort worker's hands for their job: item id -> item.
-- units.active is the bounded list (hundreds); a worker's inventory is a dozen entries.
-- The job link is the item's in_job flag: a hauled item that is nobody's job is a
-- dwarf carrying their own property, not a haul.
local function carried_heavy()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if u.job.current_job and dfhack.units.isFortControlled(u)
                and dfhack.units.isAlive(u) then
            for _, e in ipairs(u.inventory) do
                local item = e.item
                if e.mode == MODE_HAULED and item.flags.in_job and not item:isWheelbarrow()
                        and (tracked[item.id] or is_heavy(item)) then
                    out[item.id] = item
                end
            end
        end
    end
    return out
end

local function lighten(item, wb)
    tracked[item.id] = {whole = item.weight.whole, fraction = item.weight.fraction, wb = wb.id}
    item.weight.whole, item.weight.fraction = LIGHT, 0
end

-- put the real weight back. A missing item (dumped into magma, atom-smashed) just
-- drops out of the table.
local function restore(id)
    local t = tracked[id]
    if not t then return end
    local item = df.item.find(id)
    if item then item.weight.whole, item.weight.fraction = t.whole, t.fraction end
    tracked[id] = nil
end

-- one sweep: release what is no longer carried, lighten what just got picked up
local function sweep()
    local changed = false
    -- release first, so a barrow freed this sweep is handy for a pickup this sweep
    local still = carried_heavy()
    for id in pairs(tracked) do
        if not still[id] then restore(id) changed = true end
    end
    local reserved = {}
    for _, t in pairs(tracked) do reserved[t.wb] = true end
    for id, item in pairs(still) do
        if not tracked[id] then
            local wb = free_wheelbarrow(reserved)
            if wb then
                lighten(item, wb)
                reserved[wb.id] = true
                changed = true
            end
        end
    end
    if changed then persist() end
    reconcile_runs()
end

local function restore_all()
    for id in pairs(tracked) do restore(id) end
    persist()
end

-- ---------------------------------------------------------------------------
-- the service
-- ---------------------------------------------------------------------------

-- generation guard: a reqscript reload builds fresh locals, so the running heartbeat
-- closure must be told to stop through something that survives the reload
local function hb_gen(set)
    if set ~= nil then dfhack.internal.wheelbarrow_dumping_hb_gen = set end
    return dfhack.internal.wheelbarrow_dumping_hb_gen or 0
end

function isEnabled() return enabled end

local function start()
    enabled = true
    -- the retype has to land before a dwarf claims the job, and dump jobs are claimed
    -- within ticks of being posted: the per-tick event is the only thing fast enough
    eventful.enableEvent(eventful.eventType.JOB_INITIATED, 1)
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 0)
    eventful.onJobInitiated[GLOBAL_KEY] = function(job) pcall(convert, job) end
    eventful.onJobCompleted[GLOBAL_KEY] = function(job) pcall(finish, job) end
    local my_gen = hb_gen() + 1
    hb_gen(my_gen)
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen() then return end
        if dfhack.world.isFortressMode() then pcall(sweep) end
        dfhack.timeout(BEAT_FRAMES, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen(hb_gen() + 1)
    eventful.onJobInitiated[GLOBAL_KEY] = nil
    -- runs already under way are DF's jobs now and finish on their own; the completion
    -- hook stays so their items are still forbidden and un-marked when they land
    restore_all()
end

function set_enabled(on)
    if on then start() else stop() end
    persist()
    return enabled
end

local function load_persisted()
    local data = dfhack.persistent.getSiteData(GLOBAL_KEY)
    tracked, runs = {}, {}
    if not data then return false end
    for _, row in ipairs(data.tracked or {}) do
        tracked[row.id] = {whole = row.whole, fraction = row.fraction, wb = row.wb}
    end
    for _, row in ipairs(data.runs or {}) do runs[row.id] = {pos = row.pos} end
    stats = data.stats or {runs = 0, items = 0}
    -- items lightened when the fort was last saved get their weight back before
    -- anything else happens; a live haul is re-lightened by the first sweep anyway
    restore_all()
    return data.enabled == true
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode() and load_persisted() then start() end
    elseif sc == SC_MAP_UNLOADED then
        enabled = false
        hb_gen(hb_gen() + 1)
        eventful.onJobInitiated[GLOBAL_KEY] = nil
        eventful.onJobCompleted[GLOBAL_KEY] = nil
        tracked, runs = {}, {}
    end
end

if dfhack_flags.module then return end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if not dfhack.world.isFortressMode() then
    qerror('wheelbarrow-dumping only works in fortress mode')
end

if dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print(('wheelbarrow-dumping: %s'):format(enabled and
        'ON -- dumps go by wheelbarrow, other heavy hauls at barrow pace' or 'OFF'))
    return
end

-- status
local free, loose, total = 0, 0, 0
local reserved = {}
for _, t in pairs(tracked) do reserved[t.wb] = true end
for _, it in ipairs(df.global.world.items.other.TOOL) do
    if it:isWheelbarrow() then
        total = total + 1
        if wheelbarrow_free(it, reserved) then free = free + 1 end
        if it.stockpile.id == -1 and not it.flags.in_job and not it.flags.forbid then loose = loose + 1 end
    end
end
print(('wheelbarrow-dumping is %s; %d wheelbarrow%s on the map, %d free, %d loose (unassigned) for dump runs')
    :format(enabled and 'ON' or 'OFF', total, total == 1 and '' or 's', free, loose))
print(('  %d barrow run%s so far, %d item%s delivered by barrow')
    :format(stats.runs, stats.runs == 1 and '' or 's', stats.items, stats.items == 1 and '' or 's'))
local n = 0
for id, r in pairs(runs) do
    n = n + 1
    local job
    for _, j in utils.listpairs(df.global.world.jobs.list) do if j.id == id then job = j break end end
    if job then
        local w = dfhack.job.getWorker(job)
        local loads = 0
        for _, ji in ipairs(job.items) do if ji.role == df.job_role_type.Hauled then loads = loads + 1 end end
        print(('  barrow run: %d item%s to %d,%d,%d -- %s'):format(loads, loads == 1 and '' or 's',
            r.pos.x, r.pos.y, r.pos.z, w and dfhack.units.getReadableName(w) or 'unclaimed'))
    end
end
for id, t in pairs(tracked) do
    n = n + 1
    local item = df.item.find(id)
    print(('  by hand at barrow pace: %s (real weight %d) -- as if in wheelbarrow [item %d]'):format(
        item and dfhack.items.getDescription(item, 0) or ('item #' .. id), t.whole, t.wb))
end
if n == 0 then print('  no barrow run or heavy hand-haul under way right now') end
if loose == 0 then
    print('  NOTE: no loose wheelbarrow -- dump runs need one that is not assigned to a stockpile')
end
