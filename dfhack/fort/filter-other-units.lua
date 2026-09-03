-- Category filter buttons for the Units screen's "Other" tab.
--@module = true
--[[
fort/filter-other-units

The Units screen's **Other** tab is one undifferentiated list: your visitors, the
merchants' guards, a goblin ambush and every cave crawler on the map, all mixed
together. DF already knows which is which -- it prints the answer in the `Cat`
column -- so this adds buttons that filter on it, in the same corner of the panel
where the Dead/Missing tab keeps its `[Show death cause]` button:

    [Friendly] [Wildlife] [Hostile] [Caged?]

The first three are independent TOGGLES, not a radio group. With none of them
lit the list is unfiltered; clicking one filters to just that; clicking a second
one adds it, so `Wildlife` + `Hostile` is "everything that is not a guest".

`[Caged?]` is separate, and cycles through three states rather than toggling:

    [Caged?]   cages make no difference (the default)
    [No Cage]  hide anything in a cage
    [Caged!]   show ONLY what is in a cage

It combines with the other three, so `Hostile` + `[Caged!]` is your prisoner
list and `Hostile` + `[No Cage]` is what is still loose.

The categories are DF's own, read from the text it draws in the `Cat` column
rather than worked out again from unit flags -- the unit flags DFHack exposes do
not agree with it (a cave fish man from a hostile cavern civilization is not
flagged an invader, but DF still calls it Hostile). `Caged Prisoner` counts as
Hostile: it is an enemy, it just happens to be in a box. A unit DF has not
categorised yet is always shown, never silently hidden.

Auto-discovered by `overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local ON_PEN = COLOR_LIGHTGREEN
local OFF_PEN = COLOR_GREY

-- ---------------------------------------------------------------------------
-- reading the screen's widgets
-- ---------------------------------------------------------------------------
--
-- The units screen is DF's newer widget tree, not a viewscreen with fields:
--
--   info.creatures
--     Tabs
--       Residents / Pets/Livestock / Other   (a stack wrapping a widget_unit_list)
--         Unit List (widget_table)
--           [1] column headers
--           [2] widget_scroll_rows  -> ONE ROW WIDGET PER UNIT THE TAB SHOWS
--           [3] ...
--         Filter box (widget_textbox)
--
-- The rows are the thing to work with, and finding that out took the long way
-- round, so: the tempting target is `unit_list.entry_list`, the vector of units
-- behind the tab. Narrowing it does nothing you can see. DF builds its row
-- widgets from that vector once and rebuilds them on its own schedule -- when the
-- units on the map change, or when you type in the filter box -- and until then
-- it goes on drawing the rows it already has, from a list that no longer says
-- what they say. Nor can that rebuild be provoked from outside: writing the
-- filter box's `str`, writing the list's own `filter_str`, bouncing the selected
-- tab, closing and reopening the screen, and feeding synthetic keystrokes all
-- leave the rows exactly as they were, because the rebuild lives inside DF's key
-- handler.
--
-- Clearing a row's `flag.VISIBILITY_ACTIVE`, on the other hand, takes it out of
-- the list on the very next frame and closes the gap behind it. That is all this
-- needs, it is immediate, and it is undone just as easily.

local function creatures()
    return df.global.game.main_interface.info.creatures
end

local function unit_list(tab)
    local list
    pcall(function()
        local w = dfhack.gui.getWidget(creatures(), 'Tabs', tab)
        if not w then return end
        if w._type == df.widget_unit_list then list = w; return end
        for _, k in ipairs(dfhack.gui.getWidgetChildren(w)) do
            if k._type == df.widget_unit_list then list = k; return end
        end
    end)
    return list
end

local function rows_of(ul)
    local rows = {}
    pcall(function()
        local tbl = dfhack.gui.getWidgetChildren(ul)[1]
        local scroll = dfhack.gui.getWidgetChildren(tbl)[2]
        rows = dfhack.gui.getWidgetChildren(scroll)
    end)
    return rows
end

local function row_unit(row)
    local u
    pcall(function() u = dfhack.gui.getWidget(row, 0).u end)
    return u
end

-- the `Cat` cell: a truncated-text widget inside the row's fifth cell
local function row_category(row)
    local str
    pcall(function()
        local cell = dfhack.gui.getWidgetChildren(row)[5]
        if not cell then return end
        for _, k in ipairs(dfhack.gui.getWidgetChildren(cell)) do
            local ok, s = pcall(function() return k.str end)
            if ok and s and s ~= '' then str = s; return end
        end
    end)
    return str
end

-- DF's own words, in the three buckets the buttons offer. Anything unrecognised
-- returns nil, which means "show it" -- a category this does not know about is
-- never a reason to make a unit disappear.
local function bucket(str)
    if not str then return nil end
    if str:find('^Wild Animal') then return 'wildlife' end
    if str:find('^Hostile') then return 'hostile' end
    if str:find('^Caged Prisoner') then return 'hostile' end
    if str:find('^Friendly') then return 'friendly' end
    return nil
end

local function set_shown(row, show)
    pcall(function()
        if row.flag.VISIBILITY_ACTIVE ~= show then
            row.flag.VISIBILITY_ACTIVE = show
        end
    end)
end

-- ---------------------------------------------------------------------------
-- filter state
-- ---------------------------------------------------------------------------

local CAGE_ANY, CAGE_NONE, CAGE_ONLY = 0, 1, 2

local function is_caged(u, cat)
    local c = false
    if u then pcall(function() c = u.flags1.caged end) end
    -- DF says so too, for any row whose unit cannot be read
    return c or (cat ~= nil and cat:find('Caged') ~= nil)
end

-- ---------------------------------------------------------------------------
-- overlay
-- ---------------------------------------------------------------------------

FilterOther = defclass(FilterOther, overlay.OverlayWidget)
FilterOther.ATTRS{
    desc = 'Adds category filter buttons to the units screen\'s Other tab.',
    default_pos = {x = 50, y = -7},     -- where the Dead tab keeps its own button
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/CREATURES/OTHER',
    frame = {w = 44, h = 1},
    overlay_onupdate_max_freq_seconds = 0.1,
    version = 1,
}

function FilterOther:init()
    self.show = {friendly = false, wildlife = false, hostile = false}
    self.cage = CAGE_ANY
    self.hiding = false        -- true while rows are being held out of the list

    local function toggle(id)
        return function()
            self.show[id] = not self.show[id]
            self:relabel()
            self:sweep()       -- act on the click, not a tenth of a second later
        end
    end

    self:addviews{
        widgets.TextButton{
            view_id = 'friendly', frame = {t = 0, l = 0, w = 10},
            label = 'Friendly', on_activate = toggle('friendly'),
        },
        widgets.TextButton{
            view_id = 'wildlife', frame = {t = 0, l = 11, w = 10},
            label = 'Wildlife', on_activate = toggle('wildlife'),
        },
        widgets.TextButton{
            view_id = 'hostile', frame = {t = 0, l = 22, w = 9},
            label = 'Hostile', on_activate = toggle('hostile'),
        },
        widgets.TextButton{
            view_id = 'cage', frame = {t = 0, l = 32, w = 9},
            label = 'Caged? ',
            on_activate = function()
                self.cage = (self.cage + 1) % 3
                self:relabel()
                self:sweep()
            end,
        },
    }
    self:relabel()
end

-- The buttons carry their own state: lit when they are doing something, grey
-- when they are not, and the cage button says which of its three states it is in.
function FilterOther:relabel()
    for _, id in ipairs{'friendly', 'wildlife', 'hostile'} do
        local b = self.subviews[id]
        b.label.text_pen = self.show[id] and ON_PEN or OFF_PEN
        b:setLabel(b.label.text[1].text)
    end
    local cage = self.subviews.cage
    -- padded to one width: the button keeps its size as it cycles rather than
    -- growing and shrinking under the pointer
    cage.label.text_pen = self.cage == CAGE_ANY and OFF_PEN or ON_PEN
    cage:setLabel(({[CAGE_ANY] = 'Caged? ', [CAGE_NONE] = 'No Cage',
                    [CAGE_ONLY] = 'Caged! '})[self.cage])
end

-- is any button actually asking for something?
function FilterOther:filtering()
    return self.cage ~= CAGE_ANY
        or self.show.friendly or self.show.wildlife or self.show.hostile
end

function FilterOther:wanted(row)
    local cat = row_category(row)
    if self.cage ~= CAGE_ANY then
        local caged = is_caged(row_unit(row), cat)
        if self.cage == CAGE_NONE and caged then return false end
        if self.cage == CAGE_ONLY and not caged then return false end
    end
    if not (self.show.friendly or self.show.wildlife or self.show.hostile) then
        return true                     -- no category picked: every category passes
    end
    local b = bucket(cat)
    if not b then return true end       -- uncategorised rows are always shown
    return self.show[b] and true or false
end

-- Hide or show every row to match the buttons. DF rebuilds these rows whenever
-- the units on the map change and a fresh row comes back visible, so this runs on
-- a timer as well as on a click -- and once more after the last button goes out,
-- to put everything back.
function FilterOther:sweep()
    local filtering = self:filtering()
    if not filtering and not self.hiding then return end
    local ul = unit_list('Other')
    if not ul then return end
    for _, row in ipairs(rows_of(ul)) do
        set_shown(row, not filtering or self:wanted(row))
    end
    self.hiding = filtering
end

function FilterOther:overlay_onupdate()
    self:sweep()
end

OVERLAY_WIDGETS = {filter = FilterOther}

if dfhack_flags and dfhack_flags.module then return end

print('filter-other-units: overlay registered.')
print('Open the Units screen\'s Other tab and use [Friendly] [Wildlife] [Hostile] [Caged?].')
