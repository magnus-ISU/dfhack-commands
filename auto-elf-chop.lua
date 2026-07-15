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

The limit is READ from the game -- the actual per-year figure the World > Civilizations agreements
screen shows ("Lumber limits N/N"), which the elven diplomat renegotiates each year (it can be 5 one
year, 4 / 7 / 32 another). It's the `TreeQuota` meeting_event on the elven civilization's
`historical_entity.meeting_events`: `quota_total` is the year's cap and `quota_remaining` is how many
fells you have left. We gate directly on `quota_remaining`, so it stays correct as you cut and resets
itself whenever the elves agree a new quota -- no manual bookkeeping. You can still pin a fixed number
by hand with `auto-elf-chop limit N` (e.g. if you have no elf agreement).

How it works:
  * While the elves' remaining lumber allowance is > 0, it enables autochop, so autochop maintains
    your logs as normal.
  * The moment the remaining allowance hits 0, it DISABLES autochop *and* undesignates all pending
    tree-chop jobs, so no more trees come down this year -- even the batch autochop already queued
    toward its wood target. (Undesignate clears every chop designation on the map, so this assumes
    autochop is your only source of chop designations. If you mark trees by hand, they'll be cleared
    too.)
  * When the elves renegotiate (a fresh quota), the remaining allowance jumps back up and autochop is
    allowed to run again.

Usage:
    enable auto-elf-chop        start gating autochop by the limit (persists with the fort)
    disable auto-elf-chop       stop gating (autochop is left in whatever state it's in)
    auto-elf-chop               show status: quota, remaining, gate state
    auto-elf-chop auto          read the limit from the elven lumber agreement (the default)
    auto-elf-chop limit <N>     pin the annual tree-cutting limit to a fixed N (overrides auto)
    auto-elf-chop reset         (manual mode only) reset this year's cut count to 0 right now

While enabled, let auto-elf-chop own autochop's on/off state -- don't toggle autochop by hand or the
two will fight.
]]

local GLOBAL_KEY = 'auto-elf-chop'
local CHECK_FRAMES = 100        -- how often (in frames) the watcher re-checks the count

-- ---- persisted config -----------------------------------------------------
-- state = { enabled, mode, limit, year_baseline, last_year }
--   mode  = 'auto' (read the elven lumber agreement) or 'manual' (use `limit`)
--   limit = the fixed cap used in manual mode
--   year_baseline / last_year = trees_removed at the start of last_year (manual-mode counting only)
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

-- ---- reading the elven lumber agreement -----------------------------------
-- The elves' tree quota is a TreeQuota meeting_event on the elven civ's historical_entity:
-- quota_total = this year's cap, quota_remaining = fells left. (Verified: it matches the
-- "Lumber limits N/N ... Agreed in year Y" line on World > Civilizations.) We cache which
-- entity/index holds it so the per-cycle read is one lookup, and re-scan if it moves.
local quota_cache = nil     -- {eid, idx}

local function read_agreement()
    if quota_cache then
        local e = df.historical_entity.find(quota_cache.eid)
        if e then
            local ok, m = pcall(function() return e.meeting_events[quota_cache.idx] end)
            if ok and m and m.topic == df.meeting_topic.TreeQuota then
                return {total = m.quota_total, remaining = m.quota_remaining, year = m.year, eid = quota_cache.eid}
            end
        end
        quota_cache = nil
    end
    for _, e in ipairs(df.global.world.entities.all) do
        local ok, n = pcall(function() return #e.meeting_events end)
        if ok then
            for i = 0, n - 1 do
                local okm, is_tq = pcall(function() return e.meeting_events[i].topic == df.meeting_topic.TreeQuota end)
                if okm and is_tq then
                    local m = e.meeting_events[i]
                    quota_cache = {eid = e.id, idx = i}
                    return {total = m.quota_total, remaining = m.quota_remaining, year = m.year, eid = e.id}
                end
            end
        end
    end
    return nil
end

-- ---- driving the base autochop plugin -------------------------------------

local function autochop_enable(on)
    dfhack.run_command(on and 'enable' or 'disable', 'autochop')   -- idempotent
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

-- ---- manual-mode yearly cut tracking (fallback when there's no agreement) --

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
    if cut < 0 then cut = 0; state.year_baseline = removed; save_state() end
    return cut
end

-- the current picture: {limit, remaining, source}. Auto mode reads the elven agreement's
-- live remaining allowance; manual mode counts trees felled this year against the pinned cap.
local function gate_status()
    load_state()
    if state.mode ~= 'manual' then
        local ag = read_agreement()
        if ag then
            return {limit = ag.total, remaining = ag.remaining, source = 'elven agreement', ag = ag}
        end
    end
    local cut = trees_cut_this_year()
    return {limit = state.limit, remaining = math.max(0, state.limit - cut),
            source = state.mode == 'manual' and 'manual' or 'manual (no elf agreement found)'}
end

-- ---- background watcher ---------------------------------------------------

enabled = enabled or false
function isEnabled()
    return enabled
end

local hb_gen = 0
local last_want = nil

-- Bring autochop's on/off state in line with the remaining allowance. Reads autochop's ACTUAL
-- state and only acts when it diverges, so it self-corrects if autochop is toggled out from under
-- us, and never spams enable/disable. (Global so it can be poked via reqscript.)
function do_check()
    if not dfhack.world.isFortressMode() then return end
    local g = gate_status()
    local want = g.remaining > 0
    local actual = autochop_is_enabled()
    local need
    if actual == nil then need = (want ~= last_want) else need = (want ~= actual) end
    if need then
        autochop_enable(want)
        if not want then autochop_undesignate() end   -- clear the pending batch at the cap
        last_want = want
        print(('auto-elf-chop: %d/%d lumber allowance remaining -- autochop %s'):format(
            g.remaining, g.limit, want and 'ENABLED' or 'DISABLED (limit reached)'))
    end
end

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
    pcall(do_check)
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

-- ---- lifecycle ------------------------------------------------------------

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, last_want, quota_cache = nil, nil, nil
        load_state()
        if dfhack.world.isFortressMode() and state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, last_want, quota_cache = nil, nil, nil
    end
end

-- exported so it can be driven via reqscript (the `enable` command path can serve a stale copy)
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
    last_want = nil
    print(('auto-elf-chop: annual tree-cutting limit pinned to %d (manual mode)'):format(state.limit))
    if enabled then pcall(do_check) end
elseif cmd == 'auto' then
    state.mode = 'auto'
    save_state()
    last_want = nil
    local ag = read_agreement()
    print('auto-elf-chop: reading the limit from the elven lumber agreement' ..
        (ag and (' (%d/%d remaining, agreed in year %d)'):format(ag.remaining, ag.total, ag.year)
             or ' (none found yet -- will fall back to the pinned limit until the elves agree one)'))
    if enabled then pcall(do_check) end
elseif cmd == 'reset' then
    state.year_baseline = df.global.plotinfo.trees_removed
    state.last_year = df.global.cur_year
    save_state()
    last_want = nil
    print('auto-elf-chop: this year\'s (manual-mode) tree-cut count reset to 0')
    if enabled then pcall(do_check) end
else
    -- status
    local g = gate_status()
    print(('auto-elf-chop: %s'):format(enabled and 'ENABLED (background)' or 'disabled'))
    print(('  limit    : %d trees/year  (source: %s)'):format(g.limit, g.source))
    print(('  remaining: %d  (autochop gate should be %s)'):format(
        g.remaining, g.remaining > 0 and 'ON' or 'OFF (limit reached)'))
    if g.ag then
        print(('  elven agreement: %d/%d lumber, agreed in year %d'):format(
            g.ag.remaining, g.ag.total, g.ag.year))
    end
    local ac_on = autochop_is_enabled()
    if ac_on ~= nil then
        print(('  base autochop: currently %s'):format(ac_on and 'enabled' or 'disabled'))
    end
    if not enabled then
        print('  run `enable auto-elf-chop` to start gating autochop.')
    end
end
