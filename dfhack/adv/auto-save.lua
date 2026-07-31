-- Adventure mode: save the game the way the player does, automatically.
--@module = true
--[[
adv/auto-save
=============

Tags: adventure | auto

Saves an adventure game by driving DF's own escape-menu flow -- the exact
steps a player takes -- and can repeat it on a timer:

    adv/auto-save                  save once, right now
    adv/auto-save enable [min]     also auto-save every N minutes (default 20)
    adv/auto-save disable          stop the timer
    adv/auto-save status           what it's doing

The interval is counted from the last SUCCESSFUL save, and `enable` arms it
from that moment -- enabling never fires a save immediately.  A cycle only
begins from a completely quiet game (plain `dungeonmode/Default`, no options
menu, no context menu, no conversation); otherwise it waits for a calm
moment rather than driving a menu stack it does not understand.
`fort/magnus-scripts` enables it on every adventure load.

The save is named "adventurer-autosave" (DF then treats that as the active
save folder: "Save and continue playing" RENAMES the running session into
save/<name>, leaving the old folder behind empty).

The whole flow was driven live, step by step, before this script existed;
every quirk below was observed, not guessed:

1. The escape menu opens on the `OPTIONS` interface key.  LEAVESCREEN does
   NOT open it (a likely cause of earlier failed attempts).  State:
   `main_interface.options.open`.
2. A fed click on the rendered "Save and continue playing" label opens the
   save-name box (`options.entering_manual_folder`); its text buffer
   (`options.entering_manual_str`) always starts EMPTY, even on repeat saves.
   That buffer is a plain Lua STRING, not a struct: reading `.value` on it
   yields nil, so a compare against `.value` never matches (this cost a
   debugging round).
3. Characters land through `STRING_A###` interface keys, exactly like
   typing; `SELECT` submits.
4. First save with a fresh name sets `options.do_manual_save` and the game
   saves over the next frames.  A repeat save pops "There is a folder with
   this name already" -- its Save button takes a fed click.
5. The menu then closes itself and play resumes.  `do_manual_save` /
   `confirm_manual_overwrite` linger true afterwards -- harmless; DF resets
   them the next time the menu opens.
6. The name box IGNORES Escape; only its Cancel button closes it.  The
   options menu itself does close on Escape.  Cleanup relies on both.

The stepper is an OVERLAY onupdate, not a frame timer: frame timers freeze
while menus are open, which is precisely when this has work to do.  Every
step has a wall-clock timeout and retry, and a cycle only STARTS from the
plain dungeonmode/Default focus (never mid-travel, mid-conversation or
inside someone else's menu).  On any timeout it reports, feeds one
LEAVESCREEN to close what it opened, and gives up rather than wander.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

DEFAULT_NAME = 'adventurer-autosave'
local STEP_TIMEOUT_MS = 8000
-- the write blocks DF (and therefore this overlay) for seconds; give the
-- finishing step its own generous budget so it can't expire mid-save
local SAVE_TIMEOUT_MS = 180000
local RETRY_MS = 700
local SAVER_IDLE = 51        -- options.saver.stage when no save is running

-- ALL cross-invocation state lives in env GLOBALS, never file locals: every
-- command invocation re-executes this file in the shared script env, which
-- re-initializes locals -- so a local set by the command would be invisible
-- to the overlay's closures (this exact bug ate the first version).
enabled = enabled or false
interval_min = interval_min or 20
saves_done = saves_done or 0
-- the interval is counted from the last SUCCESSFUL save (or from `enable`,
-- so enabling never fires an immediate save)
last_save_ms = last_save_ms or nil

phase = phase or nil       -- nil | open | click_save | type | submit | finish
phase_deadline = phase_deadline or 0
retry_at = retry_at or 0
cycle_name = cycle_name or DEFAULT_NAME

local function opts() return df.global.game.main_interface.options end
local function cur_focus() return dfhack.gui.getCurFocus(true)[1] or '' end

local function read_row(y)
    local gps = df.global.gps
    if y < 0 or y >= gps.dimy then return '' end
    local row = {}
    for x = 0, gps.dimx - 1 do
        local t = dfhack.screen.readTile(x, y)
        local ch = t and t.ch or 0
        row[x + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(row)
end

-- find `needle` on screen (optionally only at/below row y0); click its middle
local function click_text(needle, y0)
    local gps = df.global.gps
    for y = y0 or 0, gps.dimy - 1 do
        local row = read_row(y)
        local a, b = row:find(needle, 1, true)
        if a then
            local cx = math.floor((a - 1 + b - 1) / 2)
            gps.mouse_x, gps.mouse_y = cx, y
            gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
            gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
            gui.simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
            return true
        end
    end
    return false
end

local function find_row(needle)
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        if read_row(y):find(needle, 1, true) then return y end
    end
end

local function feed(key)
    gui.simulateInput(dfhack.gui.getCurViewscreen(true), key)
end

-- Back out of whatever this script opened, leaving plain play.  The name box
-- IGNORES Escape (measured) -- it only closes on its Cancel button -- so the
-- cleanup clicks Cancel first, then Escapes the options menu.
local function cleanup()
    local o = opts()
    if o.entering_manual_folder then
        click_text('Cancel')
    elseif o.open then
        feed('LEAVESCREEN')
    end
end

local function fail(why)
    print(('adv/auto-save: gave up at step "%s" (%s); backing out.')
        :format(tostring(phase), why))
    phase = 'cleanup'
    phase_deadline = dfhack.getTickCount() + STEP_TIMEOUT_MS
    retry_at = 0
end

local function start_cycle(name)
    cycle_name = name or DEFAULT_NAME
    phase = 'open'
    phase_deadline = dfhack.getTickCount() + STEP_TIMEOUT_MS
    retry_at = 0
end

local function advance(next_phase)
    phase = next_phase
    phase_deadline = dfhack.getTickCount()
        + (next_phase == 'finish' and SAVE_TIMEOUT_MS or STEP_TIMEOUT_MS)
    retry_at = 0
end

local function step()
    if not phase then return end
    local now = dfhack.getTickCount()
    local o = opts()

    -- backing out after a failure: keep dismissing until plain play returns
    if phase == 'cleanup' then
        if not o.open and cur_focus() == 'dungeonmode/Default' then
            phase = nil
        elseif now > phase_deadline then
            print('adv/auto-save: could not close the menu -- press Escape yourself.')
            phase = nil
        elseif now >= retry_at then
            cleanup()
            retry_at = now + RETRY_MS
        end
        return
    end

    if now > phase_deadline then return fail('timeout') end

    if phase == 'open' then
        if o.open then return advance('click_save') end
        if now >= retry_at then
            -- only pull the menu up from plain play, never over another screen
            if cur_focus() ~= 'dungeonmode/Default' then return end
            feed('OPTIONS')
            retry_at = now + RETRY_MS
        end
    elseif phase == 'click_save' then
        if o.entering_manual_folder then return advance('type') end
        if now >= retry_at then
            click_text('Save and continue playing')
            retry_at = now + RETRY_MS
        end
    elseif phase == 'type' then
        -- NB: entering_manual_str is a plain Lua STRING (DFHack converts
        -- std::string fields on read), NOT a struct with .value -- reading
        -- `.value` yields nil and the compare below never matches.
        local buf = o.entering_manual_str
        if buf == cycle_name then
            feed('SELECT')
            return advance('submit')
        end
        if now >= retry_at then
            for _ = 1, #buf do feed('STRING_A000') end          -- backspace out leftovers
            for i = 1, #cycle_name do
                feed(('STRING_A%03d'):format(cycle_name:byte(i)))
            end
            retry_at = now + RETRY_MS
        end
    elseif phase == 'submit' then
        if o.do_manual_save or not o.open then return advance('finish') end
        if o.confirm_manual_overwrite and now >= retry_at then
            -- "There is a folder with this name already." -- click its Save button
            local y = find_row('Would you like to overwrite it?')
            if y then click_text('Save', y + 1) end
            retry_at = now + RETRY_MS
        end
    elseif phase == 'finish' then
        -- The write itself blocks DF's main thread, so this overlay simply
        -- does not run for several seconds -- hence the long deadline (a
        -- short one just expires while the save is in progress).
        -- `saver.stage` runs 18 -> 39 -> 46 -> 51 (51 = idle/done), and DF
        -- closes the options menu by itself when the save lands.
        if o.open then
            if o.saver.stage == SAVER_IDLE and now >= retry_at then
                cleanup()                    -- written, but the menu lingered
                retry_at = now + RETRY_MS
            end
            return
        end
        phase = nil
        saves_done = saves_done + 1
        last_save_ms = now
        print(('adv/auto-save: saved as "%s" (%d this session)'):format(cycle_name, saves_done))
    end
end

-- ---- overlay driver ---------------------------------------------------------

AutoSave = defclass(AutoSave, overlay.OverlayWidget)
AutoSave.ATTRS{
    desc = 'Saves adventure games via the escape menu; optional timer.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

-- A cycle may only START from a completely quiet game: plain play focus, no
-- options menu, no context menu, no conversation.  Anything else means the
-- player is mid-interaction and DF's menu stack is not what this expects --
-- so it waits for a calm moment instead of guessing.
-- NB: `entering_manual_folder` / `do_manual_save` / `confirm_manual_overwrite`
-- LINGER true after a completed save (DF only resets them when the menu next
-- opens), so they are meaningless while `options.open` is false -- testing
-- them here would wedge the timer permanently after the first save.
local function safe_to_start()
    if cur_focus() ~= 'dungeonmode/Default' then return false end
    local o = opts()
    if o.open then return false end
    if o.saver.stage ~= SAVER_IDLE then return false end     -- a save is running
    local adv = df.global.game.main_interface.adventure
    if adv.option_list.open or adv.conversation.open then return false end
    return true
end

function AutoSave:overlay_onupdate()
    pcall(function()
        step()
        if not phase and enabled then
            local now = dfhack.getTickCount()
            -- arm relative to enable, so enabling never triggers a save at once
            if not last_save_ms then last_save_ms = now end
            if now - last_save_ms >= interval_min * 60 * 1000 and safe_to_start() then
                start_cycle(DEFAULT_NAME)
            end
        end
    end)
end

OVERLAY_WIDGETS = {save = AutoSave}

-- ---- commands ---------------------------------------------------------------

function save_now(name)
    if not dfhack.world.isAdventureMode() then
        qerror('adv/auto-save only works in adventure mode')
    end
    if phase then print('adv/auto-save: a save cycle is already running') return end
    if not safe_to_start() then
        qerror('adv/auto-save: close any open menu first (needs plain play, focus is '
            .. cur_focus() .. ')')
    end
    start_cycle(name)
    print(('adv/auto-save: saving as "%s"...'):format(name or DEFAULT_NAME))
end

function status()
    local when = 'never'
    if last_save_ms then
        when = ('%ds ago'):format((dfhack.getTickCount() - last_save_ms) // 1000)
    end
    print(('adv/auto-save: %s | timer %s (%d min) | %d save%s this session | last: %s')
        :format(phase and ('SAVING (step ' .. phase .. ')') or 'idle',
            enabled and 'ON' or 'off', interval_min,
            saves_done, saves_done == 1 and '' or 's', when))
end

if dfhack_flags.module then return end

local args = {...}
local cmd = args[1]
if cmd == 'enable' then
    enabled = true
    interval_min = tonumber(args[2]) or interval_min
    last_save_ms = dfhack.getTickCount()
    print(('adv/auto-save: auto-saving every %d minute%s (as "%s").')
        :format(interval_min, interval_min == 1 and '' or 's', DEFAULT_NAME))
elseif cmd == 'disable' then
    enabled = false
    print('adv/auto-save: timer off.')
elseif cmd == 'status' then
    status()
else
    -- NB: no overlay.rescan() here -- rescanning from inside a command
    -- execution reloads this very script and orphans the cycle state the
    -- command just set. The overlay registers at deploy/startup rescans.
    save_now(cmd)      -- optional: adv/auto-save <name> saves under that name
end
