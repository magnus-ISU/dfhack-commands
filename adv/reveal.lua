-- Adventure mode: keep the map revealed while it's safe, hide it when it matters.
--@module = true
--[[
adv/reveal

While nothing dangerous is going on, keeps the whole loaded map revealed by cycling
`unreveal` then `reveal` -- the cycle (rather than a single reveal) is what keeps the
reveal plugin's hidden-map backup fresh as new terrain scrolls into the loaded window.
The moment any of these starts, it runs `unreveal`:

    - combat        (the adventurer appears in a Conflict activity's sides)
    - travel        (the travel screen opens -- BEFORE the local map unloads)
    - sleep         (the sleep dialog opens, and while actually asleep)

    adv/reveal           start watching (idempotent)
    adv/reveal stop      stop, and unreveal if currently revealed
    adv/reveal status    running? revealed? cycle counts?

Driven by an OVERLAY like adv/right-click-move: onupdate fires every render frame even
while DF waits for input, which frame timers don't survive. All timers are wall-clock ms
from dfhack.getTickCount(), never frame counts (FPS here swings ~60-800).

Measured on this build (2026-07): `reveal` ~5ms, `unreveal` ~3ms -- cheap, but not
every-frame cheap, so the refresh cycle only runs when something calls for it:
entering the safe state, the map window moving (world.map.region_x/y/z shift as you
walk far -- that is exactly when hidden blocks scroll in), or a REFRESH_MS fallback.

STUCK-STATE RECOVERY, seen live: reveal while revealed says "Map is already revealed."
and unreveal after the map CHANGED under a live reveal (travel with the map revealed,
e.g. from a manual reveal before this script ran) says "Map is not available!". The
plugin's own `revforget` discards the stale backup; on any unexpected command output we
revforget and rebuild. That stale backup is also why unreveal-before-travel matters:
restore the real hidden flags while the map they belong to is still loaded.
]]

local overlay = require('plugins.overlay')

local DANGER_SCAN_MS = 100    -- how often to check combat/travel/sleep
local REFRESH_MS = 5000       -- safe-state fallback re-reveal cadence

running = running or false
revealed = revealed or false  -- do WE currently hold the map revealed
reveals = reveals or 0        -- completed unreveal+reveal refresh cycles
hides = hides or 0            -- danger-triggered unreveals
forgets = forgets or 0        -- stuck-state revforget recoveries
last_danger = last_danger or '(none yet)'

local function run(cmd)
    return dfhack.run_command_silent(cmd) or ''
end

-- true while the adventurer is a listed participant in any Conflict activity.
-- world.activities is small (tens); sides/unit_ids are a handful each.
local function in_combat()
    local me = dfhack.world.getAdventurer()
    if not me then return false end
    local id = me.id
    for _, act in ipairs(df.global.world.activities.all) do
        if act.type == df.activity_entry_type.Conflict then
            for _, ev in ipairs(act.events) do
                if df.activity_event_conflictst:is_instance(ev) then
                    for _, side in ipairs(ev.sides) do
                        for _, uid in ipairs(side.unit_ids) do
                            if uid == id then return true end
                        end
                    end
                end
            end
        end
    end
    return false
end

-- what makes us hide the map right now; nil when safe
local function danger()
    local menu = df.global.adventure.menu
    if menu == df.ui_advmode_menu.Travel then return 'travel screen' end
    if menu == df.ui_advmode_menu.TravelSleep then return 'travel sleep' end
    if menu == df.ui_advmode_menu.SleepConfirm then return 'sleep dialog' end
    if df.global.adventure.sleeping ~= 0 then return 'sleeping' end
    if in_combat() then return 'combat' end
    return nil
end

local function do_unreveal()
    if not revealed then return end
    local out = run('unreveal')
    if not out:find('Map hidden') then
        -- backup is stale (map changed under it) -- drop it rather than stay wedged
        run('revforget')
        forgets = forgets + 1
    end
    revealed = false
end

-- the unreveal-then-reveal refresh cycle
local function do_reveal()
    do_unreveal()
    local out = run('reveal')
    if not out:find('Map revealed') then
        run('revforget')
        forgets = forgets + 1
        out = run('reveal')
    end
    if out:find('Map revealed') then
        revealed = true
        reveals = reveals + 1
    end
end

-- watcher state (locals, reset on reload -- counters above persist)
local scan_at, refresh_at = 0, 0
local rx, ry, rz = -1, -1, -1   -- last seen map window origin

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end
    if not dfhack.isMapLoaded() then return end
    local now = dfhack.getTickCount()
    if now < scan_at then return end
    scan_at = now + DANGER_SCAN_MS

    local why = danger()
    if why then
        if revealed then
            do_unreveal()
            hides = hides + 1
            last_danger = why
        end
        return
    end

    local map = df.global.world.map
    local moved = map.region_x ~= rx or map.region_y ~= ry or map.region_z ~= rz
    if not revealed or moved or now >= refresh_at then
        rx, ry, rz = map.region_x, map.region_y, map.region_z
        refresh_at = now + REFRESH_MS
        do_reveal()
    end
end

-- ---- overlay driver ---------------------------------------------------------

AdvReveal = defclass(AdvReveal, overlay.OverlayWidget)
AdvReveal.ATTRS{
    desc = 'Drives adv/reveal: map revealed while safe, hidden in combat/travel/sleep.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function AdvReveal:overlay_onupdate()
    pcall(step)
end

OVERLAY_WIDGETS = {watch = AdvReveal}

function stop()
    running = false
    do_unreveal()
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/reveal: stopped -- map left unrevealed.')
elseif arg == 'status' then
    print(('adv/reveal: %s | map %s | reveal cycles x%d | hides x%d (last: %s) | recoveries x%d')
        :format(running and 'WATCHING' or 'stopped', revealed and 'REVEALED' or 'hidden',
                reveals, hides, last_danger, forgets))
else
    if not dfhack.world.isAdventureMode() then
        qerror('adv/reveal only works in adventure mode')
    end
    running = true
    overlay.rescan()
    print('adv/reveal: watching -- map stays revealed; combat, travel and sleep hide it.')
end
