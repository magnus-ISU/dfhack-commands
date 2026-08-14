-- Bring every citizen back when you unretire a fortress.
--@module = true
--[[
loyal-retirees

Retiring a fortress scatters its citizens. Some come back when you unretire, many do not --
they end up settled at other sites, and DF offers no way to recall them.

This records who lived here the moment you RETIRE, and summons every one of them back the
next time you unretire. Anyone still alive is brought home; the dead are reported and
skipped. No other filtering -- if they were a citizen when you retired, they return.
Livestock is excluded (`getCitizens` counts tame animals, and a fort's yaks carry historical
figures of their own); only castes with CAN_LEARN are recorded.

Progress is reported through DF's own announcement log, not the DFHack console, so it reads
alongside the rest of your fortress news.

How it works
============

**While you play.** The citizen roster lives in this site's persistent data
(`dfhack.persistent.saveSiteData`) and is rebuilt whenever the fort's membership moves --
EventManager's UNIT_NEW_ACTIVE and UNIT_DEATH. Those fire on migrant waves, births, deaths
and departures, which is rare enough to be free, and a rebuild that finds no change writes
nothing. Nothing depends on the player visiting a particular screen, so there is no way to
retire with a stale roster.

A seasonal sweep runs on top of that. The unit events do not fire when an ALREADY-ACTIVE unit
becomes a citizen -- a visitor accepted as a resident, say -- so the season catches what the
events structurally cannot. It writes nothing when the membership has not moved.

**Absent members are carried forward, never rebuilt away.** A rebuild derives its list from the
people standing in the fort, so on its own it would delete anyone who is not -- which after an
unretire is precisely everybody this tool exists to fetch, deleted by the rebuild that runs on
map load, before you could type `recover`. So each rebuild keeps every stored member who is
still alive and still has a nemesis record, and re-asserts their never-cull flags while they are
away. Only the dead and the culled fall off the roster. Someone away on a raid or a mission is
the same problem in miniature, and is kept for the same reason.

Each roster member also gets `histfig.flags.never_cull` and `nemesis.flags.DO_NOT_CULL`.
This matters more than it looks: DF culls historical figures it considers unimportant, and
a citizen whose NEMESIS RECORD is culled becomes unrecoverable by any means, because the
recall rides on nemesis ids. Ordinary migrants are exactly what culling targets.

**At unretire.** On map load, the roster is compared against the current citizens. Everyone
missing and still alive is brought home in one trip, by the mechanism below.

Summoning people home
=====================

DF only materialises an off-map histfig as a real unit when an ARMY carrying them arrives at
your site -- and that path restores the ORIGINAL unit, with its skills, wounds, clothing and
inventory intact. Rebuilding units from scratch instead would produce blank strangers wearing
the right names.

Armies cannot be fabricated: DF allocates them from an internal pool, and one built from Lua
(`pool_id = -1`) is silently culled within ~50 ticks. Army CONTROLLERS -- the mission orders,
a separate object -- survive fabrication just fine. So this does not build an army. It builds
a fake mission and lets DF build the army:

  1. fabricate an `army_controller` (a DIPLOMACY task) for the site government;
  2. bind it to an ACTIVE noble position assignment, both ways --
     `assignment.assigned_army_controller_id` and `controller.assigned_epp_*`;
  3. put that noble on a map-edge tile and hold them there.

DF resolves a departing unit's mission through unit -> histfig -> position assignment ->
controller, mints a real pool-registered army, and off they go. The returnees are inserted
into `army.members` (sorted by `nemesis_id`) the frame it appears. When the army gets home
they arrive as visitors and are naturalised with `makeown`.

Gotchas this encodes, each of which cost a debugging session:

  * The courier must stand on a tile of the MAP PERIMETER -- any of the four edges, direction
    irrelevant. Non-perimeter tiles never work however walkable. And DF's departure check is
    PERIODIC, so a courier who wanders off before it fires simply never leaves; they are
    pinned to the tile until the mission starts.
  * The position must be `active` (enabled in this fort). `active` is set on EMPTY assignments
    too, so it means "this office exists here", not "on a mission".
  * Never store scratch state on a df struct (`hf.done = true` throws and silently kills the
    frame callback it was running in). Progress lives in plain Lua tables.
  * The mission needs a real DESTINATION SITE. The riders materialise when the army comes HOME,
    so it has to go somewhere first; given `site_id = -1` DF still mints the army and it then
    parks on the origin tile forever, everyone aboard, nothing ever arriving. A person's
    `whereabouts.site_id` is -1 whenever DF has not placed them, so the destination is voted for
    across everyone being fetched rather than read off one of them.
  * The driver runs on repeat-util, never `dfhack.timeout`. Timeouts belong to the environment
    that made them and a command invocation's environment does not outlive the command, so the
    courier's pin died within a minute, they wandered back indoors, and the mission sat bound to
    their office forever -- silently, since nothing had errored.
  * Nothing in DF ever clears `assignment.assigned_army_controller_id`. Every mission that dies
    before it departs would otherwise burn one noble office permanently, until no courier was
    left and every recall answered "no noble is free to carry word abroad".

Usage::

    loyal-retirees                 -- status: roster on file, who is missing
    loyal-retirees snapshot        -- record the current citizens now
    loyal-retirees recover         -- summon missing roster members immediately
    loyal-retirees migrate <id>... -- summon any historical figures by id, from anywhere
    loyal-retirees forget          -- discard the stored roster

`migrate` uses the same machinery as `recover` but takes historical figure ids directly, so
it can recruit anyone alive in the world -- handy for testing the recall path without waiting
on a retirement, and for deliberately headhunting a particular legend::

    loyal-retirees migrate 163 204 197

The roster maintains itself once the script has been loaded (`magnus-scripts` does this, or
run `loyal-retirees` once); it re-registers on every map load.
]]

local utils = require('utils')
local eventful = require('plugins.eventful')
local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'loyal-retirees'
local UNIT_EVENT_FREQ = 100      -- ticks between EventManager sweeps for unit arrivals/deaths
local SEASON_MONTHS = 3          -- seasonal safety sweep, on top of the unit events
-- How long to hold the courier on the map edge waiting for DF to notice them. DF's departure
-- check is PERIODIC and its period is not ours to know: measured, it has fired within seconds and
-- it has taken well over an in-game fortnight. The old 20000-frame cap (a few real minutes) let
-- go first, leaving the courier to wander back inside and the mission to sit bound forever with
-- no army and no error -- the exact "recover does nothing" symptom. A season is long enough that
-- giving up means something is really wrong.
local MAX_PIN_FRAMES = 400000     -- frames to hold the courier on the edge before giving up
local MAX_WAIT_FRAMES = 400000    -- frames to wait for the army to come home

-- DF calendar: 12 months of 28 days, 1200 ticks a day. A year is a long time to a fortress and
-- no time at all to an adventurer, so the roster reports the DAY it was taken, not just the year.
local MONTHS = {'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena',
                'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian'}
local TICKS_PER_DAY, DAYS_PER_MONTH = 1200, 28
local TICKS_PER_MONTH = TICKS_PER_DAY * DAYS_PER_MONTH
local TICKS_PER_YEAR = TICKS_PER_MONTH * 12

-- the live army DF minted for one of our missions, if it has minted one yet
local function army_of(ctrl_id)
    for _, a in ipairs(df.global.world.armies.all) do
        local ac = a.controller
        if a.controller_id == ctrl_id or (ac and ac.master_id == ctrl_id) then return a end
    end
end

local function date_str(year, tick)
    if not year or year < 0 then return 'an unknown date' end
    if not tick then return ('year %d'):format(year) end   -- roster written before dates were kept
    local doy = math.floor(tick / TICKS_PER_DAY)
    local month = math.min(math.floor(doy / DAYS_PER_MONTH) + 1, #MONTHS)
    return ('%d %s, year %d'):format(doy % DAYS_PER_MONTH + 1, MONTHS[month], year)
end

local function translate(name)
    local ok, s = pcall(dfhack.translation.translateName, name, true)
    return ok and s or '?'
end

-- Report through DF's own announcement log rather than the DFHack console, so the player
-- sees what happened in the place they already read fortress news. `true` recentres/pauses
-- on the announcement the same way DF's own notices do.
local function announce(text, color)
    pcall(dfhack.gui.showAnnouncement, text, color or COLOR_WHITE, true)
end

-- ---------------------------------------------------------------------------
-- roster storage
-- ---------------------------------------------------------------------------

local function load_roster()
    return dfhack.persistent.getSiteData(GLOBAL_KEY, {members = {}, year = -1})
end

local function save_roster(r)
    dfhack.persistent.saveSiteData(GLOBAL_KEY, r)
end

-- Citizens worth recording: people, backed by a historical figure AND a nemesis record.
--   * CAN_LEARN excludes livestock. `getCitizens` counts tame animals as citizens, and a
--     fort's yaks and war dogs can carry historical figures and nemesis records of their own
--     -- they would otherwise be recalled by diplomatic mission alongside the dwarves.
--   * the histfig + nemesis record are what the recall rides on; without both there is no
--     way to bring someone home by any route.
local function is_person(u)
    return dfhack.units.casteFlagSet(u.race, u.caste, df.caste_raw_flags.CAN_LEARN)
end

-- Roster members who are NOT currently citizens but are still alive and still recoverable.
-- Every rebuild carries these forward, and this is what makes the whole tool work at all:
-- a rebuild derives its list from the people standing in the fort, and after an unretire that
-- list is exactly the ones who came back on their own. Without carrying the absent forward, the
-- first refresh after unretire quietly deletes everyone the tool exists to fetch -- and it runs
-- on map load, before you could ever type `recover`. Someone away on a raid or a mission is the
-- same shape of problem in miniature.
-- Dropped here, deliberately: the dead, and anyone whose nemesis record was culled (there is no
-- route home for them, so keeping them only produces a permanent nag).
local function still_away()
    local here = {}
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        if u.hist_figure_id >= 0 then here[u.hist_figure_id] = true end
    end
    local out = {}
    for _, m in ipairs(load_roster().members or {}) do
        if not here[m.hf] then
            local hf = df.historical_figure.find(m.hf)
            if hf and hf.died_year == -1 and hf.nemesis_id >= 0 then out[#out + 1] = m end
        end
    end
    return out
end

-- last rebuilt roster, as a comparable key: a rebuild that changes nothing costs no write.
-- Declared here because snapshot() invalidates it.
local last_key = nil

function snapshot()
    last_key = nil      -- a hand-run snapshot must not be deduped away by the next rebuild
    local members, skipped = {}, 0
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        local hf = u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
        if hf and hf.nemesis_id >= 0 and is_person(u) then
            -- ids only. Names are NOT stored: persistent data is JSON, and DF names carry
            -- CP437 bytes that are not valid UTF-8, which makes the whole roster unreadable
            -- on the way back in. The historical figure is the source of truth for the name.
            members[#members + 1] = {hf = hf.id, nem = hf.nemesis_id}
            -- protect them from being culled while the fort is retired
            pcall(function() hf.flags.never_cull = true end)
            local nem = df.nemesis_record.find(hf.nemesis_id)
            if nem then pcall(function() nem.flags.DO_NOT_CULL = true end) end
        else
            skipped = skipped + 1
        end
    end
    local home = #members
    for _, m in ipairs(still_away()) do
        members[#members + 1] = m       -- keep the absent on the books until they are home or dead
        -- re-assert the culling protection: they are away and unwatched, which is when DF
        -- decides a nobody historical figure is not worth keeping
        local hf = df.historical_figure.find(m.hf)
        if hf then
            pcall(function() hf.flags.never_cull = true end)
            local nem = df.nemesis_record.find(hf.nemesis_id)
            if nem then pcall(function() nem.flags.DO_NOT_CULL = true end) end
        end
    end
    local roster = {members = members, year = df.global.cur_year, tick = df.global.cur_year_tick,
                    site = df.global.plotinfo.site_id}
    save_roster(roster)
    return home, skipped, #members - home
end

-- The roster as a stable, comparable key, so a rebuild that changed nothing costs no write.
local function roster_key(members)
    local ids = {}
    for _, m in ipairs(members) do ids[#ids + 1] = m.hf end
    table.sort(ids)
    return table.concat(ids, ',')
end

-- Rebuild from the live citizen list and store it ONLY if the membership actually moved.
-- Cheap enough to run on every arrival and death: getCitizens is bounded by fort population,
-- and the common case is "nothing changed", which writes nothing.
local function refresh(force)
    if not dfhack.world.isFortressMode() then return end
    local members = {}
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        local hf = u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
        if hf and hf.nemesis_id >= 0 and is_person(u) then
            members[#members + 1] = {hf = hf.id, nem = hf.nemesis_id}
        end
    end
    local key = roster_key(members)
    if not force and key == last_key then return end
    snapshot()          -- re-derives the same list and applies the never-cull protection
    last_key = key      -- after, so snapshot's own invalidation cannot outlive this rebuild
end

-- ---------------------------------------------------------------------------
-- courier + departure point
-- ---------------------------------------------------------------------------

-- A position bound to a mission is off limits as a courier, and NOTHING clears that binding
-- when a mission ends -- DF does not, and a mission that dies before it departs leaves it set
-- forever. Every failed attempt therefore used to burn one office permanently, until the fort
-- ran out of nobles and every recall answered "no noble is free to carry word abroad". Release
-- any binding whose controller is gone, and any pointing at OUR OWN parked missions.
local function release_stale_bindings()
    local fe = df.historical_entity.find(df.global.plotinfo.group_id)
    if not fe then return 0 end
    local freed = 0
    for _, a in ipairs(fe.positions.assignments) do
        local cid = a.assigned_army_controller_id
        if cid >= 0 then
            local c = df.army_controller.find(cid)
            local stale = not c
                -- site_id < 0 is a mission of ours that can never arrive anywhere: DF mints the
                -- army, it has nowhere to go, and it parks on the origin tile for the whole game
                or c.site_id < 0
                -- or DF never minted an army for it at all (the courier was replaced or the
                -- office emptied before the periodic departure check fired). A month is well
                -- past that check, so at that age with no army it is never leaving.
                or (not army_of(cid)
                    and (df.global.cur_year - c.year) * TICKS_PER_YEAR
                         + (df.global.cur_year_tick - c.year_tick) > TICKS_PER_MONTH)
            if stale then
                a.assigned_army_controller_id = -1
                freed = freed + 1
            end
        end
    end
    return freed
end

-- A courier is the holder of a position that is ACTIVE (this office exists in this fort),
-- currently filled, on the map, and not already away on a mission.
local function find_courier()
    local fe = df.historical_entity.find(df.global.plotinfo.group_id)
    if not fe then return end
    release_stale_bindings()
    for _, a in ipairs(fe.positions.assignments) do
        local ok, active = pcall(function()
            return a.flags[df.entity_position_profile_flags.active]
        end)
        if ok and active and a.histfig >= 0 and a.assigned_army_controller_id < 0 then
            local hf = df.historical_figure.find(a.histfig)
            local u = hf and df.unit.find(hf.unit_id)
            if u and not u.flags1.inactive and dfhack.units.isCitizen(u) then
                return a, hf, u
            end
        end
    end
end

-- Departure only happens from the MAP PERIMETER. Pick the nearest perimeter tile whose
-- surface is walkable and in the courier's own walkability group.
local function edge_tile(unit)
    local W = df.global.world.map
    local ok, mygroup = pcall(dfhack.maps.getWalkableGroup, unit.pos)
    if not ok then mygroup = nil end
    local xmax, ymax = W.x_count - 1, W.y_count - 1
    local cands = {}
    for y = 1, ymax - 1 do
        cands[#cands + 1] = {0, y}
        cands[#cands + 1] = {xmax, y}
    end
    for x = 1, xmax - 1 do
        cands[#cands + 1] = {x, 0}
        cands[#cands + 1] = {x, ymax}
    end
    local best, bestd
    for _, xy in ipairs(cands) do
        for z = W.z_count - 1, 1, -1 do
            local pos = xyz2pos(xy[1], xy[2], z)
            local tt = dfhack.maps.getTileType(pos)
            if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.FLOOR then
                local fl, occ = dfhack.maps.getTileFlags(pos)
                if fl and fl.outside and not fl.hidden
                    and occ and occ.building == df.tile_building_occ.None then
                    local ok2, wg = pcall(dfhack.maps.getWalkableGroup, pos)
                    if ok2 and wg ~= 0 and (not mygroup or wg == mygroup) then
                        local d = math.abs(xy[1] - unit.pos.x) + math.abs(xy[2] - unit.pos.y)
                        if not bestd or d < bestd then best, bestd = pos, d end
                    end
                end
                break                      -- topmost floor in the column is the surface
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- the fake mission
-- ---------------------------------------------------------------------------

local function next_id(vec)
    local m = -1
    for _, o in ipairs(vec) do if o.id > m then m = o.id end end
    return m + 1
end

local function make_mission(courier_hf, assignment, dest_site)
    local world = df.global.world
    local govt = df.global.plotinfo.group_id
    local site = df.world_site.find(df.global.plotinfo.site_id)
    local hx, hy = site.global_min_x * 3, site.global_min_y * 3

    local c = df.army_controller:new()
    c.id = next_id(world.army_controllers.all)
    c.entity_id, c.site_id, c.subregion_id = govt, dest_site, -1
    c.pos_x, c.pos_y = hx, hy
    c.year, c.year_tick = df.global.cur_year, df.global.cur_year_tick
    c.parent_id, c.master_id = -1, c.id
    c.master_hf, c.commander_hf = courier_hf.id, -1
    c.origin_task_holder_nemesis_id, c.origin_task_id = -1, -1
    c.origin_plot_holder_nemesis_id, c.origin_plot_id = -1, -1
    c.goal = df.army_controller_goal_type.DIPLOMACY
    local gd = df.ac_goal_diplomacyst:new()
    gd.topic:insert('#', df.meeting_topic.OpenTrade)
    gd.topic_id1:insert('#', -1)
    gd.topic_id2:insert('#', -1)
    gd.source_abs_smm_x, gd.source_abs_smm_y = hx, hy
    c.data.goal_diplomacy = gd
    c.flag.civ_rep = true
    c.assigned_epp_entity_id:insert('#', govt)
    c.assigned_epp_epp_id:insert('#', assignment.id)
    world.army_controllers.all:insert('#', c)
    assignment.assigned_army_controller_id = c.id
    return c
end

-- Insert a rider into a live army. Members are kept sorted by nemesis_id.
local function board_one(army, hf)
    for _, m in ipairs(army.members) do
        if m.nemesis_id == hf.nemesis_id then return false end
    end
    local ref = army.members[0]
    local m = df.army_nemesisst:new()
    m.nemesis_id = hf.nemesis_id
    m.stored_fat = ref and ref.stored_fat or 413500
    m.tracking_rating = ref and ref.tracking_rating or 15
    m.sneak_rating = ref and ref.sneak_rating or 31
    m.smell_trigger, m.odor_level = 50, 50
    m.travel_rate = ref and ref.travel_rate or 10
    m.abs_x, m.abs_y, m.abs_z = -1000000, -1000000, -1000000
    m.mount_nemid, m.section_master_acid, m.section_index = -1, -1, -1
    utils.insert_sorted(army.members, m, 'nemesis_id')

    local w = hf.info.whereabouts
    local old_site = w.site_id
    w.army_id, w.state, w.site_id = army.id, df.whereabouts_type.army_died, -1
    -- DF does not clear the old residency itself; leaving it makes the histfig a resident of
    -- two places, and the copy at the old site can later die in a worldgen event while a unit
    -- here still points at them.
    if old_site >= 0 then
        local st = df.world_site.find(old_site)
        if st then
            for k = #st.populace.nemesis - 1, 0, -1 do
                if st.populace.nemesis[k] == hf.nemesis_id then st.populace.nemesis:erase(k) end
            end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- recovery
-- ---------------------------------------------------------------------------

-- Put back anyone left in LIMBO: a unit that is not `inactive`, not dead, belongs to no army and
-- is still a citizen by every flag -- but is missing from `world.units.active`. DF only ticks what
-- is in that list, so such a person is frozen where they stand, invisible to getCitizens and to
-- every tool that counts citizens (the fort's own population included). Boarding somebody onto a
-- mission that then dies is exactly how one is made, which this tool used to do routinely; the
-- symptom is a citizen who never comes home and never appears anywhere either.
-- Bounded by the roster, so it costs nothing to check on every load.
local function reclaim_stranded()
    local active = {}
    for _, u in ipairs(df.global.world.units.active) do active[u.id] = true end
    local fixed = {}
    for _, m in ipairs(load_roster().members or {}) do
        local hf = df.historical_figure.find(m.hf)
        local w = hf and hf.info and hf.info.whereabouts
        local u = hf and hf.died_year == -1 and hf.unit_id >= 0 and df.unit.find(hf.unit_id)
        if u and w and not active[u.id] and not u.flags1.inactive
            and w.army_id < 0 and dfhack.units.isCitizen(u) then
            df.global.world.units.active:insert('#', u)
            fixed[#fixed + 1] = hf
        end
    end
    return fixed
end

-- who from the roster is not currently a citizen here?
-- "Not in getCitizens" is not the same as "gone": a squad away on a raid and a diplomat on a
-- mission are both off the citizen list while still belonging to this fort, and DF brings them
-- back by itself. Summoning those is worse than useless -- it boards someone who is already
-- riding an army onto a second one -- so anyone travelling with an army, or whom DF still places
-- at THIS site, is counted as neither away nor dead. They are simply out.
local function missing_from(roster)
    local here = {}
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        if u.hist_figure_id >= 0 then here[u.hist_figure_id] = true end
    end
    local home_site = df.global.plotinfo.site_id
    local away, dead, out = {}, {}, {}
    for _, m in ipairs(roster.members or {}) do
        if not here[m.hf] then
            local hf = df.historical_figure.find(m.hf)
            local w = hf and hf.info and hf.info.whereabouts
            if not hf then
                dead[#dead + 1] = m
            elseif hf.died_year ~= -1 then
                dead[#dead + 1] = m
            elseif hf.nemesis_id < 0 then
                dead[#dead + 1] = m       -- nemesis culled: unrecoverable
            elseif w and (w.army_id >= 0 or w.site_id == home_site) then
                out[#out + 1] = hf        -- ours, just not standing here right now
            else
                away[#away + 1] = hf
            end
        end
    end
    return away, dead, out
end

-- Where the mission is nominally going. This is not a formality: the riders materialise when the
-- army COMES HOME, so the army has to have somewhere to go first. Given `site_id = -1` DF still
-- mints the army, and it then sits on the origin tile forever with everybody aboard and nothing
-- ever arriving -- which is exactly what a recall looks like when it silently does nothing.
-- A person's `whereabouts.site_id` is -1 whenever DF has not placed them at a site, so taking the
-- destination from one arbitrary person is a coin flip. Take the site most of them are actually
-- at, fall back to their site links, then to any other site of our civilisation.
local function pick_destination(people)
    local home = df.global.plotinfo.site_id
    local tally, best, bestn = {}, nil, 0
    local function vote(site, weight)
        if not site or site < 0 or site == home or not df.world_site.find(site) then return end
        tally[site] = (tally[site] or 0) + weight
        if tally[site] > bestn then best, bestn = site, tally[site] end
    end
    for _, hf in ipairs(people) do vote(hf.info and hf.info.whereabouts and hf.info.whereabouts.site_id, 2) end
    if best then return best end
    for _, hf in ipairs(people) do
        pcall(function() for _, sl in ipairs(hf.site_links) do vote(sl.site, 1) end end)
    end
    if best then return best end
    -- nobody is anywhere DF will admit to: any foreign site our own civilisation holds will do,
    -- since the journey only has to be a round trip
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if civ then
        local ok = pcall(function()
            for _, sl in ipairs(civ.site_links) do vote(sl.target, 1) end
        end)
        if not ok then pcall(function()
            for _, s in ipairs(civ.sites) do vote(s, 1) end
        end) end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- the mission driver
-- ---------------------------------------------------------------------------
--
-- A summon is not finished when the command returns. The courier has to be HELD on the map edge
-- until DF's periodic departure check notices them, the riders have to be inserted the moment DF
-- mints the army, and each one has to be naturalised as their unit materialises back home. That
-- is minutes of frame-by-frame work after the command has printed its last line.
--
-- It runs on repeat-util, keyed by name, NOT on `dfhack.timeout`. Timeouts belong to the
-- environment that created them, and a command invocation's environment does not outlive the
-- command: measured, the courier's pin stopped within a minute, they walked back indoors, and the
-- mission sat bound to their office forever with no army and no error -- `recover` doing nothing,
-- exactly as reported. repeat-util lives in its own module, so the driver keeps ticking, and
-- being keyed means a second summon replaces the first instead of racing it.
local MISSION_KEY = GLOBAL_KEY .. '-mission'
local mission = nil

local function end_mission(why, color)
    if mission and mission.assignment then
        -- always give the office back; nothing in DF clears this
        pcall(function() mission.assignment.assigned_army_controller_id = -1 end)
    end
    mission = nil
    repeatutil.cancel(MISSION_KEY)
    if why then announce(why, color or COLOR_YELLOW); dfhack.printerr('loyal-retirees: ' .. why) end
end

local function mission_tick()
    local m = mission
    if not m then repeatutil.cancel(MISSION_KEY) return end
    m.frames = m.frames + 1

    if not m.boarded then
        local army = army_of(m.ctrl)
        if army then
            local n = 0
            for _, hf in ipairs(m.people) do
                if board_one(army, hf) then n = n + 1 end
            end
            m.boarded, m.army = true, army.id
            print(('loyal-retirees: %d boarded army %d'):format(n, army.id))
            announce(('The journey has begun; %d %s expected.'):format(#m.people,
                #m.people == 1 and 'traveller is' or 'travellers are'), COLOR_LIGHTCYAN)
        elseif not df.army_controller.find(m.ctrl) then
            return end_mission('The journey was abandoned before it began. Run the command again to retry.')
        else
            -- Hold the courier on the edge. DF's departure check is periodic and a courier who
            -- steps off before it fires never leaves at all.
            local u = df.unit.find(m.unit)
            if u and not u.flags1.inactive
                and (u.pos.x ~= m.edge.x or u.pos.y ~= m.edge.y or u.pos.z ~= m.edge.z) then
                pcall(dfhack.units.teleport, u, m.edge)
            end
            if m.frames > MAX_PIN_FRAMES then
                return end_mission('No word ever left the fortress. Run the command again to retry.')
            end
            return
        end
    end

    -- Naturalise each arrival as their unit materialises. Do NOT stop early just because nobody
    -- is in an army any more: there is a window where the army has dissolved and the unit has not
    -- loaded yet, and giving up there strands them as permanent visitors.
    local remaining = 0
    for _, hf in ipairs(m.people) do
        if not m.settled[hf.id] then
            local u = df.unit.find(hf.unit_id)
            if u and not u.flags1.inactive and hf.info.whereabouts.army_id < 0 then
                u.flags2.visitor = false
                pcall(dfhack.units.makeown, u)
                if dfhack.units.isCitizen(u) then
                    m.settled[hf.id] = true
                    announce(('%s has joined the fortress.')
                        :format(dfhack.units.getReadableName(u)), COLOR_LIGHTGREEN)
                end
            end
            if not m.settled[hf.id] then remaining = remaining + 1 end
        end
    end
    if remaining == 0 then
        announce(('All %d have arrived.'):format(#m.people), COLOR_LIGHTGREEN)
        return end_mission()
    end
    if m.frames > MAX_WAIT_FRAMES then
        return end_mission('The journey has taken too long; giving up on the stragglers.')
    end
end

local function start_mission_driver()
    repeatutil.scheduleEvery(MISSION_KEY, 1, 'frames', mission_tick)
end

-- what the driver is doing right now, for `loyal-retirees` status
local function mission_status()
    local m = mission
    if not m then return end
    local names = {}
    for _, hf in ipairs(m.people) do
        if not m.settled[hf.id] then names[#names + 1] = translate(hf.name) end
    end
    return ('  mission %d %s (%d frames) -- awaiting %s'):format(
        m.ctrl, m.boarded and ('under way with army ' .. tostring(m.army)) or 'waiting for the courier to depart',
        m.frames, #names > 0 and table.concat(names, ', ') or 'nobody')
end

-- Send one mission that fetches everyone in `people` (a list of historical_figure). Shared by
-- `recover` (roster members who went missing) and `migrate` (anybody you name).
-- `what` names the group for the announcements; `dead` is reported but not fetched.
local function summon(people, what, dead)
    dead = dead or 0
    if mission then
        dfhack.printerr('loyal-retirees: a summons is already under way; wait for it to finish')
        return false
    end
    local assignment, chf, cu = find_courier()
    if not assignment then
        announce('No noble is free to carry word abroad. Appoint one, then try again.', COLOR_YELLOW)
        dfhack.printerr('loyal-retirees: no active, filled, free noble position to carry the mission.')
        dfhack.printerr('  Appoint a noble to any active office and run the command again.')
        return false
    end
    local edge = edge_tile(cu)
    if not edge then
        dfhack.printerr('loyal-retirees: no reachable map-edge tile found')
        return false
    end
    local dest = pick_destination(people)
    if not dest then
        announce('There is nowhere abroad to send for them.', COLOR_YELLOW)
        dfhack.printerr('loyal-retirees: no destination site found -- refusing to send a mission')
        dfhack.printerr('  a mission with no destination never travels, so nobody would ever arrive.')
        return false
    end

    local ctrl = make_mission(chf, assignment, dest)
    dfhack.units.teleport(cu, edge)
    dfhack.units.setPathGoal(cu, edge, df.unit_path_goal.SeekStation)

    announce(('%s departs to summon %d %s%s.'):format(
        translate(chf.name), #people, what, dead > 0 and (' -- %d cannot be reached'):format(dead) or ''),
        COLOR_LIGHTCYAN)
    local dsite = df.world_site.find(dest)
    print(('loyal-retirees: summoning %d (%d unreachable)'):format(#people, dead))
    print(('  courier %s -> edge (%d,%d,%d), mission %d bound for %s'):format(
        translate(chf.name), edge.x, edge.y, edge.z, ctrl.id,
        dsite and translate(dsite.name) or ('site ' .. dest)))

    mission = {ctrl = ctrl.id, unit = cu.id, assignment = assignment, edge = edge,
               people = people, frames = 0, boarded = false, settled = {}}
    start_mission_driver()
    return true
end

-- Summon roster members who are no longer here.
function recover()
    local roster = load_roster()
    if #(roster.members or {}) == 0 then
        dfhack.printerr('loyal-retirees: no roster on file for this site')
        return
    end
    local away, dead = missing_from(roster)
    if #away == 0 then
        print(('loyal-retirees: nobody to summon (%d dead/unrecoverable)'):format(#dead))
        return
    end
    summon(away, ('former citizen%s home'):format(#away == 1 and '' or 's'), #dead)
end

-- Summon anybody in the world by historical figure id, whether or not they ever lived here.
-- Useful for testing the recall machinery, and for recruiting a specific person on purpose.
function migrate(ids)
    local people, skipped = {}, {}
    local here = {}
    for _, u in ipairs(dfhack.units.getCitizens(false)) do
        if u.hist_figure_id >= 0 then here[u.hist_figure_id] = true end
    end
    for _, id in ipairs(ids) do
        local hf = df.historical_figure.find(id)
        if not hf then skipped[#skipped + 1] = ('%d: no such historical figure'):format(id)
        elseif hf.died_year ~= -1 then skipped[#skipped + 1] = ('%d: dead'):format(id)
        elseif hf.nemesis_id < 0 then skipped[#skipped + 1] = ('%d: no nemesis record, cannot travel'):format(id)
        elseif here[id] then skipped[#skipped + 1] = ('%d: already here'):format(id)
        elseif hf.info and hf.info.whereabouts and hf.info.whereabouts.army_id >= 0 then
            skipped[#skipped + 1] = ('%d: already travelling with an army'):format(id)
        else
            people[#people + 1] = hf
        end
    end
    for _, why in ipairs(skipped) do dfhack.printerr('  skipped hf ' .. why) end
    if #people == 0 then
        dfhack.printerr('loyal-retirees: nobody to migrate')
        return
    end
    for _, hf in ipairs(people) do
        print(('  %s (hf %d)'):format(translate(hf.name), hf.id))
    end
    summon(people, ('new arrival%s'):format(#people == 1 and '' or 's'), #skipped)
end

-- ---------------------------------------------------------------------------
-- keeping the roster current
-- ---------------------------------------------------------------------------
--
-- The roster is maintained from EventManager rather than from the retire dialog. Watching the
-- GUI meant the roster was only ever as good as the player passing through one specific
-- screen; the events fire whenever the fort's membership actually moves, which is the thing
-- we care about, and they cannot be bypassed.
--
-- Both events are cheap: they fire on migrant waves, births, deaths and departures -- not
-- often -- and each one only rebuilds a list bounded by fort population, writing to persistent
-- storage only when the membership actually differs from what is already stored.
--
-- UNIT_NEW_ACTIVE fires when a unit becomes active on the map, not when an existing unit
-- BECOMES a citizen (a visitor accepted as a resident was already active). The seasonal sweep
-- below exists to cover exactly that gap; `loyal-retirees snapshot` forces a rebuild on demand.

local function on_unit_event()
    refresh()
end

local function register_events()
    if not dfhack.world.isFortressMode() then return end
    eventful.enableEvent(eventful.eventType.UNIT_NEW_ACTIVE, UNIT_EVENT_FREQ)
    eventful.enableEvent(eventful.eventType.UNIT_DEATH, UNIT_EVENT_FREQ)
    eventful.onUnitNewActive[GLOBAL_KEY] = on_unit_event
    eventful.onUnitDeath[GLOBAL_KEY] = on_unit_event
    -- Seasonal safety sweep. The unit events cover arrivals and deaths, but they do NOT fire
    -- when an already-active unit becomes a citizen -- a visitor accepted as a resident, a
    -- captive who joins. This catches those without anyone having to remember anything, and
    -- still writes nothing when the membership has not moved.
    repeatutil.scheduleEvery(GLOBAL_KEY, SEASON_MONTHS, 'months', function() refresh() end)
    refresh(true)      -- seed the baseline for this fort
end

local function unregister_events()
    eventful.onUnitNewActive[GLOBAL_KEY] = nil
    eventful.onUnitDeath[GLOBAL_KEY] = nil
    repeatutil.cancel(GLOBAL_KEY)
    repeatutil.cancel(MISSION_KEY)
    mission = nil          -- a mission in flight does not survive the map unloading
    last_key = nil
end

-- ---------------------------------------------------------------------------
-- unretire: summon on map load
-- ---------------------------------------------------------------------------

dfhack.onStateChange[GLOBAL_KEY] = function(ev)
    if ev == SC_MAP_UNLOADED then
        unregister_events()
        return
    end
    if ev ~= SC_MAP_LOADED then return end
    if not dfhack.world.isFortressMode() then return end
    -- read the stored roster BEFORE registering (registration rebuilds it), so what is reported
    -- is the roster as it was written, not one rewritten by this very load
    local roster = load_roster()
    local away, dead = {}, {}
    if #(roster.members or {}) > 0 then away, dead = missing_from(roster) end
    register_events()
    for _, hf in ipairs(reclaim_stranded()) do
        announce(('%s was stranded between here and elsewhere, and is back among the living.')
            :format(translate(hf.name)), COLOR_LIGHTGREEN)
    end
    if #away == 0 then return end
    announce(('%d former citizen%s of this fortress (roster of %s) %s living elsewhere%s. Run loyal-retirees recover to send for them.')
        :format(#away, #away == 1 and '' or 's', date_str(roster.year, roster.tick),
                #away == 1 and 'is' or 'are',
                #dead > 0 and (' (%d have died)'):format(#dead) or ''), COLOR_LIGHTCYAN)
end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

function status()
    for _, hf in ipairs(reclaim_stranded()) do
        print(('  un-stranded %s (was frozen off the active unit list)'):format(translate(hf.name)))
    end
    local roster = load_roster()
    local n = #(roster.members or {})
    if n == 0 then
        print('loyal-retirees: no roster recorded for this site yet.')
        print('  It is written automatically when you open the Retire confirmation,')
        print('  or right now with: loyal-retirees snapshot')
        return
    end
    print(('loyal-retirees: %d citizens recorded, roster last written %s'):format(
        n, date_str(roster.year, roster.tick)))
    local away, dead, out = missing_from(roster)
    print(('  home: %d   away: %d   dead/unrecoverable: %d%s'):format(
        n - #away - #dead - #out, #away, #dead,
        #out > 0 and ('   on fortress business: %d'):format(#out) or ''))
    for i, hf in ipairs(away) do
        if i > 10 then print(('  ... and %d more'):format(#away - 10)) break end
        local w = hf.info.whereabouts
        local st = w.site_id >= 0 and df.world_site.find(w.site_id)
        print(('    %-28s at %s'):format(translate(hf.name), st and translate(st.name) or 'unknown'))
    end
    -- the whole point of the tool is the next command; say it here rather than leave a list of
    -- absent people and no way out of it
    local ms = mission_status()
    if ms then print(ms)
    elseif #away > 0 then print('  Run `loyal-retirees recover` to bring them home.') end
end

-- Start maintaining the roster as soon as the script is loaded, so it does not have to wait
-- for the next map load to begin tracking. Idempotent: registering twice replaces the handler.
if dfhack.isMapLoaded() then register_events() end

if dfhack_flags and dfhack_flags.module then return end

-- Run the work in the PERSISTENT module environment, not in this throwaway one. A summon is not
-- over when the command returns: it holds the courier on the map edge and boards the army from
-- frame timers, for as long as DF takes to notice the mission. Timers created here belong to the
-- environment this invocation runs in, and when that goes so does the courier's pin -- they walk
-- back indoors and the mission never departs. `reqscript` on ourselves hands back the module copy,
-- which is loaded for the whole session.
local mod = reqscript('fort/loyal-retirees')

local cmd = ({...})[1]
if cmd == 'snapshot' then
    local n, skipped, kept = mod.snapshot()
    print(('loyal-retirees: recorded %d citizens on %s%s%s'):format(
        n, date_str(df.global.cur_year, df.global.cur_year_tick),
        kept > 0 and (', plus %d still away'):format(kept) or '',
        skipped > 0 and (' (%d skipped: livestock or no historical figure)'):format(skipped) or ''))
elseif cmd == 'recover' then
    mod.recover()
elseif cmd == 'migrate' then
    local args = {...}
    local ids = {}
    for i = 2, #args do
        local n = tonumber(args[i])
        if n then ids[#ids + 1] = n
        else dfhack.printerr(('not a historical figure id: %s'):format(tostring(args[i]))) end
    end
    if #ids == 0 then
        qerror('usage: loyal-retirees migrate <hf_id> [<hf_id> ...]')
    end
    mod.migrate(ids)
elseif cmd == 'forget' then
    dfhack.persistent.deleteSiteData(GLOBAL_KEY)
    print('loyal-retirees: roster discarded')
else
    mod.status()
end
