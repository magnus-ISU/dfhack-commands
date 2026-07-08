-- Create steel military uniform templates, one per typical weapon type.
--@module = true
--@enable = true
--[[
    military-uniforms            create/refresh the steel uniform set
    military-uniforms orders     queue gear orders for outfitted soldiers, once
    enable military-uniforms     background: queue gear orders as soldiers are
                                 assigned (steel) uniforms
    disable military-uniforms    stop the background order service

Creates a "<Metal> - <weapon>" uniform template on the fort entity for each of the
typical weapons (short sword, war hammer, battle axe, spear, pick, mace,
crossbow). Each is the full metal set -- breastplate + mail shirt, helm,
gauntlets, greaves, high boots, and a shield -- plus a weapon of
that type, with "replace clothing" on. Exceptions: the crossbow uniform uses a
COPPER crossbow + buckler; the war hammer uniform uses a SILVER war hammer.

Gauntlets and high boots are worn as pairs, so the service targets TWO of each
per soldier. Gauntlets are HANDED: it requires one masterwork of EACH hand (left
and right), not just any two. High boots have no handedness, so any two masterwork
count. It melts inferior/surplus copies and reforges (in pairs) until each soldier
has 1 masterwork left gauntlet, 1 masterwork right gauntlet, and 2 masterwork boots.

SIZED PER WEARER: gear is sized to each soldier's RACE. Non-dwarf soldiers (e.g. a human
mercenary) need bigger armor, so for them the manager order sets specdata.race = their race
and the forge makes their size (the finished item records it in maker_race). Requirements
and stock are tracked per size, so dwarf-sized armor never counts as covering a human (or
vice-versa), and each soldier -- and their iron/copper backups -- is geared to fit.

BACKUP GEAR STOCK: the uniform is NEVER edited -- soldiers keep their steel uniform and
pick what to wear themselves. Gear is made in the uniform's metal (steel). But whenever
the soldiers don't have enough wearable/usable pieces for a slot (desired steel + backup
stock < the number who need it), the service also stocks a BACKUP version of that piece
-- armour, shield, AND weapon -- so nobody is left without something to equip. The backup
metal is IRON when there's iron to spare after the steel we still owe (iron ore + iron
bars - iron for the outstanding steel > 0), else COPPER; iron gear is far better, and
picking iron also replaces copper backups. NOT gated on steel supply -- copper/iron fills
the gap while steel forges; it stops once steel + backup covers everyone. (Uniform-copper
pieces like the crossbow are skipped -- the main loop makes those.)

Everything is resolved generically per world: STEEL/COPPER/SILVER by inorganic
id, and every item subtype by name within the fort civ's producible lists (so it
picks the dwarf-makeable breastplate, not a modded look-alike). Re-running
refreshes the "Steel - *" templates it owns (it won't touch your own uniforms).

The Equip screen overlay (dwarfmode/Squads/Equipment/Default) has four toggles. Queue gear
orders, Upgrade to masterwork, and Forge Steel Picks show "Done" (instead of "On") once
there is nothing left to do (every soldier fully equipped / everything masterwork / every
miner has a masterwork steel pick).
  Queue gear orders (Shift-G)      forges one soldier's set at a time PER METAL (so
                                   steel finishes one soldier's set while silver can
                                   progress another), one unit per gear piece, keeps 3
                                   bars of each metal in reserve for moods, serves
                                   dwarves in the "Military" work detail first, and
                                   stocks BACKUP gear (armour + weapon; IRON if there's
                                   iron to spare after steel, else COPPER) for any soldier
                                   who lacks a piece (steel + backup < need)
  Upgrade to masterwork (Shift-M)  upgrades EVERY soldier's pieces in parallel (not one
                                   soldier at a time -- so soldier 2's shield isn't blocked
                                   behind soldier 1's hard-to-masterwork piece), and melts
                                   enough surplus inferior copies each cycle to cover the
                                   masterwork shortfall (out of bars -> recycle the extras),
                                   clearing forbid so they actually melt

A masterwork only counts toward the goal if it is UNDAMAGED (wear 0) and NOT on display -- a
worn masterwork has lost its edge, and a piece locked in a display case/pedestal can never be
equipped -- so neither is treated as "done" (and displayed pieces are never melted). Whenever a
better piece than what's in use becomes available (a fresh masterwork, or just any higher-quality
item), the service flags DF to re-run equipment assignment for that slot, so soldiers swap UP to
it -- fired only when a new, better piece actually appears, so there's no equip churn.
  Forge Steel Picks (Shift-P)      OFF by default. Keeps one steel pick per miner (dwarves
                                   with the Mining labor) in stock, forged one at a time,
                                   respecting the bar reserve. Honours Upgrade to masterwork
                                   (targets a masterwork pick each). Out of steel bars, it
                                   recycles surplus steel gear into bars to make the picks.
                                   When complete, FORBIDS every other (non-steel) pickaxe in
                                   the fort so miners switch to the steel ones.
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

-- how many metal (mattype 0) bars of each inorganic index the fort has on hand
local function metal_bar_counts()
    local c = {}
    for _, it in ipairs(df.global.world.items.all) do
        if it:getType() == df.item_type.BAR and it:getMaterial() == 0 and not it.flags.melt then
            local mi = it:getMaterialIndex()
            c[mi] = (c[mi] or 0) + 1
        end
    end
    return c
end

-- pick the metal to actually use: the preferred one if any of its bars are on hand,
-- else COPPER if copper bars are on hand (the requested fallback), else the preferred
-- one anyway (nothing on hand yet -> keep the aspiration rather than force copper).
-- Availability = "bars on hand right now" (per the chosen definition).
local function resolve_metal(pref, copper, counts)
    if pref and (counts[pref] or 0) > 0 then return pref end
    if copper and (counts[copper] or 0) > 0 then return copper end
    return pref or copper
end

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
    -- wears out, so the service replaces a damaged one and the dwarf re-equips it (see the tally).
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
    local wmat = resolve_metal(inorganic_idx(spec.wmat or 'STEEL') or steel,
                               inorganic_idx('COPPER'), metal_bar_counts())
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

-- give every military soldier a leather cloak WITHOUT re-assigning uniforms: add it (slot 0) to
-- the owned "Steel - *" templates AND to each fort squad position's resolved uniform. Idempotent
-- and self-healing (re-adds if DF re-derives a position from its template). The civilian uniform
-- is skipped (it has no cloak).
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
    local fort = df.global.plotinfo.group_id
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                if pos.occupant >= 0 then
                    local v = pos.equipment.uniform[0]
                    local has = false
                    for j = 0, #v - 1 do
                        if v[j].item_type == df.item_type.ARMOR and v[j].item_subtype == sub then
                            has = true; break
                        end
                    end
                    if not has then
                        local spec = df.squad_uniform_spec:new()
                        spec.item = -1
                        spec.item_type = df.item_type.ARMOR
                        spec.item_subtype = sub
                        spec.material_class = df.entity_material_category.Leather
                        spec.mattype, spec.matindex, spec.color = -1, -1, -1
                        v:insert('#', spec)
                    end
                end
            end
        end
    end
end

-- resolve the regular-shield subtype (not a buckler) once
local shield_sub_cache
local function shield_subtype(ent)
    if shield_sub_cache == nil then
        shield_sub_cache = resolve_sub(df.global.world.raws.itemdefs.shields,
                                       setof(ent.resources.shield_type), 'shield') or false
    end
    return shield_sub_cache or nil
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
    local copper = inorganic_idx('COPPER')
    local counts = metal_bar_counts()
    -- steel unless there are no steel bars on hand and copper bars are (fall back to copper)
    local armour = resolve_metal(steel, copper, counts)
    remove_owned(ent)
    local made = {}
    for _, spec in ipairs(GROUP) do
        local wmat = resolve_metal(inorganic_idx(spec.wmat or 'STEEL') or steel, copper, counts)
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

-- ---- order service: queue the gear each squad soldier's uniform requires -----

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local GLOBAL_KEY = 'military-uniforms'
local DAY_TICKS = 1200
local BARS_PER_ITEM = 1   -- metal gear (armour/weapon) = ~1 bar each
local RESERVE_BARS = 3    -- keep this many bars of each metal free (moods / other jobs)
local BREEDER_MALES = 2   -- adult male dogs kept untrained for breeding

-- weapon subtype for the mining pick (ITEM_WEAPON_PICK), resolved per world
local function pick_subtype()
    local w = df.global.world.raws.itemdefs.weapons
    for i = 0, #w - 1 do if w[i].id == 'ITEM_WEAPON_PICK' then return i end end
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

-- item_type -> the plotinfo.equipment.update dirty-flag field that makes DF re-run assignment
-- for that slot (so soldiers swap up to a better piece when one becomes available)
local UPDATE_FIELD = {
    [df.item_type.ARMOR]  = 'armor',
    [df.item_type.HELM]   = 'helm',
    [df.item_type.PANTS]  = 'pants',
    [df.item_type.GLOVES] = 'gloves',
    [df.item_type.SHOES]  = 'shoes',
    [df.item_type.SHIELD] = 'shield',
    [df.item_type.WEAPON] = 'weapon',
}

-- gauntlets and high boots are worn as PAIRS, so a soldier needs 2 of each (a
-- uniform slot lists them once). They're forged a pair at a time, but each item's
-- quality is independent, so a "pair" can be one masterwork + one not.
local PAIR_TYPES = {[df.item_type.GLOVES] = true, [df.item_type.SHOES] = true}
local function slot_qty(item_type) return PAIR_TYPES[item_type] and 2 or 1 end

-- GAUNTLETS are HANDED (left/right, via the item's `handedness` bitarray): a soldier
-- needs 1 masterwork of EACH hand (not just any 2). HIGH BOOTS have no handedness
-- field, so they just need 2 masterwork of any hand. Only gloves are handed.
local HANDED = {[df.item_type.GLOVES] = true}
-- which hand an item is (0 or 1); handedness bit 1 = one hand, bit 0/none = the other
local function item_hand(it)
    local ok, h = pcall(function() return it.handedness end)
    if ok and h and h[1] then return 1 end
    return 0
end

-- ARMOR/GEAR MUST BE SIZED TO THE WEARER. A dwarf fort forges non-dwarf-sized armor by setting a
-- manager order's specdata.race; the finished item records that size in its maker_race.
--
-- SIZING POLICY (per request):
--   * HYENA-MAN is a universal size -- its wearer sits between dwarves (6000) and humans (7000),
--     so hyena-man armor fits BOTH. We MAKE hyena-man armor for dwarves (slightly better than
--     dwarf-sized, and it cross-fits), and dwarves ACCEPT either hyena-man OR dwarf-sized.
--   * Humans MAKE and accept human-sized armor.
--   * MASTERWORK target = the make size: a dwarf's target is hyena-man (a dwarf-sized masterwork
--     doesn't satisfy it, so it gets upgraded to hyena-man); a human's is human.
-- (Simplification: humans do not count a hyena-sized piece toward basic coverage -- only
--  human-sized -- since fully sharing the hyena pool would need a bigger allocation rewrite and
--  the impact is nil: humans get human armor made for them.)
local function civ_race() return df.global.plotinfo.race_id end
-- SHIELDS and WEAPONS are HELD, not worn -- one size fits all, so they are never sized per wearer;
-- they always key to civ size on both the requirement and stock sides.
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

-- the size race to MAKE armor for a wearer of `race`: hyena-man for dwarves, else the wearer's
-- own race. Sizeless gear is always civ size. This is the req/order key size.
local function make_race(item_type, race)
    if SIZELESS[item_type] then return civ_race() end
    local h = hyena_race()
    if h and race == civ_race() then return h end   -- dwarf -> hyena-man
    return race
end
local function key_race(item_type, race) return make_race(item_type, race) end

-- which req-key size an item's ACTUAL size satisfies for basic coverage: a hyena- OR dwarf-sized
-- piece both cover the dwarf (hyena) key; anything else keys to its own maker race. Sizeless ->
-- civ. This is where "dwarves accept dwarf-sized OR hyena-man" lives.
local function item_size_race(it)
    if SIZELESS[it:getType()] then return civ_race() end
    local ok, r = pcall(function() return it.maker_race end)
    local m = (ok and r and r >= 0) and r or civ_race()
    local h = hyena_race()
    if h and (m == civ_race() or m == h) then return h end   -- dwarf/hyena-sized -> hyena key
    return m
end
-- is this item ALREADY the MAKE size for its key? Only make-size pieces count toward the
-- MASTERWORK target (so a dwarf-sized masterwork does not satisfy a dwarf -> it upgrades to
-- hyena-man). Sizeless items are always "make size".
local function item_is_makesize(it)
    if SIZELESS[it:getType()] then return true end
    local ok, r = pcall(function() return it.maker_race end)
    local m = (ok and r and r >= 0) and r or civ_race()
    return m == item_size_race(it)
end
-- the race the soldier occupying a squad position is (for sizing their gear)
local function occupant_race(pos)
    local hf = pos.occupant >= 0 and df.historical_figure.find(pos.occupant)
    local u = hf and df.unit.find(hf.unit_id)
    return (u and u.race) or civ_race()
end

-- ---- non-metal materials (wood shields, leather cloaks/armour, bone greaves) ----------------
-- A gear material in our keys/orders is a (mat_type, mat_index) pair: a METAL is (0, inorganic
-- idx) as before; a WOOD / LEATHER / BONE piece is (-1, entity_material_category). MATCLASS maps
-- that category to the manager-order material_category field (to MAKE it) and the material_flags
-- bit (to DETECT it in stock).
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
-- the (mat_type, mat_index) key pair for a UNIFORM item's material spec: a specific material
-- (mattype>=0, e.g. steel) stays; a material CLASS (material_class>=0) becomes (-1, category).
-- Returns nil if the spec has neither (a bare "any material" slot we don't manage).
local function uniform_matpair(it)
    if it.mattype >= 0 then return it.mattype, it.matindex end
    if it.material_class >= 0 and MATCLASS[it.material_class] then return -1, it.material_class end
    return nil
end

-- tally what every assigned squad soldier's uniform asks for, by exact item +
-- material (so copper armour + iron sword each get their own order):
-- "type/sub/mt/mi" -> {item_type, subtype, mat_type, mat_index, count}
local function compute_required()
    local fort = df.global.plotinfo.group_id
    local req = {}
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                if pos.occupant >= 0 then
                    local srace = occupant_race(pos)   -- size this soldier's gear to their race
                    for slot = 0, 6 do
                        local v = pos.equipment.uniform[slot]
                        for j = 0, #v - 1 do
                            local it = v[j]
                            -- squad_uniform_spec uses mattype/matindex (metal) OR material_class
                            local mt, mi = uniform_matpair(it)
                            if MAKE_JOB[it.item_type] and it.item_subtype >= 0 and mt then
                                local krace = key_race(it.item_type, srace)   -- civ for shields/weapons
                                local key = ('%d/%d/%d/%d/%d'):format(it.item_type, it.item_subtype,
                                                                      mt, mi, krace)
                                local r = req[key]
                                if not r then
                                    r = {item_type = it.item_type, subtype = it.item_subtype,
                                         mat_type = mt, mat_index = mi,
                                         size_race = krace, count = 0}
                                    req[key] = r
                                end
                                r.count = r.count + slot_qty(it.item_type)
                            end
                        end
                    end
                end
            end
        end
    end
    return req
end

-- unit ids in the "Military" work detail (the fort's active standing military, per
-- military-labor). Empty if there's no such detail.
local function military_labor_set()
    local wd = df.global.plotinfo.labor_info.work_details
    for i = 0, #wd - 1 do
        if wd[i].name == 'Military' then
            local set = {}
            for _, id in ipairs(wd[i].assigned_units) do set[id] = true end
            return set
        end
    end
    return {}
end

-- squad ids DFHack's autotraining tool is currently driving (active only), read from its
-- persisted site data (keys are stored as strings, so coerce back to numbers). Matches how
-- military-labor / dwarf-rts read it. Non-leader members of these are only rostered to train,
-- not real soldiers, so we deprioritise their gear like a civilian's.
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

-- a squad position wearing a "Civilian - *" uniform: no metal breastplate / mail shirt in the
-- body slot (leather body armour instead). Same marker military-labor uses -- DFHack exposes no
-- squad->uniform-template link, so we can't read the name.
local function position_is_civilian(pos)
    local has_armor, has_metal = false, false
    local body = pos.equipment.uniform[0]
    for j = 0, #body - 1 do
        if body[j].item_type == df.item_type.ARMOR then
            has_armor = true
            if body[j].mattype == 0 then has_metal = true end
        end
    end
    return has_armor and not has_metal
end

-- index of the "Ready" routine in the fort's schedule list (what a squad's cur_routine_idx points
-- into), or nil if there's no routine by that name. Off-duty is index 0; "Ready" is the standard
-- station-and-train routine, so once a civilian militia is fully equipped we switch it on.
local function ready_routine_idx()
    local routines = df.global.plotinfo.alerts.routines
    for i = 0, #routines - 1 do
        if routines[i].name == 'Ready' then return i end
    end
end

-- ordered list of soldiers, each -> {unit_id, sid, civilian, needs = {{k=gearkey, hand=..}, ...}}
-- for the makeable pieces their uniform specifies. Ordered MILITARY first (Military-detail
-- members, then other military, in squad order), then CIVILIAN-uniform soldiers LAST -- so a
-- civilian's gear is only queued after every military dwarf already has theirs.
local function compute_per_soldier()
    local fort = df.global.plotinfo.group_id
    local mil = military_labor_set()
    local training = autotraining_squads()
    local prioritized, rest, civ = {}, {}, {}
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local pos = sq.positions[p]
                if pos.occupant >= 0 then
                    local hf = df.historical_figure.find(pos.occupant)
                    local uid = hf and hf.unit_id or -1
                    local srace = occupant_race(pos)
                    local needs = {}
                    for slot = 0, 6 do
                        local v = pos.equipment.uniform[slot]
                        for j = 0, #v - 1 do
                            local it = v[j]
                            local mt, mi = uniform_matpair(it)
                            if MAKE_JOB[it.item_type] and it.item_subtype >= 0 and mt then
                                local k = ('%d/%d/%d/%d/%d'):format(it.item_type, it.item_subtype,
                                    mt, mi, key_race(it.item_type, srace))
                                if HANDED[it.item_type] then           -- gauntlets: one of each hand
                                    needs[#needs + 1] = {k = k, hand = 0}
                                    needs[#needs + 1] = {k = k, hand = 1}
                                else                                    -- boots (x2) / everything (x1)
                                    for _ = 1, slot_qty(it.item_type) do needs[#needs + 1] = {k = k} end
                                end
                            end
                        end
                    end
                    if #needs > 0 then
                        -- civilian for gear purposes = a Civilian-* uniform OR a non-leader member of
                        -- an autotraining squad (only rostered to train; the leader stays a soldier).
                        local civilian = position_is_civilian(pos) or (training[sq.id] and p ~= 0)
                        local entry = {unit_id = uid, sid = sq.id, civilian = civilian, needs = needs}
                        if civilian then civ[#civ + 1] = entry
                        elseif mil[uid] then prioritized[#prioritized + 1] = entry
                        else rest[#rest + 1] = entry end
                    end
                end
            end
        end
    end
    for _, e in ipairs(rest) do prioritized[#prioritized + 1] = e end   -- military detail, then rest military
    for _, e in ipairs(civ) do prioritized[#prioritized + 1] = e end    -- ...then civilians LAST
    return prioritized
end

local function barkey(mt, mi) return mt .. '/' .. mi end

-- df.global.world.items.all also lists items the fort doesn't possess -- e.g. named
-- artifacts and gear carried by offsite historical figures (UNIT_HOLDER to a unit
-- not loaded here, or a non-civ unit). Those would inflate our stock counts and
-- make us under-produce, so a "fort stock" item is one with no unit holder
-- (stockpile/building/ground) OR held by one of our own loaded dwarves.
local function not_fort_stock(it)
    for _, r in ipairs(it.general_refs) do
        if r:getType() == df.general_ref_type.UNIT_HOLDER then
            local u = df.unit.find(r.unit_id)
            return not (u and dfhack.units.isOwnCiv(u))
        end
    end
    return false
end

-- is this item in a unit's inventory (worn / wielded / carried)? An equipped piece can't
-- be melted -- the melt job never fires -- so it must never be a melt candidate, even though
-- it still counts as owned stock. (Any UNIT_HOLDER = someone has it; offsite/enemy holders
-- are already filtered out by not_fort_stock before this is checked.)
local function item_equipped(it)
    for _, r in ipairs(it.general_refs) do
        if r:getType() == df.general_ref_type.UNIT_HOLDER then return true end
    end
    return false
end

-- is this item built into a building? Such a piece can never be equipped by a soldier, so it
-- must NOT count as available gear (nor be a melt candidate). This covers two cases that would
-- otherwise inflate stock and mask a real shortage:
--   * a weapon locked in a weapon TRAP -- a fort can have dozens (e.g. 88 silver war hammers,
--     60+ spears in traps here), none of them equippable;
--   * a piece on DISPLAY in a case / pedestal (the player put it there on purpose).
-- flags.in_building is set for exactly these built-in items -- verified on this fort that every
-- in-building gear piece is a trap or display component, never loose/equippable stock.
local function item_installed(it)
    return it.flags.in_building
end

-- locate one of our tracked manager orders by id
local function order_by_id(id)
    local mo = df.global.world.manager_orders
    for i = 0, #mo.all - 1 do if mo.all[i].id == id then return mo.all[i], i end end
end

-- delete the order we track for `key`, if it still exists
local function drop_order(key)
    local id = state.orders[key]
    if not id then return end
    local o, idx = order_by_id(id)
    if o then df.global.world.manager_orders.all:erase(idx); o:delete() end
    state.orders[key] = nil
end

-- DF makes the items of any order whose amount_left>0 the moment it's submitted,
-- WITHOUT checking conditions (conditions only decide whether to re-fire an
-- already-completed order), and it never re-arms an order sitting at amount_left=0.
-- So leaning on DF's repeat always force-produces at least one unit you may not
-- need. Instead we self-manage: run_cycle decides WHICH gear key to make (one
-- soldier's set at a time, honouring the bar reserve) and calls this to create or
-- re-arm exactly ONE unit for that key; drop_order removes a key once it's covered.
local function queue_one(key, r)
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
        o.frequency = df.workquota_frequency_type.OneTime  -- one unit, no DF auto-repeat
        o.amount_total, o.amount_left = 1, 1
        o.status.validated, o.status.active = true, true
        mo.all:insert(0, o)
        state.orders[key] = o.id
    elseif o.amount_left < 1 then
        o.amount_total, o.amount_left = 1, 1     -- last unit forged, still short: one more
        o.status.active = true
    end
    -- else: a unit is queued and not yet forged -- leave it (one at a time)
end

local function item_wear(it)
    local ok, w = pcall(function() return it.wear end)
    return (ok and w) or 0
end

-- mark an item for melting, clearing forbid so it can actually be hauled + melted. NEVER melt a
-- masterwork or artifact -- their quality/value is irreplaceable. (The callers already filter to
-- inferior copies, but guard here too so no future path can ever melt one.)
local function mark_melt(it)
    if it.flags.artifact or it:getQuality() >= df.item_quality.Masterful then return false end
    it.flags.forbid = false
    return dfhack.items.markForMelting(it)
end

-- Masterwork recycling: to re-forge a masterwork we must recycle an inferior copy into
-- metal -- but NEVER below the count needed to keep every soldier geared. So per material,
-- for the masterwork pieces we still owe (bars + in-flight melts not yet covering them), we
-- melt enough surplus inferior copies THIS cycle to cover the shortfall (worst first:
-- most-damaged, then lowest quality, never masterwork/artifact), only from item types with
-- more than `need` equippable copies -- so soldiers keep a full set while we recycle the
-- extras into bars for re-forging. `extra_short` adds non-gear steel demand (miner picks).
local function melt_for_masterwork(req, mwstock, mwstock_h, stock, bars, extra_short, basic_done)
    local short, inbound, cands = {}, {}, {}
    if state.masterwork then     -- gear masterwork shortfall (only when upgrading is on)
        for key, r in pairs(req) do
            if not basic_done or basic_done[key] then   -- only recycle for a key past its basic set
            local mk = barkey(r.mat_type, r.mat_index)
            local owed
            if HANDED[r.item_type] then
                -- gauntlets: need one masterwork of EACH hand per soldier. r.count is 2 per
                -- soldier (a pair), so soldiers-needing = count/2 = the per-hand target.
                local perhand = r.count / 2
                local h = mwstock_h[key] or {}
                owed = math.max(0, perhand - (h[0] or 0)) + math.max(0, perhand - (h[1] or 0))
            else
                owed = math.max(0, r.count - (mwstock[key] or 0))
            end
            short[mk] = (short[mk] or 0) + owed
            end
        end
    end
    for mk, n in pairs(extra_short or {}) do short[mk] = (short[mk] or 0) + n end
    for mk, b in pairs(bars) do inbound[mk] = b end
    for _, it in ipairs(df.global.world.items.all) do
        if not_fort_stock(it) then goto next_item end
        local key = ('%d/%d/%d/%d/%d'):format(it:getType(), it:getSubtype(), it:getMaterial(),
                                              it:getMaterialIndex(), item_size_race(it))
        if req[key] then
            local mk = barkey(it:getMaterial(), it:getMaterialIndex())
            if it.flags.melt then
                if item_equipped(it) then
                    -- a worn piece marked for melt is STUCK (the melt job never fires while
                    -- it's equipped) -- un-designate it so it stops blocking, and don't count
                    -- it as inbound metal
                    dfhack.items.cancelMelting(it)
                elseif not it.flags.forbid then
                    -- metal already on the way -- but a FORBIDDEN marked item can't be hauled
                    -- to a smelter, so it never yields a bar; don't let it throttle marking
                    inbound[mk] = (inbound[mk] or 0) + 1
                end
            elseif it:getQuality() < df.item_quality.Masterful
                and not it.flags.artifact
                and not item_equipped(it)                     -- a worn piece can't be melted
                and not item_installed(it)                    -- never melt a trapped/displayed piece
                and dfhack.items.canMelt(it)
                and (stock[key] or 0) > req[key].count        -- surplus only: keep a full set
            then
                cands[mk] = cands[mk] or {}
                cands[mk][#cands[mk] + 1] = it
            end
        end
        ::next_item::
    end
    local marked = 0
    for mk, owed in pairs(short) do
        local list = cands[mk]
        local deficit = owed - (inbound[mk] or 0)             -- bars still needed for the shortfall
        if deficit > 0 and list and #list > 0 then
            table.sort(list, function(a, b)
                local wa, wb = item_wear(a), item_wear(b)
                if wa ~= wb then return wa > wb end            -- most-damaged first
                return a:getQuality() < b:getQuality()          -- then lowest quality
            end)
            for i = 1, math.min(deficit, #list) do              -- melt enough to cover it now
                if mark_melt(list[i]) then marked = marked + 1 end
            end
        end
    end
    return marked
end

-- A leather-category supply order (backpack / waterskin) tracked like a gear
-- order: queue ONE while soldiers lack the item and a tanned hide is on hand;
-- delete it once everyone is covered. (A waterskin is just a leather FLASK.)
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

-- ---- enable state: toggles, persisted ---------------------------------------

state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.queue == nil then state.queue = true end       -- gear queueing defaults ON
        if state.masterwork == nil then state.masterwork = false end
        if state.wardogs == nil then state.wardogs = false end
        if state.pickaxes == nil then state.pickaxes = false end -- miner steel picks default OFF
        if not state.orders then state.orders = {} end
        if not state.best_q then state.best_q = {} end           -- best avail quality per gear key
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

function isEnabled() return load_state().queue end

-- any background service on? (gear queueing, war-dog training, or miner pickaxes)
local function service_on() load_state(); return state.queue or state.wardogs or state.pickaxes end

-- item types that get a copper BACKUP piece stocked when soldiers lack a wearable/usable
-- one (a copper version is stocked so they can equip something instead of going naked or
-- unarmed; the uniform itself is never touched). Armour, shield, AND weapon -- a copper
-- weapon beats an empty hand. Pieces the uniform already specifies as copper are skipped.
local BACKUP_TYPES = {
    [df.item_type.ARMOR] = true, [df.item_type.HELM] = true, [df.item_type.PANTS] = true,
    [df.item_type.GLOVES] = true, [df.item_type.SHOES] = true, [df.item_type.SHIELD] = true,
    [df.item_type.WEAPON] = true,
}

-- inorganic indices whose ore smelts to IRON (hematite/magnetite/limonite). Cached per
-- world (raws are static), rebuilt if the iron index differs (different world).
local iron_ore_cache
local function iron_ore_set(iron_idx)
    if iron_ore_cache and iron_ore_cache.iron == iron_idx then return iron_ore_cache.set end
    local set = {}
    if iron_idx then
        local i = 0
        while df.inorganic_raw.find(i) do
            local mo = df.inorganic_raw.find(i).metal_ore
            if mo then
                for _, m in ipairs(mo.mat_index) do
                    if m == iron_idx then set[i] = true; break end
                end
            end
            i = i + 1
        end
    end
    iron_ore_cache = {iron = iron_idx, set = set}
    return set
end

-- fort citizens with the Mining labor enabled (the dwarves who dig)
local function miners()
    local out = {}
    for _, u in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(u) and dfhack.units.isActive(u) and not dfhack.units.isDead(u) then
            local ok, has = pcall(function() return u.status.labors[df.unit_labor.MINE] end)
            if ok and has then out[#out + 1] = u end
        end
    end
    return out
end

-- Equip miners with steel pickaxes: keep one steel pick per miner in stock, forged one
-- at a time (respecting the steel reserve + whatever soldier gear has committed). When
-- "Upgrade to masterwork" is on, the target is a MASTERWORK pick per miner, and inferior
-- surplus picks are melted to re-forge (same policy as the gear masterwork upgrade).
-- Tracked under the single order key 'pick'. Independent of the gear-queue toggle.
local function equip_miner_pickaxes()
    local steel_idx = inorganic_idx('STEEL')
    local sub = pick_subtype()
    if not steel_idx or not sub then drop_order('pick'); return end
    local need = #miners()
    if need == 0 then drop_order('pick'); return end

    -- tally steel picks (total + masterwork), steel bars, and inferior melt candidates
    local total, mw, steel_bars, melting = 0, 0, 0, 0
    local cands = {}
    for _, it in ipairs(df.global.world.items.all) do
        if not_fort_stock(it) then goto next end
        local t = it:getType()
        if t == df.item_type.BAR and it:getMaterial() == 0 and it:getMaterialIndex() == steel_idx then
            steel_bars = steel_bars + 1
        elseif t == df.item_type.WEAPON and it:getSubtype() == sub
            and it:getMaterial() == 0 and it:getMaterialIndex() == steel_idx then
            if it.flags.melt then
                melting = melting + 1                       -- steel already on the way back
            elseif not item_installed(it) then              -- a trapped/displayed pick isn't usable stock
                total = total + 1
                if it:getQuality() >= df.item_quality.Masterful and it.wear == 0 and not it.flags.artifact then
                    mw = mw + 1                             -- masterwork counts only if undamaged
                elseif dfhack.items.canMelt(it) and not item_equipped(it) then
                    cands[#cands + 1] = it                  -- inferior, meltable, not in-hand
                end
            end
        end
        ::next::
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

    -- forge toward one (masterwork, if enabled) pick per miner, one at a time
    local avail = state.masterwork and mw or total
    local o = state.orders['pick'] and order_by_id(state.orders['pick'])
    local in_flight = o and o.amount_left > 0
    if avail < need and (in_flight or budget >= BARS_PER_ITEM) then
        queue_one('pick', {item_type = df.item_type.WEAPON, subtype = sub,
                           mat_type = 0, mat_index = steel_idx})
    else
        drop_order('pick')
    end

    -- COMPLETE = every miner has a (masterwork, if enabled) steel pick. Record it for the
    -- overlay's "Done" label, and forbid all OTHER pickaxes (any pick that isn't one of our
    -- steel ones) so miners drop them and pick up the steel picks instead.
    local done = avail >= need
    state.done_picks = done
    if done then
        for _, it in ipairs(df.global.world.items.all) do
            if it:getType() == df.item_type.WEAPON and it:getSubtype() == sub
                and not (it:getMaterial() == 0 and it:getMaterialIndex() == steel_idx)
                and not it.flags.forbid
            then it.flags.forbid = true end
        end
    end

    -- masterwork: recycle inferior surplus picks when steel + inbound melts don't cover the
    -- masterwork shortfall (keep at least `need` picks so miners aren't left bare)
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

    -- report how many picks we still need but can't forge from current steel bars, so the
    -- caller can recycle surplus steel GEAR into bars for them (out of bars -> melt extras)
    return math.max(0, (need - avail) - math.max(0, budget))
end

local function run_cycle()
    if not dfhack.world.isFortressMode() then return end
    load_state()
    if state.wardogs then train_surplus_war_dogs(); assign_war_dogs() end
    local pick_short = state.pickaxes and equip_miner_pickaxes() or 0
    if not state.queue then return end
    local ent = fort_entity()
    if ent then ensure_cloaks(ent) end   -- every soldier carries a leather cloak (templates + positions)
    local copper_idx = inorganic_idx('COPPER')
    local iron_idx, pig_idx, steel_idx = inorganic_idx('IRON'), inorganic_idx('PIG_IRON'), inorganic_idx('STEEL')
    local iron_ores = iron_ore_set(iron_idx)
    local req = compute_required()
    -- armour pieces soldiers need, indexed by "item_type/subtype" (for copper backup)
    local backup_by_ts = {}
    for key, r in pairs(req) do
        if BACKUP_TYPES[r.item_type] then
            backup_by_ts[r.item_type .. '/' .. r.subtype .. '/' .. r.size_race] = key
        end
    end
    -- one pass over items: tally gear stock (total + masterwork) by item key, bar
    -- stock by material, and the leather-supply counts. Items already flagged for
    -- melting don't count (they're being recycled).
    local stock, mwstock, bars = {}, {}, {}
    local shields_by_sub = {}     -- wearable shields per subtype, ANY material (for the stand-in)
    -- best AVAILABLE (unassigned, wearable) quality per gear key -> drives the upgrade re-equip
    local availq = {}
    -- hand-split counts for handed types (gauntlets): stock_h[key][hand], mwstock_h[key][hand]
    local stock_h, mwstock_h = {}, {}
    local bstock = {}            -- bstock[material_index]["type/sub"] = existing iron/copper backup pieces
    local iron_ore_count = 0
    local hides, flasks, backpacks, logs = 0, 0, 0, 0
    for _, it in ipairs(df.global.world.items.all) do
        if not_fort_stock(it) then goto next_item end
        local t = it:getType()
        if t == df.item_type.BAR then
            bars[barkey(it:getMaterial(), it:getMaterialIndex())] = (bars[barkey(it:getMaterial(), it:getMaterialIndex())] or 0) + 1
        elseif t == df.item_type.BOULDER then
            if it:getMaterial() == 0 and iron_ores[it:getMaterialIndex()] then iron_ore_count = iron_ore_count + 1 end
        elseif t == df.item_type.WOOD and not it.flags.melt then
            logs = logs + 1                                  -- for the wood-shield stand-in
        elseif t == df.item_type.SKIN_TANNED then
            hides = hides + 1
        elseif not it.flags.melt and t == df.item_type.FLASK then
            flasks = flasks + 1
        elseif not it.flags.melt and t == df.item_type.BACKPACK then
            backpacks = backpacks + 1
        elseif not it.flags.melt and not item_installed(it) and MAKE_JOB[t] then
            -- (only makeable gear types; an item built into a building -- weapon trap / display
            -- case -- can never be equipped, so it does not count as gear stock)
            if t == df.item_type.SHIELD then
                shields_by_sub[it:getSubtype()] = (shields_by_sub[it:getSubtype()] or 0) + 1
            end
            local mt, mi_ = item_matpair(it)
            local k = ('%d/%d/%d/%d/%d'):format(t, it:getSubtype(), mt, mi_, item_size_race(it))
            -- LEATHER wears out: a damaged (worn) leather piece (cloak / leather armour) does NOT
            -- count as coverage, so the service makes a fresh one and the dwarf re-equips it.
            local leather_worn = mt == -1 and mi_ == df.entity_material_category.Leather and it.wear > 0
            if req[k] and not leather_worn then
                stock[k] = (stock[k] or 0) + 1
                -- track the best quality among UNASSIGNED copies (an equipped piece is already
                -- on a soldier -- it isn't something to upgrade TO)
                if not item_equipped(it) then
                    local q = it:getQuality()
                    if q > (availq[k] or -1) then availq[k] = q end
                end
                local handed = HANDED[t]
                local hand = handed and item_hand(it) or nil
                if handed then
                    stock_h[k] = stock_h[k] or {[0] = 0, [1] = 0}
                    stock_h[k][hand] = stock_h[k][hand] + 1
                end
                -- a masterwork counts toward the goal only if it is UNDAMAGED (wear 0 -- a worn
                -- masterwork has lost its edge) and not an artifact (artifacts never auto-equip
                -- and can't be melted), so we don't treat a degraded/undisplayable piece as done
                if it:getQuality() >= df.item_quality.Masterful
                    and it.wear == 0
                    and item_is_makesize(it)   -- a dwarf-sized masterwork isn't the hyena target
                    and dfhack.items.getGeneralRef(it, df.general_ref_type.IS_ARTIFACT) == nil
                then
                    mwstock[k] = (mwstock[k] or 0) + 1
                    if handed then
                        mwstock_h[k] = mwstock_h[k] or {[0] = 0, [1] = 0}
                        mwstock_h[k][hand] = mwstock_h[k][hand] + 1
                    end
                end
            elseif mt == 0 then
                -- an iron/copper piece of a backup-able type = existing backup stock
                if mi_ == iron_idx or mi_ == copper_idx then
                    local ts = t .. '/' .. it:getSubtype() .. '/' .. item_size_race(it)
                    if backup_by_ts[ts] then
                        bstock[mi_] = bstock[mi_] or {}
                        bstock[mi_][ts] = (bstock[mi_][ts] or 0) + 1
                    end
                end
            end
        end
        ::next_item::
    end

    -- RE-EQUIP ON UPGRADE: when a better piece than what's in use becomes available (a freshly
    -- forged masterwork -- or just any higher-quality item), set DF's per-slot dirty flag so it
    -- re-runs equipment assignment and soldiers swap up. We fire only when the best AVAILABLE
    -- (unassigned) quality for a needed piece RISES above what we last saw for that key, i.e. a
    -- new, better piece was created -- so it's not re-triggered every cycle (no equip churn).
    state.best_q = state.best_q or {}
    local upd = df.global.plotinfo.equipment.update
    local seen_key = {}
    for key, r in pairs(req) do
        seen_key[key] = true
        local cur = availq[key] or -1
        local field = UPDATE_FIELD[r.item_type]
        if field and cur > (state.best_q[key] or -1) then
            upd[field] = true
        end
        state.best_q[key] = cur
    end
    -- drop keys no longer needed, so if that piece is re-created later it re-triggers cleanly
    for key in pairs(state.best_q) do if not seen_key[key] then state.best_q[key] = nil end end

    -- count soldiers (occupied fort squad positions)
    local fort = df.global.plotinfo.group_id
    local soldiers = 0
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do if sq.positions[p].occupant >= 0 then soldiers = soldiers + 1 end end
        end
    end
    -- drop gear orders no longer required (soldier left / uniform changed); leave the
    -- leather-supply orders ("supply/*"), copper-backup orders ("cu/*"), and the miner
    -- pickaxe order ("pick") to their own passes (but drop a cu/ order whose steel base is
    -- gone from req).
    for key in pairs(state.orders) do
        if key:sub(1, 7) == 'supply/' then                                    -- ensure_supply handles it
        elseif key == 'pick' then                                             -- equip_miner_pickaxes handles it
        elseif key == 'shieldstandin' then                                    -- shield stand-in pass handles it
        elseif key:sub(1, 3) == 'cu/' then
            if not req[key:sub(4)] then drop_order(key) end                   -- base steel piece gone
        elseif not req[key] then
            drop_order(key)
        end
    end
    -- BASIC COVERAGE, PER KEY: a key's non-masterwork set is "done" once total stock (masterwork
    -- pieces count -- a masterwork boot is still a boot to wear) covers everyone who wants it. Only
    -- then may that key be UPGRADED to masterwork. This gates masterwork per item, so masterworks
    -- are made only after every unit (military AND civilian) has a plain piece of that item -- and,
    -- because civilians are ordered last for basic equip, only after the military are fully kitted.
    local basic_done = {}
    for key, r in pairs(req) do
        if HANDED[r.item_type] then
            local ph, sh = r.count / 2, stock_h[key] or {}
            basic_done[key] = (sh[0] or 0) >= ph and (sh[1] or 0) >= ph
        else
            basic_done[key] = (stock[key] or 0) >= r.count
        end
    end

    -- ONE SOLDIER AT A TIME, PER METAL: hand current stock to soldiers in order, then
    -- for EACH metal independently forge one soldier at a time. A metal is "claimed" by
    -- the first soldier (in order) still missing a piece of it, and only that soldier's
    -- gaps in that metal are queued -- so e.g. a later soldier's SILVER warhammer still
    -- gets made while STEEL is busy finishing an earlier soldier's set. This still
    -- completes full sets (breastplate included) instead of spreading a metal thin.
    -- A key that is in its MASTERWORK phase (masterwork toggle on AND its basic set done)
    -- draws from the masterwork count instead, and upgrades in parallel.
    -- Handed types (gauntlets) get a per-hand pool so we require one of EACH hand.
    local persoldier = compute_per_soldier()
    local avail, avail_h = {}, {}
    for key, r in pairs(req) do
        local mwph = state.masterwork and basic_done[key]   -- this key is upgrading to masterwork
        if HANDED[r.item_type] then
            local src = mwph and mwstock_h[key] or stock_h[key]
            avail_h[key] = {[0] = src and src[0] or 0, [1] = src and src[1] or 0}
        else
            avail[key] = mwph and (mwstock[key] or 0) or (stock[key] or 0)
        end
    end
    local want = {}          -- gear keys to forge this cycle
    local metal_owner = {}   -- barkey -> index of the soldier that metal is finishing now
    for i, sreq in ipairs(persoldier) do
        for _, need in ipairs(sreq.needs) do
            local k = need.k
            local covered
            if need.hand ~= nil then                              -- gauntlet: this exact hand
                local pool = avail_h[k]
                if pool and pool[need.hand] > 0 then pool[need.hand] = pool[need.hand] - 1; covered = true end
            elseif (avail[k] or 0) > 0 then
                avail[k] = avail[k] - 1; covered = true           -- covered from stock
            end
            if not covered and req[k] then                        -- missing: needs forging
                if state.masterwork and basic_done[k] then
                    -- MASTERWORK UPGRADE: everyone already has a plain piece of this item, so
                    -- upgrade them all in parallel (the bar budget still paces it). Otherwise a
                    -- later soldier's piece (e.g. soldier 2's shield) would be blocked behind
                    -- an earlier soldier's hard-to-masterwork piece forever.
                    want[k] = true
                else
                    -- INITIAL EQUIP: finish ONE soldier's set per metal before the next, so a
                    -- scarce metal completes whole sets instead of spreading thin.
                    local mk = barkey(req[k].mat_type, req[k].mat_index)
                    if metal_owner[mk] == nil then metal_owner[mk] = i end
                    if metal_owner[mk] == i then want[k] = true end
                end
            end
        end
    end

    -- BAR RESERVE: keep RESERVE_BARS of each metal free for moods / other jobs. The
    -- spendable budget is on-hand bars minus the reserve minus what our already-queued
    -- orders will still consume, so we never queue an order that dips a metal below it.
    local committed = {}
    for k, id in pairs(state.orders) do
        if k:sub(1, 7) ~= 'supply/' then
            local o = order_by_id(id)
            if o and o.amount_left > 0 then
                local mk = barkey(o.mat_type, o.mat_index)
                committed[mk] = (committed[mk] or 0) + o.amount_left
            end
        end
    end
    local budget = {}
    for mk, b in pairs(bars) do budget[mk] = b - RESERVE_BARS - (committed[mk] or 0) end

    -- STEEL SHIELDS LAST: a steel shield is only forged once EVERY OTHER requested steel item is
    -- covered (and masterworked, if upgrading) -- i.e. no other steel item is still requested. This
    -- flag defers the steel-shield order below; the wood replacement is queued separately.
    local steel_gear_done = true
    if steel_idx then
        for key, r in pairs(req) do
            if r.mat_type == 0 and r.mat_index == steel_idx and r.item_type ~= df.item_type.SHIELD then
                if HANDED[r.item_type] then
                    local ph = r.count / 2
                    local sh, mh = stock_h[key] or {}, mwstock_h[key] or {}
                    if (sh[0] or 0) < ph or (sh[1] or 0) < ph then steel_gear_done = false end
                    if state.masterwork and ((mh[0] or 0) < ph or (mh[1] or 0) < ph) then steel_gear_done = false end
                else
                    if (stock[key] or 0) < r.count then steel_gear_done = false end
                    if state.masterwork and (mwstock[key] or 0) < r.count then steel_gear_done = false end
                end
            end
        end
    end

    for key, r in pairs(req) do
        local is_steel_shield = r.item_type == df.item_type.SHIELD
            and r.mat_type == 0 and r.mat_index == steel_idx
        local mk = barkey(r.mat_type, r.mat_index)
        local o = state.orders[key] and order_by_id(state.orders[key])
        local in_flight = o and o.amount_left > 0
        local is_metal = r.mat_type == 0        -- wood / leather / bone don't consume metal bars
        if is_steel_shield and not steel_gear_done then
            drop_order(key)    -- steel shields wait until the rest of the steel gear is done
        elseif want[key] and (in_flight or not is_metal or (budget[mk] or 0) >= BARS_PER_ITEM) then
            if is_metal and not in_flight then budget[mk] = (budget[mk] or 0) - BARS_PER_ITEM end
            queue_one(key, r)
        else
            drop_order(key)    -- another soldier's piece, or no bars to spare past the reserve
        end
    end

    -- BACKUP GEAR STOCK (uniform untouched): whenever the soldiers don't have enough
    -- wearable/usable pieces for a slot in the backup metal -- i.e. desired(steel) +
    -- backup-metal stock < the number who need it -- stock a backup version so nobody is
    -- left without something to equip. Armour, shield, AND weapon.
    --
    -- The BACKUP METAL is IRON when there's iron to spare after all the steel we still owe
    -- (iron ore + iron bars - iron to make the outstanding steel > 0), else COPPER -- iron
    -- gear is far better than copper. Coverage counts only the CHOSEN backup metal, so when
    -- iron is picked it also replaces any copper backups (copper stops, iron is made in its
    -- place). Not gated on steel supply; stops once steel + backup covers everyone. One per
    -- type per cycle, respecting that metal's reserve; uniform-copper pieces are skipped.
    local steel_short = 0
    if steel_idx then
        for key, r in pairs(req) do
            if r.mat_type == 0 and r.mat_index == steel_idx then
                steel_short = steel_short + math.max(0, r.count - (stock[key] or 0))
            end
        end
    end
    -- each outstanding steel bar needs 1 iron directly + 1 pig iron (itself 1 iron, unless
    -- pig iron is already on hand)
    local pig_bars = bars[barkey(0, pig_idx or -1)] or 0
    local iron_for_steel = steel_short + math.max(0, steel_short - pig_bars)
    local iron_left = ((bars[barkey(0, iron_idx or -1)] or 0) + iron_ore_count) - iron_for_steel
    local backup_idx = (iron_idx and iron_left > 0) and iron_idx or copper_idx
    if backup_idx then
        local bmk = barkey(0, backup_idx)
        local backup_stock = bstock[backup_idx] or {}
        for key, r in pairs(req) do
            local ts = r.item_type .. '/' .. r.subtype .. '/' .. r.size_race
            local already_backup = r.mat_type == 0 and r.mat_index == backup_idx
            if backup_by_ts[ts] == key and not already_backup then   -- a backup-able piece
                local cukey = 'cu/' .. key
                local covered = (stock[key] or 0) + (backup_stock[ts] or 0)
                local o = state.orders[cukey] and order_by_id(state.orders[cukey])
                if o and (o.mat_type ~= 0 or o.mat_index ~= backup_idx) then
                    drop_order(cukey); o = nil   -- backup metal switched -> remake in the new metal
                end
                local in_flight = o and o.amount_left > 0
                if covered < r.count
                    and (in_flight or (budget[bmk] or 0) >= BARS_PER_ITEM) then
                    if not in_flight then budget[bmk] = (budget[bmk] or 0) - BARS_PER_ITEM end
                    queue_one(cukey, {item_type = r.item_type, subtype = r.subtype,
                                      mat_type = 0, mat_index = backup_idx, size_race = r.size_race})
                else
                    drop_order(cukey)   -- everyone's covered
                end
            end
        end
    end

    -- SHIELD REPLACEMENT: the uniforms are left exactly as written -- military ask for a STEEL
    -- shield, civilians for a WOOD shield. The rule lives entirely in the orders: a STEEL shield
    -- is only forged once NO OTHER steel item is still requested (steel_gear_done; the steel-shield
    -- order is deferred in the main queue above). Otherwise a WOOD shield (or iron/copper) is made
    -- as the replacement so soldiers have something to hold. Shields are sizeless, so we count
    -- EVERY regular shield of the subtype (need = every soldier who wants one).
    local ssub = ent and shield_subtype(ent)
    if ssub and steel_idx and not steel_gear_done then
        local need = 0
        for _, r in pairs(req) do
            if r.item_type == df.item_type.SHIELD and r.subtype == ssub then need = need + r.count end
        end
        if (shields_by_sub[ssub] or 0) < need then
            local mt, mi, mc
            if logs > 0 then
                mt, mi, mc = -1, -1, df.entity_material_category.Wood
            elseif iron_idx and ((bars[barkey(0, iron_idx)] or 0) > 0 or iron_ore_count > 0) then
                mt, mi, mc = 0, iron_idx, -1
            elseif copper_idx then
                mt, mi, mc = 0, copper_idx, -1
            end
            if mt then
                queue_one('shieldstandin', {item_type = df.item_type.SHIELD, subtype = ssub,
                    mat_type = mt, mat_index = mi, size_race = civ_race()})
            else
                drop_order('shieldstandin')
            end
        else
            drop_order('shieldstandin')
        end
    else
        drop_order('shieldstandin')
    end

    -- recycle surplus steel: for the masterwork upgrade AND to free bars for miner picks
    -- when we're out of steel (out of bars -> melt extra steel items that aren't needed)
    if state.masterwork or pick_short > 0 then
        local extra = pick_short > 0 and steel_idx
            and {[barkey(0, steel_idx)] = pick_short} or nil
        melt_for_masterwork(req, mwstock, mwstock_h, stock, bars, extra, basic_done)
    end
    -- leather field kit: a backpack (food) and a waterskin/flask (water) per soldier
    ensure_supply('supply/backpack', df.job_type.MakeBackpack, soldiers, backpacks, hides)
    ensure_supply('supply/flask', df.job_type.MakeFlask, soldiers, flasks, hides)

    -- CIVILIAN MILITIA -> READY: a civilian squad stays off-duty while its gear is being made
    -- (orders are queued regardless of routine), and flips to the "Ready" routine once every one
    -- of its members actually holds a full basic set. Coverage is allocated in priority order
    -- (military first, civilians last) against a fresh copy of stock, so a civilian squad only
    -- flips once the pieces it shares with the army (steel helm/gauntlets/boots) are truly spare.
    do
        local ridx = ready_routine_idx()
        local training = autotraining_squads()   -- never override an autotraining squad's routine
        if ridx then
            local av, avh = {}, {}
            for key, r in pairs(req) do
                if HANDED[r.item_type] then
                    local s = stock_h[key] or {}
                    avh[key] = {[0] = s[0] or 0, [1] = s[1] or 0}
                else
                    av[key] = stock[key] or 0
                end
            end
            local geared, seen = {}, {}
            for _, sreq in ipairs(persoldier) do
                local ok = true
                for _, need in ipairs(sreq.needs) do
                    local k = need.k
                    if need.hand ~= nil then
                        local pool = avh[k]
                        if pool and pool[need.hand] > 0 then pool[need.hand] = pool[need.hand] - 1 else ok = false end
                    elseif (av[k] or 0) > 0 then av[k] = av[k] - 1 else ok = false end
                end
                if sreq.civilian then
                    if not seen[sreq.sid] then seen[sreq.sid] = true; geared[sreq.sid] = true end
                    if not ok then geared[sreq.sid] = false end
                end
            end
            for sid, done in pairs(geared) do
                local sq = df.squad.find(sid)
                if done and sq and not training[sid] and sq.cur_routine_idx ~= ridx then
                    sq.cur_routine_idx = ridx
                end
            end
        end
    end

    -- completion flags for the overlay's "Done" label: queue = every soldier has each piece
    -- (by stock, hand-aware); masterwork = every piece is masterwork. Vacuously done if no
    -- soldiers/pieces are required.
    local queue_done, mw_done = true, true
    for key, r in pairs(req) do
        if HANDED[r.item_type] then
            local perhand = r.count / 2
            local sh, mh = stock_h[key] or {}, mwstock_h[key] or {}
            if (sh[0] or 0) < perhand or (sh[1] or 0) < perhand then queue_done = false end
            if (mh[0] or 0) < perhand or (mh[1] or 0) < perhand then mw_done = false end
        else
            if (stock[key] or 0) < r.count then queue_done = false end
            if (mwstock[key] or 0) < r.count then mw_done = false end
        end
    end
    state.done_queue, state.done_masterwork = queue_done, mw_done

    save_state()        -- persist the updated order-id map + completion flags
end

-- per-frame heartbeat gated on the calendar (repeat-util's tick timers fire too
-- coarsely on this build; see auto-mandate); runs the cycle ~once a game-day.
-- The generation counter lives on dfhack.internal (NOT a module local) so it
-- survives script reloads: reloading/re-enabling bumps it, and every previously
-- scheduled heartbeat -- including ones closed over an older copy of this code --
-- sees my ~= current and exits instead of leaking a second ticking loop.
local last_run = nil
local function hb_gen(set)
    if set ~= nil then dfhack.internal.military_uniforms_hb_gen = set end
    return dfhack.internal.military_uniforms_hb_gen or 0
end
local function start_heartbeat()
    last_run = nil
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        if not service_on() or my ~= hb_gen() then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= DAY_TICKS then last_run = now; run_cycle() end
        dfhack.timeout(1, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

-- delete every standing order we created (used when the service is switched off)
local function drop_all_orders()
    for key in pairs(state.orders) do drop_order(key) end
end

-- set a toggle; runs the cycle now and (re)starts/stops the shared heartbeat so
-- it ticks whenever either service (gear queueing or war-dog training) is on
function set_toggle(name, val)
    load_state()
    state[name] = val
    save_state()
    if name == 'queue' and not val then drop_all_orders(); save_state() end
    if name == 'pickaxes' and not val then drop_order('pick'); save_state() end
    if service_on() then start_heartbeat() else stop_heartbeat() end
    run_cycle()
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
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
    desc = 'Toggles to auto-queue squad gear orders, upgrade to masterwork, and train war dogs.',
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
                    label = 'Forge Steel Picks',
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
    DONE.queue, DONE.masterwork, DONE.picks = st.done_queue, st.done_masterwork, st.done_picks
    self.subviews.queue:setOption(state.queue)
    self.subviews.masterwork:setOption(state.masterwork)
    self.subviews.wardogs:setOption(state.wardogs)
    self.subviews.pickaxes:setOption(state.pickaxes)
    MilitaryUniformOverlay.super.render(self, dc)
end

OVERLAY_WIDGETS = {entry = MilitaryUniformOverlay}

if dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then qerror('military-uniforms only works in fortress mode') end
    set_toggle('queue', dfhack_flags.enable_state)
    print('military-uniforms: gear queueing ' .. (load_state().queue and 'ON' or 'OFF'))
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
    run_cycle()        -- reconcile standing orders against current stock/need once
    local n = 0
    for _ in pairs(state.orders) do n = n + 1 end
    print(('military-uniforms: %d gear order(s) standing (short of need)'):format(n))
    return
end

local made, deleted = create_steel_uniforms()
print(('military-uniforms: created %d steel uniform templates:'):format(#made))
for _, n in ipairs(made) do print('  + ' .. n) end
if #deleted > 0 then
    print(('  deleted %d default metal uniform%s:'):format(#deleted, #deleted == 1 and '' or 's'))
    for _, n in ipairs(deleted) do print('    - ' .. n) end
end

-- Queue gear orders defaults ON. The heartbeat normally starts on map load via
-- onStateChange, but that already fired before this module loaded (e.g. when run from
-- magnus-scripts), so start it here too if the service is on. Persist the resolved state
-- (so the default sticks) -- a fort where you turned it OFF stays off (load_state only
-- defaults when unset).
load_state()
save_state()
if service_on() then
    start_heartbeat()
    print('  gear-order service ON (Queue gear orders), running daily.')
else
    print('  gear-order service is OFF (enable on the Equip screen with Shift-G).')
end
