-- Adventure mode: periodically save the game to an "adventure-autosave" folder.
--@module = true
--[[
adv/autosave

Adventure mode has no save command, so this drives DF's own manual-save code
path every N minutes (default 20). It is pure data + two fed keys -- no mouse
clicks, no external tools:

    1. feed OPTIONS                     -> the escape menu opens
    2. options.entering_manual_str = "adventure-autosave"   (the folder name)
       options.do_manual_save = true, manual_save_timer = 5 -> DF saves
    3. wait for options.saver.stage to come back to 51      (save finished)
    4. clear entering_manual_folder / confirm_manual_overwrite, feed LEAVESCREEN

Notes from working this out live against DF 53.15:

* `plotinfo.main.autosave_request` (what `quicksave` uses in fortress mode) is
  never consumed by the adventure loop, and `do_manual_save` is only processed
  while the escape menu is OPEN -- hence step 1.
* Setting `do_manual_save` directly skips the name prompt AND the
  "folder already exists, overwrite?" prompt, so nothing has to be clicked.
  That matters because those buttons are hover-driven: a fed `_MOUSE_L` lands
  wherever the real pointer happens to be, and can activate the wrong one.
* DF re-opens the name prompt when the save finishes, and a fed `LEAVESCREEN`
  does NOT reach a text-entry dialog -- that is the "press Escape three times"
  trap. Clearing the two prompt flags first makes one fed Escape close the menu.
* **Completion is read from the game, never from disk**: `options.saver.stage`
  climbs back to 51 when the save is done. (Under Steam the script's idea of the
  save path is redirected, so file timestamps cannot be trusted anyway.)
* Frame timers freeze while the menu is up, so a timer loop AND an overlay
  watchdog both step the machine.

A cycle only starts from a calm `dungeonmode/Default` frame, so it never
interrupts combat prompts, menus or fast travel.

HEADS UP: a manual save makes that folder DF's active save, so after the first
autosave the game continues in (and later saves to) "adventure-autosave"; the
folder you started from is left untouched at its last save.

    adv/autosave           start with the current interval (default 20 min)
    adv/autosave 15        start, saving every 15 minutes
    adv/autosave now       run a save cycle immediately
    adv/autosave cleanup   clear a stuck save dialog / close the options menu
    adv/autosave stop      stop
    adv/autosave status    running? interval? saves so far? last result?
]]

local overlay = require('plugins.overlay')

running = running or false
interval_min = interval_min or 20
next_at = next_at or 0
saves_done = saves_done or 0
last_result = last_result or 'none yet'

local SAVE_NAME    = 'adventure-autosave'
local SAVER_DONE   = 51    -- options.saver.stage once a save has completed
local SAVE_TIMEOUT = 600   -- seconds a single save may take before we give up

local function opts()
    return df.global.game.main_interface.options
end

local function feed_key(key)
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), key)
end

-- the two prompt flags that make a fed LEAVESCREEN bounce off the menu
local function clear_prompts()
    local o = opts()
    o.entering_manual_folder = false
    o.confirm_manual_overwrite = false
end

local function announce(msg, color)
    print('adv/autosave: ' .. msg)
    pcall(dfhack.gui.showAnnouncement, 'adv/autosave: ' .. msg, color or COLOR_GREEN)
end

-- ---- state machine -------------------------------------------------------------

local state, st_frames, st_started = 'idle', 0, 0
local saw_progress, failure, esc_tries = false, nil, 0

local function enter(s)
    state, st_frames, st_started = s, 0, os.time()
end

local function fail(why)
    failure = why
    enter('done')
end

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end
    st_frames = st_frames + 1
    local o = opts()

    if state == 'idle' then
        if os.time() < next_at or not dfhack.isMapLoaded() then return end
        local focus = dfhack.gui.getCurFocus(true)
        if #focus ~= 1 or focus[1] ~= 'dungeonmode/Default' then return end
        if o.open or not dfhack.world.getAdventurer() then return end
        saw_progress, failure, esc_tries = false, nil, 0
        feed_key('OPTIONS')
        enter('arm')

    elseif state == 'arm' then
        if o.open then
            -- name the save, then hand DF the same request its own menu makes
            clear_prompts()
            o.entering_manual_str = SAVE_NAME
            o.do_manual_save = true
            o.manual_save_timer = 5
            enter('saving')
        elseif st_frames > 180 then
            fail('escape menu never opened')
        end

    elseif state == 'saving' then
        -- in-game signals only: the stage counter dips while saving and returns to
        -- SAVER_DONE, and DF re-opens the name prompt once the save has landed
        if o.saver.stage < SAVER_DONE then saw_progress = true end
        local finished = (saw_progress and o.saver.stage >= SAVER_DONE)
            or o.entering_manual_folder or o.confirm_manual_overwrite
        if finished then
            enter('done')
        elseif os.time() - st_started > SAVE_TIMEOUT then
            fail('save did not finish within ' .. SAVE_TIMEOUT .. 's')
        end

    elseif state == 'done' then
        -- clear the post-save re-prompt, then one Escape closes the menu
        clear_prompts()
        o.do_manual_save = false
        o.manual_save_timer = 0
        if not o.open then
            if failure then
                last_result = 'failed: ' .. failure
                next_at = os.time() + 60
                announce('save failed (' .. failure .. ') -- retrying in a minute', COLOR_LIGHTRED)
            else
                saves_done = saves_done + 1
                last_result = 'saved ' .. os.date('%H:%M')
                next_at = os.time() + interval_min * 60
                announce(('saved to "%s" (next in %d min)'):format(SAVE_NAME, interval_min))
            end
            enter('idle')
            return
        end
        if st_frames % 15 ~= 0 then return end    -- one Escape every ~15 frames
        esc_tries = esc_tries + 1
        if esc_tries > 8 then
            last_result = 'saved, but the menu stayed open -- press Esc'
            next_at = os.time() + interval_min * 60
            announce('saved, but I could not close the menu -- press Esc', COLOR_YELLOW)
            enter('idle')
            return
        end
        feed_key('LEAVESCREEN')
    end
end

-- ---- drivers -------------------------------------------------------------------
-- The timer loop runs between frames, where fed keys land reliably; the overlay
-- watchdog covers the stretches where an open menu freezes frame timers.

gen = gen or 0
local last_step = 0

local function start_loop()
    gen = gen + 1
    local my_gen = gen
    local function tick()
        if not running or my_gen ~= gen then return end
        last_step = os.clock()
        pcall(step)
        dfhack.timeout(1, 'frames', tick)
    end
    tick()
end

AutosaveOverlay = defclass(AutosaveOverlay, overlay.OverlayWidget)
AutosaveOverlay.ATTRS{
    desc = 'Watchdog for adv/autosave: periodic adventure-mode save.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function AutosaveOverlay:overlay_onupdate()
    if not running then return end
    if os.clock() - last_step > 0.5 then
        pcall(step)
        if os.clock() - last_step > 5 then start_loop() end
    end
end

OVERLAY_WIDGETS = {watch = AutosaveOverlay}

function stop()
    running = false
    gen = gen + 1
end

-- exported: get out of a half-open save dialog / options menu
function cleanup()
    clear_prompts()
    local o = opts()
    o.do_manual_save = false
    o.manual_save_timer = 0
    if o.open then feed_key('LEAVESCREEN') end
end

if dfhack_flags.module then return end

if not dfhack.world.isAdventureMode() then
    qerror('adv/autosave only works in adventure mode')
end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/autosave: stopped.')
elseif arg == 'status' then
    print(('adv/autosave: %s | every %d min | %d saved | state %s | next in %s | last: %s')
        :format(running and 'RUNNING' or 'stopped', interval_min, saves_done, state,
            running and (math.max(0, next_at - os.time()) .. 's') or 'n/a', last_result))
elseif arg == 'cleanup' then
    cleanup()
    print('adv/autosave: cleared save prompts and closed the menu.')
elseif arg == 'now' then
    running = true
    next_at = 0
    overlay.rescan()
    start_loop()
    print('adv/autosave: saving on the next calm frame.')
else
    local mins = tonumber(arg)
    if arg and not mins then qerror('usage: adv/autosave [minutes|now|cleanup|stop|status]') end
    if mins and mins > 0 then interval_min = math.floor(mins) end
    running = true
    next_at = os.time() + interval_min * 60
    overlay.rescan()
    start_loop()
    print(('adv/autosave: saving every %d min to "%s" (adv/autosave now to test).')
        :format(interval_min, SAVE_NAME))
end
