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
local dialogs = require('gui.dialogs')

local common = reqscript('internal/planeswalkers/common')

-- ---------------------------------------------------------------------------
-- what there is to choose from
-- ---------------------------------------------------------------------------

-- module-level so they can be exercised without opening the screen: a list builder that
-- throws takes the whole window with it, which is exactly what happened first time out
function citizens()
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
function loose_items()
    local out = {}
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        local f = it.flags
        if not (f.garbage_collect or f.removed or f.in_inventory or f.hostile or f.trader) then
            -- getValue is a MODULE function, not a method: `item:getValue()` exists on some
            -- item classes and not others (item_shieldst has none), so calling it that way
            -- died on the first shield in the fort.
            local ok, desc = pcall(dfhack.items.getReadableDescription, it)
            local okv, value = pcall(dfhack.items.getValue, it)
            if ok and desc then
                out[#out + 1] = {id = it.id, name = desc, value = okv and value or 0}
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
    -- the item list costs a fifth of a second to build (33k readable descriptions on this
    -- fort) and most of the time you only came to pick dwarves, so it waits until asked for
    self.units, self.items = citizens(), nil

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
    if which ~= 'units' and not self.items then self.items = loose_items() end
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
    -- NO updateLayout HERE. refresh() runs from init(), before the window has been given a
    -- parent rect, and laying out against a rect that does not exist yet is what killed the
    -- screen on open ("attempt to index a nil value (local 'parent_rect')"). setChoices does
    -- the work that actually matters; the frame is computed when the screen shows itself.
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


-- ---------------------------------------------------------------------------
-- snapshot browser: inspect a completed snapshot before starting a destructive load
-- ---------------------------------------------------------------------------
SnapshotWindow = defclass(SnapshotWindow, widgets.Window)
SnapshotWindow.ATTRS{
    frame_title = 'Planeswalkers - Snapshot Browser',
    frame = {w = 82, h = 34},
    resizable = true,
    on_load = DEFAULT_NIL,
}

function SnapshotWindow:init()
    self.snapshots = common.list_snapshots()
    table.sort(self.snapshots, function(a, b)
        return (a.manifest.created or '') > (b.manifest.created or '')
    end)
    self.selected = nil
    self:addviews{
        widgets.EditField{
            view_id = 'search', frame = {t = 0, l = 0, w = 42},
            label_text = 'Search: ',
            on_change = function() self:refresh_list() end,
        },
        widgets.List{
            view_id = 'snapshots', frame = {t = 2, l = 0, w = 43, b = 4},
            choices = {},
            on_select = function(_, choice) self:select_snapshot(choice) end,
            on_submit = function(_, choice) self:load_snapshot(choice) end,
        },
        widgets.Label{view_id = 'details', frame = {t = 0, l = 45, r = 0, h = 23}, text =
            'Select a snapshot to inspect its origin, dimensions, contents, and format.'},
        widgets.HotkeyLabel{frame = {b = 1, l = 0}, key = 'CUSTOM_SHIFT_L', label = 'load selected',
            on_activate = function() self:load_snapshot() end},
        widgets.HotkeyLabel{frame = {b = 1, l = 23}, key = 'CUSTOM_SHIFT_D', label = 'delete selected',
            on_activate = function() self:delete_snapshot() end},
        widgets.HotkeyLabel{frame = {b = 1, l = 48}, key = 'LEAVESCREEN', label = 'close',
            on_activate = function() self.parent_view:dismiss() end},
    }
    self:refresh_list()
    if #self.snapshots > 0 then
        self:select_snapshot({id = 1})
    end
end

function SnapshotWindow:refresh_list()
    local filter = (self.subviews.search.text or ''):lower()
    local choices = {}
    for i, snap in ipairs(self.snapshots) do
        local m = snap.manifest or {}
        local d = m.dims or {}
        local haystack = table.concat({snap.name, m.world or '', m.fort_display or m.fort or '',
            m.civilization and m.civilization.name or ''}, ' '):lower()
        if filter == '' or haystack:find(filter, 1, true) then
            choices[#choices + 1] = {
                text = ('%s  [%dx%d]  %s'):format(snap.name, d.bx or 0, d.by or 0,
                    m.world or 'unknown world'),
                id = i,
            }
        end
    end
    if #choices == 0 then choices[1] = {text = '(no matching complete snapshots)', id = -1} end
    self.subviews.snapshots:setChoices(choices)
    if self.selected then
        local found = false
        for _, choice in ipairs(choices) do
            if choice.id == self.selected then found = true break end
        end
        if not found then
            self.selected = nil
            self.subviews.details:setText('Select a snapshot to inspect its origin, dimensions, contents, and format.')
        end
    end
end

function SnapshotWindow:select_snapshot(choice)
    local idx = choice and choice.id or nil
    if not idx or idx < 1 then self.selected = nil; return end
    self.selected = idx
    local snap = self.snapshots[idx]
    local m = snap.manifest or {}
    local d, c = m.dims or {}, m.counts or {}
    local lines = {
        snap.name,
        '',
        'Origin world: ' .. tostring(m.world or 'unknown'),
        'Origin fortress: ' .. tostring(m.fort_display or m.fort or 'unknown'),
        'Civilization: ' .. tostring(m.civilization and m.civilization.name or 'unknown'),
        'Created: ' .. tostring(m.created or 'unknown'),
        'DF version: ' .. tostring(m.df_version or 'unknown'),
        'Snapshot format: v' .. tostring(m.format_version or '?'),
        ('Dimensions: %s x %s blocks; %s z-levels'):format(d.bx or '?', d.by or '?', d.bz or '?'),
        '', 'CONTENTS',
        ('Terrain blocks: %s'):format(c.terrain_blocks or 'recorded in binary data'),
        ('Magma blocks: %s'):format(c.magma_blocks or 0),
        ('Buildings: %s'):format(c.buildings or 0),
        ('Units: %s'):format(c.units or 0),
        ('Items: %s'):format(c.items or 0),
        ('Corpses: %s'):format(c.corpses or 0),
        ('Plants: %s'):format(c.plants or 0),
        ('Artifacts: %s'):format(c.artifacts or 0),
        '',
        (m.complete and m.complete.terrain and 'Integrity marker: complete' or 'Integrity marker: INCOMPLETE'),
        'Restore replaces the corresponding destination footprint.',
    }
    self.subviews.details:setText(table.concat(lines, '\n'))
end

function SnapshotWindow:delete_snapshot()
    if not self.selected then return end
    local snap = self.snapshots[self.selected]
    if not snap then return end
    dialogs.showYesNoPrompt('Delete snapshot?',
        ('Permanently delete "%s" and any pending/replacement data?'):format(snap.name),
        COLOR_LIGHTRED,
        function()
            local base = common.snap_dir(snap.name)
            for _, path in ipairs({base, base .. '.pending', base .. '.replaced', base .. '.publish_failed'}) do
                local ok, err = common.remove_tree(path)
                if not ok then
                    dfhack.printerr(('planeswalkers: could not delete %s: %s'):format(path, tostring(err)))
                    return
                end
            end
            self.snapshots = common.list_snapshots()
            table.sort(self.snapshots, function(a, b)
                return (a.manifest.created or '') > (b.manifest.created or '')
            end)
            self.selected = nil
            self:refresh_list()
            self.subviews.details:setText('Snapshot deleted. Select another snapshot to inspect it.')
        end)
end

function SnapshotWindow:load_snapshot(choice)
    if choice then self:select_snapshot(choice) end
    if not self.selected then return end
    local snap = self.snapshots[self.selected]
    self.parent_view:dismiss()
    self.on_load(snap.name)
end

SnapshotScreen = defclass(SnapshotScreen, gui.ZScreenModal)
SnapshotScreen.ATTRS{focus_path = 'planeswalkers/snapshots', on_load = DEFAULT_NIL}
function SnapshotScreen:init()
    self:addviews{SnapshotWindow{on_load = self.on_load}}
end

function show_browser(on_load)
    return SnapshotScreen{on_load = on_load}:show()
end
