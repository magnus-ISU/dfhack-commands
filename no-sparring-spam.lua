-- Automatically remove sparring combat reports from the announcements as soon as they appear.
--@module = true
--[[
Sparring (military training) floods the combat-report log with "X strikes at Y ... Y blocks"
spam (often 70%+ of world.status.reports). There is no distinct sparring announcement_type --
sparring uses the same COMBAT_* report types as real fights. The reliable discriminator: every
report is filed into the involved units' per-category report logs, and one category IS Sparring
(df.unit_report_type.Sparring). So a report is a sparring report exactly when its id appears in
some unit's reports.log[Sparring].

On start this clears the existing sparring backlog, then removes new sparring reports on a
repeat-util tick loop (10 ticks). repeat-util is used instead of a self-rescheduling
dfhack.timeout because the latter's chain did not survive being started from a transient
dfhack-run context. Wired into magnus-scripts; re-running is idempotent.
]]

local repeatUtil = require('repeat-util')

local SPARRING = df.unit_report_type.Sparring   -- 1
local status = df.global.world.status
local KEY = 'no-sparring-spam'

local seen = {}   -- unit id -> number of Sparring-log entries already accounted for

local function spar_log(u)
    return u.reports and u.reports.log and u.reports.log[SPARRING] or nil
end

-- erase every report whose id is in `ids` from a vector (full scan, from the newest end so the
-- shifts stay small)
local function erase_matching(vec, ids)
    local i = #vec - 1
    while i >= 0 do
        if ids[vec[i].id] then vec:erase(i) end
        i = i - 1
    end
end

local function remove(ids)
    if not next(ids) then return end
    erase_matching(status.announcements, ids)
    erase_matching(status.reports, ids)
end

-- every sparring report id currently referenced by any unit's Sparring log (for the initial sweep)
local function all_ids()
    local ids = {}
    for _, u in ipairs(df.global.world.units.active) do
        local log = spar_log(u)
        if log then for i = 0, #log - 1 do ids[log[i]] = true end end
    end
    return ids
end

-- ids of sparring reports that appeared since the last cycle; advances `seen`
local function new_ids()
    local ids = {}
    for _, u in ipairs(df.global.world.units.active) do
        local log = spar_log(u)
        if log then
            local n = #log
            local prev = seen[u.id]
            if prev == nil then prev = n end        -- unit new this cycle: don't retro-remove
            for i = prev, n - 1 do ids[log[i]] = true end
            seen[u.id] = n
        end
    end
    return ids
end

local function prime()
    seen = {}
    for _, u in ipairs(df.global.world.units.active) do
        local log = spar_log(u)
        if log then seen[u.id] = #log end
    end
end

function cycle()
    if not dfhack.world.isFortressMode() then return end
    remove(new_ids())
end

if dfhack_flags and dfhack_flags.module then return end

-- stop any old self-rescheduling loop from a previous version of this script
dfhack.internal.no_sparring_token = nil

local removed = #status.reports
remove(all_ids())                 -- clear the existing backlog
removed = removed - #status.reports
prime()
repeatUtil.scheduleEvery(KEY, 10, 'ticks', cycle)
print(('no-sparring-spam: cleared %d backlog sparring reports; removing new ones every 10 ticks.')
    :format(removed))
