-- Automatically clear the fort's sparring notification alerts as they appear.
--@module = true
--@enable = true
--[[
no-sparring-spam

Military training fills the notification strip with sparring alerts -- DF groups every
sparring blow into an `announcement_alert_type.SPARRING` button that reappears the moment
the next squad starts drilling, so it is permanently in the way and buries the alerts you
actually want to read (a job failure, a guest, a real fight).

This removes the sparring alert button, but not the instant it appears: it waits for the
bout to finish. Every pass asks whether sparring is still going on, and the button is only
taken away once THREE SECONDS of RUNNING FORT have passed with no new sparring report. Squads
drill in flurries, and clearing mid-flurry just means DF rebuilds the button a moment later;
three seconds is long enough to sit out the gaps between blows, so it is one removal per bout
instead of a button that flickers while they train.

The clock only turns while the world does. A paused fort files no sparring reports, so counting
wall-clock time there meant the button was always taken away while you sat reading -- the combat
log, say -- which is the one moment you might want it.

Nothing else about sparring changes: the reports themselves stay in the combat logs, so a
unit's Sparring report category still reads back in full -- only the alert button is dropped.

How it identifies them: `world.status.announcement_alert` holds one `announcement_alertst`
per live alert button, and its `type` names the category, so a sparring button is exactly
`type == df.announcement_alert_type.SPARRING`. That makes the check O(number of buttons)
-- a handful -- with no unit or report scan at all. (The previous version of this script
walked `units.active` every 10 ticks looking for reports filed under
`unit_report_type.Sparring`; it was deleted for that cost. This does not do that.)

"Is sparring still going on" is answered from the button itself, at the same cost. The alert
names the units involved, and each of those units keeps a count of its own Sparring reports,
so the pass reads a handful of units the button already points at -- never the unit list --
and a new blow anywhere in the bout moves that total. The clock is real time, but only the parts of it
where the fort was actually running, so a slow fort still gets its full three seconds and a
paused one never runs the window down at all.

Removing a button means: erase its entry from `world.status.announcement_alert` and free it,
drop every report id it carried from the sorted `world.status.alert_button_announcement_id`
vector, and reset `main_interface.hover_announcement_alert_button_width` to 0 -- DF zeroes
that width itself whenever an alert is created, so leaving a width behind that was measured
for a button that no longer exists is not worth the risk. Any interface pointer aimed at the
button being freed (`announcement_alert.viewing_alert`, `current_hover_alert`,
`hover_announcement_alert`) is nulled first so nothing is left dangling, and a pass is
skipped entirely while the alert panel is open, so a button can never be pulled out from
under you mid-read.

    enable no-sparring-spam     clear sparring alerts from now on (persists with the fort)
    disable no-sparring-spam    stop
    no-sparring-spam            clear what is showing right now, without waiting, and report

Add `enable no-sparring-spam` to magnus-scripts / dfhack.init to run it every session.
]]

local GLOBAL_KEY = 'no-sparring-spam'
local SCAN_FRAMES = 10       -- the pass is a walk of a handful of alert buttons; cheap enough
                             -- to run often, so the button goes away as fast as it appears

local SPARRING = df.announcement_alert_type.SPARRING
local SPAR_LOG = df.unit_report_type.Sparring
local QUIET_MS = 3000        -- how long sparring must have been over before the button goes

-- ---- the work ---------------------------------------------------------------

-- Erase `id` from a SORTED int32 vector (binary search). Returns true if it was there.
local function erase_sorted(vec, id)
    local lo, hi = 0, #vec - 1
    while lo <= hi do
        local mid = (lo + hi) // 2
        local v = vec[mid]
        if v == id then vec:erase(mid) return true
        elseif v < id then lo = mid + 1
        else hi = mid - 1 end
    end
    return false
end

-- Null every interface pointer aimed at `alert`, so freeing it leaves nothing dangling.
local function unreference(alert)
    local mi = df.global.game.main_interface
    if mi.announcement_alert.viewing_alert == alert then
        mi.announcement_alert.viewing_alert = nil
    end
    if mi.current_hover_alert == alert then mi.current_hover_alert = nil end
    if mi.hover_announcement_alert == alert then mi.hover_announcement_alert = nil end
end

-- How much sparring has happened, as one number. The alert button names the units in the
-- bout, and every unit counts its own Sparring reports, so a new blow anywhere moves this
-- total. Reading it costs a handful of unit lookups -- the ones the button already points
-- at -- and never touches the unit list.
local function sparring_activity()
    local st = df.global.world.status
    local total, seen = 0, false
    for _, a in ipairs(st.announcement_alert) do
        if a.type == SPARRING then
            seen = true
            total = total + #a.announcement_id + #a.report_unid
            for j = 0, #a.report_unid - 1 do
                local u = df.unit.find(a.report_unid[j])
                local log = u and u.reports and u.reports.log[SPAR_LOG]
                if log then total = total + #log end
            end
        end
    end
    if not seen then return nil end     -- no sparring button at all: nothing to wait for
    return total
end

-- the quiet window, kept across heartbeat ticks (the script's environment survives reloads)
watch = watch or {count = nil, quiet_ms = 0, last_ms = nil, last_frame = nil}

-- Is the bout over? True once the activity total has stood still for QUIET_MS of RUNNING game
-- time. Anything that moves the total restarts the clock.
--
-- THE CLOCK ONLY TURNS WHILE THE WORLD DOES. Wall-clock time was wrong: with the game paused --
-- reading the combat log, say -- no new sparring report can possibly arrive, so the window
-- always expired and the button was taken away under the player while they were looking at it.
-- Elapsed real time is only counted for a pass where the frame counter has moved since the last
-- one, which is exactly "three seconds of unpaused fort".
local function sparring_is_quiet()
    local count = sparring_activity()
    local now = dfhack.getTickCount()
    local frame = df.global.world.frame_counter or 0
    if not count then                    -- button gone: forget the window
        watch.count, watch.quiet_ms, watch.last_ms, watch.last_frame = nil, 0, now, frame
        return false
    end
    if watch.count ~= count then         -- a new sparring report: still going on
        watch.count, watch.quiet_ms = count, 0
        watch.last_ms, watch.last_frame = now, frame
        return false
    end
    -- getTickCount can jump backwards across a reload; treat that as a fresh start rather than
    -- as a very long quiet period
    if not watch.last_ms or now < watch.last_ms then
        watch.last_ms, watch.last_frame = now, frame
        return false
    end
    if frame ~= watch.last_frame then    -- the world moved: this interval counts
        watch.quiet_ms = watch.quiet_ms + (now - watch.last_ms)
    end
    watch.last_ms, watch.last_frame = now, frame
    return watch.quiet_ms >= QUIET_MS
end

-- One pass: drop every sparring alert button. Returns how many were removed.
function clear_sparring_alerts()
    local st = df.global.world.status
    local mi = df.global.game.main_interface
    -- The panel is open: the player is reading an alert right now, and DF is holding
    -- pointers into the entry (and into its zoom lines) while it renders. Leave it be;
    -- the next pass gets it.
    if mi.announcement_alert.open then return 0 end
    local removed = 0
    for i = #st.announcement_alert - 1, 0, -1 do
        local alert = st.announcement_alert[i]
        if alert.type == SPARRING then
            for j = 0, #alert.announcement_id - 1 do
                erase_sorted(st.alert_button_announcement_id, alert.announcement_id[j])
            end
            unreference(alert)
            st.announcement_alert:erase(i)
            alert:delete()
            removed = removed + 1
        end
    end
    if removed > 0 then
        -- DF measures this width for whichever button is under the cursor; every alert it
        -- creates resets it to 0. Do the same rather than leave a width sized for a button
        -- that is gone.
        mi.hover_announcement_alert_button_width = 0
        watch.count, watch.quiet_ms = nil, 0
    end
    return removed
end

-- What the heartbeat calls: clear, but only once the bout has been over for a second.
function clear_when_quiet()
    if not sparring_is_quiet() then return 0 end
    return clear_sparring_alerts()
end

-- ---- enable state (persisted per fort) --------------------------------------

state = state or nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.enabled == nil then state.enabled = false end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
function isEnabled() return load_state().enabled end

-- ---- heartbeat (every SCAN_FRAMES; survives reloads via dfhack.internal) -----

local function hb_gen(set)
    if set ~= nil then dfhack.internal.no_sparring_spam_hb_gen = set end
    return dfhack.internal.no_sparring_spam_hb_gen or 0
end
local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        if dfhack.world.isFortressMode() then clear_when_quiet() end
        dfhack.timeout(SCAN_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

function set_enabled(v)
    load_state()
    state.enabled = v
    save_state()
    if v then start_heartbeat() else stop_heartbeat() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- entry point ------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then qerror('no-sparring-spam only works in fortress mode') end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('no-sparring-spam: ' .. (isEnabled() and 'ENABLED (clearing sparring alerts)' or 'disabled'))
    return
end

local removed = clear_sparring_alerts()
print(('no-sparring-spam: cleared %d sparring alert%s.'):format(removed, removed == 1 and '' or 's'))
