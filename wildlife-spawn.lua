-- Spawn wild animals from scratch -- the spawn primitive for the wildlife-migration plan.
--@module = true
--[[
wildlife-spawn

A minimal, working spawn primitive. On DFHack 53.15-r1 / DF v0.53.15 the stock
`modtools/create-unit` is broken -- it drives DF's old arena-spawn machinery, but that was
removed (`world.arena_spawn` is gone, and the `D_LOOK_ARENA_CREATURE` keybinding no longer
exists). Instead we use **`dfhack.units.create(race, caste)`** -- a Bay12 entry point that
builds a *complete* unit (race, caste, name, soul, initialized body and mind) -- and then put
it into play ourselves as a WILD animal: give it a map position, register it, make it active.

This is what the migration features (wandering wildlife / migration waves) will call.

Usage:
    wildlife-spawn <CREATURE_ID> [count] [caste]
        Spawn `count` (default 1) wild <CREATURE_ID> at the keyboard cursor. `caste` is a
        caste index (default 0). Example: place the cursor, then `wildlife-spawn WOLF 3`.

Module:
    local spawn = reqscript('wildlife-spawn').spawn
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
