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

So this presents ONE dark pit as a town: the closest one, and only while you are
within 1 world tile of it. Every other dark fortress in the world is left alone,
so the blast radius is a single site you are standing on or next to. The flip
side is that pits elsewhere on your route still bump you -- get near one and it
gets patched in turn.

WHAT IT TOUCHES
  Only `world_site.type`, only on that one site, only while it is DarkFortress.
  No units, no map, no map blocks.

WHY IT HOLDS THE PATCH INSTEAD OF PULSING IT
  Travel does not start inside the keypress -- DF re-reads the site over the
  following frames while it tears the local map down. Restoring the type in
  that window SIGSEGVs the game (learned the hard way). So the patch is applied
  and left alone; it is only ever removed at a standstill.

HOW IT AVOIDS SAVING A TOWN-SHAPED DARK FORTRESS INTO YOUR WORLD
  1. The patch is only held while `viewscreen_dungeonmodest` is up, i.e. while
     you are actually playing. Anything else on screen -- the ESC menu, the save
     screen, adventurer setup, the title -- drops it within a few frames, and it
     goes back on when you return to play. Adventure mode has no timed autosave
     (AUTOSAVE is a fortress-mode setting), so a save cannot happen without one
     of those screens being up first.
  2. It also drops on world unload.
  3. The patched site is written to a per-world stash file first, so if DF dies
     while armed you can put the world back with `adv/fear-no-goblin restore`.
     On arm, a stash left over from a crash in THIS world is replayed
     automatically; stashes belonging to other worlds are left untouched.

    adv/fear-no-goblin           arm (idempotent; re-run re-targets)
    adv/fear-no-goblin once      arm, and disarm by itself once you have
                                 travelled clear of the pit
    adv/fear-no-goblin stop      restore + disarm
    adv/fear-no-goblin status    armed? which site is patched?
    adv/fear-no-goblin restore   put the patched site back, including one left
                                 over from a crashed session
]]

local BAN_TYPE = df.world_site_type.DarkFortress
local SAFE_TYPE = df.world_site_type.Town

local RANGE = 1          -- world tiles: how close a pit must be to get patched
local EVAL_EVERY = 100   -- frames between target re-evaluations
local LIFT_AFTER = 10    -- consecutive off-screen frames before dropping the patch
                         -- (debounced so a transient screen mid-travel cannot trip it)

running = running or false
once_mode = once_mode or false
patched = patched or {}   -- [site id] = real type
local gen = gen or 0

local function save_dir()
    local sg = df.global.world.cur_savegame
    return sg and sg.save_dir or ''
end

-- one stash per world: arming in a second world must not clobber the first
-- world's recovery record
local function stash_path()
    local dir = save_dir():gsub('[^%w%-_]', '_')
    if dir == '' then return end
    return dfhack.getDFPath() .. '/dfhack-config/fear-no-goblin-stash-' .. dir .. '.txt'
end

local function sites_by_id()
    local by_id = {}
    for _, site in ipairs(df.global.world.world_data.sites) do
        by_id[site.id] = site
    end
    return by_id
end

-- stash: line 1 is the save folder, then "<site id> <real type>" per line
local function write_stash()
    local path = stash_path()
    if not path then return end
    local lines = {}
    for id, t in pairs(patched) do lines[#lines + 1] = ('%d %d'):format(id, t) end
    if #lines == 0 then
        os.remove(path)
        return
    end
    local f = io.open(path, 'w')
    if not f then return end
    f:write(save_dir(), '\n', table.concat(lines, '\n'), '\n')
    f:close()
end

local function read_stash()
    local path = stash_path()
    if not path then return end
    local f = io.open(path, 'r')
    if not f then return end
    local dir = f:read('*l')
    local entries = {}
    for line in f:lines() do
        local id, t = line:match('^(%-?%d+) (%-?%d+)$')
        if id then entries[#entries + 1] = {id = tonumber(id), type = tonumber(t)} end
    end
    f:close()
    return dir, entries
end

-- the patch is only ever held while the adventure play screen is up
local function in_play()
    return dfhack.world.isAdventureMode()
        and df.viewscreen_dungeonmodest:is_instance(dfhack.gui.getCurViewscreen(true))
end

-- adventurer's world tile, via the loaded map: region_x/y are embark tiles,
-- 48 map tiles to an embark tile, 16 embark tiles to a world tile
local function player_world_tile()
    if not dfhack.isMapLoaded() then return end
    local map = df.global.world.map
    local u = dfhack.world.getAdventurer()
    local ex = map.region_x + (u and u.pos.x // 48 or 0)
    local ey = map.region_y + (u and u.pos.y // 48 or 0)
    return ex // 16, ey // 16
end

-- a site's footprint in world tiles (global_min/max are embark tiles)
local function site_world_rect(site)
    return site.global_min_x // 16, site.global_min_y // 16,
           (site.global_max_x - 1) // 16, (site.global_max_y - 1) // 16
end

-- closest dark pit to the adventurer, or nil if none is within RANGE world tiles
local function nearest_pit()
    local wx, wy = player_world_tile()
    if not wx then return end
    local best, best_dist
    for _, site in ipairs(df.global.world.world_data.sites) do
        if site.type == BAN_TYPE or patched[site.id] then
            local x0, y0, x1, y1 = site_world_rect(site)
            local dx = math.max(x0 - wx, 0, wx - x1)
            local dy = math.max(y0 - wy, 0, wy - y1)
            local dist = math.max(dx, dy)   -- 0 while standing in the site
            if dist <= RANGE and (not best_dist or dist < best_dist) then
                best, best_dist = site, dist
            end
        end
    end
    return best, best_dist
end

-- put the real type back; only touches sites still sitting at SAFE_TYPE
function restore()
    if not next(patched) then return 0 end
    local by_id = sites_by_id()
    local n = 0
    for id, real in pairs(patched) do
        local site = by_id[id]
        if site and site.type == SAFE_TYPE then
            site.type = real
            n = n + 1
        end
    end
    patched = {}
    write_stash()
    return n
end

-- point the patch at the closest in-range pit, moving it off whatever it was on.
-- returns the site now patched (nil if nothing is in range).
function retarget()
    local site = nearest_pit()
    if site and patched[site.id] then return site end   -- already on the right one
    restore()
    if not site or site.type ~= BAN_TYPE then return end
    patched[site.id] = site.type
    site.type = SAFE_TYPE
    write_stash()
    -- DF ignores every further travel keypress until you move once you have
    -- already been refused, so clear that latch or the first press does nothing
    df.global.adventure.travel_not_moved = 0
    return site
end

-- replay a stash left behind by a crashed session
function recover()
    local dir, entries = read_stash()
    if not dir or not entries or #entries == 0 then return 0 end
    if dir ~= save_dir() then return 0 end
    local by_id = sites_by_id()
    local n = 0
    for _, e in ipairs(entries) do
        local site = by_id[e.id]
        if site and site.type == SAFE_TYPE then
            site.type = e.type
            n = n + 1
        end
    end
    patched = {}
    write_stash()
    return n
end

function site_label(site)
    local ok, name = pcall(dfhack.translation.translateName, site.name, true)
    return ('"%s" (site %d)'):format(ok and name or '?', site.id)
end

local function watch_loop()
    gen = gen + 1
    local my_gen = gen
    local off_screen, since_eval = 0, 0
    local function loop()
        if not running or my_gen ~= gen then return end
        if not in_play() then
            off_screen = off_screen + 1
            if off_screen > LIFT_AFTER then restore() end
        else
            off_screen, since_eval = 0, since_eval + 1
            -- re-evaluate on a slow cadence, and immediately after the patch was
            -- dropped for a menu, so it comes straight back on return to play
            if since_eval >= EVAL_EVERY or not next(patched) then
                since_eval = 0
                local site = retarget()
                if once_mode and not site then
                    running = false
                    print('adv/fear-no-goblin: clear of the pit -- restored, disarmed.')
                    return
                end
            end
        end
        dfhack.timeout(1, 'frames', loop)
    end
    loop()
end

function stop()
    running = false
    gen = gen + 1
    return restore()
end

-- world going away: never leave a patched site behind
dfhack.onStateChange[_ENV] = function(sc)
    if sc == SC_BEGIN_UNLOAD or sc == SC_WORLD_UNLOADED then
        running = false
        gen = gen + 1
        restore()
    end
end

if dfhack_flags.module then return end

local arg = ({...})[1]

if arg == 'stop' then
    local n = stop()
    print(('adv/fear-no-goblin: disarmed, %d site(s) restored.'):format(n))
    return
elseif arg == 'restore' then
    local n = restore()
    running = false
    gen = gen + 1
    if n == 0 then n = recover() end
    print(('adv/fear-no-goblin: restored %d site(s).'):format(n))
    return
elseif arg == 'status' then
    local by_id = sites_by_id()
    local where = 'nothing patched'
    for id in pairs(patched) do
        local s = by_id[id]
        where = s and ('patching ' .. site_label(s)) or ('patching site ' .. id)
    end
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

-- the already-armed re-target MUST come before recover(): onMapLoad re-runs this
-- on every map load, and recover() would otherwise read our OWN live stash as
-- crash leftovers and un-patch the world behind the watcher's back
if running then
    local site = retarget()
    print(site
        and ('adv/fear-no-goblin: re-targeted -- %s presented as a town.')
            :format(site_label(site))
        or 'adv/fear-no-goblin: armed, no dark pit within 1 tile -- nothing patched.')
    return
end

local recovered = recover()
if recovered > 0 then
    print(('adv/fear-no-goblin: recovered %d site(s) from a previous session.')
        :format(recovered))
end

once_mode = (arg == 'once')
running = true
local site = retarget()
watch_loop()

if site then
    print(('adv/fear-no-goblin: armed -- %s presented as a town.'):format(site_label(site)))
    print('  Fast travel in and out of it now works.')
else
    print('adv/fear-no-goblin: armed -- no dark pit within 1 tile, nothing patched yet.')
    print('  It will patch the closest pit as soon as you are next to one.')
end
if once_mode then
    print('  One-shot: disarms itself once you have travelled clear of the pit.')
else
    print('  Run `adv/fear-no-goblin stop` when you are done.')
end
print('  The patch lifts by itself whenever you leave the play screen, so a save'
    .. ' cannot catch it.')
