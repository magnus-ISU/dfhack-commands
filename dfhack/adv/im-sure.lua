-- Adventure mode: auto-click "Continue waiting".
--@module = true
--[[
adv/im-sure

During long-running actions (slow walking, waiting, being pinned) the game
interrupts with a "You haven't been able to act for a while" prompt that must
be acknowledged by clicking its **Continue waiting** button. The prompt has NO
dialog struct (verified: nothing in main_interface opens; keyboard feeds don't
reach it) -- only the on-screen button works. This watches for the prompt state
(`adventure.player_control_state == TAKING_TOO_LONG_INPUT`), finds the literal
button text by READING THE SCREEN, and clicks it.

    adv/im-sure           start watching (idempotent)
    adv/im-sure stop      stop
    adv/im-sure status    running? how many handled?

The watcher is driven by an OVERLAY, not a frame timer: while a menu or
confirmation is open DF sits waiting for input and `dfhack.timeout` frame timers
FREEZE -- an overlay's onupdate is the only driver that keeps firing then.

The right-click "Path to here" auto-select and its finish-action confirmations
used to live here too; they are now adv/right-click-move. They were split out on
performance grounds: identifying those menus needs a screen read (~10k
dfhack.screen.readTile calls), and the check ran EVERY FRAME with no gate --
measured at 59 FPS with this script running against 316 FPS without, i.e. about
80% of frame time. What is left here scans only while the prompt state is
actually set, and at most once a second, so it costs nothing at rest.
]]

local overlay = require('plugins.overlay')

running = running or false
dismissed = dismissed or 0     -- "Continue waiting" clicks

-- Find a string on the rendered screen; returns its top-left text cell + length. This is
-- ~10k readTile calls -- NEVER put it on an ungated per-frame path. One pcall wraps the
-- whole scan rather than one per tile, and it returns as soon as it hits.
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

-- click the middle of a text-cell run (text cells are gps.tile_pixel_x/y sized)
local function click_text(x, y, len)
    local gps = df.global.gps
    local cx = x + len // 2
    gps.mouse_x, gps.mouse_y = cx, y
    gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
    gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
end

-- exported: find and click "Continue waiting"; true if the button was found
function dismiss()
    local x, y, len = find_text('Continue waiting')
    if not x then x, y, len = find_text('Continue') end
    if not x then return false end
    click_text(x, y, len)
    return true
end

-- per-frame watcher state (locals, reset on script reload -- the counter above persists)
local stuck, cooldown = 0, 0

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end

    -- the prompt state is a single enum read; the screen scan below happens only inside it
    local prompt = df.global.adventure.player_control_state
        == df.adventure_game_loop_type.TAKING_TOO_LONG_INPUT
    if not prompt then
        stuck, cooldown = 0, 0
        return
    end

    stuck = stuck + 1
    if cooldown > 0 then cooldown = cooldown - 1 end
    -- give the prompt a moment to render, then click; retry at ~1/second.
    -- the cooldown is what keeps the screen scan off the per-frame path.
    if stuck > 15 and cooldown <= 0 then
        if dismiss() then dismissed = dismissed + 1 end
        cooldown = 100
    end
end

-- ---- overlay driver ---------------------------------------------------------
-- onupdate fires every render frame even while DF waits for input, which is exactly
-- when frame timers stall -- and waiting for input is the whole point here.

ImSureOverlay = defclass(ImSureOverlay, overlay.OverlayWidget)
ImSureOverlay.ATTRS{
    desc = 'Drives adv/im-sure: auto-dismisses the adventure "Continue waiting" prompt.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function ImSureOverlay:overlay_onupdate()
    pcall(step)
end

OVERLAY_WIDGETS = {watch = ImSureOverlay}

function stop()
    running = false
end

if dfhack_flags.module then return end

if not dfhack.world.isAdventureMode() then
    qerror('adv/im-sure only works in adventure mode')
end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/im-sure: stopped.')
elseif arg == 'status' then
    print(('adv/im-sure: %s | "Continue waiting" x%d')
        :format(running and 'WATCHING' or 'stopped', dismissed))
else
    running = true
    overlay.rescan()
    print('adv/im-sure: watching -- the "Continue waiting" prompt is clicked for you.'
        .. ' (Right-click pathing is now adv/right-click-move.)')
end
