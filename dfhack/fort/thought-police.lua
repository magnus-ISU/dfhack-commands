-- List the bad thoughts the fort has actually been having, most common first.
--[[
fort/thought-police

The stress screen tells you WHO is unhappy. It never tells you WHAT is doing it to
them, and a fort of a hundred dwarves is not a set of unit sheets you can read one
by one. This counts the negative thoughts every citizen has had recently and prints
the ones doing the most damage, most common first.

    fort/thought-police                 the last month, top 10
    fort/thought-police days=90 top=20  a season, top 20
    fort/thought-police -v              also name the citizens worst hit by each

WHAT COUNTS AS A BAD THOUGHT

  Every emotion a dwarf has is a `personality_moodst`: an emotion (Anger, Grief,
  Satisfaction) attached to a thought (SawDeadBody, NeedsUnfulfilled) with a severity
  and the year and tick it happened. DF converts one into stress by dividing the
  severity by the emotion's `divider`, so the sign of that divider is DF's OWN
  verdict on whether the feeling helps or hurts -- positive divides into stress,
  negative divides it away, zero does nothing. That is what "bad" means here: no
  hand-written list of unpleasant-sounding emotions to fall out of date, and the
  stress each thought actually caused comes out of the same arithmetic.

  Rows are grouped by thought, not by emotion -- "a dwarf was sad about X" and "a
  dwarf was angry about X" are one problem to fix. `NeedsUnfulfilled` is broken out
  by which need went unmet, since that is the whole content of the row.

  Only citizens are counted. Visitors and the long-term residents who have not been
  made citizens have their own miseries and you cannot do much about them.

READING IT

  OCCURRENCES is how often the thought happened and DWARVES how many separate
  citizens had it -- a thought that hits everybody once is usually the fort's
  problem, one that hits a single dwarf forty times is usually that dwarf's.

  STILL FELT is how many of those a dwarf has not got over yet. DF gives a fresh
  emotion a `strength` and decays it to zero as the dwarf overcomes it, so this is
  the part of the count that is still weighing on somebody right now.

  WORST FEELING is the harshest emotion DF attached to that thought -- horror and
  grief divide their way into stress far faster than annoyance does -- so it ranks
  the rows the count cannot: sixty dwarves mildly annoyed about cups is a smaller
  problem than three reliving a death.

WHAT IS NOT HERE, AND WHY

  There is no "stress caused" column, because DF does not record one. An emotion
  keeps its type, its thought, a strength that decays, and the moment it happened
  -- nothing else. The stress it caused was applied to the dwarf's running total
  when it happened and is not attributable afterwards. `severity` looks like the
  number you want and is not: DF leaves it at 0 or -1 on most unpleasant thoughts,
  including witnessing a death, so anything computed from it reports a contented
  paradise with the fort's real miseries all reading zero.

  `-v` gives the honest version of that question: the dwarves who had the thought
  most, each with the running stress total DF does keep for them. Higher is worse;
  a negative total is a dwarf who is content on balance.
]]

local args = {...}
local days, top, verbose = 30, 10, false
for _, a in ipairs(args) do
    local k, v = a:match('^(%w+)=(%d+)$')
    if k == 'days' then days = tonumber(v)
    elseif k == 'top' then top = tonumber(v)
    elseif a == '-v' or a == '--verbose' then verbose = true
    else qerror('unknown argument: ' .. a) end
end

if not dfhack.isMapLoaded() then qerror('fort/thought-police needs a loaded fort') end

local TICKS_PER_DAY = 1200
local TICKS_PER_YEAR = 403200

-- one comparable clock, so "the last N days" survives a new year
local function stamp(year, tick) return year * TICKS_PER_YEAR + tick end

local now = stamp(df.global.cur_year, df.global.cur_year_tick)
local cutoff = now - days * TICKS_PER_DAY

-- SawDeadBody -> "Saw dead body". The enum key is the only name DF gives these.
local function prettify(name)
    local words = {}
    for word in name:gmatch('%u+%l*%d*') do words[#words + 1] = word end
    if #words == 0 then return name end
    local out = table.concat(words, ' '):lower()
    return out:sub(1, 1):upper() .. out:sub(2)
end

-- DF's own verdict on a feeling: `divider` is what it divides the thought's
-- severity by to reach stress, so a POSITIVE divider is an emotion that hurts, a
-- negative one an emotion that helps, and zero (ANYTHING, the empty slot) neither.
--
-- The severity itself is no use as the test. Most unpleasant thoughts carry a
-- severity of 0 or -1 -- annoyance at drinking without a cup, dejection at an
-- unmet need -- so anything keyed on "how much stress did this add" throws away
-- nearly every bad thought in the fort and reports a contented paradise. The
-- emotion says whether it was bad; the severity only says how badly.
local function divider_of(emotion)
    local attrs = df.emotion_type.attrs[emotion.type]
    return attrs and attrs.divider or 0
end

local function is_bad(emotion)
    return divider_of(emotion) > 0
end

-- The harshest feeling wins the row's WORST FEELING. A smaller divider means DF
-- divides the same severity into MORE stress, so divider 1 (horror, grief) is the
-- bottom of the pit and 8 (annoyance) the top.
local function harsher(a, b)
    if not a then return b end
    if not b then return a end
    return divider_of(a) <= divider_of(b) and a or b
end

-- DF hands a fresh emotion a strength and decays it to zero as the dwarf gets over
-- it, so a strength still above zero is a thought still being felt.
local function still_felt(emotion)
    return emotion.strength > 0
end

local function label_of(emotion)
    local thought = df.unit_thought_type[emotion.thought]
    if not thought then return 'thought ' .. emotion.thought end
    -- the need is the whole story in this one; without it every unmet need in the
    -- fort piles into a single meaningless row
    if emotion.thought == df.unit_thought_type.NeedsUnfulfilled then
        local need = df.need_type[emotion.subthought]
        if need then return 'Unmet need: ' .. prettify(need) end
    end
    return prettify(thought)
end

-- the only stress figure DF actually keeps: the dwarf's own running total. Higher
-- is worse and a NEGATIVE total is a dwarf in credit -- content on balance -- which
-- is why it is never printed as a bare number.
local function stress_of_unit(unit)
    local soul = unit.status.current_soul
    return soul and soul.personality.stress or 0
end

local function stress_text(unit)
    local stress = stress_of_unit(unit)
    if stress > 0 then return ('carrying %d stress'):format(stress) end
    return ('content on balance, %d stress'):format(stress)
end

local rows, order = {}, {}

for _, unit in ipairs(df.global.world.units.active) do
    if dfhack.units.isCitizen(unit) and not dfhack.units.isDead(unit) then
        local soul = unit.status.current_soul
        local personality = soul and soul.personality
        for _, emotion in ipairs(personality and personality.emotions or {}) do
            -- year -1 is an empty slot, never a thing that happened
            if is_bad(emotion) and emotion.year >= 0
                    and stamp(emotion.year, emotion.year_tick) >= cutoff then
                local label = label_of(emotion)
                local row = rows[label]
                if not row then
                    row = {label = label, count = 0, live = 0, worst = nil,
                           who = {}, names = {}}
                    rows[label] = row
                    order[#order + 1] = row
                end
                row.count = row.count + 1
                if still_felt(emotion) then row.live = row.live + 1 end
                row.worst = harsher(row.worst, emotion)
                if not row.who[unit.id] then
                    row.who[unit.id] = 0
                    row.names[#row.names + 1] = unit
                end
                row.who[unit.id] = row.who[unit.id] + 1
            end
        end
    end
end

if #order == 0 then
    print(('fort/thought-police: not one bad thought in the last %d days. Enjoy it.'):format(days))
    return
end

table.sort(order, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.live ~= b.live then return a.live > b.live end
    return a.label < b.label
end)

local shown = math.min(top, #order)
print(('Worst thoughts of the last %d days (%d kind%s in all, top %d):'):format(
    days, #order, #order == 1 and '' or 's', shown))
print(('  %-34s %11s %8s %10s  %s'):format(
    'THOUGHT', 'OCCURRENCES', 'DWARVES', 'STILL FELT', 'WORST FEELING'))

for i = 1, shown do
    local row = order[i]
    local dwarves = #row.names
    local feeling = row.worst and prettify(df.emotion_type[row.worst.type] or '?') or '?'
    print(('  %-34s %11d %8d %10d  %s'):format(
        row.label:sub(1, 34), row.count, dwarves, row.live, feeling))
    if verbose then
        table.sort(row.names, function(a, b)
            if row.who[a.id] ~= row.who[b.id] then return row.who[a.id] > row.who[b.id] end
            return stress_of_unit(a) > stress_of_unit(b)
        end)
        for n = 1, math.min(3, dwarves) do
            local unit = row.names[n]
            print(('      %s -- %d time%s, %s'):format(
                dfhack.units.getReadableName(unit), row.who[unit.id],
                row.who[unit.id] == 1 and '' or 's', stress_text(unit)))
        end
        if dwarves > 3 then print(('      ... and %d more'):format(dwarves - 3)) end
    end
end
