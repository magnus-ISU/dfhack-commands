-- Adventure mode: fast travel into, out of and through goblin dark pits.
--@module = true
--[[
adv/fear-no-goblin

Dwarf Fortress refuses to let an adventurer fast travel while standing in a
dark fortress ("You cannot travel until you leave this site.") and bumps you
off the world map when you try to cross one ("You cannot travel through the
Dark pits."). Both checks read one field: `world_site.type`. Nothing else about
the site matters -- verified live, a dark pit presented as a Town lets the
travel check pass.

So this presents every DarkFortress site as a Town while it is armed, and puts
the real type back when it is not.

WHAT IT TOUCHES
  Only `world_site.type`, only on sites whose type is DarkFortress. No units,
  no map, no map blocks.

WHY IT HOLDS THE PATCH INSTEAD OF PULSING IT
  Travel does not start inside the keypress -- DF re-reads the site over the
  following frames while it tears the local map down. Restoring the type in
  that window SIGSEGVs the game (learned the hard way). So the patch is applied
  and left alone; it is only ever removed at a standstill.

HOW IT AVOIDS SAVING A TOWN-SHAPED DARK FORTRESS INTO YOUR WORLD
  1. The patch drops the moment a viewscreen that can save appears (the ESC
     menu, the save screen). It goes back on when you return to play. Adventure
     mode has no timed autosave -- AUTOSAVE is a fortress-mode setting -- so a
     save cannot happen without passing through one of those screens.
  2. It also drops on world unload.
  3. Every patched site is written to a stash file first, so if DF dies while
     armed you can put the world back with `adv/fear-no-goblin restore`. On
     start, a stash left over from a crash is replayed automatically.

    adv/fear-no-goblin           arm (idempotent)
    adv/fear-no-goblin once      arm, and disarm by itself once you have
                                 travelled clear of every dark pit
    adv/fear-no-goblin stop      restore + disarm
    adv/fear-no-goblin status    armed? how many sites are patched?
    adv/fear-no-goblin restore   put every patched site back, including ones
                                 left over from a crashed session
]]

local BAN_TYPE = df.world_site_type.DarkFortress
local SAFE_TYPE = df.world_site_type.Town
local STASH = dfhack.getDFPath() .. '/dfhack-config/fear-no-goblin-stash.txt'

-- viewscreens that can lead to a save; the patch is off while any is up
local SAVE_SCREENS = {'viewscreen_optionst', 'viewscreen_savegamest',
                      'viewscreen_titlest', 'viewscreen_loadgamest'}

running = running or false
once_mode = once_mode or false
patched = patched or {}   -- [site id] = real type
local gen = gen or 0

local function save_dir()
    local sg = df.global.world.cur_savegame
    return sg and sg.save_dir or ''
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
    local lines = {}
    for id, t in pairs(patched) do lines[#lines + 1] = ('%d %d'):format(id, t) end
    if #lines == 0 then
        os.remove(STASH)
        return
    end
    local f = io.open(STASH, 'w')
    if not f then return end
    f:write(save_dir(), '\n', table.concat(lines, '\n'), '\n')
    f:close()
end

local function read_stash()
    local f = io.open(STASH, 'r')
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

local function at_save_screen()
    local vs = dfhack.gui.getCurViewscreen(true)
    for _, name in ipairs(SAVE_SCREENS) do
        local t = df[name]
        if t and t:is_instance(vs) then return true end
    end
    return false
end

-- present every dark pit as a town; returns how many sites changed
function apply()
    local n = 0
    for _, site in ipairs(df.global.world.world_data.sites) do
        if site.type == BAN_TYPE and patched[site.id] == nil then
            patched[site.id] = site.type
            site.type = SAFE_TYPE
            n = n + 1
        end
    end
    if n > 0 then write_stash() end
    -- DF ignores every further travel keypress until you move once you have
    -- already been refused, so clear that latch or the first press does nothing
    if dfhack.world.isAdventureMode() then
        df.global.adventure.travel_not_moved = 0
    end
    return n
end

-- put the real types back; only touches sites still sitting at SAFE_TYPE
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

-- replay a stash left behind by a crashed session
function recover()
    local dir, entries = read_stash()
    if not dir or not entries or #entries == 0 then return 0 end
    if dir ~= save_dir() then
        dfhack.printerr(('adv/fear-no-goblin: stash belongs to save "%s", not "%s"'
            .. ' -- leaving it alone.'):format(dir, save_dir()))
        return 0
    end
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

-- true while the loaded local map overlaps any site we have patched
local function standing_in_a_patched_site()
    if not dfhack.maps.isValid() then return true end   -- travelling: assume yes
    local map = df.global.world.map
    local x0, y0 = map.region_x, map.region_y
    local x1 = x0 + math.max(1, map.x_count // 48) - 1
    local y1 = y0 + math.max(1, map.y_count // 48) - 1
    local by_id = sites_by_id()
    for id in pairs(patched) do
        local s = by_id[id]
        if s and s.global_min_x <= x1 and s.global_max_x >= x0
             and s.global_min_y <= y1 and s.global_max_y >= y0 then
            return true
        end
    end
    return false
end

local function watch_loop()
    gen = gen + 1
    local my_gen = gen
    local clear_for = 0
    local function loop()
        if not running or my_gen ~= gen then return end
        if dfhack.world.isAdventureMode() then
            if at_save_screen() then
                restore()
            elseif not next(patched) then
                apply()
            elseif once_mode then
                -- disarm once the adventurer has been clear of every dark pit
                -- for a couple of seconds of settled local play
                if standing_in_a_patched_site() then
                    clear_for = 0
                else
                    clear_for = clear_for + 1
                    if clear_for > 200 then
                        local n = restore()
                        running = false
                        print(('adv/fear-no-goblin: travelled clear -- restored %d'
                            .. ' dark pit(s), disarmed.'):format(n))
                        return
                    end
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
    print(('adv/fear-no-goblin: disarmed, %d dark pit(s) restored.'):format(n))
    return
elseif arg == 'restore' then
    local n = restore()
    running = false
    gen = gen + 1
    if n == 0 then n = recover() end
    print(('adv/fear-no-goblin: restored %d dark pit(s).'):format(n))
    return
elseif arg == 'status' then
    local n = 0
    for _ in pairs(patched) do n = n + 1 end
    print(('adv/fear-no-goblin: %s | %d dark pit(s) presented as towns%s')
        :format(running and 'ARMED' or 'disarmed', n,
                once_mode and ' | one-shot mode' or ''))
    return
end

if not dfhack.world.isAdventureMode() then
    qerror('adv/fear-no-goblin only works in adventure mode')
end

if arg and arg ~= 'once' then
    qerror('unknown argument: ' .. arg .. ' (try: once, stop, status, restore)')
end

-- the already-armed check MUST come first: onMapLoad re-runs this on every map
-- load (including arriving somewhere after a travel), and recover() would read
-- our OWN live stash as crash leftovers, un-patch everything and then bail out
-- here, leaving the script "armed" over an unpatched world.
if running then
    print('adv/fear-no-goblin: already armed. `adv/fear-no-goblin stop` to disarm.')
    return
end

local recovered = recover()
if recovered > 0 then
    print(('adv/fear-no-goblin: recovered %d dark pit(s) from a previous session.')
        :format(recovered))
end

once_mode = (arg == 'once')
running = true
local n = apply()
watch_loop()
print(('adv/fear-no-goblin: armed -- %d dark pit(s) presented as towns.'):format(n))
print('  Fast travel in, out of and through them now works.')
if once_mode then
    print('  One-shot: disarms itself once you have travelled clear of them all.')
else
    print('  Run `adv/fear-no-goblin stop` when you are done.')
end
print('  The patch lifts by itself whenever the ESC/save screen is up, so a save'
    .. ' cannot catch it.')
