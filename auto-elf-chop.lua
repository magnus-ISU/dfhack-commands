-- Gate the base `autochop` plugin by the elves' tree-cutting limit.
--@module = true
--@enable = true
--[[
auto-elf-chop

The stock `autochop` plugin keeps your log stock topped up by designating trees for chopping --
but it has no idea the elves have capped how many trees you may fell per year, so left alone it
will happily blow past that cap and sour (or end) relations. This does NOT modify autochop; it
sits on top of it and switches the base plugin on and off to keep your yearly tree count under the
elven limit.

The limit is READ from the game, not guessed: it's the elven tree-cutting cap from your world's
difficulty settings -- `plotinfo.main.custom_difficulty.tree_fell_count` (a.k.a. `diplomacy_tree_cap`,
the "total allowed cuts" the World > Civilizations agreements screen shows), or its high-savagery
variant `tree_fell_count_savage` when your embark is savage (savagery >= 66). You can still pin a
fixed number by hand with `auto-elf-chop limit N` if you'd rather not track the game value.

How it works:
  * While trees-cut-this-year is UNDER the limit, it enables autochop, so autochop maintains your
    logs as normal.
  * The moment trees-cut-this-year reaches the limit, it DISABLES autochop *and* undesignates all
    pending tree-chop jobs, so no more trees come down this year -- even the batch autochop already
    queued toward its wood target. (Undesignate clears every chop designation on the map, so this
    assumes autochop is your only source of chop designations. If you mark trees by hand, they'll
    be cleared too.)
  * At the start of each in-game year the count resets to 0 and autochop is allowed to run again.

"Trees cut this year" is measured from `plotinfo.trees_removed` (the running total of trees removed
from the map) captured at the start of each year. If the elves reset your quota mid-year (e.g. a new
caravan renegotiates), run `auto-elf-chop reset` to zero the count immediately.

Usage:
    enable auto-elf-chop        start gating autochop by the limit (persists with the fort)
    disable auto-elf-chop       stop gating (autochop is left in whatever state it's in)
    auto-elf-chop               show status: limit (+ source), cut this year, remaining, gate state
    auto-elf-chop auto          read the limit from the game's elven tree cap (the default)
    auto-elf-chop limit <N>     pin the annual tree-cutting limit to a fixed N (overrides auto)
    auto-elf-chop reset         reset this year's cut count to 0 right now

While enabled, let auto-elf-chop own autochop's on/off state -- don't toggle autochop by hand or the
two will fight.
]]

local GLOBAL_KEY = 'auto-elf-chop'
local CHECK_FRAMES = 100        -- how often (in frames) the watcher re-checks the count
local SAVAGE_THRESHOLD = 66     -- DF savagery >= this counts as "savage" (high third, 66-99)

-- ---- persisted config -----------------------------------------------------
-- state = { enabled, mode, limit, year_baseline, last_year }
--   mode  = 'auto' (read the elven cap from the game) or 'manual' (use `limit`)
--   limit = the fixed cap used in manual mode
--   year_baseline = trees_removed captured at the start of last_year, so
--   cut_this_year = trees_removed - year_baseline.
state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY,
            {enabled = false, mode = 'auto', limit = 5, year_baseline = -1, last_year = -1})
    end
    return state
end

local function save_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

-- ---- reading the elven tree cap from the game -----------------------------

-- is the fort's world tile high-savagery? (cached -- savagery doesn't change)
local savage_cache = nil
local function fort_is_savage()
    if savage_cache ~= nil then return savage_cache end
    savage_cache = false
    pcall(function()
        local site = df.world_site.find(df.global.plotinfo.site_id)
        if not site then return end
        local wd = df.global.world.world_data
        local sav
        local ok = pcall(function() sav = wd.region_map[site.pos.x]:_displace(site.pos.y).savagery end)
        if not ok then sav = wd.region_map[site.pos.x][site.pos.y].savagery end
        savage_cache = (sav >= SAVAGE_THRESHOLD)
    end)
    return savage_cache
end

-- the elven tree-cutting cap from difficulty settings (savage variant on savage embarks), or nil
local function read_elf_cap()
    local ok, cap = pcall(function()
        local cd = df.global.plotinfo.main.custom_difficulty
        return fort_is_savage() and cd.tree_fell_count_savage or cd.tree_fell_count
    end)
    if ok and type(cap) == 'number' and cap >= 0 then return cap end
    return nil
end

-- the limit in force right now, plus a short source tag for status
local function effective_limit()
    load_state()
    if state.mode == 'manual' then return state.limit, 'manual' end
    local cap = read_elf_cap()
    if cap then return cap, 'elven agreement' end
    return state.limit, 'fallback (could not read elven cap)'
end

-- ---- driving the base autochop plugin -------------------------------------

local function autochop_enable(on)
    -- `enable`/`disable` are built-ins; toggling is idempotent
    dfhack.run_command(on and 'enable' or 'disable', 'autochop')
end

local function autochop_undesignate()
    local ok, ac = pcall(require, 'plugins.autochop')
    if ok and ac and ac.parse_commandline then
        pcall(ac.parse_commandline, 'undesignate')
    end
end

-- true / false, or nil if autochop's state can't be read
local function autochop_is_enabled()
    local ok, ac = pcall(require, 'plugins.autochop')
    if ok and ac and ac.isEnabled then
        local ok2, v = pcall(ac.isEnabled)
        if ok2 then return v and true or false end
    end
    return nil
end

-- ---- yearly cut tracking --------------------------------------------------

-- trees felled since the start of the current in-game year; rolls the baseline
-- over when the year changes so the count resets to 0 each year.
local function trees_cut_this_year()
    load_state()
    local removed = df.global.plotinfo.trees_removed
    local y = df.global.cur_year
    if y ~= state.last_year or state.year_baseline < 0 then
        state.last_year = y
        state.year_baseline = removed
        save_state()
    end
    local cut = removed - state.year_baseline
    if cut < 0 then                 -- shouldn't happen, but never report negative
        cut = 0
        state.year_baseline = removed
        save_state()
    end
    return cut
end

-- ---- background watcher ---------------------------------------------------

enabled = enabled or false
function isEnabled()
    return enabled
end

local hb_gen = 0            -- generation guard so only the newest heartbeat survives
local last_want = nil       -- fallback dedup when autochop's real state can't be read

-- Bring autochop's on/off state in line with the limit. Reads autochop's ACTUAL
-- state and only acts when it diverges, so it self-corrects if autochop is toggled
-- out from under us, and never spams enable/disable when already correct.
-- (Global so it can be poked via reqscript; the heartbeat calls it on a timer.)
function do_check()
    if not dfhack.world.isFortressMode() then return end
    local cut = trees_cut_this_year()
    local limit = effective_limit()
    local want = cut < limit
    local actual = autochop_is_enabled()
    local need
    if actual == nil then need = (want ~= last_want) else need = (want ~= actual) end
    if need then
        autochop_enable(want)
        if not want then autochop_undesignate() end   -- clear the pending batch at the cap
        last_want = want
        print(('auto-elf-chop: %d/%d trees cut this year -- autochop %s'):format(
            cut, limit, want and 'ENABLED' or 'DISABLED (limit reached)'))
    end
end

-- Per-frame heartbeat that acts every CHECK_FRAMES frames. A 'frames' timeout is
-- used (not repeat-util) so the check is prompt and does not fire while paused --
-- which is fine, since trees are only felled while unpaused too.
local function start()
    enabled = true
    last_want = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local n = 0
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        n = n + 1
        if n >= CHECK_FRAMES then n = 0; pcall(do_check) end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    pcall(do_check)   -- act immediately on enable, don't wait a full cycle
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1     -- orphan the running heartbeat
    -- deliberately leave autochop wherever it is; the user regains manual control
end

-- ---- lifecycle ------------------------------------------------------------

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, last_want, savage_cache = nil, nil, nil
        load_state()
        if dfhack.world.isFortressMode() and state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, last_want, savage_cache = nil, nil, nil
    end
end

-- exported so it can be driven via reqscript (the `enable` command path can serve
-- a stale cached copy on this build)
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
    if not dfhack.world.isFortressMode() then
        qerror('auto-elf-chop can only be enabled in fortress mode')
    end
    load_state()
    if dfhack_flags.enable_state then start() else stop() end
    state.enabled = enabled
    save_state()
    print('auto-elf-chop: ' .. (enabled and 'enabled (background)' or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then
    qerror('auto-elf-chop only works in fortress mode')
end
load_state()

local args = {...}
local cmd = args[1]

if cmd == 'limit' then
    local n = tonumber(args[2])
    if not n or n < 0 then qerror('limit must be a non-negative integer') end
    state.mode = 'manual'
    state.limit = math.floor(n)
    save_state()
    last_want = nil                              -- force the gate to re-evaluate
    print(('auto-elf-chop: annual tree-cutting limit pinned to %d (manual mode)'):format(state.limit))
    if enabled then pcall(do_check) end
elseif cmd == 'auto' then
    state.mode = 'auto'
    save_state()
    last_want = nil
    local cap = read_elf_cap()
    print('auto-elf-chop: reading the limit from the elven tree cap' ..
        (cap and (' (currently %d)'):format(cap) or ' (could not read it right now)'))
    if enabled then pcall(do_check) end
elseif cmd == 'reset' then
    state.year_baseline = df.global.plotinfo.trees_removed
    state.last_year = df.global.cur_year
    save_state()
    last_want = nil
    print('auto-elf-chop: this year\'s tree-cut count reset to 0')
    if enabled then pcall(do_check) end
else
    -- status (default, and for any unrecognised command)
    local cut = trees_cut_this_year()
    local limit, src = effective_limit()
    print(('auto-elf-chop: %s'):format(enabled and 'ENABLED (background)' or 'disabled'))
    print(('  limit        : %d trees/year  (source: %s)'):format(limit, src))
    print(('  cut this year: %d  (%d remaining)'):format(cut, math.max(0, limit - cut)))
    print(('  autochop gate: should be %s at the current count'):format(
        cut < limit and 'ON' or 'OFF (limit reached)'))
    -- show the raw game values so you can sanity-check against the Agreements screen
    local ok = pcall(function()
        local cd = df.global.plotinfo.main.custom_difficulty
        print(('  elven cap    : %d normal / %d savage; this embark is %s'):format(
            cd.tree_fell_count, cd.tree_fell_count_savage,
            fort_is_savage() and 'SAVAGE (uses the savage cap)' or 'not savage (uses the normal cap)'))
    end)
    local ac_on = autochop_is_enabled()
    if ac_on ~= nil then
        print(('  base autochop: currently %s'):format(ac_on and 'enabled' or 'disabled'))
    end
    if not enabled then
        print('  run `enable auto-elf-chop` to start gating autochop.')
    end
end
