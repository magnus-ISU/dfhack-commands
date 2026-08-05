-- Overlay button for the Squads screen.
--@module = true
--[[
On the Squads screen (focus dwarfmode/Squads/Default) this adds one button that
shows only the action it will take -- "Select all squads" while any squad is
unselected, "Select no squads" once every squad is selected. No hotkey; click it.

(The old "Target all invaders" / "Target all hostiles" kill-order buttons were
removed -- dwarf-rts's drag-box attack handles group targeting now, so there's no
need to fill the kill-target list from here.)

It sits three rows below the map's "Elevation N" readout, centered on it.

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
    -- Parked under the map's "Elevation N" readout: three rows below it, and centered on
    -- it. Measured on the Squads screen, where this overlay lives -- the readout sits at
    -- row 16 (1-based 17) spanning columns 174-185 of a 192-wide grid, so its centre is
    -- 179.5 and the button (19 columns) takes 170-188. y is 1-based from the top, like the
    -- readout, which hangs off the top-right panel; x is negative so the frame's RIGHT edge
    -- anchors to the right screen edge (dimx + x), keeping the two aligned at any width.
    default_pos = {x = -4, y = 20},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    -- exactly the width of the rendered button, "[Select all squads]" -- the frame used to
    -- carry two spare columns, which would throw the centring off by one
    frame = {w = 19, h = 1},
    version = 8,   -- bumped: moved under the Elevation readout (resets saved positions)
    overlay_onupdate_max_freq_seconds = 0,
}

function KillTargetsOverlay:init()
    -- two visibility-swapped buttons so the label always names exactly the action
    -- a click will perform; no hotkey
    self:addviews{
        widgets.TextButton{
            view_id = 'select_all',
            frame = {t = 0, l = 0, w = 19, h = 1},
            label = 'Select all squads',
            on_activate = function() self:set_all(true) end,
        },
        widgets.TextButton{
            view_id = 'select_none',
            -- l=1: one column narrower than [Select all squads], so both buttons share
            -- the same RIGHT edge
            frame = {t = 0, l = 1, w = 18, h = 1},
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
