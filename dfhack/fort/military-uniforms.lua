-- Create steel military uniform templates and pin each soldier's actual gear items.
--@module = true
--@enable = true
--[[
    military-uniforms            create/refresh the steel uniform set
    military-uniforms orders     run one gear cycle (pin items + queue orders), once
    enable military-uniforms     background: pin gear items and queue orders as
                                 soldiers are assigned uniforms
    disable military-uniforms    stop the background service

Creates a "<Metal> - <weapon>" uniform template on the fort entity for each of the
typical weapons (short sword, war hammer, battle axe, spear, pick, mace,
crossbow). Each is the full metal set -- breastplate + mail shirt, helm,
gauntlets, greaves, high boots, and a shield -- plus a weapon of
that type, with "replace clothing" on. Exceptions: the crossbow uniform uses a
COPPER crossbow + buckler; the war hammer uniform uses a SILVER war hammer.

HOW GEAR IS ASSIGNED (rewritten -- see "the model" below)
Every soldier is given a CUSTOM uniform: for each slot their uniform asks for, the
service picks one specific item out of the fort's stock and pins it to them, using
DF's own "specific item" uniform mode. Nobody shares a claim, so there is no stock
accounting, no backup-metal stocking, and no re-solve churn -- a pinned item is the
player's explicit choice as far as DF is concerned, so DF's equipment solver does
not second-guess it.

Asking what to PRODUCE then becomes trivial: anything a soldier is supposed to have
but isn't pinned (nothing suitable in stock), or is pinned only to an inferior
stand-in (wrong material), is exactly one order.

SIZED PER WEARER: gear is sized to each soldier's RACE. A piece only counts as
pinnable for a soldier if its size fits them (an item records its size in
maker_race), and orders for non-dwarf soldiers set the manager order's
specdata.race so the forge makes their size.

The Equip screen overlay (dwarfmode/Squads/Equipment/Default) has four toggles. Queue gear
orders, Upgrade to masterwork, and Forge Steel Tools show "Done" (instead of "On") once
there is nothing left to do (every soldier fully pinned / everything masterwork / every
miner has a masterwork steel pick).
  Queue gear orders (Shift-G)      pins each soldier's gear from stock and forges what is
                                   still missing or only stood in for, keeping 3 bars of
                                   each metal in reserve for moods, and serving dwarves in
                                   the "Military" work detail first
  Upgrade to masterwork (Shift-M)  additionally treats a pinned piece below masterwork
                                   quality as something still owed, so the service forges
                                   masterworks and re-pins soldiers onto them as they
                                   appear; melts surplus unclaimed inferior copies to fund
                                   the re-forging when bars run short
  Forge Steel Tools (Shift-P)      OFF by default. Keeps one steel pick per miner (Mining labor)
                                   AND one steel battle axe per woodcutter (Wood Cutting labor) in
                                   stock, forged one at a time, respecting the bar reserve. Honours
                                   Upgrade to masterwork (targets a masterwork tool each). Out of
                                   steel bars, it recycles surplus steel gear into bars. When a
                                   tool type is complete, FORBIDS every other (non-steel) one so the
                                   workers switch to steel -- but never a battle axe a SOLDIER holds
                                   (the military's steel axes are left alone, not miscounted either).
                                   This is the OLD pre-pinning path, kept as-is: a mining-labor
                                   dwarf cannot be uniformed at all (a DF conflict), so their pick
                                   has to be handled outside the uniform system.
  Train surplus war dogs (Shift-D) war-train adult male dogs beyond BREEDER_MALES
                                   breeders (Pets/Livestock training, done by an Animal
                                   Trainer -- not the soldiers). A male PUPPY counts toward
                                   the breeder reserve (it'll grow into one), so 2 adults +
                                   1 male pup trains one adult. Finished war dogs are then
                                   auto-assigned (owner link) to squad members, spread
                                   evenly across the military.
]]

-- weapon group + per-weapon overrides (material + shield kind); default = steel
local GROUP = {
    {weapon = 'short sword'},
    {weapon = 'battle axe'},
    {weapon = 'war hammer', wmat = 'SILVER'},
    {weapon = 'spear'},
    {weapon = 'mace'},
    {weapon = 'pick'},
    {weapon = 'crossbow', wmat = 'COPPER', shield = 'buckler'},
}

-- civilian uniforms: "Civilian - <weapon>", same steel/leather/bone/wood set, one per weapon
local CIVILIAN_GROUP = {
    {weapon = 'battle axe', wmat = 'STEEL'},
    {weapon = 'mace', wmat = 'SILVER'},
}

-- our templates are named "<Metal> - <weapon>" (metal varies with the copper
-- fallback), so we recognise our own by the weapon suffix, not a fixed prefix.
local WEAPON_SET = {}
for _, s in ipairs(GROUP) do WEAPON_SET[s.weapon] = true end
local function is_civilian_name(name) return name:find('^Civilian %- ') ~= nil end
local function is_owned_name(name)
    local w = name:match('^.+ %- (.+)$')     -- "Steel - X" and "Civilian - X" both match by weapon
    return w ~= nil and WEAPON_SET[w] == true
end

-- the always-steel armour set, by uniform slot (0=body 1=head 2=legs 3=hands
-- 4=feet 5=shield 6=weapon); each entry is {item_type, itemdef vec, civ list, name}
local function armour_slots(r, R, IT)
    return {
        [0] = {{IT.ARMOR, R.armor, r.armor_type, 'breastplate'},
               {IT.ARMOR, R.armor, r.armor_type, 'mail shirt'}},
        [1] = {{IT.HELM, R.helms, r.helm_type, 'helm'}},
        [2] = {{IT.PANTS, R.pants, r.pants_type, 'greaves'}},   -- no leggings: they
                                                                -- conflict with greaves and never equip
        -- gauntlets and high boots are listed TWICE: the wearer needs two of each, and the
        -- pin model gives every item its own spec (see ensure_pair_specs). Declaring the
        -- pair in the template keeps a squad position the same SHAPE as the template it was
        -- applied from -- DF stores no squad->template link and matches by content, so a
        -- position with two glove specs against a template with one stops being recognised
        -- as that uniform at all.
        [3] = {{IT.GLOVES, R.gloves, r.gloves_type, 'gauntlet'},
               {IT.GLOVES, R.gloves, r.gloves_type, 'gauntlet'}},
        [4] = {{IT.SHOES, R.shoes, r.shoes_type, 'high boot'},
               {IT.SHOES, R.shoes, r.shoes_type, 'high boot'}},
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

local function item_info(mattype, matindex, matclass)
    local info = df.entity_uniform_item:new()
    info.mattype, info.matindex = mattype or -1, matindex or -1
    info.material_class = matclass or -1          -- e.g. Leather / Bone for non-metal pieces
    info.item_color, info.armorlevel, info.maker_race = -1, -1, -1
    info.art_image_id, info.art_image_subid = -1, -1
    info.image_thread_color, info.image_material_class = -1, -1
    info.random_dye = 0
    return info
end

-- add an item to a uniform slot: either a specific material (mattype/matindex, e.g. steel) OR a
-- material CLASS (matclass, an entity_material_category like Leather/Bone) for non-metal pieces.
local function add_to_slot(u, slot, item_type, subtype, mattype, matindex, matclass)
    if not subtype then return false end
    u.uniform_item_types[slot]:insert('#', item_type)
    u.uniform_item_subtypes[slot]:insert('#', subtype)
    u.uniform_item_info[slot]:insert('#', item_info(mattype, matindex, matclass))
    return true
end

-- an item (bar / ore boulder) that is REALLY on hand -- one a forge job could claim.
-- Excludes items built into a building (e.g. the bars of a steel bridge), items inside
-- a constructed wall/floor, a merchant's goods, and forbidden/dumped/inaccessible ones.
-- Without this, bars locked in a bridge satisfied the bar reserve on paper while the
-- real stock was already gone.
local function on_hand(it)
    local f = it.flags
    return not (f.in_building or f.construction or f.trader or f.forbid
        or f.dump or f.garbage_collect or f.encased or f.on_fire)
end

-- NOTE: there used to be a resolve_metal() here that swapped the whole armour set to COPPER
-- whenever zero steel bars were on hand at the moment the templates were built. Because
-- magnus-scripts re-runs template creation every session, one session that happened to start
-- with no steel bars silently rebuilt the fort's entire military as "Copper - <weapon>" --
-- renamed AND with copper armour in the specs, which is a permanent downgrade of every squad
-- the uniform is later applied to. It also contradicted the core rule that THE UNIFORM IS
-- NEVER EDITED: the uniform states the goal, and a shortage is handled by making a cheaper
-- STAND-IN (see queue_standins) which soldiers wear until the real thing is forged. So the
-- templates now always ask for their intended metal. Deliberate per-weapon exceptions
-- (SILVER war hammer, COPPER crossbow) live in GROUP and are unaffected.

-- "STEEL" -> "Steel", "COPPER" -> "Copper" (for the template name)
local function metal_name(idx)
    local raw = idx and df.inorganic_raw.find(idx)
    local id = (raw and raw.id) or 'Metal'
    return id:sub(1, 1):upper() .. id:sub(2):lower()
end

-- build one "<Metal> - <weapon>" template and insert it on the entity. Armour (and
-- shield) use `armour`; the weapon uses `wmat`.
local function create_template(ent, spec, armour, wmat)
    local r, R, IT = ent.resources, df.global.world.raws.itemdefs, df.item_type
    local proto
    for i = 0, #ent.uniforms - 1 do
        if ent.uniforms[i].name:find('Melee') then proto = ent.uniforms[i]; break end
    end
    local u = df.entity_uniform:new()
    u.id = ent.next_uniform_id
    u.name = metal_name(armour) .. ' - ' .. spec.weapon
    u.type = proto and proto.type or 0
    u.flags.replace_clothing = true

    -- armour set (armour metal -- steel, or copper if steel is unavailable)
    for slot, items in pairs(armour_slots(r, R, IT)) do
        for _, it in ipairs(items) do
            add_to_slot(u, slot, it[1], resolve_sub(it[2], setof(it[3]), it[4]), 0, armour)
        end
    end
    -- leather CLOAK (over-layer, slot 0) -- always leather regardless of the armour metal. Leather
    -- wears out, so the service replaces a damaged one and the dwarf re-equips it.
    add_to_slot(u, 0, IT.ARMOR, resolve_sub(R.armor, setof(r.armor_type), 'cloak'),
                -1, -1, df.entity_material_category.Leather)
    -- shield (slot 5) -- armour metal; buckler for crossbow
    add_to_slot(u, 5, IT.SHIELD, resolve_sub(R.shields, setof(r.shield_type), spec.shield or 'shield'), 0, armour)
    -- weapon (slot 6) -- its own metal (steel unless overridden); weapons include diggers (pick)
    local wset = setof(r.weapon_type)
    for _, x in ipairs(r.digger_type) do wset[x] = true end
    add_to_slot(u, 6, IT.WEAPON, resolve_sub(R.weapons, wset, spec.weapon), 0, wmat)

    ent.uniforms:insert('#', u)
    ent.next_uniform_id = ent.next_uniform_id + 1
    return u
end

-- the standalone "civilian" uniform: steel helm/gauntlets/high boots + steel battle axe, a LEATHER
-- body armour, BONE greaves, and a WOOD shield. "Wear clothing under armor" is OFF
-- (replace_clothing = true). Meant to be assigned to civilians for light self-defence gear.
local function create_civilian_uniform(ent, spec)
    local r, R, IT = ent.resources, df.global.world.raws.itemdefs, df.item_type
    local proto
    for i = 0, #ent.uniforms - 1 do
        if ent.uniforms[i].name:find('Melee') then proto = ent.uniforms[i]; break end
    end
    local steel = inorganic_idx('STEEL')
    local wmat = inorganic_idx(spec.wmat or 'STEEL') or steel
    local u = df.entity_uniform:new()
    u.id = ent.next_uniform_id
    u.name = 'Civilian - ' .. spec.weapon
    u.type = proto and proto.type or 0
    u.flags.replace_clothing = true                                          -- no clothing under armour
    add_to_slot(u, 1, IT.HELM,   resolve_sub(R.helms,  setof(r.helm_type),   'helm'),      0, steel)
    add_to_slot(u, 3, IT.GLOVES, resolve_sub(R.gloves, setof(r.gloves_type), 'gauntlet'),  0, steel)
    add_to_slot(u, 4, IT.SHOES,  resolve_sub(R.shoes,  setof(r.shoes_type),  'high boot'), 0, steel)
    add_to_slot(u, 0, IT.ARMOR,  resolve_sub(R.armor,  setof(r.armor_type),  'armor'),     -- leather body armour
                -1, -1, df.entity_material_category.Leather)
    add_to_slot(u, 2, IT.PANTS,  resolve_sub(R.pants,  setof(r.pants_type),  'greaves'),   -- bone greaves
                -1, -1, df.entity_material_category.Bone)
    add_to_slot(u, 5, IT.SHIELD, resolve_sub(R.shields, setof(r.shield_type), 'shield'),   -- wood shield
                -1, -1, df.entity_material_category.Wood)
    add_to_slot(u, 6, IT.WEAPON, resolve_sub(R.weapons, setof(r.weapon_type), spec.weapon), 0, wmat)  -- steel axe / silver mace
    ent.uniforms:insert('#', u)
    ent.next_uniform_id = ent.next_uniform_id + 1
    return u
end

-- resolve the leather-cloak armour subtype once
local cloak_sub_cache
local function cloak_subtype(ent)
    if cloak_sub_cache == nil then
        cloak_sub_cache = resolve_sub(df.global.world.raws.itemdefs.armor,
                                      setof(ent.resources.armor_type), 'cloak') or false
    end
    return cloak_sub_cache or nil
end

-- make sure the owned "Steel - *" uniform TEMPLATES include a leather cloak (slot 0).
-- Templates ONLY: squad positions pick the cloak up when their uniform is applied from a
-- template; this function must never write into a squad position's resolved gear (it used
-- to, which meant silently modifying every squad member's uniform every day -- removed).
-- The civilian uniform is skipped (it has no cloak).
local function ensure_cloaks(ent)
    local sub = cloak_subtype(ent)
    if not sub then return end
    for i = 0, #ent.uniforms - 1 do
        local u = ent.uniforms[i]
        if is_owned_name(u.name) and not is_civilian_name(u.name) then
            local has = false
            for j = 0, #u.uniform_item_types[0] - 1 do
                if u.uniform_item_types[0][j] == df.item_type.ARMOR
                    and u.uniform_item_subtypes[0][j] == sub then has = true; break end
            end
            if not has then
                add_to_slot(u, 0, df.item_type.ARMOR, sub, -1, -1, df.entity_material_category.Leather)
            end
        end
    end
    -- PAIR ENTRIES: every owned template (military AND civilian) must declare gauntlets and
    -- high boots TWICE, so a position split into one spec per item still matches the shape
    -- of the template it came from. Migrates templates created before the pair split.
    for i = 0, #ent.uniforms - 1 do
        local u = ent.uniforms[i]
        if is_owned_name(u.name) then
            for _, pair in ipairs({{slot = 3, it = df.item_type.GLOVES},
                                   {slot = 4, it = df.item_type.SHOES}}) do
                local types = u.uniform_item_types[pair.slot]
                local n = 0
                for j = 0, #types - 1 do if types[j] == pair.it then n = n + 1 end end
                if n == 1 then
                    -- duplicate the existing entry exactly (subtype + material spec)
                    local idx
                    for j = 0, #types - 1 do if types[j] == pair.it then idx = j; break end end
                    local info = u.uniform_item_info[pair.slot][idx]
                    add_to_slot(u, pair.slot, pair.it, u.uniform_item_subtypes[pair.slot][idx],
                                info.mattype, info.matindex, info.material_class)
                end
            end
        end
    end
end

-- remove the templates this tool owns (name prefix), so re-running is clean
local function remove_owned(ent)
    local removed = 0
    for i = #ent.uniforms - 1, 0, -1 do
        if is_owned_name(ent.uniforms[i].name) then
            local u = ent.uniforms[i]
            ent.uniforms:erase(i)
            u:delete()
            removed = removed + 1
        end
    end
    return removed
end

-- a default "metal armour" uniform: not one of ours, and its body armour uses the
-- generic Armor material class (the auto-generated metal uniform) rather than a
-- specific metal (our steel = mattype 0) or leather/cloth (material_class Leather).
local function is_metal_default(u)
    if is_owned_name(u.name) then return false end
    local info = u.uniform_item_info[0]
    return #info > 0 and info[0].material_class == df.entity_material_category.Armor
end

-- delete the default metal uniforms (leather ones stay); returns their names
local function delete_metal_defaults(ent)
    local names = {}
    for i = #ent.uniforms - 1, 0, -1 do
        if is_metal_default(ent.uniforms[i]) then
            names[#names + 1] = ent.uniforms[i].name
            local u = ent.uniforms[i]
            ent.uniforms:erase(i)
            u:delete()
        end
    end
    return names
end

-- put the entity's uniforms in a tidy order: the military "Steel - *" set (GROUP order), then the
-- "Civilian - *" set (CIVILIAN_GROUP order), then the two default "..., leather armor" uniforms at
-- the very end. Anything else keeps its relative order after. Reorders the pointer vector IN PLACE
-- (reassigns slots, no delete/insert), so uniform ids and squad assignments are untouched.
local function reorder_uniforms(ent)
    local mil, civ, defs, others = {}, {}, {}, {}
    for i = 0, #ent.uniforms - 1 do
        local u = ent.uniforms[i]
        local name = u.name
        if is_civilian_name(name) then
            civ[name:match('^Civilian %- (.+)$')] = u
        elseif is_owned_name(name) then
            mil[name:match('.+ %- (.+)$')] = u
        elseif name == 'Melee, leather armor' or name == 'Crossbows, leather armor' then
            defs[name] = u
        else
            others[#others + 1] = u
        end
    end
    local ordered = {}
    for _, s in ipairs(GROUP) do if mil[s.weapon] then ordered[#ordered + 1] = mil[s.weapon] end end
    for _, s in ipairs(CIVILIAN_GROUP) do if civ[s.weapon] then ordered[#ordered + 1] = civ[s.weapon] end end
    if defs['Melee, leather armor'] then ordered[#ordered + 1] = defs['Melee, leather armor'] end
    if defs['Crossbows, leather armor'] then ordered[#ordered + 1] = defs['Crossbows, leather armor'] end
    for _, u in ipairs(others) do ordered[#ordered + 1] = u end
    if #ordered == #ent.uniforms then
        for i = 0, #ent.uniforms - 1 do ent.uniforms[i] = ordered[i + 1] end
    end
end

function create_steel_uniforms()
    local ent = fort_entity()
    if not ent then qerror('no fort entity') end
    local steel = inorganic_idx('STEEL')
    if not steel then qerror('no STEEL inorganic in this world') end
    local armour = steel          -- always: a shortage is met with stand-ins, not a downgrade
    remove_owned(ent)
    local made = {}
    for _, spec in ipairs(GROUP) do
        local wmat = inorganic_idx(spec.wmat or 'STEEL') or steel
        local u = create_template(ent, spec, armour, wmat)
        made[#made + 1] = u.name
    end
    for _, spec in ipairs(CIVILIAN_GROUP) do
        made[#made + 1] = create_civilian_uniform(ent, spec).name
    end
    local deleted_metal = delete_metal_defaults(ent)
    reorder_uniforms(ent)
    return made, deleted_metal
end

-- =============================================================================
-- THE MODEL
--
-- DF keeps a squad's uniform on the POSITION -- squad_position.equipment.uniform[slot],
-- a vector of squad_uniform_spec -- and NOT on the squad: there is no squad ->
-- entity_uniform link anywhere in the structures (`squad` carries only
-- `uniform_priority`). The position outlives its occupant: removing a dwarf leaves the
-- specs in place, which is why a fresh recruit dropped into that slot already wears the
-- right uniform. The position specs are therefore the one persistent record of what a
-- soldier is SUPPOSED to have, and this service never writes their filter fields
-- (item_type / item_subtype / mattype / matindex / material_class). It only ever fills
-- in WHICH ITEM satisfies them:
--
--   * `spec.assigned` (plus the position's assigned_items) is what actually makes a dwarf
--     GO AND FETCH a piece. It is written for EVERY slot. `spec.item` alone does nothing:
--     DF never back-fills `assigned` from it, so a slot pinned that way sits unequipped
--     forever with no pickup job -- measured live, see pin_single.
--   * `spec.item` is additionally set on SINGLETON slots: DF's native "specific item" pin,
--     which records the choice, shows on the Equip screen, and stops the solver re-solving
--     the slot out from under us. PAIR slots (gauntlets / high boots: ONE spec, TWO items)
--     cannot use it -- it names only one item -- so they rely on `assigned` alone.
--
-- Reading intent back is just reading the spec, and that also settles ownership with no
-- persisted bookkeeping at all:
--
--   spec.item >= 0, filters all -1    a HAND-PICKED specific item -- the player's, or
--                                     noble-warriors' symbols of office. NEVER touched.
--   spec.item >= 0, filters present   OUR pin. May be re-pinned (stand-in -> exact
--                                     material, or an upgrade to masterwork).
--   spec.item <  0, filters present   an unpinned filter spec -- ours to fill.
--
-- A spec naming a material we would never ask for (an adamantine short sword on an
-- otherwise steel uniform) is the player customising that slot: we skip THAT property
-- and leave the rest of their uniform managed.
-- =============================================================================

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')
local utils = require('utils')

local GLOBAL_KEY = 'military-uniforms'
local DAY_TICKS = 1200
local BARS_PER_ITEM = 1   -- metal gear (armour/weapon) = ~1 bar each
local RESERVE_BARS = 3    -- keep this many bars of each metal free (moods / other jobs)
local BREEDER_MALES = 2   -- adult male dogs kept untrained for breeding
local MAX_WEAR = 1        -- a piece worn beyond this is not worth pinning to anyone

-- weapon subtype for the mining pick (ITEM_WEAPON_PICK), resolved per world
local function pick_subtype()
    local w = df.global.world.raws.itemdefs.weapons
    for i = 0, #w - 1 do if w[i].id == 'ITEM_WEAPON_PICK' then return i end end
end
-- weapon subtype for the wood-cutting axe (ITEM_WEAPON_AXE_BATTLE), resolved per world
local function axe_subtype()
    local w = df.global.world.raws.itemdefs.weapons
    for i = 0, #w - 1 do if w[i].id == 'ITEM_WEAPON_AXE_BATTLE' then return i end end
end

-- makeable equipment item_type -> Make job
local MAKE_JOB = {
    [df.item_type.ARMOR]  = df.job_type.MakeArmor,
    [df.item_type.HELM]   = df.job_type.MakeHelm,
    [df.item_type.PANTS]  = df.job_type.MakePants,
    [df.item_type.GLOVES] = df.job_type.MakeGloves,
    [df.item_type.SHOES]  = df.job_type.MakeShoes,
    [df.item_type.SHIELD] = df.job_type.MakeShield,
    [df.item_type.WEAPON] = df.job_type.MakeWeapon,
}

-- item_type -> the plotinfo.equipment.update dirty-flag field that makes DF act on a
-- changed assignment for that slot (generate the pickup job / drop the old piece)
local UPDATE_FIELD = {
    [df.item_type.ARMOR]  = 'armor',
    [df.item_type.HELM]   = 'helm',
    [df.item_type.PANTS]  = 'pants',
    [df.item_type.GLOVES] = 'gloves',
    [df.item_type.SHOES]  = 'shoes',
    [df.item_type.SHIELD] = 'shield',
    [df.item_type.WEAPON] = 'weapon',
}

-- item_type -> the world.items.other vector to scan for candidates. Scanning these
-- (a few thousand entries) instead of world.items.all (hundreds of thousands) is what
-- keeps a cycle cheap enough to run on DF's main thread.
local OTHER_VEC = {
    [df.item_type.ARMOR]  = df.items_other_id.ARMOR,
    [df.item_type.HELM]   = df.items_other_id.HELM,
    [df.item_type.PANTS]  = df.items_other_id.PANTS,
    [df.item_type.GLOVES] = df.items_other_id.GLOVES,
    [df.item_type.SHOES]  = df.items_other_id.SHOES,
    [df.item_type.SHIELD] = df.items_other_id.SHIELD,
    [df.item_type.WEAPON] = df.items_other_id.WEAPON,
}

-- gauntlets and high boots are worn as PAIRS: the uniform lists them once but the
-- soldier wears two, so one spec owns TWO items.
-- worn as a matched pair: the slot is split into one spec per item by ensure_pair_specs,
-- after which nothing else in the pin pass needs to treat them specially
local PAIR_TYPES = {[df.item_type.GLOVES] = true, [df.item_type.SHOES] = true}
-- GAUNTLETS are HANDED (left/right, via the item's `handedness` bitarray): a soldier needs
-- one of EACH hand, not just any two. HIGH BOOTS have no handedness, so any two will do.
local HANDED = {[df.item_type.GLOVES] = true}
-- which hand an item is (0 or 1); handedness bit 1 = one hand, bit 0/none = the other
local function item_hand(it)
    local ok, h = pcall(function() return it.handedness end)
    if ok and h and h[1] then return 1 end
    return 0
end

local function item_wear(it)
    local ok, w = pcall(function() return it.wear end)
    return (ok and w) or 0
end

-- ---- sizing -----------------------------------------------------------------
-- ARMOR MUST BE SIZED TO THE WEARER. A dwarf fort forges non-dwarf-sized armor by setting a
-- manager order's specdata.race; the finished item records that size in its maker_race.
--
-- HYENA-MAN is a universal size -- its wearer sits between dwarves (6000) and humans (7000),
-- so hyena-man armor fits BOTH. We MAKE hyena-man armor for dwarves (slightly better than
-- dwarf-sized, and it cross-fits), and dwarves ACCEPT either hyena-man OR dwarf-sized.
-- Humans make and accept human-sized armor.
local function civ_race() return df.global.plotinfo.race_id end
-- SHIELDS and WEAPONS are HELD, not worn -- one size fits all, so they are never sized per
-- wearer; they always key to civ size on both the requirement and the stock side.
local SIZELESS = {[df.item_type.SHIELD] = true, [df.item_type.WEAPON] = true}

-- hyena-man creature index (our universal armor size), resolved once (raws are static)
local hyena_cache
local function hyena_race()
    if hyena_cache ~= nil then return hyena_cache or nil end
    local all = df.global.world.raws.creatures.all
    for i = 0, #all - 1 do
        if all[i].creature_id == 'HYENA_MAN' then hyena_cache = i; return i end
    end
    hyena_cache = false
    return nil
end

-- the size race to MAKE armor for a wearer of `race`: hyena-man for dwarves, else the
-- wearer's own race. Sizeless gear is always civ size. This is the req/order key size.
local function key_race(item_type, race)
    if SIZELESS[item_type] then return civ_race() end
    local h = hyena_race()
    if h and race == civ_race() then return h end   -- dwarf -> hyena-man
    return race
end

-- which size key an item's ACTUAL size satisfies: a hyena- OR dwarf-sized piece both cover
-- the dwarf (hyena) key; anything else keys to its own maker race. Sizeless -> civ.
local function item_size_race(it)
    if SIZELESS[it:getType()] then return civ_race() end
    local ok, r = pcall(function() return it.maker_race end)
    local m = (ok and r and r >= 0) and r or civ_race()
    local h = hyena_race()
    if h and (m == civ_race() or m == h) then return h end   -- dwarf/hyena-sized -> hyena key
    return m
end

-- WEARABILITY IS ABOUT BODY SIZE, NOT RACE IDENTITY. Measured in this world:
--   DWARF 6000, ELF 6000, GOBLIN 6000, HYENA_MAN 6500, HUMAN 7000, KOBOLD 2000
-- so elf- and goblin-made armour is EXACTLY dwarf-sized and perfectly wearable, hyena-man
-- is loose but fine, human is too big. Matching on the maker's race INDEX (which this did
-- before) threw all of that away: 20 free leather cloaks sat unusable, marked "wrong size",
-- while four soldiers had no cloak at all. Fits = same size, up to ~10% larger.
local SIZE_TOLERANCE = 1.10
local adult_size_cache = {}
local function adult_size(race)
    local v = adult_size_cache[race]
    if v == nil then
        local c = df.creature_raw.find(race)
        v = (c and #c.caste > 0 and c.caste[0].misc.adult_size) or 0
        adult_size_cache[race] = v
    end
    return v
end

-- the body size a worn item was made for; 0 for held gear (shields/weapons: one size fits all)
local function item_maker_size(it)
    if SIZELESS[it:getType()] then return 0 end
    local ok, mr = pcall(function() return it.maker_race end)
    local m = (ok and mr and mr >= 0) and mr or civ_race()
    return adult_size(m)
end

local function size_fits(item_size, wearer_size)
    if item_size == 0 or wearer_size == 0 then return true end
    return item_size >= wearer_size and item_size <= wearer_size * SIZE_TOLERANCE
end

-- the race the soldier occupying a squad position is (for sizing their gear)
local function occupant_race(pos)
    local hf = pos.occupant >= 0 and df.historical_figure.find(pos.occupant)
    local u = hf and df.unit.find(hf.unit_id)
    return (u and u.race) or civ_race()
end

-- ---- non-metal materials (wood shields, leather cloaks/armour, bone greaves) -------------
-- A gear material in our keys/orders is a (mat_type, mat_index) pair: a METAL is (0, inorganic
-- idx); a WOOD / LEATHER / BONE piece is (-1, entity_material_category). MATCLASS maps that
-- category to the manager-order material_category field (to MAKE it) and the material_flags bit
-- (to DETECT it in stock).
local MATCLASS = {
    [df.entity_material_category.Leather] = {order = 'leather', flag = df.material_flags.LEATHER},
    [df.entity_material_category.Bone]    = {order = 'bone',    flag = df.material_flags.BONE},
    [df.entity_material_category.Wood]    = {order = 'wood',    flag = df.material_flags.WOOD},
}
local function is_matclass(mt, mi) return mt == -1 and MATCLASS[mi] ~= nil end
-- the non-metal class (a MATCLASS key) of an item, or nil. (Only called for gear items.)
local function item_matclass(it)
    local mi = dfhack.matinfo.decode(it)
    if not (mi and mi.material) then return nil end
    local f = mi.material.flags
    for cat, spec in pairs(MATCLASS) do
        if f[spec.flag] then return cat end
    end
    return nil
end
-- the (mat_type, mat_index) key pair for an ITEM: metal -> (0, idx); wood/leather/bone ->
-- (-1, category); anything else its raw material.
local function item_matpair(it)
    if it:getMaterial() == 0 then return 0, it:getMaterialIndex() end
    local cls = item_matclass(it)
    if cls then return -1, cls end
    return it:getMaterial(), it:getMaterialIndex()
end
-- the (mat_type, mat_index) key pair for a UNIFORM spec's material: a specific material
-- (mattype >= 0, e.g. steel) stays; a material CLASS (material_class >= 0) becomes
-- (-1, category). Returns nil for a bare "any material" slot we don't manage.
local function uniform_matpair(spec)
    if spec.mattype >= 0 then return spec.mattype, spec.matindex end
    if spec.material_class >= 0 and MATCLASS[spec.material_class] then return -1, spec.material_class end
    return nil
end

-- How good a metal is as ARMOUR/WEAPON stock, best first -- used both to choose the best
-- stand-in already in stock and to decide what to forge when the demanded metal is
-- unaffordable. Deliberately NOT the raw's material_value: that is an economic price, and
-- by it SILVER outranks IRON, which would put soldiers in soft silver breastplates. Silver
-- is last here for the same reason (it is only ever wanted where a uniform asks for it, on
-- war hammers). Anything unlisted -- including wood/leather/bone -- sorts after all metals.
local STANDIN_ORDER = {'STEEL', 'IRON', 'BRONZE', 'BISMUTH_BRONZE', 'COPPER', 'SILVER'}
local WOOD_SHIELD_RANK = 1.5     -- better than iron (2), below the demanded steel (1)
local metal_rank_cache
local function metal_rank(mt, mi, item_type)
    if mt ~= 0 then
        -- A WOODEN SHIELD IS PREFERRED over any metal stand-in: it costs no bars at all and
        -- blocks just as well while weighing far less. Only the material the uniform
        -- actually demands outranks it.
        if item_type == df.item_type.SHIELD and mi == df.entity_material_category.Wood then
            return WOOD_SHIELD_RANK
        end
        return #STANDIN_ORDER + 1                          -- other material classes: worst
    end
    if not metal_rank_cache then
        metal_rank_cache = {}
        for i, id in ipairs(STANDIN_ORDER) do
            local idx = inorganic_idx(id)
            if idx then metal_rank_cache[idx] = i end
        end
    end
    return metal_rank_cache[mi] or (#STANDIN_ORDER + 1)
end

-- MATERIALS THIS SERVICE IS WILLING TO ASK FOR. A uniform spec naming anything else -- the
-- adamantine short sword on an otherwise steel uniform -- is the player customising that
-- slot by hand: we leave that property alone entirely (no pin, no order), while still
-- managing the rest of that soldier's uniform.
local MANAGED_METALS = {'STEEL', 'IRON', 'COPPER', 'BRONZE', 'BISMUTH_BRONZE', 'SILVER'}
local managed_cache
local function managed_materials()
    if managed_cache then return managed_cache end
    local set = {}
    for _, id in ipairs(MANAGED_METALS) do
        local idx = inorganic_idx(id)
        if idx then set['0/' .. idx] = true end
    end
    for cat in pairs(MATCLASS) do set['-1/' .. cat] = true end
    managed_cache = set
    return set
end

-- ---- stock / ownership helpers ------------------------------------------------

-- world.items.other also lists items the fort doesn't possess -- named artifacts and gear
-- carried by offsite historical figures (UNIT_HOLDER to a unit not loaded here, or a
-- non-civ unit). A "fort stock" item is one with no unit holder (stockpile/building/ground)
-- OR held by one of our own loaded dwarves.
local function not_fort_stock(it)
    for _, r in ipairs(it.general_refs) do
        if r:getType() == df.general_ref_type.UNIT_HOLDER then
            local u = df.unit.find(r.unit_id)
            return not (u and dfhack.units.isOwnCiv(u))
        end
    end
    return false
end

-- is this item built into a building? Such a piece can never be equipped by a soldier:
-- a weapon locked in a weapon TRAP, or a piece on DISPLAY in a case / pedestal (the
-- player put it there on purpose). Never pinnable, never a melt candidate.
local function item_installed(it) return it.flags.in_building end

-- the unit holding an item (worn / wielded / hauled), or nil
local function holder_of(it)
    return dfhack.items.getHolderUnit(it)
end

-- ---- unsticking: why an assigned piece never reaches its soldier -------------
-- Writing spec.assigned is necessary but NOT sufficient. Several states silently block a
-- pickup, all measured on this fort (assignments correct, PickupEquipment jobs = 0). The
-- list below is the one PunPun's "Military Reequip" workshop mod fixes, which is where the
-- diagnosis came from:
--   * the piece sits inside a BIN -- DF frequently never fetches uniform items out of one
--   * flags.in_job is set while NO live job references the item (a stale claim)
--   * flags.owned is set with no actual owner (stale ownership), or it is someone's property
--   * the soldier is simply never given a PickupEquipment job

-- item ids referenced by any live job. Built ONCE per cycle: the naive form (re-walk the
-- job list per item) is O(items x jobs) and would freeze DF's main thread. Read-only --
-- never mutate a live job's item list from here, that segfaults DF.
local function live_job_items()
    local set = {}
    local link = df.global.world.jobs.list.next
    local guard = 0
    while link and guard < 4000 do
        guard = guard + 1
        local j = link.item
        if j then
            for _, jr in ipairs(j.items) do
                if jr.item then set[jr.item.id] = true end
            end
        end
        link = link.next
    end
    return set
end

-- a stale in_job claim: the flag is set but nothing is actually fetching the item, so it
-- would block pickup forever. Returns true if the item is (now) free of a job claim.
local function clear_stale_in_job(it, jobitems)
    if not it.flags.in_job then return true end
    if jobitems[it.id] then return false end        -- a real job wants it: leave it alone
    if not dry_run then it.flags.in_job = false end
    return true
end

-- the unit id that owns this item, or nil. Clears the flag when it is stale (owned set with
-- no owner), a common corruption that hides perfectly good gear.
local function owner_id_of(it)
    if not it.flags.owned then return nil end
    local ow = dfhack.items.getOwner(it)
    if ow == nil then
        if not dry_run then it.flags.owned = false end
        return nil
    end
    return ow.id
end

-- is this item somebody ELSE's personal property? DF will never hand a dwarf another
-- dwarf's belongings, so such a piece can be assigned but will sit unfetched forever --
-- which is exactly how eight soldiers ended up with a permanently pending leather cloak
-- that was some civilian's clothing. Pass the wearer's unit id; nil means "anyone's
-- property disqualifies it".
local function owned_by_other(it, unit_id)
    local oid = owner_id_of(it)
    return oid ~= nil and oid ~= unit_id
end

-- lift a piece out of its BIN onto the floor the bin stands on, so a soldier can reach it
local function free_from_bin(it)
    local c = dfhack.items.getContainer(it)
    if not c or c:getType() ~= df.item_type.BIN then return false end
    if dry_run then return true end
    local ok = pcall(dfhack.items.moveToGround, it, xyz2pos(c.pos.x, c.pos.y, c.pos.z))
    return ok and true or false
end

-- STRANGE MOODS ARE SACRED. A moody dwarf's whole artifact sequence hangs off their
-- current_job and the items they have reserved; interrupting it fails the mood and the
-- dwarf goes insane. Measured live: this service replaced a Possessed dwarf's mood job with
-- its own PickupEquipment job. Anyone in a real mood is skipped entirely -- not nudged, not
-- re-pinned, and none of their reserved items touched. Baby and Traumatized are `mood_type`
-- values too but are not artifact moods, so they must NOT disable gear handling.
local REAL_MOODS = {}
for _, n in ipairs{'Fey', 'Secretive', 'Possessed', 'Macabre', 'Fell', 'Melancholy',
                   'Raving', 'Berserk'} do
    if df.mood_type[n] then REAL_MOODS[df.mood_type[n]] = true end
end
local function in_strange_mood(u)
    return u ~= nil and REAL_MOODS[u.mood] == true
end

-- jobs a soldier must never be yanked off to go fetch a sock
local NUDGE_PROTECTED = {}
for _, n in ipairs{'Eat', 'Drink', 'Sleep', 'Rest', 'AttackEnemy', 'Flee', 'Fight', 'Kill',
                   'Hunt', 'MeleeAttack', 'RecoverWounded', 'PickupEquipment', 'CarryBody',
                   'GiveWater', 'GiveFood', 'Diagnose', 'Surgery', 'Suture', 'DressWound',
                   -- every mood job, plus the hunt for its materials
                   'SeekArtifact', 'StrangeMoodCrafter', 'StrangeMoodJeweller',
                   'StrangeMoodForge', 'StrangeMoodMagmaForge', 'StrangeMoodBrooding',
                   'StrangeMoodFell', 'StrangeMoodCarpenter', 'StrangeMoodMason',
                   'StrangeMoodBowyer', 'StrangeMoodTanner', 'StrangeMoodWeaver',
                   'StrangeMoodGlassmaker', 'StrangeMoodMechanics'} do
    if df.job_type[n] then NUDGE_PROTECTED[df.job_type[n]] = true end
end

-- Give a soldier a PickupEquipment job. DF very often does not generate one on its own even
-- with the slot assigned and dirtied (measured: 0 such jobs fort-wide while 50+ slots were
-- assigned and their owners idle), so we create it.
--
-- NEVER CANCEL AN EXISTING JOB. This used to interrupt a busy soldier via
-- dfhack.job.removeJob, and that CRASHED THE GAME (SIGSEGV in DF's main loop): removeJob
-- frees the job but does NOT clear unit.job.current_job, so the unit is left holding a
-- dangling pointer and DF dereferences it on the next frame. It even looks like it worked
-- from Lua -- reading current_job afterwards returns the freed struct's stale contents.
--
-- So a nudge only ever happens when the dwarf is genuinely IDLE. A busy one gets nudged on
-- a later cycle instead; nothing is lost by waiting, and there is no safe way to take a job
-- away from a unit from here. (NUDGE_PROTECTED is kept as a second gate for the same
-- reason -- most importantly it covers every StrangeMood job.)
local function nudge_pickup(unit)
    if in_strange_mood(unit) then return false end     -- never interrupt an artifact mood
    local cur = unit.job.current_job
    if cur then return false end                       -- busy: leave them entirely alone
    if dry_run then return true end
    local job = df.job:new()
    job.job_type = df.job_type.PickupEquipment
    job.pos = xyz2pos(unit.pos.x, unit.pos.y, unit.pos.z)
    unit.job.current_job = job
    return true
end

-- locate one of our tracked manager orders by id
local function order_by_id(id)
    local mo = df.global.world.manager_orders
    for i = 0, #mo.all - 1 do if mo.all[i].id == id then return mo.all[i], i end end
end

-- ---- enable state: toggles, persisted ---------------------------------------

state = state or nil
-- gear picture from the most recent cycle, consumed by civilian_arrange() -- the
-- `civilian-militia` command's engine
civ_snapshot = civ_snapshot or nil

-- DRY RUN (`military-uniforms dry`): every mutating primitive below becomes a no-op that
-- records what it WOULD have done, so a cycle can be previewed against a live fort without
-- touching a single uniform, order or item. Reset by the command that sets it.
local dry_run = false
local dry_log = nil
local function note(fmt, ...)
    if dry_log then dry_log[#dry_log + 1] = fmt:format(...) end
end

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.queue == nil then state.queue = true end       -- gear queueing defaults ON
        if state.masterwork == nil then state.masterwork = false end
        if state.wardogs == nil then state.wardogs = false end
        if state.pickaxes == nil then state.pickaxes = false end -- miner steel picks default OFF
        if not state.orders then state.orders = {} end
        state.best_q = nil          -- retired: the pinning model has no swap-up heuristic
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

function isEnabled() return load_state().queue end

-- any background service on? (gear queueing, war-dog training, or miner pickaxes)
local function service_on() load_state(); return state.queue or state.wardogs or state.pickaxes end

-- delete the order we track for `key`, if it still exists
local function drop_order(key)
    local id = state.orders[key]
    if not id then return end
    if dry_run then note('  - would drop order for %s', key); return end
    local o, idx = order_by_id(id)
    if o then df.global.world.manager_orders.all:erase(idx); o:delete() end
    state.orders[key] = nil
end

-- DF makes the items of any order whose amount_left>0 the moment it's submitted, WITHOUT
-- checking conditions (conditions only decide whether to re-fire an already-completed
-- order), and it never re-arms an order sitting at amount_left=0. So leaning on DF's
-- repeat always force-produces at least one unit you may not need. Instead we self-manage:
-- run_cycle decides what is still owed and calls this to create or re-size exactly that
-- many units; drop_order removes a key once it's covered.
local function queue_one(key, r, n)
    n = n or 1
    if dry_run then
        local mat = 'material class ' .. tostring(r.mat_index)
        if r.mat_type == 0 then
            local raw = df.inorganic_raw.find(r.mat_index)
            mat = raw and raw.id:lower() or ('mat ' .. r.mat_index)
        elseif MATCLASS[r.mat_index] then mat = MATCLASS[r.mat_index].order end
        note('  + would order %dx %s %s%s', n, mat,
             tostring(df.item_type[r.item_type]):lower(),
             key:sub(1, 4) == 'sub/' and '   (STAND-IN for an unaffordable metal)' or '')
        return
    end
    local o = state.orders[key] and order_by_id(state.orders[key])
    if not o then
        local mo = df.global.world.manager_orders
        o = df.manager_order:new()
        o.job_type, o.item_type, o.item_subtype = MAKE_JOB[r.item_type], -1, r.subtype
        if is_matclass(r.mat_type, r.mat_index) then
            o.mat_type, o.mat_index = -1, -1
            o.material_category[MATCLASS[r.mat_index].order] = true   -- wood / leather / bone
        else
            o.mat_type, o.mat_index = r.mat_type, r.mat_index
        end
        -- SIZE the gear to the wearer's race: for a non-dwarf (e.g. human) soldier, set the
        -- order's specdata.race so the forge makes their size; dwarves use the default (-1)
        if r.size_race and r.size_race ~= civ_race() then o.specdata.race = r.size_race end
        o.id = mo.manager_order_next_id
        mo.manager_order_next_id = o.id + 1
        o.frequency = df.workquota_frequency_type.OneTime  -- one batch, no DF auto-repeat
        o.amount_total, o.amount_left = n, n
        o.status.validated, o.status.active = true, true
        mo.all:insert(0, o)
        state.orders[key] = o.id
    else
        -- re-size the outstanding batch to what we want NOW (the caller recomputes the
        -- shortfall each cycle), so an over-large batch shrinks as pieces are forged and
        -- never keeps hogging a metal's bar budget away from other gear.
        o.amount_total, o.amount_left = n, n
        o.status.active = true
    end
end

-- mark an item for melting, clearing forbid so it can actually be hauled + melted. NEVER melt a
-- masterwork or artifact -- their quality/value is irreplaceable.
local function mark_melt(it)
    if it.flags.artifact or it:getQuality() >= df.item_quality.Masterful then return false end
    if it.flags.in_job then return false end   -- could be a moody dwarf's reserved material
    if dry_run then note('  ~ would melt %s', dfhack.items.getDescription(it, 0, true)); return true end
    it.flags.forbid = false
    return dfhack.items.markForMelting(it)
end

-- ---- reading the squad: what each soldier is SUPPOSED to have -----------------

-- squad ids DFHack's autotraining tool is currently driving (active only), read from its
-- persisted site data (keys are stored as strings, so coerce back to numbers). Non-leader
-- members of these are only rostered to train, not real soldiers, so we deprioritise their
-- gear like a civilian's.
local function autotraining_squads()
    local set = {}
    local d = dfhack.persistent.getSiteData('autotraining')
    if d and d.training_squads then
        for k, active in pairs(d.training_squads) do
            if active then set[tonumber(k)] = true end
        end
    end
    return set
end

-- the LIVE dwarf occupying a squad position, or nil (vacant, or the occupant is dead /
-- off-map). A position keeps its uniform -- and anything we pinned into it -- after its
-- occupant is gone, so "occupant >= 0" alone is not enough to call a position manned.
local function position_occupant(pos)
    if pos.occupant < 0 then return nil end
    local hf = df.historical_figure.find(pos.occupant)
    local u = hf and df.unit.find(hf.unit_id)
    if u and not u.flags1.inactive then return u end
    return nil
end

-- a squad position wearing a "Civilian - *" uniform: no metal breastplate / mail shirt in the
-- body slot (leather body armour instead). Same marker military-labor uses -- DF exposes no
-- squad->uniform-template link, so we can't read the name.
local function position_is_civilian(pos)
    local has_armor, has_metal = false, false
    local body = pos.equipment.uniform[0]
    for j = 0, #body - 1 do
        local sp = body[j]
        local it_type, mattype = sp.item_type, sp.mattype
        -- a HAND-PICKED specific item carries no filter fields, so read the ITEM itself --
        -- otherwise a soldier whose breastplate was chosen by hand shows only the leather
        -- cloak in this slot and reads as a civilian (see the same fix in dwarf-rts)
        if it_type < 0 and sp.item >= 0 then
            local it = df.item.find(sp.item)
            if it then it_type, mattype = it:getType(), it:getMaterial() end
        end
        if it_type == df.item_type.ARMOR then
            has_armor = true
            if mattype == 0 then has_metal = true end
        end
    end
    return has_armor and not has_metal
end

-- Classify one spec. Returns nil when it isn't ours to manage, else a want descriptor.
--   * a HAND-PICKED specific item (item set, every filter field -1) is the player's
--     (or noble-warriors') -- never touched
--   * a spec whose material is outside managed_materials() (an adamantine sword on a
--     steel uniform) is the player customising THAT property -- skipped, while the rest
--     of the uniform stays managed
local function spec_want(spec, race, unit)
    if spec.item >= 0 and spec.item_type < 0 then return nil end    -- hand-picked specific item
    local it = spec.item_type
    if not MAKE_JOB[it] or spec.item_subtype < 0 then return nil end
    local mt, mi = uniform_matpair(spec)
    if not mt or not managed_materials()[mt .. '/' .. mi] then return nil end
    -- EVERY spec now owns exactly ONE item, pair slots included: ensure_pair_specs has
    -- already split a gauntlet/boot slot into one spec per wearable item (and sized that
    -- split to the soldier's actual anatomy, so a one-handed veteran gets one glove spec).
    local qty = 1
    return {item_type = it, subtype = spec.item_subtype, mat_type = mt, mat_index = mi,
            size_race = key_race(it, race),          -- the size we ORDER in (make target)
            wsize = adult_size(race), qty = qty,     -- the size that actually FITS them
            handed = HANDED[it] or false}
end

-- the gear key an order/shortfall is tracked under
local function want_key(w)
    return ('%d/%d/%d/%d/%d'):format(w.item_type, w.subtype, w.mat_type, w.mat_index, w.size_race)
end

-- Walk every occupied fort squad position and build the per-soldier picture:
--   {unit_id, unit, pos, sid, civilian, real_civ, leader, custom, specs = {{spec, want}, ...}}
--
-- ORDER = THE GAME'S OWN SQUAD ORDER (historical_entity.squads, i.e. exactly the order the
-- Squads screen shows), then position within the squad. Gear is pinned first-come, so this
-- order decides who gets the good stuff when stock is scarce -- which makes it the player's
-- call, not ours. Reorder your squads on the Squads screen to change priority.
--
-- This deliberately does NOT re-rank soldiers by anything clever. An earlier version put
-- "Military" work-detail members first and civilian-uniform members last; the effect was
-- that a squad with 9/10 members in that detail silently outranked one with 10/10 and got
-- first pick of every piece, which is not a decision this script should be making.
-- (The civilian / real_civ / leader flags are still computed -- civilian-militia consumes
-- them -- they just no longer influence ordering.)
local function read_soldiers()
    local fort = df.global.plotinfo.group_id
    local training = autotraining_squads()
    local out = {}
    local ent
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == fort then ent = e; break end
    end
    -- the entity's ordered squad list is the Squads-screen order; fall back to the world
    -- list only if it is somehow unavailable
    local sids = {}
    if ent and #ent.squads > 0 then
        for i = 0, #ent.squads - 1 do sids[#sids + 1] = ent.squads[i] end
    else
        for s = 0, #df.global.world.squads.all - 1 do
            local sq = df.global.world.squads.all[s]
            if sq.entity_id == fort then sids[#sids + 1] = sq.id end
        end
    end
    for _, sid in ipairs(sids) do
        local sq = df.squad.find(sid)
        if sq and sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                local u = position_occupant(pos)
                if u then
                    local specs, custom = {}, false
                    for slot = 0, 6 do
                        local v = pos.equipment.uniform[slot]
                        for j = 0, #v - 1 do
                            local spec = v[j]
                            if spec.item >= 0 and spec.item_type < 0 then custom = true end
                            local w = spec_want(spec, u.race, u)
                            if w then specs[#specs + 1] = {spec = spec, want = w, slot = slot} end
                        end
                    end
                    -- link specs that share a slot AND item type: pair slots need them to
                    -- coordinate handedness (see assign_gear)
                    for _, a in ipairs(specs) do
                        local sibs = {}
                        for _, b in ipairs(specs) do
                            if b.slot == a.slot and b.want.item_type == a.want.item_type then
                                sibs[#sibs + 1] = b
                            end
                        end
                        a.siblings = sibs
                    end
                    if #specs > 0 or custom then
                        -- civilian for gear purposes = a Civilian-* uniform OR a non-leader
                        -- member of an autotraining squad (only rostered to train; the
                        -- leader stays a soldier)
                        local real_civ = position_is_civilian(pos)
                        local civilian = real_civ or (training[sq.id] and p ~= 0)
                        out[#out + 1] = {unit_id = u.id, unit = u, pos = pos, sid = sq.id,
                                         civilian = civilian, real_civ = real_civ,
                                         leader = (p == 0), custom = custom, specs = specs}
                    end
                end
            end
        end
    end
    return out
end

-- ---- the candidate pool: which items may be pinned to whom --------------------

-- Drop a spec's assignments AND the ownership we stamped on them, otherwise a released
-- piece stays flagged as the ex-soldier's property and build_pool would skip it forever.
-- ONLY ownership belonging to this position's own occupant is cleared: a piece owned by
-- somebody else is a civilian's clothing that we merely failed to obtain, and un-owning it
-- would quietly confiscate their belongings.
local function release_assignment(pos, spec)
    if dry_run then return end
    local hf = pos.occupant >= 0 and df.historical_figure.find(pos.occupant)
    local uid = hf and hf.unit_id or nil
    for k = #spec.assigned - 1, 0, -1 do
        local id = spec.assigned[k]
        utils.erase_sorted(pos.equipment.assigned_items, id)
        spec.assigned:erase(k)
        local it = df.item.find(id)
        if it and it.flags.owned and uid then
            local ow = dfhack.items.getOwner(it)
            if ow and ow.id == uid then pcall(dfhack.items.setOwner, it, nil) end
        end
    end
end

-- A position keeps its uniform after its occupant leaves or dies -- that is exactly how DF
-- gives a fresh recruit the right uniform -- but it also keeps whatever WE pinned into it,
-- so the next dwarf to fill the slot would inherit a dead soldier's item ids and lock that
-- gear away from everyone else. Clear OUR pins (and their assignments) off unmanned
-- positions every cycle. Hand-picked specific items (filters all -1) are the player's
-- standing choice for that position and are left in place.
local function clear_unmanned_positions()
    local fort = df.global.plotinfo.group_id
    local cleared = 0
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                if not position_occupant(pos) then
                    for slot = 0, 6 do
                        local v = pos.equipment.uniform[slot]
                        for j = 0, #v - 1 do
                            local spec = v[j]
                            local ours = spec.item >= 0 and spec.item_type >= 0
                            if ours or (spec.item < 0 and #spec.assigned > 0) then
                                if ours and not dry_run then spec.item = -1 end
                                release_assignment(pos, spec)
                                cleared = cleared + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return cleared
end

-- PAIR SLOTS GET ONE SPEC PER ITEM.
--
-- A gauntlet/boot slot needs two items, but `spec.item` names only one -- so the original
-- model left pair slots with no pin at all and drove them purely through `spec.assigned`.
-- DF's own "Refresh Equipment" button (and a save reload) re-solves every slot: it honours
-- an explicit `spec.item` and DISCARDS hand-written `assigned` entries. The result was that
-- boots and gauntlets -- and ONLY those -- were stripped off every soldier on a refresh,
-- while all 114 singleton pins came through untouched.
--
-- Verified live that DF accepts TWO specs in one slot each pinning one item, and then wants
-- exactly two items, not two pairs. So normalise every pair slot to one managed spec per
-- item the wearer can actually use; from there pair slots pin exactly like every other slot.
-- Hand-picked specs in the slot count toward the total and are never touched.
local function ensure_pair_specs()
    local fort = df.global.plotinfo.group_id
    local added, removed = 0, 0
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                local u = position_occupant(pos)
                if u then
                    for _, it_type in ipairs({df.item_type.GLOVES, df.item_type.SHOES}) do
                        local slot = (it_type == df.item_type.GLOVES) and 3 or 4
                        local v = pos.equipment.uniform[slot]
                        local mine, fixed = {}, 0
                        for j = 0, #v - 1 do
                            local sp = v[j]
                            if sp.item >= 0 and sp.item_type < 0 then fixed = fixed + 1
                            elseif sp.item_type == it_type and sp.item_subtype >= 0 then
                                mine[#mine + 1] = {spec = sp, idx = j}
                            end
                        end
                        if #mine > 0 then
                            -- how many this body can actually wear (an amputee wears one)
                            local anat = (it_type == df.item_type.GLOVES)
                                and math.min(2, u.status2.limbs_grasp_count)
                                or math.min(2, u.status2.limbs_stand_count)
                            local want_n = math.max(0, anat - fixed)
                            while #mine < want_n do
                                local proto = mine[1].spec
                                if dry_run then added = added + (want_n - #mine); break end
                                v:insert('#', {new = df.squad_uniform_spec,
                                    item = -1, item_type = proto.item_type,
                                    item_subtype = proto.item_subtype,
                                    material_class = proto.material_class,
                                    mattype = proto.mattype, matindex = proto.matindex,
                                    color = -1})
                                mine[#mine + 1] = {spec = v[#v - 1], idx = #v - 1}
                                added = added + 1
                            end
                            while #mine > want_n do
                                if dry_run then removed = removed + (#mine - want_n); break end
                                local last = table.remove(mine)
                                release_assignment(pos, last.spec)
                                for j = #v - 1, 0, -1 do
                                    if v[j] == last.spec then v:erase(j); break end
                                end
                                removed = removed + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return added, removed
end

-- Every item currently spoken for by a MANNED fort squad position -- a pinned `spec.item`,
-- or anything in that position's assigned_items. An item claimed by someone else can never
-- be offered to a second soldier, which is what makes pinning conflict-free without any
-- stock arithmetic. Unmanned positions are skipped (clear_unmanned_positions has already
-- emptied ours, and a hand-picked item on a vacant position stays reserved for it).
local function claimed_items()
    local fort = df.global.plotinfo.group_id
    local claimed = {}
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                local manned = position_occupant(pos) ~= nil
                if manned then
                    for _, iid in ipairs(pos.equipment.assigned_items) do claimed[iid] = pos end
                end
                for slot = 0, 6 do
                    local v = pos.equipment.uniform[slot]
                    for j = 0, #v - 1 do
                        local spec = v[j]
                        if spec.item >= 0 and (manned or spec.item_type < 0) then
                            claimed[spec.item] = pos
                        end
                    end
                end
            end
        end
    end
    return claimed
end

-- Base legality of an item as gear for ANYBODY: it exists as real, reachable, undamaged
-- fort stock that a soldier could actually be made to carry.
--   * forbidden / dumped / garbage-collected / burning / encased -> unreachable
--   * marked for melting -> on its way to a smelter
--   * in_building -> locked in a weapon TRAP or a display case / PEDESTAL: never equippable
--   * construction / trader -> not ours to hand out
--   * artifact -> DF will not auto-equip one; the player pins those by hand (noble-warriors)
--   * worn past MAX_WEAR -> falling apart, not worth assigning to anyone
local function item_pinnable(it)
    local f = it.flags
    if f.forbid or f.dump or f.garbage_collect or f.melt or f.on_fire or f.encased then return false end
    if f.in_building or f.construction or f.trader or f.artifact then return false end
    if item_wear(it) > MAX_WEAR then return false end
    if not_fort_stock(it) then return false end
    return true
end

-- Build the pool of assignable items, bucketed by "item_type/subtype". One pass over the
-- seven gear vectors in world.items.other (NOT items.all). Items already claimed by a
-- squad position are left out -- they belong to that soldier until we release them.
local function build_pool(claimed, jobitems)
    local pool = {}
    for item_type, vec_id in pairs(OTHER_VEC) do
        local handed = HANDED[item_type]
        for _, it in ipairs(df.global.world.items.other[vec_id]) do
            -- an item someone is already carrying but which no position claims is loose
            -- gear from a dead/discharged soldier: DF will not hand it to a new owner while
            -- it is held, so skip it this cycle. (Checked first -- it also subsumes the
            -- offsite/foreign-holder test, which is the expensive part of item_pinnable.)
            -- Personal property is off limits, and an item a LIVE job is fetching is already
            -- spoken for -- but a STALE in_job claim (no such job) is cleared, not respected.
            if not claimed[it.id] and not holder_of(it) and item_pinnable(it)
                and not owned_by_other(it, nil) and clear_stale_in_job(it, jobitems) then
                local k = it:getType() .. '/' .. it:getSubtype()
                local b = pool[k]
                if not b then b = {}; pool[k] = b end
                local mt, mi = item_matpair(it)
                b[#b + 1] = {it = it, id = it.id, mt = mt, mi = mi,
                             q = it:getQuality(), wear = item_wear(it),
                             size = item_size_race(it),
                             hand = handed and item_hand(it) or nil,
                             rank = metal_rank(mt, mi, it:getType())}
            end
        end
    end
    return pool
end

-- Does a candidate fit this want at all? (type/subtype already matched by the bucket.)
local function cand_fits(c, w, hand)
    if c.size ~= w.size_race then return false end                  -- wrong size for this wearer
    if hand ~= nil and c.hand ~= nil and c.hand ~= hand then return false end
    return true
end

local function cand_exact(c, w) return c.mt == w.mat_type and c.mi == w.mat_index end

-- Anything suitable THE SOLDIER IS ALREADY WEARING, not claimed by any spec.
--
-- This is essential, not an optimisation. build_pool deliberately skips items with a holder
-- (gear on someone's back is not free stock), so a piece that becomes unassigned while its
-- wearer still has it on is invisible to the pool FOREVER -- it can never be re-pinned. Any
-- change to the matching rules therefore stripped soldiers permanently instead of simply
-- re-pinning what they already had on: two successive rule tweaks released 64 and then 70
-- assignments and drove "fully equipped" from 15/20 down to 1/20, purely through this hole.
-- Always re-adopt from the wearer before reaching for the shared pool.
local function take_from_inventory(sol, w, hand, claimed)
    for _, ie in ipairs(sol.unit.inventory) do
        local it = ie.item
        if it:getType() == w.item_type and it:getSubtype() == w.subtype
            and not claimed[it.id] and item_pinnable(it)
            and item_size_race(it) == w.size_race
            and (hand == nil or not HANDED[w.item_type] or item_hand(it) == hand)
        then
            local mt, mi = item_matpair(it)
            return {it = it, id = it.id, mt = mt, mi = mi, q = it:getQuality(),
                    wear = item_wear(it), size = item_size_race(it),
                    hand = HANDED[w.item_type] and item_hand(it) or nil,
                    rank = metal_rank(mt, mi, it:getType())}
        end
    end
end

-- Pick the best free candidate for a want. EXACT material always beats a stand-in; then
-- higher quality, then less wear, then the more valuable material (so a stand-in is the
-- best metal on hand rather than the first one found). `hand` restricts to one hand for
-- gauntlets. `require` narrows what counts as acceptable at all:
--   nil           anything that fits -- used to fill an EMPTY slot, where a stand-in
--                 beats sending a soldier out bare
--   'exact'       only the material the uniform demands -- used to replace a stand-in
--   'masterwork'  only an exact-material masterwork -- used to upgrade a piece that is
--                 already the right material while the masterwork toggle is on
-- Returns the candidate and removes it from the pool.
local function take_best(pool, w, hand, require)
    local bucket = pool[w.item_type .. '/' .. w.subtype]
    if not bucket then return nil end
    local best, best_i
    for i = 1, #bucket do
        local c = bucket[i]
        if cand_fits(c, w, hand) then
            local ok = true
            if require == 'exact' then
                ok = cand_exact(c, w)
            elseif require == 'masterwork' then
                ok = cand_exact(c, w) and c.q >= df.item_quality.Masterful
            end
            if ok and (not best
                or (cand_exact(c, w) and not cand_exact(best, w))
                or (cand_exact(c, w) == cand_exact(best, w)
                    and (c.q > best.q
                        or (c.q == best.q and (c.wear < best.wear
                            or (c.wear == best.wear and c.rank < best.rank))))))
            then best, best_i = c, i end
        end
    end
    if best then table.remove(bucket, best_i) end
    return best
end

-- ---- writing the pin ---------------------------------------------------------

local function add_assignment(pos, spec, id)
    if dry_run then return end
    spec.assigned:insert('#', id)
    utils.insert_sorted(pos.equipment.assigned_items, id)
end

local function dirty(item_type)
    if dry_run then return end
    local f = UPDATE_FIELD[item_type]
    if f then df.global.plotinfo.equipment.update[f] = true end
end

-- SINGLETON slot. BOTH fields must be written, and this was measured the hard way:
--
--   * `spec.item` is DF's native "specific item" pin -- it records the choice, shows on the
--     Equip screen, and stops DF's solver re-solving the slot out from under us.
--   * `spec.assigned` is what actually makes the dwarf GO AND FETCH the thing.
--
-- Setting `spec.item` ALONE does nothing: DF never back-fills `assigned` from it. Measured
-- live -- of 110 slots pinned that way, the only 58 that equipped were the ones whose
-- `assigned` was already populated (items the dwarf happened to be wearing), while the 52
-- newly pinned sat at `assigned=EMPTY, in_job=false` forever and no pickup job was ever
-- generated. Gauntlets and boots equipped fine over the same period precisely because the
-- pair path writes `assigned` directly.
--
-- Writing both is a state DF is demonstrably happy with (those 58 adopted slots carry item
-- + assigned together and wear correctly). The filter fields are still never touched --
-- they remain the record of what this slot is SUPPOSED to be.
-- Make an item genuinely reachable by the soldier we are giving it to: out of any bin,
-- un-forbidden, and stamped as their property (DF's own "assign specific item" does the
-- same, and unowned gear is what other haulers keep wandering off with).
local function claim_item(unit, id)
    local it = df.item.find(id)
    if not it or dry_run then return end
    free_from_bin(it)
    if it.flags.forbid then it.flags.forbid = false end
    -- never confiscate: pool candidates are already filtered to unowned items, so this only
    -- guards the re-pin paths
    if unit and not owned_by_other(it, unit.id) then
        pcall(dfhack.items.setOwner, it, unit)
    end
end

local function pin_single(pos, spec, id, unit)
    release_assignment(pos, spec)
    if not dry_run then
        spec.item = id
        add_assignment(pos, spec, id)
    end
    claim_item(unit, id)
    dirty(spec.item_type)
end

-- What is this spec currently holding? The singleton pin, or the pair slot's assignments --
-- and, for a singleton that is not pinned yet, whatever DF's own solver already assigned.
-- ADOPTING DF's pick matters: without it the very first cycle would unpin every soldier in
-- the fort and make them all drop and re-fetch gear they were already correctly wearing.
local function current_pins(spec)
    local out = {}
    if spec.item >= 0 then
        out[1] = spec.item
    elseif #spec.assigned > 0 then
        out[1] = spec.assigned[0]                    -- adopt DF's existing solution
    end
    return out
end

-- Is an already-pinned item still a legal pin for this soldier? Re-checked every cycle,
-- because pinning means DF will NOT quietly find a replacement the way it does for a plain
-- filter spec -- if the piece was melted, forbidden, put on a pedestal, worn out or taken
-- by somebody else, we own noticing.
local function pin_still_valid(id, w, unit_id, claimed)
    local it = df.item.find(id)
    if not it then return false end
    if it:getType() ~= w.item_type or it:getSubtype() ~= w.subtype then return false end
    if not item_pinnable(it) then return false end
    if item_size_race(it) ~= w.size_race then return false end
    -- somebody else's property: DF will never fetch it for this soldier, so the slot would
    -- show "pending" forever. Release it and let the pin pass find (or order) another.
    if owned_by_other(it, unit_id) then return false end
    local h = holder_of(it)
    if h and h.id ~= unit_id then return false end        -- somebody else is carrying it
    local owner = claimed[id]
    if owner and owner.occupant >= 0 then
        local hf = df.historical_figure.find(owner.occupant)
        if hf and hf.unit_id ~= unit_id then return false end   -- claimed by another position
    end
    return true
end

-- Make every ALREADY-ASSIGNED piece physically obtainable, whoever chose it.
--
-- This deliberately covers the player's HAND-PICKED specific items too. Freeing a piece
-- from a bin, or clearing a phantom job claim, does not change WHAT was chosen -- it only
-- lets the choice actually happen. Without it a hand-picked item that got hauled into a bin
-- is red forever, because the pin pass refuses to touch those specs at all: one soldier here
-- had four hand-picked steel pieces (mail shirt, helm, greaves, sword) all sitting in bins.
--
-- It also re-runs for OUR pins every cycle, not just at pin time: a piece can be assigned
-- while loose and then hauled into a bin afterwards.
local function unstick_assigned(soldiers, jobitems)
    local freed, unjobbed, unforbid, owned = 0, 0, 0, 0
    for _, sol in ipairs(soldiers) do
        -- likewise: never move, un-forbid or re-own anything belonging to a moody dwarf
        if in_strange_mood(sol.unit) then goto next_unstick end
        for slot = 0, 6 do
            local v = sol.pos.equipment.uniform[slot]
            for j = 0, #v - 1 do
                local sp = v[j]
                local ids = {}
                if sp.item >= 0 then ids[#ids + 1] = sp.item end
                for _, id in ipairs(sp.assigned) do ids[#ids + 1] = id end
                for _, id in ipairs(ids) do
                    local it = df.item.find(id)
                    local h = it and holder_of(it)
                    -- someone else carrying it is a case we must not meddle with
                    if it and (not h or h.id == sol.unit_id) then
                        -- CLAIM OWNERSHIP EVERY CYCLE, not just when the pin is created.
                        -- A leather cloak is CLOTHING (armorlevel 0), so while it sits
                        -- unowned DF's clothing system will hand it to whichever citizen
                        -- needs clothes -- and then the pin reads as "owned by someone
                        -- else" next cycle and gets released. Pin, lose, release, re-pin,
                        -- forever: that was a permanent churn loop of ~6 cloaks a day.
                        if owner_id_of(it) == nil then
                            if not dry_run then pcall(dfhack.items.setOwner, it, sol.unit) end
                            owned = owned + 1
                        end
                        if not h then
                            if free_from_bin(it) then freed = freed + 1 end
                            if it.flags.in_job and not jobitems[id] then
                                if not dry_run then it.flags.in_job = false end
                                unjobbed = unjobbed + 1
                            end
                            -- only un-forbid what nobody owns: a forbidden piece that is
                            -- somebody's property is not ours to hand out
                            if it.flags.forbid and owner_id_of(it) == nil then
                                if not dry_run then it.flags.forbid = false end
                                unforbid = unforbid + 1
                            end
                        end
                    end
                end
            end
        end
        ::next_unstick::
    end
    return freed, unjobbed, unforbid, owned
end

-- =============================================================================
-- THE PIN PASS
--
-- For every soldier, for every spec we manage: keep the pins that are still valid, drop
-- the ones that aren't, and fill the gaps from the pool. Returns the shortfall -- what
-- nobody could be given, which is exactly what needs forging.
-- =============================================================================
local function assign_gear(soldiers, claimed, pool, jobitems)
    local shortfall = {}                    -- key -> {want fields..., count}
    local pinned, repinned, released, adopted, repaired, nudged, pruned = 0, 0, 0, 0, 0, 0, 0

    -- `count` = pieces of the demanded material still owed (empty slots AND slots filled
    -- only by a stand-in). `empty` = the subset with NOTHING on them at all. The two drive
    -- different orders: `count` forges the real material, `empty` is the only thing that
    -- justifies forging a cheap stand-in -- a soldier already wearing a bronze breastplate
    -- does not need an iron one made, they need the steel one they are waiting for.
    local function owe(w, n, empty)
        if n <= 0 and (empty or 0) <= 0 then return end
        local k = want_key(w)
        local r = shortfall[k]
        if not r then
            r = {item_type = w.item_type, subtype = w.subtype, mat_type = w.mat_type,
                 mat_index = w.mat_index, size_race = w.size_race, count = 0, empty = 0}
            shortfall[k] = r
        end
        r.count = r.count + math.max(0, n)
        r.empty = r.empty + math.max(0, empty or 0)
    end

    for _, sol in ipairs(soldiers) do
        -- a dwarf in an artifact mood is left completely alone: no re-pinning, no releasing,
        -- no ownership changes, no pickup job. Their gear can wait; the mood cannot.
        if in_strange_mood(sol.unit) then
            for _, entry in ipairs(sol.specs) do
                entry.satisfied = true          -- and do not order replacements for them
                entry.filled = entry.want.qty
            end
            goto next_soldier
        end
        for _, entry in ipairs(sol.specs) do
            local spec, w = entry.spec, entry.want
            local keep, stale = {}, false
            for _, id in ipairs(current_pins(spec)) do
                if pin_still_valid(id, w, sol.unit_id, claimed) then
                    keep[#keep + 1] = id
                else
                    stale = true
                    released = released + 1
                end
            end
            -- surplus (anatomy shrank -- a soldier lost a hand): drop the extras
            while #keep > w.qty do table.remove(keep); stale = true end

            -- A handed spec holding the SAME hand an earlier sibling already has leaves the
            -- other hand bare. Filling coordinates hands, but an assignment INHERITED from
            -- before the pair split (or from DF's own solver) can duplicate one -- drop it
            -- so step 1 re-fills with the hand that is actually missing.
            if w.handed and #keep > 0 then
                local taken = {}
                for _, sib in ipairs(entry.siblings or {}) do
                    if sib == entry then break end
                    for _, id in ipairs(current_pins(sib.spec)) do
                        local sit = df.item.find(id)
                        if sit then taken[item_hand(sit)] = true end
                    end
                end
                local held = df.item.find(keep[1])
                if held and taken[item_hand(held)] then
                    keep = {}
                    stale = true
                    released = released + 1
                end
            end

            -- a stand-in of the wrong material, or (in masterwork mode) a piece below
            -- masterwork, is a slot we still owe -- and one we upgrade the moment a
            -- proper piece exists
            local upgradeable = {}
            for i, id in ipairs(keep) do
                local it = df.item.find(id)
                local mt, mi = item_matpair(it)
                local exact = (mt == w.mat_type and mi == w.mat_index)
                if not exact or (state.masterwork and it:getQuality() < df.item_quality.Masterful) then
                    upgradeable[#upgradeable + 1] = i
                end
            end

            -- HANDEDNESS ACROSS SIBLINGS. Each gauntlet spec holds one glove, so "one of
            -- each hand" is now a property of the SLOT, not of a single spec: ask for
            -- whichever hand the other specs in this slot are not already covering.
            -- Without this the two specs would independently pick "best available" and
            -- happily leave a soldier with two left gauntlets.
            local want_hand
            if w.handed then
                local covered = {}
                for _, sib in ipairs(entry.siblings or {}) do
                    if sib ~= entry then
                        for _, id in ipairs(current_pins(sib.spec)) do
                            local sit = df.item.find(id)
                            if sit then covered[item_hand(sit)] = true end
                        end
                    end
                end
                for _, id in ipairs(keep) do
                    local it = df.item.find(id)
                    if it then covered[item_hand(it)] = true end
                end
                if #(entry.siblings or {}) < 2 then want_hand = nil       -- only one glove wanted
                elseif not covered[0] then want_hand = 0
                elseif not covered[1] then want_hand = 1 end
            end

            local changed = stale
            -- 1. fill empty slots from the pool (any material -- a stand-in beats nothing)
            local gap = w.qty - #keep
            local unfilled = 0
            for _ = 1, gap do
                local hand = want_hand
                -- prefer something already on this dwarf, then the shared pool
                local c = take_from_inventory(sol, w, hand, claimed) or take_best(pool, w, hand, false)
                if c then
                    keep[#keep + 1] = c.id
                    claimed[c.id] = sol.pos
                    changed = true
                    pinned = pinned + 1
                else
                    unfilled = unfilled + 1
                end
            end
            -- 2. upgrade stand-ins / sub-masterwork pieces when a proper one is now free.
            -- A WRONG-MATERIAL stand-in upgrades to any exact-material piece; a piece that
            -- is already the right material only ever upgrades to an exact masterwork (and
            -- only while that toggle is on). Getting this split wrong is what would leave a
            -- soldier in a copper breastplate just because no steel MASTERWORK existed yet.
            local still_owed = unfilled
            for _, idx in ipairs(upgradeable) do
                local old = keep[idx]
                local it = df.item.find(old)
                local mt, mi = item_matpair(it)
                local old_exact = (mt == w.mat_type and mi == w.mat_index)
                local old_q = it:getQuality()
                local hand = w.handed and item_hand(it) or nil   -- swap like for like
                local c = take_best(pool, w, hand, old_exact and 'masterwork' or 'exact')
                -- never swap DOWN in quality: a soldier should not drop a fine steel helm
                -- to fetch a plain one of the same metal
                if c and c.q >= old_q then
                    keep[idx] = c.id
                    claimed[c.id] = sol.pos
                    claimed[old] = nil
                    changed = true
                    repinned = repinned + 1
                    -- still owed if we only got as far as the right material but the
                    -- masterwork toggle wants better
                    if state.masterwork and c.q < df.item_quality.Masterful then
                        still_owed = still_owed + 1
                    end
                else
                    if c then                                    -- not an upgrade: put it back
                        local bucket = pool[w.item_type .. '/' .. w.subtype]
                        if bucket then bucket[#bucket + 1] = c end
                    end
                    still_owed = still_owed + 1
                end
            end
            owe(w, still_owed, unfilled)

            -- 3. write it back -- but only where the outcome actually differs from what is
            -- already on the position, so an unchanged slot never makes a soldier drop and
            -- re-fetch a piece they are correctly wearing
            if keep[1] then
                if spec.item ~= keep[1] then
                    if #spec.assigned == 1 and spec.assigned[0] == keep[1] then
                        -- DF's own solver already put exactly this item on the slot: adopt it
                        -- as our pin without releasing anything. No churn, and from now on
                        -- DF treats the slot as an explicit choice.
                        if not dry_run then spec.item = keep[1] end
                        adopted = adopted + 1
                    else
                        pin_single(sol.pos, spec, keep[1], sol.unit)
                    end
                elseif #spec.assigned == 0 then
                    -- pinned but with no assignment, so nothing will ever fetch it. Writing
                    -- the assignment is the repair; dirtying alone was proven insufficient
                    -- (see pin_single). Also self-heals slots pinned by an older version of
                    -- this script that only set spec.item.
                    add_assignment(sol.pos, spec, keep[1])
                    claim_item(sol.unit, keep[1])
                    dirty(w.item_type)
                    repaired = repaired + 1
                elseif #spec.assigned > 1 and not dry_run then
                    -- DF's own re-solve still treats a glove spec as meaning "a PAIR" and
                    -- bolts a second item onto it. On a split pair slot that yields four
                    -- gauntlets and duplicate hands (measured after a Refresh Equipment:
                    -- 90 assignments across 79 specs, 7 soldiers with two of one hand).
                    -- The pin is the truth -- drop anything else DF bolted on.
                    for k = #spec.assigned - 1, 0, -1 do
                        local id = spec.assigned[k]
                        if id ~= spec.item then
                            utils.erase_sorted(sol.pos.equipment.assigned_items, id)
                            spec.assigned:erase(k)
                            local extra = df.item.find(id)
                            if extra and extra.flags.owned then
                                local ow = dfhack.items.getOwner(extra)
                                if ow and ow.id == sol.unit_id then
                                    pcall(dfhack.items.setOwner, extra, nil)
                                end
                            end
                            pruned = pruned + 1
                        end
                    end
                    dirty(w.item_type)
                end
            elseif changed or spec.item >= 0 then
                release_assignment(sol.pos, spec)
                if not dry_run then spec.item = -1 end
                dirty(w.item_type)
            end
            entry.satisfied = (still_owed == 0 and #keep == w.qty)
            entry.filled = #keep                  -- pieces actually on the slot, any material
        end
        -- Anything assigned that the soldier is not yet carrying needs a pickup job, and DF
        -- routinely never makes one (see nudge_pickup). Do it ourselves, once per soldier.
        local needs_pickup = false
        for _, e in ipairs(sol.specs) do
            for _, id in ipairs(e.spec.assigned) do
                local it = df.item.find(id)
                if it and not it.flags.in_inventory then needs_pickup = true; break end
            end
            if needs_pickup then break end
        end
        if needs_pickup and nudge_pickup(sol.unit) then nudged = nudged + 1 end
        if dry_log then
            -- FILLED and CORRECT are different questions, and only the first one decides
            -- whether a dwarf walks out with something on: a slot filled by a stand-in is
            -- equipped but still owes production.
            local want_n, filled_n, correct_n = 0, 0, 0
            for _, e in ipairs(sol.specs) do
                want_n = want_n + e.want.qty
                filled_n = filled_n + e.filled
                if e.satisfied then correct_n = correct_n + e.want.qty end
            end
            note('%-34s %s  equipped %d/%d   right material %d/%d%s',
                dfhack.units.getReadableName(sol.unit):sub(1, 34),
                sol.civilian and '[civ]' or '[mil]', filled_n, want_n, correct_n, want_n,
                sol.custom and '  (+hand-picked)' or '')
        end
        ::next_soldier::
    end
    return shortfall, pinned, repinned, released, adopted, repaired, nudged, pruned
end

-- ---- production: forge exactly what nobody could be given ---------------------

local function barkey(mt, mi) return mt .. '/' .. mi end

-- Queue one order per gear key that is still short, sized to the shortfall and bounded by
-- the metal's bar budget. Metal keys share their metal's budget evenly, so one big
-- shortfall (39 helms) can't hog the bars and starve another (the civilians' axes).
local function queue_shortfall(shortfall)
    -- bars on hand, and what our own NON-gear orders (miner pick / woodcutter axe) already
    -- committed. Gear orders are re-sized every cycle, so they are not pre-subtracted.
    local bars = {}
    for _, it in ipairs(df.global.world.items.other[df.items_other_id.BAR]) do
        if on_hand(it) and not it.flags.melt then
            local k = barkey(it:getMaterial(), it:getMaterialIndex())
            bars[k] = (bars[k] or 0) + 1
        end
    end
    local committed = {}
    for k, id in pairs(state.orders) do
        if not shortfall[k] and k:sub(1, 7) ~= 'supply/' then
            local o = order_by_id(id)
            if o and o.amount_left > 0 then
                local mk = barkey(o.mat_type, o.mat_index)
                committed[mk] = (committed[mk] or 0) + o.amount_left
            end
        end
    end
    local budget = {}
    for mk, b in pairs(bars) do budget[mk] = math.max(0, b - RESERVE_BARS - (committed[mk] or 0)) end

    -- fair share of each metal's budget across the keys short in it
    local wanted_n = {}
    for _, r in pairs(shortfall) do
        if r.mat_type == 0 then
            local mk = barkey(r.mat_type, r.mat_index)
            wanted_n[mk] = (wanted_n[mk] or 0) + 1
        end
    end
    local share = {}
    for mk, cnt in pairs(wanted_n) do share[mk] = math.max(1, math.floor((budget[mk] or 0) / cnt)) end

    local queued = 0
    for key, r in pairs(shortfall) do
        local mk = barkey(r.mat_type, r.mat_index)
        local is_metal = r.mat_type == 0            -- wood / leather / bone cost no bars
        if is_metal and (budget[mk] or 0) < BARS_PER_ITEM then
            drop_order(key)                          -- no bars to spare past the reserve
        else
            local n = is_metal and math.max(1, math.min(r.count, share[mk] or 1)) or r.count
            queue_one(key, r, n)
            queued = queued + 1
        end
    end
    -- drop orders for keys nobody is short of any more (soldier left, uniform changed,
    -- gear finally arrived), plus anything left over from the pre-pinning model
    for key in pairs(state.orders) do
        if key:sub(1, 7) == 'supply/' then                  -- ensure_supply handles it
        elseif key:sub(1, 4) == 'sub/' then                 -- queue_standins handles these
        elseif key == 'pick' or key == 'axe' then           -- equip_workers handles these
        elseif not shortfall[key] then
            drop_order(key)                                 -- covered, or a retired cu/* key
        end
    end
    return queued, budget
end

-- STAND-IN PRODUCTION. Everything above orders the material the uniform actually demands.
-- When that material is unaffordable -- its bar budget is spent, e.g. 2 steel bars against a
-- 3-bar reserve -- the order is withheld, and if stock is empty too the slot then stays bare
-- FOREVER: nothing to pin, nothing being made. That is how five soldiers ended up with no
-- shield at all while the fort had none in stock and no steel to forge one.
--
-- So also order the piece in the best material we CAN afford (for a shield, plain wood costs
-- no bars at all). The pin pass already treats a wrong-material piece as a stand-in and
-- upgrades the soldier the moment the real thing exists, so this costs nothing but a cheap
-- item. Generalises the old wood-shield-only pass to every slot.
local function queue_standins(shortfall, budget)
    local want_sub = {}
    for key, r in pairs(shortfall) do
        local mk = barkey(r.mat_type, r.mat_index)
        if (r.empty or 0) > 0 and r.mat_type == 0 and (budget[mk] or 0) < BARS_PER_ITEM then
            local best_mi, best_rank
            for _, id in ipairs(STANDIN_ORDER) do
                local idx = inorganic_idx(id)
                if idx and idx ~= r.mat_index and (budget[barkey(0, idx)] or 0) >= BARS_PER_ITEM then
                    local rk = metal_rank(0, idx)
                    if not best_rank or rk < best_rank then best_mi, best_rank = idx, rk end
                end
            end
            local sub = 'sub/' .. key
            local wood_shield = r.item_type == df.item_type.SHIELD
                and #df.global.world.items.other[df.items_other_id.WOOD] > 0
            if wood_shield then
                -- PREFERRED over any metal stand-in (see metal_rank): costs no bars, so it
                -- also leaves the whole metal budget for armour that actually needs metal.
                queue_one(sub, {item_type = r.item_type, subtype = r.subtype, mat_type = -1,
                                mat_index = df.entity_material_category.Wood,
                                size_race = r.size_race}, r.empty)
                want_sub[sub] = true
            elseif best_mi then
                local n = math.max(1, math.min(r.empty, budget[barkey(0, best_mi)]))
                queue_one(sub, {item_type = r.item_type, subtype = r.subtype, mat_type = 0,
                                mat_index = best_mi, size_race = r.size_race}, n)
                budget[barkey(0, best_mi)] = budget[barkey(0, best_mi)] - n
                want_sub[sub] = true
            end
        end
    end
    -- retire stand-ins whose real key is covered, or whose real material is affordable again
    for key in pairs(state.orders) do
        if key:sub(1, 4) == 'sub/' and not want_sub[key] then drop_order(key) end
    end
end

-- Masterwork re-forging needs metal: melt surplus inferior copies of the gear types we
-- manage. Surplus = a pinnable item NO squad position has claimed -- with everyone's gear
-- pinned, anything left over is by definition spare -- and below masterwork. Bounded by
-- what we are actually short of, worst (most damaged, then lowest quality) first.
local function melt_surplus(shortfall, claimed, managed_ts, extra_short)
    local short = {}
    for _, r in pairs(shortfall) do
        if r.mat_type == 0 then
            local mk = barkey(r.mat_type, r.mat_index)
            short[mk] = (short[mk] or 0) + r.count
        end
    end
    for mk, n in pairs(extra_short or {}) do short[mk] = (short[mk] or 0) + n end
    if not next(short) then return 0 end

    -- NEVER recycle a kind of gear we are still short of. "Unclaimed" is not the same as
    -- "surplus": a shield can be unclaimed because it is forbidden, the wrong size, or
    -- simply not reached yet -- and melting it while five soldiers stand there shieldless
    -- is the exact opposite of the goal. (Caught live: one steel shield was melt-designated
    -- while the fort had zero free shields and five soldiers wanting one.)
    local short_ts = {}
    for _, r in pairs(shortfall) do short_ts[r.item_type .. '/' .. r.subtype] = true end

    local cands, inbound = {}, {}
    for _, vec_id in pairs(OTHER_VEC) do
        for _, it in ipairs(df.global.world.items.other[vec_id]) do
            local mk = barkey(it:getMaterial(), it:getMaterialIndex())
            if short_ts[it:getType() .. '/' .. it:getSubtype()] then goto skip_item end
            -- only ever recycle the KINDS of gear soldiers actually wear (a type+subtype
            -- some uniform asks for). Anything else of the same metal -- a decorative
            -- weapon subtype, gear for a squad we don't manage -- is left alone.
            if short[mk] and not claimed[it.id]
                and managed_ts[it:getType() .. '/' .. it:getSubtype()]
                and not not_fort_stock(it) then
                if it.flags.melt then
                    if holder_of(it) then
                        -- a worn piece marked for melt is STUCK (the melt job never fires
                        -- while it's equipped) -- un-designate it so it stops blocking
                        dfhack.items.cancelMelting(it)
                    elseif not it.flags.forbid then
                        inbound[mk] = (inbound[mk] or 0) + 1     -- metal already on the way
                    end
                elseif it:getQuality() < df.item_quality.Masterful
                    and not it.flags.artifact
                    and not holder_of(it)
                    and not item_installed(it)
                    and dfhack.items.canMelt(it)
                then
                    cands[mk] = cands[mk] or {}
                    table.insert(cands[mk], it)
                end
            end
            ::skip_item::
        end
    end
    local marked = 0
    for mk, owed in pairs(short) do
        local list = cands[mk]
        local deficit = owed - (inbound[mk] or 0)
        if deficit > 0 and list and #list > 0 then
            table.sort(list, function(a, b)
                local wa, wb = item_wear(a), item_wear(b)
                if wa ~= wb then return wa > wb end            -- most-damaged first
                return a:getQuality() < b:getQuality()          -- then lowest quality
            end)
            for i = 1, math.min(deficit, #list) do
                if mark_melt(list[i]) then marked = marked + 1 end
            end
        end
    end
    return marked
end

-- A leather-category supply order (backpack / waterskin) tracked like a gear order: queue
-- ONE while soldiers lack the item and a tanned hide is on hand; delete it once everyone
-- is covered. (A waterskin is just a leather FLASK.)
local function ensure_supply(key, job, want, have, hides)
    if want > 0 and have < want and hides >= 1 then
        local o = state.orders[key] and order_by_id(state.orders[key])
        if not o then
            local mo = df.global.world.manager_orders
            o = df.manager_order:new()
            o.job_type, o.item_type, o.item_subtype = job, -1, -1
            o.mat_type, o.mat_index = -1, -1
            o.material_category.leather = true     -- from any tanned hide
            o.id = mo.manager_order_next_id
            mo.manager_order_next_id = o.id + 1
            o.frequency = df.workquota_frequency_type.OneTime
            o.amount_total, o.amount_left = 1, 1
            o.status.validated, o.status.active = true, true
            mo.all:insert(0, o)
            state.orders[key] = o.id
        elseif o.amount_left < 1 then
            o.amount_total, o.amount_left = 1, 1
            o.status.active = true
        end
    else
        drop_order(key)
    end
end

-- ---- war-dog training: train surplus adult males beyond the breeders --------
--
-- War training is the Pets/Livestock system, NOT the military: add a
-- training_assignment to plotinfo.training with flags.train_war, and any dwarf
-- with the Animal Trainer skill turns the dog into a war dog (profession
-- TRAINED_WAR) over time. We keep BREEDER_MALES untrained adult males for
-- breeding and queue the rest; females and pups are left alone.
local function dog_race()
    local all = df.global.world.raws.creatures.all
    for i = 0, #all - 1 do
        if all[i].creature_id == 'DOG' then return i end
    end
end

local function is_war_dog(u) return u.profession == df.profession.TRAINED_WAR end

-- a male dog pup (baby or child) of our civ, alive and tame
local function is_male_puppy(u, race)
    return u.race == race and u.sex == 1 and dfhack.units.isOwnCiv(u) and dfhack.units.isTame(u)
        and dfhack.units.isAlive(u) and (dfhack.units.isBaby(u) or dfhack.units.isChild(u))
end

-- returns newly-queued count. Keeps BREEDER_MALES males as the breeding stock, but a male
-- PUPPY counts toward that reserve (it'll grow into a breeder), so e.g. 2 adults + 1 male
-- pup reserves only 1 adult and trains the other. Females and pups are never trained.
local function train_surplus_war_dogs()
    local race = dog_race()
    if not race then return 0 end
    local tr = df.global.plotinfo.training.training_assignments
    local assigned = {}
    for i = 0, #tr - 1 do assigned[tr[i].animal_id] = true end
    -- untrained, unassigned, living, tame, adult male dogs = the train pool
    local pool, male_pups = {}, 0
    for _, u in ipairs(df.global.world.units.active) do
        if is_male_puppy(u, race) then
            male_pups = male_pups + 1
        elseif u.race == race and u.sex == 1 and dfhack.units.isOwnCiv(u) and dfhack.units.isTame(u)
            and dfhack.units.isAlive(u) and not dfhack.units.isBaby(u) and not dfhack.units.isChild(u)
            and not is_war_dog(u) and not assigned[u.id]
        then pool[#pool + 1] = u end
    end
    -- reserve adult males as breeders, but male pups fill that reserve first
    local reserve = math.max(0, BREEDER_MALES - male_pups)
    local queued = 0
    for i = reserve + 1, #pool do
        local ta = df.training_assignment:new()
        ta.animal_id = pool[i].id
        ta.trainer_id = -1
        ta.flags.train_war = true
        ta.flags.any_trainer = true
        tr:insert('#', ta)
        queued = queued + 1
    end
    return queued
end

-- fort citizens currently in a squad (war dogs get spread across them)
local function squad_members()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if u.military.squad_id >= 0 and dfhack.units.isCitizen(u)
            and dfhack.units.isActive(u) and not dfhack.units.isDead(u)
        then out[#out + 1] = u end
    end
    return out
end

-- assign every trained war dog that has no owner to the squad member with the fewest war
-- dogs (so they spread evenly across the military). The owner link is the animal's
-- relationship_ids.PetOwner -- the same field the game's "assign animal" sets. Returns the
-- number newly assigned.
local function assign_war_dogs()
    local race = dog_race()
    if not race then return 0 end
    local members = squad_members()
    if #members == 0 then return 0 end
    local count, unowned = {}, {}
    for _, m in ipairs(members) do count[m.id] = 0 end
    for _, u in ipairs(df.global.world.units.active) do
        if u.race == race and is_war_dog(u) and dfhack.units.isOwnCiv(u) and dfhack.units.isAlive(u) then
            local owner = u.relationship_ids.PetOwner
            if owner >= 0 then
                if count[owner] ~= nil then count[owner] = count[owner] + 1 end   -- already on a soldier
            else
                unowned[#unowned + 1] = u
            end
        end
    end
    local assigned = 0
    for _, dog in ipairs(unowned) do
        local best = members[1]
        for _, m in ipairs(members) do if count[m.id] < count[best.id] then best = m end end
        dog.relationship_ids.PetOwner = best.id
        count[best.id] = count[best.id] + 1
        assigned = assigned + 1
    end
    return assigned
end

-- ---- steel tools for miners / woodcutters (the OLD path, deliberately kept) ----
-- A dwarf with the mining labor cannot be uniformed at all (a DF conflict), so a miner's
-- pick can never be handled by the pinning model above -- it is not a uniform slot. Same
-- for a woodcutter's axe. This keeps them stocked the pre-pinning way: forge toward one
-- steel tool per worker, then forbid the others so they switch over.

-- fort citizens with a given labor enabled
local function workers_with_labor(labor)
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and dfhack.units.isActive(u) and not dfhack.units.isDead(u) then
            local ok, has = pcall(function() return u.status.labors[labor] end)
            if ok and has then out[#out + 1] = u end
        end
    end
    return out
end
local function miners() return workers_with_labor(df.unit_labor.MINE) end
local function woodcutters() return workers_with_labor(df.unit_labor.CUTWOOD) end

-- a citizen SOLDIER is holding this item? (a pick or battle axe wielded as a military
-- weapon -- so the forbid never disarms them)
local function soldier_holding(it)
    local u = holder_of(it)
    return u and u.military.squad_id >= 0
end
-- held by a FIGHTER: a soldier who is NOT one of the workers we're equipping. Both picks
-- and battle axes double as military weapons, so a tool assigned to such a fighter must
-- NOT be counted as a spare worker tool.
local function held_by_fighter(it, worker_ids)
    local u = holder_of(it)
    return u and u.military.squad_id >= 0 and not worker_ids[u.id]
end

local function equip_workers(units, sub, key, done_field)
    local steel_idx = inorganic_idx('STEEL')
    if not steel_idx or not sub then drop_order(key); return 0 end
    local need = #units
    if need == 0 then drop_order(key); return 0 end
    local worker_ids = {}
    for _, u in ipairs(units) do worker_ids[u.id] = true end

    -- tally steel tools (total + masterwork), steel bars, and inferior melt candidates
    local total, mw, melting = 0, 0, 0
    local cands = {}
    for _, it in ipairs(df.global.world.items.other[df.items_other_id.WEAPON]) do
        if it:getSubtype() == sub and it:getMaterial() == 0 and it:getMaterialIndex() == steel_idx
            and not not_fort_stock(it)
        then
            if it.flags.melt then
                melting = melting + 1                       -- steel already on the way back
            elseif not item_installed(it)                   -- a trapped/displayed tool isn't stock
                and not held_by_fighter(it, worker_ids) then
                total = total + 1
                if it:getQuality() >= df.item_quality.Masterful and it.wear == 0 and not it.flags.artifact then
                    mw = mw + 1                             -- masterwork counts only if undamaged
                elseif dfhack.items.canMelt(it) and not holder_of(it) then
                    cands[#cands + 1] = it                  -- inferior, meltable, not in-hand
                end
            end
        end
    end
    local steel_bars = 0
    for _, it in ipairs(df.global.world.items.other[df.items_other_id.BAR]) do
        if it:getMaterial() == 0 and it:getMaterialIndex() == steel_idx and on_hand(it) then
            steel_bars = steel_bars + 1
        end
    end

    -- steel budget: bars minus the reserve minus every steel order we already track
    local committed = 0
    for _, id in pairs(state.orders) do
        local o = order_by_id(id)
        if o and o.amount_left > 0 and o.mat_type == 0 and o.mat_index == steel_idx then
            committed = committed + o.amount_left
        end
    end
    local budget = steel_bars - RESERVE_BARS - committed

    -- forge toward one (masterwork, if enabled) tool per worker, one at a time
    local avail = state.masterwork and mw or total
    local o = state.orders[key] and order_by_id(state.orders[key])
    local in_flight = o and o.amount_left > 0
    if avail < need and (in_flight or budget >= BARS_PER_ITEM) then
        queue_one(key, {item_type = df.item_type.WEAPON, subtype = sub,
                        mat_type = 0, mat_index = steel_idx})
    else
        drop_order(key)
    end

    -- COMPLETE = every worker has a (masterwork, if enabled) steel tool. Record it for the
    -- overlay's "Done" label, and forbid all OTHER tools of that type so the workers drop
    -- them and pick up the steel ones instead.
    local done = avail >= need
    state[done_field] = done
    if done then
        for _, it in ipairs(df.global.world.items.other[df.items_other_id.WEAPON]) do
            if it:getSubtype() == sub
                and not (it:getMaterial() == 0 and it:getMaterialIndex() == steel_idx)
                and not it.flags.forbid
                and not it.flags.trader and not not_fort_stock(it)   -- never a merchant's goods
                and not soldier_holding(it)   -- never disarm a soldier (pick/axe as a weapon)
            then it.flags.forbid = true end
        end
    end

    -- masterwork: recycle inferior surplus tools when steel + inbound melts don't cover the
    -- masterwork shortfall (keep at least `need` so workers aren't left bare)
    if state.masterwork then
        local owed = math.max(0, need - mw)
        local deficit = owed - (steel_bars + melting)
        if deficit > 0 and #cands > 0 and total > need then
            table.sort(cands, function(a, b)
                local wa, wb = item_wear(a), item_wear(b)
                if wa ~= wb then return wa > wb end
                return a:getQuality() < b:getQuality()
            end)
            for i = 1, math.min(deficit, #cands, total - need) do mark_melt(cands[i]) end
        end
    end

    -- report how many tools we still need but can't forge from current steel bars, so the
    -- caller can recycle surplus steel GEAR into bars for them
    return math.max(0, (need - avail) - math.max(0, budget))
end

-- ---- the cycle ---------------------------------------------------------------

local function run_cycle()
    if not dfhack.world.isFortressMode() then return end
    load_state()
    if state.wardogs and not dry_run then train_surplus_war_dogs(); assign_war_dogs() end
    -- steel digging picks for miners + steel battle axes for woodcutters (same toggle)
    local tool_short = 0
    if state.pickaxes and not dry_run then
        tool_short = equip_workers(miners(), pick_subtype(), 'pick', 'done_picks')
                   + equip_workers(woodcutters(), axe_subtype(), 'axe', 'done_axes')
    elseif not dry_run then
        drop_order('pick'); drop_order('axe')
    end
    if not state.queue then if not dry_run then save_state() end return end

    local ent = fort_entity()
    if ent then ensure_cloaks(ent) end   -- cloaks in the owned uniform TEMPLATES (never positions)

    clear_unmanned_positions()           -- no dead soldier's pins locking gear away
    -- one spec per wearable item in pair slots, so gauntlets/boots can carry a real
    -- spec.item pin like everything else and survive DF's "Refresh Equipment"
    local split_added, split_removed = ensure_pair_specs()
    local soldiers = read_soldiers()
    local jobitems = live_job_items()          -- one bounded walk; used to spot stale in_job
    -- free already-assigned pieces (ours AND hand-picked ones) from bins / phantom job
    -- claims BEFORE deciding anything, so this cycle's nudge can actually reach them
    local freed, unjobbed, unforbid, owned = unstick_assigned(soldiers, jobitems)
    local claimed = claimed_items()
    local pool = build_pool(claimed, jobitems)
    local shortfall, pinned, repinned, released, adopted, repaired, nudged, pruned =
        assign_gear(soldiers, claimed, pool, jobitems)
    local _, budget = queue_shortfall(shortfall)
    queue_standins(shortfall, budget)   -- something wearable while the real metal is short

    -- recycle surplus gear into bars: for the masterwork upgrade, and when the miner/
    -- woodcutter tools have run the steel out
    if state.masterwork or tool_short > 0 then
        local managed_ts = {}
        for _, sol in ipairs(soldiers) do
            for _, e in ipairs(sol.specs) do
                managed_ts[e.want.item_type .. '/' .. e.want.subtype] = true
            end
        end
        local steel_idx = inorganic_idx('STEEL')
        local extra = tool_short > 0 and steel_idx and {[barkey(0, steel_idx)] = tool_short} or nil
        melt_surplus(shortfall, claimed, managed_ts, extra)
    end

    -- leather field kit: a backpack (food) and a waterskin/flask per soldier
    local hides, flasks, backpacks = 0, 0, 0
    for _, it in ipairs(df.global.world.items.other[df.items_other_id.SKIN_TANNED]) do
        if on_hand(it) then hides = hides + 1 end
    end
    for _, it in ipairs(df.global.world.items.other[df.items_other_id.FLASK]) do
        if not it.flags.melt then flasks = flasks + 1 end
    end
    for _, it in ipairs(df.global.world.items.other[df.items_other_id.BACKPACK]) do
        if not it.flags.melt then backpacks = backpacks + 1 end
    end
    ensure_supply('supply/backpack', df.job_type.MakeBackpack, #soldiers, backpacks, hides)
    ensure_supply('supply/flask', df.job_type.MakeFlask, #soldiers, flasks, hides)

    -- CIVILIAN MILITIA: routine swapping + member shuffling are NOT part of the automatic
    -- cycle (too brittle unattended -- it kept overriding hand-set squad schedules). The
    -- cycle only SNAPSHOTS the picture here; `civilian-militia` applies an arrangement on
    -- demand via civilian_arrange() below.
    local snap = {}
    for _, sol in ipairs(soldiers) do
        local equipped = true
        for _, e in ipairs(sol.specs) do if not e.satisfied then equipped = false; break end end
        snap[#snap + 1] = {unit_id = sol.unit_id, sid = sol.sid, leader = sol.leader,
                           real_civ = sol.real_civ, pinned = sol.custom, equipped = equipped}
    end
    civ_snapshot = {persoldier = snap}

    -- completion flag for the overlay's "Done" labels: every managed slot pinned to a piece
    -- of the demanded material (and, when the masterwork toggle is on, at masterwork
    -- quality -- assign_gear folds that test into `satisfied`). Vacuously done when nothing
    -- is required. The masterwork label only ever shows while its toggle is on, so it is
    -- the same measurement under that toggle.
    local queue_done = true
    for _, sol in ipairs(soldiers) do
        for _, e in ipairs(sol.specs) do
            if not e.satisfied then queue_done = false; break end
        end
        if not queue_done then break end
    end
    state.done_queue = queue_done
    state.done_masterwork = state.masterwork and queue_done or false

    if dry_run then
        local fully, partly = 0, 0
        for _, sol in ipairs(soldiers) do
            local want_n, filled_n = 0, 0
            for _, e in ipairs(sol.specs) do
                want_n = want_n + e.want.qty; filled_n = filled_n + e.filled
            end
            if filled_n >= want_n then fully = fully + 1
            elseif filled_n > 0 then partly = partly + 1 end
        end
        note('')
        note('%d of %d soldiers would have EVERY slot filled; %d partly, %d with nothing',
             fully, #soldiers, partly, #soldiers - fully - partly)
        note('slots: %d already correct (adopted), %d newly pinned, %d upgraded, %d stale released, %d repaired',
             adopted, pinned, repinned, released, repaired)
        note('%d soldier(s) would be given a PickupEquipment job', nudged)
        note('pair slots: %d spec(s) would be added, %d removed', split_added, split_removed)
        note('unstick: %d freed from bins, %d phantom job claims cleared, %d un-forbidden, %d ownership claimed',
             freed, unjobbed, unforbid, owned)
        local n, pieces = 0, 0
        for _, r in pairs(shortfall) do n = n + 1; pieces = pieces + r.count end
        note('still to forge: %d piece(s) across %d gear key(s)', pieces, n)
        return
    end
    if split_added > 0 or split_removed > 0 then
        print(('military-uniforms: pair slots normalised (%d spec(s) added, %d removed)')
            :format(split_added, split_removed))
    end
    if freed > 0 or unjobbed > 0 or unforbid > 0 or owned > 0 then
        print(('military-uniforms: unstuck %d from bins, %d phantom job claims, %d forbidden, claimed %d unowned')
            :format(freed, unjobbed, unforbid, owned))
    end
    if pinned > 0 or repinned > 0 or released > 0 or repaired > 0 or nudged > 0 or pruned > 0 then
        print(('military-uniforms: pinned %d, upgraded %d, released %d stale, repaired %d, nudged %d (%d already correct)')
            :format(pinned, repinned, released, repaired, nudged, adopted)
              .. (pruned > 0 and (', pruned %d DF-added extra(s)'):format(pruned) or ''))
    end
    save_state()        -- persist the updated order-id map + completion flags
end

-- ---- civilian militia arrangement -------------------------------------------
-- A squad set to "Ready" makes ALL its members equip, stripping any who lack a full set
-- down to naked. So instead of flipping a squad early, we PACK members between civilian
-- squads so every Ready squad holds only members who are each fully equipped -- and each
-- person kits up as their own set comes off the forge. Squad LEADERS never move (they
-- anchor their squad). A member with a hand-assigned CUSTOM uniform is PINNED: never moved
-- (a move would replace their custom uniform with the destination's standard one).
--
-- With gear pinned per soldier there is no stock pool to reserve against any more: a
-- member is equippable exactly when every slot we manage for them is pinned, which the
-- cycle already computed. That reduced this from a stock-allocation problem to a count.
local OFF_ROUTINE = 0                       -- "No Orders" == the built-in Off-duty routine (index 0)

-- index of the "Ready" routine in the fort's schedule list, or nil if there's none
local function ready_routine_idx()
    local routines = df.global.plotinfo.alerts.routines
    for i = 0, #routines - 1 do
        if routines[i].name == 'Ready' then return i end
    end
end

local function arrange_civilian_squads(persoldier)
    local ridx = ready_routine_idx()
    if not ridx then return end
    local training = autotraining_squads()

    -- gather real civilian squads. Split each squad's members into its LEADER, PINNED
    -- members (a hand-assigned custom uniform -- never moved, else the move wipes it), and
    -- MOVABLE members (standard uniform, freely repacked).
    local squads, sids = {}, {}
    for _, e in ipairs(persoldier) do
        if e.real_civ and not training[e.sid] then
            local g = squads[e.sid]
            if not g then g = {movable = {}, pinned = {}}; squads[e.sid] = g; sids[#sids + 1] = e.sid end
            if e.leader then g.leader = e
            elseif e.pinned then g.pinned[#g.pinned + 1] = e
            else g.movable[#g.movable + 1] = e end
        end
    end
    if #sids == 0 then return end
    table.sort(sids)

    local movpool = {}
    for _, sid in ipairs(sids) do for _, m in ipairs(squads[sid].movable) do movpool[#movpool + 1] = m end end

    -- a PINNED member counts as equipped without further checks: their gear is hand-picked
    -- specific items, so our managed-slot test says nothing about them
    local function ok(m) return m.pinned or m.equipped end

    -- M = total civilian members; S = how many are fully equipped -- together these set how
    -- many Ready vs No-Orders squads are needed
    local M, S = 0, 0
    for _, sid in ipairs(sids) do
        local g = squads[sid]
        local all = {}
        if g.leader then all[#all + 1] = g.leader end
        for _, p in ipairs(g.pinned) do all[#all + 1] = p end
        for _, m in ipairs(g.movable) do all[#all + 1] = m end
        M = M + #all
        for _, m in ipairs(all) do if ok(m) then S = S + 1 end end
    end
    local avail = #sids
    local function ceil10(n) return n > 0 and math.floor((n + 9) / 10) or 0 end
    local ready_needed, noorder_needed = ceil10(S), ceil10(M - S)
    local feasible = (ready_needed + noorder_needed) <= avail
    local R = feasible and ready_needed or math.max(0, avail - noorder_needed)
    local need_squad = not feasible

    -- assign the first R squads as Ready. A squad's fixed occupants (leader + any pinned
    -- members) can't be moved out, so it can be Ready only if EVERY one of them is
    -- equipped (else a fixed member is stripped naked); then fill the rest with movable
    -- equipped members. Everything else -> No Orders.
    local target, routine, used = {}, {}, {}
    local ready_made = 0
    for _, sid in ipairs(sids) do
        local g = squads[sid]
        local anchors = {}
        if g.leader then anchors[#anchors + 1] = g.leader end
        for _, p in ipairs(g.pinned) do anchors[#anchors + 1] = p end
        -- a squad anchored by a PINNED member can't be consolidated away (pinned members
        -- never move), so it earns Ready on its own merits, outside the ceil(S/10) cap --
        -- otherwise a hand-kitted noble's one-man squad loses the Ready slots to lower
        -- squad ids and gets planned No-Orders forever
        local has_pinned = (g.leader and g.leader.pinned) or #g.pinned > 0
        local can = g.leader ~= nil and (ready_made < R or has_pinned)
        if can then
            for _, a in ipairs(anchors) do if not ok(a) then can = false; break end end
        end
        if can then
            routine[sid] = ridx
            if not has_pinned then ready_made = ready_made + 1 end
            local filled = #anchors
            for _, a in ipairs(anchors) do target[a.unit_id] = sid; used[a.unit_id] = true end
            local order = {}
            for _, m in ipairs(g.movable) do order[#order + 1] = m end
            for _, m in ipairs(movpool) do order[#order + 1] = m end
            for _, m in ipairs(order) do
                if filled >= 10 then break end
                if not used[m.unit_id] and ok(m) then
                    target[m.unit_id] = sid; used[m.unit_id] = true; filled = filled + 1
                end
            end
        else
            routine[sid] = OFF_ROUTINE
            for _, a in ipairs(anchors) do target[a.unit_id] = sid; used[a.unit_id] = true end
        end
    end
    -- place remaining MOVABLE members into No-Orders squads; the leader + pinned members
    -- already hold fixed slots, so a No-Orders squad has (9 - #pinned) movable slots.
    -- Prefer their current squad.
    local noorder, slots = {}, {}
    for _, sid in ipairs(sids) do
        if routine[sid] == OFF_ROUTINE then noorder[#noorder + 1] = sid; slots[sid] = 9 - #squads[sid].pinned end
    end
    for _, m in ipairs(movpool) do
        if not used[m.unit_id] and routine[m.sid] == OFF_ROUTINE and (slots[m.sid] or 0) > 0 then
            target[m.unit_id] = m.sid; used[m.unit_id] = true; slots[m.sid] = slots[m.sid] - 1
        end
    end
    for _, m in ipairs(movpool) do
        if not used[m.unit_id] then
            for _, sid in ipairs(noorder) do
                if slots[sid] > 0 then target[m.unit_id] = sid; slots[sid] = slots[sid] - 1; used[m.unit_id] = true; break end
            end
            if not used[m.unit_id] then need_squad = true end   -- nowhere to put them
        end
    end

    if _G.MU_DRY_ARRANGE then
        for _, sid in ipairs(sids) do
            local n = 0; for _, ts in pairs(target) do if ts == sid then n = n + 1 end end
            print(('PLAN squad %d -> %-8s members=%d'):format(sid, routine[sid] == ridx and 'Ready' or 'NoOrders', n))
        end
        print(('PLAN M=%d S=%d avail=%d ready_needed=%d noorder_needed=%d feasible=%s R=%d need_squad=%s'):format(
            M, S, avail, ready_needed, noorder_needed, tostring(feasible), R, tostring(need_squad)))
        return
    end

    -- EXECUTE: free every mover first (so target slots open up), then re-add.
    -- NOTE: a move drops the destination position's uniform on the mover, which includes
    -- whatever WE pinned to that position's previous occupant -- the next cycle re-checks
    -- every pin against its new owner and re-pins, so this self-corrects.
    local moves = {}
    for uid, sid in pairs(target) do
        local u = df.unit.find(uid)
        if u and u.military.squad_id ~= sid then moves[#moves + 1] = {uid = uid, sid = sid} end
    end
    for _, mv in ipairs(moves) do pcall(dfhack.military.removeFromSquad, mv.uid) end
    for _, mv in ipairs(moves) do pcall(dfhack.military.addToSquad, mv.uid, mv.sid, -1) end
    for _, sid in ipairs(sids) do
        local sq = df.squad.find(sid)
        if sq then
            -- RESPECT MANUAL ROUTINES: only ever flip a squad between Off-duty and Ready.
            -- A squad the player put on ANY other routine (training, even/odd month,
            -- custom) is never touched.
            local cur = sq.cur_routine_idx
            if cur == OFF_ROUTINE or cur == ridx then
                local want = routine[sid]
                if cur ~= want then sq.cur_routine_idx = want end
            end
        end
    end

    state.civ_need_squad = need_squad and true or false
end

-- Run one civilian-militia arrangement pass (the `civilian-militia` command's engine):
-- runs a gear cycle first so the snapshot is fresh, then packs civilian squads and flips
-- their routines (Off-duty <-> Ready only; hand-set routines are never touched).
-- dry = print the plan, change nothing.
function civilian_arrange(dry)
    if not dfhack.world.isFortressMode() then qerror('civilian_arrange needs a loaded fortress') end
    load_state()
    if not state.queue then
        qerror('the gear service ("Queue gear orders") is off -- no gear snapshot to plan from')
    end
    run_cycle()
    if not civ_snapshot then qerror('no gear snapshot (no squads with uniforms?)') end
    _G.MU_DRY_ARRANGE = dry and true or nil
    local ok, err = pcall(arrange_civilian_squads, civ_snapshot.persoldier)
    _G.MU_DRY_ARRANGE = nil
    if not ok then qerror(tostring(err)) end
end

-- ---- heartbeat ---------------------------------------------------------------

-- per-frame heartbeat gated on the calendar (repeat-util's tick timers fire too
-- coarsely on this build; see auto-mandate); runs the cycle ~once a game-day.
-- The generation counter lives on dfhack.internal (NOT a module local) so it
-- survives script reloads: reloading/re-enabling bumps it, and every previously
-- scheduled heartbeat -- including ones closed over an older copy of this code --
-- sees my ~= current and exits instead of leaking a second ticking loop.
--
-- HOT-RELOAD TRAP, hit for real: the generation is only bumped by start_heartbeat /
-- stop_heartbeat. `reqscript` alone returns at the dfhack_flags.module guard and calls
-- NEITHER -- so a heartbeat scheduled by an EARLIER version of this file keeps ticking that
-- old code against the same fort. That is not merely a duplicate loop, it is two different
-- algorithms fighting: the pre-pinning version's weekly unstick pass erases any assignment
-- whose item the soldier is not yet carrying and no job is fetching -- i.e. exactly the pins
-- this version writes. Symptom was ~50 assignments silently reverting each game-day while
-- the code looked correct. AFTER ANY HOT RELOAD, take ownership of the tick:
--     dfhack-run lua 'reqscript("fort/military-uniforms").set_toggle("queue", true)'
-- (Tell-tale that the old code is still live: state.last_unstick or state.best_q reappearing
-- in the persisted site data -- only the pre-rewrite version ever wrote those.)
local last_run = nil
local function hb_gen(set)
    if set ~= nil then dfhack.internal.military_uniforms_hb_gen = set end
    return dfhack.internal.military_uniforms_hb_gen or 0
end

-- Give every workshop job that came from one of OUR gear orders "top priority"
-- (job.flags.do_now -- exactly what the workshop's "Make top priority" toggle sets), so the
-- forge does auto-gear pieces before other queued work. A job carries the manager order id
-- it was assigned from (job.order_id), so we match our tracked orders EXACTLY -- no guessing
-- by type. Idempotent; a bounded walk of the active job list so a corrupt list can never
-- hang the game.
local function prioritize_gear_jobs()
    load_state()
    if not state.orders or not next(state.orders) then return end
    local ours = {}
    for _, id in pairs(state.orders) do ours[id] = true end
    local link = df.global.world.jobs.list.next
    local guard = 0
    while link and guard < 4000 do
        guard = guard + 1
        local j = link.item
        if j and j.order_id and ours[j.order_id] and not j.flags.do_now then
            j.flags.do_now = true
        end
        link = link.next
    end
end

local function start_heartbeat()
    last_run = nil
    local my = hb_gen() + 1
    hb_gen(my)
    local prio = 0
    local function hb()
        if not service_on() or my ~= hb_gen() then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= DAY_TICKS then last_run = now; run_cycle() end
        prio = prio + 1
        if prio >= 50 then prio = 0; pcall(prioritize_gear_jobs) end   -- ~1s: our gear jobs -> top priority
        dfhack.timeout(1, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

-- delete every standing order we created (used when the service is switched off)
local function drop_all_orders()
    for key in pairs(state.orders) do drop_order(key) end
end

-- Release every pin this service made, leaving the uniforms' filter specs exactly as they
-- were -- so switching the service off hands each slot back to DF's own solver. A
-- hand-picked specific item (filters all -1) is never touched.
local function release_all_pins()
    local fort = df.global.plotinfo.group_id
    local n = 0
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                for slot = 0, 6 do
                    local v = pos.equipment.uniform[slot]
                    for j = 0, #v - 1 do
                        local spec = v[j]
                        if spec.item >= 0 and spec.item_type >= 0 then   -- ours, not hand-picked
                            spec.item = -1
                            dirty(spec.item_type)
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    return n
end

-- set a toggle; runs the cycle now and (re)starts/stops the shared heartbeat so
-- it ticks whenever any service is on
function set_toggle(name, val)
    load_state()
    state[name] = val
    save_state()
    if name == 'queue' and not val then
        drop_all_orders()
        release_all_pins()
        save_state()
    end
    if name == 'pickaxes' and not val then drop_order('pick'); drop_order('axe'); save_state() end
    if service_on() then start_heartbeat() else stop_heartbeat() end
    run_cycle()
end

-- ---- notification: "appoint another civilian squad" (mirrors the pack's notify scripts) ----
-- arrange_civilian_squads sets state.civ_need_squad when the civilian militia cannot be split into
-- equipped (Ready) and un-equipped (No Orders) groups without another squad. Surface that as a
-- notify-panel line so the player knows to appoint one more civilian squad.
local CIV_SQUAD_NOTE = 'military_uniforms_civ_squad'
local function civ_squad_message()
    if not dfhack.world.isFortressMode() then return end
    load_state()
    if not state.civ_need_squad then return end
    return {{text = 'Appoint another civilian militia squad (no room to equip everyone)', pen = COLOR_YELLOW}}
end
local function register_civ_squad_notify()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok or not n then return end
    local entry = n.NOTIFICATIONS_BY_NAME[CIV_SQUAD_NOTE]
    if not entry then
        entry = {name = CIV_SQUAD_NOTE, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[CIV_SQUAD_NOTE] = entry
    end
    entry.desc = 'Asks you to appoint another civilian militia squad when the existing ones cannot '
        .. 'hold the equipped (Ready) and un-equipped (No Orders) members in separate squads.'
    entry.dwarf_fn = civ_squad_message
    if n.config and n.config.data and not n.config.data[CIV_SQUAD_NOTE] then
        n.config.data[CIV_SQUAD_NOTE] = {enabled = true, version = 1}
    end
end
register_civ_squad_notify()

-- ---- notifications: gear completeness, measured against what soldiers actually WEAR ----------
-- These read each squad member's real inventory (not just the order queue) so the counts always
-- reflect the gear the military is using right now. A piece counts as equipped only if it is worn,
-- wielded, or strapped (mode 2/1/10) -- a piece merely hauled or sitting in stock does not.
local NOTE_GEAR = 'military_uniforms_gear'
local NOTE_MW = 'military_uniforms_masterwork'
local EQUIPPED_MODE = {[1] = true, [2] = true, [10] = true}    -- Weapon (wielded), Worn, Strapped

-- singular + plural name of a uniform piece (item_type + subtype), e.g. "gauntlet"/"gauntlets" --
-- pulled from the itemdef so it reads like the game does; falls back to the item-type token.
local PIECE_DEFVEC = {}
for _, p in ipairs{{'ARMOR', 'armor'}, {'HELM', 'helms'}, {'PANTS', 'pants'}, {'GLOVES', 'gloves'},
                   {'SHOES', 'shoes'}, {'SHIELD', 'shields'}, {'WEAPON', 'weapons'}, {'AMMO', 'ammo'}} do
    if df.item_type[p[1]] then PIECE_DEFVEC[df.item_type[p[1]]] = p[2] end
end
local function piece_name(item_type, subtype)
    local ln = PIECE_DEFVEC[item_type]
    if ln and subtype >= 0 then
        local vec = df.global.world.raws.itemdefs[ln]
        if vec then
            for i = 0, #vec - 1 do
                if vec[i].subtype == subtype and vec[i].name ~= '' then
                    return vec[i].name, (vec[i].name_plural ~= '' and vec[i].name_plural) or (vec[i].name .. 's')
                end
            end
        end
    end
    local base = df.item_type[item_type]
    base = base and base:lower():gsub('_', ' ') or 'item'
    return base, base .. 's'
end

-- Walk every occupied fort-squad position and compare the managed uniform specs to what the
-- occupant is actually wearing. Returns totals:
--   soldiers  = squad members with a managed uniform
--   missing   = members not wearing every managed piece (a gap, of any kind)
--   notmw     = members wearing every piece but with some piece below masterwork quality
-- plus the persisted done_queue / done_masterwork / masterwork flags.
-- Result is cached within a game tick so the two notifications don't each re-scan the fort.
local _gear_cache, _gear_cache_tick
local function analyze_gear()
    local now = df.global.cur_year * 1200000 + df.global.cur_year_tick
    if _gear_cache and _gear_cache_tick == now then return _gear_cache end
    local soldiers, missing, notmw = 0, 0, 0
    local miss_agg = {}   -- [item_type*100000+subtype] = total pieces of that type missing fort-wide
    for _, sol in ipairs(read_soldiers()) do
        local u = sol.unit
        -- what this soldier is supposed to have, by type+subtype, with the material demanded
        local need = {}
        for _, e in ipairs(sol.specs) do
            local w = e.want
            local k = w.item_type * 100000 + w.subtype
            local rq = need[k]
            if not rq then rq = {n = 0, mt = w.mat_type, mi = w.mat_index}; need[k] = rq end
            rq.n = rq.n + w.qty
        end
        if next(need) then
            soldiers = soldiers + 1
            local have, worstq = {}, {}
            for _, ie in ipairs(u.inventory) do
                if EQUIPPED_MODE[ie.mode] then
                    local it = ie.item
                    local k = it:getType() * 100000 + it:getSubtype()
                    local rq = need[k]
                    -- MATERIAL-AWARE: when the uniform demands an EXACT material (steel), a
                    -- worn piece only satisfies the slot if it IS that material. A stand-in
                    -- does not count as wearing the correct thing -- otherwise a stand-in
                    -- wearer reads as satisfied, then flips to "missing" when they swap up.
                    if rq then
                        local mt, mi = item_matpair(it)
                        if mt == rq.mt and mi == rq.mi then
                            have[k] = (have[k] or 0) + 1
                            local q = it.getQuality and it:getQuality() or 0
                            if not worstq[k] or q < worstq[k] then worstq[k] = q end
                        end
                    end
                end
            end
            local short, below_mw = false, false
            for k, rq in pairs(need) do
                local gap = rq.n - (have[k] or 0)
                if gap > 0 then short = true; miss_agg[k] = (miss_agg[k] or 0) + gap end
                if (have[k] or 0) > 0 and (worstq[k] or 0) < df.item_quality.Masterful then below_mw = true end
            end
            if short then missing = missing + 1
            elseif below_mw then notmw = notmw + 1 end
        end
    end
    -- the item type with the most pieces missing fort-wide, and how many of it are short
    local top_k, top_n
    for k, n in pairs(miss_agg) do
        if not top_n or n > top_n then top_k, top_n = k, n end
    end
    local common_name, common_plural
    if top_k then common_name, common_plural = piece_name(math.floor(top_k / 100000), top_k % 100000) end
    local st = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
    _gear_cache = {soldiers = soldiers, missing = missing, notmw = notmw,
                   common_count = top_n, common_name = common_name, common_plural = common_plural,
                   done_queue = st.done_queue, done_masterwork = st.done_masterwork,
                   masterwork = st.masterwork}
    _gear_cache_tick = now
    return _gear_cache
end

-- Line 1: N of M soldiers aren't wearing their full assigned uniform, plus the single item type with
-- the most pieces short and how many of it are missing (e.g. "14/87 missing uniform items (8
-- gauntlets)"). Colour reflects the phase: red while still being forged, yellow once all forged.
local function gear_message()
    if not dfhack.world.isFortressMode() then return end
    local g = analyze_gear()
    if g.missing <= 0 then return end
    local n = g.common_count or 0
    local label = ('%d %s'):format(n, (n == 1 and g.common_name or g.common_plural) or 'items')
    return {{text = ('%d/%d missing uniform items (%s)'):format(g.missing, g.soldiers, label),
        pen = g.done_queue and COLOR_YELLOW or COLOR_LIGHTRED}}
end

-- Line 2: only once "Upgrade to masterwork" is on AND EVERY soldier is already in their complete
-- uniform (missing == 0) -- then count members who have all their pieces but not all at masterwork
-- quality. Gating on missing == 0 keeps this line from ever overlapping the line above.
local function masterwork_message()
    if not dfhack.world.isFortressMode() then return end
    local g = analyze_gear()
    if not g.masterwork or g.missing > 0 or g.notmw <= 0 then return end
    return {{text = ('%d military dwarves not yet in full masterwork gear'):format(g.notmw),
        pen = COLOR_YELLOW}}
end

local function register_gear_notify()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok or not n then return end
    local specs = {
        {name = NOTE_GEAR, fn = gear_message,
         desc = 'Reports how many military dwarves are not wearing every piece of their assigned '
             .. 'uniform, naming the item type with the most pieces short and how many (e.g. "8 gauntlets"). '
             .. 'Red while gear is still being forged, yellow once it is all forged.'},
        {name = NOTE_MW, fn = masterwork_message,
         desc = 'Once "Upgrade to masterwork" is on and every soldier\'s basic gear is forged, '
             .. 'reports how many military dwarves are not yet fully equipped in masterwork gear.'},
    }
    for _, spec in ipairs(specs) do
        local entry = n.NOTIFICATIONS_BY_NAME[spec.name]
        if not entry then
            entry = {name = spec.name, version = 1, default = true}
            table.insert(n.NOTIFICATIONS_BY_IDX, entry)
            n.NOTIFICATIONS_BY_NAME[spec.name] = entry
        end
        entry.desc = spec.desc
        entry.dwarf_fn = spec.fn
        -- registered but OFF by default (both plain and lovely magnus-scripts load this):
        -- the missing-uniform lines are noise; re-enable via gui/notify for a session
        -- when wanted (registration turns them back off on the next load)
        if n.config and n.config.data then
            n.config.data[spec.name] = n.config.data[spec.name] or {version = 1}
            n.config.data[spec.name].enabled = false
        end
    end
end
register_gear_notify()

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        managed_cache, hyena_cache, cloak_sub_cache = nil, nil, nil   -- per-world caches
        matval_cache = {}
        register_civ_squad_notify()
        register_gear_notify()
        if dfhack.world.isFortressMode() and service_on() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- overlay: toggles on the squad equipment screen ------------------------

-- completion flags mirrored from the persisted state so the toggle labels can read them.
-- A done-aware toggle shows "Done" (instead of "On") once its task has nothing left to do.
local DONE = {}
local function on_or_done(flag)
    return {
        {label = function() return DONE[flag] and 'Done' or 'On' end, value = true, pen = COLOR_GREEN},
        {label = 'Off', value = false},
    }
end

MilitaryUniformOverlay = defclass(MilitaryUniformOverlay, overlay.OverlayWidget)
MilitaryUniformOverlay.ATTRS{
    desc = 'Toggles to auto-pin squad gear, upgrade to masterwork, and train war dogs.',
    default_pos = {x = -93, y = 13},   -- right-anchored: the equip screen is flush to the
                                       -- screen's right edge, so track that edge to slide with it
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Equipment/Default',
    frame = {w = 36, h = 7},
}

function MilitaryUniformOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, h = 7},
            frame_style = gui.MEDIUM_FRAME,
            frame_background = gui.CLEAR_PEN,
            frame_title = 'auto gear',
            subviews = {
                widgets.ToggleHotkeyLabel{
                    view_id = 'queue',
                    frame = {t = 0, l = 0},
                    label = 'Queue gear orders',
                    key = 'CUSTOM_SHIFT_G',
                    options = on_or_done('queue'),
                    initial_option = false,
                    on_change = function(v) set_toggle('queue', v) end,
                },
                widgets.ToggleHotkeyLabel{
                    view_id = 'masterwork',
                    frame = {t = 1, l = 0},
                    label = 'Upgrade to masterwork',
                    key = 'CUSTOM_SHIFT_M',
                    options = on_or_done('masterwork'),
                    initial_option = false,
                    on_change = function(v) set_toggle('masterwork', v) end,
                },
                widgets.ToggleHotkeyLabel{
                    view_id = 'wardogs',
                    frame = {t = 2, l = 0},
                    label = 'Train surplus war dogs',
                    key = 'CUSTOM_SHIFT_D',
                    initial_option = false,
                    on_change = function(v) set_toggle('wardogs', v) end,
                },
                widgets.ToggleHotkeyLabel{
                    view_id = 'pickaxes',
                    frame = {t = 3, l = 0},
                    label = 'Forge Steel Tools',
                    key = 'CUSTOM_SHIFT_P',
                    options = on_or_done('picks'),
                    initial_option = false,
                    on_change = function(v) set_toggle('pickaxes', v) end,
                },
            },
        },
    }
end

function MilitaryUniformOverlay:render(dc)
    load_state()
    -- read completion flags straight from persisted state (the background cycle that sets
    -- them may run in a different script env than this overlay), for the "Done" labels
    local st = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
    DONE.queue, DONE.masterwork = st.done_queue, st.done_masterwork
    -- "Forge Steel Tools" is Done only when miners AND woodcutters are all covered (no woodcutters
    -- -> done_axes is vacuously true, so it reflects the picks alone)
    DONE.picks = st.done_picks and (st.done_axes ~= false)
    self.subviews.queue:setOption(state.queue)
    self.subviews.masterwork:setOption(state.masterwork)
    self.subviews.wardogs:setOption(state.wardogs)
    self.subviews.pickaxes:setOption(state.pickaxes)
    MilitaryUniformOverlay.super.render(self, dc)
end

OVERLAY_WIDGETS = {entry = MilitaryUniformOverlay}

-- EXPERIMENTAL (`military-uniforms altsched`): add two fort schedules, "even month" and "odd
-- month", right after "Ready" -- each trains on those months and stands Ready the rest -- and give
-- EVERY fort squad matching 6-entry schedules. All squads must stay length-synced with the routine
-- list, or the Schedule screen reads past the end of a squad's shorter list. Re-run after adding
-- squads (this is NOT automatic -- it would clobber hand edits). Per-month entries are built from
-- scratch: a train month is one squad_order_trainst (min_count 10) with 10 order_assignments ->
-- order 0; a ready month has 10 order_assignments -> -1. BOTH use sleep_mode AnywhereAtWill (0) so
-- soldiers sleep in their OWN bedrooms when they choose -- never InBarracksAtNeed (2, "sleep at
-- need"), which parks them asleep in the barracks on the job instead of working while equipped.
-- NB: `positions` is a vector<bool> -- it must be RESIZEd; inserting into a bit-packed vector<bool>
-- segfaults DF.
local function setup_alt_schedules()
    local function set_assignments(e, idx)
        e.order_assignments:resize(0)
        for _ = 1, 10 do local mp = df.squad_month_positionst:new(); mp.assigned_order_idx = idx; e.order_assignments:insert('#', mp) end
    end
    local SLEEP_AT_WILL = df.squad_sleep_option_type.AnywhereAtWill   -- own bed, at will (never barracks-at-need)
    local function make_train(e)
        e.sleep_mode = SLEEP_AT_WILL; e.uniform_mode = 0; e.orders:resize(0)
        local so = df.squad_schedule_order:new(); so.min_count = 10
        local t = df.squad_order_trainst:new(); t.issuer_hf = -1; t.recipient_hf = -1; t.origin_army_controller = -1
        so.order = t; so.positions:resize(10)
        e.orders:insert('#', so)
        set_assignments(e, 0)
    end
    local function make_ready(e)
        e.sleep_mode = SLEEP_AT_WILL; e.uniform_mode = 0; e.orders:resize(0)
        set_assignments(e, -1)
    end
    local function fill(sched, train_on_even)
        for m = 0, 11 do
            if ((m + 1) % 2 == 0) == train_on_even then make_train(sched.month[m]) else make_ready(sched.month[m]) end
        end
    end
    local routines = df.global.plotinfo.alerts.routines
    local maxid = -1; for i = 0, #routines - 1 do if routines[i].id > maxid then maxid = routines[i].id end end
    local function ensure_routine(name)
        for i = 0, #routines - 1 do if routines[i].name == name then return i end end
        maxid = maxid + 1
        local r = df.military_routinest:new(); r.id = maxid; r.name = name
        routines:insert('#', r)
        return #routines - 1
    end
    local eidx = ensure_routine('even month')
    local oidx = ensure_routine('odd month')
    local gid = df.global.plotinfo.group_id
    local n = 0
    for _, sq in ipairs(df.global.world.squads.all) do
        if sq.entity_id == gid and #sq.schedule.routine >= 4 then
            while #sq.schedule.routine <= oidx do sq.schedule.routine:insert('#', df.squad_routine_schedulest:new()) end
            fill(sq.schedule.routine[eidx], true)    -- even month: train on even months, Ready on odd
            fill(sq.schedule.routine[oidx], false)   -- odd month:  train on odd months,  Ready on even
            n = n + 1
        end
    end
    return n, eidx, oidx
end

if dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then qerror('military-uniforms only works in fortress mode') end
    set_toggle('queue', dfhack_flags.enable_state)
    print('military-uniforms: gear service ' .. (load_state().queue and 'ON' or 'OFF'))
    return
end

if not dfhack.world.isFortressMode() then qerror('military-uniforms only works in fortress mode') end

local args = {...}
if args[1] == 'civilian' then
    -- ensure both "Civilian - *" uniforms exist + are ordered. (You assign them to squads
    -- yourself -- this tool no longer drafts civilians.)
    local ent = fort_entity()
    if not ent then qerror('no fort entity') end
    for i = 0, #ent.uniforms - 1 do                                    -- migrate the old name
        if ent.uniforms[i].name == 'civilian' then ent.uniforms[i].name = 'Civilian - battle axe' end
    end
    local byname = {}
    for i = 0, #ent.uniforms - 1 do byname[ent.uniforms[i].name] = ent.uniforms[i] end
    for _, spec in ipairs(CIVILIAN_GROUP) do
        local nm = 'Civilian - ' .. spec.weapon
        if not byname[nm] then byname[nm] = create_civilian_uniform(ent, spec) end
    end
    reorder_uniforms(ent)
    load_state(); run_cycle()
    print('military-uniforms: civilian uniforms ready (Civilian - battle axe, Civilian - mace) + reordered.')
    return
end
if args[1] == 'orders' then
    load_state()
    run_cycle()        -- pin what we can and reconcile standing orders against the shortfall
    local n = 0
    for _ in pairs(state.orders) do n = n + 1 end
    print(('military-uniforms: %d gear order(s) standing (short of need)'):format(n))
    return
end
if args[1] == 'dry' then
    -- preview a full cycle against the live fort without writing anything: no pins, no
    -- assignments, no orders, no melts, no state saved
    load_state()
    dry_run, dry_log = true, {}
    local ok, err = pcall(run_cycle)
    dry_run = false
    local log = dry_log
    dry_log = nil
    if not ok then qerror(tostring(err)) end
    print('military-uniforms: DRY RUN -- nothing was changed.')
    for _, line in ipairs(log) do print(line) end
    return
end
if args[1] == 'release-unobtainable' then
    -- A HAND-PICKED specific item (spec.item set, every filter -1) is normally untouchable:
    -- it is the player's explicit choice. But when the named item can never arrive -- it no
    -- longer exists, it is another dwarf's property or on their back, or it is locked into a
    -- display case / weapon trap -- that slot shows red forever and the service is forbidden
    -- from helping. This converts exactly those specs into ordinary managed FILTER specs for
    -- the same kind of item, so the slot goes back into rotation and gets pinned or forged.
    -- Nothing else about the uniform is touched.
    load_state()
    local dry = args[2] == 'dry'
    local fort = df.global.plotinfo.group_id
    local n = 0
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                local hf = pos.occupant >= 0 and df.historical_figure.find(pos.occupant)
                local u = hf and df.unit.find(hf.unit_id)
                if u then
                    for slot = 0, 6 do
                        local v = pos.equipment.uniform[slot]
                        for j = 0, #v - 1 do
                            local spec = v[j]
                            if spec.item >= 0 and spec.item_type < 0 then
                                local it = df.item.find(spec.item)
                                local why
                                if not it then why = 'item no longer exists'
                                elseif it.flags.in_building then why = 'locked in a building (display case / trap)'
                                else
                                    local ow = it.flags.owned and dfhack.items.getOwner(it) or nil
                                    local h = dfhack.items.getHolderUnit(it)
                                    if ow and ow.id ~= u.id then
                                        why = 'owned by ' .. dfhack.units.getReadableName(ow)
                                    elseif h and h.id ~= u.id then
                                        why = 'carried by ' .. dfhack.units.getReadableName(h)
                                    end
                                end
                                if why then
                                    n = n + 1
                                    print(('  %s: %s -- %s'):format(
                                        dfhack.units.getReadableName(u):sub(1, 30),
                                        it and dfhack.items.getDescription(it, 0, true) or ('#' .. spec.item),
                                        why))
                                    if not dry then
                                        -- rebuild it as a managed filter for the same KIND of
                                        -- thing: same item type + subtype, and the material
                                        -- CLASS if it is one we manage (a leather cloak stays
                                        -- "any leather cloak"), else that exact material.
                                        spec.item = -1
                                        if it then
                                            spec.item_type, spec.item_subtype = it:getType(), it:getSubtype()
                                            local mt, mi = item_matpair(it)
                                            if mt == -1 then
                                                spec.mattype, spec.matindex = -1, -1
                                                spec.material_class = mi
                                            else
                                                spec.mattype, spec.matindex = mt, mi
                                                spec.material_class = -1
                                            end
                                            local f = UPDATE_FIELD[spec.item_type]
                                            if f then df.global.plotinfo.equipment.update[f] = true end
                                        else
                                            v:erase(j)   -- nothing left to describe: drop it
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if n == 0 then
        print('military-uniforms: no unobtainable hand-picked items found.')
    elseif dry then
        print(('military-uniforms: DRY RUN -- %d hand-picked slot(s) would be handed back to the service.'):format(n))
    else
        print(('military-uniforms: %d hand-picked slot(s) released to the service.'):format(n))
        run_cycle()
    end
    return
end
if args[1] == 'unpin' then
    -- hand every managed slot back to DF's own equipment solver (leaves hand-picked
    -- specific items alone). The service re-pins on its next cycle unless it is off.
    load_state()
    local n = release_all_pins()
    print(('military-uniforms: released %d pinned uniform slot%s.'):format(n, n == 1 and '' or 's'))
    return
end
if args[1] == 'altsched' then
    -- `altsched once` (used by magnus-scripts lovely): only set up if the routines don't
    -- exist yet, so hand-edited schedules on an already-initialized fort survive every
    -- session. Bare `altsched` = force re-apply (e.g. after adding squads).
    if args[2] == 'once' then
        local routines = df.global.plotinfo.alerts.routines
        for i = 0, #routines - 1 do
            if routines[i].name == 'even month' then
                print('military-uniforms: alt schedules already set up (skipped -- run `military-uniforms altsched` to re-apply).')
                return
            end
        end
    end
    local n, eidx, oidx = setup_alt_schedules()
    print(('military-uniforms: "even month" (idx %d) + "odd month" (idx %d) schedules ready on %d fort squads.'):format(eidx, oidx, n))
    print('  even month = train even months / Ready odd;  odd month = train odd months / Ready even.')
    print('  Assign squads to them on the Schedule screen. Re-run after adding new squads.')
    return
end

local made, deleted = create_steel_uniforms()
print(('military-uniforms: created %d steel uniform templates:'):format(#made))
for _, n in ipairs(made) do print('  + ' .. n) end
if #deleted > 0 then
    print(('  deleted %d default metal uniform%s:'):format(#deleted, #deleted == 1 and '' or 's'))
    for _, n in ipairs(deleted) do print('    - ' .. n) end
end

-- The gear service defaults ON. The heartbeat normally starts on map load via
-- onStateChange, but that already fired before this module loaded (e.g. when run from
-- magnus-scripts), so start it here too if the service is on. Persist the resolved state
-- (so the default sticks) -- a fort where you turned it OFF stays off (load_state only
-- defaults when unset).
load_state()
save_state()
if service_on() then
    start_heartbeat()
    print('  gear service ON (pins each soldier\'s gear, forges the rest), running daily.')
else
    print('  gear service is OFF (enable on the Equip screen with Shift-G).')
end
