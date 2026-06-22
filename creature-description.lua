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

-- total kills: named victims (events) + anonymous kills (killed_count, which
-- already includes undead-group kills). killed_undead is a parallel per-group
-- flag, NOT a count, so it must not be added.
local function kill_count(u)
    local hf = u.hist_figure_id and u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
    if not (hf and hf.info and hf.info.kills) then return 0 end
    local k = hf.info.kills
    local total = #k.events
    for i = 0, #k.killed_count - 1 do total = total + k.killed_count[i] end
    return total
end

-- description + kills line for the selected creature, or nil
local function unit_info()
    local u = dfhack.gui.getSelectedUnit(true)
    if not u then return end
    local cr = df.global.world.raws.creatures.all[u.race]
    local caste = cr and cr.caste[u.caste]
    if not (caste and caste.description and #caste.description > 0) then return end
    return ('%s\nKills: %d'):format(caste.description, kill_count(u))
end

-- how many display rows the text needs after word-wrapping to `width`
local function wrapped_lines(text, width)
    local n = 0
    for para in (text .. '\n'):gmatch('(.-)\n') do
        local len
        for word in para:gmatch('%S+') do
            local wl = #word
            if not len then len = wl
            elseif len + 1 + wl <= width then len = len + 1 + wl
            else n = n + 1; len = wl end
        end
        n = n + 1
    end
    return n
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
    local text = unit_info()
    self.visible = text ~= nil
    if not text then return end
    local changed = false
    if text ~= self.subviews.desc.text_to_wrap then
        self.subviews.desc.text_to_wrap = text
        changed = true
    end
    -- grow the box to fit the wrapped text (incl. the Kills line), so nothing is
    -- cut off; cap so it stays on screen
    local _, sh = dfhack.screen.getWindowSize()
    local h = math.max(4, math.min(wrapped_lines(text, self.frame.w - 2) + 2, sh - 6))
    if self.frame.h ~= h then self.frame.h = h; changed = true end
    if changed then self:updateLayout() end
end

OVERLAY_WIDGETS = {desc = CreatureDescOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('creature-description: registered overlay creature-description.desc')
