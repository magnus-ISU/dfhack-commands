-- Search window for the Settings > Announcements page, with clickable toggles.
--@module = true
--[[
The announcements settings page lists ~356 announcement types with no way to find
one. This adds a [dfhack search] button to that page; clicking it opens a
full-height search window: type to filter the announcement types (matches the
display name and the raw enum token; empty search lists everything), and click a
row's Popup / Pause / Recen / Adv / Fort / Rep / RepAA / Alert cells to toggle
the same `d_init.announcements.flags` bits the native page edits. Up/Down/PgUp/
PgDn scroll. Esc closes.

Why a separate window: the native list is a v50 widget_container whose child list
sits behind an opaque shared_ptr, and its `search_string` field is not wired up --
the native list cannot be filtered from outside. A ZScreen window also gets real
keyboard/mouse focus, which a passive overlay panel does not.

Registered automatically as overlay `announcement-search.search` (the button).
Reposition the button with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

-- column layout: name, then one cell per flag
local NAME_W = 34
local COLS = {
    {label = 'Popup', flag = 'DO_MEGA'},
    {label = 'Pause', flag = 'PAUSE'},
    {label = 'Recen', flag = 'RECENTER'},
    {label = 'Adv',   flag = 'A_DISPLAY'},
    {label = 'Fort',  flag = 'D_DISPLAY'},
    {label = 'Rep',   flag = 'UNIT_COMBAT_REPORT'},
    {label = 'RepAA', flag = 'UNIT_COMBAT_REPORT_ALL_ACTIVE'},
    {label = 'Alert', flag = 'ALERT'},
}
local COL_W = 6
local GRID_W = NAME_W + #COLS * COL_W

-- "BIRTH_CITIZEN" -> "Birth citizen"
local function prettify(key)
    local s = key:lower():gsub('_', ' ')
    return (s:gsub('^%l', string.upper))
end

-- all announcement types once: {idx=, name=, lower=}
local catalog
local function get_catalog()
    if catalog then return catalog end
    catalog = {}
    for i = 0, 1000 do
        local key = df.announcement_type[i]
        if not key then break end
        key = tostring(key)
        local name = prettify(key)
        catalog[#catalog + 1] = {idx = i, name = name,
            lower = name:lower() .. ' ' .. key:lower()}
    end
    return catalog
end

-- empty needle lists the whole catalog (the window is full-height and scrollable)
local function matches(needle)
    needle = (needle or ''):lower()
    if #needle == 0 then return get_catalog() end
    local out = {}
    for _, e in ipairs(get_catalog()) do
        if e.lower:find(needle, 1, true) then out[#out + 1] = e end
    end
    return out
end

-- ---- the results grid (custom rendering + per-cell clicks + scrolling) --------

ResultsGrid = defclass(ResultsGrid, widgets.Widget)
ResultsGrid.ATTRS{}

function ResultsGrid:init()
    self.rows = {}
    self.top = 0        -- scroll offset into self.rows
end

function ResultsGrid:set_rows(rows)
    self.rows = rows
    self.top = 0
end

function ResultsGrid:page_size()
    return math.max(1, (self.frame_body and self.frame_body.height or 20) - 1)
end

function ResultsGrid:scroll(delta)
    local max_top = math.max(0, #self.rows - self:page_size())
    self.top = math.max(0, math.min(max_top, self.top + delta))
end

function ResultsGrid:onRenderBody(dc)
    local page = self:page_size()
    dc:seek(0, 0):pen(COLOR_GREY):string(('%-' .. NAME_W .. 's'):format(
        (#self.rows > page) and ('Name (%d-%d of %d)'):format(
            self.top + 1, math.min(self.top + page, #self.rows), #self.rows)
        or 'Name'))
    for c, col in ipairs(COLS) do
        dc:seek(NAME_W + (c - 1) * COL_W, 0):pen(COLOR_GREY)
            :string(('%-' .. COL_W .. 's'):format(col.label))
    end
    local flags = df.global.d_init.announcements.flags
    for r = 1, page do
        local e = self.rows[self.top + r]
        if not e then break end
        local f = flags[e.idx]
        dc:seek(0, r):pen(COLOR_WHITE):string(e.name:sub(1, NAME_W - 1))
        for c, col in ipairs(COLS) do
            local on = f[col.flag]
            dc:seek(NAME_W + (c - 1) * COL_W, r)
                :pen(on and COLOR_LIGHTGREEN or COLOR_DARKGREY)
                :string(on and 'Yes' or 'No')
        end
    end
end

-- toggle the cell under grid-relative pos; true if a cell was hit. Called from the
-- WINDOW's onInput, BEFORE the focused EditField gets the click -- the focus owner
-- receives input first and its text area can swallow mouse clicks, which is why
-- handling clicks down here on the grid itself never fired.
function ResultsGrid:click(pos)
    local e = pos.y >= 1 and self.rows[self.top + pos.y]
    if not e then return false end
    local c = (pos.x - NAME_W) // COL_W + 1
    if pos.x < NAME_W or not COLS[c] then return false end
    local f = df.global.d_init.announcements.flags[e.idx]
    f[COLS[c].flag] = not f[COLS[c].flag]
    return true
end

-- scroll keys, also dispatched from the window level
function ResultsGrid:handle_keys(keys)
    if keys.STANDARDSCROLL_UP or keys.KEYBOARD_CURSOR_UP then self:scroll(-1) return true end
    if keys.STANDARDSCROLL_DOWN or keys.KEYBOARD_CURSOR_DOWN then self:scroll(1) return true end
    if keys.STANDARDSCROLL_PAGEUP or keys.KEYBOARD_CURSOR_UP_FAST then self:scroll(-self:page_size()) return true end
    if keys.STANDARDSCROLL_PAGEDOWN or keys.KEYBOARD_CURSOR_DOWN_FAST then self:scroll(self:page_size()) return true end
    if keys.CONTEXT_SCROLL_UP then self:scroll(-3) return true end
    if keys.CONTEXT_SCROLL_DOWN then self:scroll(3) return true end
    return false
end

-- ---- the window ----------------------------------------------------------------

SearchWindow = defclass(SearchWindow, widgets.Window)
SearchWindow.ATTRS{
    frame_title = 'Announcement settings search',
    -- full vertical space; fixed width for the grid
    frame = {w = GRID_W + 3, t = 0, b = 0, l = 4},
    resizable = false,
}

function SearchWindow:init()
    self:addviews{
        widgets.EditField{
            view_id = 'search',
            frame = {t = 0, l = 0, r = 0, h = 1},
            label_text = 'search: ',
            on_change = function(text)
                self.subviews.grid:set_rows(matches(text))
            end,
        },
        ResultsGrid{
            view_id = 'grid',
            frame = {t = 2, l = 0, r = 0, b = 0},
        },
    }
end

-- intercept grid clicks + scrolling BEFORE the standard dispatch: the focused
-- EditField is the focus owner and receives input first, eating mouse clicks
function SearchWindow:onInput(keys)
    local grid = self.subviews.grid
    if keys._MOUSE_L then
        local pos = grid:getMousePos()
        if pos and grid:click(pos) then return true end
    end
    if grid:handle_keys(keys) then return true end
    return SearchWindow.super.onInput(self, keys)
end

SearchScreen = defclass(SearchScreen, gui.ZScreen)
SearchScreen.ATTRS{focus_path = 'announcement-search'}

function SearchScreen:init()
    self:addviews{SearchWindow{}}
    -- open ready to type, with the full list showing
    self.subviews.grid:set_rows(matches(''))
    self.subviews.search:setFocus(true)
end

view = view or nil
function SearchScreen:onDismiss() view = nil end

-- ---- the overlay button ----------------------------------------------------------

AnnouncementSearchOverlay = defclass(AnnouncementSearchOverlay, overlay.OverlayWidget)
AnnouncementSearchOverlay.ATTRS{
    desc = 'Adds a [dfhack search] button to the announcement settings page.',
    default_pos = {x = 6, y = 32},
    default_enabled = true,
    viewscreens = 'dwarfmode/Settings/ANNOUNCEMENTS',
    frame = {w = 15, h = 1},
    version = 2,   -- v2: panel replaced by a button that opens a full-height window
}

function AnnouncementSearchOverlay:init()
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 15},
            label = '[dfhack search]',
            on_activate = function()
                if not view then view = SearchScreen{}:show() end
            end,
        },
    }
end

OVERLAY_WIDGETS = {search = AnnouncementSearchOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('announcement-search: registered overlay announcement-search.search (button opens the window)')
