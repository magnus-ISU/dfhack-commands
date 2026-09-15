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

`[Caged?]` IS ON ALL THREE TABS -- Residents and Pets/Livestock as well as Other
-- because a caged animal is just as easy to lose in the livestock list, and a
resident can be in a cage too. It appears ONLY where the list you are looking at
actually has something caged in it, which is the same rule on every tab: no
caged members, no button. A tab with none is never offered a filter whose only
possible effect is to empty it.

The cage state is kept when you step onto a tab that has nothing caged, so
stepping back finds it as you left it rather than silently reset. The category
buttons stay on Other, which is the only tab with a `Cat` column to sort by.

WHERE IT SITS. `[Caged?]` is pushed out to column 88, well right of the other
three, to clear DFHack's own `logistics.autoretrain` panel -- that sits at
columns 51-86 over rows 59-63 on the Pets/Livestock tab, which is exactly the row
this uses. The columns between `Hostile` and `Caged?` draw nothing and swallow no
clicks.

The categories are DF's own, read from the text it draws in the `Cat` column
rather than worked out again from unit flags -- the unit flags DFHack exposes do
not agree with it (a cave fish man from a hostile cavern civilization is not
flagged an invader, but DF still calls it Hostile).

WHAT GOES WHERE. `Friendly` and `Hostile` are not the only friends and enemies on
this tab, and taking them for the whole answer is what made the buttons look
broken: a fort with a caravan in and a tavern full of visitors had not one row
saying either word -- the list was guests, a merchant's camel, ravens and a bronze
colossus -- so every row fell through to "unknown" and no filter moved anything.

    Friendly   Friendly, Merchant, Guest (`Guest / Listen to Story`), Caged Guest
    Hostile    Hostile, Uninvited Guest, Caged Prisoner
    Wildlife   Wild Animal, including `Wild Animal (Caged)`

Merchants and guests are people you let in; an *uninvited* guest is DF's word for
the thing that walked in without being asked, and it belongs with the enemies. A
cage says where somebody is, not whose side they are on, so `Caged Prisoner` is
Hostile and `Caged Guest` is Friendly. A unit DF has not categorised yet is always
shown, never silently hidden.

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

-- Which tab is on screen, by the focus string DF reports and the name its widget tree is
-- keyed by. `creatures().current_mode` is NOT the source of truth -- it reads OTHER while the
-- screen is plainly showing Pets/Livestock -- so the focus string decides.
--
-- RESIDENTS HAS NO TAIL. Pets is `.../CREATURES/PET`, Other is `.../CREATURES/OTHER`,
-- Dead/Missing is `.../CREATURES/DECEASED` -- and Residents is just
-- `dwarfmode/Info/CREATURES`, with nothing after it. Registering for `.../CITIZEN`, which is
-- what the mode enum calls it, matches nothing and the buttons never appear there at all.
-- The tailed ones are therefore tested FIRST and the bare string is the fallthrough, since
-- it matches every one of them.
--
-- DEAD/MISSING IS DELIBERATELY NOT ONE OF THEM. That row already belongs to
-- `sort.deathcause_button` and `fort/needs-tomb-notification`, at columns 50-70 and 72-89,
-- and the cage button would land on top of the second one.
local TABS = {
    {focus = 'dwarfmode/Info/CREATURES/PET',      name = 'Pets/Livestock', other = false},
    {focus = 'dwarfmode/Info/CREATURES/OTHER',    name = 'Other',          other = true},
    {focus = 'dwarfmode/Info/CREATURES/DECEASED', name = nil,              other = false},
}
local RESIDENTS = {focus = 'dwarfmode/Info/CREATURES', name = 'Residents', other = false}

local function current_tab()
    for _, t in ipairs(TABS) do
        if dfhack.gui.matchFocusString(t.focus) then
            return t.name and t or nil          -- a nil name is a tab we stay off
        end
    end
    if dfhack.gui.matchFocusString(RESIDENTS.focus) then return RESIDENTS end
end

-- The unit list under a tab, wherever DF has buried it. NOT a one-level scan: the tabs are
-- not shaped alike. `Dead/Missing` IS the list; `Other` is a stack holding it directly; but
-- `Residents` and `Pets/Livestock` wrap theirs in a `widget_container` one level further
-- down, and looking only at the stack's own children finds nothing there. The symptom is
-- not an error -- the sweep just quietly does nothing on those two tabs, and the cage button
-- goes on showing whatever the last tab it could read had to say.
local function unit_list(tab)
    local list
    local function find(w, depth)
        if not w or list or depth > 4 then return end
        if w._type == df.widget_unit_list then list = w; return end
        for _, k in ipairs(dfhack.gui.getWidgetChildren(w)) do
            find(k, depth + 1)
            if list then return end
        end
    end
    pcall(function() find(dfhack.gui.getWidget(creatures(), 'Tabs', tab), 0) end)
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
--
-- THE WORDS ARE DF'S, matched on the prefix because several of them carry a tail: a visitor
-- reads "Guest / Listen to Story", "Guest / No activity" and so on, with what they are
-- currently up to after the slash, and a caged animal reads "Wild Animal (Caged)".
--
-- `Friendly` and `Hostile` are not the only friends and enemies on this tab, which is what
-- made the buttons look broken: a fort with a caravan in and a tavern full of visitors had
-- not one row saying either word -- the list was guests, a merchant's camel, ravens and a
-- bronze colossus -- so every one of them fell through to nil and no filter moved anything.
--   * MERCHANTS and GUESTS are friendly. A guest is someone you let in; a merchant is here
--     to trade with you.
--   * An UNINVITED GUEST is not. DF's word for the thing that walked in without being asked
--     -- the bronze colossus, on the fort this was measured on -- and it belongs with the
--     enemies.
-- `Caged Guest` goes with the guests for the same reason `Caged Prisoner` goes with the
-- enemies: the cage says where they are, not whose side they are on.
local function bucket(str)
    if not str then return nil end
    if str:find('^Wild Animal') then return 'wildlife' end
    if str:find('^Hostile') then return 'hostile' end
    if str:find('^Uninvited Guest') then return 'hostile' end
    if str:find('^Caged Prisoner') then return 'hostile' end
    if str:find('^Friendly') then return 'friendly' end
    if str:find('^Merchant') then return 'friendly' end
    if str:find('^Guest') then return 'friendly' end
    if str:find('^Caged Guest') then return 'friendly' end
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
    desc = 'Adds category and cage filter buttons to the units screen.',
    default_pos = {x = 50, y = -7},     -- where the Dead tab keeps its own button
    default_enabled = true,
    -- one string, because it is a prefix of every creature tab's focus including Residents,
    -- whose own focus string has no tail at all; `current_tab` sorts out which is which and
    -- draws nothing on the tabs this stays off
    viewscreens = 'dwarfmode/Info/CREATURES',
    -- WIDE ENOUGH TO CLEAR DFHACK'S OWN BUTTON. The three category buttons live in the first
    -- 31 columns and `Caged?` is pushed out to column 38 -- x 88 on screen -- because
    -- `logistics.autoretrain` sits at x 51..86 over rows 59..63 on the Pets/Livestock tab,
    -- which is exactly where this row is. The gap between Hostile and Caged? is that button.
    -- The columns in between draw nothing (no frame style, no background) and swallow no
    -- clicks: a Panel only consumes input a subview actually took.
    frame = {w = 47, h = 1},
    overlay_onupdate_max_freq_seconds = 0.1,
    version = 2,
}

function FilterOther:init()
    self.show = {friendly = false, wildlife = false, hostile = false}
    self.cage = CAGE_ANY
    self.has_caged = false     -- does the tab being looked at hold anything in a cage?
    self.hiding_tab = nil      -- the tab whose rows are currently being held out of the list

    local function toggle(id)
        return function()
            self.show[id] = not self.show[id]
            self:relabel()
            self:sweep()       -- act on the click, not a tenth of a second later
        end
    end

    self:addviews{
        -- the categories are the Other tab's own words; Residents and Pets have no Cat column
        widgets.TextButton{
            view_id = 'friendly', frame = {t = 0, l = 0, w = 10},
            label = 'Friendly', on_activate = toggle('friendly'),
            visible = function() return self:on_other() end,
        },
        widgets.TextButton{
            view_id = 'wildlife', frame = {t = 0, l = 11, w = 10},
            label = 'Wildlife', on_activate = toggle('wildlife'),
            visible = function() return self:on_other() end,
        },
        widgets.TextButton{
            view_id = 'hostile', frame = {t = 0, l = 22, w = 9},
            label = 'Hostile', on_activate = toggle('hostile'),
            visible = function() return self:on_other() end,
        },
        -- SHOWN ONLY WHERE THERE IS SOMETHING IN A CAGE, on every one of the three tabs, so
        -- the button means the same thing wherever it appears: this list has caged members
        -- in it. A tab with none never offers a filter that could only hide everything.
        widgets.TextButton{
            view_id = 'cage', frame = {t = 0, l = 38, w = 9},
            label = 'Caged? ',
            visible = function() return self.has_caged end,
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

function FilterOther:on_other()
    local t = current_tab()
    return t ~= nil and t.other
end

-- Is the cage filter doing anything? Only where the tab actually has something in a cage --
-- the state is KEPT when you step onto a tab that has none, so stepping back onto one that
-- does finds the filter as you left it, rather than silently reset.
function FilterOther:caging()
    return self.has_caged and self.cage ~= CAGE_ANY
end

-- is any button actually asking for something?
function FilterOther:filtering()
    return self:caging()
        or (self:on_other() and (self.show.friendly or self.show.wildlife or self.show.hostile))
end

function FilterOther:wanted(row)
    local cat = row_category(row)
    if self:caging() then
        local caged = is_caged(row_unit(row), cat)
        if self.cage == CAGE_NONE and caged then return false end
        if self.cage == CAGE_ONLY and not caged then return false end
    end
    if not self:on_other() then return true end   -- no Cat column to categorise by
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
    local tab = current_tab()
    -- LEAVING A TAB PUTS IT BACK. Rows are hidden per tab, and a tab stepped away from while
    -- it was filtered would keep its rows hidden with no button on screen to say so.
    if self.hiding_tab and (not tab or self.hiding_tab ~= tab.name) then
        local old = unit_list(self.hiding_tab)
        if old then for _, row in ipairs(rows_of(old)) do set_shown(row, true) end end
        self.hiding_tab = nil
    end
    if not tab then self.has_caged = false; return end
    local ul = unit_list(tab.name)
    -- no list means nothing can be said about this tab, and saying nothing means NO BUTTON --
    -- leaving the last tab's answer standing is how a filter that does nothing gets offered
    if not ul then self.has_caged = false; return end
    local rows = rows_of(ul)

    -- Whether to offer the cage button at all is a fact about THIS list, so it is answered
    -- from the same rows the filter runs over, once a pass. A row the filter is currently
    -- hiding still counts: otherwise turning `Caged!` on would empty the list, take the
    -- button away with it, and strand the filter on.
    local caged = false
    for _, row in ipairs(rows) do
        if is_caged(row_unit(row), row_category(row)) then caged = true; break end
    end
    self.has_caged = caged

    local filtering = self:filtering()
    if not filtering and not self.hiding_tab then return end
    for _, row in ipairs(rows) do
        set_shown(row, not filtering or self:wanted(row))
    end
    self.hiding_tab = filtering and tab.name or nil
end

function FilterOther:overlay_onupdate()
    self:sweep()
end

OVERLAY_WIDGETS = {filter = FilterOther}

if dfhack_flags and dfhack_flags.module then return end

print('filter-other-units: overlay registered.')
print('Open the Units screen\'s Other tab and use [Friendly] [Wildlife] [Hostile] [Caged?].')
