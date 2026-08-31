-- Pick a work detail's icon from a grid of the actual icons.
--@module = true
--[[
fort/choose-labor-icon

DF gives a custom work detail one of nineteen icons, and the only way to change
it is the little cycler on the Labor screen: click, look, click again, all the
way round. This shows every icon at once, drawn as DF draws it, and sets the one
you click.

    LEFT   your work details, each with its current icon's name
    RIGHT  every icon, 4x3 tiles each, the current one framed

Click a detail, click an icon, done -- the change is written straight to
`work_detail.icon`.

DF DOES NOT REDRAW ITS OWN LIST
  Measured on a live fort: setting `work_detail.icon` updates the data and the
  Labor screen keeps drawing the sprite it drew before. Every visible row was
  checked against its stored value -- seven matched, and the only ones that did
  not were the ones changed from outside DF. The list is built with the icon
  baked in, and nothing tried so far makes DF rebuild it: bouncing
  `info.cur_idx` to another tab and back, toggling `info.open`, setting and
  clearing `labor.search_string`, and feeding clicks at the Work Details /
  Standing orders sub-tabs all left the stale sprite in place. The widget that
  owns the row is a `shared_ptr` child that DFHack's lua binding will not
  dereference, so the cached texpos cannot be written directly either.

  So the change IS applied -- the data is correct, and a save and reload shows
  the right icon -- but the Labor screen may keep showing the old one for the
  rest of the session. This window's own list always shows the stored truth.

    fort/choose-labor-icon

THE CUSTOM SLOTS
  Ten icons are borrowed from the default labors (miners, woodcutters, ...) and
  `CUSTOM_1` through `CUSTOM_8` are vanilla's roman numerals I..VIII -- which is
  why fort/labor-groups borrows recognizable built-in icons instead of using
  them, and why several groups end up sharing one. A graphics mod can rebind
  those eight to real art (they are the identifiers `WORK_DETAIL_CUSTOM_1..8`),
  and this picker draws whatever is bound: OVERRIDE_PAGES lists tile pages to
  check before vanilla's, so a mod page with the vanilla layout shows through
  here as it does in the game.

ASCII
  `findGraphicsTile` returns nothing without a graphics tileset, so in ASCII the
  grid falls back to a plain list of icon names. Same clicks, same result.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

-- Tile pages checked before vanilla's for the CUSTOM_1..8 slots, in order. A
-- work-detail-icon mod that keeps vanilla's layout (same coordinates, its own
-- page) is picked up by adding its page name here. INTERFACE_BITS_LABOR_WD is
-- the Steam Workshop "Work Detail Icons" mod.
OVERRIDE_PAGES = {'INTERFACE_BITS_LABOR_WD'}
local VANILLA_PAGE = 'INTERFACE_BITS_LABOR'

local ICON_W, ICON_H = 4, 3          -- every icon is a 4x3 tile rectangle
-- one tile of border on every side, so the marker for the current icon can be a
-- box drawn AROUND it. The old marker was an underline along the icon's bottom
-- row, which painted over the bottom of the art it was pointing at.
local CELL_W, CELL_H = ICON_W + 2, ICON_H + 2
local COLS = 5
local TEXT_CELL_W = 20               -- name-only rows when the sprites do not resolve

-- name -> where the icon sits on INTERFACE_BITS_LABOR, read from vanilla's
-- graphics_interface.txt. Order follows work_detail_icon_type, so the grid runs
-- in the same order as DF's own cycler.
local ICONS = {
    {name = 'NONE'},
    {name = 'MINERS',          x = 20, y = 0},
    {name = 'WOODCUTTERS',     x = 24, y = 0},
    {name = 'HUNTERS',         x = 28, y = 0},
    {name = 'PLANTERS',        x = 20, y = 6},
    {name = 'FISHERMEN',       x = 24, y = 6},
    {name = 'STONECUTTERS',    x = 32, y = 0},
    {name = 'ENGRAVERS',       x = 36, y = 0},
    {name = 'PLANT_GATHERERS', x = 40, y = 0},
    {name = 'HAULERS',         x = 44, y = 0},
    {name = 'ORDERLIES',       x = 48, y = 0},
    {name = 'CUSTOM_1',        x = 20, y = 3, custom = true},
    {name = 'CUSTOM_2',        x = 24, y = 3, custom = true},
    {name = 'CUSTOM_3',        x = 28, y = 3, custom = true},
    {name = 'CUSTOM_4',        x = 32, y = 3, custom = true},
    {name = 'CUSTOM_5',        x = 36, y = 3, custom = true},
    {name = 'CUSTOM_6',        x = 40, y = 3, custom = true},
    {name = 'CUSTOM_7',        x = 44, y = 3, custom = true},
    {name = 'CUSTOM_8',        x = 48, y = 3, custom = true},
    {name = 'SIEGE_OPERATORS', x = 12, y = 6},
}

local function icon_value(entry)
    if entry.name == 'NONE' then return -1 end
    return df.work_detail_icon_type[entry.name]
end

-- texpos for one tile of an icon, or nil in ASCII / when the page is missing.
-- Only the CUSTOM slots consult the override pages: a mod page is a full-size
-- sheet, so asking it for a built-in icon's coordinates would draw whatever
-- happens to sit there rather than the built-in icon.
local function tile_at(entry, dx, dy)
    if not entry.x then return end
    if entry.custom then
        for _, page in ipairs(OVERRIDE_PAGES) do
            local t = dfhack.screen.findGraphicsTile(page, entry.x + dx, entry.y + dy)
            if t then return t end
        end
    end
    return dfhack.screen.findGraphicsTile(VANILLA_PAGE, entry.x + dx, entry.y + dy)
end

local function graphics_available()
    return tile_at(ICONS[2], 0, 0) ~= nil
end

local function work_details()
    return df.global.plotinfo.labor_info.work_details
end

local function icon_name(value)
    return df.work_detail_icon_type[value] or 'NONE'
end

-- ---------------------------------------------------------------------------
-- the icon grid
-- ---------------------------------------------------------------------------

IconGrid = defclass(IconGrid, widgets.Panel)
IconGrid.ATTRS{
    on_select = DEFAULT_NIL,     -- function(icon_value)
    get_current = DEFAULT_NIL,   -- function() -> icon_value
}

local PEN_BLANK = dfhack.pen.parse{fg = COLOR_WHITE, bg = COLOR_BLACK}
local CH_NW, CH_NE, CH_SW, CH_SE = string.char(218), string.char(191),
                                   string.char(192), string.char(217)
local CH_H, CH_V = string.char(196), string.char(179)
local PEN_FRAME = dfhack.pen.parse{fg = COLOR_LIGHTGREEN, bg = COLOR_BLACK}
local PEN_NAME = dfhack.pen.parse{fg = COLOR_GREY, bg = COLOR_BLACK}
local PEN_NAME_CUR = dfhack.pen.parse{fg = COLOR_LIGHTGREEN, bg = COLOR_BLACK}

-- Cell geometry, which depends on whether the sprites resolve. With graphics we
-- lay the icons out as a grid of their own 4x3 blocks; without them there is
-- nothing to look at, so cells become full-width rows carrying the icon's name.
-- Both paths must agree, so hit-testing and painting share this.
function IconGrid:geom()
    if graphics_available() then
        return CELL_W, CELL_H, COLS, true
    end
    return TEXT_CELL_W, 1, 1, false
end

function IconGrid:cell_rect(idx, cw, ch, cols)
    local col, row = (idx - 1) % cols, (idx - 1) // cols
    return col * cw, row * ch
end

-- which icon is under (x, y), in view-local coordinates
function IconGrid:hit(x, y)
    if x < 0 or y < 0 then return end
    local cw, ch, cols, gfx = self:geom()
    local col, row = x // cw, y // ch
    if col >= cols then return end
    -- the whole cell is clickable, border included: a one-tile target ring
    -- around a 4x3 icon is easier to hit than the icon alone
    local idx = row * cols + col + 1
    if ICONS[idx] then return idx end
end

-- a box around the icon, in the gutter, touching none of the art
function IconGrid:draw_border(dc, ox, oy)
    local x2, y2 = ox + ICON_W + 1, oy + ICON_H + 1
    dc:pen(PEN_FRAME)
    dc:seek(ox, oy):char(CH_NW)
    dc:seek(x2, oy):char(CH_NE)
    dc:seek(ox, y2):char(CH_SW)
    dc:seek(x2, y2):char(CH_SE)
    for dx = 1, ICON_W do
        dc:seek(ox + dx, oy):char(CH_H)
        dc:seek(ox + dx, y2):char(CH_H)
    end
    for dy = 1, ICON_H do
        dc:seek(ox, oy + dy):char(CH_V)
        dc:seek(x2, oy + dy):char(CH_V)
    end
end

function IconGrid:onRenderBody(dc)
    local cur = self.get_current and self.get_current()
    local cw, ch, cols, gfx = self:geom()
    for idx, entry in ipairs(ICONS) do
        local ox, oy = self:cell_rect(idx, cw, ch, cols)
        local is_cur = cur == icon_value(entry)
        if gfx and entry.x then
            for dy = 0, ICON_H - 1 do
                for dx = 0, ICON_W - 1 do
                    local t = tile_at(entry, dx, dy)
                    if t then
                        dc:seek(ox + 1 + dx, oy + 1 + dy):tile(' ', t, PEN_BLANK)
                    end
                end
            end
            if is_cur then self:draw_border(dc, ox, oy) end
        else
            local label = entry.name == 'NONE' and '(none)' or entry.name:lower()
            dc:seek(ox, oy):pen(is_cur and PEN_NAME_CUR or PEN_NAME)
                :string((is_cur and '> ' or '  ') .. label)
        end
    end
end

function IconGrid:onInput(keys)
    if not keys._MOUSE_L then return false end
    local x, y = self:getMousePos()
    if not x then return false end
    local idx = self:hit(x, y)
    if not idx then return false end
    if self.on_select then self.on_select(icon_value(ICONS[idx]), ICONS[idx].name) end
    return true
end

-- ---------------------------------------------------------------------------
-- window
-- ---------------------------------------------------------------------------

ChooseIcon = defclass(ChooseIcon, widgets.Window)
ChooseIcon.ATTRS{
    frame_title = 'Work detail icons',
    frame = {w = 68, h = 30},
    resizable = true,
    start_idx = DEFAULT_NIL,   -- work detail to open on, 0-based
}

function ChooseIcon:init()
    self:addviews{
        widgets.List{
            view_id = 'details',
            frame = {l = 0, t = 0, w = 28, b = 3},
            on_select = function() self:show_status() end,
        },
        widgets.Label{
            frame = {l = 30, t = 0},
            text = 'Click an icon:',
        },
        IconGrid{
            view_id = 'grid',
            -- Sized explicitly rather than stretched to r/b. The grid needs
            -- exactly COLS x CELL_W by rows x CELL_H, and letting the layout
            -- decide left it a tile short in each direction, which clipped the
            -- right edge and bottom of the last row and column of icons.
            frame = {l = 30, t = 2,
                     w = COLS * CELL_W,
                     h = math.ceil(#ICONS / COLS) * CELL_H},
            get_current = function()
                local d = self:selected_detail()
                return d and d.icon
            end,
            on_select = function(value, name) self:set_icon(value, name) end,
        },
        widgets.Label{
            view_id = 'status',
            frame = {l = 0, b = 1},
            text = '',
        },
    }
    self:refresh()
    if self.start_idx then
        -- rows are built in work_details order, so the list index is the detail
        -- index plus one; jump the cursor there rather than making the player
        -- find the detail they were already looking at
        self.subviews.details:setSelected(self.start_idx + 1)
        self:show_status()
    end
end

function ChooseIcon:selected_detail()
    local list = self.subviews.details
    local _, choice = list:getSelected()
    return choice and work_details()[choice.idx]
end

function ChooseIcon:show_status()
    local d = self:selected_detail()
    self.subviews.status:setText(d and ('%s: %s'):format(d.name, icon_name(d.icon)) or
        'no work details in this fort')
end

-- Rebuilds the rows (their labels carry the icon name, so a change has to be
-- redrawn), keeping the cursor where it was.
function ChooseIcon:refresh()
    local list = self.subviews.details
    local sel = list:getSelected() or 1
    local choices = {}
    for i, d in ipairs(work_details()) do
        choices[#choices + 1] = {
            text = ('%-18s %s'):format(d.name:sub(1, 18), icon_name(d.icon):lower()),
            idx = i,
        }
    end
    list:setChoices(choices, sel)
    self:show_status()
end

function ChooseIcon:set_icon(value, name)
    local d = self:selected_detail()
    if not d then return end
    d.icon = value
    self:refresh()
    self.subviews.status:setText(('%s: %s'):format(d.name, name))
end

-- DF's own labor list caches the icon it drew for each row and does not re-read
-- work_detail.icon afterwards, so a change made here does not show up over
-- there until DF rebuilds that list -- see the header. This window at least
-- never lies about the current state: the rows are rebuilt every frame, so the
-- name beside each detail is always what is actually stored.
function ChooseIcon:onRenderFrame(dc, rect)
    ChooseIcon.super.onRenderFrame(self, dc, rect)
    local sig = {}
    for i, d in ipairs(work_details()) do
        sig[#sig + 1] = i .. ':' .. tostring(d.icon)
    end
    sig = table.concat(sig, ',')
    if sig ~= self.last_sig then
        self.last_sig = sig
        self:refresh()
    end
end

ChooseIconScreen = defclass(ChooseIconScreen, gui.ZScreen)
ChooseIconScreen.ATTRS{
    focus_path = 'choose-labor-icon',
    start_idx = DEFAULT_NIL,
    pass_movement_keys = true,
}
function ChooseIconScreen:init()
    self:addviews{ChooseIcon{start_idx = self.start_idx}}
end
function ChooseIconScreen:onDismiss() view = nil end


-- ---------------------------------------------------------------------------
-- [Change Icon] button on the work detail screen
-- ---------------------------------------------------------------------------
--
-- DF draws the selected detail's own icon and the configure gear as two 4x3
-- sprites on the work detail header row; this sits immediately right of them.
--
-- Which detail is selected cannot be read from the game state on this build:
-- main_interface.info.labor is a widget whose children are shared_ptrs that
-- DFHack's lua binding cannot dereference, and df-structures has mapped only
-- the generic widget fields on labor_work_details_interfacest -- no selection
-- index exists to read. So the name DF prints on that header row is read off
-- the screen instead and matched against plotinfo.labor_info.work_details.
-- Renaming two details to the same string makes the first one win; nothing
-- worse happens.
local HEADER_ROW = 11        -- 0-based screen row DF draws the header on
local NAME_START = 39        -- where the detail name begins on that row

local function read_row_text(y, x1, x2)
    local chars = {}
    for x = x1, x2 do
        local ok, pen = pcall(dfhack.screen.readTile, x, y)
        local ch = (ok and pen and pen.ch) or 0
        chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return (table.concat(chars):gsub('%s+$', ''):gsub('^%s+', ''))
end

-- index (0-based) of the work detail whose name DF is showing, or nil
function selected_detail_idx()
    local name = read_row_text(HEADER_ROW, NAME_START, NAME_START + 40)
    if #name == 0 then return end
    for i, d in ipairs(work_details()) do
        if d.name == name then return i end
    end
end

ChangeIconOverlay = defclass(ChangeIconOverlay, overlay.OverlayWidget)
ChangeIconOverlay.ATTRS{
    desc = 'Adds a [Change Icon] button to the work detail screen.',
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/LABOR/WORK_DETAILS',
    default_pos = {x = 90, y = 12},
    frame = {w = 13, h = 1},
}

local PEN_BUTTON = dfhack.pen.parse{fg = COLOR_LIGHTCYAN, bg = COLOR_BLACK}

function ChangeIconOverlay:onRenderBody(dc)
    dc:seek(0, 0):pen(PEN_BUTTON):string('[Change Icon]')
end

function ChangeIconOverlay:onInput(keys)
    if not keys._MOUSE_L then return false end
    if not self:getMousePos() then return false end
    if #work_details() == 0 then return false end
    if view then view:raise() else
        view = ChooseIconScreen{start_idx = selected_detail_idx()}:show()
    end
    return true
end

OVERLAY_WIDGETS = {button = ChangeIconOverlay}

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('fort/choose-labor-icon only works in fortress mode')
end
if #work_details() == 0 then
    qerror('this fort has no work details yet')
end

view = view and view:raise()
    or ChooseIconScreen{start_idx = selected_detail_idx()}:show()
