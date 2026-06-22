-- Create steel military uniform templates, one per typical weapon type.
--@module = true
--[[
    military-uniforms            create/refresh the steel uniform set

Creates a "Steel - <weapon>" uniform template on the fort entity for each of the
typical weapons (short sword, war hammer, battle axe, spear, pick, mace,
crossbow). Each is the full steel set -- breastplate + mail shirt, helm,
gauntlets, greaves + leggings, high boots, and a shield -- plus a steel weapon of
that type, with "replace clothing" on. Exceptions: the crossbow uniform uses a
COPPER crossbow + steel buckler; the war hammer uniform uses a SILVER war hammer.

Everything is resolved generically per world: STEEL/COPPER/SILVER by inorganic
id, and every item subtype by name within the fort civ's producible lists (so it
picks the dwarf-makeable breastplate, not a modded look-alike). Re-running
refreshes the "Steel - *" templates it owns (it won't touch your own uniforms).

(Coming next: delete the default metal uniforms, assign to squads, and create the
steel/masterwork manager orders when a uniform is assigned to a soldier.)
]]

local NAME_PREFIX = 'Steel - '

-- weapon group + per-weapon overrides (material + shield kind); default = steel
local GROUP = {
    {weapon = 'short sword'},
    {weapon = 'war hammer', wmat = 'SILVER'},
    {weapon = 'battle axe'},
    {weapon = 'spear'},
    {weapon = 'pick'},
    {weapon = 'mace'},
    {weapon = 'crossbow', wmat = 'COPPER', shield = 'buckler'},
}

-- the always-steel armour set, by uniform slot (0=body 1=head 2=legs 3=hands
-- 4=feet 5=shield 6=weapon); each entry is {item_type, itemdef vec, civ list, name}
local function armour_slots(r, R, IT)
    return {
        [0] = {{IT.ARMOR, R.armor, r.armor_type, 'breastplate'},
               {IT.ARMOR, R.armor, r.armor_type, 'mail shirt'}},
        [1] = {{IT.HELM, R.helms, r.helm_type, 'helm'}},
        [2] = {{IT.PANTS, R.pants, r.pants_type, 'greaves'},
               {IT.PANTS, R.pants, r.pants_type, 'leggings'}},
        [3] = {{IT.GLOVES, R.gloves, r.gloves_type, 'gauntlet'}},
        [4] = {{IT.SHOES, R.shoes, r.shoes_type, 'high boot'}},
    }
end

local function fort_entity()
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.group_id then return e end
    end
end

local function inorganic_idx(id)
    local i = 0
    while df.inorganic_raw.find(i) do
        if df.inorganic_raw.find(i).id == id then return i end
        i = i + 1
    end
end

local function setof(vec) local s = {}; for _, x in ipairs(vec) do s[x] = true end; return s end

-- subtype by name, preferring the civ-producible one (fallback: any by name)
local function resolve_sub(vec, civ_set, name)
    for i = 0, #vec - 1 do if vec[i].name == name and civ_set[i] then return i end end
    for i = 0, #vec - 1 do if vec[i].name == name then return i end end
end

local function item_info(mattype, matindex)
    local info = df.entity_uniform_item:new()
    info.mattype, info.matindex, info.material_class = mattype, matindex, -1
    info.item_color, info.armorlevel, info.maker_race = -1, -1, -1
    info.art_image_id, info.art_image_subid = -1, -1
    info.image_thread_color, info.image_material_class = -1, -1
    info.random_dye = 0
    return info
end

-- add an item (type+subtype+material) to a uniform slot
local function add_to_slot(u, slot, item_type, subtype, mattype, matindex)
    if not subtype then return false end
    u.uniform_item_types[slot]:insert('#', item_type)
    u.uniform_item_subtypes[slot]:insert('#', subtype)
    u.uniform_item_info[slot]:insert('#', item_info(mattype, matindex))
    return true
end

-- build one "Steel - <weapon>" template and insert it on the entity
local function create_template(ent, spec, steel)
    local r, R, IT = ent.resources, df.global.world.raws.itemdefs, df.item_type
    local proto
    for i = 0, #ent.uniforms - 1 do
        if ent.uniforms[i].name:find('Melee') then proto = ent.uniforms[i]; break end
    end
    local u = df.entity_uniform:new()
    u.id = ent.next_uniform_id
    u.name = NAME_PREFIX .. spec.weapon
    u.type = proto and proto.type or 0
    u.flags.replace_clothing = true

    -- steel armour set
    for slot, items in pairs(armour_slots(r, R, IT)) do
        for _, it in ipairs(items) do
            add_to_slot(u, slot, it[1], resolve_sub(it[2], setof(it[3]), it[4]), 0, steel)
        end
    end
    -- shield (slot 5) -- always steel; buckler for crossbow
    add_to_slot(u, 5, IT.SHIELD, resolve_sub(R.shields, setof(r.shield_type), spec.shield or 'shield'), 0, steel)
    -- weapon (slot 6) -- steel unless overridden; weapons include diggers (pick)
    local wset = setof(r.weapon_type)
    for _, x in ipairs(r.digger_type) do wset[x] = true end
    local wmat = inorganic_idx(spec.wmat or 'STEEL') or steel
    add_to_slot(u, 6, IT.WEAPON, resolve_sub(R.weapons, wset, spec.weapon), 0, wmat)

    ent.uniforms:insert('#', u)
    ent.next_uniform_id = ent.next_uniform_id + 1
    return u
end

-- remove the templates this tool owns (name prefix), so re-running is clean
local function remove_owned(ent)
    local removed = 0
    for i = #ent.uniforms - 1, 0, -1 do
        if ent.uniforms[i].name:sub(1, #NAME_PREFIX) == NAME_PREFIX then
            local u = ent.uniforms[i]
            ent.uniforms:erase(i)
            u:delete()
            removed = removed + 1
        end
    end
    return removed
end

function create_steel_uniforms()
    local ent = fort_entity()
    if not ent then qerror('no fort entity') end
    local steel = inorganic_idx('STEEL')
    if not steel then qerror('no STEEL inorganic in this world') end
    local removed = remove_owned(ent)
    local made = {}
    for _, spec in ipairs(GROUP) do
        local u = create_template(ent, spec, steel)
        made[#made + 1] = u.name
    end
    return made, removed
end

if dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then qerror('military-uniforms only works in fortress mode') end
local made, removed = create_steel_uniforms()
if removed > 0 then print(('military-uniforms: refreshed (removed %d old)'):format(removed)) end
print(('military-uniforms: created %d steel uniform templates:'):format(#made))
for _, n in ipairs(made) do print('  + ' .. n) end
