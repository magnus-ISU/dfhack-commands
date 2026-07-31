-- Expand the item-description box on the item view sheet to use the empty vertical space.
--@ module = true
--[[
item-description

DF's item view sheet (dwarfmode/ViewSheets/ITEM) renders an item's description in a short,
fixed ~8-row box. Long descriptions -- artifacts, finely-decorated items, figurines, books,
engraved slabs -- get truncated to a handful of lines while the rest of the panel sits
empty. This overlay redraws the full description in place, using up to HALF the screen
height before it needs to scroll, so you can read it without scrolling.

It is a standard DFHack overlay (name: "item-description.expand"): toggle or reposition it
with `gui/overlay` if it doesn't line up with your UI scale. magnus-scripts loads it (via
overlay rescan) so it's on every session.
]]

local overlay = require('plugins.overlay')

-- DF shows roughly this many rows in its own box; only step in past that, so short
-- descriptions (which DF already renders fully) are left untouched.
local DF_VISIBLE_ROWS = 8

ItemDescriptionOverlay = defclass(ItemDescriptionOverlay, overlay.OverlayWidget)
ItemDescriptionOverlay.ATTRS{
    desc = 'Expands a long item description to use the available vertical space.',
    default_pos = {x = -40, y = 11},
    viewscreens = 'dwarfmode/ViewSheets/ITEM',
    frame = {w = 57, h = 34},
}

-- the wrapped description lines DF computed for the current item, or nil if not applicable
local function desc_lines()
    local vs = df.global.game.main_interface.view_sheets
    if vs.active_sheet ~= df.view_sheet_type.ITEM then return nil, vs end
    return vs.description.text, vs
end

function ItemDescriptionOverlay:onRenderBody(dc)
    local lines, vs = desc_lines()
    if not lines then return end
    local total = #lines
    -- leave short descriptions to DF (it renders those fully already)
    if total <= DF_VISIBLE_ROWS then return end

    -- use up to half the screen height; scroll the rest with DF's own scroll position
    local maxrows = math.max(1, math.floor(df.global.gps.dimy / 2))
    local n = math.min(total, maxrows)
    local scroll = math.max(0, math.min(vs.scroll_position_item, total - n))

    -- size the frame to exactly the lines we draw, so nothing below them is occluded
    if self.frame.h ~= n then self.frame.h = n; self:updateLayout() end

    local w = self.frame.w
    local pen = {fg = COLOR_WHITE, bg = COLOR_BLACK}   -- opaque, to cover DF's short box
    for row = 0, n - 1 do
        local s = '  ' .. lines[scroll + row].value     -- DF indents the text two columns
        if #s < w then s = s .. (' '):rep(w - #s) else s = s:sub(1, w) end
        dc:seek(0, row):string(s, pen)
    end
end

OVERLAY_WIDGETS = {expand = ItemDescriptionOverlay}

-- running it directly just prints what it is (the overlay is registered via rescan)
if not dfhack_flags.module then
    print('item-description: overlay "item-description.expand" -- expands the item view-sheet')
    print('description to use up to half the screen height. Manage it with gui/overlay.')
end
