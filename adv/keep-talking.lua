-- Adventure mode: when a conversation closes, auto-reopen it with the same person.
--@module = true
--@enable = true
--[[
In adventure mode a conversation drops back to the map every time you pick a topic -- to ask
the next thing you press `k` (talk) and choose "Continue conversation with ...". With
keep-talking ENABLED, that's done for you: the instant the conversation menu closes it is
reopened, so you keep asking questions in one flowing exchange instead of re-initiating every
line.

    enable keep-talking       auto-reopen conversations (this session)
    disable keep-talking      stop
    keep-talking              toggle
    Ctrl+K  (in adventure)    toggle on/off in-game -- press it to leave a conversation, then
                              close the menu one last time and it stays closed

Default is OFF, so nothing happens until you enable it.

HOW IT REOPENS -- all through DF's own input, no fragile state writes (those segfault): on
close it feeds the `A_TALK` interface key (the `k` "talk" action), which opens the "who to
talk to" menu, then clicks the "Continue conversation with ..." entry. If that entry isn't
there (the person left, or the conversation truly ended) it backs out and does nothing --
fail-safe. NB: it always continues the FIRST listed ongoing conversation; if you're juggling
several people at once it may pick a different one (walk away / disable to sort it out).

Registered as overlay `keep-talking.watcher`.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

enabled = enabled or false
function isEnabled() return enabled end

local CONTINUE = 'Continue conversation'   -- the menu label the reopen click looks for

local function mi() return df.global.game.main_interface end
local function feed(k) gui.simulateInput(dfhack.gui.getDFViewscreen(true), k) end

-- click the middle of the first on-screen text run containing `needle`. Left-clicks on rendered
-- text drive menus reliably (right-clicks and the game's mouse fields don't -- DF reads right-click
-- targets from the real hardware cursor, which a script can't move; this keyboard+text path avoids
-- that entirely). Returns true if something was clicked.
local function click_text(needle)
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local chars = {}
        for x = 0, gps.dimx - 1 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            local ch = ok and t and t.ch or 0
            chars[x] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local line = table.concat(chars, '', 0, gps.dimx - 1)
        local i = line:find(needle, 1, true)
        if i then
            local cx = (i - 1) + #needle // 2
            gps.mouse_x, gps.mouse_y = cx, y
            gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
            gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
            feed('_MOUSE_L')
            return true
        end
    end
    return false
end

-- ---- screen-state helpers ---------------------------------------------------
-- FOCUS is the reliable signal: the conversation flags (selecting_conversation) can linger stale
-- while the menu is actually closed on the map, so every state is gated on the focus string.

local function focus_is(s) return (dfhack.gui.getCurFocus(true)[1] or '') == s end
-- the real conversation (topic list) is up
local function in_conversation()
    local c = mi().adventure.conversation
    return focus_is('dungeonmode/Conversation') and not c.selecting_conversation and #c.conv_choice_info > 0
end
-- the A_TALK "who to talk to / continue which conversation" menu is up
local function in_select_menu()
    local c = mi().adventure.conversation
    return focus_is('dungeonmode/Conversation') and c.selecting_conversation and #c.select_option > 0
end
local function on_map() return focus_is('dungeonmode/Default') end

-- ---- overlay ----------------------------------------------------------------

KeepTalking = defclass(KeepTalking, overlay.OverlayWidget)
KeepTalking.ATTRS{
    desc = 'Adventure mode: auto-reopen the conversation menu with the same person.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dungeonmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function KeepTalking:reset() self.was_open = false; self.job = nil end

-- Drive a pending reopen across frames. Stages:
--   'talk'   -> conversation just closed: feed A_TALK to raise the "who to talk to" menu
--   'select' -> that menu is up: click the "Continue conversation with ..." entry
-- Bounded retries; on anything unexpected it aborts (no input spam), and if it raised the select
-- menu but there is no Continue entry it backs out with Escape so the player isn't stranded there.
function KeepTalking:drive()
    local job = self.job
    if job.stage == 'talk' then
        if not on_map() then                             -- wait for the plain map, then give up
            job.tries = job.tries + 1
            if job.tries > 12 then self.job = nil end
            return
        end
        feed('A_TALK')
        job.stage, job.tries = 'select', 0
    elseif job.stage == 'select' then
        if in_conversation() then self.job = nil; return end            -- resumed: done
        if in_select_menu() then
            if click_text(CONTINUE) then self.job = nil; return end      -- clicked Continue: done
            -- menu up but the label isn't rendered yet -> retry a few frames, then back out
            job.tries = job.tries + 1
            if job.tries > 5 then feed('LEAVESCREEN'); self.job = nil end
        else
            job.tries = job.tries + 1                     -- select menu hasn't come up yet
            if job.tries > 12 then self.job = nil end
        end
    end
end

function KeepTalking:overlay_onupdate()
    if not enabled then self:reset(); return end
    if not dfhack.world.isAdventureMode() then return end
    if in_conversation() then                            -- actually talking: remember it, no reopen pending
        self.was_open = true
        self.job = nil
        return
    end
    if self.job then self:drive(); return end            -- a reopen is in flight (incl. the select menu)
    if self.was_open and on_map() then                    -- conversation just closed -> queue a reopen
        self.was_open = false
        self.job = {stage = 'talk', tries = 0}
        self:drive()
    end
end

-- Ctrl+K toggles keep-talking in-game, so you can leave a conversation without the console.
function KeepTalking:onInput(keys)
    if keys.CUSTOM_CTRL_K then
        enabled = not enabled
        dfhack.gui.showAnnouncement('keep-talking ' .. (enabled and 'ON' or 'OFF'),
            enabled and COLOR_LIGHTGREEN or COLOR_YELLOW, true)
        return true
    end
    return false
end

OVERLAY_WIDGETS = {watcher = KeepTalking}

-- ---- enable / disable -------------------------------------------------------

if dfhack_flags.module then return end

if dfhack_flags.enable ~= nil then
    enabled = dfhack_flags.enable_state and true or false
else
    enabled = not enabled
end
require('plugins.overlay').rescan()
print('keep-talking: ' .. (enabled
    and 'ON -- conversations auto-reopen (Ctrl+K or `disable keep-talking` to stop).' or 'OFF.'))
