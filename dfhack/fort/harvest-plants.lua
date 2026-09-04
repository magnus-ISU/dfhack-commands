-- Post a plant-gathering job for every shrub standing in a Gather Fruit zone.
--@module = true
--@enable = true
--[[
harvest-plants

A Gather Fruit zone hands its plants out slowly: DF picks a few tiles at a time and
trickles the rest in as the zone timer comes round again, so a big patch of shrubs
sits half-picked for seasons. Once a month this walks every Gather Fruit zone and posts
a `GatherPlants` job on each shrub in it, so the whole zone is worked at once by whoever
has the labor -- and the [Harvest] button does it on the spot.

  * Every shrub tile inside an active Gather Fruit zone gets a job, unless one is
    already posted there -- DF's own zone jobs count, so nothing is ever duplicated.
  * A zone with "Pick shrubs" switched off is skipped: the zone's own settings still
    decide what gets gathered.
  * Per zone, on by default. The [Harvest] button on the zone panel (below the three
    gather settings) turns this zone's auto-posting off and on, and acts immediately:
    switching it ON posts the zone's jobs there and then, switching it OFF pulls the
    zone's outstanding gathering jobs back out of the queue (any job a dwarf has
    already picked up is left to finish). The choice persists with the fort.
  * A tile whose job disappears while the shrub is still standing (unreachable, no
    free barrel, gathering forbidden there) is dropped for the rest of the session
    rather than re-posted every day, so a stuck plant can't spam job cancellations.
  * Only shrubs with something ON them are posted -- a plant with growths has produce
    only while one is in SEASON, and leaves and flowers are not produce -- and OUR
    outstanding jobs are re-checked daily and taken back when their season ends. A job
    posted over a summer berry patch is still queued in late autumn otherwise, on bare
    twigs; this fort had 114 of them.

    enable harvest-plants     post jobs once a month (persists with the fort)
    disable harvest-plants    stop
    harvest-plants            one pass right now, and report what was posted

Add `enable fort/harvest-plants` to magnus-scripts / dfhack.init to run it every
session.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local GLOBAL_KEY = 'harvest-plants'
local CYCLE_MONTHS = 1     -- a DF month is 28 days; a daily sweep is far more than plants need
local MAX_NEW_JOBS = 60   -- per cycle, so a freshly painted forest zone doesn't flood the queue

-- ---- state ----------------------------------------------------------------
-- Persisted per fort: {enabled, off = {['<zone id>'] = true}}. Absent id = ON, so a
-- zone you never touched harvests itself; JSON keys are strings, hence tostring().
state = state or nil
enabled = enabled or false
-- job id -> {x,y,z}: the jobs this script posted. PERSISTED, not session state: a job that
-- goes out of season two months after it was posted has to be recognisable as ours in order to
-- be taken back, and a save in between must not make it anonymous.
mine = mine or nil
skip = skip or nil        -- 'x,y,z' -> true: tiles whose job died with the shrub still there

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, off = {}})
        if type(state.off) ~= 'table' then state.off = {} end
        if type(state.mine) ~= 'table' then state.mine = {} end
    end
    if not mine then
        mine = {}
        for id, at in pairs(state.mine or {}) do
            local x, y, z = tostring(at):match('^(-?%d+),(-?%d+),(-?%d+)$')
            if x then
                mine[tonumber(id)] = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
            end
        end
    end
    if not skip then skip = {} end
    return state
end

-- written once at the end of a sweep rather than per job: sixty saves in a row for one
-- cycle's posting is sixty writes of the same table
local function save_mine()
    if not state then return end
    state.mine = {}
    for id, pos in pairs(mine) do
        state.mine[tostring(id)] = ('%d,%d,%d'):format(pos.x, pos.y, pos.z)
    end
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, state)
end

local function save_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

-- ---- zones ----------------------------------------------------------------

local function is_gather_zone(bld)
    return bld and df.building_civzonest:is_instance(bld)
        and bld.type == df.civzone_type.PlantGathering
end

function zone_enabled(zone)
    load_state()
    return not state.off[tostring(zone.id)]
end

-- Toggling the button acts at once: ON posts this zone's jobs now (and un-retires any
-- tiles this session gave up on -- asking again is asking for a fresh try), OFF pulls the
-- zone's outstanding gathering jobs back out of the queue.
function set_zone_enabled(zone, on)
    load_state()
    state.off[tostring(zone.id)] = (not on) or nil
    save_state()
    if on then
        clear_zone_skips(zone)
        return do_cycle(zone)
    end
    return clear_zone_jobs(zone)
end

-- the Gather Fruit zone shown on the zone panel right now, or nil
function cur_zone()
    local bld = df.global.game.main_interface.civzone.cur_bld
    if is_gather_zone(bld) then return bld end
end

-- ---- job posting ----------------------------------------------------------

local function key(x, y, z) return ('%d,%d,%d'):format(x, y, z) end

local function is_shrub(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    return tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.SHRUB
end

-- ---- is there anything on it to pick? ----------------------------------------
--
-- A SHRUB-shaped tile is not the same as a plant with produce on it, and the difference is
-- most of the map. This fort had 171 gather jobs posted: 169 of them on bilberry, blueberry
-- and cranberry bushes, whose fruit ran from year-tick 120000 to 200000 and it was 248289 --
-- the berries were months gone. The dwarves walk out, find nothing, and cancel.
--
-- The rule the raws give us:
--   * a plant with NO growths is picked whole -- a dimple cup, a wild plump helmet -- and is
--     always fair game;
--   * a plant WITH growths only has produce while one is in season, and LEAVES and FLOWERS do
--     not count: they are permanently "in season" (timing -1) and are not what a gather job
--     collects, so counting them would make every bush look ripe all year.
local plant_index, plant_index_tick

local function plants_by_pos()
    -- rebuilt at most once per tick: the vector is thousands long and this runs per tile
    local now = df.global.world.frame_counter or 0
    if plant_index and plant_index_tick == now then return plant_index end
    plant_index, plant_index_tick = {}, now
    for _, p in ipairs(df.global.world.plants.all) do
        plant_index[('%d/%d/%d'):format(p.pos.x, p.pos.y, p.pos.z)] = p
    end
    return plant_index
end

local NOT_PRODUCE = {LEAVES = true, FLOWERS = true}

local function has_produce(x, y, z)
    local plant = plants_by_pos()[('%d/%d/%d'):format(x, y, z)]
    if not plant then return false end                   -- shrub tile with no plant record
    local dead = false
    pcall(function() dead = plant.damage_flags.is_dead end)
    if dead then return false end
    local raw = df.global.world.raws.plants.all[plant.material]
    if not raw then return false end
    if #raw.growths == 0 then return true end            -- picked whole
    local tick = df.global.cur_year_tick
    for _, g in ipairs(raw.growths) do
        if not NOT_PRODUCE[g.id] then
            if g.timing_1 < 0 and g.timing_2 < 0 then return true end
            if tick >= g.timing_1 and tick <= g.timing_2 then return true end
        end
    end
    return false
end

-- Every tile that already has a plant-gathering job posted on it, whoever posted it.
-- Walking the job list once per cycle is far cheaper than a per-tile search, and it is
-- the only way to see DF's own zone jobs -- they are not attached to the zone building.
local function gather_job_tiles()
    local tiles, live = {}, {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job then
            if job.job_type == df.job_type.GatherPlants then
                tiles[key(job.pos.x, job.pos.y, job.pos.z)] = true
            end
            live[job.id] = true
        end
        link = link.next
    end
    return tiles, live
end

-- A bare df.job is enough for a designation-style job like this one: no building holder,
-- no job items. DF assigns, runs and cleans it up like one of its own.
local function post_job(x, y, z)
    local job = df.job:new()
    job.job_type = df.job_type.GatherPlants
    job.pos.x, job.pos.y, job.pos.z = x, y, z
    job.completion_timer = -1
    dfhack.job.linkIntoWorld(job, true)
    mine[job.id] = {x = x, y = y, z = z}
    return job
end

-- A job of ours that is gone while its shrub still stands never got done: something
-- refuses that tile. Retire the tile so the next cycle doesn't post it all over again.
local function retire_dead_jobs(live)
    for id, pos in pairs(mine) do
        if not live[id] then
            mine[id] = nil
            if is_shrub(pos.x, pos.y, pos.z) then
                skip[key(pos.x, pos.y, pos.z)] = true
            end
        end
    end
end

-- A SEASON ENDS WHILE THE JOBS ARE STILL QUEUED.
--
-- Checking for produce before posting is only half the job. Berries are in season from
-- year-tick 120000 to 200000; a job posted in the summer is still sitting in the queue in
-- late autumn, on a bush with nothing on it, and the dwarf who finally walks out to it finds
-- bare twigs. This fort had 114 of them, every one posted legitimately months earlier.
--
-- So our own outstanding jobs are re-checked daily and taken back when the tile stops having
-- anything to pick. ONLY ours, and only while nobody has picked the job up: removing a job a
-- dwarf is working segfaults DF, and removing a job DF's own zone posted segfaulted it once
-- ten seconds later, inside an unrelated overlay, and cost this fort its unsaved progress.
function retire_stale()
    load_state()
    local doomed = {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and job.job_type == df.job_type.GatherPlants and mine[job.id]
            and not dfhack.job.getWorker(job)
            and not (is_shrub(job.pos.x, job.pos.y, job.pos.z)
                     and has_produce(job.pos.x, job.pos.y, job.pos.z)) then
            doomed[#doomed + 1] = job          -- collect first: removeJob unlinks the list
        end
        link = link.next
    end
    for _, job in ipairs(doomed) do
        mine[job.id] = nil
        dfhack.job.removeJob(job)
    end
    if #doomed > 0 then save_mine() end
    return #doomed
end

-- Is this tile inside the zone? (Cheap z check first -- zones are one z-level.)
local function in_zone(zone, x, y, z)
    return z == zone.z and x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2
        and dfhack.buildings.containsTile(zone, x, y)
end

-- Pull our outstanding gathering jobs inside `zone` back out of the queue.
--
-- THREE rules, each of them paid for. Collect the whole list BEFORE removing anything
-- (removeJob unlinks from the list we would still be walking). Never touch a job a dwarf has
-- already taken -- removing a unit's current job segfaults DF. And never touch a job DF's own
-- zone posted, only ones in `mine`: doing that segfaulted DF ten seconds later, inside an
-- unrelated overlay walking a building's job list, and cost this fort its unsaved progress.
-- This used to remove DF's too, on the reasoning that the zone re-posts them anyway.
function clear_zone_jobs(zone)
    load_state()
    local doomed = {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and job.job_type == df.job_type.GatherPlants and mine[job.id]
            and in_zone(zone, job.pos.x, job.pos.y, job.pos.z)
            and not dfhack.job.getWorker(job) then
            doomed[#doomed + 1] = job
        end
        link = link.next
    end
    for _, job in ipairs(doomed) do
        mine[job.id] = nil
        dfhack.job.removeJob(job)
    end
    if #doomed > 0 then save_mine() end
    return #doomed
end

-- Forget the tiles in this zone that were retired as unworkable, so they are tried again.
function clear_zone_skips(zone)
    load_state()
    for k in pairs(skip) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        if x and in_zone(zone, tonumber(x), tonumber(y), tonumber(z)) then skip[k] = nil end
    end
end

-- Post a job on every unposted shrub in every enabled Gather Fruit zone (or just in
-- `only_zone`, when given). Returns the number of jobs posted.
function do_cycle(only_zone)
    load_state()
    if not dfhack.world.isFortressMode() then return 0 end
    local tiles, live = gather_job_tiles()
    retire_dead_jobs(live)
    local posted, dirty = 0, false
    for _, zone in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if (not only_zone or zone.id == only_zone.id)
            and is_gather_zone(zone) and zone.spec_sub_flag.active
            and zone.zone_settings.gather.flags.pick_shrubs and zone_enabled(zone) then
            for x = zone.x1, zone.x2 do
                for y = zone.y1, zone.y2 do
                    local k = key(x, y, zone.z)
                    if posted < MAX_NEW_JOBS and not tiles[k] and not skip[k]
                        and dfhack.buildings.containsTile(zone, x, y)
                        and is_shrub(x, y, zone.z) and has_produce(x, y, zone.z) then
                        post_job(x, y, zone.z)
                        tiles[k] = true
                        posted = posted + 1
                        dirty = true
                    end
                end
            end
        end
    end
    if dirty then save_mine() end
    return posted
end

-- ---- service --------------------------------------------------------------
-- Once a month: new shrubs grow slowly, and the [Harvest] button covers the moment you
-- actually want a zone swept. Same heartbeat as auto-pasture: repeat-util's day timeouts
-- count rendered frames on this build and fire every few game-days, so gate a per-frame
-- timeout on the calendar instead.
local CYCLE_TICKS = 1200 * 28 * CYCLE_MONTHS
local RETIRE_TICKS = 1200          -- one day
local last_run, last_retire = nil, nil
local hb_gen = 0

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        -- Daily, not monthly: a season ends on a particular day, and a bush that stopped
        -- fruiting this morning should not have a job on it this afternoon.
        if not last_retire or now - last_retire >= RETIRE_TICKS then
            last_retire = now
            pcall(retire_stale)
        end
        if not last_run or now - last_run >= CYCLE_TICKS then
            last_run = now
            do_cycle()
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

-- exported so a hot reload can re-arm the heartbeat (reqscript does not bump hb_gen
-- on its own, so the old loop keeps running against the old module copy)
function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

-- ---- zone panel button ----------------------------------------------------

HarvestOverlay = defclass(HarvestOverlay, overlay.OverlayWidget)
HarvestOverlay.ATTRS{
    desc = 'Adds a harvest-everything toggle to the Gather Fruit zone panel.',
    -- three rows below the "Gather Fruit" title, at the left edge of the row the three
    -- gather settings sit on
    default_pos = {x = 9, y = 13},
    default_enabled = true,
    viewscreens = 'dwarfmode/Zone/Some/PlantGathering',
    frame = {w = 9, h = 1},
    version = 1,
}

function HarvestOverlay:init()
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 9, h = 1},   -- '[Harvest]'
            label = '[Harvest]',
            text_pen = function()
                local zone = cur_zone()
                return (zone and zone_enabled(zone)) and COLOR_GREEN or COLOR_WHITE
            end,
            on_activate = function()
                local zone = cur_zone()
                if zone then set_zone_enabled(zone, not zone_enabled(zone)) end
            end,
        },
    }
end

OVERLAY_WIDGETS = {harvest = HarvestOverlay}

-- ---- entry points ---------------------------------------------------------

if dfhack_flags.module then
    return
end

if not dfhack.world.isFortressMode() then
    qerror('harvest-plants only works in fortress mode')
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('harvest-plants: ' .. (enabled and 'enabled (background)' or 'disabled'))
else
    load_state()
    local n = do_cycle()
    print(('harvest-plants: posted %d gathering job%s'):format(n, n == 1 and '' or 's'))
    if n == 0 then
        print('  (nothing to pick: no shrubs in a Gather Fruit zone without a job already on them)')
    end
end
