-- Adventure mode: auto-click "Continue waiting" + auto-confirm pathing prompts.
--@module = true
--[[
adv/im-sure

Two annoyance-killers for adventure mode, in one watcher:

1. During long-running actions (slow walking, waiting, being pinned) the game
   interrupts with a "You haven't been able to act for a while" prompt that must
   be acknowledged by clicking its **Continue waiting** button. The prompt has NO
   dialog struct (verified: nothing in main_interface opens; keyboard feeds don't
   reach it) -- only the on-screen button works. This watches for the prompt state
   (`adventure.player_control_state == TAKING_TOO_LONG_INPUT`), finds the literal
   button text by READING THE SCREEN, and clicks it.

2. When the right-click context menu offers ONLY the two pathing choices --
   "Path to here" and "Path to here (no climbing/jumping)" (detected as exactly
   two entries in `adventure.commands` plus the literal menu text on screen) --
   it presses `a` to take the plain "Path to here", then watches a few seconds
   for the follow-up confirmations, "Finish action" and "In conflict - finish
   anyway?", and presses `c` on each one that appears. If a key feed bounces off
   the menu (DF50 widgets sometimes ignore synthetic keys), the retry clicks the
   option/button text directly.

The watcher is driven by an OVERLAY, not a frame timer: while a menu or
confirmation is open DF sits waiting for input and `dfhack.timeout` frame timers
FREEZE -- an overlay's onupdate is the only driver that keeps firing then.

    adv/im-sure           start watching (idempotent)
    adv/im-sure stop      stop
    adv/im-sure status    running? how many handled?
]]

local overlay = require('plugins.overlay')

running = running or false
dismissed = dismissed or 0     -- "Continue waiting" clicks
autopathed = autopathed or 0   -- auto-selected "Path to here"
confirmed = confirmed or 0     -- "Finish action" / "In conflict" confirms

-- find a text string on the rendered screen; returns its top-left text cell + length
local function find_text(needle)
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local row = {}
        for x = 0, gps.dimx - 1 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            local ch = ok and t and t.ch or 0
            row[#row + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local i = table.concat(row):find(needle, 1, true)
        if i then return i - 1, y, #needle end
    end
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

-- exported: find and click "Continue waiting"; true if the button was found
function dismiss()
    local x, y, len = find_text('Continue waiting')
    if not x then x, y, len = find_text('Continue') end
    if not x then return false end
    click_text(x, y, len)
    return true
end

-- read `len` text cells of row y starting at cell x
local function read_row(y, x, len)
    local gps = df.global.gps
    if y < 0 or y >= gps.dimy then return '' end
    local row = {}
    for cx = x, math.min(x + len, gps.dimx - 1) do
        local ok, t = pcall(dfhack.screen.readTile, cx, y)
        local ch = ok and t and t.ch or 0
        row[#row + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(row)
end

-- The right-click "What do you want to do?" menu when pathing is the ONLY choice.
-- Measured live (2026-07): options render at a 3-row pitch, each prefixed by its
-- hotkey letter --
--   row Y   : a Path to here
--   row Y+3 : b Path to here (no climbing/jumping)
--   row Y+6 : (blank => there is no option c)
-- The "a " prefix requirement guarantees plain path IS the first option, so
-- pressing `a` can never hit an Attack/Talk entry in a bigger menu. NOTE: the
-- menu populates NO struct we could find (adventure.commands stays empty) --
-- the rendered text is the only readable state.
local function path_menu_open()
    local x, y = find_text('a Path to here')
    if not x then return false end
    if not read_row(y + 3, x, 50):find('b Path to here (no climbing/jumping)', 1, true) then
        return false
    end
    return read_row(y + 6, x, 50):match('^%s*$') ~= nil
end

local CONFIRM_WINDOW = 900   -- overlay frames (~9s) to watch for confirmations
local CONFIRM_TEXTS = {'finish anyway', 'Finish action'}

-- per-frame watcher state (locals, reset on script reload -- counters above persist)
local stuck, cooldown = 0, 0
local menu_cd, a_attempts = 0, 0
local confirm_left, confirm_cd, c_attempts = 0, 0, 0

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end

    -- 1. the "haven't been able to act for a while" prompt
    local prompt = df.global.adventure.player_control_state
        == df.adventure_game_loop_type.TAKING_TOO_LONG_INPUT
    if prompt then
        stuck = stuck + 1
        if cooldown > 0 then cooldown = cooldown - 1 end
        -- give the prompt a moment to render, then click; retry at ~1/second
        if stuck > 15 and cooldown <= 0 then
            if dismiss() then dismissed = dismissed + 1 end
            cooldown = 100
        end
    else
        stuck, cooldown = 0, 0
    end

    -- 2. auto-select "Path to here" when it's the only real choice
    if menu_cd > 0 then menu_cd = menu_cd - 1 end
    if menu_cd <= 0 then
        if path_menu_open() then
            a_attempts = a_attempts + 1
            -- 'Path to here' matches the PLAIN option first (listed above the
            -- no-climbing variant), so the click fallback stays correct
            press_or_click(a_attempts, 'CUSTOM_A', 'Path to here')
            if a_attempts == 1 then autopathed = autopathed + 1 end
            menu_cd = 50
            confirm_left = CONFIRM_WINDOW
            confirm_cd = 10   -- let the first confirmation render
            c_attempts = 0
        else
            a_attempts = 0
        end
    end

    -- 3. after pathing, dismiss "Finish action" / "In conflict - finish anyway?"
    if confirm_left > 0 then
        confirm_left = confirm_left - 1
        if confirm_cd > 0 then confirm_cd = confirm_cd - 1 end
        -- scan the screen at most a few times a second
        if confirm_cd <= 0 and confirm_left % 10 == 0 then
            local hit = nil
            for _, needle in ipairs(CONFIRM_TEXTS) do
                if find_text(needle) then hit = needle break end
            end
            if hit then
                c_attempts = c_attempts + 1
                press_or_click(c_attempts, 'CUSTOM_C', hit)
                if c_attempts % 2 == 1 then confirmed = confirmed + 1 end
                confirm_cd = 30
            end
        end
    end
end

-- ---- overlay driver ---------------------------------------------------------
-- onupdate fires every render frame even while DF waits for input (menus,
-- confirmations), which is exactly when frame timers stall.

ImSureOverlay = defclass(ImSureOverlay, overlay.OverlayWidget)
ImSureOverlay.ATTRS{
    desc = 'Drives adv/im-sure: auto-dismisses adventure prompts and lone path menus.',
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
    print(('adv/im-sure: %s | "Continue waiting" x%d | auto-path x%d | confirms x%d')
        :format(running and 'WATCHING' or 'stopped', dismissed, autopathed, confirmed))
else
    running = true
    overlay.rescan()
    print('adv/im-sure: watching -- "Continue waiting", lone "Path to here" menus,'
        .. ' and the finish-action confirmations are handled for you.')
end
