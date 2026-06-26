-- RTS-style click-to-command for the Dwarf Fortress squad screen.
--@module = true
--[[
dwarf-rts -- on the Squads screen:

  * Opening the Squads screen auto-selects every squad (RTS "select all"). After
    that you control the selection yourself: click squad buttons to toggle, or press
    keyboard 1-9 to select that squad in the list (1 = first). The FIRST press of a
    squad's key just selects it; pressing the same key again centers the camera on and
    follows its leader, and each further press follows the next member (wrapping). Every
    selected member (individual or whole-squad) is outlined on the map in the selection
    art. Right-clicking the
    military window tries to close it (same path as q/the banner); a right-click on
    the map is left to DF (backs out the member view / closes the panel); right-
    clicking the right edge of the screen while it's closed opens it. Deselecting is
    no longer fought -- nothing re-selects behind your back.
  * All left-button map commands resolve on mouse-UP (the raw button is polled each
    frame), so a click is cleanly told apart from a drag and nothing fires on press:
      - A plain click (no drag) is passed straight through to the game as a normal
        left-click on mouse-up, so you can select squads, units, and anything under the
        cursor exactly as you would without this overlay. (The press is swallowed so the
        game doesn't act mid-gesture, then the click is re-dispatched on release.) RTS
        commands are issued by DRAGGING, below.
      - A drag (a box) with hostiles inside it orders the selection to attack every
        hostile within +/-3 z-levels of the drag; Shift+drag folds the box's hostiles
        into the current kill order instead of replacing it. A drag with NO hostiles is
        a selection/conscription gesture instead (below) -- it never disturbs orders.
    Clicks and box-attacks act on the highlighted MEMBERS when one squad is expanded
    into its member view (per-position orders), otherwise on the selected squads.
    A live box with a WxH readout tracks the drag, its corners marked with a CURSORS
    graphic for what it will do: attack cursor over enemies, friendly cursor over your
    own dwarves, empty cursor over nothing. Selected members are marked the same way.
    The press is gated to a genuine map press (a squad is selected, the cursor is
    not on a command button, and it's left of the right-side window), so panels and
    banners can never command squads. While a squad is selected these map clicks are
    also swallowed, so DF doesn't open a stockpile/pedestal/building menu under the
    cursor mid-command; with nothing selected, clicks fall through to DF as usual.
  * Left-clicking a unit's portrait (any "View ... sheet" button -- the squad
    leader's image or a member's) works in two stages, like the close-guard: the
    first click starts the camera following that unit and immediately closes the
    info page DF opened (so it reads as "follow", not "open sheet"); a second click
    on a unit you're already following opens its info page and leaves it up while
    still following the unit. Right-
    clicking that page (or any menu over the squads screen) closes the menu rather
    than toggling the squad window. Scrolling the map releases the follow natively.
  * Trying to close the screen (q or the bottom-right banner) while ANY squad is
    selected doesn't close it -- it deselects all squads instead, as a deliberate
    "are you sure" step (the screen opens with everything selected, so the first
    close always just clears the selection). Press again with nothing selected and
    it closes, standing every squad down (all move/attack/patrol/burrow-defense
    orders are dismissed on the close that actually goes through -- BOTH squad-level and
    per-member individual orders).
  * Drag a box over your own DWARVES (no hostiles in it) to select them (`box_select`):
      - members of several squads -> select those whole squads
      - members of one squad: the WHOLE squad if every member is boxed, else just the
        boxed members (expands that squad into its member view -- map clicks then issue
        per-member orders via squad_position.orders, exactly as DF's own member view does)
      - only un-squadded civilians -> conscript them (below)
  * Drag a box over your own un-squadded CIVILIANS to conscript them into temporary
    "Conscripts" squads -- one per 10 (a captain in pos 0 + 9). Each squad's name is
    prefixed with its 1-based slot in the list (e.g. "3. Conscripts") so it matches its
    1-9 hotkey. Each
    is a real squad: a fresh militia-captain assignment with one conscript properly
    appointed (entity-link) and hand-seated in pos 0, named via `alias`, the rest
    in pos 1-9. The new squads are then selected, after a REAL list refresh: we feed
    DF the `D_SQUADS` key twice (close+reopen) via simulateInput so it rebuilds the
    squad list -- flag-toggling sq.open does NOT run that logic. Closing the squads
    screen disbands every Conscription squad (found by alias, so it survives a
    reload), returning the conscripts to civilian life.
  * Each conscript's uniform is rewritten to EXACTLY match what they already wear and
    wield (one already-satisfied spec per equipped item), replacing the generic metal
    uniform a fresh squad gets, and the squad carries no food/water so no backpack or
    flask is sought either. So they answer orders instantly -- a miner keeps fighting
    with his pick, everyone keeps their clothes -- instead of trooping off to a
    stockpile to equip gear they don't have. See `match_uniform_to_inventory`.

It only acts with a squad selected and the cursor on the map, not on a command
button (guarded via `main_interface.current_hover`). It also stands fully aside
whenever a squads SUB-dialog is up -- the squad equipment (uniform/ammo) or schedule
viewscreen, or the "assign uniform" picker -- so those work normally. This matters most
for assign_uniform, which is drawn over the map but keeps the squads focus: without the
guard its clicks were swallowed (no uniform assigned) and the mouse-up poller fired
stray station orders, which is why a new squad couldn't be equipped. See
`squad_subscreen_open`. Registered automatically as overlay `dwarf-rts.clickmove`.

The drag/refresh/select/disband cycle is verified end-to-end via the remote API;
the in-game drag path still wants a live test.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')
local guidm = require('gui.dwarfmode')
local utils = require('utils')

-- The military window is right-anchored and overlays the map (so getMousePos can't
-- tell window from map -- it returns the tile underneath either way). It occupies
-- this many columns at the right screen edge; a right-click inside that band closes
-- the window, a right-click left of it falls on the map. Measured from the right
-- edge so it holds up when the window is resized.
local WINDOW_COLS = 28

local function squads_ui() return df.global.game.main_interface.squads end

-- Squad sub-dialogs that sit ON TOP of the squads screen, where dwarf-rts must stand
-- fully aside. Two distinct hazards:
--   * squad_equipment / squad_schedule are separate viewscreens that hide the squads
--     panel (squads.open flips to false). Without this guard the close-guard in
--     overlay_onupdate reads that flip as the player closing the squads screen, vetoes
--     it (reopens the panel + deselects the squad) and breaks the screen.
--   * assign_uniform is the "pick a uniform" dialog. It is drawn over the MAP area but
--     leaves the focus at 'dwarfmode/Squads/Default' and its list rows report
--     current_hover == -1 -- so without this guard onInput swallows the clicks (the
--     uniform never gets assigned) AND the mouse-up poller fires stray station/move
--     orders on the selected squads. This is THE reason you couldn't equip a new squad.
-- Detected via each dialog's own open flag, so it's independent of focus strings (and
-- harmless for the viewscreen cases if squads.open happens to stay true -- no edge fires).
local function squad_subscreen_open()
    local mi = df.global.game.main_interface
    return mi.squad_equipment.open or mi.squad_schedule.open or mi.assign_uniform.open
end

-- does this widget belong to the screen we're actually on right now? (matchFocusString
-- is the same test the overlay framework uses; it safely says "no" for the many
-- widgets bound to other screens, so we never touch their stale state)
local function widget_on_screen(w, vs)
    local vss = w.viewscreens
    if type(vss) == 'string' then vss = {vss} end
    if type(vss) ~= 'table' then return false end
    for _, fs in ipairs(vss) do
        if type(fs) == 'string' then
            local ok, m = pcall(dfhack.gui.matchFocusString, fs, vs)
            if ok and m then return true end
        end
    end
    return false
end

-- Is the cursor over some OTHER overlay panel that's actually showing right now (the
-- notifications list, a civ-alert button, etc.)? If so we must not swallow the click
-- -- it needs to reach that overlay. We gate on the framework's own focus match
-- before reading frame_rect/visible, so stale rects from off-screen widgets (which
-- otherwise blanket the screen) and their throwing getters are never consulted.
-- Frame rects are absolute screen tiles, like gps.mouse_*.
local function over_other_overlay(mx, my)
    local vs = dfhack.gui.getDFViewscreen(true)
    local fullw, fullh = df.global.gps.dimx - 1, df.global.gps.dimy - 1
    for name, e in pairs(overlay.get_state().db) do
        if name ~= 'dwarf-rts.clickmove' then
            local w = e.widget
            local r = w.frame_rect
            -- skip whole-screen interaction layers (confirm/spectate/design): they
            -- always report visible and would blanket every click. Real panels are small.
            if r and mx >= r.x1 and mx <= r.x2 and my >= r.y1 and my <= r.y2
                and not (r.x1 <= 0 and r.y1 <= 0 and r.x2 >= fullw and r.y2 >= fullh)
                and widget_on_screen(w, vs)
            then
                local ok, vis = pcall(function() return utils.getval(w.visible) end)
                if ok and vis then return true end
            end
        end
    end
    return false
end

-- mid-way through giving some other squad order: leave the input alone
local function busy(sq)
    return sq.giving_kill_order or sq.giving_patrol_order
        or sq.giving_burrow_order or sq.giving_move_order
end

-- A valid attack target? RTS targeting: anything visible and alive that isn't ours
-- or an obvious friendly is fair game. (We can't gate on isDanger/isInvader --
-- plenty of real threats here, e.g. magma crabs and wild beasts, report neither;
-- and hidden ambushers are excluded so a move onto an unseen tile can't silently
-- become an attack.)
local function is_enemy(u)
    return not dfhack.units.isDead(u)
        and not dfhack.units.isHidden(u)
        and not dfhack.units.isFortControlled(u)
        and not u.flags1.merchant and not u.flags1.diplomat
end

-- the live enemy standing on a map tile, if any
local function enemy_at(pos)
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        if u.pos.x == pos.x and u.pos.y == pos.y and u.pos.z == pos.z and is_enemy(u) then
            return u
        end
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

-- close the unit info page DF opens off a portrait click, but only if it is the
-- topmost screen right now (never yank away anything else the player opened since)
local function close_unit_sheet()
    local f1 = dfhack.gui.getCurFocus(true)[1]
    if f1 and f1:find('ViewSheets') then
        gui.simulateInput(dfhack.gui.getDFViewscreen(true), 'LEAVESCREEN')
    end
end

-- the minimap tooltip text for a hovered button id (its "what does this do" hint)
local function hover_tooltip(id)
    if id < 0 then return nil end
    local h = df.global.game.main_interface.hover_instruction
    if id >= #h then return nil end
    local b = h[id]
    if b and b.text and #b.text > 0 then
        return tostring(b.text[0].value or b.text[0])
    end
end

-- erase a squad's orders (no delete: DF frees these on its own cancel path, so we
-- avoid leaving a dangling military target ref -- a tiny leak beats a crash)
local function clear_orders(sq)
    for i = #sq.orders - 1, 0, -1 do sq.orders:erase(i) end
end

-- ---- individual-member orders ---------------------------------------------------
-- When one squad is expanded into its member view (viewing_squad_index >= 0) with
-- members highlighted (squad_hfid_selected), DF commands per POSITION, not per squad:
-- a fresh order on squad_position.orders, issuer/recipient -1 (the order lives on the
-- member's own slot, alongside any stale squad-level order). We mirror that exactly so
-- a map click moves/attacks only the highlighted dwarves. Verified against a live squad
-- whose members each carried their own squad_order_movest in pos.orders.

-- individual-member selection active? (a squad expanded, with members highlighted)
local function has_indiv_selection(ui)
    return ui.viewing_squad_index >= 0 and #ui.squad_hfid_selected > 0
end

-- the squad_position objects of the currently highlighted members of the viewed squad
local function selected_positions(ui)
    local out = {}
    if ui.viewing_squad_index < 0 then return out end
    local sq = df.squad.find(ui.squad_id[ui.viewing_squad_index])
    if not sq then return out end
    local want = {}
    for i = 0, #ui.squad_hfid_selected - 1 do want[ui.squad_hfid_selected[i]] = true end
    for p = 0, #sq.positions - 1 do
        if want[sq.positions[p].occupant] then out[#out + 1] = sq.positions[p] end
    end
    return out
end

-- erase one member's own orders (no :delete(), same reasoning as clear_orders)
local function clear_pos_orders(pos)
    for i = #pos.orders - 1, 0, -1 do pos.orders:erase(i) end
end

-- drop every member's individual order in a squad (a squad-wide order supersedes them)
local function clear_member_orders(s)
    for p = 0, #s.positions - 1 do clear_pos_orders(s.positions[p]) end
end

-- order one member (its position) to move to a tile -- replaces that member's order
local function pos_move(pos, target)
    clear_pos_orders(pos)
    local mo = df.squad_order_movest:new()
    mo.issuer_hf, mo.recipient_hf = -1, -1
    mo.year, mo.year_tick = df.global.cur_year, df.global.cur_year_tick
    mo.pos.x, mo.pos.y, mo.pos.z = target.x, target.y, target.z
    mo.point_id = -1
    pos.orders:insert('#', mo)
end

-- order one member to kill `ids`. append folds into its current kill order; otherwise
-- replaces. Built fresh (DF only recomputes targeting when an order is newly given).
local function pos_kill(pos, ids, append)
    local all, seen = {}, {}
    local function add(id) if not seen[id] then seen[id] = true; all[#all + 1] = id end end
    if append then
        local last = #pos.orders > 0 and pos.orders[#pos.orders - 1] or nil
        if last and df.squad_order_kill_listst:is_instance(last) then
            for j = 0, #last.units - 1 do add(last.units[j]) end
        end
    end
    for _, id in ipairs(ids) do add(id) end
    clear_pos_orders(pos)
    local ko = df.squad_order_kill_listst:new()
    ko.issuer_hf, ko.recipient_hf = -1, -1
    ko.year, ko.year_tick = df.global.cur_year, df.global.cur_year_tick
    for _, id in ipairs(all) do ko.units:insert('#', id) end
    pos.orders:insert('#', ko)
end

-- give squad `s` a kill order on the unit ids in `ids`. append=true folds them into
-- its current kill order (multi-target / additive selection); otherwise it replaces
-- the squad's orders. Either way the order is built FRESH (and duplicate targets are
-- skipped): DF only (re)computes an order -- its title and, crucially, its targeting
-- -- when the order is newly given, so mutating an existing order's unit list in
-- place leaves it half-applied (stale "Kill X" title, the added target not engaged).
local function squad_kill(s, ids, append)
    local all, seen = {}, {}
    local function add(id) if not seen[id] then seen[id] = true; all[#all + 1] = id end end
    if append then
        local last = #s.orders > 0 and s.orders[#s.orders - 1] or nil
        if last and df.squad_order_kill_listst:is_instance(last) then
            for j = 0, #last.units - 1 do add(last.units[j]) end
        end
    end
    for _, id in ipairs(ids) do add(id) end
    clear_orders(s)
    clear_member_orders(s)          -- squad-wide order: drop any individual member orders
    local ko = df.squad_order_kill_listst:new()
    ko.issuer_hf = leader_hf(s)
    ko.recipient_hf = -1
    ko.year = df.global.cur_year
    ko.year_tick = df.global.cur_year_tick
    for _, id in ipairs(all) do ko.units:insert('#', id) end
    s.orders:insert('#', ko)
end

-- order the selected squads to kill `enemy`. append=true adds it to the current
-- kill order (multi-target); otherwise it replaces their orders with a fresh one.
local function order_kill_single(ui, enemy, append)
    for i = 0, #ui.squad_selected - 1 do
        if ui.squad_selected[i] then
            local s = df.squad.find(ui.squad_id[i])
            if s then squad_kill(s, {enemy.id}, append) end
        end
    end
end

-- order the selected squads to move to a map tile (replaces their orders)
local function move_selected(ui, pos)
    for i = 0, #ui.squad_selected - 1 do
        if ui.squad_selected[i] then
            local s = df.squad.find(ui.squad_id[i])
            if s then
                clear_orders(s)
                clear_member_orders(s)   -- squad-wide order: drop any individual member orders
                local mo = df.squad_order_movest:new()
                mo.issuer_hf = leader_hf(s)
                mo.recipient_hf = -1
                mo.year = df.global.cur_year
                mo.year_tick = df.global.cur_year_tick
                mo.pos.x = pos.x; mo.pos.y = pos.y; mo.pos.z = pos.z
                mo.point_id = -1
                s.orders:insert('#', mo)
            end
        end
    end
end

local box_select   -- forward decl (defined after conscription): single_command selects
                   -- the own dwarf under a click via a 1-tile box_select

-- a plain click on the map (resolved on mouse-up): attack the enemy on that tile; else,
-- if one of your own dwarves is under the cursor, SELECT it (a 1-tile box_select, so the
-- same squad/member rules apply); else move the current selection there. Orders route to
-- the highlighted members in member view, else to the selected squads. Shift on an enemy
-- appends to the kill order. Returns box_select's result when the click selected.
local function single_command(ui, pos, shift)
    local enemy = enemy_at(pos)
    if enemy then
        if has_indiv_selection(ui) then
            for _, p in ipairs(selected_positions(ui)) do pos_kill(p, {enemy.id}, shift) end
        else
            order_kill_single(ui, enemy, shift)
        end
        return
    end
    local sel = box_select(ui, pos, pos)        -- own dwarf under the cursor -> select it
    if sel then return sel end
    if has_indiv_selection(ui) then
        for _, p in ipairs(selected_positions(ui)) do pos_move(p, pos) end
    else
        move_selected(ui, pos)
    end
end

-- stand every squad down: wipe all move/attack/patrol/burrow-defense orders. Used
-- when the close-guard finally lets the screen close. squad_id survives the close,
-- so we can read the fort's squads straight off the (closing) panel.
local function clear_all_orders(sq)
    for i = 0, #sq.squad_id - 1 do
        local s = df.squad.find(sq.squad_id[i])
        if s then
            clear_orders(s)             -- squad-level orders
            clear_member_orders(s)      -- and every member's individual orders
        end
    end
end

local function has_selection(ui)
    for i = 0, #ui.squad_selected - 1 do if ui.squad_selected[i] then return true end end
    return false
end

-- list index of the SINGLE selected squad (nil if zero, several, or in member view) --
-- used to tell "this squad is the active selection" from "select-all / something else"
local function only_selected_squad(ui)
    if has_indiv_selection(ui) then return nil end
    local idx, cnt = nil, 0
    for i = 0, #ui.squad_selected - 1 do
        if ui.squad_selected[i] then idx = i; cnt = cnt + 1 end
    end
    if cnt == 1 then return idx end
end

local function same_tile(a, b)
    return a.x == b.x and a.y == b.y and a.z == b.z
end

-- drag-box offensive command: every selected squad attacks all enemies inside the
-- dragged rectangle, within +/-3 z-levels of the drag. append=true (Shift+drag)
-- folds the box's hostiles into the current kill order instead of replacing it. An
-- empty box (no hostiles) is a no-op -- it leaves each squad's existing order alone.
local function box_attack(ui, p1, p2, append)
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local z1, z2 = p1.z - 3, p1.z + 3
    local ids = {}
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        local p = u.pos
        if p.x >= x1 and p.x <= x2 and p.y >= y1 and p.y <= y2
            and p.z >= z1 and p.z <= z2 and is_enemy(u)
        then ids[#ids + 1] = u.id end
    end
    if #ids == 0 then return 0 end          -- nothing in the box: keep the prior order
    if has_indiv_selection(ui) then
        for _, p in ipairs(selected_positions(ui)) do pos_kill(p, ids, append) end
    else
        for i = 0, #ui.squad_selected - 1 do
            if ui.squad_selected[i] then
                local s = df.squad.find(ui.squad_id[i])
                if s then squad_kill(s, ids, append) end
            end
        end
    end
    return #ids
end

-- ---- conscription: drag civilians (squad screen open) into temporary squads -----

local CONSCRIPTS_PER_SQUAD = 10  -- 1 captain (pos 0) + 9 members (pos 1-9)
local CONSCRIPT_TAG = 'Conscripts'   -- base squad alias; also how we find them to disband
                                     -- (an index prefix is added once the panel lists them)
local pending_select             -- new squad ids to select once the panel lists them

local function fort_entity() return df.historical_entity.find(df.global.plotinfo.group_id) end

-- the unlimited squad-leader position (militia captain: squad_size>0, number<0)
local function militia_captain_position(ent)
    for j = 0, #ent.positions.own - 1 do
        local p = ent.positions.own[j]
        if p.squad_size > 0 and p.number < 0 then return p.id, j end
    end
end

-- adult fort citizens standing in the box who aren't already in a squad. NOTE: exact
-- box z-range only -- unlike attacking, conscription does NOT reach +/-3 z.
local function civilians_in_box(p1, p2)
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local z1, z2 = math.min(p1.z, p2.z), math.max(p1.z, p2.z)
    local ids = {}
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        local p = u.pos
        if p.x >= x1 and p.x <= x2 and p.y >= y1 and p.y <= y2 and p.z >= z1 and p.z <= z2
            and u.military.squad_id == -1
            and dfhack.units.isCitizen(u) and dfhack.units.isActive(u)
            and not dfhack.units.isDead(u) and dfhack.units.isAdult(u)
        then ids[#ids + 1] = u.id end
    end
    return ids
end

-- scan a box for fort dwarves (exact box z-range, like civilians_in_box): the squadded
-- ones grouped by squad id -> their histfig ids, plus the loose (un-squadded) ones as
-- unit ids. Drives drag-to-select: squads vs members vs conscription.
local function dwarves_in_box(p1, p2)
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local z1, z2 = math.min(p1.z, p2.z), math.max(p1.z, p2.z)
    local by_squad, loose = {}, {}
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        local p = u.pos
        if p.x >= x1 and p.x <= x2 and p.y >= y1 and p.y <= y2 and p.z >= z1 and p.z <= z2
            and dfhack.units.isCitizen(u) and dfhack.units.isActive(u)
            and not dfhack.units.isDead(u) and dfhack.units.isAdult(u)
        then
            local sid = u.military.squad_id
            if sid >= 0 and u.hist_figure_id >= 0 then
                by_squad[sid] = by_squad[sid] or {}
                by_squad[sid][#by_squad[sid] + 1] = u.hist_figure_id
            elseif sid == -1 then
                loose[#loose + 1] = u.id
            end
        end
    end
    return by_squad, loose
end

-- occupied positions in a squad (its real member count)
local function squad_member_count(sq)
    local n = 0
    for p = 0, #sq.positions - 1 do if sq.positions[p].occupant >= 0 then n = n + 1 end end
    return n
end

-- list index of a squad id within the panel's squad list (for viewing_squad_index)
local function squad_list_index(ui, sid)
    for i = 0, #ui.squad_id - 1 do if ui.squad_id[i] == sid then return i end end
end

-- whole-squad selection: pick exactly the squads in `want` (a set of squad ids),
-- leaving the individual-member view (back to the top-level squad list)
local function select_squads(ui, want)
    ui.viewing_squad_index = -1
    ui.squad_hfid_selected:resize(0)
    for i = 0, #ui.squad_id - 1 do
        ui.squad_selected[i] = want[ui.squad_id[i]] or false
    end
end

-- individual-member selection: expand squad `sid` into its member view with exactly
-- `hfids` highlighted (clears the top-level squad selection so commands route per member)
local function select_individuals(ui, sid, hfids)
    local idx = squad_list_index(ui, sid)
    if not idx then return false end
    for i = 0, #ui.squad_selected - 1 do ui.squad_selected[i] = false end
    ui.viewing_squad_index = idx
    ui.squad_hfid_selected:resize(0)
    for _, hf in ipairs(hfids) do ui.squad_hfid_selected:insert('#', hf) end
    return true
end

-- appoint a histfig to a position assignment (the embark-nobles pattern: set histfig
-- AND add the position entity-link -- without the link DF won't list the squad)
local function appoint(ent, a, aidx, figid)
    a.histfig, a.histfig2 = figid, figid
    df.historical_figure.find(figid).entity_links:insert('#', {
        new = df.histfig_entity_link_positionst, entity_id = ent.id, link_strength = 100,
        assignment_id = a.id, assignment_vector_idx = aidx, start_year = df.global.cur_year})
end

-- inverse of appoint: drop the position entity-link and vacate the slot
local function vacate(ent, a)
    if a.histfig == -1 then return end
    local f = df.historical_figure.find(a.histfig)
    if f then
        for k, v in ipairs(f.entity_links) do
            if df.histfig_entity_link_positionst:is_instance(v)
                and v.assignment_id == a.id and v.entity_id == ent.id then
                f.entity_links:erase(k); break
            end
        end
    end
    a.histfig, a.histfig2 = -1, -1
end

-- item_type -> uniform slot (0=body 1=head 2=legs 3=hands 4=feet 5=shield 6=weapon)
local UNIFORM_SLOT = {
    [df.item_type.WEAPON] = 6,
    [df.item_type.SHIELD] = 5,
    [df.item_type.ARMOR]  = 0,
    [df.item_type.HELM]   = 1,
    [df.item_type.PANTS]  = 2,
    [df.item_type.GLOVES] = 3,
    [df.item_type.SHOES]  = 4,
}
-- only items the unit is actually wearing/wielding count as "equipped" (skip Hauled
-- cargo, mounts, things stuck in wounds, etc.)
local EQUIPPED_MODE = {
    [df.inv_item_role_type.Weapon] = true,   -- grasped: weapon, shield, crutch
    [df.inv_item_role_type.Worn] = true,
    [df.inv_item_role_type.Strapped] = true,
    [df.inv_item_role_type.SewnInto] = true,
}

-- Make a squad position's uniform an EXACT match of what its occupant already wears
-- and wields, so the conscript is "fully equipped" the instant they're drafted and
-- never runs off to a stockpile: a fresh makeSquad squad gets a generic 7-slot metal
-- uniform, and on any order DF would send them to fetch that gear. We replace it with
-- one spec per currently-equipped item -- a type/subtype/material requirement with the
-- exact item already recorded in `assigned`, mirroring how DF marks a uniform fully
-- satisfied (item(req)=-1 + the held item in the assigned list), so nothing is fetched.
-- Clearing the default: empty each slot vector (resize 0) -- do NOT :delete() the old
-- specs (DF owns them; deleting crashes), a small leak that dies with the temp squad.
local function match_uniform_to_inventory(pos, unit)
    local eq = pos.equipment
    for slot = 0, 6 do eq.uniform[slot]:resize(0) end
    eq.assigned_items:resize(0)
    eq.backpack, eq.flask, eq.quiver = -1, -1, -1   -- no field kit (see supplies below)
    for _, inv in ipairs(unit.inventory) do
        local slot = EQUIPPED_MODE[inv.mode] and UNIFORM_SLOT[inv.item:getType()]
        if slot then
            local it = inv.item
            local spec = df.squad_uniform_spec:new()
            spec.item = -1                          -- not a specific-item request...
            spec.item_type = it:getType()
            spec.item_subtype = it:getSubtype()
            spec.material_class = -1
            spec.mattype = it:getMaterial()
            spec.matindex = it:getMaterialIndex()
            spec.color = -1
            spec.assigned:insert('#', it.id)        -- ...the held item already satisfies it
            eq.uniform[slot]:insert('#', spec)
            eq.assigned_items:insert('#', it.id)
        end
    end
end

-- one "Conscription N" squad: a fresh militia-captain assignment with `captain_unit`
-- appointed + seated in pos 0, and `member_ids` filling pos 1-9. (makeSquad/addToSquad
-- won't touch pos 0, so we seat the leader by hand; the appointment is what lists it.)
local function make_conscription_squad(ent, captain_unit, member_ids)
    local pos_id, pidx = militia_captain_position(ent)
    if not pos_id then return nil end
    local aid = ent.positions.next_assignment_id
    ent.positions.next_assignment_id = aid + 1
    ent.positions.assignments:insert('#', {new = df.entity_position_assignment,
        id = aid, position_id = pos_id, position_vector_idx = pidx,
        histfig = -1, histfig2 = -1, squad_id = -1, st_id = -1, ab_id = -1,
        vassal_of_entity_id = -1, vassal_of_position_profile_id = -1,
        assigned_army_controller_id = -1, temp = 0})
    local aidx
    for i = 0, #ent.positions.assignments - 1 do
        if ent.positions.assignments[i].id == aid then aidx = i; break end
    end
    appoint(ent, ent.positions.assignments[aidx], aidx, captain_unit.hist_figure_id)
    local sq = dfhack.military.makeSquad(aid)
    if not sq then    -- couldn't make it: undo the appointment + assignment
        vacate(ent, ent.positions.assignments[aidx])
        for i = #ent.positions.assignments - 1, 0, -1 do
            if ent.positions.assignments[i].id == aid then ent.positions.assignments:erase(i) end
        end
        return nil
    end
    sq.alias = CONSCRIPT_TAG     -- index prefix added by apply_pending_select once listed
    -- no field kit: carry no food/water, so conscripts never fetch a backpack or flask
    sq.supplies.carry_food = 0
    sq.supplies.carry_water = df.squad_water_level_type.NoWater
    -- put them on the fort's "Ready" schedule immediately (its index is shared by every
    -- squad's routine list), so they stand ready instead of defaulting to off-duty/training
    local routines = df.global.plotinfo.alerts.routines
    for i = 0, #routines - 1 do
        if routines[i].name == 'Ready' and i < #sq.schedule.routine then
            sq.cur_routine_idx = i; break
        end
    end
    sq.positions[0].occupant = captain_unit.hist_figure_id   -- seat the captain by hand
    captain_unit.military.squad_id = sq.id
    captain_unit.military.squad_position = 0
    match_uniform_to_inventory(sq.positions[0], captain_unit)
    for i, uid in ipairs(member_ids) do
        dfhack.military.addToSquad(uid, sq.id, i)         -- pos 1..9
        local u = df.unit.find(uid)
        if u then match_uniform_to_inventory(sq.positions[i], u) end
    end
    return sq
end

-- drag a box over civilians: draft them into new Conscription squads (one per 10 -- a
-- captain plus 9), then queue those squads to be selected. Returns the new squad ids.
local function conscript_box(p1, p2)
    local civs = civilians_in_box(p1, p2)
    if #civs == 0 then return false end
    local ent = fort_entity()
    local made = {}
    local idx = 1
    while idx <= #civs do
        local captain = df.unit.find(civs[idx]); idx = idx + 1
        local members = {}
        while idx <= #civs and #members < CONSCRIPTS_PER_SQUAD - 1 do
            members[#members + 1] = civs[idx]; idx = idx + 1
        end
        local sq = make_conscription_squad(ent, captain, members)
        if not sq then break end
        made[#made + 1] = sq.id
    end
    if #made > 0 then pending_select = made end
    return #made > 0
end

-- a drag-box over dwarves (no hostiles): decide what it selects.
--   * several squads represented -> select those whole squads (top-level)
--   * exactly one squad -> the WHOLE squad if every member is boxed (DF's squad view),
--     else just the boxed members (the individual-order member view)
--   * no squadded dwarves at all -> draft the loose civilians (the conscription gesture)
-- Returns 'select' (pure selection) or 'conscript' (drafted civilians) or nil (nothing).
function box_select(ui, p1, p2)
    local by_squad = dwarves_in_box(p1, p2)
    local sids = {}
    for sid in pairs(by_squad) do sids[#sids + 1] = sid end
    if #sids == 0 then
        return conscript_box(p1, p2) and 'conscript' or nil
    end
    if #sids > 1 then
        local want = {}
        for _, sid in ipairs(sids) do want[sid] = true end
        select_squads(ui, want)
        return 'select'
    end
    local sid = sids[1]
    local sq = df.squad.find(sid)
    if not sq then return nil end
    if #by_squad[sid] >= squad_member_count(sq) then   -- whole squad boxed
        select_squads(ui, {[sid] = true})
    else
        select_individuals(ui, sid, by_squad[sid])
    end
    return 'select'
end

-- select exactly the just-conscripted squads, once the panel lists them (we trigger
-- the rebuild with refresh_squad_list, which can take a frame to land)
local function apply_pending_select(SQ)
    if not pending_select then return end
    local present = {}
    for i = 0, #SQ.squad_id - 1 do present[SQ.squad_id[i]] = true end
    for _, id in ipairs(pending_select) do if not present[id] then return end end
    local want = {}
    for _, id in ipairs(pending_select) do want[id] = true end
    local n = math.min(#SQ.squad_id, #SQ.squad_selected)   -- never read past either array
    for i = 0, n - 1 do SQ.squad_selected[i] = want[SQ.squad_id[i]] or false end
    -- prefix each new squad's name with its 1-based slot in the list (matches its 1-9
    -- hotkey); idempotent via stripping any existing "N. " so a re-run won't stack numbers
    for i = 0, #SQ.squad_id - 1 do
        if want[SQ.squad_id[i]] then
            local s = df.squad.find(SQ.squad_id[i])
            if s then s.alias = (i + 1) .. '. ' .. (tostring(s.alias):gsub('^%d+%. ', '')) end
        end
    end
    pending_select = nil
end

-- feed DF the real squads-panel key twice (close+reopen) so it rebuilds the squad list
-- -- flag-toggling sq.open does NOT run that logic. Synchronous, so onupdate never sees
-- the close (no spurious disband).
local function refresh_squad_list()
    local scr = dfhack.gui.getDFViewscreen(true)
    gui.simulateInput(scr, 'D_SQUADS')
    gui.simulateInput(scr, 'D_SQUADS')
end

-- disband every Conscription squad (found by alias, so it survives a script reload):
-- free the members, vacate + drop the minted captain assignment, delete the squad.
local function disband_conscription_squads()
    local ent = fort_entity()
    local all = df.global.world.squads.all
    for i = #all - 1, 0, -1 do
        local s = all[i]
        if s.entity_id == ent.id and tostring(s.alias):find(CONSCRIPT_TAG, 1, true) then
            local sid = s.id
            for p = 0, #s.positions - 1 do
                local occ = s.positions[p].occupant
                if occ ~= -1 then
                    local hf = df.historical_figure.find(occ)
                    if hf and hf.unit_id >= 0 then
                        local u = df.unit.find(hf.unit_id)
                        if u then u.military.squad_id, u.military.squad_position = -1, -1 end
                    end
                    s.positions[p].occupant = -1
                end
            end
            for k = 0, #ent.positions.assignments - 1 do
                if ent.positions.assignments[k].squad_id == sid then vacate(ent, ent.positions.assignments[k]) end
            end
            for k = #ent.squads - 1, 0, -1 do if ent.squads[k] == sid then ent.squads:erase(k) end end
            for k = #all - 1, 0, -1 do if all[k].id == sid then all:erase(k) end end
            for k = #ent.positions.assignments - 1, 0, -1 do
                if ent.positions.assignments[k].squad_id == sid then ent.positions.assignments:erase(k) end
            end
            s:delete()
        end
    end
    pending_select = nil
end

DwarfRtsClickMove = defclass(DwarfRtsClickMove, overlay.OverlayWidget)
DwarfRtsClickMove.ATTRS{
    desc = 'Squads screen: click to move/attack/select, drag to select squads/members, keys 1-9 pick a squad, select-all on open.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    -- whole fort mode, so onupdate sees the panel both open AND close (a
    -- Squads-only binding stalls the instant focus shifts off it)
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function DwarfRtsClickMove:overlay_onupdate()
    -- a portrait was clicked last frame: DF has now set the sheet's active unit, so
    -- follow it (DF's own follow mechanism; manual scrolling releases it natively)
    if self.follow_pending then
        self.follow_pending = nil
        -- DF has now opened the portrait's unit info page and set its active unit.
        -- (DF also zeroes follow_unit whenever it opens the sheet, which is why we
        -- compare against follow_before -- captured in onInput, pre-click.)
        local uid = df.global.game.main_interface.view_sheets.active_id
        local u = uid and uid >= 0 and df.unit.find(uid)
        if u and not dfhack.units.isDead(u) then
            df.global.plotinfo.follow_unit = uid       -- follow in both cases (DF zeroed it on open)
            if self.follow_before ~= uid then
                -- first click: close the page back out, so the click reads as
                -- "follow", not "open sheet"
                dfhack.timeout(1, 'frames', close_unit_sheet)
            end
            -- second click (already following this unit): leave the info page open
            -- AND keep following it
        end
    end

    -- a squads sub-screen (equipment / schedule) is up: disable all handling. Drop any
    -- in-flight drag and resync the button poller so nothing fires when it closes, then
    -- leave prev_open untouched -- when the sub-screen closes, squads.open returns to its
    -- prior value with no spurious open/close edge.
    if squad_subscreen_open() then
        self.press, self.press_ok = nil, false
        self.lbut_down = df.global.enabler.mouse_lbut_down
        return
    end

    local sq = squads_ui()
    local open = sq.open

    if open and not self.prev_open then
        -- panel just opened: RTS select-all, unless a conscription selection is pending
        if not pending_select then
            for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = true end
        end
    elseif (not open) and self.prev_open then
        -- panel just closed: if anything is still selected (a squad, or members in the
        -- expanded member view), veto the close and drop the selection instead (a second
        -- close, nothing selected now, goes through)
        if self.armed_close then
            sq.open = true
            for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = false end
            sq.viewing_squad_index = -1            -- collapse the member view too
            sq.squad_hfid_selected:resize(0)
            open = true
        else
            clear_all_orders(sq)            -- close goes through: stand every squad down
            disband_conscription_squads()   -- ...and disband any temp Conscription squads
        end
    end

    if open then
        apply_pending_select(sq)
        -- any selection (whole-squad or individual members) vetoes the first close
        self.armed_close = has_selection(sq) or has_indiv_selection(sq)
    else
        self.armed_close = false
    end
    self.prev_open = open

    -- All left-button map commands resolve on mouse-UP, so a drag is cleanly told
    -- apart from a click (nothing fires on press). We poll the raw button each frame
    -- (press 0->1 records the start; release 1->0 acts): same start/end tile is a
    -- click (move, or attack the unit there); a real box is a drag (attack every
    -- hostile inside it). Press is gated to a genuine map press (squad selected, not
    -- on a button, left of the right-side window) so panels never command squads.
    local down = df.global.enabler.mouse_lbut_down
    if down == 1 and self.lbut_down ~= 1 then              -- press
        self.press = dfhack.gui.getMousePos(true)
        self.press_ok = open and not busy(sq)
            -- a selection is NOT required: a drag still selects/conscripts, and a click
            -- dispatches the normal action (move/attack/select-own-unit) on mouse-up
            -- ONLY the main squads screen -- never the equip/schedule sub-screens,
            -- whose buttons would otherwise queue station/attack commands
            and dfhack.gui.getCurFocus(true)[1] == 'dwarfmode/Squads/Default'
            and df.global.game.main_interface.current_hover == -1
            and df.global.gps.mouse_x < df.global.gps.dimx - WINDOW_COLS
            and not over_other_overlay(df.global.gps.mouse_x, df.global.gps.mouse_y)
    elseif down ~= 1 and self.lbut_down == 1 then          -- release
        local rel = dfhack.gui.getMousePos(true)
        if self.press_ok and self.press and rel then
            local shift = dfhack.internal.getModifiers().shift
            local acted   -- 'conscript' if a civilian was drafted (needs a list refresh)
            if same_tile(self.press, rel) then
                -- NOT a drag -- it's a plain click. We swallowed the press so DF didn't act
                -- mid-gesture; now re-dispatch it as a normal left-click so the game gets it
                -- and you can select squads / units / anything under the cursor as usual.
                -- (self.passthrough tells onInput not to re-swallow this synthetic click.)
                self.passthrough = true
                gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
                self.passthrough = false
            elseif box_attack(sq, self.press, rel, shift) == 0 then
                -- a drag that hit no hostiles is a SELECTION gesture: pick the boxed
                -- squads / members (box_select), or -- if it covers only loose civilians
                -- -- draft them, then (deferred) trigger the real list refresh so
                -- apply_pending_select can select the new Conscription squads.
                acted = box_select(sq, self.press, rel)
            end
            if acted == 'conscript' then
                dfhack.timeout(1, 'frames', refresh_squad_list)
            end
        end
        self.press = nil
    end
    self.lbut_down = down
end

function DwarfRtsClickMove:onInput(keys)
    -- a squads sub-screen (equipment / schedule) is up: stay out of it entirely so its
    -- buttons and the uniform/schedule editors work normally
    if squad_subscreen_open() then return false end

    local sq = squads_ui()
    local top = dfhack.gui.getCurFocus(true)[1] or ''

    -- window closed: a right-click in the right-edge band opens it. Gated to plain
    -- map view so we don't swallow right-clicks meant for some other open panel.
    if not sq.open then
        if keys._MOUSE_R and not busy(sq)
            and df.global.gps.mouse_x >= df.global.gps.dimx - WINDOW_COLS
            and top == 'dwarfmode/Default'
        then
            sq.open = true                             -- onupdate's open edge selects all
            return true
        end
        return false
    end

    -- the squads panel is open but another menu sits on top of it (e.g. the unit
    -- info page from a portrait click): stay out of the way, so a right-click closes
    -- THAT menu rather than toggling the squad window.
    if top ~= 'dwarfmode/Squads/Default' then return false end

    if busy(sq) then return false end
    local on_ui = df.global.game.main_interface.current_hover ~= -1

    -- keyboard 1-9: select that squad in the panel's list (1 = first). If the squad was
    -- ALREADY the sole selection, the press instead centers + camera-follows its members
    -- (leader on the first such press, the next member on each subsequent one, wrapping).
    -- So pressing the key of an unselected squad only selects it -- it never recenters.
    for n = 1, 9 do
        if keys[('STRING_A%03d'):format(48 + n)] then
            local idx = n - 1
            if idx < #sq.squad_id then
                local sid = sq.squad_id[idx]
                if only_selected_squad(sq) == idx then
                    -- already the active selection: cycle the camera through its members
                    local s = df.squad.find(sid)
                    local members = {}
                    for p = 0, s and #s.positions - 1 or -1 do
                        local hf = df.historical_figure.find(s.positions[p].occupant)
                        local u = hf and df.unit.find(hf.unit_id)
                        if u and not dfhack.units.isDead(u) then members[#members + 1] = u end
                    end
                    if #members > 0 then
                        if self.follow_sid == sid then
                            self.follow_i = (self.follow_i % #members) + 1   -- next, wrapping
                        else
                            self.follow_sid, self.follow_i = sid, 1           -- start at leader
                        end
                        local u = members[self.follow_i]
                        df.global.plotinfo.follow_unit = u.id                 -- keep following
                        guidm.Viewport.get():centerOn(u.pos):set()           -- center now
                    end
                else
                    select_squads(sq, {[sid] = true})   -- not selected yet: just select it
                    self.follow_sid = nil               -- next press (now sole) starts at leader
                end
            end
            return true                                -- consume the digit either way
        end
    end

    if keys._MOUSE_R then
        -- right-click inside the right-anchored military window: attempt to close it
        -- (the close-guard in onupdate then vetoes/deselects or closes+stands down)
        if df.global.gps.mouse_x >= df.global.gps.dimx - WINDOW_COLS then
            sq.open = false
            return true
        end
        -- right-click on the map: leave it to DF (backs out the member view / closes the
        -- panel via the close-guard). It no longer cycles the squad selection.
        return false
    end

    -- left-click a unit-portrait ("View ... sheet.") button -> camera-follow that
    -- unit. We let the click through so DF sets view_sheets.active_id to the
    -- portrait's unit, then pick it up next frame (see overlay_onupdate).
    if keys._MOUSE_L and on_ui then
        local tip = hover_tooltip(df.global.game.main_interface.current_hover)
        if tip and tip:match('^View .* sheet') then
            self.follow_pending = true
            self.follow_before = df.global.plotinfo.follow_unit  -- pre-click follow state
        end
        return false                                   -- UI button: let DF handle the click
    end

    -- our own re-dispatched plain click (from the mouse-up handler): let it through so the
    -- game actually receives it, instead of swallowing it again.
    if self.passthrough then return false end

    -- Map left-clicks (drag/select) resolve on mouse-UP via the button poller in
    -- overlay_onupdate. Swallow the press so DF doesn't act on whatever is under the cursor
    -- mid-gesture (open a stockpile/pedestal/building menu); the raw button state we poll is
    -- unaffected by consuming here. A drag is a box select/attack; a plain click is
    -- re-dispatched as a normal click on mouse-up so selection works. We do NOT swallow
    -- clicks landing on another visible overlay (e.g. the notifications list).
    if keys._MOUSE_L
        and df.global.gps.mouse_x < df.global.gps.dimx - WINDOW_COLS
        and not over_other_overlay(df.global.gps.mouse_x, df.global.gps.mouse_y)
    then
        return true
    end
    return false
end

-- ---- drag selection box (visual feedback) ---------------------------------------
-- We must draw on the MAP grid, not the text/UI grid: graphical map tiles are a
-- different size, so a text-grid paint comes out scaled. The map-aware path is the
-- Viewport (map tile -> on-map screen tile) plus paintTile(..., map=true), exactly as
-- guidm.renderMapOverlay does. The WxH readout stays on the text grid by the cursor.
-- The outline is colored by what the drag will do, mirroring the action precedence:
-- red = enemies in the box (attack), blue = own dwarves (select/conscript), white = no
-- valid target.
local BOX_CH = 250   -- CP437 small centered dot (the ASCII-mode fallback glyph)
-- Per-outcome graphics so the drag self-describes: friendly CURSORS(4,22) for selecting
-- your dwarves, attack STOCKPILE_ICONS_SIGNLESS(0,16) for hostiles, empty CURSORS(1,22);
-- selected units use CURSORS(4,23). fg is only the ASCII-mode glyph color (the tile
-- carries its own art); keep_lower leaves the map tile visible underneath.
local function marker_pen(color, page, tx, ty)
    return dfhack.pen.parse{ch = BOX_CH, fg = color, keep_lower = true,
                            tile = dfhack.screen.findGraphicsTile(page, tx, ty)}
end
local SELECT_PEN = marker_pen(COLOR_LIGHTGREEN, 'CURSORS', 4, 23)        -- selected units
local BOX_PENS = {
    enemy = marker_pen(COLOR_LIGHTRED,  'STOCKPILE_ICONS_SIGNLESS', 0, 16),  -- attack
    ally  = marker_pen(COLOR_LIGHTBLUE, 'CURSORS', 4, 22),               -- friendly
    none  = marker_pen(COLOR_WHITE,     'CURSORS', 1, 22),               -- empty
}
local DIM_PEN = {fg = COLOR_WHITE, bg = COLOR_BLACK}

-- what would this box act on? enemies (within +/-3 z, as box_attack) win over our own
-- adult dwarves (exact z, as the select/conscript scans); neither -> nothing.
local function classify_box(p1, p2)
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local ze1, ze2 = p1.z - 3, p1.z + 3
    local za1, za2 = math.min(p1.z, p2.z), math.max(p1.z, p2.z)
    local ally = false
    for _, u in ipairs(df.global.world.units.active) do
        local p = u.pos
        if p.x >= x1 and p.x <= x2 and p.y >= y1 and p.y <= y2 then
            if p.z >= ze1 and p.z <= ze2 and is_enemy(u) then
                return 'enemy'                  -- attack takes priority over selection
            end
            if not ally and p.z >= za1 and p.z <= za2
                and dfhack.units.isCitizen(u) and dfhack.units.isActive(u)
                and not dfhack.units.isDead(u) and dfhack.units.isAdult(u)
            then ally = true end
        end
    end
    return ally and 'ally' or 'none'
end

local function draw_drag_box(p1, p2, pen)
    local vp = guidm.Viewport.get()
    local z = df.global.window_z
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local function paint(mx, my)
        local pos = xyz2pos(mx, my, z)
        if vp:isVisible(pos) then
            local s = vp:tileToScreen(pos)
            dfhack.screen.paintTile(pen, s.x, s.y, nil, nil, true)
        end
    end
    paint(x1, y1); paint(x2, y1); paint(x1, y2); paint(x2, y2)   -- 4 corners only
    local label = ('%dx%d'):format(x2 - x1 + 1, y2 - y1 + 1)
    local lx = math.max(0, math.min(df.global.gps.mouse_x + 2, df.global.gps.dimx - #label))
    dfhack.screen.paintString(DIM_PEN, lx, df.global.gps.mouse_y, label)
end

-- units currently selected on the squads screen: the highlighted members in member
-- view, else every member of every selected squad
local function selected_units(ui)
    local out = {}
    local function add(occ)
        if occ and occ >= 0 then
            local hf = df.historical_figure.find(occ)
            local u = hf and df.unit.find(hf.unit_id)
            if u then out[#out + 1] = u end
        end
    end
    if has_indiv_selection(ui) then
        for _, pos in ipairs(selected_positions(ui)) do add(pos.occupant) end
    else
        for i = 0, #ui.squad_selected - 1 do
            if ui.squad_selected[i] then
                local s = df.squad.find(ui.squad_id[i])
                if s then for p = 0, #s.positions - 1 do add(s.positions[p].occupant) end end
            end
        end
    end
    return out
end

function DwarfRtsClickMove:render(dc)
    DwarfRtsClickMove.super.render(self, dc)
    if squad_subscreen_open() then return end   -- don't paint over the equipment/schedule screen
    local sq = squads_ui()
    if not sq.open then return end
    local vp = guidm.Viewport.get()
    local z = df.global.window_z
    -- outline every currently-selected member (the existing selection art), so you can
    -- see your selection on the map at a glance
    for _, u in ipairs(selected_units(sq)) do
        local p = u.pos
        if p.z == z then
            local pos = xyz2pos(p.x, p.y, p.z)
            if vp:isVisible(pos) then
                local s = vp:tileToScreen(pos)
                dfhack.screen.paintTile(SELECT_PEN, s.x, s.y, nil, nil, true)
            end
        end
    end
    -- the live drag box (press recorded, button still held); press_ok already confined
    -- the press to the squads map area
    if self.press_ok and self.press and self.lbut_down == 1 then
        local cur = dfhack.gui.getMousePos(true)
        if cur and cur.z == self.press.z and not same_tile(self.press, cur) then
            draw_drag_box(self.press, cur, BOX_PENS[classify_box(self.press, cur)])
        end
    end
end

OVERLAY_WIDGETS = {clickmove = DwarfRtsClickMove}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dwarf-rts: click move/attack/select, drag-select, keys 1-9, select-all + close-guard active')
