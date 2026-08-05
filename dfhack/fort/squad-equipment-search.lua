-- Adds a search bar to the squad-equipment "specific item" list (the screen where you pick an
-- exact item to assign to a uniform slot -- often hundreds or thousands of entries).
--@module = true
--[[
squad-equipment-search

When customizing a squad's uniform and choosing a SPECIFIC item for a slot
(dwarfmode/Squads/Equipment/Customizing, with the specific-item list open), the game shows every
matching item in the fort -- easily 1000+ rows. This overlay drops a Search field on that list
(Alt-S to focus) that filters it live by the item's description, exactly like DFHack's built-in
list searches. Clearing the search restores the full list.

Built on DFHack's reusable sort/sortoverlay machinery: it saves the game's item-id list, filters
it in place by description, and restores it when you leave the screen. Auto-discovered by
`overlay rescan` (magnus-scripts runs it); no enable needed.
]]

local sortoverlay = require('plugins.sort.sortoverlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local function squad_equipment()
    return df.global.game.main_interface.squad_equipment
end

-- Find the "Select Item." label on the specific-item picker by reading the screen, and return the
-- SCREEN (col, row) where our search bar should sit: 2 columns to the right of that text (a trailing
-- '.' is folded into the label when drawn). Returns nil if the text isn't on screen yet so the
-- caller can retry next frame. Mirrors butcher-shop's dynamic [Butcher]-button placement.
local SELECT_ITEM = 'Select Item'
local function select_item_pos()
    local sw, sh = dfhack.screen.getWindowSize()
    for y = 0, sh - 1 do
        local chars = {}
        for x = 0, sw - 1 do
            local ok, pen = pcall(dfhack.screen.readTile, x, y)
            local ch = (ok and pen and pen.ch) or 0
            chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local line = table.concat(chars)
        local c = line:find(SELECT_ITEM, 1, true)
        if c then
            local len = #SELECT_ITEM
            if line:sub(c + len, c + len) == '.' then len = len + 1 end   -- include the trailing period
            return (c - 1) + len + 2, y                                    -- 0-based col, 2-column gap
        end
    end
end

-- the searchable text for one entry: the specific item's readable description ("steel breastplate")
local function get_item_search_key(item_id)
    local it = df.item.find(item_id)
    if not it then return '' end
    local ok, desc = pcall(dfhack.items.getReadableDescription, it)
    return ok and desc or ''
end

SquadEquipmentSearchOverlay = defclass(SquadEquipmentSearchOverlay, sortoverlay.SortOverlay)
SquadEquipmentSearchOverlay.ATTRS{
    desc = 'Adds a search bar to the squad-equipment "specific item" list.',
    default_pos = {x = 23, y = 23},   -- fallback until it snaps 2 cols right of the "Select Item." label
    viewscreens = 'dwarfmode/Squads/Equipment/Customizing',
    frame = {w = 34, h = 1},
    version = 2,                        -- bumped: now dynamically positioned (resets any saved pos)
}

function SquadEquipmentSearchOverlay:init()
    local panel = widgets.Panel{visible = self:callback('get_key')}
    panel:addviews{
        widgets.BannerPanel{
            frame = {l = 0, t = 0, r = 0, h = 1},
            subviews = {
                widgets.EditField{
                    view_id = 'search',
                    frame = {l = 1, t = 0, r = 1},
                    label_text = 'Search: ',
                    key = 'CUSTOM_ALT_S',
                    on_change = function(text) self:do_search(text) end,
                },
            },
        },
    }
    self:addviews{panel}

    -- filter the game's specific-item id list (cs_add_spec_id) in place by item description.
    -- pass the vector as a thunk so we always act on the live one even if the game re-populates it.
    self:register_handler('SPEC',
        function() return squad_equipment().cs_add_spec_id end,
        function(vec, data, text, incremental)
            sortoverlay.single_vector_search({get_search_key_fn = get_item_search_key}, vec, data, text, incremental)
        end)
end

-- active only while the specific-item picker is open (so the bar hides for the rest of the
-- customize screen, and the base class resets/restores the list when you leave it)
--
-- DROPPING THE SNAPSHOT ON CLOSE IS NOT OPTIONAL. sortoverlay's single_vector_search caches the
-- list the first time it filters (data.saved_original) and, on any later NON-incremental search,
-- writes that cache straight back into the game's live vector:
--     elseif not incremental then vec:assign(data.saved_original); vec:resize(...)
-- Re-opening a picker is exactly such a search (onRenderBody sees cur_key go nil -> 'SPEC' and
-- calls do_search(text, true), force_full_search). DF rebuilds cs_add_spec_id per SLOT, so the
-- cache belongs to whichever slot was picked LAST -- open the body-armor slot, then the helm slot,
-- and the helm picker gets stamped with body armour. That was the "assigning a helmet shows the
-- armor list" bug.
--
-- The base class's own cleanup can never save us here: do_cleanup only runs on a cur_group change
-- (we return no group, so cur_group is permanently nil) or on scope exit -- and the focus string
-- stays dwarfmode/Squads/Equipment/Customizing/Default whether the picker is open or shut, so
-- opening and closing pickers never leaves the scope. Clearing state.SPEC ourselves is the guard;
-- DFHack's own SlabOverlay:get_key does the same thing for the same reason.
--
-- Clearing the WHOLE state.SPEC (not just saved_original) also drops prev_text, so a new picker
-- opens with an empty search box instead of inheriting the previous slot's query.
function SquadEquipmentSearchOverlay:get_key()
    if squad_equipment().cs_adding_specific_item then
        return 'SPEC'
    end
    if self.state and self.state.SPEC then
        self.state.SPEC = nil
    end
end

-- snap the search bar 2 columns right of the "Select Item." label (frame coords are relative to the
-- interface rect, so convert the screen position by the interface origin). False until it's drawn.
function SquadEquipmentSearchOverlay:reposition()
    local col, row = select_item_pos()
    if not col then return false end
    local ir = gui.get_interface_rect()
    self.frame = {w = self.frame.w, h = self.frame.h, l = col - ir.x1, t = row - ir.y1}
    self:updateLayout(gui.ViewRect{rect = ir})
    return true
end

-- Reposition once each time the specific-item picker opens (its label can sit at a different spot
-- depending on window / panel layout). The open/closed check is cheap every frame; the screen scrape
-- + reposition runs only on open. Chains to the SortOverlay base (scope reset / list save-restore).
function SquadEquipmentSearchOverlay:overlay_onupdate()
    SquadEquipmentSearchOverlay.super.overlay_onupdate(self)
    if not self:get_key() then self.placed = nil; return end
    if not self.placed and self:reposition() then self.placed = true end
end

OVERLAY_WIDGETS = {search = SquadEquipmentSearchOverlay}

if dfhack_flags and dfhack_flags.module then return end

print('squad-equipment-search: overlay registered.')
print('Open a squad uniform slot\'s "specific item" list and press Alt-S to search it by description.')
