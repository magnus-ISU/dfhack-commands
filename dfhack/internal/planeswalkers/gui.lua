-- The planeswalkers save screen: take the fort, or take a party.
--@module = true
--[[
Two questions, in the order you actually ask them:

  1. EVERYTHING, or these travellers? Taking the fort is the original tool -- terrain,
     buildings, stockpiles, plants, the lot. Taking a party is a handful of dwarves and what
     they carry, which is a different wish and a much cheaper one: nothing about the
     destination map is touched, so the fort you arrive in survives intact.
  2. If travellers: WHICH ones, and what else goes with them.

WHAT COMES ANYWAY. A traveller's own gear is not a choice you have to make -- everything worn,
wielded or carried follows them, and a container follows with its contents. The item list is
for things that are NOT on anybody: the anvil in the stockpile, the barrel of ale, the
artifact on its pedestal.
]]

local gui = require('gui')
local widgets = require('gui.widgets')

local common = reqscript('internal/planeswalkers/common')

-- ---------------------------------------------------------------------------
-- what there is to choose from
-- ---------------------------------------------------------------------------

local function citizens()
    local out = {}
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        out[#out + 1] = {
            id = u.id,
            name = dfhack.units.getReadableName(u),
            prof = dfhack.units.getProfessionName(u) or '',
        }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Items nobody is carrying. A traveller's own gear comes with them automatically, so listing
-- it here would be asking a question whose answer is already yes -- and it is most of the
-- fort's item list, which would bury the things you might actually want to name.
local function loose_items()
    local out = {}
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        local f = it.flags
        if not (f.garbage_collect or f.removed or f.in_inventory or f.hostile or f.trader) then
            local ok, desc = pcall(dfhack.items.getReadableDescription, it)
            if ok and desc then
                out[#out + 1] = {id = it.id, name = desc, value = it:getValue()}
            end
        end
    end
    table.sort(out, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.id < b.id
    end)
    return out
end

-- ---------------------------------------------------------------------------
-- the screen
-- ---------------------------------------------------------------------------

SaveWindow = defclass(SaveWindow, widgets.Window)
SaveWindow.ATTRS{
    frame_title = 'Planeswalk: what comes with you?',
    frame = {w = 76, h = 34},
    resizable = true,
    on_save = DEFAULT_NIL,
}

function SaveWindow:init()
    self.chosen_units, self.chosen_items = {}, {}
    self.units, self.items = citizens(), loose_items()

    self:addviews{
        widgets.CycleHotkeyLabel{
            view_id = 'mode',
            frame = {t = 0, l = 0, w = 46},
            label = 'Take:',
            key = 'CUSTOM_SHIFT_M',
            options = {
                {label = 'these travellers and their gear', value = 'party'},
                {label = 'the whole fort (terrain and all)', value = 'fort'},
            },
            initial_option = 'party',
            on_change = function() self:refresh() end,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'tab',
            frame = {t = 1, l = 0, w = 46},
            label = 'Choosing:',
            key = 'CUSTOM_SHIFT_T',
            options = {
                {label = 'travellers', value = 'units'},
                {label = 'extra items (gear comes anyway)', value = 'items'},
            },
            initial_option = 'units',
            on_change = function() self:refresh() end,
        },
        widgets.EditField{
            view_id = 'search',
            frame = {t = 3, l = 0, r = 0},
            label_text = 'Search: ',
            on_change = function() self:refresh() end,
        },
        widgets.List{
            view_id = 'list',
            frame = {t = 5, l = 0, r = 0, b = 4},
            on_submit = function(_, ch) self:toggle(ch) end,
        },
        widgets.Label{
            view_id = 'summary',
            frame = {b = 2, l = 0, r = 0},
            text = '',
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 0},
            key = 'CUSTOM_SHIFT_A',
            label = 'all/none in this list',
            on_activate = function() self:toggle_all() end,
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 30},
            key = 'CUSTOM_SHIFT_S',
            label = 'save',
            on_activate = function() self:do_save() end,
        },
    }
    self:refresh()
end

function SaveWindow:party_mode()
    return self.subviews.mode:getOptionValue() == 'party'
end

function SaveWindow:rows()
    local which = self.subviews.tab:getOptionValue()
    return which == 'units' and self.units or self.items,
           which == 'units' and self.chosen_units or self.chosen_items
end

function SaveWindow:toggle(ch)
    if not ch or not ch.id then return end
    local _, chosen = self:rows()
    chosen[ch.id] = not chosen[ch.id] or nil
    self:refresh()
end

function SaveWindow:toggle_all()
    local rows, chosen = self:rows()
    local filter = (self.subviews.search.text or ''):lower()
    local any = false
    for _, r in ipairs(rows) do
        if filter == '' or r.name:lower():find(filter, 1, true) then
            if chosen[r.id] then any = true end
        end
    end
    for _, r in ipairs(rows) do
        if filter == '' or r.name:lower():find(filter, 1, true) then
            chosen[r.id] = (not any) or nil
        end
    end
    self:refresh()
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function SaveWindow:refresh()
    local party = self:party_mode()
    local rows, chosen = self:rows()
    local filter = (self.subviews.search.text or ''):lower()
    local choices = {}
    for _, r in ipairs(rows) do
        if filter == '' or r.name:lower():find(filter, 1, true) then
            local mark = chosen[r.id] and '[x] ' or '[ ] '
            local text = mark .. r.name
            if r.prof and r.prof ~= '' then text = text .. ', ' .. r.prof end
            choices[#choices + 1] = {text = text, id = r.id}
            if #choices >= 400 then break end
        end
    end
    if #choices == 0 then choices = {{text = '(nothing matches)'}} end
    self.subviews.list:setChoices(choices)

    -- the summary is the honest statement of what pressing save would do
    local nu, ni = count(self.chosen_units), count(self.chosen_items)
    local text
    if not party then
        text = {{text = 'The whole fort: terrain, buildings, stockpiles, plants, everyone.',
                 pen = COLOR_YELLOW}}
    elseif nu == 0 then
        text = {{text = 'Choose at least one traveller (Enter toggles a row).', pen = COLOR_LIGHTRED}}
    else
        text = {{text = ('%d traveller%s and their gear%s'):format(
                    nu, nu == 1 and '' or 's',
                    ni > 0 and (', plus %d named item%s'):format(ni, ni == 1 and '' or 's') or ''),
                 pen = COLOR_GREEN}}
    end
    self.subviews.summary:setText(text)
    self.subviews.list:updateLayout()
end

function SaveWindow:do_save()
    local party = self:party_mode()
    if party and count(self.chosen_units) == 0 then return end
    local units, items = {}, {}
    for id in pairs(self.chosen_units) do units[#units + 1] = id end
    for id in pairs(self.chosen_items) do items[#items + 1] = id end
    self.parent_view:dismiss()
    self.on_save(party and {units = units, items = items} or nil)
end

SaveScreen = defclass(SaveScreen, gui.ZScreenModal)
SaveScreen.ATTRS{focus_path = 'planeswalkers/save', on_save = DEFAULT_NIL}
function SaveScreen:init() self:addviews{SaveWindow{on_save = self.on_save}} end

function show(on_save)
    return SaveScreen{on_save = on_save}:show()
end
