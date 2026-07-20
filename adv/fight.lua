-- Adventure mode: auto-fight designated creatures until they are dead.
--@module = true
--@enable = true
--[[
adv/fight

Designate creatures on the local map as kill targets; your adventurer then automatically
moves to and attacks them, turn by turn, until every designated target is dead.

    adv/fight <name>       target every creature matching <name> (race id or name,
                           case-insensitive substring: "goblin", "cave dragon", ...)
    adv/fight all          target EVERY creature in the area (party excluded)
    adv/fight status       what is still on the kill list
    adv/fight stop         stand down
    adv/fight              this help

RUNS AS AN OVERLAY. Adventure mode is turn-based and pauses waiting for your input, so a
plain frame-timer loop freezes exactly when it needs to act. An overlay's onupdate fires
every render frame -- including while paused -- so the hunt keeps driving. The framework
owns a single widget instance, so there are no zombie-loop leftovers from reloads either.

Each turn it picks the NEAREST living target and, edge-triggered to ONE input per turn:
  * DISTANT: centers the camera on the target (fixing the view to its z-level) and clicks
    its tile, so DF's OWN pathfinder travels there -- across z-levels, down ramps.
  * ADJACENT & ACTIVELY HOSTILE (isDanger): a single keyboard BUMP into it (native quick
    attack). Bumping only works on a creature that is fighting you.
  * ADJACENT/same-tile & PASSIVE (isDanger=false): bumping a non-hostile only SWAPS places,
    so it MUST be force-attacked through the menu. QUICK_ATTACK jumps straight to the
    body-part target list (skipping A_ATTACK's conflict-confirm + attack-type steps), then
    it clicks the first target ("upper body") and the first attack ("strike") -- verified
    to kill. Each turn re-opens the menu (each strike lands damage) until the target dies
    or turns hostile (then the bump branch takes over). Passivity is judged LIVE every
    turn, so a target that stays passive is always menu-attacked -- the case that used to
    be missed when a stale "provoked" flag made it bump-swap forever.
Menu steps use the inputs that actually work (found by testing): A_ATTACK_CONFIRM advances
the conflict prompt (MENU_CONFIRM/SELECT/typed-char all fail); list options are chosen by
LEFT-CLICKING their rendered text (the letter hotkeys are not real keypresses here).
Your party (you, companions, mounts) and caged/chained creatures are never targeted.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

-- ---- state (session-local; survives reqscript reload) ------------------------
targets = targets or {}          -- unit ids still to kill
running = running or false
trace = trace or {}              -- rolling decision log (debug: `adv/fight trace`)
chase = chase or {x = -1, y = -1, z = -1, stall = 0, blacklist = {}}
armed = (armed == nil) and true or armed
last_stamp = last_stamp or ''
attack_steps = attack_steps or 0     -- how many keys pressed in the current attack menu
idle_beats = idle_beats or 0         -- onupdate calls since our last action (watchdog)

local function tr(fmt, ...)
    local s = fmt:format(...):gsub('[\128-\255]', '?')   -- keep it ascii-safe
    table.insert(trace, s)
    if #trace > 120 then table.remove(trace, 1) end
end

local function adv_unit()
    return dfhack.world.getAdventurer and dfhack.world.getAdventurer() or nil
end

-- ---- party & target selection ------------------------------------------------

-- the adventurer's party: self, anyone whose group-leader chain reaches the player
local function party_ids()
    local adv = adv_unit()
    local ids = {}
    if not adv then return ids end
    ids[adv.id] = true
    for _, u in ipairs(df.global.world.units.active) do
        local seen, cur = {}, u
        for _ = 1, 10 do
            local gl = cur.relationship_ids.GroupLeader
            if gl < 0 or seen[gl] then break end
            if gl == adv.id then ids[u.id] = true break end
            seen[gl] = true
            cur = df.unit.find(gl)
            if not cur then break end
        end
    end
    return ids
end

local function unit_matches(u, needle)
    if needle == 'all' then return true end
    local cr = df.global.world.raws.creatures.all[u.race]
    if not cr then return false end
    local hay = (tostring(cr.creature_id) .. ' ' .. tostring(cr.name[0]) .. ' '
        .. tostring(cr.name[1])):lower()
    return hay:find(needle, 1, true) ~= nil
end

local function reachable(adv, u)
    local dx, dy = math.abs(u.pos.x - adv.pos.x), math.abs(u.pos.y - adv.pos.y)
    if dx <= 1 and dy <= 1 and u.pos.z == adv.pos.z then return true end
    return dfhack.maps.canWalkBetween(adv.pos, u.pos)
end

local function eligible(u, party)
    return not dfhack.units.isDead(u)
        and not u.flags1.inactive
        and not u.flags1.caged and not u.flags1.chained    -- never fight the caged
        and not party[u.id]
        and u.pos.x >= 0
end

local function designate(needle)
    local party = party_ids()
    local adv = adv_unit()
    targets = {}
    chase = {x = -1, y = -1, z = -1, stall = 0, blacklist = {}}   -- fresh per hunt
    local names = {}
    local unreachable = 0
    for _, u in ipairs(df.global.world.units.active) do
        if eligible(u, party) and unit_matches(u, needle) then
            if adv and reachable(adv, u) then
                targets[#targets + 1] = u.id
                names[#names + 1] = dfhack.units.getReadableName(u)
            else
                unreachable = unreachable + 1
            end
        end
    end
    return names, unreachable
end

local function prune()
    local out = {}
    local party = party_ids()
    for _, id in ipairs(targets) do
        local u = df.unit.find(id)
        if u and not dfhack.units.isDead(u) and not u.flags1.inactive and not party[u.id] then
            out[#out + 1] = id
        end
    end
    targets = out
end

local function nearest(adv)
    -- no canWalkBetween here: its cache flips as the adv map streams and a false negative
    -- would strand the hunt. Reachability is judged empirically by the stall-dropper.
    local best, bd
    for _, id in ipairs(targets) do
        local u = df.unit.find(id)
        if u and not chase.blacklist[id] then
            local d = math.max(math.abs(u.pos.x - adv.pos.x), math.abs(u.pos.y - adv.pos.y))
                + math.abs(u.pos.z - adv.pos.z) * 10
            if not bd or d < bd then best, bd = u, d end
        end
    end
    return best
end

local function hostile(u)
    local ok, v = pcall(dfhack.units.isDanger, u)
    return ok and v
end

-- ---- input helpers -----------------------------------------------------------

local DIR_KEYS = {
    [-1] = {[-1] = 'A_MOVE_NW', [0] = 'A_MOVE_W', [1] = 'A_MOVE_SW'},
    [0]  = {[-1] = 'A_MOVE_N',                    [1] = 'A_MOVE_S'},
    [1]  = {[-1] = 'A_MOVE_NE', [0] = 'A_MOVE_E', [1] = 'A_MOVE_SE'},
}

local function key(name)
    -- feed the real GAME viewscreen (getDFViewscreen skips dfhack overlays; getCurViewscreen
    -- can return the lua launcher and swallow the key). The feeder is gui.simulateInput.
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), name)
end

-- send a literal typed character (the attack menu's "a"/"b" hotkeys are character input,
-- NOT the CUSTOM_A keybinding -- CUSTOM_A does nothing on those list screens)
local function char_key(c)
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), {_STRING = string.byte(c)})
end

-- click the middle of an on-screen TEXT run (menu rows are text-cell sized). Left-clicks
-- on rendered text WORK (unlike right-clicks on the map, which need real hardware hover),
-- so this drives the attack menu / confirm dialogs, which have no addressable structs.
local function click_text(needle)
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local chars = {}
        for x = 0, gps.dimx - 1 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            local ch = ok and t and t.ch or 0
            chars[x] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local line = table.concat(chars, '', 0, gps.dimx - 1)
        local i = line:find(needle, 1, true)
        if i then
            local cx = (i - 1) + #needle // 2
            gps.mouse_x, gps.mouse_y = cx, y
            gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
            gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
            key('_MOUSE_L')
            return true
        end
    end
    return false
end

-- is a (lowercase) substring visible anywhere on the rendered screen?
local function screen_has(needle)
    local gps = df.global.gps
    needle = needle:lower()
    for y = 0, gps.dimy - 1 do
        local chars = {}
        for x = 0, gps.dimx - 1 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            local ch = ok and t and t.ch or 0
            chars[x] = (ch >= 65 and ch < 123) and string.char(ch):lower() or ' '
        end
        if table.concat(chars, '', 0, gps.dimx - 1):find(needle, 1, true) then return true end
    end
    return false
end

-- click the TOP-most list option on the current menu: a row whose text starts with a
-- hotkey letter ("a Strike", "g right lower arm", "v Heavy attack", ...). Picks the
-- first option, matching the manual "press a" -> top choice. Returns true if clicked.
local function click_first_option()
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local chars = {}
        for x = 0, gps.dimx - 1 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            local ch = ok and t and t.ch or 0
            chars[x] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local line = table.concat(chars, '', 0, gps.dimx - 1)
        -- a menu option row: some leading spaces, one lowercase letter, a space, a word
        local col = line:find('%l %u') or line:find('%l %l')
        if col and line:sub(1, col - 1):find('^%s*$') then
            local cx = col + 2                       -- into the label text
            gps.mouse_x, gps.mouse_y = cx, y
            gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
            gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
            key('_MOUSE_L')
            return true
        end
    end
    return false
end

local function walkable(x, y, z)
    local b = dfhack.maps.getTileBlock(x, y, z)
    return b and b.walkable[x % 16][y % 16] > 0
end

-- map tiles render at S = viewport_zoom_factor/4 px (verified across zooms). Point the
-- mouse at map tile (tx,ty) and click; getMousePos is only a sanity log (aborting on a
-- transient mismatch would strand the hunt, and the formula is deterministic).
local function fire_click(tx, ty, button)
    local gps = df.global.gps
    local S = math.max(1, gps.viewport_zoom_factor // 4)
    local px = (tx - df.global.window_x) * S + S // 2
    local py = (ty - df.global.window_y) * S + S // 2
    gps.precise_mouse_x, gps.precise_mouse_y = px, py
    gps.mouse_x = px // gps.tile_pixel_x
    gps.mouse_y = py // gps.tile_pixel_y
    key(button or '_MOUSE_L')
    return true
end

-- visible map-tile count = screen pixels / S (NOT vp.dim_x, which overstates it and puts
-- a "centered" target off the real screen edge where clicks silently miss).
local function visible_tiles()
    local gps = df.global.gps
    local S = math.max(1, gps.viewport_zoom_factor // 4)
    return math.max(4, (gps.dimx * gps.tile_pixel_x) // S),
           math.max(4, (gps.dimy * gps.tile_pixel_y) // S)
end

-- Center the camera on a map position. Fixing window_z to the target's z is the trick:
-- a click resolves on the CURRENT view level, so with the camera on the target's z (and
-- it on-screen) a click on its tile makes DF path there itself -- across z-levels.
local function center_camera(x, y, z)
    local mx = df.global.world.map.x_count
    local my = df.global.world.map.y_count
    local mz = df.global.world.map.z_count
    local vw, vh = visible_tiles()
    df.global.window_z = math.max(0, math.min(mz - 1, z))
    df.global.window_x = math.max(0, math.min(mx - vw, x - vw // 2))
    df.global.window_y = math.max(0, math.min(my - vh, y - vh // 2))
end

-- travel toward a target: center the camera on it, then LEFT-click its tile -> DF travels
-- there natively, one step per click while enemies are near (so re-clicking each turn is
-- the "one step, re-designate" chase). We never cancel the command mid-step.
local function travel_to(tx, ty, tz)
    center_camera(tx, ty, tz)
    return fire_click(tx, ty)
end

-- ---- the per-turn brain ------------------------------------------------------

local function do_turn()
    prune()
    if #targets == 0 then
        running = false
        dfhack.gui.showAnnouncement('adv/fight: all designated targets are dead. Standing down.',
            COLOR_LIGHTGREEN, true)
        return
    end
    local focus = dfhack.gui.getCurFocus(true)[1] or ''
    local cstate = df.global.adventure.player_control_state
    -- "You haven't been able to act for a while": no dialog struct, only a "Continue
    -- waiting" button -- adv/im-sure reads the screen text and clicks it.
    if cstate == df.adventure_game_loop_type.TAKING_TOO_LONG_INPUT then
        local ok2, sure = pcall(reqscript, 'adv/im-sure')
        if ok2 and sure.dismiss then sure.dismiss() end
        tr('cannot-act prompt: dismiss')
        return
    end
    local at = df.global.game.main_interface.adventure.attack
    local ol = df.global.game.main_interface.adventure.option_list
    local waiting = cstate == df.adventure_game_loop_type.TAKING_INPUT
    if not waiting then
        armed = true                        -- a turn is processing: re-arm for the next
        return
    end
    local adv = adv_unit()
    if not adv or dfhack.units.isDead(adv) then return end
    -- one input per turn/menu-step: re-arm only on a real advance. Signals, any of which
    -- means the game moved on since our last action:
    --   * adventurer POSITION changed (a MOVE happened -- mouse travel-clicks do NOT
    --     update the input timestamp, so position is the only reliable move signal),
    --   * DF's input timestamp changed (a keyboard action was taken),
    --   * focus or attack-menu MODE changed (a new menu sub-step; focus stays
    --     'dungeonmode/Attack' across conflict/attack/slash/body, so mode is the tell).
    local av = df.global.adventure
    local mode = df.global.game.main_interface.adventure.attack.mode
    local ctx = ('%d,%d,%d|%d:%d:%d|%s|%d'):format(adv.pos.x, adv.pos.y, adv.pos.z,
        av.last_took_input_year, av.last_took_input_season_count,
        av.last_took_input_precise_phase, focus, mode)
    if ctx ~= last_stamp then armed = true; last_stamp = ctx end
    -- watchdog: if nothing has changed for a while (a click that did NOTHING -- an
    -- unreachable tile), re-arm anyway so we retry and the stall-dropper can fire
    idle_beats = (idle_beats or 0) + 1
    if idle_beats > 40 then armed = true end
    if not armed then return end
    armed = false
    idle_beats = 0
    -- stall detection: position unchanged since our last action = the game rejected it
    if adv.pos.x == chase.x and adv.pos.y == chase.y and adv.pos.z == chase.z then
        chase.stall = chase.stall + 1
    else
        chase.stall = 0
        chase.x, chase.y, chase.z = adv.pos.x, adv.pos.y, adv.pos.z
    end
    local t = nearest(adv)
    if not t then
        running = false
        dfhack.gui.showAnnouncement(
            ('adv/fight: %d target%s left but none reachable -- standing down.')
                :format(#targets, #targets == 1 and '' or 's'), COLOR_YELLOW, true)
        return
    end
    local dx, dy = t.pos.x - adv.pos.x, t.pos.y - adv.pos.y
    local adjacent = math.abs(dx) <= 1 and math.abs(dy) <= 1 and t.pos.z == adv.pos.z
        and (dx ~= 0 or dy ~= 0)
    local same_tile = dx == 0 and dy == 0 and t.pos.z == adv.pos.z
    local ol_focus = focus == 'dungeonmode/OptionList' or ol.open
    -- NB: at.mode is STALE when the panel is closed (keeps its last value), so the attack
    -- state is gated on at.open / the Attack focus ONLY -- never on at.mode alone
    local in_attack = at.open or focus == 'dungeonmode/Attack'

    -- ===== ATTACK MENU state machine =========================================
    -- A neutral is force-attacked through the keyboard menu (bumping only SWAPS with a
    -- non-hostile). Sequence: A_ATTACK, then MENU_CONFIRM ("alt+y", start conflict / accept
    -- attacking a yielded foe), then type "a" x3 (attack-not-dodge, slash, upper body).
    -- Whatever the target is, running the menu once marks it PROVOKED so we bump it after,
    -- which both finishes the kill and breaks the "already-yielded" re-attack loop.
    -- Verified mode-by-mode (MENU_CONFIRM/SELECT/typed-char all fail on the list screens;
    -- these are what actually advance them):
    --   CONFIRM    ("Really start a conflict?")  -> A_ATTACK_CONFIRM
    --   MOVE_CHOICE ("a Strike / b Dodge")       -> click "Strike"
    --   AIM_TARGET / AIM_ATTACK / UNIT_CHOICE    -> click the first list option
    if in_attack then
        attack_steps = (attack_steps or 0) + 1
        local M = df.adventure_interface_attack_mode_type
        if attack_steps > 8 then
            tr('attack menu: bail after %d steps -> leave', attack_steps)
            key('LEAVESCREEN'); attack_steps = 0
        elseif at.mode == M.CONFIRM then
            tr('attack: A_ATTACK_CONFIRM (start conflict)')
            key('A_ATTACK_CONFIRM')
        elseif at.mode == M.MOVE_CHOICE then
            tr('attack: click Strike')
            if not click_text('Strike') then click_first_option() end
        else
            tr('attack: first option (mode %s)', tostring(M[at.mode]))
            if not click_first_option() then key('LEAVESCREEN') end
        end
        return
    end
    attack_steps = 0

    -- right-click option list (distant hostiles -> Path to here)
    if ol_focus then
        if click_text('Path to here') or click_text('Travel to') then
            tr('option list: Path to here')
        else
            tr('option list: no Path row -- closing'); key('LEAVESCREEN')
        end
    -- a conversation / announcement popped up (goblins taunt mid-chase) and is blocking
    -- movement: dismiss it so the hunt continues
    elseif focus:find('Conversation', 1, true) or focus == 'dungeonmode/Announcements' then
        tr('dialogue %s: dismissing', focus)
        key('LEAVESCREEN')
    elseif focus ~= 'dungeonmode/Default' then
        tr('foreign focus %s: waiting', focus)
    -- ADJACENT & ACTIVELY HOSTILE (isDanger): a keyboard bump is a native quick attack.
    elseif adjacent and hostile(t) then
        tr('adjacent hostile %d: bump %d,%d', t.id, dx, dy)
        key(DIR_KEYS[dx][dy])
    -- ADJACENT/same-tile & PASSIVE (isDanger=false): bumping a non-hostile only SWAPS, so
    -- it MUST be attacked through the menu. QUICK_ATTACK -> target -> strike lands damage;
    -- we re-open the menu each turn (each strike hurts it) until it dies or turns hostile
    -- (then the bump branch takes over). No "provoked" shortcut -- a still-passive target
    -- is always menu-attacked, which is exactly the case that used to be missed.
    elseif adjacent or same_tile then
        tr('reach PASSIVE %d: QUICK_ATTACK (menu)', t.id)
        key('QUICK_ATTACK')
    elseif chase.stall > 10 then
        tr('target %d unreachable after %d stalls: dropping', t.id, chase.stall)
        chase.blacklist[t.id] = true
        chase.stall = 0
    -- DISTANT hostile: can't left-click-path onto an enemy -> right-click for Path menu
    elseif hostile(t) then
        tr('distant hostile %d: right-click for Path menu', t.id)
        center_camera(t.pos.x, t.pos.y, t.pos.z)
        fire_click(t.pos.x, t.pos.y, '_MOUSE_R')
    -- DISTANT neutral: camera-center and left-click -> DF travels there
    else
        tr('travel to %d (%d,%d,%d) dz=%d', t.id, t.pos.x, t.pos.y, t.pos.z, t.pos.z - adv.pos.z)
        travel_to(t.pos.x, t.pos.y, t.pos.z)
    end
end

-- ---- overlay widget (drives the hunt every render frame, even while paused) ---

FightOverlay = defclass(FightOverlay, overlay.OverlayWidget)
FightOverlay.ATTRS{
    desc = 'Drives adv/fight: auto-move-to and attack designated creatures.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,   -- every update cycle
    frame = {w = 1, h = 1},                  -- invisible; a pure driver, no rendering
}

heartbeat = heartbeat or 0
function FightOverlay:overlay_onupdate()
    heartbeat = heartbeat + 1                 -- proves onupdate is firing (adv/fight beat)
    if not running then return end
    local ok, err = pcall(do_turn)
    if not ok then
        running = false
        tr('TURN ERROR: %s', tostring(err))
        dfhack.printerr('adv/fight: ' .. tostring(err))
    end
end

OVERLAY_WIDGETS = {fight = FightOverlay}

function stop()
    running = false
end

if dfhack_flags.module then return end

-- ---- CLI ---------------------------------------------------------------------

if not dfhack.world.isAdventureMode() then
    qerror('adv/fight only works in adventure mode')
end

local arg = ({...})[1]
if not arg or arg == 'help' then
    print('adv/fight <name>|all  -- designate targets and auto-fight them to the death')
    print('    adv/fight goblin      fight every goblin in the area')
    print('    adv/fight all         fight EVERYTHING (party excluded)')
    print('    adv/fight status      what is left on the kill list')
    print('    adv/fight stop        stand down')
elseif arg == 'stop' then
    stop()
    print('adv/fight: standing down.')
elseif arg == 'trace' then
    print(('adv/fight trace (%d entries, newest last):'):format(#trace))
    for _, s in ipairs(trace) do print('  ' .. s) end
elseif arg == 'status' then
    prune()
    print(('adv/fight: %s, %d target%s left'):format(running and 'FIGHTING' or 'idle',
        #targets, #targets == 1 and '' or 's'))
    local adv = adv_unit()
    for _, id in ipairs(targets) do
        local u = df.unit.find(id)
        if u and adv then
            print(('  %s (dist %d)'):format(dfhack.units.getReadableName(u),
                math.max(math.abs(u.pos.x - adv.pos.x), math.abs(u.pos.y - adv.pos.y))))
        end
    end
else
    local needle = table.concat({...}, ' '):lower()
    local names, unreachable = designate(needle)
    if unreachable and unreachable > 0 then
        print(('adv/fight: %d matching creature%s skipped -- unreachable from where you stand')
            :format(unreachable, unreachable == 1 and '' or 's'))
    end
    if #names == 0 then
        print(('adv/fight: no reachable living creature here matches "%s"'):format(needle))
    else
        print(('adv/fight: %d target%s designated:'):format(#names, #names == 1 and '' or 's'))
        for _, n in ipairs(names) do print('  ' .. n) end
        running = true
        print('adv/fight: FIGHTING -- `adv/fight stop` to stand down.')
    end
end
