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

IT FIRES ON THE BUILD ITSELF, not on a timer. The job that raises a hive is a
`ConstructBuilding` job carrying a reference to the building it is raising, and DFHack's
JOB_COMPLETED event hands that job over the moment the builder finishes. So the flag goes on
in the same tick the hive becomes a hive, and nothing is scanned in between. A hive that
was already finished when this was switched on -- or built while it was off -- is caught
once, on enable, by a single pass over the fort's buildings; after that the event is the
whole mechanism.

Usage:
    enable fort/better-hives      nudge each hive as it is finished
    disable fort/better-hives     stop
    fort/better-hives             status, and nudge any finished hive not yet seen
]]

local GLOBAL_KEY = 'better-hives'

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

-- the one nudge a hive gets. Returns true if the flag was actually switched on.
local function nudge(bld)
    local s = load_state()
    local key = tostring(bld.id)
    if s.seen[key] then return false end
    s.seen[key] = true
    local did = false
    if not bld.hive_flags.do_install then
        bld.hive_flags.do_install = true
        did = true
    end
    save_state()
    return did
end

-- the building a ConstructBuilding job was raising, if it was a hive
local function hive_of(job)
    if job.job_type ~= df.job_type.ConstructBuilding then return nil end
    for _, r in ipairs(job.general_refs) do
        if r:getType() == df.general_ref_type.BUILDING_HOLDER then
            local bld = df.building.find(r.building_id)
            if bld and df.building_hivest:is_instance(bld) then return bld end
        end
    end
end

-- every finished hive this fort has not nudged yet: the catch-up pass, run once on enable
-- and from the command line. Returns how many were nudged.
local function nudge_new_hives()
    local s = load_state()
    local n = 0
    for _, bld in ipairs(df.global.world.buildings.all) do
        if df.building_hivest:is_instance(bld) and finished(bld) and nudge(bld) then
            n = n + 1
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

local eventful = require('plugins.eventful')

-- JOB_COMPLETED fires after DF has finished the job -- for ConstructBuilding, after the
-- building's stage has been advanced -- so the hive is a hive by the time this runs.
-- Registered under our own key: a reload replaces the handler rather than stacking one.
local function on_job_completed(job)
    local ok, bld = pcall(hive_of, job)
    if ok and bld and finished(bld) and nudge(bld) then
        print(('better-hives: hive %d finished -- set to install a colony'):format(bld.id))
    end
end

local function start()
    enabled = true
    eventful.enableEvent(eventful.eventType.JOB_COMPLETED, 5)
    eventful.onJobCompleted[GLOBAL_KEY] = on_job_completed
    -- anything finished while we were not listening
    local n = nudge_new_hives()
    if n > 0 then
        print(('better-hives: %d hive%s already finished set to install a colony'):format(n, n == 1 and '' or 's'))
    end
end

local function stop()
    enabled = false
    eventful.onJobCompleted[GLOBAL_KEY] = nil
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
    print('better-hives: ' .. (enabled and 'enabled (fires as each hive is finished)' or 'disabled'))
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
