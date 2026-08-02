-- Adventure mode: stop auto-walking the moment you take a wound.
--@module = true
--[[
adv/fear-death
==============

Tags: adventure | auto

Click-to-walk marches your adventurer to the destination no matter what
happens on the way: an ambusher can open you up on step two and the walk
keeps feeding turns to the enemy until you arrive.  With this overlay
loaded, taking a wound mid-walk silently presses the game's own
**Stop Action** button for you, and you are back at input, yours to
react with.

What counts as wounded (all verified against a live frame log of a
captain beating on the adventurer):

- Every strike that does tissue damage -- even a bruise through armor --
  mints a new wound record, so the trigger is `unit.body.wound_next_id`
  ticking up.  Blocked, dodged and armor-deflected attacks mint nothing
  and do NOT stop the walk.
- Blood loss alone is deliberately NOT a trigger: you may well be walking
  BECAUSE you bleed, and an open wound drips every few frames -- keying on
  it would pin a bleeding adventurer in place.  Only fresh damage stops
  the walk.

Why the cancel is a BUTTON CLICK and nothing else.  A click-walk is
`unit.path` (dest + step queue) plus per-step Move `unit_action`s that DF
auto-passes frames for (enemies act free the whole time; a stunned step
counts down from ~70 frames instead of ~15).  Editing that state does
not work: clear the path and DF re-paths it when the in-flight step
lands; void the actions too and the UI-side walk is still armed -- the
player ends up standing still with no input focus until they press
**b Stop Action** themselves (the v1/v2 bug of this script).  The button
is also unreachable by fed keys -- `CUSTOM_B` bounces off it, exactly
like the "Continue waiting" prompt in adv/im-sure -- so this does what
im-sure does: READ THE SCREEN for the literal button text and click it.
DF then unwinds its own walk state, which it demonstrably does right.

The screen scan (~10k readTile calls) runs only when a wound lands
mid-walk, then every 100ms (wall clock) while movement persists (a view
sheet can cover the button; the walk pauses under menus and the retry
catches it on close), giving up after 10 seconds.  It costs nothing at
rest.

The wound baseline resyncs every frame and whenever the adventurer
changes (new game, reload, body swap), so a reload or a full-heal never
false-triggers.

    adv/fear-death           status (the overlay is on by default)

Manage it with gui/control-panel (Overlays tab), like any overlay.
]]

local overlay = require('plugins.overlay')

local NONE = -30000            -- unit.path.dest sentinel: no pathing goal
local GIVE_UP_MS = 10000       -- how long we keep trying to stop
local RETRY_MS = 100           -- wall-clock pause between button clicks

local last_unit, last_wid = nil, nil
local latch_until, last_try = 0, 0

-- Find a string on the rendered screen; top-left text cell + length (the
-- adv/im-sure pattern).  ~10k readTile calls -- never on an ungated
-- per-frame path.
local function find_text(needle)
    local gps = df.global.gps
    local readTile, char = dfhack.screen.readTile, string.char
    local dimx, dimy = gps.dimx, gps.dimy
    local fx, fy, flen
    pcall(function()
        local row = {}
        for y = 0, dimy - 1 do
            for x = 0, dimx - 1 do
                local t = readTile(x, y)
                local ch = t and t.ch or 0
                row[x + 1] = (ch >= 32 and ch < 127) and char(ch) or ' '
            end
            local i = table.concat(row, '', 1, dimx):find(needle, 1, true)
            if i then fx, fy, flen = i - 1, y, #needle return end
        end
    end)
    return fx, fy, flen
end

local function click_text(x, y, len)
    local gps = df.global.gps
    local cx = x + len // 2
    gps.mouse_x, gps.mouse_y = cx, y
    gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
    gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
end

-- click the game's own Stop Action button; true if it was on screen
local function press_stop()
    local x, y, len = find_text('Stop Action')
    if not x then x, y, len = find_text('Stop action') end
    if not x then return false end
    click_text(x, y, len)
    return true
end

local function moving(u)
    if u.path.dest.x ~= NONE then return true end
    for i = 0, #u.actions - 1 do
        if u.actions[i].type == df.unit_action_type.Move then return true end
    end
    return false
end

local function check()
    local u = df.global.world.units.adv_unit
    if not u then last_unit = nil; latch_until = 0 return end
    local wid = u.body.wound_next_id
    if u.id ~= last_unit then          -- new adventurer / reload: just resync
        last_unit, last_wid, latch_until = u.id, wid, 0
        return
    end
    local now = dfhack.getTickCount()
    if latch_until > 0 then
        if not moving(u) or now > latch_until then
            latch_until = 0            -- stopped (or gave up): done
        elseif now - last_try >= RETRY_MS then
            press_stop()
            last_try = now
        end
    elseif moving(u) and wid > last_wid then
        latch_until, last_try = now + GIVE_UP_MS, now
        press_stop()
    end
    last_wid = wid
end

FearDeath = defclass(FearDeath, overlay.OverlayWidget)
FearDeath.ATTRS{
    desc = 'Presses Stop Action for you when the adventurer is wounded mid-walk.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function FearDeath:overlay_onupdate()
    pcall(check)
end

OVERLAY_WIDGETS = {stop = FearDeath}

if dfhack_flags.module then return end

local u = df.global.world.units.adv_unit
if u then
    local walking = u.path.dest.x ~= NONE
    print(('adv/fear-death: watching %s -- %s.'):format(
        dfhack.units.getReadableName(u),
        walking and ('currently walking to %d,%d,%d'):format(
            u.path.dest.x, u.path.dest.y, u.path.dest.z)
        or 'not currently on a walk'))
else
    print('adv/fear-death: no adventurer loaded.')
end
print('A wound taken mid-walk now presses Stop Action for you.'
    .. ' Manage the overlay with gui/control-panel.')
