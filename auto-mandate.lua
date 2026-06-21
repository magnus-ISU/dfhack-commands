-- Auto-queue manager work orders to satisfy nobles' production (Make) mandates.
--@ module = false
--[[
Scans active noble mandates of type "Make" and queues a manager work order for
each unfulfilled one, choosing the cheapest / most renewable material the item
can be made from:

    * craft / jewelry items (amulet, ring, ...) -> wood
    * furniture & wooden goods                  -> wood
    * metal gear (weapons, armor, ...)          -> copper
    * stone-only goods (mechanisms, statues)    -> any (stone)

If the mandate itself demands a specific material (e.g. "a silver amulet"), that
material is used instead of the cheap default, so the order actually counts.

Safe to run repeatedly: it skips mandates that already have a matching order
queued, and only ever adds orders (never removes them). Unknown item types are
reported and skipped rather than guessed at.

    auto-mandate            queue orders for all unfulfilled Make mandates

To run it automatically, schedule it, e.g. once a day:
    repeat -name auto-mandate -time 1 -timeUnits days -command [ auto-mandate ]
]]

if not dfhack.world.isFortressMode() then
    qerror('auto-mandate only works in fortress mode')
end

-- cheapest metal: copper (resolved live so it is correct for any world)
local COPPER = dfhack.matinfo.find('COPPER')

-- item_type token -> { job token, material policy, kind }
--   kind 'craft' : set order.item_type (MakeCrafts targets a specific craft)
--   kind 'sub'   : set order.item_subtype (forge jobs pick the specific gear)
--   kind 'fixed' : the job implies the item; set neither
local W, C, A = 'wood', 'copper', 'any'
local RAW = {
    -- craft / jewelry  (Craftsdwarf's workshop)
    {'AMULET',   'MakeCrafts', W, 'craft'},
    {'RING',     'MakeCrafts', W, 'craft'},
    {'BRACELET', 'MakeCrafts', W, 'craft'},
    {'EARRING',  'MakeCrafts', W, 'craft'},
    {'CROWN',    'MakeCrafts', W, 'craft'},
    {'SCEPTER',  'MakeCrafts', W, 'craft'},
    {'FIGURINE', 'MakeCrafts', W, 'craft'},
    -- fixed wooden goods
    {'TOY',        'MakeToy',          W, 'fixed'},
    {'GOBLET',     'MakeGoblet',       W, 'fixed'},
    {'FLASK',      'MakeFlask',        W, 'fixed'},
    {'CAGE',       'MakeCage',         W, 'fixed'},
    {'BARREL',     'MakeBarrel',       W, 'fixed'},
    {'BUCKET',     'MakeBucket',       W, 'fixed'},
    {'ANIMALTRAP', 'MakeAnimalTrap',   W, 'fixed'},
    {'TOTEM',      'MakeTotem',        A, 'fixed'},  -- carved from a skull
    -- furniture (Carpenter's, wood)
    {'DOOR',       'ConstructDoor',       W, 'fixed'},
    {'FLOODGATE',  'ConstructFloodgate',  W, 'fixed'},
    {'BED',        'ConstructBed',        W, 'fixed'},  -- beds must be wood
    {'CHAIR',      'ConstructThrone',     W, 'fixed'},
    {'COFFIN',     'ConstructCoffin',     W, 'fixed'},
    {'TABLE',      'ConstructTable',      W, 'fixed'},
    {'BOX',        'ConstructChest',      W, 'fixed'},
    {'CABINET',    'ConstructCabinet',    W, 'fixed'},
    {'ARMORSTAND', 'ConstructArmorStand', W, 'fixed'},
    {'WEAPONRACK', 'ConstructWeaponRack', W, 'fixed'},
    {'BIN',        'ConstructBin',        W, 'fixed'},
    {'HATCH_COVER','ConstructHatchCover', W, 'fixed'},
    {'BLOCKS',     'ConstructBlocks',     W, 'fixed'},
    -- metal gear (Forge, copper)
    {'WEAPON',   'MakeWeapon',         C, 'sub'},
    {'ARMOR',    'MakeArmor',          C, 'sub'},
    {'HELM',     'MakeHelm',           C, 'sub'},
    {'PANTS',    'MakePants',          C, 'sub'},
    {'GLOVES',   'MakeGloves',         C, 'sub'},
    {'SHOES',    'MakeShoes',          C, 'sub'},
    {'TRAPCOMP', 'MakeTrapComponent',  C, 'sub'},
    {'CHAIN',    'MakeChain',          C, 'fixed'},
    -- cheap renewable picks for things that needn't be metal
    {'SHIELD',   'MakeShield',         W, 'sub'},   -- wooden shields
    {'AMMO',     'MakeAmmo',           W, 'sub'},   -- wooden bolts
    -- stone-only
    {'STATUE',    'ConstructStatue',      A, 'fixed'},
    {'TRAPPARTS', 'ConstructMechanisms',  A, 'fixed'},
}

-- build the lookup, silently skipping any token this version doesn't have
local MAP = {}
for _, e in ipairs(RAW) do
    local it = df.item_type[e[1]]
    local job = df.job_type[e[2]]
    if it and job then
        MAP[it] = {job = job, mat = e[3], kind = e[4]}
    end
end

-- what item_type / item_subtype the order should carry
local function order_target(m, map)
    local it, sub = -1, -1
    if map.kind == 'craft' then
        it = m.item_type
    elseif map.kind == 'sub' then
        sub = m.item_subtype
    end
    return it, sub
end

local function already_queued(job, it, sub)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == job and o.item_type == it and o.item_subtype == sub then
            return true
        end
    end
    return false
end

local function set_material(o, policy, m)
    if m.mat_type and m.mat_type >= 0 then          -- mandate demands a material
        o.mat_type = m.mat_type
        o.mat_index = m.mat_index
        local mi = dfhack.matinfo.decode(m.mat_type, m.mat_index)
        return mi and mi:toString() or 'specified material'
    elseif policy == W then
        o.material_category.wood = true
        return 'wood'
    elseif policy == C and COPPER then
        o.mat_type = COPPER.type
        o.mat_index = COPPER.index
        return 'copper'
    end
    return 'any material'                            -- leave unconstrained
end

local function item_label(m)
    local tok = df.item_type[m.item_type]
    return tok and tok:lower():gsub('_', ' ') or 'goods'
end

-- main
local mandates = df.global.world.mandates.all
local queued, skipped, existing = {}, {}, {}

for i = 0, #mandates - 1 do
    local m = mandates[i]
    if m.mode == df.mandate_type.Make and m.amount_remaining > 0 then
        local map = MAP[m.item_type]
        local label = item_label(m)
        if not map then
            table.insert(skipped, label)
        else
            local it, sub = order_target(m, map)
            if already_queued(map.job, it, sub) then
                table.insert(existing, label)
            else
                local mo = df.global.world.manager_orders
                local o = df.manager_order:new()
                o.id = mo.manager_order_next_id
                mo.manager_order_next_id = o.id + 1
                o.job_type = map.job
                o.item_type = it
                o.item_subtype = sub
                o.amount_total = m.amount_remaining
                o.amount_left = m.amount_remaining
                o.frequency = 0
                o.status.validated = true
                o.status.active = true
                local matdesc = set_material(o, map.mat, m)
                mo.all:insert('#', o)
                table.insert(queued, ('%d %s (%s)'):format(m.amount_remaining, label, matdesc))
            end
        end
    end
end

if #queued == 0 and #existing == 0 and #skipped == 0 then
    print('auto-mandate: no production mandates to fill.')
else
    if #queued > 0 then
        print(('auto-mandate: queued %d work order%s:'):format(#queued, #queued == 1 and '' or 's'))
        for _, s in ipairs(queued) do print('  + ' .. s) end
    end
    if #existing > 0 then
        print(('  (%d mandate%s already had a matching order)'):format(
            #existing, #existing == 1 and '' or 's'))
    end
    if #skipped > 0 then
        print('  skipped (no known recipe): ' .. table.concat(skipped, ', '))
    end
end
