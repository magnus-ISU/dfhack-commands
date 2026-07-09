-- Overlay button for the Squads screen.
--@module = true
--[[
On the Squads screen (focus dwarfmode/Squads/Default) this adds one button:

    * Select all/no squads  -- toggles selection of every squad

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

KillTargetsOverlay = defclass(KillTargetsOverlay, overlay.OverlayWidget)
KillTargetsOverlay.ATTRS{
    desc = 'Squads screen button: select all / no squads.',
    default_pos = {x = -31, y = -1},   -- bottom-right (negative = from right/bottom edge)
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 30, h = 1},
    version = 5,   -- bumped: kill-target buttons removed, widget shrank to one row
    overlay_onupdate_max_freq_seconds = 0,
}

function KillTargetsOverlay:init()
    self:addviews{
        widgets.TextButton{
            view_id = 'selectall',
            frame = {t = 0, l = 0, w = 30, h = 1},
            label = 'Select all/no squads',
            key = 'CUSTOM_CTRL_S',
            on_activate = function() self:toggle_select_all() end,
        },
    }
end

-- if not every squad is selected, select them all; otherwise clear the selection
function KillTargetsOverlay:toggle_select_all()
    local sq = squads_panel()
    local n = #sq.squad_id
    local selected = 0
    for i = 0, n - 1 do if sq.squad_selected[i] then selected = selected + 1 end end
    local want = selected < n
    for i = 0, n - 1 do sq.squad_selected[i] = want end
end

function KillTargetsOverlay:overlay_onupdate()
    self.visible = squads_panel().open
end

OVERLAY_WIDGETS = {killtargets = KillTargetsOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('squad-buttons: registered overlay squad-buttons.killtargets')
