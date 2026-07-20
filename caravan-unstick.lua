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
no anger, tile occupancy scrubbed) and the spent caravan entry is deleted. That alone lets
DF schedule the next natural visit. This script NEVER force-sends caravans or migrants.

As a free extra, AtDepot caravans get the stock `caravan unload` pack-animal rejoin each
check (idempotent, touches nothing healthy).

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

-- clear one stuck caravan entry (index into plotinfo.caravans). Deliberately does NOT
-- force any replacement events: with the entry gone, DF resumes its natural schedule.
local function fix_stuck(idx)
    local cs = df.global.plotinfo.caravans
    local c = cs[idx]
    local entity_id = c.entity
    local members = caravan_members(entity_id)
    for _, u in ipairs(members) do offload_member(u) end
    cs:erase(idx)
    pcall(function() c:delete() end)
    dfhack.gui.showAnnouncement(
        ('A long-stranded %s caravan (%d member%s left behind) has been sent home; the next one can now be scheduled.')
            :format(civ_name(entity_id), #members, #members == 1 and '' or 's'),
        COLOR_LIGHTGREEN, true)
    return #members
end

-- ---- the watchdog pass -------------------------------------------------------

-- one scan. With `now` true, anything CURRENTLY stuck-looking is fixed immediately
-- (manual override -- the automatic path demands a year of continuous stuckness).
local function do_check(now)
    if not dfhack.world.isFortressMode() then return end
    load_state()
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
    print(('caravan-unstick: scanned %d caravan entr%s, %d left after fixes')
        :format(before, before == 1 and 'y' or 'ies', #df.global.plotinfo.caravans))
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
    if not enabled then print('  `enable caravan-unstick` to watch automatically; `caravan-unstick fix` to fix now.') end
end
