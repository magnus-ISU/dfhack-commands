-- RTS-style squad controls for the Dwarf Fortress squad UI.
--@module = true
--[[
dwarf-rts -- make the squad screen behave like an RTS (see the README "dwarf-rts"
spec for the full design). Implemented:

  1. Opening the Squads screen auto-selects every squad and arms movement mode.
  2. Left-clicking the map in movement mode issues the move and re-arms movement
     mode, so you can chain destinations without re-selecting.
  3. Left-clicking a hostile in movement mode switches to attack (kill) mode and
     targets it instead of moving; hold Shift to add to the existing target list.
     (Engage with DF's normal confirm.)

  4. (TODO) clicking a leader portrait / unit camera -> follow with the camera.

The squad UI state lives in `df.global.game.main_interface.squads`: the mode
flags `giving_move_order` / `giving_kill_order` / `giving_patrol_order` /
`giving_burrow_order`, `squad_selected[]` (parallel to `squad_id[]`), `kill_unid[]`
for kill targets. NOTE: an `giving_*_order` flag pauses the game and persists even
after the menu closes, so it must be cleared on close or the fort stays frozen.

Registered automatically as overlay `dwarf-rts.control`; #1 runs from a frame poll
started by running the script (magnus-scripts does this) and on map load.
]]

local overlay = require('plugins.overlay')
local GLOBAL_KEY = 'dwarf-rts'

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

-- #2: re-arm movement mode once, a couple frames after a move is let through.
-- One-shot, never a sticky flag (a sticky re-arm fights the player's Esc).
local function rearm_move_once()
    dfhack.timeout(2, 'frames', function()
        local sq = squads_ui()
        if sq.open and #sq.squad_id > 0 then sq.giving_move_order = true end
    end)
end

-- #1 runs from a single frame poll keyed off the Squads screen opening/closing,
-- NOT the overlay's own update clock: that clock stalls while the game is in the
-- order-giving sub-mode (its focus moves off the Squads screen), so a gap-based
-- re-detect re-fired #1 and re-applied move mode the instant the player pressed
-- Esc -- trapping them in the paused mode. Frame timers keep ticking while paused,
-- so an edge-triggered poll is reliable. The generation counter lives on
-- dfhack.internal so a reload bumps it and any older poll exits.
local function poll_gen(set)
    if set ~= nil then dfhack.internal.dwarf_rts_gen = set end
    return dfhack.internal.dwarf_rts_gen or 0
end

function start_poll()
    local my = poll_gen() + 1
    poll_gen(my)
    local was_open = squads_ui().open
    local function tick()
        if my ~= poll_gen() then return end
        local sq = squads_ui()
        if sq.open and not was_open then
            select_all_and_move()                    -- #1: fire once, on open
        elseif was_open and not sq.open then
            sq.giving_move_order = false             -- closed: don't leave the fort paused
        end
        was_open = sq.open
        dfhack.timeout(1, 'frames', tick)
    end
    tick()
end

-- the overlay exists only to intercept map clicks (#2/#3); #1 is the poll above
DwarfRtsControl = defclass(DwarfRtsControl, overlay.OverlayWidget)
DwarfRtsControl.ATTRS{
    desc = 'RTS squad control: chain-move and click-enemy attack on the Squads map.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 1, h = 1},
}

-- onInput sees all input on the Squads screen regardless of our tiny frame (same
-- approach as DFHack's burrow-paint overlay).
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
    rearm_move_once()                                -- #2: let the move through, re-arm once
    return false
end

OVERLAY_WIDGETS = {control = DwarfRtsControl}

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then start_poll() end
end

if dfhack_flags.module then return end

start_poll()
require('plugins.overlay').rescan()
print('dwarf-rts: poll + overlay active (select+move on open, chain-move, click-enemy attack)')
