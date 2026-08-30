-- Set the standing orders a new fort should have started with.
--@module = true
--[[
fort/initial-standing-orders

The two settings worth changing on day one, neither of which DF remembers
between forts:

  * CHILDREN DO NOT HAUL REFUSE OR CORPSES. Children still do every other
    chore. Refuse hauling walks them out to the refuse pile past whatever is
    lurking there, and corpse hauling hands a child the body of someone they
    knew -- DF has no separate "burial" chore, hauling the corpse to its coffin
    IS the burial job, and it is `HAUL_BODY` that does it. Both are switched off
    in `labor_info.chores`, which is the per-labor list behind the Standing
    Orders screen's chore checkboxes.

  * OBSIDIAN IS AVAILABLE FOR ORDINARY WORK. While a stone is flagged in
    `economic_stone` -- the fort's stone-use restrictions -- masons pass it over
    for furniture, blocks and crafts and it piles up unused. This clears
    obsidian's entry. Whether DF starts a fort with obsidian restricted seems to
    vary (the world checked while writing this had it already free), so the run
    is a no-op as often as not; it costs nothing and guarantees the state.

Idempotent, and it only writes the two settings above -- everything else on the
Standing Orders screen is left exactly as you set it.

    fort/initial-standing-orders          apply
    fort/initial-standing-orders status   report the current values, change nothing
]]

-- chores children should not be given. Indexed into labor_info.chores by
-- unit_labor, which is the same order the Standing Orders screen uses.
local CHILD_CHORES_OFF = {'HAUL_REFUSE', 'HAUL_BODY'}

-- stones to release from the fort's stone-use restrictions
local FREE_STONES = {'OBSIDIAN'}

local function labor_info()
    return df.global.plotinfo.labor_info
end

-- economic_stone is a 0/1 vector, not a vector of Lua booleans -- and 0 is
-- truthy in Lua, so it has to be compared explicitly or every stone reads as
-- restricted.
local function is_restricted(idx)
    local econ = df.global.plotinfo.economic_stone
    if idx == nil or idx >= #econ then return nil end
    return econ[idx] == 1
end

local function stone_index(token)
    local mat = dfhack.matinfo.find(token)
    return mat and mat.index or nil
end

function apply()
    local changed = {}

    local chores = labor_info().chores
    for _, name in ipairs(CHILD_CHORES_OFF) do
        local labor = df.unit_labor[name]
        if labor and chores[labor] then
            chores[labor] = false
            changed[#changed + 1] = ('children no longer do %s'):format(name:lower():gsub('_', ' '))
        end
    end

    local econ = df.global.plotinfo.economic_stone
    for _, token in ipairs(FREE_STONES) do
        local idx = stone_index(token)
        if not idx then
            changed[#changed + 1] = ('%s: not in this world'):format(token:lower())
        elseif idx >= #econ then
            changed[#changed + 1] = ('%s: no stone-use entry yet (embark first)'):format(token:lower())
        elseif econ[idx] == 1 then
            econ[idx] = 0
            changed[#changed + 1] = ('%s released for ordinary work'):format(token:lower())
        end
    end

    return changed
end

function status()
    local chores = labor_info().chores
    print(('fort/initial-standing-orders: children do chores at all: %s')
        :format(tostring(labor_info().flags.children_do_chores)))
    for _, name in ipairs(CHILD_CHORES_OFF) do
        local labor = df.unit_labor[name]
        print(('  %-12s children: %s'):format(name:lower(),
            labor and (chores[labor] and 'yes' or 'no') or 'no such labor'))
    end
    for _, token in ipairs(FREE_STONES) do
        local idx = stone_index(token)
        local r = is_restricted(idx)
        print(('  %-12s %s'):format(token:lower(),
            r == nil and 'no stone-use entry' or
            (r and 'RESTRICTED (economic)' or 'available for ordinary work')))
    end
end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('fort/initial-standing-orders only works in fortress mode')
end

local arg = ({...})[1]
if arg == 'status' then
    status()
    return
end

local changed = apply()
if #changed == 0 then
    print('fort/initial-standing-orders: already set, nothing to do.')
else
    for _, line in ipairs(changed) do
        print('fort/initial-standing-orders: ' .. line)
    end
end
