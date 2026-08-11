-- Adventure mode: fast travel into and out of the goblin dark pit you are at.
--@module = true
--[[
adv/fear-no-goblin

Dwarf Fortress refuses to let an adventurer fast travel while standing in a
dark fortress ("You cannot travel until you leave this site.") and bumps you
off the world map when you try to cross one ("You cannot travel through the
Dark pits."). Both checks read one field: `world_site.type`. Nothing else about
the site matters -- verified live, a dark pit presented as a Town lets the
travel check pass.

So this presents nearby dark pits as towns: every pit within RANGE world
tiles, for only as long as it stays in range. Distant pits are left alone, so
the blast radius is the sites around you -- and a WALL of adjacent pits (they
cluster) is crossable, where patching only the closest one dead-ends you one
tile in (measured: a 4-pit cluster at world 46-48,2-5 refused entry to pit
two).

UNDERGROUND IS EXEMPT. While the adventurer stands on a subterranean tile the
patch is lifted and nothing is re-patched, so DF gives its normal travel
refusal instead of opening the travel screen from inside the pit. Travel
started down there renders a black world map (nothing explored on the
underground travel layer) and has teleported the player army to the map's
top-left corner before crashing -- climb to the surface and travel opens
normally. The lift happens ONLY at a standstill (normal play, travel screen
closed): restoring a site's type while DF is mid-travel is the SIGSEGV this
header already warns about.

WHAT IT TOUCHES
  Only `world_site.type`, only on that one site, only while it is DarkFortress.
  No units, no map, no map blocks.

WHY IT HOLDS THE PATCH INSTEAD OF PULSING IT
  Travel does not start inside the keypress -- DF re-reads the site over the
  following frames while it tears the local map down. Restoring the type in
  that window SIGSEGVs the game (learned the hard way). So the patch is applied
  and left alone; it is only ever removed at a standstill.

HOW IT AVOIDS SAVING A TOWN-SHAPED DARK FORTRESS INTO YOUR WORLD
  1. The patch is only held while you are actually playing: the adventure play
     screen up AND the pause/options window (the save gateway) closed. Anything
     else -- the ESC menu, the save flow, another viewscreen, the title --
     drops it within LIFT_AFTER_MS, and it goes back on when you return to
     play. Adventure mode has no timed autosave (AUTOSAVE is a fortress-mode
     setting), so a save cannot happen without one of those being up first.
  2. It also drops on world unload.
  3. The real types are ALSO recorded in dfhack persistence
     (dfhack.persistent.saveWorldData) BEFORE any site is touched. Persistence
     is stored inside the save itself, so a save that catches the patch
     necessarily catches the recovery record too, and the next load heals the
     world before anything else runs. This is the correctness backstop; the
     off-play lift above is just the first line of defense. (The previous
     design kept an external stash file keyed by save folder -- a save-and-quit
     mid-travel saved a town-shaped pit, then the unload handler restored the
     already-torn-down world and WIPED the stash, orphaning the damage. In-save
     persistence cannot lose that race: measured live on site 61 "Highseduce".)

ALWAYS-ON
  The watcher is an OVERLAY (adv/fear-no-goblin.watch, enabled by default),
  not a frame-timer loop: dfhack.timeout('frames') FREEZES while DF waits for
  input -- which is precisely the travel map as you approach a pit (the moment
  a new pit must be patched) and the menus (the moment the patch must lift
  before a save can happen). onupdate keeps firing through both. The overlay's
  enabled flag persists across sessions, so there is nothing to arm.

MID-TRAVEL POSITION
  While fast travelling there is no adventurer unit and no loaded map --
  dfhack.world.getAdventurer() is nil. Position comes from the player army
  instead (adventure.player_army_id): army coords are embark tiles x3, so
  army.pos//48 is the world tile. Measured live: army (2207,132) = world
  (45,2), with the pit one tile east correctly at distance 1.

    adv/fear-no-goblin           arm (idempotent; the overlay defaults on
                                 anyway -- run it to re-target immediately)
    adv/fear-no-goblin once      arm, and disarm by itself once you have
                                 travelled clear of the pit
    adv/fear-no-goblin stop      restore + disarm
    adv/fear-no-goblin status    armed? which site is patched?
    adv/fear-no-goblin restore   put the patched site back, including one left
                                 over from a crashed session
]]

local overlay = require('plugins.overlay')

local BAN_TYPE = df.world_site_type.DarkFortress
local SAFE_TYPE = df.world_site_type.Town

local RANGE = 1          -- world tiles: how close a pit must be to get patched
local EVAL_MS = 500      -- wall-clock gap between target re-evaluations
local LIFT_AFTER_MS = 250 -- how long off-play must persist before the patch drops
                          -- (debounced so a transient frame mid-travel cannot trip it)

-- always-on: nil (never touched) counts as running. `stop` turns it off for
-- the session; the overlay's own enabled flag is the persistent switch.
if running == nil then running = true end
once_mode = once_mode or false
patched = patched or {}   -- [site id] = real type
recovered_this_load = recovered_this_load or false

local GLOBAL_KEY = 'fear-no-goblin'

-- the recovery record lives IN the save (dfhack persistence): {sites = {["<id>"] = real_type}}.
-- Written before any site is touched, deleted once nothing is patched.
local function persist_record()
    if next(patched) then
        local sites = {}
        for id, t in pairs(patched) do sites[tostring(id)] = t end
        dfhack.persistent.saveWorldData(GLOBAL_KEY, {sites = sites})
    else
        dfhack.persistent.deleteWorldData(GLOBAL_KEY)
    end
end

-- the patch is only ever held while actually playing: the adventure play
-- screen up and the pause/options window (the save gateway) closed
local function in_play()
    if not dfhack.world.isAdventureMode() then return false end
    if not df.viewscreen_dungeonmodest:is_instance(dfhack.gui.getCurViewscreen(true)) then
        return false
    end
    local ok, options_open = pcall(function()
        return df.global.game.main_interface.options.open
    end)
    return not (ok and options_open)
end

-- adventurer's world tile. Walking around: the loaded map (region_x/y are
-- embark tiles, 48 map tiles per embark tile, 16 embark tiles per world
-- tile). Fast travelling: no unit and no loaded map -- the player ARMY
-- carries the position, in embark tiles x3 (army.pos//48 = world tile).
local function player_world_tile()
    local u = dfhack.world.getAdventurer()
    if u and dfhack.isMapLoaded() then
        local map = df.global.world.map
        local ex = map.region_x + u.pos.x // 48
        local ey = map.region_y + u.pos.y // 48
        return ex // 16, ey // 16
    end
    local army = df.army.find(df.global.adventure.player_army_id)
    if army then
        return army.pos.x // 48, army.pos.y // 48
    end
end

-- a site's footprint in world tiles (global_min/max are embark tiles)
local function site_world_rect(site)
    return site.global_min_x // 16, site.global_min_y // 16,
           (site.global_max_x - 1) // 16, (site.global_max_y - 1) // 16
end

-- every dark pit within RANGE world tiles of the adventurer
local function pits_in_range()
    local wx, wy = player_world_tile()
    if not wx then return {} end
    local out = {}
    for _, site in ipairs(df.global.world.world_data.sites) do
        if site.type == BAN_TYPE or patched[site.id] then
            local x0, y0, x1, y1 = site_world_rect(site)
            local dx = math.max(x0 - wx, 0, wx - x1)
            local dy = math.max(y0 - wy, 0, wy - y1)
            if math.max(dx, dy) <= RANGE then out[#out + 1] = site end
        end
    end
    return out
end

-- put the real type back; only touches sites still sitting at SAFE_TYPE
function restore()
    if not next(patched) then return 0 end
    local n = 0
    for id, real in pairs(patched) do
        local site = df.world_site.find(id)
        if site and site.type == SAFE_TYPE then
            site.type = real
            n = n + 1
        end
    end
    patched = {}
    persist_record()
    return n
end

-- patch every in-range pit, release every patched site that fell out of
-- range. Returns the list of currently patched sites (empty = nothing near).
function retarget()
    local near = pits_in_range()
    local want = {}
    for _, site in ipairs(near) do want[site.id] = site end
    -- release what drifted out of range
    for id, real in pairs(patched) do
        if not want[id] then
            local site = df.world_site.find(id)
            if site and site.type == SAFE_TYPE then site.type = real end
            patched[id] = nil
        end
    end
    -- the record is written BEFORE the sites are touched: a save landing
    -- between the two must contain the recovery data for what it sees
    local newly = {}
    for id, site in pairs(want) do
        if not patched[id] and site.type == BAN_TYPE then
            newly[#newly + 1] = site
        end
    end
    if #newly > 0 then
        for _, site in ipairs(newly) do patched[site.id] = site.type end
        persist_record()
        for _, site in ipairs(newly) do site.type = SAFE_TYPE end
        -- DF ignores every further travel keypress until you move once you
        -- have already been refused; clear the latch or the press does nothing
        df.global.adventure.travel_not_moved = 0
    else
        persist_record()
    end
    return near
end

-- heal a world whose save caught the patch: replay the in-save record.
-- Only touches sites still sitting at SAFE_TYPE, so a record that outlived a
-- clean restore (persistence flushes on the NEXT save) is harmless.
function recover()
    local rec = dfhack.persistent.getWorldData(GLOBAL_KEY, {sites = {}})
    local n = 0
    for id, real in pairs(rec.sites or {}) do
        local site = df.world_site.find(tonumber(id))
        if site and site.type == SAFE_TYPE then
            site.type = real
            n = n + 1
        end
    end
    patched = {}
    dfhack.persistent.deleteWorldData(GLOBAL_KEY)
    return n
end

function site_label(site)
    local ok, name = pcall(dfhack.translation.translateName, site.name, true)
    return ('"%s" (site %d)'):format(ok and name or '?', site.id)
end

-- ---- overlay driver ---------------------------------------------------------
-- An overlay, NOT dfhack.timeout('frames'): frame timers freeze while DF waits
-- for input, which is exactly the travel map (where a new pit must get patched
-- as you approach) and the menus (where the patch must lift before a save).
-- onupdate fires every render frame through both. Timers are wall-clock ms.

local off_play_since, next_eval = nil, 0

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end
    local now = dfhack.getTickCount()
    if not in_play() then
        off_play_since = off_play_since or now
        if now - off_play_since > LIFT_AFTER_MS then restore() end
        return
    end
    off_play_since = nil
    -- underground: hold no patches, so DF refuses travel instead of opening a
    -- black world map (and worse -- see header). Restore ONLY at a standstill:
    -- the travel screen being open means DF may be mid-teardown, where a type
    -- write is the known SIGSEGV.
    local u = dfhack.world.getAdventurer()
    if u and dfhack.isMapLoaded()
        and df.global.adventure.menu == df.ui_advmode_menu.Default then
        local ok, des = pcall(dfhack.maps.getTileFlags, u.pos.x, u.pos.y, u.pos.z)
        if ok and des and des.subterranean then
            if next(patched) then restore() end
            return
        end
    end
    -- a crash's leftover stash is replayed once per session, before any patching
    if not recovered_this_load then
        recovered_this_load = true
        local n = recover()
        if n > 0 then
            dfhack.println(('adv/fear-no-goblin: recovered %d site(s) from a'
                .. ' previous session.'):format(n))
        end
    end
    -- re-evaluate on a slow cadence, and immediately after the patch was
    -- dropped for a menu, so it comes straight back on return to play
    if now >= next_eval or not next(patched) then
        next_eval = now + EVAL_MS
        local near = retarget()
        if once_mode and #near == 0 then
            running = false
            once_mode = false
            dfhack.println('adv/fear-no-goblin: clear of the pit -- restored, disarmed.')
        end
    end
end

FearNoGoblin = defclass(FearNoGoblin, overlay.OverlayWidget)
FearNoGoblin.ATTRS{
    desc = 'Drives adv/fear-no-goblin: fast travel into, out of and past goblin dark pits.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function FearNoGoblin:overlay_onupdate()
    pcall(step)
end

OVERLAY_WIDGETS = {watch = FearNoGoblin}

function stop()
    running = false
    return restore()
end

-- world going away: never leave a patched site behind. running is NOT
-- touched -- always-on means the next world is watched too; the per-load
-- crash-recovery flag resets so the new world's stash gets replayed.
dfhack.onStateChange[_ENV] = function(sc)
    if sc == SC_BEGIN_UNLOAD or sc == SC_WORLD_UNLOADED then
        restore()
        recovered_this_load = false
    end
end

if dfhack_flags.module then return end

local arg = ({...})[1]

if arg == 'stop' then
    local n = stop()
    print(('adv/fear-no-goblin: disarmed, %d site(s) restored.'):format(n))
    print('  (disarmed for this session; `overlay disable adv/fear-no-goblin.watch`'
        .. ' turns the always-on watcher off for good)')
    return
elseif arg == 'restore' then
    local n = restore()
    running = false
    if n == 0 then n = recover() end
    print(('adv/fear-no-goblin: restored %d site(s).'):format(n))
    return
elseif arg == 'status' then
    local labels = {}
    for id in pairs(patched) do
        local s = df.world_site.find(id)
        labels[#labels + 1] = s and site_label(s) or ('site ' .. id)
    end
    table.sort(labels)
    local where = #labels == 0 and 'nothing patched'
        or ('patching ' .. table.concat(labels, ', '))
    print(('adv/fear-no-goblin: %s | %s%s'):format(running and 'ARMED' or 'disarmed',
        where, once_mode and ' | one-shot mode' or ''))
    return
end

-- arming is only legal from actual play: isAdventureMode() is also true on the
-- adventurer-setup screen, and patching a world you are still setting up gets
-- that world saved with a town-shaped dark fortress in it
if not in_play() then
    qerror('adv/fear-no-goblin only works while playing an adventurer'
        .. ' (the adventure map screen)')
end

if arg and arg ~= 'once' then
    qerror('unknown argument: ' .. arg .. ' (try: once, stop, status, restore)')
end

-- crash recovery MUST come before the first retarget: recover() would
-- otherwise read our OWN live stash as crash leftovers and un-patch the world
-- behind the watcher's back
if not recovered_this_load then
    recovered_this_load = true
    local recovered = recover()
    if recovered > 0 then
        print(('adv/fear-no-goblin: recovered %d site(s) from a previous session.')
            :format(recovered))
    end
end

once_mode = (arg == 'once')
running = true
overlay.rescan()
local near = retarget()

if #near > 0 then
    local labels = {}
    for _, site in ipairs(near) do labels[#labels + 1] = site_label(site) end
    print(('adv/fear-no-goblin: armed -- %s presented as town(s).')
        :format(table.concat(labels, ', ')))
    print('  Fast travel in, out and past them now works.')
else
    print('adv/fear-no-goblin: armed -- no dark pit within 1 tile, nothing patched yet.')
    print('  It will patch every pit in range as soon as you are next to one.')
end
if once_mode then
    print('  One-shot: disarms itself once you have travelled clear of the pit.')
else
    print('  Always-on: the overlay keeps watching in every session;'
        .. ' `adv/fear-no-goblin stop` pauses it.')
end
print('  The patch lifts by itself whenever you leave the play screen, so a save'
    .. ' cannot catch it.')
