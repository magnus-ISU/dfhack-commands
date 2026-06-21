-- Show a statue's description (and value) on its building info sheet.
--@module = true
--[[
When a statue is selected, this renders a fuller description of the statue --
quality, what it depicts, any decorations, and its value -- in a wrapping block
on the statue's info sheet, so you don't have to open the item's own sheet.

NOTE: DF's full multi-sentence prose description is not exposed by DFHack, so the
text here is assembled from quality + getDescription + improvements + value.

Registered automatically as overlay `statue-description.desc`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local DWARF_BUCK = string.char(15)   -- the in-game value symbol

local function cap(s)
    return (s:gsub('^%l', string.upper))
end

local function selected_statue_item()
    local b = dfhack.gui.getSelectedBuilding(true)
    if not b or b:getType() ~= df.building_type.Statue then return end
    for i = 0, #b.contained_items - 1 do
        local it = b.contained_items[i].item
        if it:getType() == df.item_type.STATUE then return it end
    end
end

-- DF's exact prose description lives in view_sheets.raw_description, which DF
-- populates for the statue while its info sheet is showing (same text as the
-- item sheet). We just read it -- no assembling/approximating.
local function statue_description()
    local it = selected_statue_item()
    if not it then return end
    local prose = df.global.game.main_interface.view_sheets.raw_description
    if not prose or #prose == 0 then return end
    prose = prose:gsub('%s+$', '')        -- trim trailing spaces
    return ('%s\nValue: %d%s'):format(prose, dfhack.items.getValue(it), DWARF_BUCK)
end

StatueDescOverlay = defclass(StatueDescOverlay, overlay.OverlayWidget)
StatueDescOverlay.ATTRS{
    desc = "Shows a statue's description and value on its info sheet.",
    default_pos = {x = 8, y = 11},          -- ~100px right/down from the corner
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/BUILDING/Statue',
    frame = {w = 78, h = 12},               -- 3x wider
    version = 3,
    overlay_onupdate_max_freq_seconds = 0,  -- update every cycle (less stale-text lag)
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
    local d = statue_description()
    self.visible = d ~= nil
    if d and d ~= self.subviews.desc.text_to_wrap then
        self.subviews.desc.text_to_wrap = d
        self:updateLayout()
    end
end

OVERLAY_WIDGETS = {desc = StatueDescOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('statue-description: registered overlay statue-description.desc')
