-- Automatically remove sparring combat reports from the announcements as soon as they appear.
--@module = true
--[[
Sparring (military training) floods the announcement feed and combat-report log with
"X strikes at Y ... Y blocks" spam. There is no distinct sparring announcement_type -- sparring
uses the same COMBAT_* report types as real fights. The reliable discriminator: every report is
filed into the involved units' per-category report logs, and one of those categories IS Sparring
(df.unit_report_type.Sparring). So a report is a sparring report exactly when its id appears in
some unit's reports.log[Sparring].

This script primes on start (so existing history is left alone) and then, on a short tick loop,
watches each unit's Sparring log for NEW ids and erases those reports from both
world.status.announcements (the notification feed) and world.status.reports (the combat log).
Re-running it restarts the loop; it is idempotent. Wired into magnus-scripts.
]]

local SPARRING = df.unit_report_type.Sparring   -- 1
local status = df.global.world.status

local seen = {}   -- unit id -> number of Sparring-log entries already accounted for

local function spar_log(u)
    return u.reports and u.reports.log and u.reports.log[SPARRING] or nil
end

-- record current Sparring-log lengths so only reports created AFTER this are ever removed
local function prime()
    seen = {}
    for _, u in ipairs(df.global.world.units.active) do
        local log = spar_log(u)
        if log then seen[u.id] = #log end
    end
end

-- gather the ids of sparring reports that appeared since the last cycle
local function collect_new()
    local ids, any = {}, false
    for _, u in ipairs(df.global.world.units.active) do
        local log = spar_log(u)
        if log then
            local n = #log
            local prev = seen[u.id]
            if prev == nil then prev = n end        -- unit new this cycle: don't retro-remove
            for i = prev, n - 1 do ids[log[i]] = true; any = true end
            seen[u.id] = n
        end
    end
    return any and ids or nil
end

-- erase reports whose id is in `ids` from a vector, scanning from the newest end (that is where
-- just-created reports live) with a bound so we never sweep the whole 10k-entry log each cycle
local function erase_from(vec, ids)
    local i, scanned = #vec - 1, 0
    while i >= 0 and scanned < 2000 do
        if ids[vec[i].id] then vec:erase(i) end
        i, scanned = i - 1, scanned + 1
    end
end

function cycle()
    local ids = collect_new()
    if ids then
        erase_from(status.announcements, ids)
        erase_from(status.reports, ids)
    end
end

-- ---- run loop ---------------------------------------------------------------

local token   -- identity of the currently-live loop; re-running supersedes the old one

local function loop()
    if dfhack.internal.no_sparring_token ~= token then return end   -- superseded by a re-run
    if dfhack.world.isFortressMode() then pcall(cycle) end
    dfhack.timeout(10, 'ticks', loop)
end

if dfhack_flags and dfhack_flags.module then return end

prime()
token = {}
dfhack.internal.no_sparring_token = token
loop()
print('no-sparring-spam: sparring reports will be removed from the feed as they appear.')
