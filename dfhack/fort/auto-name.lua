-- Give each migrant wave first names that all start with the wave's letter.
--@module = true
--@enable = true
--[[
auto-name
=========

Renames the FIRST NAME of every migrant so that, within a single migrant wave,
all dwarves share the same starting letter and each name is unique to that wave:

    wave 1 -> names starting with A   (Aulus, Aristotle, Astrid, ...)
    wave 2 -> names starting with B
    wave 3 -> names starting with C
    ...   (wraps back to A after Z)

Names are gender-correct (each dwarf gets a male or female name to match its sex)
and are drawn from `dfhack-config/scripts/data/auto-name-names.txt` -- a plain, editable text
file: one name per line, the MALE block first, then a single blank line, then the
FEMALE block. Lines starting with `#` are comments.

No two civilians ever share a first name. Every name it hands out is checked against
the first name of every LOADED unit -- fort civilians and any loaded historical figure
(visitors, merchants, diplomats, invaders) -- so a migrant is never given the name of
somebody already walking around. It also re-checks the dwarves it named on every scan
and renames any that have come to collide with a newcomer; the dwarf whose name it may
not touch (a founder, a fort-born child, a real historical figure) always keeps it.

What it leaves alone:
  * the original 7 (the embark group)
  * any dwarf that already has a nickname
  * dwarves born in the fort (only actual migrants are renamed)
  * REAL historical figures -- a migrant flagged important, or one that was a former
    member of another entity (e.g. came from another fort) or has held a noble
    position -- keeps its own name
  * any migrant it has already named, unless its name has become a duplicate

Waves are identified by the dwarves' real in-game arrival time (the historical
"settled at this site" event), so a wave is grouped correctly no matter when the
watcher happens to look -- and the original 7 are detected as the earliest arrival
group (they all settled at the instant the fort was founded).

Works on a fort that has already been running: the first time you run it, it does
a one-time retroactive pass over the migrants already present, then keeps watching
for new waves. Running it again does nothing to dwarves already handled.

    auto-name                 first run: name existing migrants + start watching;
                              afterwards: report status (no changes)
    enable auto-name          start/continue the watcher (persists with the fort)
    disable auto-name         stop the watcher
    auto-name scan            name any not-yet-named migrants right now
    auto-name status          report state

Add `enable auto-name` to magnus-scripts / dfhack.init to run it every session.
]]

local GLOBAL_KEY = 'auto-name'
local NAMES_PATH = dfhack.getDFPath() .. '/dfhack-config/scripts/data/auto-name-names.txt'
local SCAN_FRAMES = 500   -- re-check for new migrants roughly once per game-day (migrants arrive
                          -- in occasional waves, so a frequent scan of units.active is wasteful)

-- a..z ; wave index is 0-based (wave 0 -> 'a'), wraps after 'z'
local function wave_letter(idx) return string.char(string.byte('a') + (idx % 26)) end

-- one-time RNG seed (variety in which names get picked); determinism not needed
pcall(function() math.randomseed(os.time()) end)

-- ---------------------------------------------------------------------------
-- names file
-- ---------------------------------------------------------------------------
-- pools[sex] = {byletter = {a={...}, b={...}}, all = {...}}  (sex: 1 male, 0 female)
local pools

local function index_gender(list)
    local by = {}
    for _, n in ipairs(list) do
        local L = n:sub(1, 1)
        by[L] = by[L] or {}
        table.insert(by[L], n)
    end
    return {byletter = by, all = list}
end

local function load_names()
    if pools then return end
    local f = io.open(NAMES_PATH, 'r')
    if not f then
        qerror('auto-name: cannot open names file: ' .. NAMES_PATH ..
            '\n  (expected a male block, a blank line, then a female block)')
    end
    local male, female = {}, {}
    local cur, switched = male, false
    for line in f:lines() do
        local name = line:gsub('^%s+', ''):gsub('%s+$', '')
        if name == '' then
            -- the first blank line AFTER we have some male names = male/female divider
            if not switched and #male > 0 then cur, switched = female, true end
        elseif name:sub(1, 1) ~= '#' then
            table.insert(cur, name:lower())
        end
    end
    f:close()
    if #male == 0 or #female == 0 then
        qerror('auto-name: names file needs a male block and a female block ' ..
            'separated by a blank line (' .. NAMES_PATH .. ')')
    end
    pools = {[1] = index_gender(male), [0] = index_gender(female)}
end

-- ---------------------------------------------------------------------------
-- arrival time / founder detection
-- ---------------------------------------------------------------------------

local function living_citizens()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and not dfhack.units.isDead(u) then
            table.insert(out, u)
        end
    end
    return out
end

-- one-time backstop on the very first (uncapped) history scan
local FOUNDER_SCAN_CAP = 500000

-- hf -> "year:tick" of its most recent "settled at a site" event (its arrival).
-- Scans history backward (recent events are at the end) and stops once every
-- wanted hf is resolved. `stop_year` halts the scan below that year (settle
-- events for this fort never predate its founding year), so steady-state scans
-- stay cheap; `cap` is a hard backstop for the one-time founding-year lookup.
local function arrival_keys(wanted, stop_year, cap)
    local et = df.history_event_change_hf_statest
    local events = df.global.world.history.events
    local out, remaining = {}, 0
    for _ in pairs(wanted) do remaining = remaining + 1 end
    if remaining == 0 then return out end
    local n = 0
    for i = #events - 1, 0, -1 do
        if remaining == 0 then break end
        local e = events[i]
        if stop_year and e.year < stop_year then break end
        n = n + 1
        if cap and n > cap then break end
        if df.is_instance(et, e) then
            local hf = e.hfid
            if wanted[hf] and not out[hf] then
                out[hf] = ('%d:%010d'):format(e.year, e.seconds)
                remaining = remaining - 1
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- name picking + applying
-- ---------------------------------------------------------------------------

local function shuffled_indices(n)
    local idx = {}
    for i = 1, n do idx[i] = i end
    for i = n, 2, -1 do
        local j = math.random(i)
        idx[i], idx[j] = idx[j], idx[i]
    end
    return idx
end

-- a name nobody in the fort is using. `taken` is the hard constraint: it holds the
-- first name of every loaded unit (see name_holders), so a returned name is unique.
local function pick_from(list, taken)
    if not list then return nil end
    for _, i in ipairs(shuffled_indices(#list)) do
        local n = list[i]
        if not taken[n] then return n end
    end
    return nil
end

-- returns name, exact_letter_match. Tries the wave's letter first; if every free name
-- of that letter is taken, rolls FORWARD through the alphabet (Q->R->S..., wrapping
-- Z->A) and takes the first free name -- never random, never straight back to A.
-- nil means the whole gendered pool is in use: the caller leaves the dwarf alone
-- rather than hand out a duplicate.
local function pick_name(sex, letter, taken)
    local g = pools[sex] or pools[1]
    local base = string.byte(letter) - string.byte('a')
    for step = 0, 25 do
        local L = string.char((base + step) % 26 + string.byte('a'))
        local n = pick_from(g.byletter[L], taken)
        if n then return n, step == 0 end
    end
    return nil, false
end

-- first names currently in use, lowercased -> list of the units holding them. Covers
-- every fort civilian AND every loaded historical figure (visitors, merchants,
-- invaders), so those names are never handed to a migrant. Bounded by units.active.
local function name_holders()
    local holders = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) or u.hist_figure_id >= 0 then
            local n = u.name.first_name
            if n and n ~= '' then
                n = n:lower()
                holders[n] = holders[n] or {}
                table.insert(holders[n], u)
            end
        end
    end
    return holders
end

-- A migrant that came from ANOTHER FORT keeps its own name. The tell: its histfig has an
-- entity link (member / former member / squad / position) to a SITE GOVERNMENT that is NOT
-- this fort -- i.e. it lived at some other fortress. A freshly-generated wave migrant has
-- site-government links only to THIS fort (plus civ/religion/guild links, which don't count).
local function keep_original_name(u, hf)
    if not hf then return false end
    local my_group = df.global.plotinfo.group_id
    for _, l in ipairs(hf.entity_links) do
        if l.entity_id ~= my_group then
            local ent = df.historical_entity.find(l.entity_id)
            if ent and ent.type == df.historical_entity_type.SiteGovernment then
                return true          -- belonged to another fortress -> leave the name alone
            end
        end
    end
    return false
end

local function set_first_name(u, name)
    u.name.first_name = name
    u.name.has_name = true
    local hf = df.historical_figure.find(u.hist_figure_id)
    if hf then
        hf.name.first_name = name
        hf.name.has_name = true
    end
end

-- ---------------------------------------------------------------------------
-- persistent state
-- ---------------------------------------------------------------------------
-- {enabled, initialized, next_index, wave_index={key=idx}, used={key={names}},
--  processed={unit_ids}, unit_wave={["unit id"]=key}}

local function get_state()
    local s = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
    if s.enabled == nil then s.enabled = false end
    s.initialized = s.initialized or false
    s.next_index = s.next_index or 0
    s.wave_index = s.wave_index or {}
    s.used = s.used or {}
    s.processed = s.processed or {}
    s.skip = s.skip or {}              -- founders + fort-born: examined, never rename
    s.unit_wave = s.unit_wave or {}    -- "unit id" -> wave key (so a re-name keeps its letter)
    s.founder_key = s.founder_key      -- "year:tick" of fort founding (earliest settle)
    return s
end

local function save_state(s) dfhack.persistent.saveSiteData(GLOBAL_KEY, s) end

function isEnabled() return get_state().enabled end

-- ---------------------------------------------------------------------------
-- the work
-- ---------------------------------------------------------------------------

-- name every not-yet-handled migrant; returns a report list
local function process()
    load_names()
    local s = get_state()

    local processed, skip = {}, {}
    for _, id in ipairs(s.processed) do processed[id] = true end
    for _, id in ipairs(s.skip) do skip[id] = true end

    -- who holds which first name right now; `taken` is the hard no-duplicates rule
    local holders = name_holders()
    local taken = {}
    for n in pairs(holders) do taken[n] = true end

    local cits = living_citizens()

    -- candidates = dwarves that might still need a name: not already named, not
    -- already ruled out (founder/fort-born), not nicknamed by the player.
    local candidates, wanted = {}, {}
    for _, u in ipairs(cits) do
        local nick = u.name.nickname
        if u.hist_figure_id >= 0 and not processed[u.id] and not skip[u.id]
            and (nick == nil or nick == '')
        then
            local hf = df.historical_figure.find(u.hist_figure_id)
            if keep_original_name(u, hf) then
                -- a real historical figure (e.g. from another fort): never rename, and
                -- remember it so it isn't re-examined every scan
                table.insert(s.skip, u.id)
                skip[u.id] = true
            else
                table.insert(candidates, u)
                wanted[u.hist_figure_id] = true
            end
        end
    end
    -- ---- keep first names unique -------------------------------------------
    -- Anything WE named that has come to share its first name with another loaded
    -- unit gets a fresh one, keeping its own wave's letter. The other holder wins
    -- the name whenever we may not rename it -- a founder, a fort-born child, a
    -- real historical figure or a visitor is never touched.
    local report = {}
    local dup_names = {}
    for n, list in pairs(holders) do
        if #list > 1 then table.insert(dup_names, n) end
    end
    table.sort(dup_names)
    for _, n in ipairs(dup_names) do
        local list = holders[n]
        table.sort(list, function(a, b) return a.id < b.id end)
        local keeper
        for _, u in ipairs(list) do
            if not processed[u.id] then
                keeper = u
                break
            end
        end
        keeper = keeper or list[1]
        for _, u in ipairs(list) do
            if u ~= keeper and processed[u.id] then
                local key = s.unit_wave[tostring(u.id)]
                local widx = key and s.wave_index[key]
                local letter = widx and wave_letter(widx) or n:sub(1, 1)
                local sex = (u.sex == 0) and 0 or 1
                local name, exact = pick_name(sex, letter, taken)
                if name then
                    set_first_name(u, name)
                    taken[name] = true
                    if key then
                        s.used[key] = s.used[key] or {}
                        table.insert(s.used[key], name)
                    end
                    table.insert(report, {wave = letter, id = u.id, name = name,
                        sex = sex, exact = exact, was = n})
                end
            end
        end
    end

    if #candidates == 0 then
        save_state(s)
        return report
    end

    -- the founding arrival key = the earliest "settled here" time among ALL
    -- citizens. Computed once (then persisted): the original 7 share it.
    if not s.founder_key then
        local allw = {}
        for _, u in ipairs(cits) do
            if u.hist_figure_id >= 0 then allw[u.hist_figure_id] = true end
        end
        local km = arrival_keys(allw, nil, FOUNDER_SCAN_CAP)
        local minkey
        for _, k in pairs(km) do if not minkey or k < minkey then minkey = k end end
        s.founder_key = minkey or '0:0000000000'
    end
    local founder_year = tonumber(s.founder_key:match('^(%d+):')) or 0

    local keymap = arrival_keys(wanted, founder_year)

    -- classify candidates: founders / fort-born get skipped for good; everyone
    -- else (a later settle time) is a migrant, grouped by arrival into waves.
    local groups = {}
    for _, u in ipairs(candidates) do
        local k = keymap[u.hist_figure_id]
        if (not k) or k == s.founder_key then
            table.insert(s.skip, u.id)
            skip[u.id] = true
        else
            groups[k] = groups[k] or {}
            table.insert(groups[k], u)
        end
    end

    -- assign a letter index to any brand-new wave (chronological order)
    local newkeys = {}
    for k in pairs(groups) do
        if not s.wave_index[k] then table.insert(newkeys, k) end
    end
    table.sort(newkeys)
    for _, k in ipairs(newkeys) do
        s.wave_index[k] = s.next_index
        s.next_index = s.next_index + 1
    end

    -- order waves by their letter index for tidy output, then name each dwarf
    local allkeys = {}
    for k in pairs(groups) do table.insert(allkeys, k) end
    table.sort(allkeys, function(a, b) return s.wave_index[a] < s.wave_index[b] end)

    for _, k in ipairs(allkeys) do
        local letter = wave_letter(s.wave_index[k])
        s.used[k] = s.used[k] or {}

        local units = groups[k]
        table.sort(units, function(a, b) return a.id < b.id end)
        for _, u in ipairs(units) do
            local sex = (u.sex == 0) and 0 or 1
            local name, exact = pick_name(sex, letter, taken)
            if name then
                set_first_name(u, name)
                taken[name] = true
                table.insert(s.used[k], name)
                table.insert(s.processed, u.id)
                s.unit_wave[tostring(u.id)] = k
                processed[u.id] = true
                table.insert(report,
                    {wave = letter, id = u.id, name = name, sex = sex, exact = exact})
            else
                -- every free name of this dwarf's sex is in use: leave it alone (a
                -- duplicate is worse than the original name) and retry next scan.
                table.insert(report, {wave = letter, id = u.id, sex = sex, exhausted = true})
            end
        end
    end

    save_state(s)
    return report
end

-- did anything actually get renamed? (entries flagged `exhausted` are only a warning)
local function changed(report)
    for _, r in ipairs(report) do
        if not r.exhausted then return true end
    end
    return false
end

local function print_report(report)
    if #report == 0 then
        print('auto-name: no new migrants to name.')
        return
    end
    local counts, named, redone, stuck = {}, 0, 0, 0
    for _, r in ipairs(report) do
        if r.exhausted then stuck = stuck + 1
        else
            counts[r.wave] = (counts[r.wave] or 0) + 1
            if r.was then redone = redone + 1 else named = named + 1 end
        end
    end
    local parts = {}
    for w, c in pairs(counts) do table.insert(parts, ('%s=%d'):format(w:upper(), c)) end
    table.sort(parts)
    print(('auto-name: named %d migrant(s)%s  [wave=count: %s]'):format(named,
        redone > 0 and (', renamed %d duplicate(s)'):format(redone) or '',
        table.concat(parts, ', ')))
    local cap_first = function(n) return (n:gsub('^%l', string.upper)) end
    for _, r in ipairs(report) do
        if r.exhausted then
            print(('  wave %s  unit %d  %s  -- no free name left in the whole pool; left as-is')
                :format(r.wave:upper(), r.id, r.sex == 1 and 'M' or 'F'))
        else
            local tail = r.exact and ''
                or ('  (no free %s-name; used a fallback)'):format(r.wave:upper())
            print(('  wave %s  unit %d  %s  %s-> %s%s'):format(r.wave:upper(), r.id,
                r.sex == 1 and 'M' or 'F',
                r.was and ('duplicate ' .. cap_first(r.was) .. ' ') or '',
                cap_first(r.name), tail))
        end
    end
    if stuck > 0 then
        print(('  (add more names to %s)'):format(NAMES_PATH))
    end
end

-- ---------------------------------------------------------------------------
-- heartbeat (every SCAN_FRAMES; generation survives reloads via dfhack.internal)
-- ---------------------------------------------------------------------------

local function hb_gen(set)
    if set ~= nil then dfhack.internal.auto_name_hb_gen = set end
    return dfhack.internal.auto_name_hb_gen or 0
end

local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        local ok, report = pcall(process)
        -- a report of nothing but "pool exhausted" entries repeats every scan: don't
        -- print it over and over, `auto-name scan` shows it on demand.
        if ok and changed(report) then print_report(report) end
        dfhack.timeout(SCAN_FRAMES, 'frames', hb)
    end
    hb()
end

local function stop_heartbeat() hb_gen(hb_gen() + 1) end

local function set_enabled(v)
    local s = get_state()
    s.enabled = v
    if v and not s.initialized then s.initialized = true end
    save_state(s)
    if v then
        local ok, report = pcall(process)
        if ok then print_report(report) elseif report then dfhack.printerr(tostring(report)) end
        start_heartbeat()
    else
        stop_heartbeat()
    end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        pools = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat()
        pools = nil
    end
end

-- ---------------------------------------------------------------------------
-- command-line entry
-- ---------------------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('auto-name only works in fortress mode')
end

-- `enable auto-name` / `disable auto-name`
if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('auto-name: ' .. (isEnabled() and 'ENABLED (watching for migrant waves)' or 'disabled'))
    return
end

local cmd = ({...})[1]

if cmd == 'status' then
    local s = get_state()
    print(('auto-name: %s; %s; %d wave(s) lettered, %d dwarf/dwarves named.')
        :format(s.enabled and 'ENABLED' or 'disabled',
            s.initialized and 'initialized' or 'not yet initialized',
            s.next_index, #s.processed))
    return
end

if cmd == 'scan' then
    print_report(process())
    return
end

-- bare invocation
local s = get_state()
if s.initialized then
    print('auto-name: already run on this fort -- existing dwarves left as-is.')
    print('  (use `auto-name scan` to catch new migrants, `disable auto-name` to stop the watcher.)')
    if s.enabled and hb_gen() == 0 then start_heartbeat() end
    return
end

-- first run: retroactively name current migrants, then start watching
local report = process()
s = get_state()
s.initialized = true
s.enabled = true
save_state(s)
start_heartbeat()
print_report(report)
print('auto-name: watching for future migrant waves (enabled).')
