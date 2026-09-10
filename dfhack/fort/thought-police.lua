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

  STRESS is what it actually cost, and it is often zero: DF records plenty of sour
  thoughts at severity 0, which annoy without wearing anybody down. A row with a big
  count and no stress is a grumble; a row with real stress behind it is what is
  driving your dwarves to the tantrum spiral.
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

-- and what it actually cost, which is often nothing
local function stress_of(emotion)
    local divider = divider_of(emotion)
    if divider <= 0 or emotion.severity <= 0 then return 0 end
    return math.ceil(emotion.severity / divider)
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

local rows, order = {}, {}

for _, unit in ipairs(df.global.world.units.active) do
    if dfhack.units.isCitizen(unit) and not dfhack.units.isDead(unit) then
        local soul = unit.status.current_soul
        local personality = soul and soul.personality
        for _, emotion in ipairs(personality and personality.emotions or {}) do
            -- year -1 is an empty slot, never a thing that happened
            if is_bad(emotion) and emotion.year >= 0
                    and stamp(emotion.year, emotion.year_tick) >= cutoff then
                local stress = stress_of(emotion)
                local label = label_of(emotion)
                local row = rows[label]
                if not row then
                    row = {label = label, count = 0, stress = 0, who = {}, names = {}}
                    rows[label] = row
                    order[#order + 1] = row
                end
                row.count = row.count + 1
                row.stress = row.stress + stress
                if not row.who[unit.id] then
                    row.who[unit.id] = 0
                    row.names[#row.names + 1] = unit
                end
                row.who[unit.id] = row.who[unit.id] + stress
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
    return a.stress > b.stress
end)

local shown = math.min(top, #order)
print(('Worst thoughts of the last %d days (%d kind%s in all, top %d):'):format(
    days, #order, #order == 1 and '' or 's', shown))
print(('  %-40s %11s %8s %8s'):format('THOUGHT', 'OCCURRENCES', 'DWARVES', 'STRESS'))

for i = 1, shown do
    local row = order[i]
    local dwarves = #row.names
    print(('  %-40s %11d %8d %8d'):format(row.label:sub(1, 40), row.count, dwarves, row.stress))
    if verbose then
        table.sort(row.names, function(a, b) return row.who[a.id] > row.who[b.id] end)
        for n = 1, math.min(3, dwarves) do
            local unit = row.names[n]
            print(('      %s (%d stress)'):format(
                dfhack.units.getReadableName(unit), row.who[unit.id]))
        end
        if dwarves > 3 then print(('      ... and %d more'):format(dwarves - 3)) end
    end
end
