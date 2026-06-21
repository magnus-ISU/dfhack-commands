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

-- named victims + anonymous kills + undead kills
local function kill_count(u)
    local hf = u.hist_figure_id and u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
    if not (hf and hf.info and hf.info.kills) then return 0 end
    local k = hf.info.kills
    local total = #k.events
    for i = 0, #k.killed_count - 1 do total = total + k.killed_count[i] end
    if k.killed_undead then total = total + #k.killed_undead end
    return total
end

-- returns: text (description + kills line), is_dwarf
local function unit_info()
    local u = dfhack.gui.getSelectedUnit(true)
    if not u then return end
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    if not (caste and caste.description and #caste.description > 0) then return end
    local text = ('%s\nKills: %d'):format(caste.description, kill_count(u))
    return text, cr.creature_id == 'DWARF'
end

CreatureDescOverlay = defclass(CreatureDescOverlay, overlay.OverlayWidget)
CreatureDescOverlay.ATTRS{
    desc = "Shows the selected creature's description in the bottom-left.",
    default_pos = {x = 3, y = -4},   -- bottom-left
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/UNIT',
    frame = {w = 90, h = 12},
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
    local text, is_dwarf = unit_info()
    self.visible = text ~= nil
    if not text then return end
    local changed = false
    local h = is_dwarf and 4 or 12   -- dwarves get a short box
    if self.frame.h ~= h then self.frame.h = h; changed = true end
    if text ~= self.subviews.desc.text_to_wrap then
        self.subviews.desc.text_to_wrap = text
        changed = true
    end
    if changed then self:updateLayout() end
end

OVERLAY_WIDGETS = {desc = CreatureDescOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('creature-description: registered overlay creature-description.desc')
