-- Melt-focused, searchable/filterable stocks menu (+ a toolbar button).
--@module = true
--[[
A searchable list of meltable stock items, for quickly marking gear to melt
(or forbid / dump), filtering out your own usable equipment so foreign/exotic
loot is easy to find.

    dfhack-stocks            open the menu

Or click the "DFHack stocks" button the overlay adds near the vanilla Stocks
button on the bottom toolbar.

Menu:
  * Search field is focused on open; the most recent artifact is shown first.
  * Foreign filter:  all / foreign-only / local-only        (item.flags.foreign)
  * Exotic filter:   all / only-exotic / not-exotic         (gear the fort can't
                     equip -- subtype not in the civ's weapon/armor lists)
  * Action:          melt / forbid / dump / focus
      - Enter/click a row applies the action; Shift+click applies to a range.
      - melt/forbid/dump toggle the item's flag; focus opens the item's sheet.
  * The selected item's full description + value show at the bottom.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

-- ---- item model -----------------------------------------------------------

-- usable-equipment sets for the fort civ, keyed by item_type -> {subtype=true}
local function usable_sets()
    local ent
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.group_id then ent = e; break end
    end
    if not ent then return {} end
    local r = ent.resources
    local function setof(vec) local s = {}; for _, v in ipairs(vec) do s[v] = true end; return s end
    return {
        [df.item_type.WEAPON] = setof(r.weapon_type),
        [df.item_type.ARMOR]  = setof(r.armor_type),
        [df.item_type.HELM]   = setof(r.helm_type),
        [df.item_type.SHIELD] = setof(r.shield_type),
        [df.item_type.PANTS]  = setof(r.pants_type),
        [df.item_type.GLOVES] = setof(r.gloves_type),
        [df.item_type.SHOES]  = setof(r.shoes_type),
    }
end

-- equipment the fort can't normally use (foreign/exotic loot)
local function is_exotic(item, usable)
    local set = usable[item:getType()]
    if not set then return false end          -- not equipment -> not exotic
    return not set[item:getSubtype()]
end

-- one-letter status flags for the row, e.g. "M.D" (melt, dump)
local function flag_tag(item)
    local f = item.flags
    return ('%s%s%s'):format(f.melt and 'M' or '.', f.forbid and 'F' or '.', f.dump and 'D' or '.')
end

-- focus the game's item sheet on this item (mirrors statue-redirect)
local function focus_item(item)
    local vs = df.global.game.main_interface.view_sheets
    vs.active_sheet = df.view_sheet_type.ITEM
    vs.active_id = item.id
    vs.viewing_itid:insert('#', item.id)
    vs.open = true
end

-- ---- window ---------------------------------------------------------------

StocksWindow = defclass(StocksWindow, widgets.Window)
StocksWindow.ATTRS{
    frame_title = 'DFHack stocks (melt)',
    frame = {w = 80, h = 40},
    resizable = true,
    resize_min = {w = 60, h = 25},
}

function StocksWindow:init()
    self.usable = usable_sets()
    self.prev_idx = nil

    self:addviews{
        widgets.EditField{
            view_id = 'search',
            frame = {t = 0, l = 0, r = 0},
            label_text = 'Search: ',
        },
        widgets.CycleHotkeyLabel{
            view_id = 'foreign',
            frame = {t = 2, l = 0, w = 22},
            label = 'Origin:',
            key = 'CUSTOM_SHIFT_F',
            options = {
                {label = 'all', value = 'all', pen = COLOR_GRAY},
                {label = 'foreign', value = 'foreign', pen = COLOR_YELLOW},
                {label = 'local', value = 'local', pen = COLOR_GREEN},
            },
            on_change = function() self:refresh() end,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'exotic',
            frame = {t = 2, l = 24, w = 26},
            label = 'Exotic:',
            key = 'CUSTOM_SHIFT_X',
            options = {
                {label = 'all', value = 'all', pen = COLOR_GRAY},
                {label = 'only', value = 'only', pen = COLOR_YELLOW},
                {label = 'not', value = 'not', pen = COLOR_GREEN},
            },
            on_change = function() self:refresh() end,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'action',
            frame = {t = 2, r = 0, w = 20},
            label = 'Action:',
            key = 'CUSTOM_SHIFT_A',
            options = {
                {label = 'melt', value = 'melt', pen = COLOR_LIGHTRED},
                {label = 'forbid', value = 'forbid', pen = COLOR_YELLOW},
                {label = 'dump', value = 'dump', pen = COLOR_LIGHTMAGENTA},
                {label = 'focus', value = 'focus', pen = COLOR_LIGHTCYAN},
            },
        },
        widgets.Label{
            frame = {t = 4, l = 0},
            text = {{text = 'M=melt F=forbid D=dump   Enter/click: apply   Shift+click: range',
                     pen = COLOR_GRAY}},
        },
        widgets.FilteredList{
            view_id = 'list',
            frame = {t = 6, l = 0, r = 0, b = 7},
            on_submit = self:callback('apply_one'),
            on_submit2 = self:callback('apply_range'),
            on_select = self:callback('on_select'),
        },
        widgets.Panel{
            frame = {b = 0, l = 0, r = 0, h = 6},
            frame_style = gui.FRAME_THIN,
            subviews = {
                widgets.WrappedLabel{
                    view_id = 'desc',
                    frame = {t = 0, l = 0, r = 0, b = 0},
                    text_to_wrap = 'Select an item to see its description.',
                },
            },
        },
    }

    -- use our search field as the list's text filter (replace its built-in edit)
    self.subviews.list.edit.visible = false
    self.subviews.list.edit = self.subviews.search
    self.subviews.search.on_change = self.subviews.list:callback('onFilterChange')

    self:build_choices()
    self:refresh()
end

function StocksWindow:build_choices()
    local choices = {}
    for _, item in ipairs(df.global.world.items.all) do
        if dfhack.items.canMelt(item) and not item.flags.garbage_collect then
            local desc = dfhack.items.getDescription(item, 0, false)
            choices[#choices + 1] = {
                item = item,
                desc = desc,
                foreign = item.flags.foreign,
                exotic = is_exotic(item, self.usable),
                search_key = dfhack.toSearchNormalized(desc),
            }
        end
    end
    -- most-recent artifact first feel: keep insertion order (newest items last in
    -- world.items.all), so reverse so newest are on top
    local rev = {}
    for i = #choices, 1, -1 do rev[#rev + 1] = choices[i] end
    self.all_choices = rev
end

function StocksWindow:make_text(c)
    return {
        {text = flag_tag(c.item), pen = COLOR_LIGHTRED, width = 3},
        {gap = 1, text = c.exotic and 'X' or ' ', pen = COLOR_YELLOW, width = 1},
        {gap = 1, text = c.foreign and 'f' or ' ', pen = COLOR_LIGHTBLUE, width = 1},
        {gap = 1, text = c.desc},
    }
end

function StocksWindow:refresh()
    local ff = self.subviews.foreign:getOptionValue()
    local xf = self.subviews.exotic:getOptionValue()
    local list = {}
    for _, c in ipairs(self.all_choices or {}) do
        if ff == 'foreign' and not c.foreign then goto cont end
        if ff == 'local' and c.foreign then goto cont end
        if xf == 'only' and not c.exotic then goto cont end
        if xf == 'not' and c.exotic then goto cont end
        list[#list + 1] = {text = self:make_text(c), search_key = c.search_key, item = c.item, data = c}
        ::cont::
    end
    local saved = self.subviews.list:getFilter()
    self.subviews.list:setFilter('')
    self.subviews.list:setChoices(list)
    self.subviews.list:setFilter(saved)
end

function StocksWindow:on_select(idx, choice)
    if not choice then return end
    local item = choice.item
    local ok, readable = pcall(dfhack.items.getReadableDescription, item)
    local val = dfhack.items.getValue(item)
    self.subviews.desc:setText((ok and readable or choice.data.desc) ..
        ('\nvalue: %d%s%s'):format(val,
            choice.data.foreign and '  [foreign]' or '',
            choice.data.exotic and '  [exotic]' or ''))
end

function StocksWindow:do_action(item)
    local act = self.subviews.action:getOptionValue()
    if act == 'focus' then
        focus_item(item)
        if view then view:dismiss() end   -- close so the sheet is visible
    elseif act == 'melt' then
        if item.flags.melt then dfhack.items.cancelMelting(item)
        elseif dfhack.items.canMelt(item) then dfhack.items.markForMelting(item) end
    elseif act == 'forbid' then
        item.flags.forbid = not item.flags.forbid
    elseif act == 'dump' then
        item.flags.dump = not item.flags.dump
    end
end

function StocksWindow:apply_one(idx, choice)
    if choice then self:do_action(choice.item) end
    self.prev_idx = self.subviews.list.list:getSelected()
end

function StocksWindow:apply_range(idx, choice)
    local cur = self.subviews.list.list:getSelected()
    if not self.prev_idx or self:get_action() == 'focus' then
        self:apply_one(idx, choice)
        return
    end
    local choices = self.subviews.list:getVisibleChoices()
    local a, b = self.prev_idx, cur
    for i = math.min(a, b), math.max(a, b) do
        if choices[i] then self:do_action(choices[i].item) end
    end
    self.prev_idx = cur
end

function StocksWindow:get_action()
    return self.subviews.action:getOptionValue()
end

-- ---- screen ---------------------------------------------------------------

view = view or nil

StocksScreen = defclass(StocksScreen, gui.ZScreen)
StocksScreen.ATTRS{
    focus_path = 'dfhack-stocks',
}

function StocksScreen:init()
    self:addviews{StocksWindow{}}
end

function StocksScreen:onDismiss()
    view = nil
end

local function show()
    view = view and view:raise() or StocksScreen{}:show()
    return view
end

-- ---- toolbar overlay button -----------------------------------------------

StocksButton = defclass(StocksButton, overlay.OverlayWidget)
StocksButton.ATTRS{
    desc = 'Adds a button to open the DFHack melt-focused stocks menu.',
    default_pos = {x = -33, y = -5},
    default_enabled = true,
    viewscreens = 'dwarfmode/Default',
    frame = {w = 16, h = 1},
}

function StocksButton:init()
    self:addviews{
        widgets.TextButton{
            frame = {t = 0, l = 0, w = 16, h = 1},
            label = 'DFHack stocks',
            on_activate = show,
        },
    }
end

OVERLAY_WIDGETS = {button = StocksButton}

if dfhack_flags.module then
    return
end

if not dfhack.world.isFortressMode() then
    qerror('dfhack-stocks only works in fortress mode')
end
show()
