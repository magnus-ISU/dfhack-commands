-- Newest first in the combat / sparring log, and a one-tick step button on it.
--@module = true
--[[
combat-log

Two changes to the combat log screen -- a unit's own log (a soldier's Sparring category, say)
and the report picker on the same screen. NEWEST FIRST applies to both lists. The footer line
and its step button belong to the unit log only: the picker keeps DF's own footer.

  * NEWEST FIRST. DF lists a unit's report log oldest-first, so the blow that just landed is at
    the bottom of a thousand lines and you scroll to find it. This reverses the list by ENTRY,
    not by line: a report that wraps over three lines keeps its three lines in order, and only
    the entries move. Reversing lines instead would shuffle the middle of every sentence.
  * A STEP KEY. The log is worth reading a tick at a time, and DF's own `.` does not reach
    this screen. The footer line -- "You can recenter on certain announcements." -- is replaced
    with `DFHack: most recent at the top. Press . to step one tick.`, and `.` advances the world
    by exactly one tick.

How the step works: this screen STOPS THE WORLD -- with the log open the frame counter does not
move even when the game is unpaused, which is why DF's own `.` does nothing here. So the step
closes the panel, lets exactly one frame pass, re-pauses and puts the panel straight back: same
view, scrolled to the top. It does NOT rebuild the list -- DF only does that in its own open-the-
log handler -- so the entries you see are as of the last time the log was opened. Reopen it to
pull the new ones in.

There is no clickable button: a real click on this screen is taken by DF's own panel before any
overlay is offered it, so the line names the key instead.

An unpause button is deliberately absent for now: `fort/no-pausing` does not hold on this
screen, so whatever DF does to keep this screen paused needs working out first.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local FOOTER_TEXT = 'You can recenter on certain announcements'
-- the start of our own replacement line, so the search above recognises what it drew last frame
local OUR_MARK = 'DFHack: most recent at the top.'
-- No button. A real left-click on this screen is taken by DF's own panel before any overlay is
-- offered it, and polling the mouse state did not catch it either, so the line says which key to
-- press instead of pretending to be clickable.
local STEP_HINT = 'Press . to step one tick.'
-- how much blank to lay over the tail of DF's footer line; its full text is a good deal longer
-- than ours, and whatever is left of it reads as garbage
local FOOTER_PAD = 24

local function alert_iface()
    return df.global.game.main_interface.announcement_alert
end

-- ---- one tick of world time ---------------------------------------------------

-- Step exactly one tick.
--
-- THE SCREEN ITSELF STOPS THE WORLD. With the log open the frame counter and the year tick do
-- not move even with `pause_state` false -- which is why DF's own `.` does nothing here and why
-- fort/no-pausing looks broken on this screen. So the panel is shut for the frame in which the
-- world moves, and put straight back.
--
-- WHAT IT DOES NOT DO IS REBUILD THE LIST. DF builds a unit's log inside its own "open this log"
-- handler, which setting the view fields does not run. Feeding DF the click on the unit's row in
-- the picker DOES run it, and that is what an earlier version of this did -- but it had to find
-- the row by reading the whole screen, retry when the row was not drawn yet, and it left an empty
-- panel when a second step arrived mid-flight. A stale list is a small price next to a blank
-- window and a laggy screen, so the step is now the plain thing: same view, top of the list, one
-- tick further on. Reopen the log by hand to see the new lines.
pending = pending or nil

function step_one_tick()
    if pending then return false end          -- a step is already in flight; ignore the spam
    local ai = alert_iface()
    pending = {
        unit = ai.viewing_unit, uac = ai.viewing_unit_uac,
        alert = ai.viewing_alert, button = ai.viewing_alert_button,
    }
    ai.open = false
    df.global.pause_state = false
    dfhack.timeout(1, 'frames', function()
        df.global.pause_state = true
        local a = alert_iface()
        local p = pending
        pending = nil
        if not p then return end
        a.viewing_unit, a.viewing_unit_uac = p.unit, p.uac
        a.viewing_alert, a.viewing_alert_button = p.alert, p.button
        -- both scrolls to the top: an offset left over from a long list sits past the end of a
        -- shorter one, which draws as a completely empty panel
        a.scroll_position_alert, a.scroll_position_uac = 0, 0
        a.open = true                         -- open LAST, once the view is set
    end)
    return true
end

-- ---- newest first --------------------------------------------------------------

-- A log view is a set of PARALLEL vectors of the same length: the text lines, and one entry per
-- line for whatever that line points at -- the report, the unit, the unit's log category -- plus
-- a flag marking the FIRST line of each entry. An entry is a run of lines from one `is_start` to
-- the next, so reversing means reversing the runs while keeping each run's lines in their own
-- order. Reversing lines instead would shuffle the middle of every sentence.
local function entry_runs(is_start, n)
    local runs, cur = {}, nil
    for i = 0, n - 1 do
        if is_start[i] or not cur then
            cur = {first = i, last = i}
            runs[#runs + 1] = cur
        else
            cur.last = i
        end
    end
    return runs
end

-- reverse the entries of one log view in place; returns true when it rearranged anything
local function reverse_log(box, vecs, starts)
    local n = #box.text
    if n == 0 or n ~= #starts then return false end
    for _, v in ipairs(vecs) do
        if #v ~= n then return false end     -- not parallel: leave the whole thing alone
    end
    local runs = entry_runs(starts, n)
    if #runs < 2 then return false end
    -- read every vector out, then write them back run by run from the end
    local lines, starts_copy, cols = {}, {}, {}
    for _ in ipairs(vecs) do cols[#cols + 1] = {} end
    for i = 0, n - 1 do
        lines[i], starts_copy[i] = box.text[i], starts[i]
        for c, v in ipairs(vecs) do cols[c][i] = v[i] end
    end
    local w = 0
    for r = #runs, 1, -1 do
        local run = runs[r]
        for i = run.first, run.last do
            box.text[w] = lines[i]
            -- vector<bool> is bit-packed: assigning an existing index is fine, inserting is not
            starts[w] = starts_copy[i]
            for c, v in ipairs(vecs) do v[w] = cols[c][i] end
            w = w + 1
        end
    end
    return true
end

-- A signature of the list as it stands, so the reversal is applied once per rebuild rather than
-- every frame. The ends of the text are what changes when DF rebuilds the list -- and when we
-- reverse it -- so they are the signature. Report ids cannot serve: the picker's lines carry no
-- report at all, only units.
local function log_signature(box)
    local n = #box.text
    if n == 0 then return '0' end
    local first = box.text[0].value or ''
    local last = box.text[n - 1].value or ''
    return ('%d/%s/%s'):format(n, first:sub(1, 24), last:sub(1, 24))
end

-- ---- the overlay ---------------------------------------------------------------

CombatLogOverlay = defclass(CombatLogOverlay, overlay.OverlayWidget)
CombatLogOverlay.ATTRS{
    desc = 'Combat log: newest entry first, and a one-tick step button.',
    default_pos = {x = 2, y = 6},
    default_enabled = true,
    viewscreens = 'dwarfmode/AnnouncementAlert',
    -- the footer belongs to DF's own panel, which is painted late; the full painter is what puts
    -- our line on top of it (same reason fort/guild-agreement-dates needs it)
    fullscreen = true,
    frame = {w = 72, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function CombatLogOverlay:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = {
                {text = OUR_MARK .. ' ', pen = COLOR_GREY},
                {text = STEP_HINT, pen = COLOR_GREY},
                -- DF's own footer is longer than ours ("...  Right click to close."), so the
                -- rest of its line is painted over with blanks; without this its tail survives
                -- past the end of our text
                {text = function() return (' '):rep(FOOTER_PAD) end},
            },
        },
    }
end

-- Find the footer line we sit on. IT MUST ALSO FIND ITS OWN LINE: once this overlay draws, DF's
-- text is no longer on the screen to be found, so a search for DF's wording alone reported "not
-- my screen", hid the line, let DF repaint, found it again -- a blink at the rate of the scan.
-- Our own leading text counts as a match, at the same column, so the position simply holds.
local function footer_pos()
    local sw, sh = dfhack.screen.getWindowSize()
    for y = sh - 1, 0, -1 do
        local chars = {}
        for x = 0, math.min(sw, 120) - 1 do
            local ok, pen = pcall(dfhack.screen.readTile, x, y)
            local ch = (ok and pen and pen.ch) or 0
            chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local line = table.concat(chars)
        local c = line:find(FOOTER_TEXT, 1, true) or line:find(OUR_MARK, 1, true)
        if c then return c - 1, y end
    end
end

function CombatLogOverlay:overlay_onupdate()
    local ai = alert_iface()
    -- NEWEST FIRST APPLIES TO BOTH LISTS: a unit's own log (uac_*) and the report picker on the
    -- same screen (alert_*). They are rebuilt independently, so each carries its own signature.
    if ai.viewing_unit then
        self.uac_sig = self:reorder(ai.uac_text, {ai.uac_zoom_line_ann},
                                    ai.uac_zoom_line_is_start, self.uac_sig)
    else
        -- the picker's lines point at units and their log category as well as at reports, and
        -- every one of those vectors has to move with its line
        self.alert_sig = self:reorder(ai.alert_text,
                                      {ai.zoom_line_ann, ai.zoom_line_unit, ai.zoom_line_unit_uac},
                                      ai.zoom_line_is_start, self.alert_sig)
    end
    -- THE FOOTER LINE DOES NOT. It belongs to a unit's log, whose footer it replaces; the
    -- picker keeps DF's own "Select a report to view the full text." untouched. Finding that
    -- one line is the whole test -- no footer, no line of ours.
    -- The footer line belongs to a UNIT'S LOG. Gating it on the view -- not just on finding the
    -- footer text -- matters because the probe now recognises its own line: without this, once
    -- drawn it kept finding itself and followed the panel back to the report picker, which is
    -- the one place it must not appear.
    if not ai.viewing_unit then
        self.visible = false
        return
    end
    local now = dfhack.getTickCount()
    if not self.placed_ms or now < self.placed_ms or now - self.placed_ms >= 500 then
        self.placed_ms = now
        local col, row = footer_pos()
        if not col then
            self.visible = false
            return
        end
        local ir = gui.get_interface_rect()
        self.frame = {w = self.frame.w, h = self.frame.h, l = col - ir.x1, t = row - ir.y1}
        self:updateLayout(gui.ViewRect{rect = ir})
        self.visible = true
    end
end

-- reverse one list if it has been rebuilt since we last touched it; returns the new signature
function CombatLogOverlay:reorder(box, vecs, starts, sig)
    local now_sig = log_signature(box)
    if now_sig == sig then return sig end
    if reverse_log(box, vecs, starts) then
        return log_signature(box)            -- our own order becomes the baseline
    end
    return now_sig
end

-- No input handling at all: `.` arrives as a DFHack keybinding (see magnus-scripts), which is
-- dispatched before DF gets the key, and nothing else on this line is interactive.

OVERLAY_WIDGETS = {log = CombatLogOverlay}

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
if args[1] == 'step' then
    -- the command form, so a keybinding can reach it: DF eats `.` on this screen before the
    -- overlay ever sees it, while a bound command is dispatched by DFHack itself
    step_one_tick()
    return
end

local ai = alert_iface()
local box = ai.viewing_unit and ai.uac_text or ai.alert_text
print(('combat-log: %d lines in the list currently on screen.'):format(#box.text))
print('  The overlay reverses entries (newest first) and adds the step hint to the footer.')
