-- Keep the world's forgotten beasts from going extinct by reviving the dead ones.
--@module = true
--@enable = true
--[[
tarrasque

Forgotten beasts are a FINITE pool: worldgen makes exactly one per underground region (per the
wiki), and once your fort kills the ones tied to the cavern regions you can reach, that's it -- no
new ones are generated, so eventually the attacks just stop. This brings them back, tarrasque-style:
it finds forgotten beasts that have DIED and resurrects them (via DFHack's own `full-heal -r`, which
un-kills the unit, sets the historical figure's died_year back to -1, refills blood / heals the body,
and logs a "revived" history event). A revived beast comes back to life where it fell -- a live unit
in the caverns again, and a living world figure -- so the pool refills and the caverns stay dangerous.

Only beasts whose unit still exists (ones your fort has met) can be revived this way; a handful that
died off-map in worldgen leave only a history figure with no unit and are skipped.

Usage:
    tarrasque                 show how many forgotten beasts are alive / dead / revivable
    tarrasque revive [N]      revive up to N dead beasts now (default 1); `tarrasque revive all`
    tarrasque target <N>      set the minimum living population the background service maintains
    enable tarrasque          background service: whenever the living count drops below the target,
                              revive dead beasts to top it back up (checked ~monthly)
    disable tarrasque         stop the service

WARNING: a revived beast is a live forgotten beast again -- in whatever cavern it died in. Reviving
several at once (or `revive all`) can put a lot of them back in play, so start small.
]]

local GLOBAL_KEY = 'tarrasque'
local CHECK_DAYS = 28              -- background survey cadence (~once a game month)
local DEFAULT_TARGET = 5          -- keep at least this many forgotten beasts alive

-- ---- forgotten-beast identification ---------------------------------------
-- FB creatures are the procedurally-generated ones whose id is FORGOTTEN_BEAST_<n> (same test
-- DFHack's exterminate uses). Cache the race-index set; it never changes within a world.
local fb_race_cache
local function fb_races()
    if not fb_race_cache then
        fb_race_cache = {}
        local cr = df.global.world.raws.creatures.all
        for i = 0, #cr - 1 do
            if tostring(cr[i].creature_id):match('^FORGOTTEN_BEAST_%d+$') then fb_race_cache[i] = true end
        end
    end
    return fb_race_cache
end

-- one pass over the world's historical figures: living count, dead count, and the dead ones we can
-- actually resurrect (their unit still exists and is flagged killed, not a wagon "scuttle").
local function survey()
    local fb = fb_races()
    local alive, dead, revivable = 0, 0, {}
    for _, hf in ipairs(df.global.world.history.figures) do
        if fb[hf.race] then
            if (hf.died_year or -1) >= 0 then
                dead = dead + 1
                local uid = hf.unit_id or -1
                local u = uid >= 0 and df.unit.find(uid) or nil
                if u and u.flags2.killed and not u.flags3.scuttle then
                    revivable[#revivable + 1] = uid
                end
            else
                alive = alive + 1
            end
        end
    end
    return alive, dead, revivable
end

-- resurrect the dead beasts owning these unit ids (reuses full-heal -r). Returns revived names.
local function revive_units(uids)
    local revived = {}
    for _, uid in ipairs(uids) do
        dfhack.run_command('full-heal', '-r', '--unit', tostring(uid))
        local u = df.unit.find(uid)
        if u and not u.flags2.killed then
            local ok, nm = pcall(dfhack.units.getReadableName, u)   -- single unit: safe
            revived[#revived + 1] = ok and nm or ('unit ' .. uid)
        end
    end
    return revived
end

-- revive up to `n` dead forgotten beasts (nil = as many as it takes to reach the target). Returns
-- the list of revived names.
local function revive_up_to(n)
    local _, _, revivable = survey()
    if n == nil then n = #revivable end
    local take = {}
    for i = 1, math.min(n, #revivable) do take[i] = revivable[i] end
    return revive_units(take)
end

-- ---- persisted config -----------------------------------------------------
state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, target = DEFAULT_TARGET})
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

-- ---- background service ---------------------------------------------------

enabled = enabled or false
function isEnabled() return enabled end

-- top the living population back up to the target if it's fallen below
local function do_cycle()
    if not dfhack.world.isFortressMode() then return end
    load_state()
    local alive, _, revivable = survey()
    if alive >= state.target or #revivable == 0 then return end
    local want = math.min(state.target - alive, #revivable)
    local slice = {}
    for i = 1, want do slice[i] = revivable[i] end
    local revived = revive_units(slice)
    if #revived > 0 then
        print(('tarrasque: revived %d forgotten beast%s to keep the caverns alive (%d/%d):'):format(
            #revived, #revived == 1 and '' or 's', alive + #revived, state.target))
        for _, nm in ipairs(revived) do print('  + ' .. nm) end
    end
end

local hb_gen = 0
local last_run = nil
local DAY_TICKS = 1200 * CHECK_DAYS

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= DAY_TICKS then
            last_run = now
            pcall(do_cycle)
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
        state, fb_race_cache = nil, nil
        load_state()
        if dfhack.world.isFortressMode() and state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, fb_race_cache = nil, nil
    end
end

-- exported for reqscript-driven toggling (the `enable` command path can serve a stale copy)
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

-- ---- command line ---------------------------------------------------------

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then qerror('tarrasque can only be enabled in fortress mode') end
    load_state()
    if dfhack_flags.enable_state then start() else stop() end
    state.enabled = enabled
    save_state()
    print('tarrasque: ' .. (enabled and ('enabled -- maintaining >= %d living forgotten beasts'):format(state.target) or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then qerror('tarrasque only works in fortress mode') end
load_state()

local args = {...}
local cmd = args[1]

if cmd == 'revive' then
    local n = args[2]
    if n == 'all' then n = nil
    elseif n then n = tonumber(n); if not n or n < 1 then qerror('revive count must be a positive integer or "all"') end
    else n = 1 end
    local revived = revive_up_to(n)
    if #revived == 0 then
        print('tarrasque: no revivable dead forgotten beasts (they need a unit that still exists).')
    else
        print(('tarrasque: revived %d forgotten beast%s:'):format(#revived, #revived == 1 and '' or 's'))
        for _, nm in ipairs(revived) do print('  + ' .. nm) end
    end
elseif cmd == 'target' then
    local n = tonumber(args[2])
    if not n or n < 0 then qerror('target must be a non-negative integer') end
    state.target = math.floor(n)
    save_state()
    print(('tarrasque: will keep at least %d forgotten beast%s alive while enabled.'):format(
        state.target, state.target == 1 and '' or 's'))
    if enabled then pcall(do_cycle) end
else
    -- status
    local alive, dead, revivable = survey()
    print(('tarrasque: %s'):format(enabled and ('ENABLED (maintaining >= %d alive)'):format(state.target) or 'disabled'))
    print(('  forgotten beasts: %d alive, %d dead'):format(alive, dead))
    print(('  revivable now   : %d (dead beasts whose unit still exists)'):format(#revivable))
    if not enabled then
        print('  `tarrasque revive [N|all]` to revive now, or `enable tarrasque` to auto-maintain.')
    end
end
