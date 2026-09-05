-- Watchdog for stuck caravans -- the silent killer of trade AND migration.
--@module = true
--@enable = true
--[[
caravan-unstick

A caravan that gets truly stuck never resolves on its own, and the damage is far worse than
one lost trade visit: while a civ has an outstanding caravan entry, DF schedules NO new
Caravan timed event for it. For your HOME civ that also means no returning liaison report --
which is what drives migrant waves -- so migrants stop too. (Diagnosed live: a caravan sat in
trade_state=Leaving with time_remaining=0 for YEARS because its last two members stood on the
map with dead AI -- no job, no path goal -- and "no migrants or dwarven caravans ever" was
the only visible symptom.)

DETECTION IS DELIBERATELY VERY CONSERVATIVE. Caravans normally spend several months arriving,
trading and walking out, and `Leaving` with its clock at 0 is part of a NORMAL departure. So
a caravan is only treated as stuck when ALL of this holds CONTINUOUSLY for OVER A YEAR:
  * trade_state == Leaving with time_remaining == 0, and
  * its on-map members (if any) have not moved a single tile between weekly checks, and
  * every member is AI-dead (no job, no path goal) at every check.
ANY change -- a member moves, picks up a job, the member set changes, the state changes --
resets the year-long clock to zero.

THE FIX (and nothing more): stranded members are offloaded (marked as departed -- no death,
no anger, tile occupancy scrubbed) and the caravan entry is handed back to DF the way a
normal departure does it: `check_cleanup` ("a merchant left the map") plus `communicate`
("somebody lived to report home") are raised and the entry is LEFT IN PLACE. DF then closes
it itself within a few hundred ticks, and because it went through DF's own finalize the
merchants' report reaches their civ -- which is what makes the next year's caravan (and, for
the home civ, the liaison report that drives migrant waves) get scheduled at all.

Never erase the entry by hand: an erased entry is a caravan that never reported home, and
that civ's schedule stays dead for good (seen live 2026-09-04: dwarves gone after year 101,
elves after 102, humans after 104, `timed_events` empty for years). This script NEVER
force-sends caravans or migrants.

As a free extra, AtDepot caravans get the stock `caravan unload` pack-animal rejoin each
check (idempotent, touches nothing healthy).

It also takes the fort OUT OF A CIVIL WAR on the same pass, once that war is a year old. A civ
at war with itself sends your fort no caravans and no migrants -- the same silence, a different
cause -- and it is one field, the one DFHack's `fix/civil-war` clears. The year of patience is
there because a civil war can end on its own; the war itself, and its history, are left alone.

Usage:
    enable caravan-unstick        run the weekly watchdog
    disable caravan-unstick       stop it
    caravan-unstick               status: caravans, how long any has been stuck-looking
    caravan-unstick fix           fix anything CURRENTLY stuck-looking right now,
                                  ignoring the one-year grace (manual override)
]]

local GLOBAL_KEY = 'caravan-unstick'
local DAY = 1200
local YEAR = 403200
local CHECK_DAYS = 7                 -- watchdog cadence
local STUCK_GRACE = YEAR             -- must look stuck continuously this long before acting

-- ---- persisted state (per site) ---------------------------------------------
state = state or nil

local function default_state()
    return {enabled = false, sig = {}}
end

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, default_state())
    end
    for k, v in pairs(default_state()) do
        if state[k] == nil then state[k] = v end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

local function abs_tick()
    return df.global.cur_year * YEAR + df.global.cur_year_tick
end

-- ---- detection ---------------------------------------------------------------

local T = df.caravan_state.T_trade_state

-- on-map, living members of a caravan's civ (merchant-flagged)
local function caravan_members(entity_id)
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if u.civ_id == entity_id and (u.flags1.merchant or u.flags1.forest)
            and not u.flags2.killed and not u.flags1.inactive then
            out[#out + 1] = u
        end
    end
    return out
end

-- a member is "AI-dead" if it has no job and no path goal -- it will stand forever
local function member_idle(u)
    return not u.job.current_job and u.path.goal == -1
end

-- does this caravan LOOK stuck at this instant? (necessary, NOT sufficient -- the
-- year-long continuity requirement below is what makes the call)
local function looks_stuck(c)
    if c.trade_state ~= T.Leaving or c.time_remaining > 0 then return false end
    local members = caravan_members(c.entity)
    -- already handed to DF's cleanup (by us or by a real departure): let it close
    if c.flags.check_cleanup and #members == 0 then return false end
    for _, u in ipairs(members) do
        if not member_idle(u) then return false end   -- somebody is still doing something
    end
    return true, members
end

-- position fingerprint of the member set: any movement/change resets the stuck clock
local function member_fingerprint(members)
    local parts = {}
    for _, u in ipairs(members) do
        parts[#parts + 1] = ('%d@%d,%d,%d'):format(u.id, u.pos.x, u.pos.y, u.pos.z)
    end
    table.sort(parts)
    return table.concat(parts, ';')
end

-- ---- the fix -----------------------------------------------------------------

local function civ_name(entity_id)
    local e = df.historical_entity.find(entity_id)
    return e and dfhack.translation.translateName(e.name, true) or ('civ ' .. entity_id)
end

-- mark a stranded member as having left the map (no death, no corpse, no merchant anger)
local function offload_member(u)
    local x, y, z = u.pos.x, u.pos.y, u.pos.z
    u.flags1.inactive = true
    u.flags1.forest = false
    u.flags2.visitor = false
    u.animal.leave_countdown = 0
    -- scrub the tile occupancy it leaves behind (nothing else will)
    if x >= 0 then
        local b = dfhack.maps.getTileBlock(x, y, z)
        if b then
            local other = false
            for _, o in ipairs(df.global.world.units.active) do
                if o ~= u and not o.flags1.inactive
                    and o.pos.x == x and o.pos.y == y and o.pos.z == z then
                    other = true
                    break
                end
            end
            if not other then
                local occ = b.occupancy[x % 16][y % 16]
                occ.unit = false
                occ.unit_grounded = false
            end
        end
    end
end

-- finalize one stuck caravan entry (index into plotinfo.caravans) the way DF does when the
-- last merchant steps off the map. The entry is NOT erased: check_cleanup makes DF's own
-- caravan bookkeeping close it, and communicate tells it the merchants got home to report --
-- the step that schedules next year's visit. Deliberately does NOT insert any events.
local function fix_stuck(idx)
    local cs = df.global.plotinfo.caravans
    local c = cs[idx]
    local entity_id = c.entity
    local members = caravan_members(entity_id)
    for _, u in ipairs(members) do offload_member(u) end
    c.flags.check_cleanup = true
    c.flags.communicate = true
    dfhack.gui.showAnnouncement(
        ('A long-stranded %s caravan (%d member%s left behind) has been sent home; their report lets the next one be scheduled.')
            :format(civ_name(entity_id), #members, #members == 1 and '' or 's'),
        COLOR_LIGHTGREEN, true)
    return #members
end

-- ---- civil war: the other silent killer --------------------------------------
--
-- A fort whose own civ is at war with ITSELF gets no caravans from home and no standard
-- migration -- the same symptom this watchdog exists for, from a completely different cause,
-- and just as invisible: nothing announces it and nothing in the fort shows it. It is a
-- single field (`relation` on the civ's diplomacy entry for itself), and DFHack's own
-- `fix/civil-war` clears exactly that.
--
-- A YEAR OF IT FIRST, the same patience the stuck-caravan path is given. A civil war can end
-- on its own -- a diplomat carries a peace treaty -- and stepping in on the week it starts
-- takes that away. The war's AGE is read from its own history collection where DF records it
-- (`war_event_collection` -> `start_year`), so a war that has already run for years is acted
-- on at once rather than waiting another year for this tool's own clock; when that cannot be
-- read, the clock starts when this watchdog first sees it.
--
-- What is cleared is the FORT's side of it: your civ stops counting itself an enemy, so trade
-- and migration can resume. The war itself, and its history, are left exactly as they are.
local function self_war_entry(civ)
    local hit
    pcall(function()
        for _, s in ipairs(civ.relations.diplomacy.state) do
            if s.group_id == civ.id and s.relation > 0 then hit = s end
        end
    end)
    return hit
end

-- is the fort's own civ at war with itself right now?
local function in_civil_war()
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    return civ and self_war_entry(civ) ~= nil or false
end

-- how many years the civil war has been running, by DF's own record; nil if unreadable
local function civil_war_years(entry)
    if not entry or entry.war_event_collection < 0 then return nil end
    for _, c in ipairs(df.global.world.history.event_collections.all) do
        if c.id == entry.war_event_collection then
            if c.start_year and c.start_year >= 0 then
                return df.global.cur_year - c.start_year
            end
            return nil
        end
    end
    return nil
end

-- `now` forces it immediately, the same manual override the caravan path takes
local function civil_war_check(now)
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not civ then return false end
    local entry = self_war_entry(civ)
    if not entry then
        if state.civil_since then state.civil_since = nil; save_state() end
        return false
    end

    if not now then
        local years = civil_war_years(entry)
        if years then
            if years < 1 then return false end          -- DF's own record: not a year old yet
        else
            -- no readable start: fall back to how long WE have seen it
            if not state.civil_since then
                state.civil_since = abs_tick()
                save_state()
                return false
            end
            if math.abs(abs_tick() - state.civil_since) < STUCK_GRACE then return false end
        end
    end

    entry.relation = 0
    state.civil_since = nil
    save_state()
    dfhack.gui.showAnnouncement(
        "Your homeland is fighting a civil war -- but you've stayed out of it. Migrants and "
        .. "trade may resume... but hopefully peace can come soon.", COLOR_LIGHTGREEN, true)
    return true
end

-- ---- the watchdog pass -------------------------------------------------------

-- THE INVARIANT: this tool never removes a caravan entry. Removing one is how a civ's trade
-- schedule dies for good -- an entry that vanishes is a caravan that never reported home, and
-- DF then has nothing to schedule the next visit from (for the home civ that also ends the
-- liaison report, and with it migration). v2 of this script did exactly that and cost this
-- fort years of dwarven caravans. Every fix now hands the entry to DF's own cleanup and
-- leaves it in place, so the count can only go DOWN when DF itself closes one.
--
-- That is not a comment anybody has to trust: the count is checked around every pass, and if
-- an entry ever disappears within one of ours the script says so, loudly, naming the civ.
local function caravan_ids()
    local out = {}
    for _, c in ipairs(df.global.plotinfo.caravans) do out[#out + 1] = c.entity end
    return out
end

-- one scan. With `now` true, anything CURRENTLY stuck-looking is fixed immediately
-- (manual override -- the automatic path demands a year of continuous stuckness).
local function do_check(now)
    if not dfhack.world.isFortressMode() then return end
    load_state()
    civil_war_check(now)
    local before = caravan_ids()
    local cs = df.global.plotinfo.caravans
    local seen = {}
    for i = #cs - 1, 0, -1 do
        local c = cs[i]
        local key = tostring(c.entity)
        local stuck, members = looks_stuck(c)
        if stuck then
            seen[key] = true
            local fp = member_fingerprint(members or {})
            local sig = state.sig[key]
            if not sig or sig.fp ~= fp then
                -- first sighting, or something changed (a member moved/appeared/left):
                -- the year-long clock starts over
                sig = {fp = fp, since = abs_tick()}
                state.sig[key] = sig
            end
            if now or math.abs(abs_tick() - sig.since) >= STUCK_GRACE then
                fix_stuck(i)
                state.sig[key] = nil
            end
        end
        -- AtDepot but never unloading: the stock rejoin fix is idempotent and cheap
        if c.trade_state == T.AtDepot then
            pcall(dfhack.run_command, 'caravan', 'unload')
        end
    end
    -- forget clocks for caravans that recovered or left
    for key in pairs(state.sig) do
        if not seen[key] then state.sig[key] = nil end
    end
    save_state()

    -- the invariant, checked: DF closes entries on its own schedule, but never inside one of
    -- our passes. An entry gone here means something in this file removed it.
    local after = {}
    for _, id in ipairs(caravan_ids()) do after[id] = true end
    for _, id in ipairs(before) do
        if not after[id] then
            dfhack.printerr(('caravan-unstick: BUG -- the %s caravan entry disappeared during a '
                .. 'check. Entries must only ever be closed by DF itself; removing one ends '
                .. 'that civ\'s trade schedule permanently. Please report this.')
                :format(civ_name(id)))
        end
    end
end

-- ---- service loop (frame-gap-safe bounce via set_enabled) --------------------

enabled = enabled or false
function isEnabled() return enabled end

local hb_gen = 0
local last_run = nil

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = abs_tick()
        -- abs(): the calendar is NOT monotonic under timestream
        if not last_run or math.abs(now - last_run) >= CHECK_DAYS * DAY then
            last_run = now
            pcall(do_check, false)
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        load_state()
        if state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state = nil
    end
end

function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

if dfhack_flags.module then
    return
end

-- ---- command line ------------------------------------------------------------

if not dfhack.isMapLoaded() then qerror('caravan-unstick needs a loaded fort') end
load_state()

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('caravan-unstick: ' .. (enabled and 'enabled -- weekly watchdog (acts only after A YEAR of continuous stuckness)' or 'disabled'))
    return
end

local cmd = ({...})[1]

if cmd == 'fix' then
    local before = #df.global.plotinfo.caravans
    do_check(true)
    print(('caravan-unstick: scanned %d caravan entr%s; stuck ones handed to DF to close (takes a few hundred ticks)')
        :format(before, before == 1 and 'y' or 'ies'))
else
    print(('caravan-unstick: %s'):format(enabled and 'ENABLED (weekly; fixes only after a YEAR stuck)' or 'disabled'))
    local cs = df.global.plotinfo.caravans
    if #cs == 0 then print('  no caravans at the moment') end
    for i = 0, #cs - 1 do
        local c = cs[i]
        local stuck = looks_stuck(c)
        local sig = state.sig[tostring(c.entity)]
        local extra = ''
        if sig then
            local days = math.floor(math.abs(abs_tick() - sig.since) / DAY)
            extra = (' -- stuck-looking for %d day%s (fix at %d)'):format(
                days, days == 1 and '' or 's', STUCK_GRACE // DAY)
        elseif stuck then
            extra = ' -- stuck-looking (clock starts next check)'
        end
        print(('  %s: %s, time %d, %d member%s on map%s'):format(
            civ_name(c.entity), df.caravan_state.T_trade_state[c.trade_state],
            c.time_remaining, #caravan_members(c.entity),
            #caravan_members(c.entity) == 1 and '' or 's', extra))
    end
    if in_civil_war() then
        print('  YOUR CIV IS AT WAR WITH ITSELF -- no caravans from home, no migrant waves.')
        print('  The fort steps out of it once the war is a year old (`caravan-unstick fix` now).')
    end
    -- WHEN EACH CIV LAST GOT HOME. A caravan reports to its civ when it finalizes, and that
    -- report is what schedules the next visit -- so the last finalize year is the honest
    -- health check on a trade partner, and a civ that stopped years ago shows up here rather
    -- than being noticed as an absence nobody can date.
    local ev = df.global.world.history.events
    local site = df.global.plotinfo.site_id
    local last = {}
    for i = #ev - 1, math.max(0, #ev - 20000), -1 do
        local e = ev[i]
        if df.history_event_type[e:getType()] == 'MERCHANT' and e.site == site then
            local src = e.source
            if not last[src] or e.year > last[src] then last[src] = e.year end
        end
    end
    local rows = {}
    for civ_id, year in pairs(last) do rows[#rows + 1] = {id = civ_id, year = year} end
    table.sort(rows, function(a, b) return a.year > b.year end)
    if #rows > 0 then
        print('  last caravan home, by civ (this is what schedules the next one):')
        for _, r in ipairs(rows) do
            local ago = df.global.cur_year - r.year
            print(('    %-34s year %d%s'):format(civ_name(r.id), r.year,
                ago >= 3 and (' -- %d years ago'):format(ago) or ''))
        end
    end
    if not enabled then print('  `enable caravan-unstick` to watch automatically; `caravan-unstick fix` to fix now.') end
end
