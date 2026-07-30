-- Adventure mode: keep the inventory panel open after each action.
--@module = true
--@enable = true
--[[
In adventure mode the inventory panel closes the moment you act -- drop something and you are
back on the map, so emptying a pack means pressing `d`, pick, `d`, pick, `d`, pick. With
keep-inventory ENABLED the panel is reopened for you after every action, and reopened in the
SAME mode you were working in (drop stays drop, wear stays wear), scrolled back to where you
were. Closing it with ESCAPE does NOT reopen it -- that's how you leave: press Esc.

    enable keep-inventory       keep the inventory open after actions (this session)
    disable keep-inventory      stop
    keep-inventory              toggle
    Ctrl+I  (in adventure)      toggle on/off in-game

Default is OFF, so nothing happens until you enable it.

HOW IT REOPENS -- through DF's own input, never by writing `inventory.open` (forcing a panel
open by hand segfaults the game; the conversation panel taught us that). Each of DF's inventory
contexts has its own interface key, so the reopen just re-feeds the key for the context the
panel was in when it closed. If the panel does not come back after a few tries it gives up
quietly rather than spamming input.

WHAT COUNTS AS "AN ACTION" -- everything that is not a close GESTURE. Escape and right-click
dismiss the panel and are recorded in onInput (without being consumed); any other way the panel
closes is treated as an action and reopened.

Do NOT try to detect an action by watching for the game to take a turn. `adventure`'s
last_took_input_* stamp does not advance for inventory actions (it sat at year 100 in a year-250
game), and dropping an item is instantaneous, so by the time the panel is seen closed the turn
is long over -- gating on that means the reopen never fires at all. keep-talking can gate on it
only because picking a topic starts a real multi-frame exchange.

Dropping a STACK (coins) opens a "how many?" prompt after the panel closes. The reopen waits for
that -- and any other context menu -- to finish before feeding its key, so it does not fight the
prompt.

Registered as overlay `keep-inventory.watcher`.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

enabled = enabled or false
function isEnabled() return enabled end

local CTX = df.adventure_interface_inventory_context_type

-- every inventory context DF can be opened straight into has its own key; the reopen feeds the
-- one matching the context the panel was in. The remaining contexts (PUT_IN_DESTINATION,
-- INTERACT_LIST, ONE_ITEM_FULL_LIST) are sub-states you reach from one of these, so they are
-- deliberately absent -- we reopen to the last top-level context instead.
local CONTEXT_KEY = {
    [CTX.MAIN]      = 'A_INV_LOOK',
    [CTX.DROP]      = 'A_INV_DROP',
    [CTX.WEAR]      = 'A_INV_WEAR',
    [CTX.REMOVE]    = 'A_INV_REMOVE',
    [CTX.PUT_IN]    = 'A_INV_PUTIN',
    [CTX.EAT_DRINK] = 'A_INV_EATDRINK',
    [CTX.INTERACT]  = 'A_INTERACT',
    [CTX.THROW]     = 'A_THROW',
}

local function inv() return df.global.game.main_interface.adventure.inventory end
local function feed(k) gui.simulateInput(dfhack.gui.getDFViewscreen(true), k) end

local function on_map()
    return (dfhack.gui.getCurFocus(true)[1] or '') == 'dungeonmode/Default'
end

local function input_ready()
    return df.global.adventure.player_control_state == df.adventure_game_loop_type.TAKING_INPUT
end

-- a follow-up prompt is up (the "how many?" amount entry you get dropping a stack of coins,
-- or any context menu). The panel is closed during these, but the action is not finished --
-- reopening now would fight the prompt, so the reopen waits them out.
local function prompt_open()
    local ol = df.global.game.main_interface.adventure.option_list
    return ol.open or ol.entering_number or ol.doing_pickup_amount
end

-- ---- overlay ----------------------------------------------------------------

KeepInventory = defclass(KeepInventory, overlay.OverlayWidget)
KeepInventory.ATTRS{
    desc = 'Adventure mode: reopen the inventory panel after each action.',
    default_pos = {x = 1, y = 2},
    default_enabled = true,
    viewscreens = 'dungeonmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function KeepInventory:reset()
    self.was_open = false
    self.escaped = false
    self.job = nil
    self.context = CTX.MAIN
    self.scroll = 0
end

-- Drive a pending reopen across frames:
--   'wait'   -> the action's turn is still running; wait for the map + input-ready, then settle
--   'verify' -> the key was fed; confirm the panel came back, else re-feed a bounded number of times
function KeepInventory:drive()
    local job = self.job
    if job.stage == 'wait' then
        if not (on_map() and input_ready()) or prompt_open() then
            job.wait = job.wait + 1
            if job.wait > 400 then self.job = nil end     -- something is wrong: bail, don't spam
            return
        end
        job.settle = job.settle + 1
        if job.settle < 4 then return end                 -- let the frame settle before feeding
        feed(CONTEXT_KEY[self.context] or 'A_INV_LOOK')
        job.stage, job.tries = 'verify', 0
    elseif job.stage == 'verify' then
        if inv().open then
            -- back where we were rather than scrolled to the top; the list may be shorter now
            -- (we just dropped something), so clamp
            local ok, n = pcall(function() return #inv().option end)
            if ok and n and n > 0 then
                inv().scroll_position = math.max(0, math.min(self.scroll, n - 1))
            end
            self.job = nil
            return
        end
        job.tries = job.tries + 1
        if job.tries > 8 then
            job.attempts = job.attempts + 1
            if job.attempts < 4 then
                job.stage, job.wait, job.settle = 'wait', 0, 0   -- re-feed
            else
                self.job = nil                                   -- gave up quietly
            end
        end
    end
end

function KeepInventory:overlay_onupdate()
    if not enabled then self:reset(); return end
    if not dfhack.world.isAdventureMode() then return end

    if inv().open then
        -- panel is up: remember where we are. Clearing `escaped` here is what makes Escape out of
        -- a SUB-panel (put-in destination, interact list) harmless -- that Esc leaves the panel
        -- open, so the flag is dropped again before it can suppress a later reopen.
        self.was_open = true
        self.escaped = false
        if CONTEXT_KEY[inv().context] then self.context = inv().context end
        self.scroll = inv().scroll_position
        self.job = nil
        return
    end

    if self.job then self:drive(); return end

    if self.was_open then
        self.was_open = false
        if self.escaped then                    -- Esc / right-click: that is how you leave
            self.escaped = false
            return
        end
        -- anything else that closed it was an action -> bring it back
        self.job = {stage = 'wait', wait = 0, settle = 0, tries = 0, attempts = 0}
        self:drive()
    end
end

function KeepInventory:onInput(keys)
    if keys.CUSTOM_CTRL_I then
        enabled = not enabled
        dfhack.gui.showAnnouncement('keep-inventory ' .. (enabled and 'ON' or 'OFF'),
            enabled and COLOR_LIGHTGREEN or COLOR_YELLOW, true)
        return true
    end
    -- note a close GESTURE while the panel is up, but do NOT consume it -- DF still has to act on
    -- it. Escape and right-click are the two ways to dismiss the panel; everything else that
    -- closes it is an action, and gets reopened.
    if enabled and inv().open and (keys.LEAVESCREEN or keys._MOUSE_R or keys._MOUSE_R_DOWN) then
        self.escaped = true
    end
    return false
end

OVERLAY_WIDGETS = {watcher = KeepInventory}

-- ---- enable / disable -------------------------------------------------------

if dfhack_flags.module then return end

if dfhack_flags.enable ~= nil then
    enabled = dfhack_flags.enable_state and true or false
else
    enabled = not enabled
end
require('plugins.overlay').rescan()
print('keep-inventory: ' .. (enabled
    and 'ON -- the inventory stays open after actions (Ctrl+I or `disable keep-inventory` to stop).'
    or 'OFF.'))
