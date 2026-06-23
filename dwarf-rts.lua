-- RTS-style click-to-move for the Dwarf Fortress squad screen.
--@module = true
--[[
dwarf-rts -- on the Squads screen, left-clicking the map moves the selected squads
there WITHOUT leaving the game stuck in the paused move-selection mode.

DF's move-order UI (`giving_move_order`) pauses the game and stays open until you
place or cancel an order, so auto-arming it on open just froze the fort. Instead,
this leaves the screen alone on open, and on a map click it flicks move mode on
for the single frame DF needs to register the move, then immediately drops back
out -- so a click commands the squads but the game isn't left paused. If nothing
is selected, it selects all squads first, so a click always commands someone.

It is inert (passes input straight through) whenever you're actually giving a
kill / patrol / burrow order, or in another squad sub-screen (equip / schedule
have their own focus, so the overlay isn't even active there).

Map clicks are read with dfhack.gui.getMousePos, intercepted via the overlay's
onInput (works regardless of the tiny frame, like DFHack's burrow-paint overlay).

(TODO, intentionally deferred: click-an-enemy -> attack; camera-follow.)

Registered automatically as overlay `dwarf-rts.clickmove`.
]]

local overlay = require('plugins.overlay')

local function squads_ui() return df.global.game.main_interface.squads end

-- true while the player is mid-way through giving some other squad order, so we
-- must not hijack the click
local function busy(sq)
    return sq.giving_kill_order or sq.giving_patrol_order
        or sq.giving_burrow_order or sq.giving_move_order
end

DwarfRtsClickMove = defclass(DwarfRtsClickMove, overlay.OverlayWidget)
DwarfRtsClickMove.ATTRS{
    desc = 'Squads screen: left-click the map to move the selected squads (no paused move UI).',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 1, h = 1},
}

function DwarfRtsClickMove:onInput(keys)
    if not keys._MOUSE_L then return false end
    local sq = squads_ui()
    if not sq.open or busy(sq) then return false end   -- another order/mode owns the click
    local pos = dfhack.gui.getMousePos(true)
    if not pos then return false end                   -- click wasn't on the map

    -- nothing selected? select every squad so the click always commands someone
    local any = false
    for i = 0, #sq.squad_selected - 1 do if sq.squad_selected[i] then any = true; break end end
    if not any then for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = true end end

    -- flick move mode on so DF's native handler registers THIS click as the move
    -- target, then drop straight back out a couple frames later so the game is
    -- never left paused (cleared unconditionally so a closed menu can't strand it)
    sq.giving_move_order = true
    dfhack.timeout(2, 'frames', function() squads_ui().giving_move_order = false end)
    return false                                       -- pass the click to DF's move handler
end

OVERLAY_WIDGETS = {clickmove = DwarfRtsClickMove}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dwarf-rts: click-to-move active on the Squads screen (no auto-pause)')
