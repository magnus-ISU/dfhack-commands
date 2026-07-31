-- Overlay button for the Squads screen.
--@module = true
--[[
On the Squads screen (focus dwarfmode/Squads/Default) this adds one button that
shows only the action it will take -- "Select all squads" while any squad is
unselected, "Select no squads" once every squad is selected. No hotkey; click it.

(The old "Target all invaders" / "Target all hostiles" kill-order buttons were
removed -- dwarf-rts's drag-box attack handles group targeting now, so there's no
need to fill the kill-target list from here.)

Registered automatically as overlay `squad-buttons.killtargets`.
Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local function squads_panel()
    return df.global.game.main_interface.squads
end

-- every squad currently selected?
local function all_selected()
    local sq = squads_panel()
    for i = 0, #sq.squad_id - 1 do
        if not sq.squad_selected[i] then return false end
    end
    return #sq.squad_id > 0
end

KillTargetsOverlay = defclass(KillTargetsOverlay, overlay.OverlayWidget)
KillTargetsOverlay.ATTRS{
    desc = 'Squads screen button: select all / no squads (label shows the action it will take).',
    default_pos = {x = -29, y = -1},   -- bottom-right (negative = from right/bottom edge)
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 21, h = 1},
    version = 7,   -- bumped: whole widget moved 7 columns further left
    overlay_onupdate_max_freq_seconds = 0,
}

function KillTargetsOverlay:init()
    -- two visibility-swapped buttons so the label always names exactly the action
    -- a click will perform; no hotkey
    self:addviews{
        widgets.TextButton{
            view_id = 'select_all',
            frame = {t = 0, l = 0, w = 21, h = 1},
            label = 'Select all squads',
            on_activate = function() self:set_all(true) end,
        },
        widgets.TextButton{
            view_id = 'select_none',
            -- l=1: one column narrower than [Select all squads], so both buttons share
            -- the same RIGHT edge
            frame = {t = 0, l = 1, w = 20, h = 1},
            label = 'Select no squads',
            on_activate = function() self:set_all(false) end,
            visible = false,
        },
    }
end

function KillTargetsOverlay:set_all(want)
    local sq = squads_panel()
    for i = 0, #sq.squad_id - 1 do sq.squad_selected[i] = want end
end

function KillTargetsOverlay:overlay_onupdate()
    local open = squads_panel().open
    self.visible = open
    if not open then return end
    local all = all_selected()
    self.subviews.select_all.visible = not all
    self.subviews.select_none.visible = all
end

OVERLAY_WIDGETS = {killtargets = KillTargetsOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('squad-buttons: registered overlay squad-buttons.killtargets')
