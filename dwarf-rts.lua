-- RTS-style squad controls for the Dwarf Fortress squad UI.
--@module = true
--[[
dwarf-rts -- make the squad screen behave like an RTS.

Planned behaviours (see README "dwarf-rts" spec for the full design):
  1. Opening the Squads screen auto-selects every squad and arms movement mode.
  2. Left-clicking the map in movement mode issues the move and re-arms movement
     mode (so you can chain destinations).
  3. Left-clicking an enemy unit in movement mode switches to attack mode and
     targets it; holding Shift appends to the existing kill list instead.
  4. Clicking a squad leader's portrait (or a unit's camera icon) makes the
     camera follow that unit.

Only behaviour #1 is implemented so far. The squad UI state lives in
`df.global.game.main_interface.squads`: the mode flags `giving_move_order` /
`giving_kill_order` / `giving_patrol_order` / `giving_burrow_order`, the
`squad_selected[]` vector (parallel to `squad_id[]`), and `kill_unid[]` for kill
targets. Camera follow is `df.global.plotinfo.follow_unit`.

Registered automatically as overlay `dwarf-rts.autoselect`.
]]

local overlay = require('plugins.overlay')

local REOPEN_GAP_MS = 500   -- a longer gap in our update clock => screen was closed

local function squads_ui() return df.global.game.main_interface.squads end

-- behaviour #1: select every squad and arm movement mode
function select_all_and_move()
    local sq = squads_ui()
    if not sq.open then return end
    for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = true end
    if #sq.squad_id > 0 then sq.giving_move_order = true end
end

-- The overlay only updates while the Squads screen is focused, so we can't watch
-- an open/closed transition directly; instead we treat a long gap in our own
-- update clock as "the screen was closed and just reopened" and re-arm then.
DwarfRtsAutoSelect = defclass(DwarfRtsAutoSelect, overlay.OverlayWidget)
DwarfRtsAutoSelect.ATTRS{
    desc = 'Auto-selects all squads and enters movement mode when the Squads screen opens.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function DwarfRtsAutoSelect:overlay_onupdate()
    local now = dfhack.getTickCount()
    if not self.last or now - self.last > REOPEN_GAP_MS then
        select_all_and_move()
    end
    self.last = now
end

OVERLAY_WIDGETS = {autoselect = DwarfRtsAutoSelect}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dwarf-rts: registered overlay dwarf-rts.autoselect (auto select-all + movement mode)')
