-- RTS-style click-to-command for the Dwarf Fortress squad screen.
--@module = true
--[[
dwarf-rts -- on the Squads screen:

  * Selecting any squad auto-selects them all (RTS "select all").
  * Left-clicking the map MOVES the selected squads there, without leaving the
    game stuck in the paused move UI: it flicks `giving_move_order` on for the one
    frame DF needs to register the move, then a self-clearing one-shot drops it.
  * Left-clicking a hostile instead switches to attack (kill) mode and targets it;
    hold Shift to add to the existing target list. (Confirm to engage, as for any
    kill order -- entering kill mode pauses the game by DF's own design.)

It only acts with a squad selected and the cursor on the map (not on a command
button -- guarded via `main_interface.current_hover`, since getMousePos returns a
map tile under the buttons too), and is inert while you're already giving a
kill/patrol/burrow order or in another sub-screen (equip/schedule have their own
focus). DF's move/kill UI (`giving_*_order`) pauses the game and persists until an
order is placed or cancelled, which is why move mode is only flicked momentarily.

Planned (not yet built): right-click while the squad menu is open -> close it and
cancel the station/move order. Deferred pending a unified left/right handler.

Registered automatically as overlay `dwarf-rts.clickmove`.
]]

local overlay = require('plugins.overlay')

local function squads_ui() return df.global.game.main_interface.squads end

-- mid-way through giving some other squad order: leave the click alone
local function busy(sq)
    return sq.giving_kill_order or sq.giving_patrol_order
        or sq.giving_burrow_order or sq.giving_move_order
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

-- click-an-enemy: enter kill mode and target it (Shift appends, else replaces)
local function target_enemy(enemy, append)
    local sq = squads_ui()
    sq.giving_kill_order = true
    if not append then
        for i = #sq.kill_unid - 1, 0, -1 do sq.kill_unid:erase(i) end
    end
    for i = 0, #sq.kill_unid - 1 do if sq.kill_unid[i] == enemy.id then return end end
    sq.kill_unid:insert('#', enemy.id)
end

DwarfRtsClickMove = defclass(DwarfRtsClickMove, overlay.OverlayWidget)
DwarfRtsClickMove.ATTRS{
    desc = 'Squads screen: click the map to move selected squads / attack hostiles; select-all on select.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

-- selecting any squad selects them all. Safe to do here every frame: it only
-- touches squad_selected (no giving_*_order, so no pause and no focus-stall that
-- could re-trap -- unlike the abandoned auto-move-mode).
function DwarfRtsClickMove:overlay_onupdate()
    local sq = squads_ui()
    if not sq.open then return end
    local any, all = false, true
    for i = 0, #sq.squad_selected - 1 do
        if sq.squad_selected[i] then any = true else all = false end
    end
    if any and not all then
        for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = true end
    end
end

function DwarfRtsClickMove:onInput(keys)
    if not keys._MOUSE_L then return false end
    local sq = squads_ui()
    if not sq.open or busy(sq) then return false end   -- another order/mode owns the click
    if df.global.game.main_interface.current_hover ~= -1 then return false end  -- on a UI button

    local any = false
    for i = 0, #sq.squad_selected - 1 do if sq.squad_selected[i] then any = true; break end end
    if not any then return false end                   -- nothing selected: leave the click alone

    local pos = dfhack.gui.getMousePos(true)
    if not pos then return false end                   -- click wasn't on the map

    local enemy = hostile_at(pos)
    if enemy then
        target_enemy(enemy, dfhack.internal.getModifiers().shift)   -- attack (confirm to engage)
        return true                                    -- consume: don't also move onto it
    end

    -- move: flick move mode on so DF registers THIS click as the target, then drop
    -- straight back out (cleared unconditionally so a closed menu can't strand it)
    sq.giving_move_order = true
    dfhack.timeout(2, 'frames', function() squads_ui().giving_move_order = false end)
    return false                                       -- pass the click to DF's move handler
end

OVERLAY_WIDGETS = {clickmove = DwarfRtsClickMove}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dwarf-rts: click-to-move/attack + select-all active on the Squads screen')
