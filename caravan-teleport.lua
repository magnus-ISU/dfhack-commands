-- Teleport stranded caravan merchants + pack animals to the trade depot.
--@ module = false
--[[
caravan-teleport

Merchants (and their pack animals) sometimes get stuck wandering the map -- unable to path back to
the trade depot -- so their goods never reach it and the caravan just sits there. This teleports
every member of a caravan that is currently AT the depot but stranded away from it (off-map, on a
different z-level, or more than a few tiles from the depot) straight onto the depot, spread across
its tiles, so they can unload and trade.

Only touches units belonging to a caravan whose trade_state is AtDepot (so departing/arriving
caravans are left alone), and never the fort's own units. Run it whenever traders are stuck:

    caravan-teleport            teleport all stranded at-depot caravan members to the depot
]]

if not dfhack.world.isFortressMode() then qerror('caravan-teleport only works in fortress mode') end

local function find_depot()
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_tradedepotst:is_instance(b) then return b end
    end
end

local dep = find_depot()
if not dep then qerror('no trade depot on this map') end
local cx, cy, cz = dep.centerx, dep.centery, dep.z

-- the entity id of every caravan that has arrived at the depot (its members belong here now)
local atdepot = {}
for _, c in ipairs(df.global.plotinfo.caravans) do
    if c.trade_state == df.caravan_state.T_trade_state.AtDepot then atdepot[c.entity] = true end
end

-- a caravan unit is stranded if it is off the map, on a different z-level, or well away from the depot
local function is_stranded(u)
    if u.pos.x == -30000 then return true end
    if u.pos.z ~= cz then return true end
    return math.abs(u.pos.x - cx) > 3 or math.abs(u.pos.y - cy) > 3
end

-- teleport onto the depot's centre tile (always walkable -- the broker stands there); DF lets the
-- units stack momentarily and they spread out on their own. (Spreading them across the depot's own
-- tiles is unreliable -- some corner tiles are occupied by goods and reject a teleport.)
local target = xyz2pos(cx, cy, cz)

local moved, by_ent = 0, {}
for _, u in ipairs(df.global.world.units.active) do
    if (u.flags1.merchant or u.flags1.diplomat) and not u.flags1.inactive
        and atdepot[u.civ_id] and dfhack.units.isAlive(u) and is_stranded(u)
    then
        if dfhack.units.teleport(u, target) then
            moved = moved + 1
            by_ent[u.civ_id] = (by_ent[u.civ_id] or 0) + 1
        end
    end
end

if moved == 0 then
    print('caravan-teleport: no stranded caravan members found (everyone is at the depot).')
else
    print(('caravan-teleport: teleported %d stranded caravan unit%s to the depot:'):format(
        moved, moved == 1 and '' or 's'))
    for eid, n in pairs(by_ent) do
        local e = df.historical_entity.find(eid)
        print(('  %s: %d'):format(e and dfhack.translation.translateName(e.name) or ('entity ' .. eid), n))
    end
    print('  (if a caravan still won\'t unload, also run `caravan unload` to reconnect pack animals.)')
end
