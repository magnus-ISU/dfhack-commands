-- RTS-style squad controls for the Dwarf Fortress squad UI.
--@module = true
--[[
dwarf-rts -- make the squad screen behave like an RTS (see the README "dwarf-rts"
spec for the full design). Implemented so far:

  1. Opening the Squads screen auto-selects every squad and arms movement mode.
  2. Left-clicking the map in movement mode issues the move and re-arms movement
     mode, so you can chain destinations without re-selecting.
  3. Left-clicking a hostile in movement mode switches to attack (kill) mode and
     targets it instead of moving; hold Shift to add to the existing target list
     rather than replacing it. (Engage with DF's normal confirm, as for any kill
     order -- we set up the targeting, we don't forge the order ourselves.)

  4. (TODO) clicking a leader portrait / unit camera -> follow with the camera.

The squad UI state lives in `df.global.game.main_interface.squads`: the mode
flags `giving_move_order` / `giving_kill_order` / `giving_patrol_order` /
`giving_burrow_order`, the `squad_selected[]` vector (parallel to `squad_id[]`),
and `kill_unid[]` for kill targets.

Registered automatically as overlay `dwarf-rts.control`.
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

-- the live hostile standing on a map tile, if any (an enemy/danger, not ours)
local function hostile_at(pos)
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        if u.pos.x == pos.x and u.pos.y == pos.y and u.pos.z == pos.z
            and not dfhack.units.isDead(u) and not dfhack.units.isHidden(u)
            and not dfhack.units.isFortControlled(u)
            and (dfhack.units.isDanger(u) or dfhack.units.isInvader(u))
        then return u end
    end
end

-- behaviour #3: leave movement mode, enter kill mode, target the enemy. Shift
-- appends; otherwise the current target list is replaced.
local function target_enemy(enemy, append)
    local sq = squads_ui()
    sq.giving_move_order = false
    sq.giving_patrol_order = false
    sq.giving_burrow_order = false
    sq.giving_kill_order = true
    if not append then
        for i = #sq.kill_unid - 1, 0, -1 do sq.kill_unid:erase(i) end
    end
    for i = 0, #sq.kill_unid - 1 do if sq.kill_unid[i] == enemy.id then return end end
    sq.kill_unid:insert('#', enemy.id)
end

DwarfRtsControl = defclass(DwarfRtsControl, overlay.OverlayWidget)
DwarfRtsControl.ATTRS{
    desc = 'RTS squad control: auto select+move on open, chain-move, click-enemy attack.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function DwarfRtsControl:overlay_onupdate()
    local now = dfhack.getTickCount()
    if not self.last or now - self.last > REOPEN_GAP_MS then
        select_all_and_move()                        -- #1: fresh open
    end
    self.last = now
end

-- #2: re-arm movement mode ONCE, a couple frames after the move is let through
-- (DF needs the intervening frames to issue it). This is deliberately a one-shot
-- timeout, never a persistent flag: a sticky re-arm re-applies move mode the
-- instant the player presses Esc, trapping them in the paused order-giving mode.
local function rearm_move_once()
    dfhack.timeout(2, 'frames', function()
        local sq = squads_ui()
        if sq.open and #sq.squad_id > 0 then sq.giving_move_order = true end
    end)
end

-- onInput sees all input on the Squads screen regardless of our tiny frame, so we
-- can intercept map clicks (same approach as DFHack's burrow-paint overlay).
function DwarfRtsControl:onInput(keys)
    local sq = squads_ui()
    if not (keys._MOUSE_L and sq.open and sq.giving_move_order) then return false end
    local pos = dfhack.gui.getMousePos(true)
    if not pos then return false end                 -- click wasn't on the map
    local enemy = hostile_at(pos)
    if enemy then
        target_enemy(enemy, dfhack.internal.getModifiers().shift)   -- #3
        return true                                  -- consume: attack, don't move
    end
    rearm_move_once()                                -- #2: let the move through, re-arm once after
    return false
end

OVERLAY_WIDGETS = {control = DwarfRtsControl}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dwarf-rts: registered overlay dwarf-rts.control (select+move on open, chain-move, click-enemy attack)')
