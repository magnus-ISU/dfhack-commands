-- Spawn wild animals from scratch -- the spawn primitive for the wildlife-migration plan.
--@module = true
--[[
wildlife-spawn

*** WARNING: THIS DOES NOT ACTUALLY WORK / IS NOT PROVEN. ***
The `dfhack.units.create` + teleport approach below produces a unit object, but the result is NOT
a properly working in-play creature (it does not behave like a real wild animal / does not really
integrate into play). Treat `spawn()` as an UNSOLVED primitive -- do not rely on it (in particular,
tarrasque's off-map / no-unit revival path must NOT assume this works). A real spawn path still has
to be found.

Background (why the obvious route was tried): on DFHack 53.15-r1 / DF v0.53.15 the stock
`modtools/create-unit` is also broken -- it drives DF's old arena-spawn machinery, but that was
removed (`world.arena_spawn` is gone, and the `D_LOOK_ARENA_CREATURE` keybinding no longer
exists). So this tried **`dfhack.units.create(race, caste)`** -- a Bay12 entry point that builds a
unit object (race, caste, name, soul, body, mind) -- and then tried to put it into play as a WILD
animal (give it a map position, register it, make it active). That last part is the part that
does not really work.

Usage:
    wildlife-spawn <CREATURE_ID> [count] [caste]
        Spawn `count` (default 1) wild <CREATURE_ID> at the keyboard cursor. `caste` is a
        caste index (default 0). Example: place the cursor, then `wildlife-spawn WOLF 3`.

Module:
    local spawn = reqscript('fort/wildlife-spawn').spawn
    spawn(race_index, caste_index, pos)   -> the created unit (or nil)
]]

-- creature index in raws.creatures.all for a creature id, plus the raw
function race_index(creature_id)
    local all = df.global.world.raws.creatures.all
    for i = 0, #all - 1 do
        if all[i].creature_id == creature_id then return i, all[i] end
    end
end

-- Create a wild animal of (race, caste) at pos and put it into play. Returns the unit or nil.
function spawn(race, caste, pos)
    local u = dfhack.units.create(race, caste or 0)
    if not u then return nil end
    -- create() leaves the unit off-map (pos -30000) and out of the active vector. teleport
    -- can't place a unit that has no valid current tile, so seed pos first, THEN teleport so
    -- DFHack registers tile occupancy / block membership properly. Finally make it a live,
    -- wild, active creature.
    u.pos.x, u.pos.y, u.pos.z = pos.x, pos.y, pos.z
    dfhack.units.teleport(u, xyz2pos(pos.x, pos.y, pos.z))
    df.global.world.units.active:insert('#', u)
    u.flags1.inactive = false
    u.civ_id = -1                      -- wild: no civilization
    return u
end

-- ---- CLI (test tool) --------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local creature_id = args[1]
if not creature_id then
    qerror('usage: wildlife-spawn <CREATURE_ID> [count] [caste]  (spawns at the keyboard cursor)')
end
if not dfhack.world.isFortressMode() then qerror('wildlife-spawn: fortress mode only') end

local race, craw = race_index(creature_id:upper())
if not race then qerror('wildlife-spawn: unknown creature "' .. creature_id .. '"') end
local count = tonumber(args[2]) or 1
local caste = tonumber(args[3]) or 0

local cur = df.global.cursor
if not cur or cur.x < 0 then
    qerror('wildlife-spawn: no cursor -- open a look/designate cursor first, then re-run')
end

local made = 0
for _ = 1, count do
    if spawn(race, caste, {x = cur.x, y = cur.y, z = cur.z}) then made = made + 1 end
end
print(('wildlife-spawn: created %d wild %s at %d,%d,%d'):format(made, craw.creature_id, cur.x, cur.y, cur.z))
