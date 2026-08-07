--@module = true
--@enable = true
--[====[
high-adventure/kobolds
======================

Tags: fort | adventure | gameplay

Support script for the kobold civilization's Ancient Dragons.

**Idle dragons land.** A flying ancient dragon with no enemy within reach glides
down to the ground instead of hovering forever out of everyone's way. This covers
both kinds of ancient dragon: the wild ``HA_ANCIENT_DRAGON`` megabeast, and the
six draconic castes of ``HA_KOBOLD`` that supply the civ's Dread Wyrm king.

Fliers in DF have no reason to come down, so a dragon that finishes a flight
tends to park itself a dozen z-levels up: unreachable in adventure mode, and in
fortress mode a permanent "there is a dragon here" that nothing can resolve. This
brings it down when -- and only when -- nothing is fighting it, so it never
yanks a dragon out of the sky mid-battle and never turns a real air attack into
a free kill.

The descent is one z-level per pass (see ``STEP_TICKS``), which reads as a glide
rather than a teleport, and it re-checks for enemies on every step: a dragon that
is jumped halfway down stops descending and is left to the game's own AI.

Never touches the player's adventurer, a caged/chained/ridden dragon, a dragon
that is stunned or unconscious (DF drops those on its own), or one over open
water, magma or an unwalkable drop.

Auto-enables when a fort or adventure map loads with this mod active.

Usage
-----

	enable high-adventure/kobolds
	disable high-adventure/kobolds
	high-adventure/kobolds        print what the dragons on this map are doing
]====]

local repeatUtil = require('repeat-util')

local GLOBAL_KEY = 'haKobolds'

-- The wild megabeast, plus the civ castes on the kobold creature. Caste ids are
-- matched by prefix: the six draconic castes are DRAGON_H1_SPIKE .. DRAGON_H3_CLUB
-- and nothing else on HA_KOBOLD starts with DRAGON_.
local DRAGON_CREATURE   = 'HA_ANCIENT_DRAGON'
local KOBOLD_CREATURE   = 'HA_KOBOLD'
local DRAGON_CASTE_PREF = 'DRAGON_'

-- One z-level of descent per pass. 10 ticks is roughly a dragon's own move rate,
-- so the drop looks like flight rather than a series of blinks, and an enemy that
-- shows up mid-descent stops it within a step.
local STEP_TICKS   = 10
-- How far an enemy has to be before the dragon considers the sky clear. Generous
-- on purpose: the failure we care about is landing a dragon into a fight, and the
-- cost of waiting is only that a dragon stays airborne a while longer.
local ENEMY_RANGE  = 20   -- tiles, Chebyshev, horizontal
local ENEMY_Z      = 8    -- z-levels either way
-- Refuse to set a dragon down in water this deep (7 is a full tile). Shallower
-- than this is a puddle and fine to stand in.
local DEEP_WATER   = 4

enabled = enabled or false

function isEnabled()
    return enabled
end

-- ---------------------------------------------------------------- dragons ----

-- race index -> false, or a set of caste indices that are ancient dragons.
-- Rebuilt on enable because raws are per-world.
local dragon_castes = nil

local function build_dragon_castes()
    dragon_castes = {}
    for i, cr in ipairs(df.global.world.raws.creatures.all) do
        local id = cr.creature_id
        if id == DRAGON_CREATURE or id == KOBOLD_CREATURE then
            local castes = {}
            local any = false
            for c = 0, #cr.caste - 1 do
                -- the megabeast is a dragon in every caste; the kobold creature only
                -- in its DRAGON_* ones
                if id == DRAGON_CREATURE or tostring(cr.caste[c].caste_id):sub(1, #DRAGON_CASTE_PREF) == DRAGON_CASTE_PREF then
                    castes[c] = true
                    any = true
                end
            end
            if any then dragon_castes[i] = castes end
        end
    end
end

local function is_dragon(u)
    local castes = dragon_castes and dragon_castes[u.race]
    return castes ~= nil and castes[u.caste] == true
end

-- ------------------------------------------------------------------ tiles ----

-- Everything the descent needs to know about one tile, or nil off-map.
local function tile_at(x, y, z)
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return nil end
    local des = block.designation[x % 16][y % 16]
    local tt  = block.tiletype[x % 16][y % 16]
    return {
        walkable = dfhack.maps.getWalkableGroup(xyz2pos(x, y, z)) ~= 0,
        open     = df.tiletype_shape.attrs[df.tiletype.attrs[tt].shape].basic_shape == df.tiletype_shape_basic.Open,
        flow     = des.flow_size,
        magma    = des.liquid_type == df.tile_liquid.Magma,
    }
end

-- ---------------------------------------------------------------- enemies ----

-- DF's own record that two units are fighting: a Conflict activity that lists them
-- on opposing sides with a live conflict level. This is the same structure
-- high-adventure/adventure-hostility writes, so scripted hostility counts too.
local function in_conflict_with(dragon, u)
    for _, aid in ipairs(dragon.activities) do
        local act = df.activity_entry.find(aid)
        if act and act.type == df.activity_entry_type.Conflict then
            for _, ev in ipairs(act.events) do
                if df.activity_event_conflictst:is_instance(ev) then
                    local ds, us
                    for i = 0, #ev.sides - 1 do
                        for _, id in ipairs(ev.sides[i].unit_ids) do
                            if id == dragon.id then ds = i end
                            if id == u.id then us = i end
                        end
                    end
                    if ds and us and ds ~= us then
                        for _, e in ipairs(ev.sides[ds].enemies) do
                            -- conflict_level decays to 0 when a fight is over, and a
                            -- de-escalated conflict is not a reason to stay airborne
                            if e.id == ev.sides[us].id and e.conflict_level > 0 then return true end
                        end
                    end
                end
            end
        end
    end
    return false
end

local function is_enemy(dragon, u)
    if u.id == dragon.id then return false end
    if not dfhack.units.isActive(u) or not dfhack.units.isAlive(u) then return false end
    if u.flags1.caged or u.flags1.chained or dfhack.units.isHidden(u) then return false end
    if in_conflict_with(dragon, u) then return true end
    -- Opposite sides of the fortress. Only counts for units that would actually
    -- come at the dragon (or that the dragon would come at): a passing deer on the
    -- other side of the line is not a reason to stay in the air.
    if dfhack.world.isFortressMode() then
        local dfort, ufort = dfhack.units.isFortControlled(dragon), dfhack.units.isFortControlled(u)
        if dfort ~= ufort and (ufort or dfhack.units.isDanger(u)) then return true end
    end
    return false
end

local function enemy_near(dragon)
    local p = dragon.pos
    for _, u in ipairs(df.global.world.units.active) do
        local q = u.pos
        if math.abs(q.z - p.z) <= ENEMY_Z
           and math.abs(q.x - p.x) <= ENEMY_RANGE
           and math.abs(q.y - p.y) <= ENEMY_RANGE
           and is_enemy(dragon, u) then
            return u
        end
    end
    return nil
end

-- ---------------------------------------------------------------- descent ----

-- Reasons a dragon is off limits, as text (nil = fair game). Used by the status
-- command as well as the engine, so the two can never disagree.
local function skip_reason(dragon)
    if not dfhack.units.isActive(dragon) or not dfhack.units.isAlive(dragon) then return 'dead' end
    if dragon.flags1.caged or dragon.flags1.chained then return 'held' end
    if dragon.flags1.ridden or dragon.flags1.rider then return 'mounted' end
    if dragon.flags1.projectile then return 'in flight as a projectile' end
    -- a stunned or unconscious flier is already falling; pushing it down races DF
    if dragon.counters.unconscious > 0 or dragon.counters.stunned > 0 then return 'senseless' end
    if dragon.counters.webbed > 0 then return 'webbed' end
    if not dfhack.units.casteFlagSet(dragon.race, dragon.caste, df.caste_raw_flags.FLIER) then
        return 'not a flier'
    end
    local adv = dfhack.world.isAdventureMode() and dfhack.world.getAdventurer() or nil
    if adv and adv.id == dragon.id then return 'is the adventurer' end
    return nil
end

-- Airborne = standing on nothing. A swimming dragon is also standing on nothing,
-- so anything in liquid is left alone.
local function is_airborne(dragon)
    local here = tile_at(dragon.pos.x, dragon.pos.y, dragon.pos.z)
    if not here then return false end
    if here.flow > 0 then return false end
    return not here.walkable
end

-- One z-level down, if there is somewhere sane to go. Returns 'landed', 'fell',
-- or a reason it did not move.
local function descend(dragon)
    local p = dragon.pos
    if p.z <= 0 then return 'at the bottom of the map' end
    local below = tile_at(p.x, p.y, p.z - 1)
    if not below then return 'no map below' end
    if below.magma then return 'magma below' end
    if below.walkable then
        if below.flow >= DEEP_WATER then return 'deep water below' end
        if dfhack.units.teleport(dragon, xyz2pos(p.x, p.y, p.z - 1)) then return 'landed' end
        return 'teleport refused'
    end
    if not below.open then return 'blocked below' end
    if dfhack.units.teleport(dragon, xyz2pos(p.x, p.y, p.z - 1)) then return 'fell' end
    return 'teleport refused'
end

-- Every airborne, unthreatened dragon on the map takes one step down. Returns the
-- number that moved.
local function land_idle_dragons()
    local moved = 0
    for _, u in ipairs(df.global.world.units.active) do
        if is_dragon(u) and not skip_reason(u) and is_airborne(u) and not enemy_near(u) then
            local r = descend(u)
            if r == 'landed' or r == 'fell' then moved = moved + 1 end
        end
    end
    return moved
end

-- ----------------------------------------------------------------- engine ----

local function tick()
    if not (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then return end
    pcall(land_idle_dragons)
end

local function do_enable()
    enabled = true
    build_dragon_castes()
    -- scheduleEvery does not replace an existing key, so cancel first: a hot reload
    -- would otherwise leave the previous copy's timer running alongside this one
    repeatUtil.cancel(GLOBAL_KEY)
    repeatUtil.scheduleEvery(GLOBAL_KEY, STEP_TICKS, 'ticks', tick)
end

local function do_disable()
    enabled = false
    repeatUtil.cancel(GLOBAL_KEY)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then do_disable() end
    if sc == SC_MAP_LOADED and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
        do_enable()
    end
end

if dfhack_flags.module then
    -- self-enable at module load: survives any load-order race with SC_MAP_LOADED
    if not enabled and dfhack.isMapLoaded()
       and (dfhack.world.isFortressMode() or dfhack.world.isAdventureMode()) then
        do_enable()
    end
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then do_enable() else do_disable() end
    return
end

-- ------------------------------------------------------------------ status ---

if not dfhack.isMapLoaded() then qerror('high-adventure/kobolds: no map loaded') end
if not dragon_castes then build_dragon_castes() end

print(('high-adventure/kobolds: %s (a pass every %d ticks)'):format(
    enabled and 'enabled' or 'disabled', STEP_TICKS))
local n = 0
for _, u in ipairs(df.global.world.units.active) do
    if is_dragon(u) then
        n = n + 1
        local name = dfhack.units.getReadableName(u)
        local skip = skip_reason(u)
        local what
        if skip then
            what = 'left alone: ' .. skip
        elseif not is_airborne(u) then
            what = 'on the ground'
        else
            local e = enemy_near(u)
            if e then
                what = ('airborne, holding: %s in range'):format(dfhack.units.getReadableName(e))
            else
                what = 'airborne, sky clear -- coming down'
            end
        end
        print(('  %-40s (%d,%d,%d) %s'):format(name, u.pos.x, u.pos.y, u.pos.z, what))
    end
end
if n == 0 then print('  no ancient dragons on this map') end
