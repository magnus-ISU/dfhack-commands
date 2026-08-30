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
`work_detail.icon` and shows on the Labor screen immediately.

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
local widgets = require('gui.widgets')

-- Tile pages checked before vanilla's for the CUSTOM_1..8 slots, in order. A
-- work-detail-icon mod that keeps vanilla's layout (same coordinates, its own
-- page) is picked up by adding its page name here. INTERFACE_BITS_LABOR_WD is
-- the Steam Workshop "Work Detail Icons" mod.
OVERRIDE_PAGES = {'INTERFACE_BITS_LABOR_WD'}
local VANILLA_PAGE = 'INTERFACE_BITS_LABOR'

local ICON_W, ICON_H = 4, 3          -- every icon is a 4x3 tile rectangle
local CELL_W, CELL_H = 5, 4          -- plus a one-tile gutter
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
    if gfx and (x % cw >= ICON_W or y % ch >= ICON_H) then return end   -- gutter
    local idx = row * cols + col + 1
    if ICONS[idx] then return idx end
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
                        dc:seek(ox + dx, oy + dy):tile(' ', t, PEN_BLANK)
                    end
                end
            end
            if is_cur then
                for dx = 0, ICON_W - 1 do
                    dc:seek(ox + dx, oy + ICON_H - 1):pen(PEN_FRAME):char('_')
                end
            end
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
    frame = {w = 62, h = 24},
    resizable = true,
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
            frame = {l = 30, t = 2, r = 0, b = 3},
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

ChooseIconScreen = defclass(ChooseIconScreen, gui.ZScreen)
ChooseIconScreen.ATTRS{focus_path = 'choose-labor-icon'}
function ChooseIconScreen:init() self:addviews{ChooseIcon{}} end
function ChooseIconScreen:onDismiss() view = nil end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('fort/choose-labor-icon only works in fortress mode')
end
if #work_details() == 0 then
    qerror('this fort has no work details yet')
end

view = view and view:raise() or ChooseIconScreen{}:show()
