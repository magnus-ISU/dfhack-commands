-- A hive asks for a colony the moment it is built, so bees actually move in.
--@module = true
--@enable = true
--[[
better-hives

A BEEHIVE DOES NOTHING UNTIL YOU TICK "INSTALL A COLONY". A fort built fourteen of them,
each finished and holding its glass hive, with ten wild honey-bee colonies on the surface and
eighty-eight beekeepers -- and not one hive had a colony in it, because that flag is off on
every hive DF places and nobody had opened all fourteen to switch it on. DF never sets it
itself: the hive sits empty forever, looking like a finished piece of infrastructure.

So this switches it on for you, ONCE, when the hive is finished: a hive that has just gone
up asks for a colony, a beekeeper carries one in, and the fort's bee industry starts on
its own the way its other industries do.

ONCE IS THE WHOLE POINT. It is a nudge, not a policy. A hive that already has its colony,
that you have turned back off by hand, or that you want kept empty on purpose (a hive left
without a colony is how you stop a split) is never touched again: each hive gets exactly
one nudge, the first time it is seen finished, and that hive's id is then remembered with
the fort. Turning the flag off afterwards STAYS off.

Only a hive that is actually BUILT counts. While it is a construction site it has no
`do_install` to speak of, so the flag is set the first time the building stage says it is
done -- which is also what makes this fire at the right moment rather than on a stack of
planned hives.

Usage:
    enable fort/better-hives      watch for finished hives (a pass every game day)
    disable fort/better-hives     stop watching
    fort/better-hives             status, and nudge any finished hive not yet seen
]]

local GLOBAL_KEY = 'better-hives'
local CYCLE_TICKS = 1200          -- a pass a game day: a hive takes days to build anyway

-- ---- state: which hives have had their one nudge ------------------------------

state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, seen = {}})
        state.seen = type(state.seen) == 'table' and state.seen or {}
    end
    return state
end

local function save_state() pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, state) end

-- ---- the nudge --------------------------------------------------------------------

local function finished(bld)
    local ok, done = pcall(function() return bld:getBuildStage() >= bld:getMaxBuildStage() end)
    return ok and done
end

-- every finished hive this fort has not nudged yet: set do_install, remember it.
-- Returns how many were nudged.
local function nudge_new_hives()
    local s = load_state()
    local n = 0
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_hivest:is_instance(bld) and finished(bld) then
            local key = tostring(bld.id)
            if not s.seen[key] then
                s.seen[key] = true
                if not bld.hive_flags.do_install then
                    bld.hive_flags.do_install = true
                    n = n + 1
                end
            end
        end
    end
    -- forget hives that no longer exist, so the record does not grow with every rebuild
    for key in pairs(s.seen) do
        if not df.building.find(tonumber(key)) then s.seen[key] = nil end
    end
    if n > 0 or next(s.seen) then save_state() end
    return n
end

-- ---- service --------------------------------------------------------------------

enabled = enabled or false
function isEnabled() return enabled end

local last_run, hb_gen = nil, 0

local function do_cycle()
    if not dfhack.world.isFortressMode() then return end
    local n = nudge_new_hives()
    if n > 0 then
        print(('better-hives: %d new hive%s set to install a colony'):format(n, n == 1 and '' or 's'))
    end
end

-- per-frame heartbeat gated on the game calendar, the shape training-barracks uses:
-- repeat-util day timeouts are frame-counted on this build
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

function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        load_state()
        if dfhack.world.isFortressMode() and state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state = nil
    end
end

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then
        qerror('better-hives can only be enabled in fortress mode')
    end
    set_enabled(dfhack_flags.enable_state)
    print('better-hives: ' .. (enabled and 'enabled (a pass every game day)' or 'disabled'))
else
    if not dfhack.world.isFortressMode() then
        qerror('better-hives only works in fortress mode')
    end
    local hives, installing, colonised = 0, 0, 0
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_hivest:is_instance(bld) and finished(bld) then
            hives = hives + 1
            if bld.hive_flags.do_install then installing = installing + 1 end
            if bld.install_timer == 0 and bld.activity_timer > 0 then colonised = colonised + 1 end
        end
    end
    local n = nudge_new_hives()
    print(('better-hives: %s -- %d finished hive%s, %d asking for a colony'):format(
        enabled and 'enabled' or 'not running', hives, hives == 1 and '' or 's', installing + n))
    if n > 0 then
        print(('  %d hive%s just set to install a colony'):format(n, n == 1 and '' or 's'))
    end
end
