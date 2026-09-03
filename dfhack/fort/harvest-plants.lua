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
mine = mine or nil        -- job id -> {x,y,z}: jobs this script posted, this session
skip = skip or nil        -- 'x,y,z' -> true: tiles whose job died with the shrub still there

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, off = {}})
        if type(state.off) ~= 'table' then state.off = {} end
    end
    if not mine then mine = {} end
    if not skip then skip = {} end
    return state
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

-- Is this tile inside the zone? (Cheap z check first -- zones are one z-level.)
local function in_zone(zone, x, y, z)
    return z == zone.z and x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2
        and dfhack.buildings.containsTile(zone, x, y)
end

-- Pull every outstanding gathering job inside `zone` back out of the queue, ours and DF's
-- alike -- switching the button off means "stop working this patch", and DF re-posts its
-- own jobs when the zone timer next comes round anyway.
-- Two rules: collect the whole list BEFORE removing anything (removeJob unlinks from the
-- list we would still be walking), and never touch a job a dwarf has already taken --
-- removing a unit's current job segfaults DF.
function clear_zone_jobs(zone)
    local doomed = {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and job.job_type == df.job_type.GatherPlants
            and in_zone(zone, job.pos.x, job.pos.y, job.pos.z)
            and not dfhack.job.getWorker(job) then
            doomed[#doomed + 1] = job
        end
        link = link.next
    end
    load_state()
    for _, job in ipairs(doomed) do
        mine[job.id] = nil
        dfhack.job.removeJob(job)
    end
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
    local posted = 0
    for _, zone in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if (not only_zone or zone.id == only_zone.id)
            and is_gather_zone(zone) and zone.spec_sub_flag.active
            and zone.zone_settings.gather.flags.pick_shrubs and zone_enabled(zone) then
            for x = zone.x1, zone.x2 do
                for y = zone.y1, zone.y2 do
                    local k = key(x, y, zone.z)
                    if posted < MAX_NEW_JOBS and not tiles[k] and not skip[k]
                        and dfhack.buildings.containsTile(zone, x, y)
                        and is_shrub(x, y, zone.z) then
                        post_job(x, y, zone.z)
                        tiles[k] = true
                        posted = posted + 1
                    end
                end
            end
        end
    end
    return posted
end

-- ---- service --------------------------------------------------------------
-- Once a month: new shrubs grow slowly, and the [Harvest] button covers the moment you
-- actually want a zone swept. Same heartbeat as auto-pasture: repeat-util's day timeouts
-- count rendered frames on this build and fire every few game-days, so gate a per-frame
-- timeout on the calendar instead.
local CYCLE_TICKS = 1200 * 28 * CYCLE_MONTHS
local last_run = nil
local hb_gen = 0

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
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
