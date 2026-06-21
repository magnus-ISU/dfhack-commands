-- Show the selected creature's description in a scrollable panel, bottom-left.
--@module = true
--[[
When a creature is selected (its unit sheet is open), this shows the creature's
description -- `caste.description` -- in a wrapping, scrollable block in the
bottom-left. Most useful for forgotten beasts / titans / generated creatures,
whose description is their full generated flavor (body, materials, special
attacks). For ordinary creatures it's the species blurb.

Registered automatically as overlay `creature-description.desc`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local function creature_description()
    local u = dfhack.gui.getSelectedUnit(true)
    if not u then return end
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    if caste and caste.description and #caste.description > 0 then
        return caste.description
    end
end

CreatureDescOverlay = defclass(CreatureDescOverlay, overlay.OverlayWidget)
CreatureDescOverlay.ATTRS{
    desc = "Shows the selected creature's description in the bottom-left.",
    default_pos = {x = 3, y = -3},   -- bottom-left
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/UNIT',
    frame = {w = 78, h = 12},   -- same size as the old statue display
    version = 1,
    overlay_onupdate_max_freq_seconds = 0,
}

function CreatureDescOverlay:init()
    self:addviews{
        widgets.Panel{
            frame_style = gui.FRAME_THIN,
            frame_background = gui.CLEAR_PEN,
            subviews = {
                widgets.WrappedLabel{
                    view_id = 'desc',
                    frame = {t = 0, l = 0, r = 0, b = 0},
                    text_to_wrap = '',
                    text_pen = COLOR_YELLOW,
                },
            },
        },
    }
end

function CreatureDescOverlay:overlay_onupdate()
    local d = creature_description()
    self.visible = d ~= nil
    if d and d ~= self.subviews.desc.text_to_wrap then
        self.subviews.desc.text_to_wrap = d
        self:updateLayout()
    end
end

OVERLAY_WIDGETS = {desc = CreatureDescOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('creature-description: registered overlay creature-description.desc')
