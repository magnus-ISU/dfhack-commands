-- RTS-style click-to-command for the Dwarf Fortress squad screen.
--@module = true
--[[
dwarf-rts -- on the Squads screen:

  * Opening the Squads screen (or selecting any single squad) auto-selects them
    all, RTS "select all" style. Deselecting back to none is left alone, so you
    can still pick a squad and order individual members.
  * Left-clicking the map MOVES the selected squads there, without leaving the
    game stuck in the paused move UI: it flicks `giving_move_order` on for the one
    frame DF needs to register the move, then a self-clearing one-shot drops it.
  * Left-clicking a visible non-fort creature ATTACKS it immediately -- a kill
    order is built and handed straight to every selected squad (no confirm step,
    no pause). Hold Shift to add the target to the current kill order instead of
    replacing it.

It only acts with a squad selected and the cursor on the map (not on a command
button -- guarded via `main_interface.current_hover`, since getMousePos returns a
map tile under the buttons too), and is inert while you're mid-way through giving
some other squad order or in another sub-screen (equip/schedule have their own
focus). Move mode (`giving_move_order`) pauses the game by DF's own design and
persists until an order is placed, which is why it is only flicked momentarily;
the attack path sidesteps that entirely by writing the order struct directly.

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

-- A live, clickable enemy on a map tile, if any. RTS targeting: anything visible
-- and alive that isn't ours or an obvious friendly is fair game. (We can't gate
-- on isDanger/isInvader -- plenty of real threats here, e.g. magma crabs and wild
-- beasts, report neither; and hidden ambushers are excluded so a move-click onto
-- an unseen tile can't accidentally become an attack.)
local function enemy_at(pos)
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        if u.pos.x == pos.x and u.pos.y == pos.y and u.pos.z == pos.z
            and not dfhack.units.isDead(u)
            and not dfhack.units.isHidden(u)
            and not dfhack.units.isFortControlled(u)
            and not u.flags1.merchant and not u.flags1.diplomat
        then return u end
    end
end

-- the squad's commander histfig (first occupied position), for the order issuer
local function leader_hf(sq)
    for i = 0, #sq.positions - 1 do
        local occ = sq.positions[i].occupant
        if occ ~= -1 then return occ end
    end
    return -1
end

-- clear a squad's standing orders (erase only -- DF owns/frees these on its own
-- cancel path, so we don't delete and risk a dangling military target ref)
local function clear_orders(sq)
    for i = #sq.orders - 1, 0, -1 do sq.orders:erase(i) end
end

-- direct engage: hand each selected squad a kill order on `enemy`, no confirm.
-- Shift appends the target to an existing kill order; otherwise it replaces the
-- squad's orders so a fresh click retargets cleanly.
local function order_kill(enemy, append)
    local SQ = squads_ui()
    for i = 0, #SQ.squad_id - 1 do
        if SQ.squad_selected[i] then
            local sq = df.squad.find(SQ.squad_id[i])
            if sq then
                local ko
                local last = #sq.orders > 0 and sq.orders[#sq.orders - 1] or nil
                if append and last and df.squad_order_kill_listst:is_instance(last) then
                    ko = last
                else
                    if not append then clear_orders(sq) end
                    ko = df.squad_order_kill_listst:new()
                    ko.issuer_hf = leader_hf(sq)
                    ko.recipient_hf = -1
                    ko.year = df.global.cur_year
                    ko.year_tick = df.global.cur_year_tick
                    sq.orders:insert('#', ko)
                end
                local dup = false
                for j = 0, #ko.units - 1 do if ko.units[j] == enemy.id then dup = true; break end end
                if not dup then ko.units:insert('#', enemy.id) end
            end
        end
    end
end

DwarfRtsClickMove = defclass(DwarfRtsClickMove, overlay.OverlayWidget)
DwarfRtsClickMove.ATTRS{
    desc = 'Squads screen: click the map to move selected squads / attack hostiles; select-all on open.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    -- whole fort mode, so onupdate can see the panel open AND close (a Squads-only
    -- binding stalls the moment focus shifts, which is what trapped earlier builds)
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

-- Auto-select-all: on the rising edge of the panel opening, select every squad;
-- thereafter, selecting any one squad expands to all. Deselecting to none is left
-- as-is (a valid resting state for per-member orders) -- we only force-select on
-- the open edge, never just because zero are selected.
function DwarfRtsClickMove:overlay_onupdate()
    local sq = squads_ui()
    local open = sq.open
    if open and not self.prev_open then
        for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = true end
    elseif open then
        local any, all = false, true
        for i = 0, #sq.squad_selected - 1 do
            if sq.squad_selected[i] then any = true else all = false end
        end
        if any and not all then
            for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = true end
        end
    end
    self.prev_open = open
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

    local enemy = enemy_at(pos)
    if enemy then
        order_kill(enemy, dfhack.internal.getModifiers().shift)   -- attack now, no confirm
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
