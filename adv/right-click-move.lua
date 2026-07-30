-- Adventure mode: right-click to move -- auto-take "Path to here" and confirm it.
--@module = true
--[[
adv/right-click-move

Right-clicking a tile in adventure mode opens a "What do you want to do?" menu offering only
two things -- "Path to here" and "Path to here (no climbing/jumping)" -- and then, once you
pick one, up to two more confirmations ("Finish action", "In conflict - finish anyway?").
That is four clicks to walk somewhere. With this running, a right-click just moves you.

    adv/right-click-move           start watching (idempotent)
    adv/right-click-move stop      stop
    adv/right-click-move status    running? how many handled?

Split out of adv/im-sure, which now only handles the "Continue waiting" prompt.

Driven by an OVERLAY, not a frame timer: while a menu or confirmation is open DF sits waiting
for input and `dfhack.timeout` frame timers FREEZE -- and a menu being open is precisely when
this has work to do. An overlay's onupdate is the only driver that keeps firing then.

PERFORMANCE -- this is why it was split out, and the thing to preserve in any edit here.
Identifying these menus needs their rendered TEXT, and a screen read is ~10,000
dfhack.screen.readTile calls. In adv/im-sure this check ran EVERY FRAME with no gate at all:
59 FPS with it running against 316 FPS without, about 80% of frame time.

The fix is a cheap authoritative gate in front of every scan:

    df.global.game.main_interface.adventure.option_list.open

That bool is true exactly while a context menu is on screen. Measured live with the menu up:
option_list.open=true, #option=2, context=DIRECT_CLICK, focus=dungeonmode/OptionList -- while
`adventure.commands` was 0. (im-sure's header concluded no struct tracked this menu; that was
drawn from `adventure.commands`, which really does stay empty. option_list is the one that
works.) So:

  1. NOTHING scans the screen unless option_list.open is true.
  2. The text check runs ONCE per menu appearance; the verdict is cached until it closes.
  3. The post-path confirmation watch is a bounded wall-clock window, throttled to one scan
     per CONFIRM_SCAN_MS -- transient, never steady-state.
  4. find_text uses one pcall for the whole scan, not one per tile, and returns on first hit.
]]

local overlay = require('plugins.overlay')

-- Timers are WALL CLOCK, not frame counts. This overlay fires once per render frame and this
-- game swings between ~60 and ~800 FPS, so a frame-count cooldown means wildly different real
-- delays -- a 50-frame retry gap silently became a 5-SECOND dead zone at low fire rates, which
-- reads exactly like "right-click does nothing".
local CONFIRM_WINDOW_MS = 9000   -- how long to watch for confirmations after a path
local CONFIRM_SCAN_MS = 250      -- min gap between confirmation screen scans
local RETRY_MS = 400             -- min gap between auto-select attempts on one menu
local CONFIRM_TEXTS = {'finish anyway', 'Finish action'}

running = running or false
autopathed = autopathed or 0   -- auto-selected "Path to here"
confirmed = confirmed or 0     -- "Finish action" / "In conflict" confirms

local function menu_on_screen()
    return df.global.game.main_interface.adventure.option_list.open
end

-- Find a string on the rendered screen; returns its top-left text cell + length. ~10k readTile
-- calls -- every caller must sit behind menu_on_screen(). One pcall wraps the whole scan
-- rather than one per tile, and it returns as soon as it hits.
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

-- read `len` text cells of row y starting at cell x
local function read_row(y, x, len)
    local gps = df.global.gps
    if y < 0 or y >= gps.dimy then return '' end
    local row = {}
    local ok = pcall(function()
        for cx = x, math.min(x + len, gps.dimx - 1) do
            local t = dfhack.screen.readTile(cx, y)
            local ch = t and t.ch or 0
            row[#row + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
    end)
    return ok and table.concat(row) or ''
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

local function feed_key(key)
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), key)
end

-- odd attempts feed the key; even attempts click the on-screen text instead
-- (fallback for menus that ignore synthetic key events)
local function press_or_click(attempt, key, needle)
    if attempt % 2 == 1 then
        feed_key(key)
    else
        local x, y, len = find_text(needle)
        if x then click_text(x, y, len) end
    end
end

-- The right-click "What do you want to do?" menu when pathing is the ONLY choice.
-- Measured live (2026-07): options render at a 3-row pitch, each prefixed by its
-- hotkey letter --
--   row Y   : a Path to here
--   row Y+3 : b Path to here (no climbing/jumping)
--   row Y+6 : (blank => there is no option c)
-- The "a " prefix requirement guarantees plain path IS the first option, so pressing
-- `a` can never hit an Attack/Talk entry in a bigger menu. CALLER MUST have checked
-- menu_on_screen() first -- this scans.
local function path_menu_open()
    local x, y = find_text('a Path to here')
    if not x then return false end
    if not read_row(y + 3, x, 50):find('b Path to here (no climbing/jumping)', 1, true) then
        return false
    end
    return read_row(y + 6, x, 50):match('^%s*$') ~= nil
end

-- watcher state (locals, reset on script reload -- counters above persist).
-- every timer is a millisecond deadline from dfhack.getTickCount(), never a frame count.
local a_attempts, retry_at = 0, 0
-- verdict for THIS menu appearance: nil = undecided, true/false = settled.
-- Only a POSITIVE verdict is cached outright. option_list.open flips one or more frames
-- BEFORE the menu is drawn, and path_menu_open() reads the last RENDERED frame -- so an
-- early check sees nothing. Latching that first "no" is what made this dead at high frame
-- rates (the first check lands ~1ms after the flip at 750 FPS, ~100ms at 10 fires/sec, which
-- is why it worked while throttled). So a negative is retried a few times before it sticks.
local verdict, verify_at, verify_tries = nil, 0, 0
local VERIFY_RETRY_MS, VERIFY_MAX_TRIES = 60, 10   -- ~0.6s of grace, <=10 scans per menu
local confirm_until, confirm_scan_at, c_attempts = 0, 0, 0

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end
    local now = dfhack.getTickCount()

    -- 1. auto-select "Path to here" when it's the only real choice
    if not menu_on_screen() then
        -- menu gone: drop the verdict AND the retry gap, so the very next right-click is
        -- acted on immediately instead of serving out a cooldown from the previous menu
        verdict, verify_at, verify_tries, a_attempts, retry_at = nil, 0, 0, 0, 0
    else
        if verdict == nil and now >= verify_at then
            verify_tries = verify_tries + 1
            if path_menu_open() then
                verdict = true                        -- settled: cache it, no more scanning
            elseif verify_tries >= VERIFY_MAX_TRIES then
                verdict = false                       -- genuinely some other menu: stop scanning
            else
                verify_at = now + VERIFY_RETRY_MS     -- probably just not drawn yet; look again
            end
        end
        if verdict and now >= retry_at then
            a_attempts = a_attempts + 1
            -- 'Path to here' matches the PLAIN option first (listed above the
            -- no-climbing variant), so the click fallback stays correct
            press_or_click(a_attempts, 'CUSTOM_A', 'Path to here')
            if a_attempts == 1 then autopathed = autopathed + 1 end
            retry_at = now + RETRY_MS
            confirm_until, confirm_scan_at, c_attempts = now + CONFIRM_WINDOW_MS, now + 150, 0
        end
    end

    -- 2. after pathing, dismiss "Finish action" / "In conflict - finish anyway?"
    if now < confirm_until and now >= confirm_scan_at then
        confirm_scan_at = now + CONFIRM_SCAN_MS
        local hit
        for _, needle in ipairs(CONFIRM_TEXTS) do
            if find_text(needle) then hit = needle break end
        end
        if hit then
            c_attempts = c_attempts + 1
            press_or_click(c_attempts, 'CUSTOM_C', hit)
            if c_attempts % 2 == 1 then confirmed = confirmed + 1 end
        end
    end
end

-- ---- overlay driver ---------------------------------------------------------

RightClickMove = defclass(RightClickMove, overlay.OverlayWidget)
RightClickMove.ATTRS{
    desc = 'Drives adv/right-click-move: right-click a tile to just walk there.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function RightClickMove:overlay_onupdate()
    pcall(step)
end

OVERLAY_WIDGETS = {watch = RightClickMove}

function stop()
    running = false
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/right-click-move: stopped.')
elseif arg == 'status' then
    print(('adv/right-click-move: %s | auto-path x%d | confirms x%d')
        :format(running and 'WATCHING' or 'stopped', autopathed, confirmed))
else
    if not dfhack.world.isAdventureMode() then
        qerror('adv/right-click-move only works in adventure mode')
    end
    running = true
    overlay.rescan()
    print('adv/right-click-move: watching -- right-click a tile and you just walk there.')
end
