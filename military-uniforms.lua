-- Create steel military uniform templates, one per typical weapon type.
--@module = true
--@enable = true
--[[
    military-uniforms            create/refresh the steel uniform set
    military-uniforms orders     queue gear orders for outfitted soldiers, once
    enable military-uniforms     background: queue gear orders as soldiers are
                                 assigned (steel) uniforms
    disable military-uniforms    stop the background order service

Creates a "Steel - <weapon>" uniform template on the fort entity for each of the
typical weapons (short sword, war hammer, battle axe, spear, pick, mace,
crossbow). Each is the full steel set -- breastplate + mail shirt, helm,
gauntlets, greaves, high boots, and a shield -- plus a steel weapon of
that type, with "replace clothing" on. Exceptions: the crossbow uniform uses a
COPPER crossbow + steel buckler; the war hammer uniform uses a SILVER war hammer.

Everything is resolved generically per world: STEEL/COPPER/SILVER by inorganic
id, and every item subtype by name within the fort civ's producible lists (so it
picks the dwarf-makeable breastplate, not a modded look-alike). Re-running
refreshes the "Steel - *" templates it owns (it won't touch your own uniforms).

The Equip screen overlay (dwarfmode/Squads/Equipment/Default) has three toggles:
  Queue gear orders (Shift-G)      per-soldier, per-material work orders: one
                                   unit queued only when stock < need and a bar
                                   of that material exists (no over-production)
  Upgrade to masterwork (Shift-M)  also melt inferior copies and remake them
  Train surplus war dogs (Shift-D) war-train adult male dogs beyond BREEDER_MALES
                                   breeders (Pets/Livestock training, done by an Animal
                                   Trainer -- not the soldiers). A male PUPPY counts toward
                                   the breeder reserve (it'll grow into one), so 2 adults +
                                   1 male pup trains one adult. Finished war dogs are then
                                   auto-assigned (owner link) to squad members, spread
                                   evenly across the military.
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

-- a default "metal armour" uniform: not one of ours, and its body armour uses the
-- generic Armor material class (the auto-generated metal uniform) rather than a
-- specific metal (our steel = mattype 0) or leather/cloth (material_class Leather).
local function is_metal_default(u)
    if u.name:sub(1, #NAME_PREFIX) == NAME_PREFIX then return false end
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

function create_steel_uniforms()
    local ent = fort_entity()
    if not ent then qerror('no fort entity') end
    local steel = inorganic_idx('STEEL')
    if not steel then qerror('no STEEL inorganic in this world') end
    remove_owned(ent)
    local made = {}
    for _, spec in ipairs(GROUP) do
        local u = create_template(ent, spec, steel)
        made[#made + 1] = u.name
    end
    local deleted_metal = delete_metal_defaults(ent)
    return made, deleted_metal
end

-- ---- order service: queue the gear each squad soldier's uniform requires -----

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local GLOBAL_KEY = 'military-uniforms'
local DAY_TICKS = 1200
local BARS_PER_ITEM = 1   -- metal gear (armour/weapon) = ~1 bar each
local BREEDER_MALES = 2   -- adult male dogs kept untrained for breeding

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
                    for slot = 0, 6 do
                        local v = pos.equipment.uniform[slot]
                        for j = 0, #v - 1 do
                            local it = v[j]
                            -- squad_uniform_spec uses mattype/matindex (not mat_type/mat_index)
                            if MAKE_JOB[it.item_type] and it.item_subtype >= 0 and it.mattype >= 0 then
                                local key = ('%d/%d/%d/%d'):format(it.item_type, it.item_subtype, it.mattype, it.matindex)
                                local r = req[key]
                                if not r then
                                    r = {item_type = it.item_type, subtype = it.item_subtype,
                                         mat_type = it.mattype, mat_index = it.matindex, count = 0}
                                    req[key] = r
                                end
                                r.count = r.count + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return req
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
-- need. Instead we self-manage: each daily cycle we compare real stock to need and
-- queue exactly ONE unit only when genuinely short, deleting the order outright
-- once the need is met -- so nothing is ever made that isn't wanted.
local function ensure_order(key, r, need, stock, bars)
    if stock < need and bars >= BARS_PER_ITEM then
        local o = state.orders[key] and order_by_id(state.orders[key])
        if not o then
            local mo = df.global.world.manager_orders
            o = df.manager_order:new()
            o.job_type, o.item_type, o.item_subtype = MAKE_JOB[r.item_type], -1, r.subtype
            o.mat_type, o.mat_index = r.mat_type, r.mat_index
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
    else
        drop_order(key)        -- need met (or no bars): keep no standing order
    end
end

local function item_wear(it)
    local ok, w = pcall(function() return it.wear end)
    return (ok and w) or 0
end

-- Masterwork recycling: to re-forge a masterwork we must recycle an inferior copy
-- into metal -- but NEVER below the count needed to keep every soldier geared. So
-- per material, while we still owe masterwork pieces and the bars/in-flight melts
-- don't cover that, we melt at most ONE surplus piece per cycle (the worst:
-- most-damaged, then lowest quality, never masterwork/artifact), and only from an
-- item type that has more than `need` equippable copies -- so the soldiers always
-- keep a full set and we drift toward masterwork one melt+forge at a time.
local function melt_for_masterwork(req, mwstock, stock, bars)
    local short, inbound, cands = {}, {}, {}
    for key, r in pairs(req) do
        local mk = barkey(r.mat_type, r.mat_index)
        short[mk] = (short[mk] or 0) + math.max(0, r.count - (mwstock[key] or 0))
    end
    for mk, b in pairs(bars) do inbound[mk] = b end
    for _, it in ipairs(df.global.world.items.all) do
        if not_fort_stock(it) then goto next_item end
        local key = ('%d/%d/%d/%d'):format(it:getType(), it:getSubtype(), it:getMaterial(), it:getMaterialIndex())
        if req[key] then
            local mk = barkey(it:getMaterial(), it:getMaterialIndex())
            if it.flags.melt then
                inbound[mk] = (inbound[mk] or 0) + 1          -- metal already on the way
            elseif it:getQuality() < df.item_quality.Masterful
                and not it.flags.artifact
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
        -- still owe masterwork here, and bars+in-flight don't cover it: melt ONE
        if owed > 0 and (inbound[mk] or 0) < owed and list and #list > 0 then
            table.sort(list, function(a, b)
                local wa, wb = item_wear(a), item_wear(b)
                if wa ~= wb then return wa > wb end           -- most-damaged first
                return a:getQuality() < b:getQuality()         -- then lowest quality
            end)
            if dfhack.items.markForMelting(list[1]) then marked = marked + 1 end
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
        if not state.orders then state.orders = {} end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

function isEnabled() return load_state().queue end

-- any background service on? (gear queueing or war-dog training)
local function service_on() load_state(); return state.queue or state.wardogs end

local function run_cycle()
    if not dfhack.world.isFortressMode() then return end
    load_state()
    if state.wardogs then train_surplus_war_dogs(); assign_war_dogs() end
    if not state.queue then return end
    local req = compute_required()
    -- one pass over items: tally gear stock (total + masterwork) by item key, bar
    -- stock by material, and the leather-supply counts. Items already flagged for
    -- melting don't count (they're being recycled).
    local stock, mwstock, bars = {}, {}, {}
    local hides, flasks, backpacks = 0, 0, 0
    for _, it in ipairs(df.global.world.items.all) do
        if not_fort_stock(it) then goto next_item end
        local t = it:getType()
        if t == df.item_type.BAR then
            bars[barkey(it:getMaterial(), it:getMaterialIndex())] = (bars[barkey(it:getMaterial(), it:getMaterialIndex())] or 0) + 1
        elseif t == df.item_type.SKIN_TANNED then
            hides = hides + 1
        elseif not it.flags.melt and t == df.item_type.FLASK then
            flasks = flasks + 1
        elseif not it.flags.melt and t == df.item_type.BACKPACK then
            backpacks = backpacks + 1
        elseif not it.flags.melt then
            local k = ('%d/%d/%d/%d'):format(t, it:getSubtype(), it:getMaterial(), it:getMaterialIndex())
            if req[k] then
                stock[k] = (stock[k] or 0) + 1
                -- artifacts are quality 5 but never auto-equip (and can't be melted),
                -- so they must NOT count toward the masterwork goal
                if it:getQuality() >= df.item_quality.Masterful
                    and dfhack.items.getGeneralRef(it, df.general_ref_type.IS_ARTIFACT) == nil
                then mwstock[k] = (mwstock[k] or 0) + 1 end
            end
        end
        ::next_item::
    end
    -- count soldiers (occupied fort squad positions)
    local fort = df.global.plotinfo.group_id
    local soldiers = 0
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do if sq.positions[p].occupant >= 0 then soldiers = soldiers + 1 end end
        end
    end
    -- drop gear orders no longer required (soldier left / uniform changed); leave
    -- the leather-supply orders (keys "supply/*") to ensure_supply below
    for key in pairs(state.orders) do
        if not req[key] and key:sub(1, 7) ~= 'supply/' then drop_order(key) end
    end
    -- gear: in masterwork mode the "have" we measure against is the masterwork
    -- count (keep forging until each soldier has a masterful piece), else total
    for key, r in pairs(req) do
        local have = state.masterwork and (mwstock[key] or 0) or (stock[key] or 0)
        ensure_order(key, r, r.count, have, bars[barkey(r.mat_type, r.mat_index)] or 0)
    end
    if state.masterwork then melt_for_masterwork(req, mwstock, stock, bars) end
    -- leather field kit: a backpack (food) and a waterskin/flask (water) per soldier
    ensure_supply('supply/backpack', df.job_type.MakeBackpack, soldiers, backpacks, hides)
    ensure_supply('supply/flask', df.job_type.MakeFlask, soldiers, flasks, hides)
    save_state()        -- persist the updated order-id map
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

-- ---- overlay: two toggles on the squad equipment screen ---------------------

MilitaryUniformOverlay = defclass(MilitaryUniformOverlay, overlay.OverlayWidget)
MilitaryUniformOverlay.ATTRS{
    desc = 'Toggles to auto-queue squad gear orders, upgrade to masterwork, and train war dogs.',
    default_pos = {x = -93, y = 13},   -- right-anchored: the equip screen is flush to the
                                       -- screen's right edge, so track that edge to slide with it
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Equipment/Default',
    frame = {w = 36, h = 6},
}

function MilitaryUniformOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, h = 6},
            frame_style = gui.MEDIUM_FRAME,
            frame_background = gui.CLEAR_PEN,
            frame_title = 'auto gear',
            subviews = {
                widgets.ToggleHotkeyLabel{
                    view_id = 'queue',
                    frame = {t = 0, l = 0},
                    label = 'Queue gear orders',
                    key = 'CUSTOM_SHIFT_G',
                    initial_option = false,
                    on_change = function(v) set_toggle('queue', v) end,
                },
                widgets.ToggleHotkeyLabel{
                    view_id = 'masterwork',
                    frame = {t = 1, l = 0},
                    label = 'Upgrade to masterwork',
                    key = 'CUSTOM_SHIFT_M',
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
            },
        },
    }
end

function MilitaryUniformOverlay:render(dc)
    load_state()
    self.subviews.queue:setOption(state.queue)
    self.subviews.masterwork:setOption(state.masterwork)
    self.subviews.wardogs:setOption(state.wardogs)
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
