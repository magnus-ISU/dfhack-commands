-- Keeps skill rust off retired adventurers living in your fort.
--@module = true
--@enable = true
--[[
fort/rusty-adventurers

An adventurer you retired into the fort arrives with a lifetime of skills and then
sits in a dining room losing them. This scrubs skill rust off those units -- and
only those units -- so a retired hero stays the hero you played.

    rusty-adventurers            clear rust now, and report who was scrubbed
    enable rusty-adventurers     keep it clear (swept once a game year; persists with
                                 the fort and re-arms on load)
    disable rusty-adventurers    stop
    rusty-adventurers list       who counts as an adventurer, and how rusty they are

**Who counts.** Not "everyone with a lot of skills" and not a name list: a unit
qualifies when its nemesis record carries the `ADVENTURER` flag (or
`ACTIVE_ADVENTURER`), which is the same marker DF uses to paint a figure blue and
write "guided by forces unknown" in legends mode. Worldgen heroes and ordinary
migrants never have it, so no dwarf gets scrubbed by accident. Both fort citizens
and adventurers merely visiting are covered.

**What it clears.** Per skill: `rusty` (the rust level that greys the skill and
drags the effective rating down), `rust_counter` and `demotion_counter` (progress
toward more rust and toward losing a level outright), and `unused_counter` (the
idle timer that feeds the other two). Ratings and experience are never touched --
this removes decay, it does not grant skill, and it cannot give back levels a unit
had already been demoted out of before you turned it on.

There is no stock DFHack tool for this: `gui/gm-unit`'s `remove_rust` is an empty
`--TODO` stub and `modtools/skill-change` says `--TODO: skill rust?` at the top of
the file. DF exposes no per-unit or global "no rust" switch either, so the counters
have to be re-zeroed on a timer.
]]

local GLOBAL_KEY = 'rusty-adventurers'

local ADVENTURER = df.nemesis_flags.ADVENTURER
local ACTIVE_ADVENTURER = df.nemesis_flags.ACTIVE_ADVENTURER

local TICKS_PER_YEAR = 403200

-- One game year. Rust does still creep in between sweeps -- a skill left unused for
-- a season or two will show as rusty until the next check comes round and wipes it,
-- rather than never appearing at all. That is the trade for a once-a-year scan
-- instead of a daily one; the skills themselves are never actually lost, since
-- demotion_counter is cleared long before it can mature into a lost level.
local CYCLE_TICKS = TICKS_PER_YEAR

-- ---------------------------------------------------------------------------
-- who is an adventurer
-- ---------------------------------------------------------------------------

-- The nemesis record is where DF marks a figure as having been played. `ADVENTURER`
-- is set for good once a unit has been an adventurer; `ACTIVE_ADVENTURER` marks the
-- one currently being controlled. Checking both means a unit still swapped-to in
-- tactical mode is covered too.
local function is_adventurer(unit)
    local nem = dfhack.units.getNemesis(unit)
    if not nem then return false end
    return nem.flags[ADVENTURER] or nem.flags[ACTIVE_ADVENTURER]
end

-- `units.active` is the bounded list (hundreds), never `units.all` -- this runs on
-- DF's main thread and a full unit scan would stall the game.
local function adventurers()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isAlive(u) and is_adventurer(u) then out[#out + 1] = u end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- scrubbing rust
-- ---------------------------------------------------------------------------

local function rusty_skills(unit)
    local soul = unit.status.current_soul
    if not soul then return 0 end
    local n = 0
    for _, s in ipairs(soul.skills) do
        if s.rusty > 0 or s.rust_counter > 0 or s.demotion_counter > 0 then n = n + 1 end
    end
    return n
end

-- returns how many of this unit's skills had rust to clear
local function scrub(unit)
    local soul = unit.status.current_soul
    if not soul then return 0 end
    local n = 0
    for _, s in ipairs(soul.skills) do
        if s.rusty > 0 or s.rust_counter > 0 or s.demotion_counter > 0 then n = n + 1 end
        -- zero all four every pass, not just the ones already showing rust: clearing
        -- `unused_counter` before it matures is what stops the next round of rust
        -- from starting, rather than mopping it up after it lands
        s.rusty = 0
        s.rust_counter = 0
        s.demotion_counter = 0
        s.unused_counter = 0
    end
    return n
end

-- returns list of {unit, name, cleared}
function clear_rust()
    local done = {}
    for _, u in ipairs(adventurers()) do
        local cleared = scrub(u)
        done[#done + 1] = {unit = u, name = dfhack.units.getReadableName(u), cleared = cleared}
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
-- daily service would need. cur_year_tick also runs BACKWARDS under timestream, so
-- a negative delta counts as "the clock moved" and re-arms instead of wedging.
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

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode()
            and dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false}).enabled
        then
            start()
        end
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

if dfhack_flags.module then return end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if not dfhack.world.isFortressMode() then
    qerror('rusty-adventurers only works in fortress mode')
end

local args = {...}

if args[1] == 'list' then
    local found = adventurers()
    if #found == 0 then
        print('rusty-adventurers: no adventurers in this fort.')
    else
        print(('rusty-adventurers: %d adventurer%s'):format(#found, #found == 1 and '' or 's'))
        for _, u in ipairs(found) do
            print(('  %s -- %d rusty skill%s%s'):format(
                dfhack.units.getReadableName(u), rusty_skills(u),
                rusty_skills(u) == 1 and '' or 's',
                dfhack.units.isCitizen(u) and '' or ' (not a citizen)'))
        end
    end
    print(('service is %s'):format(enabled and 'ON' or 'OFF'))
    return
end

if dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print(('rusty-adventurers: %s'):format(enabled and
        'ON -- rust cleared once a game year' or 'OFF'))
    if enabled then
        local n = #adventurers()
        if n == 0 then
            dfhack.printerr('  no adventurers found in this fort yet; nothing to keep clear')
        end
    end
    return
end

-- bare invocation: a one-shot scrub
local done = clear_rust()
if #done == 0 then
    print('rusty-adventurers: no adventurers in this fort.')
    return
end
for _, d in ipairs(done) do
    print(('rusty-adventurers: %s -- cleared rust on %d skill%s'):format(
        d.name, d.cleared, d.cleared == 1 and '' or 's'))
end
if not enabled then
    print('Run `enable rusty-adventurers` to keep it clear as it re-accumulates.')
end
