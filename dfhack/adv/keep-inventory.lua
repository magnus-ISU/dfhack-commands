-- Adventure mode: keep the inventory panel open after each action.
--@module = true
--@enable = true
--[[
In adventure mode the inventory panel closes the moment you act -- drop something and you are
back on the map, so emptying a pack means pressing `d`, pick, `d`, pick, `d`, pick. With
keep-inventory ENABLED the panel is reopened for you after every action, and reopened in the
SAME mode you were working in (drop stays drop, wear stays wear), scrolled back to where you
were, with adv/inventory-search's filter re-applied if one was typed. Closing it with ESCAPE
does NOT reopen it -- that's how you leave: press Esc.

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

WHAT COUNTS AS "AN ACTION" -- everything that is not a close GESTURE. Escape, right-click and
a click on the header's Done button dismiss the panel and are recorded in onInput (without
being consumed); any other way the panel
closes is treated as an action and reopened. EXCEPT reading: a read prints the book's text into
the announcement feed -- the same screen area the reopened panel would cover -- so when the
reports appended since the panel was open start with "You read ", the reopen is skipped.

Do NOT try to detect an action by watching for the game to take a turn. `adventure`'s
last_took_input_* stamp does not advance for inventory actions (it sat at year 100 in a year-250
game), and dropping an item is instantaneous, so by the time the panel is seen closed the turn
is long over -- gating on that means the reopen never fires at all. keep-talking can gate on it
only because picking a topic starts a real multi-frame exchange.

Dropping a STACK (coins) opens a "how many?" prompt after the panel closes. The reopen waits for
that -- and any other context menu -- to finish before feeding its key, so it does not fight the
prompt.

THE PICK-UP MENU is kept open too: the "What do you want to do?" list you get by right-clicking
a tile with items (or pressing `g`) closes after every "Get", so looting a pile is right-click,
Get, right-click, Get. With keep-inventory enabled, when that menu closes and something actually
LANDED IN YOUR INVENTORY, the menu is reopened (scrolled back to where it was). The gate matters:
the same list carries "Path to here" / "View yourself" style options, and those must not summon
it back -- so the reopen fires only when the adventurer's inventory count grew since the list
opened. And only when there is still something left to take: grabbing the LAST listed item does
not resurrect a menu with nothing to pick up in it. Esc / right-click dismiss it for good, as
with the panel.

The reopen is fed as `A_GROUND` (the `g` ground list): a fed right-click never reaches DF
(hardware-only), so the exact right-click menu cannot be resurrected -- but both are the same
option_list widget, and the ground list carries the same "Get" rows. Only the two pickup
contexts (GROUND, DIRECT_CLICK) are watched; the other option_list contexts (movement options,
aim, interact-with-building, look) share the struct and are deliberately left alone.

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
reads = reads or 0        -- reopens skipped because the action was reading a book

-- pick-up list (ground) flow, separately countable: these say WHICH gate a
-- failed reopen died at, which is unobservable in game
g_close = g_close or 0    -- pickup list closed by an action (job started)
g_esc = g_esc or 0        -- pickup list dismissed by Esc/right-click
g_gate = g_gate or 0      -- job ended at the nothing-was-picked-up gate
g_feed = g_feed or 0      -- A_GROUND fed
g_back = g_back or 0      -- pickup list confirmed back open
g_dead = g_dead or 0      -- gave up: fed repeatedly, list never came back
g_note = g_note or ''     -- last gate detail
seed_note = seed_note or ''  -- last search-restore attempt result

local CTX = df.adventure_interface_inventory_context_type
local LIST = df.adventure_inventory_option_list_type
local OL_CTX = df.adventure_interface_option_list_context_type

-- the two pickup flavors of the shared option list: the `g` ground list and the
-- right-click "What do you want to do?" menu. The other contexts (movement
-- options, aim, building-interact, look) share the struct and are not ours.
local OL_PICKUP = {
    [OL_CTX.GROUND] = true,
    [OL_CTX.DIRECT_CLICK] = true,
}

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
local function ol() return df.global.game.main_interface.adventure.option_list end
local function feed(k) gui.simulateInput(dfhack.gui.getDFViewscreen(true), k) end

-- how many things the adventurer is carrying; an increase between the pick-up
-- list opening and closing is the proof a "Get" actually happened
local function carried_count()
    local ok, n = pcall(function() return #dfhack.world.getAdventurer().inventory end)
    return ok and n or 0
end

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

-- Was this left-click on the panel's "Done" button? Done lives on the header row (the one
-- carrying "Your inventory ... Burden ... Done"), so a row within one tile of the click must
-- contain "burden" AND the mouse must sit on a "done" with 3 tiles of horizontal padding
-- (the drawn button is wider than its label). Scraped per CLICK, not per frame, so the row
-- reads are cheap. Clicking Done is a deliberate leave, like Escape.
local function clicked_done()
    local mx, my = df.global.gps.mouse_x, df.global.gps.mouse_y
    if not mx or mx < 0 or not my or my < 0 then return false end
    local sw, sh = dfhack.screen.getWindowSize()
    for dy = -1, 1 do                              -- one tile of vertical padding
        local y = my + dy
        if y >= 0 and y < sh then
            local chars = {}
            for x = 0, sw - 1 do
                local ok, pen = pcall(dfhack.screen.readTile, x, y)
                local ch = (ok and pen and pen.ch) or 0
                chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
            end
            local ll = table.concat(chars):lower()
            if ll:find('burden', 1, true) then
                local s = 1
                while true do
                    local c, e = ll:find('done', s, true)
                    if not c then break end
                    -- find() is 1-based, the mouse is 0-based: the word covers cols c-1..e-1
                    if mx >= c - 4 and mx <= e + 2 then return true end
                    s = e + 1
                end
            end
        end
    end
    return false
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
    local o = ol()
    return o.open or o.entering_number or o.doing_pickup_amount
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
    self.report_n = nil
    self.job = nil
    self.context = CTX.MAIN
    self.scroll = 0
    self.restore_until = 0
    self.ol_was_open = false
    self.ol_escaped = false
    self.ol_base = 0
    self.ol_scroll = 0
    self.ol_restore_until = 0
    self.ol_items = {}
    self.ol_nopt = -1
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

-- same clamp-and-reassert for the pick-up list; its row count is plain
-- #option (the shared option list has no per-context buckets)
function KeepInventory:hold_ol_scroll()
    local ok, n = pcall(function() return #ol().option end)
    if ok and n and n > 0 then
        ol().scroll_position = math.max(0, math.min(self.ol_scroll, n - 1))
        restores = restores + 1
    end
end

-- Did the action that closed the panel READ something? Reading prints the book's text into the
-- announcement feed ("You read An Exploration of the Farm."), in the same screen area a
-- reopened inventory panel covers -- so a read must NOT reopen. Detected from the reports
-- appended since the panel was last seen open; there is no screen or struct to test, the read
-- happens entirely inline.
function KeepInventory:read_just_happened()
    local base = self.report_n
    if not base then return false end
    local reports = df.global.world.status.reports
    for i = base, #reports - 1 do
        local ok, txt = pcall(function() return reports[i].text end)
        if ok and txt and txt:sub(1, 9) == 'You read ' then return true end
    end
    return false
end

-- Drive a pending reopen across frames (job.kind nil = inventory panel, 'ground' = pick-up list):
--   'wait'   -> the action's turn is still running; wait for the map + input-ready, then settle
--   'verify' -> the key was fed; confirm the panel came back, else re-feed a bounded number of times
function KeepInventory:drive()
    local job = self.job
    local ground = job.kind == 'ground'
    if job.stage == 'wait' then
        if not (on_map() and input_ready()) or prompt_open() then
            job.wait = job.wait + 1
            if job.wait > 400 then                        -- something is wrong: bail, don't spam
                if ground then
                    g_dead = g_dead + 1
                    g_note = 'wait timeout at ' .. (dfhack.gui.getCurFocus(true)[1] or '?')
                end
                self.job = nil
            end
            return
        end
        job.settle = job.settle + 1
        if job.settle < 4 then return end                 -- let the frame settle before feeding
        if ground then
            -- reopen only when the close actually TOOK something -- the same list carries
            -- "Path to here" style options whose choice must not summon the menu back.
            -- Checked here, after the coin-amount prompt has resolved, not at close time.
            -- Two signals, either proves a Get: an item the list showed left the ground
            -- (covers the usual auto-stow into the backpack), or the carried count grew
            -- (belt and braces for anything getItem() could not resolve).
            local taken = carried_count() > self.ol_base
            if not taken then
                for _, id in ipairs(self.ol_items or {}) do
                    local it = df.item.find(id)
                    if it and not it.flags.on_ground then taken = true break end
                end
            end
            if not taken then
                g_gate = g_gate + 1
                g_note = ('nothing taken (%d listed items)'):format(#(self.ol_items or {}))
                self.job = nil
                return
            end
            -- ...but do NOT bring the list back when that Get emptied it: if none of
            -- the items it showed is still on the ground, there is nothing left to
            -- pick up here and the reopened menu would just be in the way.
            local left = 0
            for _, id in ipairs(self.ol_items or {}) do
                local it = df.item.find(id)
                if it and it.flags.on_ground then left = left + 1 end
            end
            if left == 0 then
                g_gate = g_gate + 1
                g_note = 'took the last item'
                self.job = nil
                return
            end
            g_feed = g_feed + 1
            feed('A_GROUND')
        else
            -- checked here, after the turn resolved, so the read's reports have landed
            if self:read_just_happened() then
                reads = reads + 1
                self.job = nil
                return
            end
            feed(CONTEXT_KEY[self.context] or 'A_INV_LOOK')
        end
        job.stage, job.tries = 'verify', 0
    elseif job.stage == 'verify' then
        -- NOTE: the success case is NOT handled here. overlay_onupdate tests the panel-open
        -- branches before it ever calls drive(), so on the frame the panel comes back it takes
        -- that branch and returns -- this one is unreachable on success. Claiming the reopen
        -- there is what makes the scroll restore actually run; leaving it here silently did
        -- nothing.
        if (ground and ol().open) or (not ground and inv().open) then self.job = nil return end
        job.tries = job.tries + 1
        if job.tries > 8 then
            job.attempts = job.attempts + 1
            if job.attempts < 4 then
                job.stage, job.wait, job.settle = 'wait', 0, 0   -- re-feed
            else
                if ground then g_dead = g_dead + 1 end
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
            -- bring the search filter back too: re-seed adv/inventory-search with the text
            -- that was in its box before the action closed the panel (Esc'd closes never get
            -- here, so a deliberate leave still opens clean next time)
            local ok, invsearch = pcall(reqscript, 'adv/inventory-search')
            if ok and invsearch.restore_last_search then
                local ok2, err = pcall(invsearch.restore_last_search)
                seed_note = ok2 and 'called' or ('restore err: ' .. tostring(err))
            else
                seed_note = 'reqscript failed: ' .. tostring(invsearch)
            end
        end
        self.was_open = true
        self.escaped = false
        -- reports high-water mark while the panel is up: anything past this at reopen time was
        -- printed by the closing action (how read_just_happened knows the read was THIS action)
        self.report_n = #df.global.world.status.reports
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

    local o = ol()
    if o.open then
        if OL_PICKUP[o.context] then
            -- a pending ground reopen just landed: as with the panel, this is the only
            -- place that can observe it -- start the scroll-restore window here
            if self.job and self.job.kind == 'ground' and self.job.stage == 'verify' then
                reopens = reopens + 1
                g_back = g_back + 1
                self.ol_restore_until = dfhack.getTickCount() + RESTORE_MS
            end
            if self.job and self.job.kind == 'ground' then self.job = nil end
            if not self.ol_was_open then
                -- carried count at open: one of the two "Get happened" signals
                self.ol_base = carried_count()
            end
            -- remember which ITEMS the rows resolve to. A picked-up item does NOT
            -- reliably grow unit.inventory -- "Get" auto-stows into the backpack, and
            -- container contents are not top-level entries -- so the reopen gate also
            -- checks whether any listed item left the ground. Rebuilt only when the
            -- row count changes, not per frame.
            if #o.option ~= self.ol_nopt then
                self.ol_nopt = #o.option
                local ids = {}
                for i = 0, #o.option - 1 do
                    local okI, it = pcall(function() return o.option[i]:getItem() end)
                    if okI and it then ids[#ids + 1] = it.id end
                end
                self.ol_items = ids
            end
            self.ol_was_open = true
            self.ol_escaped = false
            if dfhack.getTickCount() < (self.ol_restore_until or 0) then
                self:hold_ol_scroll()
            else
                self.ol_restore_until = 0
                self.ol_scroll = o.scroll_position
            end
        end
        return
    end

    if self.job then self:drive(); return end

    if self.ol_was_open then
        self.ol_was_open = false
        self.ol_nopt = -1          -- next open must rebuild the row->item map
        closes = closes + 1
        g_close = g_close + 1
        if self.ol_escaped then                 -- Esc / right-click: dismissed for good
            self.ol_escaped = false
            escapes = escapes + 1
            g_esc = g_esc + 1
            return
        end
        -- an option was chosen; whether it was a "Get" is decided in drive(), after
        -- any coin-amount prompt has resolved and the carried count is trustworthy
        self.job = {kind = 'ground', stage = 'wait', wait = 0, settle = 0, tries = 0, attempts = 0}
        self:drive()
        return
    end

    if self.was_open then
        self.was_open = false
        closes = closes + 1
        if self.escaped then                    -- Esc / right-click: that is how you leave
            self.escaped = false
            escapes = escapes + 1
            -- a deliberate leave also forgets the search filter, so a later action-reopen
            -- doesn't resurrect it from a previous stay in the panel
            local ok, invsearch = pcall(reqscript, 'adv/inventory-search')
            if ok and invsearch.clear_last_search then pcall(invsearch.clear_last_search) end
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
        -- the header's Done button is the third way to deliberately leave
        if keys._MOUSE_L and clicked_done() then
            self.escaped = true
        end
    end
    if enabled and ol().open and OL_PICKUP[ol().context] then
        if keys.LEAVESCREEN or keys._MOUSE_R or keys._MOUSE_R_DOWN then
            self.ol_escaped = true
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
    and 'ON -- the inventory and the pick-up menu stay open after actions (Ctrl+I or `disable keep-inventory` to stop).'
    or 'OFF.'))
