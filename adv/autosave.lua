-- Adventure mode: reminds you to save, then does all the fiddly parts for you.
--@module = true
--[[
adv/autosave

Adventure mode cannot be saved programmatically -- see "Why not fully automatic"
below. What this does instead, every N minutes (default 20):

  * reminds you that a save is due (announcement + a line in the log), and
  * as soon as you start one (Esc -> "Save and continue playing"), takes over:
    names the folder `adventure-autosave`, answers the "overwrite?" prompt,
    waits for the write to actually finish, and closes the menus afterwards.

So a save costs you one keypress and one click; everything error-prone is
handled. In particular it fixes the "now press Escape three times" trap at the
end, because DF re-opens the name prompt when the save completes.

Why not fully automatic (all verified live against DF 53.15):

  * `plotinfo.main.autosave_request` -- what `quicksave` uses in fortress mode --
    is never consumed by the adventure loop.
  * `main_interface.options.do_manual_save` IS how the save gets triggered, but
    DF only consumes it from inside the manual-save flow that the
    "Save and continue playing" button starts. Setting it at the top-level menu
    does nothing; faking `entering_manual_folder` does not enter the flow either
    (DF just closes the menu).
  * That button cannot be activated without a real mouse: the menu has no
    keyboard cursor (every row renders unhighlighted, and there is no selection
    field on the struct -- unlike `viewscreen_titlest.sel_menu_line`), and a fed
    `_MOUSE_L` clicks wherever the REAL pointer is, since these widgets ignore
    `gps.mouse_x/y`. Shelling out to move the pointer is not an option: DFHack's
    lua sandbox has no `os.execute`/`io.popen`, and it would be the wrong layer.
  * DF's own autosave (`game.autosave_cycle`, values from `df.d_init_autosave`:
    NONE/SEASONAL/YEARLY/SEMIANNUAL) is game-time based, so it cannot give a
    wall-clock interval -- but setting it to SEASONAL is a decent extra net.

What IS proven and used here: the name is written straight into
`options.entering_manual_str` (typing cannot be fed), a fed `SELECT` accepts it,
clearing `confirm_manual_overwrite` while setting `do_manual_save` +
`manual_save_timer` inside the flow performs the save, completion is read from
`options.saver.stage` returning to 51 (never from disk -- Steam redirects the
path DF reports), and clearing the two prompt flags lets one fed `LEAVESCREEN`
close the menu.

    adv/autosave           start; remind every 20 minutes
    adv/autosave 15        remind every 15 minutes
    adv/autosave remind    remind right now
    adv/autosave stop      stop
    adv/autosave status    running? interval? saves assisted? last result?
]]

local overlay = require('plugins.overlay')

running = running or false
interval_min = interval_min or 20
next_remind = next_remind or 0
saves_done = saves_done or 0
last_result = last_result or 'none yet'

local SAVE_NAME  = 'adventure-autosave'
local SAVER_DONE = 51     -- options.saver.stage once a save has completed
local ASSIST_GIVEUP = 900 -- frames to wait for each step of the flow

local function opts()
    return df.global.game.main_interface.options
end

local function feed_key(key)
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), key)
end

local function clear_prompts()
    local o = opts()
    o.entering_manual_folder = false
    o.confirm_manual_overwrite = false
end

local function announce(msg, color)
    print('adv/autosave: ' .. msg)
    pcall(dfhack.gui.showAnnouncement, 'adv/autosave: ' .. msg, color or COLOR_GREEN)
end

-- ---- assist state machine ------------------------------------------------------

local state, st_frames = 'watch', 0
local saw_progress, esc_tries = false, 0

local function enter(s)
    state, st_frames = s, 0
end

local function schedule()
    next_remind = os.time() + interval_min * 60
end

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end
    st_frames = st_frames + 1
    local o = opts()

    if state == 'watch' then
        -- you started a save: DF is asking for the folder name
        if o.entering_manual_folder then
            saw_progress, esc_tries = false, 0
            o.entering_manual_str = SAVE_NAME
            feed_key('SELECT')
            enter('confirm')
            return
        end
        -- otherwise just handle the reminder
        if os.time() < next_remind or not dfhack.isMapLoaded() then return end
        local focus = dfhack.gui.getCurFocus(true)
        if #focus ~= 1 or focus[1] ~= 'dungeonmode/Default' then return end
        announce(('save due -- press Esc then "Save and continue playing"'
            .. ' and I will name it "%s" and clean up'):format(SAVE_NAME), COLOR_YELLOW)
        schedule()

    elseif state == 'confirm' then
        if st_frames < 10 then return end
        if o.confirm_manual_overwrite then
            -- inside the flow, this both answers the prompt and starts the save
            clear_prompts()
            o.entering_manual_str = SAVE_NAME
            o.do_manual_save = true
            o.manual_save_timer = 5
            enter('saving')
        elseif o.saver.stage < SAVER_DONE then
            enter('saving')                      -- fresh name, saving already
        elseif not o.open then
            last_result = 'you left the save menu'
            enter('watch')
        elseif st_frames > ASSIST_GIVEUP then
            last_result = 'could not answer the overwrite prompt'
            announce('could not finish the save -- do it by hand', COLOR_LIGHTRED)
            enter('watch')
        end

    elseif state == 'saving' then
        -- The stage counter is the ONLY completion signal: it dips below 51 while
        -- DF writes and returns to 51 when done. The name/overwrite prompts are
        -- raised as part of STARTING a save, so treating them as "finished" is
        -- what once cancelled a save after all 1925 data files but before
        -- world.sav, leaving a folder DF refused to list. Clear and ignore them.
        if o.entering_manual_folder or o.confirm_manual_overwrite then clear_prompts() end
        local stage = o.saver.stage
        if stage < SAVER_DONE then saw_progress = true end
        if saw_progress and stage >= SAVER_DONE then
            enter('finish')
        elseif not saw_progress and st_frames > ASSIST_GIVEUP then
            last_result = 'DF never started the save'
            announce('the save never started -- do it by hand', COLOR_LIGHTRED)
            enter('watch')
        end

    elseif state == 'finish' then
        -- safe now: the write is complete
        clear_prompts()
        o.do_manual_save = false
        o.manual_save_timer = 0
        if not o.open then
            saves_done = saves_done + 1
            last_result = 'saved to ' .. SAVE_NAME .. ' at ' .. os.date('%H:%M')
            schedule()
            announce(('saved to "%s" -- next reminder in %d min')
                :format(SAVE_NAME, interval_min))
            enter('watch')
            return
        end
        if st_frames % 15 ~= 0 then return end
        esc_tries = esc_tries + 1
        if esc_tries > 8 then
            saves_done = saves_done + 1
            last_result = 'saved, but the menu stayed open'
            schedule()
            announce('saved, but I could not close the menu -- press Esc', COLOR_YELLOW)
            enter('watch')
            return
        end
        feed_key('LEAVESCREEN')
    end
end

-- ---- drivers -------------------------------------------------------------------
-- The timer loop runs between frames, where fed keys land; the overlay watchdog
-- covers the stretches where an open menu freezes frame timers (which is exactly
-- when the save dialogs are up).

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
    desc = 'Drives adv/autosave: save reminders + automatic save-dialog handling.',
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

if dfhack_flags.module then return end

if not dfhack.world.isAdventureMode() then
    qerror('adv/autosave only works in adventure mode')
end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/autosave: stopped.')
elseif arg == 'status' then
    print(('adv/autosave: %s | remind every %d min | %d assisted | state %s | next in %s | last: %s')
        :format(running and 'RUNNING' or 'stopped', interval_min, saves_done, state,
            running and (math.max(0, next_remind - os.time()) .. 's') or 'n/a', last_result))
elseif arg == 'remind' then
    running = true
    next_remind = 0
    overlay.rescan()
    start_loop()
    print('adv/autosave: reminding on the next calm frame.')
else
    local mins = tonumber(arg)
    if arg and not mins then qerror('usage: adv/autosave [minutes|remind|stop|status]') end
    if mins and mins > 0 then interval_min = math.floor(mins) end
    running = true
    schedule()
    overlay.rescan()
    start_loop()
    print(('adv/autosave: reminding every %d min; start a save (Esc -> Save and continue'
        .. ' playing) and I will name it "%s" and clean up.'):format(interval_min, SAVE_NAME))
end
