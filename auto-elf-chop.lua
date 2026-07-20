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

How it works (under a limit, the stock autochop plugin NEVER runs -- its batch/uncapped
designation was what kept breaking the limit; it stays disabled and this script designates
the permitted trees itself):
  * It reads autochop's own BURROW configuration (the burrows you flag for chopping in
    gui/autochop) and designates trees inside those burrows -- so your existing chop-area
    setup keeps working unchanged. If no burrow is flagged for chopping, it announces a
    prompt asking you to set one up.
  * It keeps the TOTAL number of chop-designated trees on the map (its own AND any you mark
    by hand) at the remaining allowance MINUS ONE: the last permitted tree is reserved for
    manual felling (moods, emergencies). Designations are only ever ADDED, never removed --
    hand-marked trees are yours.
  * Since total designations can never exceed remaining-1, a parallel felling crew cannot
    overshoot the allowance -- no throttling or job-cancelling needed.
  * NO AGREEMENT AT ALL (the elves have never negotiated one with this fort): cutting is
    UNRESTRICTED -- the stock autochop plugin is enabled and left to run as normal.
    (Between two known agreements -- the yearly gap while the diplomat renegotiates -- new
    designation is paused instead: the incoming agreement counts the year's fells
    retroactively, so gap-cutting can break it before it's even signed. Verified live.)
  * dig-shapes' drag-to-chop also consults this limit (manual_chop_budget below): it caps a
    chop box so total designations stop at the remaining allowance (manual marks may use the
    reserved tree) -- unless you're already AT the limit, in which case designating more is
    plainly deliberate and is not blocked.

Usage:
    enable auto-elf-chop        start managing tree-chopping under the limit (persists)
    disable auto-elf-chop       stop (autochop is left in whatever state it's in)
    auto-elf-chop               show status: quota, remaining, designations, mode
    auto-elf-chop auto          read the limit from the elven lumber agreement (the default)
    auto-elf-chop limit <N>     pin the annual tree-cutting limit to a fixed N (overrides auto)
    auto-elf-chop scorched on|off  once a year's agreement is ALREADY broken, clear-cut the
                                chop burrows (evidence says elves punish per breach-year --
                                hostility_level steps per incident -- not per tree). Default ON
    auto-elf-chop reset         (manual mode only) reset this year's cut count to 0 right now

While enabled, don't toggle the stock autochop by hand -- this script owns its on/off state.
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
        -- scorched defaults ON (the elves punish per breach-YEAR, not per tree -- once a
        -- year's agreement is broken, clear-cutting costs nothing more)
        if state.scorched == nil then state.scorched = true end
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

-- true / false, or nil if autochop's state can't be read
local function autochop_is_enabled()
    local ok, ac = pcall(require, 'plugins.autochop')
    if ok and ac and ac.isEnabled then
        local ok2, v = pcall(ac.isEnabled)
        if ok2 then return v and true or false end
    end
    return nil
end

-- ---- managed tree designation ----------------------------------------------
-- The stock autochop plugin stays DISABLED under a limit; we designate the permitted
-- trees ourselves, inside the burrows the player flagged for chopping in autochop's own
-- config (gui/autochop) -- the existing chop-area setup keeps working unchanged.

-- burrows flagged chop=true in autochop's config (readable while the plugin is disabled)
local function chop_burrow_list()
    local burrows = {}
    local ok, data = pcall(function()
        return require('plugins.autochop').getTreeCountsAndBurrowConfigs()
    end)
    if ok and data and data.burrow_configs then
        for _, bc in ipairs(data.burrow_configs) do
            if bc.chop then
                local b = df.burrow.find(bc.id)
                if b then burrows[#burrows + 1] = b end
            end
        end
    end
    return burrows
end

-- one pass over the map's plants: how many TREES are chop-designated (ours AND hand-marked
-- both count against the allowance), plus undesignated candidate trees inside the chop
-- burrows. Trees only (tree_info set) -- shrubs/gather marks are ignored.
local function tree_survey(burrows)
    local designated, candidates = 0, {}
    for _, p in ipairs(df.global.world.plants.all) do
        if p.tree_info then
            local ok, marked = pcall(dfhack.designations.isPlantMarked, p)
            if ok and marked then
                designated = designated + 1
            elseif burrows and #burrows > 0 then
                for _, b in ipairs(burrows) do
                    if dfhack.burrows.isAssignedTile(b, p.pos) then
                        candidates[#candidates + 1] = p
                        break
                    end
                end
            end
        end
    end
    return designated, candidates
end

local function designate_trees(candidates, n)
    local done = 0
    for _, p in ipairs(candidates) do
        if done >= n then break end
        local ok, can = pcall(dfhack.designations.canMarkPlant, p)
        if ok and can then
            local ok2 = pcall(dfhack.designations.markPlant, p)
            if ok2 then done = done + 1 end
        end
    end
    return done
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
-- Two agreement quirks handled (both hit live in year 188):
--   * the TreeQuota meeting_event VANISHES between agreements (after a year rolls over,
--     before the next diplomat ratifies) -- fall back to the LAST KNOWN agreed total, not
--     the manual default (the script once announced "elves permit 5" off the default while
--     the real new agreement said 4);
--   * a just-negotiated event carries quota_remaining == -1 as a NOT-RATIFIED sentinel
--     (a genuine overshoot tracks cuts exactly, e.g. -49) -- cross-compute remaining from
--     our own per-year cut counter instead of reading it as "1 tree over".
local function gate_status()
    load_state()
    if state.mode ~= 'manual' then
        local ag = read_agreement()
        if ag then
            if state.known_total ~= ag.total or state.known_year ~= ag.year then
                state.known_total, state.known_year = ag.total, ag.year
                save_state()
            end
            -- TRUST remaining verbatim -- a "fresh" agreement can legitimately be born
            -- negative: DF counts the YEAR's fells retroactively at ratification (verified:
            -- 5 gap-cuts against a new 4-total ratified as remaining = -1, agreement broken)
            return {limit = ag.total, remaining = ag.remaining, source = 'elven agreement', ag = ag}
        end
        -- BETWEEN two KNOWN agreements (the event vanishes until the next diplomat
        -- ratifies): new designation is NOT safe at any number -- the incoming agreement
        -- retroactively counts this year's fells against a total you can't know yet.
        if state.known_total then
            return {limit = state.known_total, remaining = 0, gap = true,
                    source = 'no active agreement -- awaiting the elven diplomat'}
        end
    end
    if state.mode ~= 'manual' then
        -- auto mode with NO agreement ever seen: the elves have never negotiated a limit
        -- with this fort -- cutting is unrestricted (stock autochop runs as normal)
        return {limit = -1, remaining = math.huge, unlimited = true,
                source = 'no elf agreement -- unrestricted'}
    end
    local cut = trees_cut_this_year()
    -- remaining is NOT clamped: negative = trees cut PAST the limit (the elves are angered);
    -- the agreement's own quota_remaining goes negative the same way
    return {limit = state.limit, remaining = state.limit - cut, source = 'manual'}
end

-- How many MORE trees may be designated by hand (dig-shapes' drag-to-chop consults this).
-- nil = no cap: either no elven agreement exists (unrestricted) or the fort is already AT
-- the limit -- past that point more designation is plainly deliberate, so it isn't blocked.
-- Manual marks may use the reserved last tree, so the cap is `remaining`, not remaining-1.
function manual_chop_budget()
    if not dfhack.world.isFortressMode() then return nil end
    load_state()
    local g = gate_status()
    if g.unlimited then return nil end
    if g.remaining <= 0 then return nil end
    local designated = tree_survey(nil)
    return math.max(0, g.remaining - designated)
end

-- ---- background watcher ---------------------------------------------------

enabled = enabled or false
function isEnabled()
    return enabled
end

local hb_gen = 0
local warned_noburrow = false
local last_pass = nil     -- {day, target}: gates the (heavier) tree survey

-- The manager. Unrestricted (no agreement ever): stock autochop runs as normal. Under a
-- limit: stock autochop stays DISABLED and total chop designations (ours + hand-marked)
-- are topped up to remaining-1 -- the last permitted tree is reserved for manual felling.
-- Designations are only added, never removed. (Global so it can be poked via reqscript.)
function do_check()
    if not dfhack.world.isFortressMode() then return end
    trees_cut_this_year()   -- keep the per-year baseline fresh (rollover caught within a check)
    local g = gate_status()

    if g.unlimited then
        -- the elves have never negotiated a limit here: no restriction at all
        if autochop_is_enabled() == false then
            autochop_enable(true)
            dfhack.gui.showAnnouncement(
                'No elven lumber agreement -- tree cutting is unrestricted (autochop enabled).',
                COLOR_LIGHTGREEN, true)
        end
        return
    end

    -- under a limit the stock plugin must never run -- its uncapped batch designation is
    -- what kept breaking the limit. Self-corrects if someone re-enables it by hand.
    if autochop_is_enabled() then
        autochop_enable(false)
        print('auto-elf-chop: stock autochop disabled -- tree designation is managed directly under the elven limit')
    end

    -- announce a NEW agreement once (per year+total)
    if g.ag and (state.announced_year ~= g.ag.year or state.announced_total ~= g.ag.total) then
        state.announced_year, state.announced_total = g.ag.year, g.ag.total
        save_state()
        local auto_n = math.max(0, math.min(g.remaining, g.limit) - 1)
        dfhack.gui.showAnnouncement(
            ('The elves permit %d tree%s this year -- designating up to %d (1 reserved for manual felling).')
                :format(g.limit, g.limit == 1 and '' or 's', auto_n), COLOR_LIGHTGREEN, true)
    end

    -- top up designations toward remaining-1 (the tree survey is the heavy part: run it
    -- when the target changes and at most once per game day otherwise). SCORCHED mode:
    -- once the year's agreement is already broken, the breach is per-YEAR (hostility_level
    -- steps per incident, not per tree) -- so optionally clear-cut the chop burrows, since
    -- the extra trees probably cost nothing more this year.
    local target = math.max(0, g.remaining - 1)
    if g.remaining < 0 and state.scorched then target = math.huge end
    local day = df.global.cur_year * 336 + df.global.cur_year_tick // 1200
    if not (last_pass and last_pass.day == day and last_pass.target == target) then
        last_pass = {day = day, target = target}
        if target > 0 then
            local burrows = chop_burrow_list()
            if #burrows == 0 then
                if not warned_noburrow then
                    warned_noburrow = true
                    dfhack.gui.showAnnouncement(
                        'auto-elf-chop: no burrow is flagged for chopping -- mark one in gui/autochop so the permitted trees can be designated.',
                        COLOR_YELLOW, true)
                end
            else
                warned_noburrow = false
                local designated, candidates = tree_survey(burrows)
                local need = (target == math.huge) and #candidates or (target - designated)
                if target == math.huge and need > 0 and state.scorched_year ~= df.global.cur_year then
                    state.scorched_year = df.global.cur_year
                    save_state()
                    dfhack.gui.showAnnouncement(
                        'The lumber agreement is already broken this year -- clear-cutting the chop burrows (scorched mode).',
                        COLOR_LIGHTRED, true)
                end
                if need > 0 then
                    local n = designate_trees(candidates, need)
                    if n > 0 then
                        if target == math.huge then
                            print(('auto-elf-chop: designated %d tree%s (scorched mode -- the year is already broken)')
                                :format(n, n == 1 and '' or 's'))
                        else
                            print(('auto-elf-chop: designated %d tree%s (%d in flight of %d permitted; 1 reserved for manual felling)')
                                :format(n, n == 1 and '' or 's', designated + n, g.limit))
                        end
                    end
                    if n < need and #candidates <= n then
                        print(('auto-elf-chop: the chop burrow%s ran out of trees (%d more permitted)')
                            :format(#burrows == 1 and '' or 's', need - n))
                    end
                end
            end
        end
    end

    -- OVER the limit: trees felled past the agreement (remaining < 0) anger the elves.
    -- Announce ONCE per breach -- in scorched mode the overshoot grows with every felled
    -- tree, so growth must NOT re-announce. Rearmed only when a renewed agreement /
    -- recount puts the count back under the limit.
    local over = (g.remaining < 0) and -g.remaining or 0
    if over > 0 then
        if (state.over_announced or 0) == 0 then
            state.over_announced = over
            save_state()
            dfhack.gui.showAnnouncement(
                ('The elven lumber limit is EXCEEDED by %d tree%s (%d felled, %d permitted) -- the elves will not forget this.')
                    :format(over, over == 1 and '' or 's', g.limit + over, g.limit), COLOR_LIGHTRED, true)
        end
    elseif state.over_announced and state.over_announced > 0 then
        state.over_announced = 0    -- back under the limit (renewed agreement / recount): rearm
        save_state()
    end
end

-- unregister the old persistent notify-panel line (replaced by the transition/over-limit
-- ANNOUNCEMENTS above; a live session may still carry the entry from an earlier version)
local function unregister_notification()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok or not n then return end
    local NAME = 'elf_lumber_gate'
    if n.NOTIFICATIONS_BY_NAME[NAME] then
        n.NOTIFICATIONS_BY_NAME[NAME] = nil
        for i = #n.NOTIFICATIONS_BY_IDX, 1, -1 do
            if n.NOTIFICATIONS_BY_IDX[i].name == NAME then table.remove(n.NOTIFICATIONS_BY_IDX, i) end
        end
    end
end

local function start()
    enabled = true
    last_pass = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local n = 0
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        n = n + 1
        if n >= CHECK_FRAMES then n = 0; pcall(do_check) end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    unregister_notification()
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
        state, quota_cache, last_pass = nil, nil, nil
        load_state()
        if dfhack.world.isFortressMode() then
            unregister_notification()
            if state.enabled then start() end
        end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, quota_cache, last_pass = nil, nil, nil
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
    last_pass = nil
    print(('auto-elf-chop: annual tree-cutting limit pinned to %d (manual mode)'):format(state.limit))
    if enabled then pcall(do_check) end
elseif cmd == 'auto' then
    state.mode = 'auto'
    save_state()
    last_pass = nil
    local ag = read_agreement()
    print('auto-elf-chop: reading the limit from the elven lumber agreement' ..
        (ag and (' (%d/%d remaining, agreed in year %d)'):format(ag.remaining, ag.total, ag.year)
             or ' (none found yet -- will fall back to the pinned limit until the elves agree one)'))
    if enabled then pcall(do_check) end
elseif cmd == 'scorched' then
    local v = args[2]
    if v ~= 'on' and v ~= 'off' then qerror('usage: auto-elf-chop scorched on|off') end
    state.scorched = (v == 'on')
    save_state()
    print('auto-elf-chop: scorched mode ' .. (state.scorched
        and 'ON -- once a year\'s agreement is already broken, the chop burrows are clear-cut (the breach is per-year)'
        or 'OFF -- an already-broken year designates nothing further automatically'))
    if enabled then pcall(do_check) end
elseif cmd == 'reset' then
    state.year_baseline = df.global.plotinfo.trees_removed
    state.last_year = df.global.cur_year
    save_state()
    last_pass = nil
    print('auto-elf-chop: this year\'s (manual-mode) tree-cut count reset to 0')
    if enabled then pcall(do_check) end
else
    -- status
    local g = gate_status()
    print(('auto-elf-chop: %s'):format(enabled and 'ENABLED (background)' or 'disabled'))
    if g.unlimited then
        print('  no elven lumber agreement -- tree cutting is UNRESTRICTED (stock autochop runs)')
    else
        print(('  limit    : %d trees/year  (source: %s)'):format(g.limit, g.source))
        print(('  remaining: %d  (designations held at remaining-1; the last tree is manual-only)')
            :format(g.remaining))
        local burrows = chop_burrow_list()
        local designated = tree_survey(burrows)
        print(('  designated now: %d tree%s; chop burrows configured: %d')
            :format(designated, designated == 1 and '' or 's', #burrows))
        print(('  scorched mode: %s (`auto-elf-chop scorched on|off` -- clear-cut once a year is already broken)')
            :format(state.scorched and 'ON' or 'off'))
    end
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
