-- RTS-style click-to-command for the Dwarf Fortress squad screen.
--@module = true
--[[
dwarf-rts -- on the Squads screen:

  * Opening the Squads screen auto-selects every squad (RTS "select all"). After
    that you control the selection yourself: click squad buttons to toggle, or
    right-click the map to cycle through the squads one at a time (first, second,
    ... wrapping around). Right-clicking the military window itself instead tries
    to close it (same path as q/the banner). Deselecting is no longer fought --
    nothing re-selects behind your back.
  * Left-clicking the map MOVES the selected squads there. It flicks
    `giving_move_order` on for the one frame DF needs to register the move, then a
    self-clearing one-shot drops it (that UI otherwise pauses and persists).
  * Left-clicking a visible hostile ATTACKS it -- the move DF registers on that
    tile is converted to a kill order the next frame. Because the attack rides on
    DF's own move handling, clicks on panels/banners (which DF never turns into a
    move) can't become stray attacks on the terrain behind them. Shift+click adds
    a target to the current kill order instead of retargeting.
  * Trying to close the screen (q or the bottom-right banner) while a selected
    squad still has orders doesn't close it -- it deselects all squads instead, as
    a deliberate "are you sure" step. Press again with nothing armed and it closes,
    standing every squad down (all move/attack/patrol/burrow-defense orders are
    dismissed on the close that actually goes through).

It only acts with a squad selected and the cursor on the map, not on a command
button (guarded via `main_interface.current_hover`). Registered automatically as
overlay `dwarf-rts.clickmove`.
]]

local overlay = require('plugins.overlay')

-- The military window is right-anchored and overlays the map (so getMousePos can't
-- tell window from map -- it returns the tile underneath either way). It occupies
-- this many columns at the right screen edge; a right-click inside that band closes
-- the window, a right-click left of it falls on the map. Measured from the right
-- edge so it holds up when the window is resized.
local WINDOW_COLS = 28

local function squads_ui() return df.global.game.main_interface.squads end

-- mid-way through giving some other squad order: leave the input alone
local function busy(sq)
    return sq.giving_kill_order or sq.giving_patrol_order
        or sq.giving_burrow_order or sq.giving_move_order
end

-- A live, clickable enemy on a map tile, if any. RTS targeting: anything visible
-- and alive that isn't ours or an obvious friendly is fair game. (We can't gate
-- on isDanger/isInvader -- plenty of real threats here, e.g. magma crabs and wild
-- beasts, report neither; and hidden ambushers are excluded so a move onto an
-- unseen tile can't silently become an attack.)
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

-- erase a squad's orders (no delete: DF frees these on its own cancel path, so we
-- avoid leaving a dangling military target ref -- a tiny leak beats a crash)
local function clear_orders(sq)
    for i = #sq.orders - 1, 0, -1 do sq.orders:erase(i) end
end

local function new_kill_order(sq, enemy_id)
    local ko = df.squad_order_kill_listst:new()
    ko.issuer_hf = leader_hf(sq)
    ko.recipient_hf = -1
    ko.year = df.global.cur_year
    ko.year_tick = df.global.cur_year_tick
    ko.units:insert('#', enemy_id)
    return ko
end

-- shift+click: append a target to the current kill order (or start one), per squad
local function append_kill(enemy)
    local SQ = squads_ui()
    for i = 0, #SQ.squad_selected - 1 do
        if SQ.squad_selected[i] then
            local sq = df.squad.find(SQ.squad_id[i])
            if sq then
                local last = #sq.orders > 0 and sq.orders[#sq.orders - 1] or nil
                if last and df.squad_order_kill_listst:is_instance(last) then
                    local dup = false
                    for j = 0, #last.units - 1 do if last.units[j] == enemy.id then dup = true; break end end
                    if not dup then last.units:insert('#', enemy.id) end
                else
                    sq.orders:insert('#', new_kill_order(sq, enemy.id))
                end
            end
        end
    end
end

-- panel-safe attack: DF only writes a squad_order_movest for a genuine map click,
-- so any selected squad whose newest order is a move landing on a hostile gets
-- that move swapped for a kill order. Clicks on banners/panels never create a
-- move, so they can never turn into an attack on the terrain behind them.
local function convert_moves_to_kills(sq)
    for i = 0, #sq.squad_selected - 1 do
        if sq.squad_selected[i] then
            local s = df.squad.find(sq.squad_id[i])
            if s and #s.orders > 0 then
                local last = s.orders[#s.orders - 1]
                if df.squad_order_movest:is_instance(last) then
                    local enemy = enemy_at(last.pos)
                    if enemy then
                        clear_orders(s)            -- a fresh click is a fresh command
                        s.orders:insert('#', new_kill_order(s, enemy.id))
                    end
                end
            end
        end
    end
end

-- stand every squad down: wipe all move/attack/patrol/burrow-defense orders. Used
-- when the close-guard finally lets the screen close. squad_id survives the close,
-- so we can read the fort's squads straight off the (closing) panel.
local function clear_all_orders(sq)
    for i = 0, #sq.squad_id - 1 do
        local s = df.squad.find(sq.squad_id[i])
        if s then clear_orders(s) end
    end
end

-- does any currently-selected squad have standing orders? (close-guard arming)
local function selected_has_orders(sq)
    for i = 0, #sq.squad_selected - 1 do
        if sq.squad_selected[i] then
            local s = df.squad.find(sq.squad_id[i])
            if s and #s.orders > 0 then return true end
        end
    end
    return false
end

DwarfRtsClickMove = defclass(DwarfRtsClickMove, overlay.OverlayWidget)
DwarfRtsClickMove.ATTRS{
    desc = 'Squads screen: click to move/attack, right-click to cycle squads, select-all on open.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    -- whole fort mode, so onupdate sees the panel both open AND close (a
    -- Squads-only binding stalls the instant focus shifts off it)
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function DwarfRtsClickMove:overlay_onupdate()
    local sq = squads_ui()
    local open = sq.open

    if open and not self.prev_open then
        -- panel just opened: RTS select-all
        for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = true end
    elseif (not open) and self.prev_open then
        -- panel just closed: if a selected squad is mid-command, veto the close and
        -- drop the selection instead (a second close, now unarmed, goes through)
        if self.armed_close then
            sq.open = true
            for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = false end
            open = true
        else
            clear_all_orders(sq)    -- close goes through: stand every squad down
        end
    end

    if open then
        convert_moves_to_kills(sq)
        self.armed_close = selected_has_orders(sq)
    else
        self.armed_close = false
    end
    self.prev_open = open
end

function DwarfRtsClickMove:onInput(keys)
    local sq = squads_ui()
    if not sq.open or busy(sq) then return false end
    local on_ui = df.global.game.main_interface.current_hover ~= -1

    if keys._MOUSE_R then
        -- right-click inside the right-anchored military window: attempt to close it
        -- (the close-guard in onupdate then vetoes/deselects or closes+stands down)
        if df.global.gps.mouse_x >= df.global.gps.dimx - WINDOW_COLS then
            sq.open = false
            return true
        end
        -- right-click the map: cycle the selection to the next single squad, wrapping
        local n = #sq.squad_selected
        if n == 0 then return false end
        local cnt, idx = 0, -1
        for i = 0, n - 1 do if sq.squad_selected[i] then cnt = cnt + 1; idx = i end end
        local nextidx = (cnt == 1) and ((idx + 1) % n) or 0
        for i = 0, n - 1 do sq.squad_selected[i] = (i == nextidx) end
        return true                                    -- consume: don't let DF exit on it
    end

    if on_ui then return false end                     -- left-click on a button: leave alone
    if not keys._MOUSE_L then return false end

    local any = false
    for i = 0, #sq.squad_selected - 1 do if sq.squad_selected[i] then any = true; break end end
    if not any then return false end                   -- nothing selected: leave the click alone

    local pos = dfhack.gui.getMousePos(true)
    if not pos then return false end                   -- click wasn't on the map

    -- shift+click a hostile: add it to the kill order (immediate; conversion can't
    -- accumulate multiple targets since each move replaces the last)
    if dfhack.internal.getModifiers().shift then
        local enemy = enemy_at(pos)
        if enemy then append_kill(enemy); return true end
    end

    -- otherwise flick move mode so DF registers THIS click as a move target, then
    -- drop straight back out. onupdate converts the move to a kill if it landed on
    -- a hostile; a click on a panel never becomes a move, so it stays inert.
    sq.giving_move_order = true
    dfhack.timeout(2, 'frames', function() squads_ui().giving_move_order = false end)
    return false                                       -- pass the click to DF's move handler
end

OVERLAY_WIDGETS = {clickmove = DwarfRtsClickMove}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dwarf-rts: click move/attack, right-click cycle, select-all + close-guard active')
