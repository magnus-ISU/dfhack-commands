-- Designate every ripe shrub standing in a Gather Fruit zone for gathering.
--@module = true
--@enable = true
--[[
harvest-plants

A Gather Fruit zone hands its plants out slowly: DF picks a few tiles at a time and
trickles the rest in as the zone timer comes round again, so a big patch of shrubs
sits half-picked for seasons. Once a month this walks every Gather Fruit zone and
DESIGNATES each ripe shrub in it for gathering -- the same tile designation the Designate >
Gather tool paints (`dfhack.designations.markPlant`) -- so DF itself posts and runs the
`GatherPlants` jobs, exactly as if you had dragged the tool over the zone. The [Harvest]
button does it on the spot.

  * Every LIVE shrub tile inside an active Gather Fruit zone gets designated, unless it
    already is or a gathering job is already posted there -- DF's own zone jobs count, so
    nothing is ever duplicated. Withered shrubs (the ShrubDead tile, or a plant record
    flagged dead) are never touched: they are what the zone has already given up on.
  * A zone with "Pick shrubs" switched off is skipped: the zone's own settings still
    decide what gets gathered.
  * Per zone, on by default. The [Harvest] button on the zone panel (below the three
    gather settings) turns this zone's auto-posting off and on, and acts immediately:
    switching it ON posts the zone's jobs there and then, switching it OFF pulls the
    zone's outstanding gathering jobs back out of the queue (any job a dwarf has
    already picked up is left to finish). The choice persists with the fort.
  * Only shrubs with something ON them are designated -- a plant with growths has
    produce only while one is in SEASON, and leaves and flowers are not produce -- and
    OUR designations are re-checked daily and cleared when their season ends, so DF stops
    handing the tile out. A job DF already posted for it is left alone (never pull a job
    DF owns: that has segfaulted this fort); a job a dwarf is already on is finished.
    Designations painted by hand or by DF are never cleared, only ours.

    enable harvest-plants     designate once a month (persists with the fort)
    disable harvest-plants    stop
    harvest-plants            one pass right now, and report what was designated

Add `enable fort/harvest-plants` to magnus-scripts / dfhack.init to run it every
session.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local GLOBAL_KEY = 'harvest-plants'
local CYCLE_MONTHS = 1     -- a DF month is 28 days; a daily sweep is far more than plants need
local MAX_NEW_MARKS = 60  -- per cycle, so a freshly painted forest zone doesn't flood the queue

-- ---- state ----------------------------------------------------------------
-- Persisted per fort: {enabled, off = {['<zone id>'] = true}}. Absent id = ON, so a
-- zone you never touched harvests itself; JSON keys are strings, hence tostring().
state = state or nil
enabled = enabled or false
-- 'x,y,z' -> true: the tiles this script designated. PERSISTED, not session state: a
-- designation that goes out of season two months after it was painted has to be recognisable
-- as ours in order to be cleared, and a save in between must not make it anonymous.
mine = mine or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, off = {}})
        if type(state.off) ~= 'table' then state.off = {} end
        if type(state.mine) ~= 'table' then state.mine = {} end
    end
    if not mine then
        mine = {}
        for k, v in pairs(state.mine or {}) do
            -- older saves kept job id -> 'x,y,z'; the tile is what matters either way
            local at = type(v) == 'string' and v or k
            if tostring(at):match('^(-?%d+),(-?%d+),(-?%d+)$') then mine[at] = true end
        end
    end
    return state
end

-- written once at the end of a sweep rather than per tile: sixty saves in a row for one
-- cycle's painting is sixty writes of the same table
local function save_mine()
    if not state then return end
    state.mine = {}
    for k in pairs(mine) do state.mine[k] = true end
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

-- Toggling the button acts at once: ON designates this zone's ripe shrubs now, OFF clears
-- the designations we painted in it.
function set_zone_enabled(zone, on)
    load_state()
    state.off[tostring(zone.id)] = (not on) or nil
    save_state()
    if on then return do_cycle(zone) end
    return clear_zone_marks(zone)
end

-- the Gather Fruit zone shown on the zone panel right now, or nil
function cur_zone()
    local bld = df.global.game.main_interface.civzone.cur_bld
    if is_gather_zone(bld) then return bld end
end

-- ---- designating ----------------------------------------------------------

local function key(x, y, z) return ('%d,%d,%d'):format(x, y, z) end

-- A standing, LIVE shrub. ShrubDead has the SHRUB shape too, and it is exactly the tile DF's
-- own zone never picks -- so treating every SHRUB-shaped tile as a bush meant every job this
-- script added was on a withered one (the live ones already had DF's).
local function is_shrub(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local attrs = df.tiletype.attrs[tt]
    return attrs.shape == df.tiletype_shape.SHRUB and attrs.special ~= df.tiletype_special.DEAD
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

-- the df.plant standing on this tile, if it is alive
local function live_plant_at(x, y, z)
    local plant = plants_by_pos()[('%d/%d/%d'):format(x, y, z)]
    if not plant then return nil end                     -- shrub tile with no plant record
    -- the flags are `dead` and `season_dead` -- an earlier `is_dead` under pcall read as
    -- "never dead" and let every withered bush through
    if plant.damage_flags.dead or plant.damage_flags.season_dead then return nil end
    return plant
end

local function has_produce(x, y, z)
    local plant = live_plant_at(x, y, z)
    if not plant then return false end
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
    local tiles = {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        if job and job.job_type == df.job_type.GatherPlants then
            tiles[key(job.pos.x, job.pos.y, job.pos.z)] = true
        end
        link = link.next
    end
    return tiles
end

-- DF's own mechanism: the Designate > Gather tool sets the tile's dig designation and flags
-- the block, and DF posts the GatherPlants job itself. markPlant does exactly that.
local function mark(plant)
    if not dfhack.designations.canMarkPlant(plant) then return false end
    if not dfhack.designations.markPlant(plant) then return false end
    mine[key(plant.pos.x, plant.pos.y, plant.pos.z)] = true
    return true
end

-- Clear a designation of ours WITHOUT touching jobs. DFHack's unmarkPlant also pulls the
-- GatherPlants job, and removing a job DF posted segfaulted this fort once, ten seconds
-- later inside an unrelated overlay. With the designation gone DF stops handing the tile
-- out; a job it already posted runs or cancels on DF's own terms.
local function unmark(x, y, z)
    local block = dfhack.maps.getTileBlock(x, y, z)
    if block then
        block.designation[x % 16][y % 16].dig = df.tile_dig_designation.No
        block.flags.designated = true
    end
    mine[key(x, y, z)] = nil
end

local function is_marked(x, y, z)
    local block = dfhack.maps.getTileBlock(x, y, z)
    return block and block.designation[x % 16][y % 16].dig ~= df.tile_dig_designation.No
end

-- A SEASON ENDS WHILE THE DESIGNATION IS STILL UP.
--
-- Checking for produce before designating is only half the job. Berries are in season from
-- year-tick 120000 to 200000; a tile painted in the summer is still designated in late
-- autumn, on a bush with nothing on it, and the dwarf who finally walks out to it finds
-- bare twigs. This fort had 114 such jobs, every one posted legitimately months earlier.
--
-- So our own designations are re-checked daily and cleared when the tile stops having
-- anything to pick. ONLY ours: a tile DF gathered (designation gone) or that the player
-- painted by hand is not ours to clear. Note the window is short: DF clears the designation
-- bit the moment it posts the GatherPlants job (verified: designated tile -> job 197539 and
-- dig=No within a day), and from then on the job is DF's and is left alone.
function retire_stale()
    load_state()
    local n = 0
    for k in pairs(mine) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not is_marked(x, y, z) then
            mine[k] = nil                                 -- DF took it: gathered or gone
        elseif not (is_shrub(x, y, z) and has_produce(x, y, z)) then
            unmark(x, y, z)
            n = n + 1
        end
    end
    if n > 0 then save_mine() end
    return n
end

-- Is this tile inside the zone? (Cheap z check first -- zones are one z-level.)
local function in_zone(zone, x, y, z)
    return z == zone.z and x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2
        and dfhack.buildings.containsTile(zone, x, y)
end

-- Clear the designations we painted inside `zone`. Only ours (in `mine`), and jobs are
-- left alone -- see unmark.
function clear_zone_marks(zone)
    load_state()
    local n = 0
    for k in pairs(mine) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if in_zone(zone, x, y, z) then
            if is_marked(x, y, z) then unmark(x, y, z); n = n + 1 else mine[k] = nil end
        end
    end
    save_mine()
    return n
end

-- Designate every ripe, undesignated shrub in every enabled Gather Fruit zone (or just in
-- `only_zone`, when given). Returns the number of tiles designated.
function do_cycle(only_zone)
    load_state()
    if not dfhack.world.isFortressMode() then return 0 end
    local tiles = gather_job_tiles()
    local posted, dirty = 0, false
    for _, zone in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
        if (not only_zone or zone.id == only_zone.id)
            and is_gather_zone(zone) and zone.spec_sub_flag.active
            and zone.zone_settings.gather.flags.pick_shrubs and zone_enabled(zone) then
            for x = zone.x1, zone.x2 do
                for y = zone.y1, zone.y2 do
                    local k = key(x, y, zone.z)
                    if posted < MAX_NEW_MARKS and not tiles[k]
                        and dfhack.buildings.containsTile(zone, x, y)
                        and is_shrub(x, y, zone.z) and has_produce(x, y, zone.z)
                        and not is_marked(x, y, zone.z)
                        and mark(live_plant_at(x, y, zone.z)) then
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
    print(('harvest-plants: designated %d shrub%s for gathering'):format(n, n == 1 and '' or 's'))
    if n == 0 then
        print('  (nothing to pick: no ripe live shrub in a Gather Fruit zone without a designation or job already on it)')
    end
end
