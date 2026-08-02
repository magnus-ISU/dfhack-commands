-- Keeps skill rust off the people it would hurt most: retired adventurers, and
-- anyone's legendary skills.
--@module = true
--@enable = true
--[[
fort/rusty-legends

Two kinds of hard-won skill rot away while their owner does something else: an
adventurer you retired into the fort, who arrived with a lifetime of skills and now
sits in a dining room, and any legendary craftsdwarf pulled onto hauling for a
season. This scrubs skill rust off both -- and nothing else.

    rusty-legends            clear rust now, and report who was scrubbed
    enable rusty-legends     keep it clear (swept once a game year; persists with
                             the fort and re-arms on load)
    disable rusty-legends    stop
    rusty-legends list       who qualifies, and how rusty they are

**Who counts.**

  * *Adventurers* -- every skill they have. A unit qualifies when its nemesis
    record carries the `ADVENTURER` flag (or `ACTIVE_ADVENTURER`), the same marker
    DF uses to paint a figure blue and write "guided by forces unknown" in legends
    mode. It is not a name list and not a skill count, so no ordinary dwarf is
    caught by it; worldgen heroes and migrants do not have the flag. Adventurers
    count whether or not they are citizens.
  * *Legendary skills* -- on any citizen, only the skills at Legendary or above
    (rating 15+, i.e. Legendary through Legendary5). Everything else that dwarf
    knows rusts normally.

**What it clears.** Per qualifying skill: `rusty` (the rust level that greys the
skill and drags the effective rating down), `rust_counter` and `demotion_counter`
(progress toward more rust and toward losing a level outright), and `unused_counter`
(the idle timer that feeds the other two). Ratings and experience are never touched
-- this removes decay, it does not grant skill, and it cannot give back levels a
unit was already demoted out of before you turned it on.

Rust does still appear between yearly sweeps: a skill left unused for a season or
two shows as rusty until the next check wipes it, rather than never appearing at
all. Nothing is actually lost, because `demotion_counter` is cleared long before it
can mature into a lost level.

There is no stock DFHack tool for any of this: `gui/gm-unit`'s `remove_rust` is an
empty `--TODO` stub and `modtools/skill-change` says `--TODO: skill rust?` at the
top of the file. DF exposes no per-unit or global "no rust" switch either, so the
counters have to be re-zeroed on a timer.
]]

local GLOBAL_KEY = 'rusty-legends'
local OLD_KEY = 'rusty-adventurers'   -- this tool's name before it grew legendary skills

local ADVENTURER = df.nemesis_flags.ADVENTURER
local ACTIVE_ADVENTURER = df.nemesis_flags.ACTIVE_ADVENTURER

-- Legendary is 15; Legendary1..Legendary5 run 16..20, so anything at or above the
-- base rank counts.
local LEGENDARY = df.skill_rating.Legendary

local TICKS_PER_YEAR = 403200

-- One game year. Rust accrues over seasons; sweeping yearly keeps the skills
-- themselves safe (demotion_counter never matures) at a fraction of the scan cost of
-- a daily pass, at the price of rust being briefly visible in between.
local CYCLE_TICKS = TICKS_PER_YEAR

-- ---------------------------------------------------------------------------
-- who qualifies
-- ---------------------------------------------------------------------------

-- The nemesis record is where DF marks a figure as having been played -- there is no
-- adventurer bit on unit.flags or on the historical figure. `ADVENTURER` is set for
-- good once a unit has been an adventurer; `ACTIVE_ADVENTURER` marks the one being
-- controlled right now, so checking both covers a tactical-mode swap too.
local function is_adventurer(unit)
    local nem = dfhack.units.getNemesis(unit)
    if not nem then return false end
    return nem.flags[ADVENTURER] or nem.flags[ACTIVE_ADVENTURER]
end

-- 'all' scrubs every skill, 'legendary' only the ones at Legendary+, nil skips the
-- unit entirely (visitors, merchants, invaders, animals).
local function scope_for(unit)
    if is_adventurer(unit) then return 'all' end
    if dfhack.units.isCitizen(unit) then return 'legendary' end
    return nil
end

-- `units.active` is the bounded list (hundreds), never `units.all` -- this runs on
-- DF's main thread and a full unit scan would stall the game.
local function targets()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isAlive(u) and u.status.current_soul then
            local scope = scope_for(u)
            if scope then out[#out + 1] = {unit = u, scope = scope} end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- scrubbing rust
-- ---------------------------------------------------------------------------

-- A skill is in scope when the whole unit is ('all'), or when it is legendary in its
-- own right. This reads the CURRENT rating: a skill already demoted out of Legendary
-- before this tool ever ran is no longer legendary and stops being protected, which
-- is the honest reading -- we never invent back a rank DF took away.
local function in_scope(skill, scope)
    return scope == 'all' or skill.rating >= LEGENDARY
end

local function is_rusty(s)
    return s.rusty > 0 or s.rust_counter > 0 or s.demotion_counter > 0
end

-- returns how many in-scope skills actually had rust on them
local function scrub(unit, scope)
    local n = 0
    for _, s in ipairs(unit.status.current_soul.skills) do
        if in_scope(s, scope) then
            if is_rusty(s) then n = n + 1 end
            -- zero all four every pass, not only where rust already shows: clearing
            -- unused_counter before it matures is what stops the next round starting,
            -- rather than mopping up after it lands
            s.rusty = 0
            s.rust_counter = 0
            s.demotion_counter = 0
            s.unused_counter = 0
        end
    end
    return n
end

local function rusty_count(unit, scope)
    local n = 0
    for _, s in ipairs(unit.status.current_soul.skills) do
        if in_scope(s, scope) and is_rusty(s) then n = n + 1 end
    end
    return n
end

-- returns a list of {name, scope, cleared}: every adventurer, plus any citizen that
-- actually had legendary rust to remove
function clear_rust()
    local done = {}
    for _, t in ipairs(targets()) do
        local cleared = scrub(t.unit, t.scope)
        if cleared > 0 or t.scope == 'all' then
            done[#done + 1] = {name = dfhack.units.getReadableName(t.unit),
                               scope = t.scope, cleared = cleared}
        end
    end
    return done
end

-- ---------------------------------------------------------------------------
-- the service
-- ---------------------------------------------------------------------------

enabled = enabled or false
local last_run = nil
local hb_gen = 0            -- generation guard so only the newest heartbeat survives

function isEnabled() return enabled end

local function now_abs()
    return df.global.cur_year * TICKS_PER_YEAR + df.global.cur_year_tick
end

-- Driven off a heartbeat gated on the game calendar rather than repeat-util's
-- day/tick timeouts: on this build those count rendered frames and fire far off
-- schedule. A yearly cycle needs no precision, so the heartbeat is coarse -- a few
-- seconds of real time between calendar checks, rather than the every-frame beat a
-- daily service would need. cur_year_tick also runs BACKWARDS under timestream, so a
-- negative delta counts as "the clock moved" and re-arms instead of wedging.
local HEARTBEAT_FRAMES = 500

local function start()
    enabled = true
    last_run = nil          -- sweep on the very next heartbeat
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = now_abs()
        if not last_run or now < last_run or now - last_run >= CYCLE_TICKS then
            last_run = now
            pcall(clear_rust)
        end
        dfhack.timeout(HEARTBEAT_FRAMES, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1     -- invalidate any running heartbeat loop
end

-- exported so it can be driven via reqscript (the `enable` command goes through
-- run_script, which on this build can serve a stale cached copy)
function set_enabled(on)
    if on then start() else stop() end
    enabled = on
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {enabled = enabled})
    return enabled
end

-- A fort switched on while this tool was still called rusty-adventurers has its flag
-- filed under the old key. Adopt it once and drop the stale entry, so renaming the
-- tool doesn't quietly turn it off on saves that already had it running.
local function load_persisted()
    local cur = dfhack.persistent.getSiteData(GLOBAL_KEY)
    if cur and cur.enabled ~= nil then return cur.enabled end
    local old = dfhack.persistent.getSiteData(OLD_KEY)
    if old and old.enabled ~= nil then
        pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {enabled = old.enabled})
        pcall(dfhack.persistent.deleteSiteData, OLD_KEY)
        return old.enabled
    end
    return false
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode() and load_persisted() then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

if dfhack_flags.module then return end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if not dfhack.world.isFortressMode() then
    qerror('rusty-legends only works in fortress mode')
end

local args = {...}

if args[1] == 'list' then
    local advs, legs = {}, {}
    for _, t in ipairs(targets()) do
        local n = rusty_count(t.unit, t.scope)
        if t.scope == 'all' then advs[#advs + 1] = {t = t, n = n}
        elseif n > 0 then legs[#legs + 1] = {t = t, n = n} end
    end
    if #advs == 0 then
        print('rusty-legends: no adventurers in this fort.')
    else
        print(('rusty-legends: %d adventurer%s (all skills protected)')
            :format(#advs, #advs == 1 and '' or 's'))
        for _, e in ipairs(advs) do
            print(('  %s -- %d rusty skill%s%s'):format(
                dfhack.units.getReadableName(e.t.unit), e.n, e.n == 1 and '' or 's',
                dfhack.units.isCitizen(e.t.unit) and '' or ' (not a citizen)'))
        end
    end
    if #legs == 0 then
        print('rusty-legends: no citizen has a rusty legendary skill.')
    else
        print(('rusty-legends: %d citizen%s with rusty legendary skills')
            :format(#legs, #legs == 1 and '' or 's'))
        for _, e in ipairs(legs) do
            print(('  %s -- %d rusty legendary skill%s'):format(
                dfhack.units.getReadableName(e.t.unit), e.n, e.n == 1 and '' or 's'))
        end
    end
    print(('service is %s'):format(enabled and 'ON' or 'OFF'))
    return
end

if dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print(('rusty-legends: %s'):format(enabled and
        'ON -- rust cleared once a game year' or 'OFF'))
    return
end

-- bare invocation: a one-shot scrub
local done = clear_rust()
if #done == 0 then
    print('rusty-legends: nobody in this fort qualifies.')
    return
end
local total = 0
for _, d in ipairs(done) do
    total = total + d.cleared
    print(('rusty-legends: %s -- cleared rust on %d %sskill%s'):format(
        d.name, d.cleared, d.scope == 'legendary' and 'legendary ' or '',
        d.cleared == 1 and '' or 's'))
end
if total == 0 then print('  (nothing was rusty)') end
if not enabled then
    print('Run `enable rusty-legends` to keep it clear as it re-accumulates.')
end
