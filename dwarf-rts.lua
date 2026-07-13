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
    frame), so a click is cleanly told apart from a drag and nothing fires on press.
      - A DRAG (a box) always acts, selected or not. SELECTING YOUR OWN takes priority: if the
        box holds any of your dwarves it's a selection/conscription gesture (below); only a box
        with NONE of your own orders the selection to attack every hostile inside within +/-3
        z-levels (Shift+drag folds them into the current kill order). You can always attack by
        boxing from a tile/z-level with no allies in it.
      - A PLAIN CLICK (no tile change between press and release) depends on selection:
        with a squad/member SELECTED it commands -- ATTACKS a hostile on that tile (Shift
        appends), else SELECTS your own dwarf under the cursor, else MOVES there. With
        NOTHING selected it is forwarded to the game as a normal click, so you can select
        squads/units/UI exactly as without the overlay.
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
  * Drag a box over your own DWARVES to select them -- takes priority even with hostiles in
    the box (`box_select`):
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

-- squad ids DFHack's autotraining tool is currently driving (active only), read from its
-- persisted site data (keys are stored as strings, so coerce back to numbers). These squads
-- are only rostered to train, so the RTS select-all leaves them out.
local function autotraining_squads()
    local set = {}
    local d = dfhack.persistent.getSiteData('autotraining')
    if d and d.training_squads then
        for k, active in pairs(d.training_squads) do
            if active then set[tonumber(k)] = true end
        end
    end
    return set
end

-- Is this a civilian-militia squad (a "Civilian - *" uniform)? DFHack exposes no squad->uniform
-- name link, so -- matching military-uniforms/military-labor -- we detect it by the body slot:
-- a civilian uniform wears LEATHER body armour with NO metal breastplate / mail shirt, while every
-- military uniform has a metal breastplate. Like autotraining squads, these are left out of the
-- RTS select-all (they're a shelter-in-place militia, not a strike force).
local function is_civilian_squad(sid)
    local sq = df.squad.find(sid)
    if not sq then return false end
    for p = 0, #sq.positions - 1 do
        local body = sq.positions[p].equipment.uniform[0]
        local has_armor, has_metal = false, false
        for j = 0, #body - 1 do
            if body[j].item_type == df.item_type.ARMOR then
                has_armor = true
                if body[j].mattype == 0 then has_metal = true end
            end
        end
        if has_armor and not has_metal then return true end   -- leather body, no metal -> civilian
    end
    return false
end

-- Order the squads panel: non-civilian (real military) squads first, then civilian-militia squads,
-- then autotraining squads last (an autotraining squad goes last even if it's civilian). Stable
-- within each group. The panel is drawn from main_interface.squads.squad_id, which DF REBUILDS (in
-- squad-id order) every time the panel opens -- it does NOT read the entity's squad list -- so this
-- re-pin has to run on each open, AFTER that rebuild (reordering while closed just gets wiped on the
-- next open). squad_selected is permuted in lockstep so selections stay aligned. No-op once ordered.
local function reorder_squad_list(ui)
    local training = autotraining_squads()
    local n = #ui.squad_id
    local mil, civ, at = {}, {}, {}          -- military, civilian, autotraining -- each of {id, sel}
    for i = 0, n - 1 do
        local id = ui.squad_id[i]
        local e = {id = id, sel = ui.squad_selected[i]}
        if training[id] then at[#at + 1] = e
        elseif is_civilian_squad(id) then civ[#civ + 1] = e
        else mil[#mil + 1] = e end
    end
    local ordered = {}
    for _, e in ipairs(mil) do ordered[#ordered + 1] = e end
    for _, e in ipairs(civ) do ordered[#ordered + 1] = e end
    for _, e in ipairs(at)  do ordered[#ordered + 1] = e end
    local changed = false
    for i = 0, n - 1 do if ui.squad_id[i] ~= ordered[i + 1].id then changed = true; break end end
    if not changed then return false end          -- already in the desired order
    for i = 0, n - 1 do ui.squad_id[i] = ordered[i + 1].id; ui.squad_selected[i] = ordered[i + 1].sel end
    return true
end

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

-- GENERAL "is this click meant for the map (not any UI)?" test -- the single guard every
-- map-interaction feature here should use. The load-bearing part is the STRICT
-- dfhack.gui.getMousePos() (no arg): it returns a tile ONLY when the cursor is over the
-- exposed map viewport, and nil over ANY UI -- the bottom toolbar, the minimap, a right-side
-- panel, an open menu/list, a designation palette, everything. (The permissive
-- getMousePos(true) instead returns a map tile even under those, which is what caused clicks
-- on menus to fall through to the scripts.) We additionally stand off DF hover elements
-- (current_hover) and any OTHER DFHack overlay (notifications, etc.) that draws over the map
-- without blocking the viewport. Works for any UI element, present or future.
--   Returns the map pos when the click is on the map, or nil when it's on UI (pass it through).
-- the protected notification/alert area (same as dig-shapes' never-mine zone): the left
-- 2 columns everywhere + the top-left 4x4 corner, where DF's notification icons and
-- alerts live -- or the cursor over a native alert. Military-screen clicks (left OR
-- right) are ignored here so notifications and alerts are always usable.
local function over_notification_area(mx, my)
    if df.global.game.main_interface.current_hover_alert then return true end
    return mx < 2 or (mx < 4 and my < 4)
end

local function map_pos_if_clear(mx, my)
    local pos = dfhack.gui.getMousePos()               -- strict: nil over any UI
    if not pos then return nil end
    local m = df.global.game.main_interface
    if m.current_hover ~= -1 then return nil end       -- DF hover element
    if over_notification_area(mx, my) then return nil end
    -- DF sets current_hover_left_x to the left edge of whatever UI element the cursor is
    -- over (the alert reads 4); it stays 0 over the open map. Non-zero => over UI.
    if m.current_hover_left_x ~= 0 then return nil end
    if over_other_overlay(mx, my) then return nil end  -- another DFHack overlay (e.g. notify)
    return pos
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

-- a live, visible FRIENDLY (non-enemy) unit on a map tile: your own dwarves/pets, or a visiting
-- merchant/diplomat -- anything you'd want to click to inspect rather than command. A mousedown on
-- one is forwarded to DF (so its info/selection opens) instead of becoming an RTS move/attack/drag.
local function allied_at(pos)
    local U = df.global.world.units.active
    for i = 0, #U - 1 do
        local u = U[i]
        if u.pos.x == pos.x and u.pos.y == pos.y and u.pos.z == pos.z
            and not dfhack.units.isDead(u) and not dfhack.units.isHidden(u) and not is_enemy(u) then
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

-- ---- notification group-kill: shift-click a vanilla "N invaders/hostiles/agitated animals" --
--
-- DFHack's gui/notify list (internal/notify/notifications) shows "N agitated animals", "N
-- invaders", "N hostiles". Normally a click zooms to the next unit in the group; a SHIFT-click
-- zooms to the PREVIOUS one. We repurpose the shift-click: with squads selected, it orders every
-- selected squad to kill EVERY unit in that group. Predicates mirror the vanilla for_* iterators
-- so we target exactly the units the count is counting; with no squads selected we fall through
-- to the vanilla behavior.
local function pred_agitated(u)
    return not dfhack.units.isDead(u) and dfhack.units.isActive(u)
        and not u.flags1.caged and not u.flags1.chained and dfhack.units.isAgitated(u)
end
local function pred_invader(u)
    return not dfhack.units.isDead(u) and dfhack.units.isActive(u)
        and not u.flags1.caged and not u.flags1.chained
        and dfhack.units.isInvader(u) and not dfhack.units.isHidden(u)
end
local function pred_hostile(u)
    return not dfhack.units.isDead(u) and dfhack.units.isActive(u)
        and not u.flags1.caged and not u.flags1.chained
        and not dfhack.units.isInvader(u) and not dfhack.units.isFortControlled(u)
        and not dfhack.units.isHidden(u) and not dfhack.units.isAgitated(u)
        and dfhack.units.isDanger(u)
end

local function group_unit_ids(pred)
    local ids = {}
    for _, u in ipairs(df.global.world.units.active) do
        if pred(u) then ids[#ids + 1] = u.id end
    end
    return ids
end

-- The vanilla notifications live only on the main map (dwarfmode/Default), where the squads
-- panel is shut -- and closing that panel deselects everything (the deliberate "are you sure"
-- close). So we remember the selection you had when you LEFT the squads screen, and command
-- that from the map. `last_selection` is that remembered set of squad ids (captured in the
-- close-guard below). The live on-screen selection still wins if there is one.
local last_selection = nil   -- captured by the overlay close-guard (defined later in this chunk)

local function effective_selected_squad_ids()
    local ui = squads_ui()
    local ids = {}
    for i = 0, #ui.squad_selected - 1 do
        if ui.squad_selected[i] then ids[#ids + 1] = ui.squad_id[i] end
    end
    if #ids > 0 then return ids end
    return last_selection or {}
end

-- order every selected squad (live selection, else the one remembered from the squads screen)
-- to kill all of `ids`, a fresh order each. Returns the number of squads commanded.
local function order_selected_kill_group(ids)
    local n = 0
    for _, sid in ipairs(effective_selected_squad_ids()) do
        local s = df.squad.find(sid)
        if s then squad_kill(s, ids, false); n = n + 1 end
    end
    return n
end

-- Shared hook for the pack's OWN notify scripts (enemies-inside, agitated-typed) to reuse the
-- same shift-click-with-squads-selected -> group-kill behavior as the wrapped vanilla ones,
-- WITHOUT the on_click-wrapping dance (those scripts re-register their on_click on every world
-- load, which would clobber a wrapper). They just call this on shift: given a list of unit ids,
-- order the effective-selected squads to kill them. Returns true when squads were selected (so
-- the caller consumes the shift-click), false when none are (caller falls through to zoom).
-- Lives on dfhack.internal so it survives across map loads; absent if the overlay isn't loaded.
function dfhack.internal.dwarf_rts_group_kill(ids)
    if #effective_selected_squad_ids() == 0 then return false end
    if ids and #ids > 0 then order_selected_kill_group(ids) end
    return true
end

local NOTIFY_PREDS = {
    agitated_count = pred_agitated,
    invader_count  = pred_invader,
    hostile_count  = pred_hostile,
}

-- wrap the three group notifications' on_click so a shift-click with squads selected commands
-- them onto the whole group. Idempotent, and re-applied on world/map load (the notify module
-- may be reloaded). Safe if the notify module isn't present.
local function register_notification_kills()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok or type(n) ~= 'table' or not n.NOTIFICATIONS_BY_NAME then return end
    for name, pred in pairs(NOTIFY_PREDS) do
        local entry = n.NOTIFICATIONS_BY_NAME[name]
        if entry and not entry.rts_group_kill then
            entry.rts_group_kill = true
            local orig = entry.on_click
            entry.on_click = function(state, shift)
                if shift and #effective_selected_squad_ids() > 0 then
                    local ids = group_unit_ids(pred)
                    if #ids > 0 then order_selected_kill_group(ids) end
                    return state   -- consumed: command the selected squads instead of zooming
                end
                return orig and orig(state, shift) or state
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
    -- countdown for the notification-click shield (armed in onInput when a click over the
    -- notification/alert area is passed through to DF)
    if self.notif_shield and self.notif_shield > 0 then
        self.notif_shield = self.notif_shield - 1
    end

    -- a portrait was clicked last frame: DF has now set the sheet's active unit, so
    -- follow it (DF's own follow mechanism; manual scrolling releases it natively).
    -- The info page the click opened stays open.
    if self.follow_pending then
        self.follow_pending = nil
        local uid = df.global.game.main_interface.view_sheets.active_id
        local u = uid and uid >= 0 and df.unit.find(uid)
        if u and not dfhack.units.isDead(u) then
            df.global.plotinfo.follow_unit = uid       -- follow (DF zeroed it on open)
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

    -- the panel was displaced by a designation tool (e.g. mining): reopen it as soon as
    -- the tool is put away. Keyed ONLY off the designation returning to NONE -- the same
    -- signal that armed the flag -- with no focus-string condition (the focus the frame
    -- the tool closes is not reliably 'dwarfmode/Default').
    local reopened = false
    if self.reopen_after_designation and not open then
        if df.global.game.main_interface.main_designation_selected == df.main_designation_type.NONE then
            self.reopen_after_designation = nil
            sq.open = true
            open = true
            reopened = true
        end
    elseif open then
        self.reopen_after_designation = nil
    end

    if open and not self.prev_open then
        -- panel just opened: DF has just (re)built squad_id in id order, so re-pin the list now
        -- (military, then civilian, then autotraining), before the frame renders.
        reorder_squad_list(sq)
        if reopened then
            -- reopened after a designation tool: come back with NOTHING selected, so a map
            -- click doesn't immediately read as a squad command
            for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = false end
            sq.viewing_squad_index = -1
            sq.squad_hfid_selected:resize(0)
        -- RTS select-all, unless a conscription selection is pending. Autotraining AND
        -- civilian-militia squads are excluded -- they're rostered to train or to shelter, not
        -- to be commanded as a strike force by default.
        elseif not pending_select then
            local training = autotraining_squads()
            for i = 0, #sq.squad_selected - 1 do
                local sid = sq.squad_id[i]
                sq.squad_selected[i] = not training[sid] and not is_civilian_squad(sid)
            end
        end
    elseif (not open) and self.prev_open then
        -- panel just closed: if anything is still selected (a squad, or members in the
        -- expanded member view), veto the close and drop the selection instead (a second
        -- close, nothing selected now, goes through)
        if df.global.game.main_interface.main_designation_selected ~= df.main_designation_type.NONE then
            -- the panel closed because the player switched to a map designation tool (e.g. the
            -- dig-helper entering mining from the squads screen): that's not a stand-down, so
            -- leave squad orders, selections and any temp squads intact -- and reopen the
            -- panel once the tool is put away.
            self.reopen_after_designation = true
        elseif self.notif_shield and self.notif_shield > 0 then
            -- the close came from a click that was really aimed at a notification/alert (we
            -- passed it through so DF could activate/dismiss it): not a stand-down. Put the
            -- panel straight back, orders and selection intact.
            sq.open = true
            open = true
        elseif self.armed_close then
            -- remember the selection you're leaving with, so a main-map notification group-kill
            -- can still command these squads after the panel deselects + closes
            last_selection = {}
            for i = 0, #sq.squad_selected - 1 do
                if sq.squad_selected[i] then last_selection[#last_selection + 1] = sq.squad_id[i] end
            end
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
        -- a press that lands on a FRIENDLY unit is forwarded to DF as a plain click (select/open
        -- that unit) and never becomes an RTS command or drag box -- decided once, here on press
        self.press_allied = self.press ~= nil and allied_at(self.press) ~= nil
        self.press_ok = open and not busy(sq)
            -- never while a designation tool is active (mining runs with the panel open)
            and df.global.game.main_interface.main_designation_selected == df.main_designation_type.NONE
            -- We always poll on the squads map (so a DRAG box works whether or not anything
            -- is selected). A plain click only commands when something is selected; with
            -- nothing selected it's forwarded to the game as a normal click (see release).
            -- ONLY the main squads screen -- never the equip/schedule sub-screens, whose
            -- buttons would otherwise queue station/attack commands
            and dfhack.gui.getCurFocus(true)[1] == 'dwarfmode/Squads/Default'
            and df.global.gps.mouse_x < df.global.gps.dimx - WINDOW_COLS
            -- general UI guard: strict getMousePos is nil over ANY menu/panel/toolbar, so a
            -- press on any UI element (not just the ones we used to special-case) is ignored
            and map_pos_if_clear(df.global.gps.mouse_x, df.global.gps.mouse_y) ~= nil
    elseif down ~= 1 and self.lbut_down == 1 then          -- release
        local rel = dfhack.gui.getMousePos(true)
        if self.press_ok and self.press and rel then
            local shift = dfhack.internal.getModifiers().shift
            local acted   -- 'conscript' if a civilian was drafted (needs a list refresh)
            if self.press_allied then
                -- gesture began on a friendly unit: forward it to DF (open/select that unit),
                -- never an RTS command or drag box (the press was swallowed; re-dispatch on up)
                self.passthrough = true
                gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
                self.passthrough = false
            elseif same_tile(self.press, rel) then
                -- a plain click (no drag). If a squad/member is selected, it's a command;
                -- if nothing is selected, forward it to the game as a normal click so you
                -- can select squads/units (the press was swallowed; re-dispatch on up).
                if has_selection(sq) or has_indiv_selection(sq) then
                    acted = single_command(sq, rel, shift)
                else
                    self.passthrough = true
                    gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
                    self.passthrough = false
                end
            else
                -- SELECT/CONSCRIPT takes priority over attacking: if the box holds any of your
                -- own dwarves (squadded members, whole squads, or loose civilians to draft), that
                -- wins -- you can always attack instead by boxing from a tile/z-level with no allies
                -- in it. Only a box with NO dwarves of yours falls through to a group attack.
                acted = box_select(sq, self.press, rel)
                if not acted then box_attack(sq, self.press, rel, shift) end
            end
            if acted == 'conscript' then
                dfhack.timeout(1, 'frames', refresh_squad_list)
            end
        end
        self.press, self.press_allied = nil, false
    end
    self.lbut_down = down
end

function DwarfRtsClickMove:onInput(keys)
    -- a squads sub-screen (equipment / schedule) is up: stay out of it entirely so its
    -- buttons and the uniform/schedule editors work normally
    if squad_subscreen_open() then return false end

    -- a designation tool is active (mining now runs with the squads panel still open): all
    -- map input belongs to the tool -- DF's box designation, right-click-cancel's helpers,
    -- dig-shapes' conversions -- so stand aside entirely until it's put away
    if df.global.game.main_interface.main_designation_selected ~= df.main_designation_type.NONE then
        return false
    end

    local sq = squads_ui()
    local top = dfhack.gui.getCurFocus(true)[1] or ''

    -- window closed: a right-click in the right-edge band opens it. Gated to plain
    -- map view so we don't swallow right-clicks meant for some other open panel.
    if not sq.open then
        if keys._MOUSE_R and not busy(sq)
            and df.global.gps.mouse_x >= df.global.gps.dimx - WINDOW_COLS
            and top == 'dwarfmode/Default'
        then
            -- Open the panel exactly as the native Squads button does: feed DF its own
            -- D_SQUADS key so it RUNS its open logic and (re)builds squad_id. Just flipping
            -- sq.open=true does NOT run that rebuild (the same reason refresh_squad_list has
            -- to re-key the panel), so the FIRST time -- before the panel has ever been
            -- opened natively, when squad_id is still empty -- a flag-flip opened a stale,
            -- empty panel with nothing to select. Deferred a frame (like refresh_squad_list)
            -- to avoid feeding input while we're mid-input. onupdate's open edge then
            -- selects-all / reorders as usual once sq.open flips true.
            dfhack.timeout(1, 'frames', function()
                gui.simulateInput(dfhack.gui.getDFViewscreen(true), 'D_SQUADS')
            end)
            return true                                -- consume the right-click that opened it
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

    -- a click (either button) over the notification/alert area belongs to DF -- left
    -- activates, right DISMISSES the notification -- so pass it through untouched. Shield
    -- the panel first: if DF's handling of that click also closes the squads panel (right
    -- click doubles as "back out"), the close-guard reopens it without a stand-down.
    if (keys._MOUSE_L or keys._MOUSE_R)
        and over_notification_area(df.global.gps.mouse_x, df.global.gps.mouse_y)
    then
        self.notif_shield = 3   -- update frames of close protection
        return false
    end

    if keys._MOUSE_R then
        -- right-click inside the right-anchored military window: attempt to close it (the
        -- close-guard in onupdate deselects on the first click, closes+stands down on the
        -- next). Closing the panel happens ONLY from here -- never from a map right-click.
        if df.global.gps.mouse_x >= df.global.gps.dimx - WINDOW_COLS then
            sq.open = false
            return true
        end
        -- right-click on the exposed map: the first click deselects every squad (and backs
        -- out the member view), with the panel staying open; a right-click with nothing
        -- selected enters mining -- also with the panel staying open.
        if map_pos_if_clear(df.global.gps.mouse_x, df.global.gps.mouse_y) then
            if has_selection(sq) or has_indiv_selection(sq) or sq.viewing_squad_index >= 0 then
                for i = 0, #sq.squad_selected - 1 do sq.squad_selected[i] = false end
                sq.viewing_squad_index = -1
                sq.squad_hfid_selected:resize(0)
            else
                df.global.game.main_interface.main_designation_selected =
                    df.main_designation_type.DIG_DIG
            end
            return true
        end
        -- right-click over some other UI element (toolbar, menu, another overlay): leave it to DF
        return false
    end

    -- left-click a unit-portrait ("View ... sheet.") button -> camera-follow that
    -- unit. We let the click through so DF sets view_sheets.active_id to the
    -- portrait's unit, then pick it up next frame (see overlay_onupdate).
    if keys._MOUSE_L and on_ui then
        local tip = hover_tooltip(df.global.game.main_interface.current_hover)
        if tip and tip:match('^View .* sheet') then
            self.follow_pending = true
        end
        return false                                   -- UI button: let DF handle the click
    end

    -- our own re-dispatched click (a plain click with nothing selected, from the mouse-up
    -- handler): let it through so the game actually receives it.
    if self.passthrough then return false end

    -- Map left-clicks resolve on mouse-UP via the button poller in overlay_onupdate; swallow
    -- the press so DF doesn't act mid-gesture (a drag must be told from a click first). A
    -- drag is always a box (select/attack); a plain click commands if a squad is selected,
    -- else it's forwarded to the game as a normal click on release. We never swallow clicks
    -- on another visible overlay (e.g. the notifications list).
    if keys._MOUSE_L
        and df.global.gps.mouse_x < df.global.gps.dimx - WINDOW_COLS
        -- general UI guard (same as the press poller): only swallow a press that lands on the
        -- exposed map, so a click on ANY menu/panel/toolbar reaches DF normally
        and map_pos_if_clear(df.global.gps.mouse_x, df.global.gps.mouse_y) ~= nil
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

-- what would this box act on? our own adult dwarves (exact z, as the select/conscript scans)
-- win over enemies (within +/-3 z, as box_attack) -- selecting allies takes priority, since you
-- can attack from a box with no allies in it; neither -> nothing.
local function classify_box(p1, p2)
    local x1, x2 = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local y1, y2 = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local ze1, ze2 = p1.z - 3, p1.z + 3
    local za1, za2 = math.min(p1.z, p2.z), math.max(p1.z, p2.z)
    local enemy = false
    for _, u in ipairs(df.global.world.units.active) do
        local p = u.pos
        if p.x >= x1 and p.x <= x2 and p.y >= y1 and p.y <= y2 then
            if p.z >= za1 and p.z <= za2
                and dfhack.units.isCitizen(u) and dfhack.units.isActive(u)
                and not dfhack.units.isDead(u) and dfhack.units.isAdult(u)
            then
                return 'ally'                   -- selection takes priority over attack
            end
            if not enemy and p.z >= ze1 and p.z <= ze2 and is_enemy(u) then enemy = true end
        end
    end
    return enemy and 'enemy' or 'none'
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
    -- the press to the squads map area. A press on a friendly unit forwards as a click, so it
    -- draws no drag box.
    if self.press_ok and self.press and self.lbut_down == 1 and not self.press_allied then
        local cur = dfhack.gui.getMousePos(true)
        if cur and cur.z == self.press.z and not same_tile(self.press, cur) then
            draw_drag_box(self.press, cur, BOX_PENS[classify_box(self.press, cur)])
        end
    end
end

OVERLAY_WIDGETS = {clickmove = DwarfRtsClickMove}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
-- explicitly turn the overlay ON. default_enabled only applies on first discovery; once an
-- `overlay disable` (e.g. `magnus-scripts disable`) has persisted an off state, rescan alone
-- won't bring it back -- so running `dwarf-rts` must re-enable it to be reliable.
dfhack.run_command('overlay', 'enable', 'dwarf-rts.clickmove')

-- hook the vanilla group notifications for shift-click group-kill, and re-hook whenever the
-- notify module may have been reloaded (new world / map load)
register_notification_kills()
dfhack.onStateChange.dwarf_rts_notify = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register_notification_kills() end
end

print('dwarf-rts: click move/attack/select, drag-select, keys 1-9, select-all + close-guard active')
print('  shift-click a "N invaders/hostiles/agitated animals" notification to send selected squads.')
