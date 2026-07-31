-- Adventure mode: keep the inventory panel open after each action.
--@module = true
--@enable = true
--[[
In adventure mode the inventory panel closes the moment you act -- drop something and you are
back on the map, so emptying a pack means pressing `d`, pick, `d`, pick, `d`, pick. With
keep-inventory ENABLED the panel is reopened for you after every action, and reopened in the
SAME mode you were working in (drop stays drop, wear stays wear), scrolled back to where you
were. Closing it with ESCAPE does NOT reopen it -- that's how you leave: press Esc.

SCROLL -- two things had to be true for this to work at all, both non-obvious:

  * The reopen is claimed in overlay_onupdate's "panel is open" branch, NOT in drive()'s
    'verify' stage. overlay_onupdate tests inv().open BEFORE it ever calls drive(), so on the
    frame the panel comes back it takes that branch and returns -- the verify success path is
    unreachable. Restoring there looked correct and silently never ran.
  * The offset is RE-ASSERTED for RESTORE_MS rather than written once, because DF zeroes
    scroll_position while finishing the open, after a single write would have landed. During
    that window the saved value is also NOT refreshed from the struct, or DF's zero would
    immediately become the new "saved" position.
  * The row count comes from `option_current`, NOT from `#inventory.option`. `option` is a
    static ARRAY of nine vectors, one per adventure_inventory_option_list_type -- its length is
    the constant 9 however many items you carry. Clamping to it pinned every restore to row 8,
    so a short list came back exactly right and anything scrolled further down came back near
    the top.

It is clamped to the row count, since the list is usually one shorter than it was.

The offset is only remembered while a TOP-LEVEL context is showing. Sub-lists (a container's
contents, the put-in destination list) scroll independently, and the reopen returns to the last
top-level context -- so saving a sub-list's offset would restore it into a different list.

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

-- Counters, kept because they are what made this debuggable: they separate "the reopen never
-- fired" from "it fired but the scroll write did nothing", which look identical in game.
closes = closes or 0      -- panel closed while we were watching
escapes = escapes or 0    -- ...of those, closed by Esc/right-click (no reopen)
reopens = reopens or 0    -- panel confirmed back open after our key feed
restores = restores or 0  -- scroll offset written back

local CTX = df.adventure_interface_inventory_context_type
local LIST = df.adventure_inventory_option_list_type

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

-- which bucket of inventory.option[] a context's rows live in. The two enums look alike but are
-- NOT interchangeable: the list enum carries DETAILS at 1, so everything after MAIN sits one
-- higher, and the sub-state contexts (PUT_IN_DESTINATION, INTERACT_LIST) have no bucket at all.
local CONTEXT_LIST = {
    [CTX.MAIN]               = LIST.MAIN,
    [CTX.DROP]               = LIST.DROP,
    [CTX.WEAR]               = LIST.WEAR,
    [CTX.REMOVE]             = LIST.REMOVE,
    [CTX.PUT_IN]             = LIST.PUT_IN,
    [CTX.EAT_DRINK]          = LIST.EAT_DRINK,
    [CTX.INTERACT]           = LIST.INTERACT,
    [CTX.THROW]              = LIST.THROW,
    [CTX.ONE_ITEM_FULL_LIST] = LIST.DETAILS,
}

local function inv() return df.global.game.main_interface.adventure.inventory end
local function feed(k) gui.simulateInput(dfhack.gui.getDFViewscreen(true), k) end

-- how many rows the panel is showing. `option_current` is the list on screen; the context's own
-- bucket is a fallback for frames where DF has not filled that in yet. The LARGER of the two is
-- what we want -- an undercount is what breaks the restore, an overcount only leaves a clamp
-- loose enough for DF to tighten itself. Never `#inv().option`: see SCROLL in the header.
local function row_count()
    local i = inv()
    local n = #i.option_current
    local bucket = CONTEXT_LIST[i.context]
    if bucket then n = math.max(n, #i.option[bucket]) end
    return n
end

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

-- how long to keep re-asserting the saved scroll after the panel comes back (wall clock, not
-- frames: this overlay fires once per render frame and the game runs anywhere from ~60 to
-- ~800 FPS, so a frame count is a different real duration every time)
local RESTORE_MS = 400

function KeepInventory:reset()
    self.was_open = false
    self.escaped = false
    self.job = nil
    self.context = CTX.MAIN
    self.scroll = 0
    self.restore_until = 0
end

-- put the saved scroll offset back, clamped: the list may be shorter now (we just dropped
-- the thing we were looking at), in which case DF's own offset would be out of range
function KeepInventory:hold_scroll()
    local ok, n = pcall(row_count)
    if ok and n and n > 0 then
        inv().scroll_position = math.max(0, math.min(self.scroll, n - 1))
        restores = restores + 1
    end
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
        -- NOTE: the success case is NOT handled here. overlay_onupdate tests inv().open before
        -- it ever calls drive(), so on the frame the panel comes back it takes that branch and
        -- returns -- this one is unreachable on success. Claiming the reopen there is what
        -- makes the scroll restore actually run; leaving it here silently did nothing.
        if inv().open then self.job = nil return end
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
        -- a pending reopen just landed: this is the only place that can observe it, so start
        -- the scroll-restore window here
        if self.job and self.job.stage == 'verify' then
            reopens = reopens + 1
            self.restore_until = dfhack.getTickCount() + RESTORE_MS
        end
        self.was_open = true
        self.escaped = false
        if dfhack.getTickCount() < (self.restore_until or 0) then
            -- still re-asserting after a reopen: keep writing our value, and do NOT read
            -- DF's back over it, or the zero it just wrote becomes the new "saved" position
            self:hold_scroll()
        else
            self.restore_until = 0
            -- only track a TOP-LEVEL list's offset -- that is the list the reopen comes back
            -- to. A sub-list (container contents, put-in destination) scrolls on its own, and
            -- its offset restored into the top-level list lands somewhere unrelated.
            if CONTEXT_KEY[inv().context] then
                self.context = inv().context
                self.scroll = inv().scroll_position
            end
        end
        self.job = nil
        return
    end

    if self.job then self:drive(); return end

    if self.was_open then
        self.was_open = false
        closes = closes + 1
        if self.escaped then                    -- Esc / right-click: that is how you leave
            self.escaped = false
            escapes = escapes + 1
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
    if enabled and inv().open then
        if keys.LEAVESCREEN or keys._MOUSE_R or keys._MOUSE_R_DOWN then
            self.escaped = true
        end
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
