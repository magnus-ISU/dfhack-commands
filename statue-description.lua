-- Show a statue's exact description (and value) on its building info sheet.
--@module = true
--[[
When a statue is selected, this renders DF's exact prose description of the
statue, plus its value, in a wrapping block on the statue's info sheet.

How it works: DF only generates the full prose into view_sheets.raw_description
while an *item's* sheet is showing. So the first time you select a given statue,
this briefly flips the view to the contained statue item (so DF regenerates the
text), reads it, caches it, and flips back to the statue. Results are cached by
item id, so each statue is only fetched once -- no flicker on repeat views and no
infinite loop.

Registered automatically as overlay `statue-description.desc`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local DWARF_BUCK = string.char(15)   -- in-game value symbol

local cache = {}          -- item_id -> description text
local fetching = false
local fetch_item, fetch_bld

local function vsheets()
    return df.global.game.main_interface.view_sheets
end

-- runs the frame after start_fetch; we cleared raw_description, so as soon as it
-- is non-empty again DF has regenerated it for our item -> flip back immediately
local function finish_fetch(tries)
    local vs = vsheets()
    -- bail if the player navigated away while we were fetching
    if vs.active_sheet ~= df.view_sheet_type.ITEM or vs.active_id ~= fetch_item then
        fetching = false
        return
    end
    local prose = vs.raw_description
    if prose and #prose > 0 then
        cache[fetch_item] = prose:gsub('%s+$', '')
    elseif tries < 8 then
        dfhack.timeout(1, 'frames', function() finish_fetch(tries + 1) end)
        return
    end
    -- flip back to the statue's building sheet
    vs.active_sheet = df.view_sheet_type.BUILDING
    vs.active_id = fetch_bld
    vs.viewing_itid:resize(0)
    fetching = false
end

-- briefly switch the view to the statue item so DF regenerates its description
local function start_fetch(item_id, bld_id)
    local vs = vsheets()
    fetching = true
    fetch_item, fetch_bld = item_id, bld_id
    vs.raw_description = ''       -- clear so a non-empty value means "regenerated"
    vs.active_sheet = df.view_sheet_type.ITEM
    vs.active_id = item_id
    vs.viewing_itid:resize(0)
    vs.viewing_itid:insert('#', item_id)
    dfhack.timeout(1, 'frames', function() finish_fetch(0) end)
end

local function selected_statue_item()
    local b = dfhack.gui.getSelectedBuilding(true)
    if not b or b:getType() ~= df.building_type.Statue then return end
    for i = 0, #b.contained_items - 1 do
        local it = b.contained_items[i].item
        if it:getType() == df.item_type.STATUE then return it, b end
    end
end

StatueDescOverlay = defclass(StatueDescOverlay, overlay.OverlayWidget)
StatueDescOverlay.ATTRS{
    desc = "Shows a statue's exact description and value on its info sheet.",
    default_pos = {x = 8, y = 11},
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/BUILDING/Statue',
    frame = {w = 78, h = 12},
    version = 4,
    overlay_onupdate_max_freq_seconds = 0,
}

function StatueDescOverlay:init()
    self:addviews{
        widgets.Panel{
            frame_style = gui.FRAME_THIN,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.WrappedLabel{
                    view_id = 'desc',
                    frame = {t = 0, l = 0, r = 0},
                    text_to_wrap = '',
                    text_pen = COLOR_YELLOW,
                },
            },
        },
    }
end

function StatueDescOverlay:overlay_onupdate()
    local it = selected_statue_item()
    if not it then self.visible = false; return end
    local desc = cache[it.id]
    if desc then
        local full = ('%s\nValue: %d%s'):format(desc, dfhack.items.getValue(it), DWARF_BUCK)
        self.visible = true
        if full ~= self.subviews.desc.text_to_wrap then
            self.subviews.desc.text_to_wrap = full
            self:updateLayout()
        end
    else
        self.visible = false
        if not fetching then
            local _, b = selected_statue_item()
            start_fetch(it.id, b.id)
        end
    end
end

OVERLAY_WIDGETS = {desc = StatueDescOverlay}

dfhack.onStateChange['statue-description'] = function(ev)
    if ev == SC_MAP_UNLOADED then cache = {}; fetching = false end
end

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('statue-description: registered overlay statue-description.desc')
