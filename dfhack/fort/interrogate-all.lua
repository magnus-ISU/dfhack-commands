-- Justice interrogation screen: schedule every visitor, or every citizen, in one click.
--@module = true
--[[
interrogate-all

The interrogation tab schedules ONE unit per click, and the question you actually have --
"has anything walked in here that shouldn't have?" -- is asked of everybody at once. DFHack's
own overlay already filters the list; this adds the two bulk actions above it:

    [cancel interviews]
    [interrogate all]
    [interrogate all visitors]

Three plain text buttons, no border, lined up with DFHack's own filter panel on the same screen
and sitting above it.

`[interrogate all]` MEANS WHAT `F: Show` MEANS. It schedules exactly the rows that filter is
showing -- set it to `Risky visitors` and the button takes the risky visitors -- because a
bulk button that reaches past the list you are looking at is one you cannot trust. DFHack's
own filter function is asked directly rather than reimplemented, so the two can never drift.

WITH NO FILTER SET (`Show: All`) it still leaves out what you cannot question: the deceased
and the missing, animals and wildlife, and megabeasts, semi-megabeasts, titans, forgotten
beasts and demons. Those share the `Others` bucket with a human axeman, who is exactly the
sort you DO want to question, so the bucket cannot be skipped wholesale.

`[interrogate all visitors]` ignores the `Show` filter and takes every visitor on the list,
under the same rules about the dead and the inhuman.

BOTH RESPECT `Interviewed:`. With DFHack's toggle on Exclude a unit already interviewed is
skipped, exactly as the list itself skips it; on Include it is scheduled again. Units already
scheduled are left alone either way.

Registered automatically as overlay `fort/interrogate-all.buttons`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local justice = df.global.game.main_interface.info.justice

-- ---- the list DF is showing --------------------------------------------------

-- the screen's own unit list, the same one DFHack's filter overlay drives
local function unit_list()
    local tabs = dfhack.gui.getWidget(justice, 'Tabs')
    if not tabs then return nil end
    return dfhack.gui.getWidget(tabs, 'Open cases', 'Right panel', 'Interrogate')
        or dfhack.gui.getWidget(tabs, 'Cold cases', 'Right panel', 'Interrogate')
end

-- The units on it, each with its index. `entry_list` is the WHOLE list -- DF filters at draw
-- time, not here, so it holds every unit whatever `Show` is set to, and the index is the one
-- the list's own cursor uses. The entry is an item-or-unit union, so the tag is checked
-- before the unit side is read.
local function listed_units()
    local list = unit_list()
    local out = {}
    if not list then return out end
    for idx, entry in ipairs(list.entry_list) do
        local ok, u = pcall(function() return entry.t == 0 and entry.u or nil end)
        if ok and u and df.unit:is_instance(u) then
            out[#out + 1] = {idx = idx, unit = u}
        end
    end
    return out
end

-- ---- scheduling --------------------------------------------------------------
--
-- DF changes two things when you click a row: the bit in `justice.crimeflag` and the entry in
-- the list's own `selected` set. NEITHER CAN BE WRITTEN FROM LUA. The map is exposed as a
-- sequence -- `pairs` hands back 0..n-1 and the flag values, never the unit keys -- and the
-- set refuses `insert`. Feeding `_MOUSE_L` at the row does nothing either; DF's widget lists
-- do not see synthetic clicks. (Do not try to recover a key by casting those numbers back to
-- units: `df.reinterpret_cast(df.unit, 0)` segfaults DF.)
--
-- WHAT DOES WORK is DF's own keyboard path: put the list's cursor on the row and feed SELECT.
-- DF then does exactly what a click does -- the same two pieces of state, no jobs, no side
-- effects. Three things had to be right before that worked:
--
--   * `cursor_idx` is a DISPLAY index -- the order the rows are drawn and stored in
--     `widget_scroll_rows.children` -- NOT an index into `entry_list`, which is DF's internal
--     order and names a different unit at every position. Reading the unit from one order and
--     pressing in the other is what made early passes switch scheduled units off.
--   * the cursor has to be set from INSIDE the frame (the overlay's update). Set over RPC,
--     between frames, it is gone before the key is processed.
--   * one fed key lands per frame, and the row has to be on screen: rows are built as they
--     scroll into view, and the end of the list is where DF stops building them.
--
-- SELECT is a toggle, so a row that is already scheduled is NEVER pressed -- `scheduled_set`
-- answers that first. And the verdict on a press is read back BY IDENTITY (is this unit
-- scheduled now?) rather than by watching the selection count, since a count cannot tell
-- "this unit went on" from "some other row went off".

local gui = require('gui')

-- frames to wait for DF to apply a fed SELECT before reading the answer
local VERIFY_TICKS = 3

local function is_interviewed(unit)
    local ok, done = pcall(require('plugins.sort').sort_is_interviewed, unit)
    return ok and done or false
end

-- WALKED, ONE ROW PER FRAME, because that is the only thing DF accepts.
--
-- Three hard limits found by measurement:
--   * SELECT only acts on a row that is currently RENDERED. Parking `cursor_idx` on row 200
--     of 372 and feeding SELECT does nothing at all -- a first attempt took the 4 eligible
--     visitors that happened to be on screen and silently missed the other 17.
--   * DF honours ONE fed key per frame. A second SELECT in the same frame is dropped, and so
--     is a STANDARDSCROLL_DOWN fed after a SELECT.
--   * `widget_scroll_rows.scroll` can be written but DF recomputes it from its own cursor on
--     the next frame, so the view cannot be jumped either.
--
-- What is left is what a player does: move the cursor down one row with its own key -- which
-- scrolls the view along with it -- and press SELECT on the rows you want. So this is pumped
-- from the overlay's update, one keystroke a frame, and a full list of 372 takes a few
-- seconds. Leaving the screen abandons it.
--
-- SELECT is a TOGGLE, so what is already scheduled has to be known BEFORE pressing it --
-- see `scheduled_set` below, which reads the current state off the selection itself. A row
-- already on is never pressed. A button whose whole job is to schedule must never switch
-- anything off, not even for a frame.
local gui = require('gui')

local function is_interviewed(unit)
    local ok, done = pcall(require('plugins.sort').sort_is_interviewed, unit)
    return ok and done or false
end

-- ---- what is already scheduled ------------------------------------------------
--
-- The `selected` set cannot be indexed by unit, but each entry PRINTS its pointer, and a
-- unit's own address comes from `df.sizeof`. Matching the two gives a straight answer to "is
-- this row already on" -- checked against the whole list, 177 for 177.
--
-- That answer is what keeps this tool from ever switching a row OFF. Enter is a toggle: press
-- it on a row that is already scheduled and you have just un-scheduled somebody. So a row
-- that is already on is never pressed -- not pressed and put back, simply not pressed.
local function addr_of(unit)
    local _, a = df.sizeof(unit)
    return ('%x'):format(a)
end

local function scheduled_set(list)
    local set, sel = {}, list.selected
    for i = 0, #sel - 1 do
        local a = tostring(sel[i]):match('0x(%x+)')
        if a then set[a] = true end
    end
    return set
end

pump = pump or nil

last_result = last_result or nil

local function stop(quiet)
    local p = pump
    pump = nil
    if not p or quiet then return end
    last_result = ('%s: added %d, already %d, missed %d, rows %d, ticks %d')
        :format(p.which, p.added, p.already, p.missed, p.row, p.ticks)
    local verb = p.target and 'scheduled for interrogation' or 'interview(s) cancelled'
    local msg = p.target and ('%d %s %s'):format(p.added, p.which, verb)
                        or ('%d %s'):format(p.added, verb)
    if p.already > 0 and p.target then
        msg = ('%s (%d already scheduled)'):format(msg, p.already)
    end
    if p.missed > 0 then msg = ('%s -- %d would not take'):format(msg, p.missed) end
    dfhack.gui.showAnnouncement(msg, p.added > 0 and COLOR_GREEN or COLOR_YELLOW, false)
end

-- A press always starts a fresh pass. Refusing while `pump` is set looks tidy and is a trap:
-- a pass that ended without clearing it (a screen left mid-way, say) leaves the buttons dead
-- with no way back short of a reload.
local SCREEN = 'dwarfmode/Info/JUSTICE/Interrogating'

local function start(which, wanted, target)
    -- ONLY FROM THE SCREEN ITSELF. A pass started while the interrogation tab is not up --
    -- which a button click cannot do, but a script call can -- has nowhere to run: the pump
    -- only ticks while the overlay is on screen, so the pass sat dormant in `pump` and fired
    -- the next time the player opened the tab, days later, scheduling fifteen visitors they
    -- had not asked for. Refused outright rather than queued.
    if not dfhack.gui.matchFocusString(SCREEN) then
        dfhack.gui.showAnnouncement('interrogate-all: open the interrogation tab first.',
            COLOR_LIGHTRED, false)
        return
    end
    local list = unit_list()
    if not list then
        dfhack.gui.showAnnouncement('interrogate-all: the interrogation list is not open.',
            COLOR_LIGHTRED, false)
        return
    end
    pump = {which = which, wanted = wanted, target = target ~= false,
            added = 0, already = 0, missed = 0,
            row = 0, state = 'walk', ticks = 0, tries = 0,
            max_ticks = (#list.entry_list + 400) * 4}
    last_result = 'running'
    dfhack.gui.showAnnouncement(pump.target and ('Interrogating all %s...'):format(which)
        or ('Cancelling %s...'):format(which), COLOR_WHITE, false)
end


-- ---- the rendered rows ---------------------------------------------------------
--
-- THE ROW WIDGETS ARE THE ONLY HONEST ORDER. `entry_list` is in DF's own internal order
-- (Beso, Sulthu, Mong...) while the list on screen is sorted (Aban, Adil, Akan...), so an
-- index into `entry_list` names a different unit than the row at that position -- which is
-- how presses meant for one unit landed on another and switched scheduled units off. The
-- rows themselves carry their unit, so they are what this reads.
local function row_widgets()
    local list = unit_list()
    if not list then return nil end
    local ok, table_w = pcall(dfhack.gui.getWidget, list, 0)
    if not ok or not table_w then return nil end
    local ok2, rows = pcall(dfhack.gui.getWidget, table_w, 1)
    if not ok2 then return nil end
    return list, table_w, rows
end

local function row_unit(row)
    if not row then return nil end
    for i = 0, #row.children - 1 do
        local ok, c = pcall(dfhack.gui.getWidget, row, i)
        if ok and c then
            local ok2, u = pcall(function() return c.u end)
            if ok2 and u and df.unit:is_instance(u) then return u end
            if #c.children > 0 then
                local nested = row_unit(c)
                if nested then return nested end
            end
        end
    end
end

-- what a pass is doing, for when one goes wrong: `dfhack.script_environment(
-- 'fort/interrogate-all').status()`
function status()
    local list = unit_list()
    return {
        list = list ~= nil,
        scheduled = list and #list.selected or -1,
        last_result = last_result,
        pump = pump and {row = pump.row, state = pump.state, added = pump.added,
                         already = pump.already, missed = pump.missed, ticks = pump.ticks} or nil,
    }
end

-- THE ROW IS ADDRESSED BY ITS DISPLAY INDEX, which is what `list.cursor_idx` means: the same
-- order the rows are drawn in and `widget_scroll_rows.children` is stored in -- NOT the order
-- of `entry_list`, which is DF's internal order and names a different unit at every index.
-- Reading the unit from one order while pressing in the other is what made earlier passes
-- switch scheduled units OFF.
--
-- Driven from inside the frame (the overlay's update), because a cursor set from an RPC call
-- between frames is gone by the time the key is processed. A row that is wanted and not
-- already scheduled costs one frame; every other row is skipped without a keystroke, so a
-- pass costs a frame per unit taken rather than per row.
local function pump_tick()
    local p = pump
    if not p then return end
    -- LEAVING THE SCREEN ABANDONS THE PASS, for real. The overlay stops ticking the moment
    -- the tab closes, so without this a half-done pass simply waited in `pump` and carried on
    -- from the same row whenever the tab was next opened -- possibly days later, on a list
    -- that had changed under it. A gap in the frame counter is what "the screen was closed"
    -- looks like from in here.
    local frame = df.global.world.frame_counter
    if p.last_frame and frame - p.last_frame > 3 then
        pump = nil
        last_result = ('%s: abandoned (screen closed) after %d added'):format(p.which, p.added)
        return
    end
    p.last_frame = frame
    local list, table_w, rows = row_widgets()
    if not list or not rows then return stop() end
    p.ticks = p.ticks + 1
    if p.ticks > p.max_ticks then return stop() end
    local visible = rows.num_visible > 0 and rows.num_visible or 10

    -- the verdict on the row pressed last frame, BY IDENTITY rather than by counting: the
    -- count cannot tell "this unit got scheduled" from "some other row got switched off"
    if p.state == 'verify' then
        local unit = df.unit.find(p.unit_id)
        local now_on = unit and scheduled_set(list)[addr_of(unit)] or false
        if unit and now_on == p.target then
            p.added, p.state, p.tries = p.added + 1, 'walk', 0
        else
            p.tries = p.tries + 1
            if p.tries >= 3 then
                p.missed, p.state, p.tries = p.missed + 1, 'walk', 0
            else
                list.cursor_idx = p.row_pressed                -- key dropped: press again
                if p.row_pressed < rows.scroll or p.row_pressed >= rows.scroll + visible then
                    rows.scroll = math.max(0, p.row_pressed - visible // 2)
                end
                gui.simulateInput(dfhack.gui.getCurViewscreen(true), 'SELECT')
            end
        end
        return
    end

    -- THE ROW HAS TO BE ON SCREEN BEFORE IT CAN BE PRESSED, and it is DF that builds and
    -- scrolls -- a frame later, not in this one. So the window is brought to the row on one
    -- tick and the row is pressed on the next.
    --
    -- THE END OF THE LIST IS WHERE DF STOPS BUILDING ROWS, not `#entry_list`: the rows DF has
    -- built are the rows there are (273 of them against 375 entries here, since entries are
    -- not rows). Sizing the walk from the entry list counted 102 rows that do not exist as
    -- failures.
    while true do
        local idx = p.row
        local built = #rows.children
        if idx >= built then
            rows.scroll = math.max(0, built - visible)
            p.waited = (p.waited or 0) + 1
            if p.waited > 6 then return stop() end    -- DF builds no more: that was the end
            return
        end
        if idx < rows.scroll or idx >= rows.scroll + visible then
            rows.scroll = math.max(0, idx - visible // 2)
            list.cursor_idx = idx
            p.waited = (p.waited or 0) + 1
            if p.waited > 6 then                      -- it will not come into view: move on
                p.missed, p.row, p.waited = p.missed + 1, idx + 1, 0
            end
            return
        end
        local ok, row = pcall(dfhack.gui.getWidget, rows, idx)
        if not ok or not row then
            p.waited = (p.waited or 0) + 1
            if p.waited > 6 then p.missed, p.row, p.waited = p.missed + 1, idx + 1, 0 end
            return                                    -- give DF a frame to build it
        end
        p.waited = 0
        local unit = row_unit(row)
        p.row = idx + 1
        if unit and p.wanted(unit) then
            local is_on = scheduled_set(list)[addr_of(unit)] or false
            if is_on == p.target then
                p.already = p.already + 1             -- already as wanted: never pressed
            else
                p.unit_id, p.row_pressed, p.state, p.tries = unit.id, idx, 'verify', 0
                list.cursor_idx = idx
                gui.simulateInput(dfhack.gui.getCurViewscreen(true), 'SELECT')
                return
            end
        end
    end
    stop()
end


-- DFHack's filter overlay owns both settings on this screen; ask it rather than keeping a
-- second copy that could disagree with the one on screen.
function filter_overlay()
    local ok, info = pcall(require, 'plugins.sort.info')
    return ok and info and rawget(info, 'interrogate_instance') or nil
end

local function include_interviewed()
    local inst = filter_overlay()
    if not inst then return true end          -- no toggle to read: scope nothing out
    local ok, v = pcall(function() return inst.subviews.include_interviewed:getOptionValue() end)
    return not ok or v
end

-- ---- who can be questioned at all -------------------------------------------
--
-- Only applied where nothing else is filtering: with `Show` set to something, that setting IS
-- the answer and this tool does not second-guess it. Unfiltered, the list is everything DF
-- knows about, and most of it cannot be interrogated in any useful sense -- but `Others`
-- holds a human axeman next to a forgotten beast, so it is the creature that has to be
-- tested, not the bucket.
local function questionable(unit)
    if dfhack.units.isDead(unit) or not dfhack.units.isActive(unit) then return false end
    if dfhack.units.isAnimal(unit) or dfhack.units.isWildlife(unit) then return false end
    if dfhack.units.isMegabeast(unit) or dfhack.units.isSemiMegabeast(unit)
        or dfhack.units.isTitan(unit) or dfhack.units.isForgottenBeast(unit)
        or dfhack.units.isDemon(unit)
    then
        return false
    end
    return true
end

-- DFHack's `Show:` setting, or nil when its overlay is not up
local function shown_subset()
    local inst = filter_overlay()
    if not inst then return nil end
    local ok, v = pcall(function() return inst.subviews.subset:getOptionValue() end)
    return ok and v or nil
end

-- DFHack's own filter, asked rather than copied -- it applies `Show:` AND `Interviewed:`
local function passes_dfhack_filter(unit)
    local ok, info = pcall(require, 'plugins.sort.info')
    if not ok or not info or not info.do_justice_filter then return true end
    local ok2, keep = pcall(info.do_justice_filter, unit)
    return not ok2 or keep
end

-- ---- the two actions ---------------------------------------------------------

-- everything the `Show` filter is showing; unfiltered, everything that can be questioned
local function interrogate_all()
    local unfiltered = (shown_subset() or 'all') == 'all'
    return start('unit(s)', function(unit)
        if not passes_dfhack_filter(unit) then return false end
        return not unfiltered or questionable(unit)
    end)
end

-- every visitor, whatever `Show` is set to -- but never one the `Interviewed` toggle excludes
local function interrogate_visitors()
    local keep_interviewed = include_interviewed()
    return start('visitor(s)', function(unit)
        if not dfhack.units.isVisiting(unit) then return false end
        if not questionable(unit) then return false end
        return keep_interviewed or not is_interviewed(unit)
    end)
end

-- CANCEL: every scheduled interview, whatever `Show` is set to. The same walk with the
-- target state inverted -- Enter is pressed only on rows that are ON, verified off by
-- identity afterwards -- so a row already off is never touched, and nothing can be switched
-- on by accident. It reaches the whole list, not the filtered view: "cancel the interviews"
-- means all of them, and a filter that hid some would leave the captain still working.
local function cancel_interviews()
    return start('scheduled interview(s)', function() return true end, false)
end

-- ---- overlay -----------------------------------------------------------------
--
-- Two bare labels rather than TextButtons: a TextButton draws its banner, and these sit
-- directly above DFHack's own bordered filter panel (`sort.interrogation`, at y=-5, four rows
-- tall) where a second frame would read as part of it. So: plain text, and the hover
-- highlight a Label gives on its own is the whole affordance.

InterrogateAllOverlay = defclass(InterrogateAllOverlay, overlay.OverlayWidget)
local STOCK = 'sort.interrogation'
local STOCK_PANEL_W = 30          -- the visible panel inside DFHack's (much wider) widget

InterrogateAllOverlay.ATTRS{
    desc = 'Adds interrogate-all and interrogate-all-visitors buttons to the justice screen.',
    default_pos = {x = 1, y = -10},
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/JUSTICE/Interrogating',
    frame = {w = STOCK_PANEL_W, h = 3},
    overlay_onupdate_max_freq_seconds = 0,       -- the pump needs every frame
    version = 3,
}

function InterrogateAllOverlay:overlay_onupdate()
    pump_tick()
end

function InterrogateAllOverlay:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 1},
            text = '[cancel interviews]',
            text_pen = COLOR_WHITE,
            on_click = cancel_interviews,
        },
        widgets.Label{
            frame = {t = 1, l = 1},
            text = '[interrogate all]',
            text_pen = COLOR_WHITE,
            on_click = interrogate_all,
        },
        widgets.Label{
            frame = {t = 2, l = 1},
            text = '[interrogate all visitors]',
            text_pen = COLOR_WHITE,
            on_click = interrogate_visitors,
        },
    }
end

-- LINED UP WITH DFHACK'S PANEL, wherever the player has dragged it. Copying the x out of the
-- config is not enough: DFHack's widget is half the screen wide and draws its panel flush
-- against its own right edge (`frame.w` is recomputed every layout), so the panel's left edge
-- is what has to be matched, not the widget's. Only the horizontal anchor is taken -- the row
-- these sit on is this overlay's own position, moved with `gui/overlay` like any other.
function InterrogateAllOverlay:preUpdateLayout()
    local ok, state = pcall(function() return require('plugins.overlay').get_state() end)
    local entry = ok and state and state.db and state.db[STOCK]
    local stock = entry and entry.widget
    if not stock or not stock.frame then return end
    local f = stock.frame
    if f.l and f.w then
        self.frame.l, self.frame.r = f.l + f.w - STOCK_PANEL_W, nil
    elseif f.r then
        self.frame.l, self.frame.r = nil, f.r
    end
end

OVERLAY_WIDGETS = {buttons = InterrogateAllOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('interrogate-all: registered overlay fort/interrogate-all.buttons')
print('  Two buttons above DFHack\'s filter panel on the interrogation tab:')
print('  [interrogate all] (whatever `F: Show` is showing) and [interrogate all visitors].')
