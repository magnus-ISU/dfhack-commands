-- Shows a dwarf's stress on their Thoughts tab, and what each thought did to it.
--@module = true
--@enable = true
--[[
fort/stress-display

The Thoughts tab of a unit sheet lists what a dwarf has felt and never says what any of it
cost. The seven-colour bar at the top of the screen sorts the fort into "super happy" through
"super unhappy", and the number behind that sorting -- the dwarf's STRESS, higher is worse --
is shown nowhere. And DF does not keep, on the thought, how much stress it added: the record
has a severity that reads 0 or -1 on most bad thoughts, and only the running total survives.

So this does two things on `Thoughts > Recent thoughts`:

  1. THE STRESS NUMBER, on the same line as the "Recent thoughts / Memories" tabs, four cells
     right of "Memories", with the bar's word for it: "Stress 63,114  Miserable". The seven
     words are the bar's own bands, which are plain thresholds on the number:

         Ecstatic     below -50,000
         Happy        -50,000 .. -25,000
         Pleased      -25,000 .. -10,000
         Content      -10,000 .. +10,000
         Displeased   +10,000 .. +25,000
         Unhappy      +25,000 .. +50,000
         Miserable    above +50,000

     (DF's own words, from the tooltips on the seven counters: "This creature is ecstatic
     right now" and so on. The thresholds are measured on a 145-citizen fort.)

  2. WHAT EACH THOUGHT HAS COST SO FAR, to the left of its line: "+1,234" in red for stress
     it added, "-380" in green for stress it took away, "0" dim for one that did nothing (the
     "didn't feel anything" kind really is nothing). The number is MEASURED, not read, and it
     is measured the way DF actually charges: AN EMOTION IS BILLED WHILE IT IS FELT, NOT WHEN
     IT LANDS. Each record carries a live `strength` that starts high and drops to 0 as the
     dwarf gets over it, and every hundred-odd ticks DF moves the stress by an amount set by
     what is live -- watched here: a dwarf with only "disgusted by miasma" live takes +250 a
     period, sample after sample, until it fades; one with only "delighted by a performance"
     live gets -20 a period. A thought whose strength has reached 0 costs nothing more, ever.

     So the service samples every citizen's stress a few times a second and, when it moves,
     gives the change to the records that are live at that moment. One live record: the
     number is exact. Several live: the change is split between them by their relative
     strength over their emotion's divider (DF's own harshness scale -- horror 1, annoyance
     8, pleasant ones negative), and every share so priced is marked with a "~" as an
     estimate. Only the live emotions pulling the same way as the change are candidates: a
     rise goes to the unpleasant ones, a drop to the pleasant ones, so a sadness felt
     alongside a masterwork never gets a share of the relief. A change with nothing live behind it is drift and is kept to one side. A
     thought that was already spent when the service started watching shows nothing: its
     cost was paid before anyone was counting.

    enable fort/stress-display     start measuring (saved with the fort)
    disable fort/stress-display    stop; what was measured stays
    fort/stress-display            status: units watched, thoughts priced, drift seen

HOW THE ROWS ARE MATCHED. DF keeps the rendered list itself: `view_sheets.raw_thought_str`
is one string per entry in display order (newest first), and `scroll_position_thoughts`
counts wrapped LINES, not entries. The display order is the emotion records with a thought,
sorted by year and tick descending, ties in record order -- checked against the list on a
42-entry sheet. The screen rows are read back and matched to the entries by text, so the
wrap width never has to be known: a row that begins an entry's text starts that entry, the
rows after it consume the rest. The tab header is found by reading a band of the screen for
"Recent thoughts", never assumed from a position, and everything is anchored to it.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local GLOBAL_KEY = 'stress-display'

-- rendered frames between samples. A thought applies its stress in the tick it lands, and a
-- dwarf gets a handful a day; five frames keeps two thoughts from sharing a window without
-- costing anything (a sample is one integer read per citizen).
local BEAT_FRAMES = 5
-- every so often the record sets are refreshed for everybody, so a thought that cost nothing
-- is noticed (and priced at 0). Measured: the refresh is the whole cost of this service -- the
-- stress reads are nothing -- so it runs twice a minute and skips any unit whose records
-- have not changed (an integer signature, no strings built)
local REFRESH_BEATS = 100
-- the citizen list is rebuilt this often; isCitizen is not free and the list barely moves
local ROSTER_BEATS = 200
-- saved this many beats after the last change, not on every one
local SAVE_BEATS = 100

-- the bar's seven words, indexed by dfhack.units.getStressCategory (0 = worst .. 6 = best)
-- DF's words for the seven counters at the top of the screen, from its own tooltips
local BANDS = {
    [0] = {'Miserable', COLOR_LIGHTRED},
    [1] = {'Unhappy', COLOR_RED},
    [2] = {'Displeased', COLOR_YELLOW},
    [3] = {'Content', COLOR_WHITE},
    [4] = {'Pleased', COLOR_GREEN},
    [5] = {'Happy', COLOR_LIGHTGREEN},
    [6] = {'Ecstatic', COLOR_LIGHTCYAN},
}

enabled = enabled or false
-- unit id -> {stress = last seen, keys = {key = true}, deltas = {key = {v = n, est = bool}},
--              drift = n}
watch = watch or {}
stats = stats or {priced = 0, drift_events = 0}

-- ---------------------------------------------------------------------------
-- records
-- ---------------------------------------------------------------------------

-- a record's identity: the same thought can recur, so the tick is part of it. Records that
-- land in one tick with the same thought share a key and share the number.
local function record_key(e)
    return ('%d:%d:%d:%d:%d'):format(e.type, e.thought, e.subthought, e.year, e.year_tick)
end

local function personality(unit)
    local soul = unit.status.current_soul
    return soul and soul.personality or nil
end

local function record_keys(pers)
    local keys = {}
    for _, e in ipairs(pers.emotions) do
        if e.year ~= -1 then keys[record_key(e)] = true end
    end
    return keys
end

-- a cheap fingerprint of the record set: integer reads only, no strings. Two sets with the
-- same count and the same sum of ticks are the same set for this purpose.
local function record_sig(pers)
    local n, sum = 0, 0
    for _, e in ipairs(pers.emotions) do
        if e.year ~= -1 then n = n + 1; sum = sum + e.year_tick + e.year * 403200 end
    end
    return n * 1e12 + sum
end

-- ---------------------------------------------------------------------------
-- the sampler
-- ---------------------------------------------------------------------------

local function persist()
    local rows = {}
    for id, w in pairs(watch) do
        local deltas = {}
        for k, d in pairs(w.deltas) do deltas[#deltas + 1] = {k = k, v = d.v, est = d.est or nil} end
        rows[#rows + 1] = {id = id, drift = w.drift, deltas = deltas}
    end
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY,
          {enabled = enabled, units = rows, stats = stats})
end

local function load_persisted()
    watch = {}
    local data = dfhack.persistent.getSiteData(GLOBAL_KEY)
    if not data then return false end
    for _, row in ipairs(data.units or {}) do
        local deltas = {}
        for _, d in ipairs(row.deltas or {}) do deltas[d.k] = {v = d.v, est = d.est == true} end
        watch[row.id] = {deltas = deltas, drift = row.drift or 0}
    end
    stats = data.stats or {priced = 0, drift_events = 0}
    return data.enabled == true
end

local roster = {}
local function rebuild_roster()
    roster = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and not dfhack.units.isDead(u) and personality(u) then
            roster[#roster + 1] = u
        end
    end
end

-- first sight of a unit: remember the stress and the records, price nothing
local function adopt(unit, pers)
    local w = watch[unit.id] or {deltas = {}, drift = 0}
    w.stress = pers.stress
    w.keys = record_keys(pers)
    w.sig = record_sig(pers)
    watch[unit.id] = w
    return w
end

-- the stress moved: the records LIVE right now (strength above 0) are what DF is billing.
-- One of them takes the whole change; several share it by relative strength over the
-- emotion's divider, and each such share is marked an estimate. Nothing live: drift.
local function attribute(w, pers)
    local delta = pers.stress - w.stress
    -- only the live emotions pulling in the change's direction are candidates: a rise is
    -- the bad ones' doing (positive divider), a drop the good ones' (negative divider).
    -- A sadness felt alongside a masterwork does not get a share of the relief.
    local live, total = {}, 0
    for _, e in ipairs(pers.emotions) do
        if e.year ~= -1 and (e.strength > 0 or e.relative_strength > 0) then
            local div = df.emotion_type.attrs[e.type].divider
            if div ~= 0 and (div > 0) == (delta > 0) then
                local wt = math.max(e.relative_strength, e.strength, 1) / math.abs(div)
                live[#live + 1] = {key = record_key(e), wt = wt}
                total = total + wt
            end
        end
    end
    if #live == 0 then
        w.drift = w.drift + delta
        stats.drift_events = stats.drift_events + 1
    else
        local est = #live > 1
        for _, r in ipairs(live) do
            local share = est and (total > 0 and delta * r.wt / total or delta / #live) or delta
            local d = w.deltas[r.key] or {v = 0, est = false}
            d.v = d.v + share
            d.est = d.est or est
            w.deltas[r.key] = d
        end
        stats.priced = stats.priced + 1
    end
    w.stress = pers.stress
    w.keys = record_keys(pers)
    w.sig = record_sig(pers)
end

-- no stress change, but the record set is looked at anyway: a new record is priced at 0 (it
-- did nothing) and one that DF has dropped takes its number with it, so the store stays the
-- size of the sheet
local function refresh(w, pers)
    local sig = record_sig(pers)
    if sig == w.sig then return end
    w.sig = sig
    local now = record_keys(pers)
    for k in pairs(now) do
        if not w.keys[k] and w.deltas[k] == nil then w.deltas[k] = {v = 0, est = false} end
    end
    for k in pairs(w.deltas) do
        if not now[k] then w.deltas[k] = nil end
    end
    w.keys = now
end

local beat_n, dirty_beats = 0, nil
local function sample()
    beat_n = beat_n + 1
    if beat_n % ROSTER_BEATS == 1 then rebuild_roster() end
    local do_refresh = beat_n % REFRESH_BEATS == 0
    for _, u in ipairs(roster) do
        local pers = personality(u)
        if pers then
            local w = watch[u.id]
            if not w or not w.keys then
                adopt(u, pers)
            elseif pers.stress ~= w.stress then
                attribute(w, pers)
                dirty_beats = dirty_beats or beat_n
            elseif do_refresh then
                refresh(w, pers)
            end
        end
    end
    if dirty_beats and beat_n - dirty_beats >= SAVE_BEATS then
        persist()
        dirty_beats = nil
    end
end

local function hb_gen(set)
    if set ~= nil then dfhack.internal.stress_display_hb_gen = set end
    return dfhack.internal.stress_display_hb_gen or 0
end

function isEnabled() return enabled end

local function start()
    enabled = true
    local my_gen = hb_gen() + 1
    hb_gen(my_gen)
    beat_n = 0
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen() then return end
        if dfhack.world.isFortressMode() then pcall(sample) end
        dfhack.timeout(BEAT_FRAMES, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen(hb_gen() + 1)
    persist()
end

function set_enabled(on)
    if on then start() else stop() end
    persist()
    return enabled
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode() and load_persisted() then start() end
    elseif sc == SC_MAP_UNLOADED then
        enabled = false
        hb_gen(hb_gen() + 1)
        watch = {}
    end
end

-- ---------------------------------------------------------------------------
-- the overlay
-- ---------------------------------------------------------------------------

local function thousands(n)
    local s = tostring(math.floor(math.abs(n) + 0.5))
    s = s:reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
    return (n < 0 and '-' or '') .. s
end

local function sheet_unit()
    local vs = df.global.game.main_interface.view_sheets
    return vs.open and df.unit.find(vs.active_id) or nil
end

-- the display order of the Recent thoughts list: records with a thought, newest first, ties
-- in record order. Checked against raw_thought_str on a live sheet.
local function displayed_records(pers)
    local list = {}
    for i, e in ipairs(pers.emotions) do
        if e.year ~= -1 and e.thought ~= df.unit_thought_type.None then
            list[#list + 1] = {e = e, i = i}
        end
    end
    table.sort(list, function(a, b)
        if a.e.year ~= b.e.year then return a.e.year > b.e.year end
        if a.e.year_tick ~= b.e.year_tick then return a.e.year_tick > b.e.year_tick end
        return a.i < b.i
    end)
    return list
end

-- the plain text of a rendered entry: DF's colour codes stripped, bytes kept as cp437 so
-- they compare with what readTile gives back
-- (DF leaves a double space where a colour code was, "remembering  [C:7:0:0]watching", and
-- renders it single -- so runs of spaces are squeezed on both sides of the comparison)
local function squeeze(s)
    return (s:gsub('%s+', ' '))
end

local function plain(s)
    return squeeze((s:gsub('%[C:%d+:%d+:%d+%]', '')))
end

local function row_text(y, x0, x1)
    local t = {}
    for x = x0, x1 do
        local pen = dfhack.screen.readTile(x, y)
        local ch = pen and pen.ch or 0
        t[#t + 1] = string.char(ch == 0 and 32 or ch)     -- an empty cell reads as 0
    end
    return table.concat(t)
end

local function trim(s) return (squeeze(s):gsub('^%s+', ''):gsub('%s+$', '')) end

local HEADER = 'Recent thoughts'
local MEMORIES = 'Memories'
local BAND_TOP, BAND_BOTTOM = 8, 30       -- where the tab row can be, on any screen size

-- find "Recent thoughts" on screen: the cached spot is checked first (a dozen reads), the
-- band is only read when that fails
local header_cache = nil
local function find_header()
    local dimx, dimy = df.global.gps.dimx, df.global.gps.dimy
    if header_cache and header_cache.dimx == dimx and header_cache.dimy == dimy then
        local h = header_cache
        if row_text(h.y, h.x, h.x + #HEADER - 1) == HEADER then return h end
    end
    header_cache = nil
    for y = BAND_TOP, math.min(BAND_BOTTOM, dimy - 1) do
        local line = row_text(y, 0, dimx - 1)
        local x = line:find(HEADER, 1, true)
        if x then
            local mx = line:find(MEMORIES, x + #HEADER, true)
            header_cache = {x = x - 1, y = y, mx = mx and mx - 1 or nil, dimx = dimx, dimy = dimy}
            return header_cache
        end
    end
    return nil
end

StressDisplayOverlay = defclass(StressDisplayOverlay, overlay.OverlayWidget)
StressDisplayOverlay.ATTRS{
    desc = 'Shows stress on the unit sheet\'s Thoughts tab, and what each thought cost.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/UNIT/Thoughts/Recent',
    frame = {w = 1, h = 1},
    version = 1,
}

function StressDisplayOverlay:init()
    self.rows = nil          -- {{y = row, key = record key}, ...} for the rows on screen
    self.rows_key = nil      -- what the rows were built for
end

-- Match the rows on screen to the entries. `entries` is the plain text per entry in display
-- order; the walk starts at entry 0 and moves forward, consuming each entry's text row by
-- row, so wrapping is never simulated and a scroll that lands mid-entry is fine.
function StressDisplayOverlay:map_rows(h, entries, records)
    local dimy = df.global.gps.dimy
    local x0, x1 = math.max(0, h.x - 2), math.min(df.global.gps.dimx - 1, h.x + 90)
    local rows = {}
    local k, rest = 1, nil        -- entry being consumed, and the text of it still to come
    for y = h.y + 3, dimy - 1 do
        local t = trim(row_text(y, x0, x1))
        if t ~= '' then
            local matched = false
            if rest and rest:sub(1, #t) == t then
                rest = trim(rest:sub(#t + 1))
                if rest == '' then rest = nil; k = k + 1 end
                matched = true
            else
                -- the start of an entry, at or after the one expected
                for j = k, #entries do
                    local full = entries[j]
                    if full:sub(1, #t) == t then
                        rows[#rows + 1] = {y = y, key = record_key(records[j].e), probe = t:sub(1, 12)}
                        rest = trim(full:sub(#t + 1))
                        k = j
                        if rest == '' then rest = nil; k = k + 1 end
                        matched = true
                        break
                    end
                end
                if not matched and not rest then
                    -- a partial line from a scrolled entry: find it inside the expected one
                    local full = entries[k]
                    if full and full:find(t, 1, true) then
                        local at = full:find(t, 1, true)
                        rest = trim(full:sub(at + #t))
                        if rest == '' then rest = nil; k = k + 1 end
                        matched = true
                    end
                end
            end
            if not matched then break end      -- past the list, or something else drawn
        end
    end
    return rows
end

-- the cached rows still describe the screen? (a scroll shows up as the text moving)
function StressDisplayOverlay:rows_valid(h)
    if not self.rows then return false end
    for _, r in ipairs(self.rows) do
        local t = trim(row_text(r.y, h.x - 2, h.x + 20))
        if t:sub(1, #r.probe) ~= r.probe then return false end
    end
    return true
end

function StressDisplayOverlay:onRenderFrame(dc, rect)
    local unit = sheet_unit()
    local pers = unit and personality(unit)
    if not pers then return end
    local h = find_header()
    if not h then return end

    -- 1. the number, four cells right of "Memories"
    local cat = dfhack.units.getStressCategory(unit)
    local band = BANDS[cat] or BANDS[3]
    local x = (h.mx or (h.x + #HEADER + 3 + 8)) + #MEMORIES + 4
    local label = 'Stress ' .. thousands(pers.stress)
    dfhack.screen.paintString({fg = COLOR_WHITE}, x, h.y, label)
    dfhack.screen.paintString({fg = band[2]}, x + #label + 2, h.y, band[1])

    -- 2. what each thought on screen cost
    local vs = df.global.game.main_interface.view_sheets
    local raw = vs.raw_thought_str
    local key = ('%d:%d:%d:%d:%d'):format(unit.id, vs.scroll_position_thoughts, #raw, h.x, h.y)
    if self.rows_key ~= key or not self:rows_valid(h) then
        local records = displayed_records(pers)
        if #records ~= #raw then
            self.rows, self.rows_key = {}, key       -- an order this does not understand: draw nothing
        else
            local entries = {}
            for i = 0, #raw - 1 do entries[i + 1] = plain(raw[i].value) end
            self.rows = self:map_rows(h, entries, records)
            self.rows_key = key
        end
    end
    local w = watch[unit.id]
    if not w then return end
    for _, r in ipairs(self.rows) do
        local d = w.deltas[r.key]
        if d ~= nil then
            local v = d.v
            local s = (v > 0 and ('+' .. thousands(v)) or thousands(v)) .. (d.est and '~' or '')
            local pen = v > 0 and COLOR_LIGHTRED or (v < 0 and COLOR_LIGHTGREEN or COLOR_DARKGREY)
            dfhack.screen.paintString({fg = pen}, h.x - 2 - #s, r.y, s)
        end
    end
end

OVERLAY_WIDGETS = {thoughts = StressDisplayOverlay}

if dfhack_flags.module then return end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if not dfhack.world.isFortressMode() then
    qerror('stress-display only works in fortress mode')
end

if dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print(('stress-display: %s'):format(enabled and
        'ON -- measuring what each thought costs' or 'OFF -- measured values kept'))
    return
end

local units, priced = 0, 0
for _, w in pairs(watch) do
    units = units + 1
    for _ in pairs(w.deltas) do priced = priced + 1 end
end
print(('stress-display is %s; %d unit%s watched, %d thought%s priced, %d change%s with nothing live behind them')
    :format(enabled and 'ON' or 'OFF', units, units == 1 and '' or 's', priced, priced == 1 and '' or 's',
            stats.drift_events, stats.drift_events == 1 and '' or 's'))
local u = sheet_unit()
if u and personality(u) then
    local pers = personality(u)
    local cat = dfhack.units.getStressCategory(u)
    print(('  %s: stress %s (%s)'):format(dfhack.units.getReadableName(u), thousands(pers.stress), BANDS[cat][1]))
    local w = watch[u.id]
    if w then
        for _, r in ipairs(displayed_records(pers)) do
            local d = w.deltas[record_key(r.e)]
            print(('    %8s  %s / %s%s'):format(d and (thousands(d.v) .. (d.est and '~' or '')) or '?',
                df.emotion_type[r.e.type], df.unit_thought_type[r.e.thought],
                r.e.strength > 0 and (' [live, strength %d]'):format(r.e.strength) or ''))
        end
        print(('    drift (no thought behind it): %s'):format(thousands(w.drift)))
    end
end
