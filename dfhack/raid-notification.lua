-- Notify-panel entry for squads out raiding + a weekly auto-unstuck.
--@module = false
--[[
Adds a notification (in the same panel as "moody dwarf...") showing squads that
are out on a raid/mission and the rough estimate of time until they're back:

    * mustering   -> "Urist McLeader is leaving to raid"  (not departed yet)
    * one squad   -> "Urist McLeader is raiding -- back in ~N days"
    * several     -> "N squads are raiding -- back in ~Z days"  (Z = soonest back)
    * overdue     -> "... back any minute now"            (estimate exceeded)
    * unknown     -> "... is raiding"                     (not yet estimable)

Every week it also runs fix/retrieve-units + fix/stuck-squad so stuck raiders get
pulled home. Click the notification to run the unstuck immediately.

Run once per session to register (add to dfhack.init / magnus-scripts to persist).
]]

local repeatUtil = require('repeat-util')

local NAME = 'raids'
local TICKS_PER_DAY  = 1200
local TICKS_PER_YEAR = 403200

local function now_ticks()
    return df.global.cur_year * TICKS_PER_YEAR + df.global.cur_year_tick
end

local function leader_name(c)
    if c.master_hf and c.master_hf >= 0 then
        local hf = df.historical_figure.find(c.master_hf)
        if hf then return dfhack.translation.translateName(hf.name) end
    end
end

-- active raids = army_controllers with fort squads assigned
local function get_raids()
    local fort = df.global.plotinfo.group_id
    local ac = df.global.world.army_controllers.all
    local raids = {}
    for i = 0, #ac - 1 do
        local c = ac[i]
        if c.assigned_squads and #c.assigned_squads > 0 then
            for j = 0, #c.assigned_squads - 1 do
                local sq = df.squad.find(c.assigned_squads[j])
                if sq and sq.entity_id == fort then
                    table.insert(raids, c)
                    break
                end
            end
        end
    end
    return raids
end

-- Days until this raid returns, from DF's own scheduled return time: the army's
-- mission_report is stamped with the year/year_tick the mission is due to wrap up
-- (the "Mission Report" filing = squads home). This is accurate (it's DF's plan),
-- not a speed/distance guess; the army can run a little late, in which case the
-- value goes negative and the caller shows "back any minute now". nil if there's
-- no schedule yet (just mustered).
local function remaining_days(c)
    local ok, val = pcall(function()
        local mr = c.mission_report
        if not mr then return nil end
        local ret = mr.year * TICKS_PER_YEAR + mr.year_tick
        local dep = c.year * TICKS_PER_YEAR + c.year_tick
        if ret <= dep then return nil end      -- no sane scheduled return yet
        return (ret - now_ticks()) / TICKS_PER_DAY
    end)
    return ok and val or nil
end

local function raid_message()
    if not dfhack.world.isFortressMode() then return end
    local raids = get_raids()
    if #raids == 0 then return end
    local now = now_ticks()
    -- pick the raid soonest to return (smallest remaining; fall back to longest gone)
    local best
    for _, c in ipairs(raids) do
        local elapsed = (now - (c.year * TICKS_PER_YEAR + c.year_tick)) / TICKS_PER_DAY
        local rem = remaining_days(c)
        local rank = rem or -elapsed                       -- no estimate: longer gone = sooner
        if not best or rank < best.rank then
            best = {c = c, elapsed = elapsed, rem = rem, rank = rank}
        end
    end
    -- describe the raid purely by time left (no elapsed-time wording)
    local function eta_phrase()
        if best.rem == nil then return 'raiding' end           -- can't estimate yet
        if best.rem <= 0 then return 'raiding -- back any minute now' end
        local r = math.max(1, math.floor(best.rem + 0.5))
        return ('raiding -- back in ~%d day%s'):format(r, r == 1 and '' or 's')
    end
    local leaving = best.elapsed < 1                            -- not yet departed
    if #raids == 1 then
        local who = leader_name(best.c) or 'A squad'
        if leaving then return ('%s is leaving to raid'):format(who) end
        return ('%s is %s'):format(who, eta_phrase())
    else
        if leaving then return ('%d squads are leaving to raid'):format(#raids) end
        return ('%d squads are %s'):format(#raids, eta_phrase())
    end
end

-- weekly: pull home stuck raiders
local function unstuck()
    if not dfhack.world.isFortressMode() then return end
    pcall(function() reqscript('fix/retrieve-units').retrieveUnits() end)
    pcall(function() dfhack.run_command('fix/stuck-squad') end)
end

local function register()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Shows squads out raiding and roughly when they will return.'
    entry.dwarf_fn = raid_message
    entry.on_click = unstuck
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
    repeatUtil.scheduleEvery('raid-notification-unstuck', 7, 'days', unstuck)
end

register()

dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_MAP_LOADED then
        register()
    elseif ev == SC_MAP_UNLOADED then
        repeatUtil.cancel('raid-notification-unstuck')
    end
end

print('raid-notification: registered "raids" notification + weekly unstuck.')
