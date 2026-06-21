-- Report how long the fort's raiding parties have been gone, and retrieve any
-- units stuck off-map.
--@ module = false
--[[
    raid-status

Lists each raiding party currently out (a player army travelling the world map),
how long it has been gone (measured from when it left), and its leader. Then it
checks for units stuck off-screen (the same condition fix/retrieve-units looks
for -- incoming/returning units left inactive) and automatically retrieves them.

NOTE: the estimated time-of-return is not shown yet -- that estimate is only
exposed while a mission is being planned / in flight, so it will be added once it
can be read from a live raid.
]]

if not dfhack.world.isFortressMode() then
    qerror('raid-status only works in fortress mode')
end

local TICKS_PER_DAY   = 1200
local DAYS_PER_MONTH  = 28
local MONTHS_PER_YEAR = 12
local TICKS_PER_YEAR  = TICKS_PER_DAY * DAYS_PER_MONTH * MONTHS_PER_YEAR  -- 403200

local function now_ticks()
    return df.global.cur_year * TICKS_PER_YEAR + df.global.cur_year_tick
end

local function fmt_duration(ticks)
    if ticks < 0 then ticks = 0 end
    local days = math.floor(ticks / TICKS_PER_DAY)
    local months = math.floor(days / DAYS_PER_MONTH)
    local rem = days % DAYS_PER_MONTH
    if months > 0 then
        return ('%d month%s, %d day%s'):format(
            months, months == 1 and '' or 's', rem, rem == 1 and '' or 's')
    end
    return ('%d day%s'):format(days, days == 1 and '' or 's')
end

local function leader_name(c)
    if c.master_hf and c.master_hf >= 0 then
        local hf = df.historical_figure.find(c.master_hf)
        if hf then return dfhack.translation.translateName(hf.name) end
    end
end

local function site_name(site_id)
    if site_id and site_id >= 0 then
        local s = df.world_site.find(site_id)
        if s then return dfhack.translation.translateName(s.name) end
    end
end

local function goal_label(c)
    local g = df.army_controller_goal_type and df.army_controller_goal_type[c.goal]
    return g and g:lower():gsub('_', ' ') or 'mission'
end

-- 1) raiding parties --------------------------------------------------------
-- Raids are tracked as army_controllers that have fort squads assigned. The
-- travelling army itself is NOT flagged player, so we key off the controller;
-- assigned_squads clears when the mission ends, so a non-empty list = active.
local function report_raids()
    local fort = df.global.plotinfo.group_id
    local ac = df.global.world.army_controllers.all
    local raids = {}
    for i = 0, #ac - 1 do
        local c = ac[i]
        if c.assigned_squads and #c.assigned_squads > 0 then
            local fort_squads = 0
            for j = 0, #c.assigned_squads - 1 do
                local sq = df.squad.find(c.assigned_squads[j])
                if sq and sq.entity_id == fort then fort_squads = fort_squads + 1 end
            end
            if fort_squads > 0 then
                table.insert(raids, {c = c, squads = fort_squads})
            end
        end
    end
    if #raids == 0 then
        print('No raiding parties are currently out.')
        return
    end
    print(('%d raiding part%s out:'):format(#raids, #raids == 1 and 'y' or 'ies'))
    local now = now_ticks()
    for _, r in ipairs(raids) do
        local c = r.c
        local gone = now - (c.year * TICKS_PER_YEAR + c.year_tick)
        local who = leader_name(c) or 'a raiding party'
        local target = site_name(c.site_id)
        local where = target and (' on ' .. target) or ''
        print(('  - %s (%s%s): gone %s, %d squad%s'):format(
            who, goal_label(c), where, fmt_duration(gone), r.squads, r.squads == 1 and '' or 's'))
    end
end

-- 2) retrieve stuck units ---------------------------------------------------
local function fix_stuck_units()
    local ru = reqscript('fix/retrieve-units')
    local units = df.global.world.units.all
    local stuck = 0
    for i = 0, #units - 1 do
        local u = units[i]
        if u.flags1.inactive and ru.shouldRetrieve(u) then
            stuck = stuck + 1
        end
    end
    if stuck == 0 then
        print('No units stuck off-map.')
        return
    end
    ru.retrieveUnits()
    print(('Retrieved %d unit%s stuck off-map.'):format(stuck, stuck == 1 and '' or 's'))
end

report_raids()
fix_stuck_units()
