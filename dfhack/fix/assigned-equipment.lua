-- Free fort gear that DF still lists as assigned to nobody, and unclaim gear the military asked for.
--[[
fix/assigned-equipment

Two different things keep a piece of gear out of the squad equipment lists, and this
repairs both.

  1. PHANTOM ASSIGNMENTS. `plotinfo.equipment.items_assigned[<item type>]` is DF's index of
     "this item already belongs to a soldier". Every id in it is supposed to be matched by a
     real reference somewhere -- a squad position's uniform, its quiver/backpack/flask, a
     squad's ammunition, a hunter's ammo, a work weapon. When a squad is disbanded, a
     uniform edited or a soldier dies at the wrong moment, an id can be left behind with
     nothing pointing at it. The item then belongs to a soldier who does not exist: it never
     shows up when you pick equipment, and nothing ever releases it. Those ids are moved
     back to `items_unassigned` (ids whose item is gone are simply dropped), which is where
     the equipment screen reads from.

  2. PERSONAL PROPERTY. An item a citizen has claimed as their own -- adventurer gear carried
     into the fort, a masterwork somebody took a liking to -- is skipped by the equipment
     manager entirely. It sits in `items_unassigned` looking perfectly available, never gets
     handed out, and never appears in the picker when you go looking for it by name. This
     reports every piece of military gear a citizen has claimed; `--unclaim` drops the claim,
     and DF offers the item on the next equipment update.

     "Military gear" means the item types the equipment screen deals in -- weapons, shields,
     ammo, quivers, flasks, backpacks and armour -- and for the armour slots, only real
     armour: `armorlevel > 0`, or an artifact. The robe a dwarf owns is their own business.
     Gear owned by VISITORS is never touched: a mercenary's own sword is not yours, and a
     mercenary you disarm is a mercenary with a grudge.

Reported, not touched: anything a squad, a hunter or a work detail still references, and the
ordinary clothing citizens own (that is `cleanowned`'s job, not this one).

Only your own fort's squads are read. `--all-squads` walks all ~300 squads in the world
instead, which is a paranoid check that freezes DF for a couple of seconds.

Usage:
    fix/assigned-equipment              free phantom assignments, report claimed gear
    fix/assigned-equipment --unclaim    also drop citizens' claims on military gear
    fix/assigned-equipment -n           report only (dry run)
    fix/assigned-equipment -v           name every item, not just the counts
    fix/assigned-equipment --all-squads read every squad in the world, not just yours
]]

local utils = require('utils')

local dry, verbose, unclaim, all_squads = false, false, false, false
for _, a in ipairs({...}) do
    if a == '-n' or a == '--dry-run' then dry = true
    elseif a == '-v' or a == '--verbose' then verbose = true
    elseif a == '--unclaim' then unclaim = true
    elseif a == '--all-squads' then all_squads = true
    else qerror('unknown argument: ' .. a) end
end

if not dfhack.isMapLoaded() then qerror('fix/assigned-equipment needs a loaded fort') end

local equipment = df.global.plotinfo.equipment
local group_id = df.global.plotinfo.group_id

local function act(fmt, ...)
    print((dry and '[dry] ' or '') .. fmt:format(...))
end

local function describe(item)
    return dfhack.items.getReadableDescription(item)
end

-- squads of this fort; --all-squads keeps every squad in the world
local function fort_squads()
    local out = {}
    for _, squad in ipairs(df.global.world.squads.all) do
        if all_squads or squad.entity_id == group_id then table.insert(out, squad) end
    end
    return out
end

local squads = fort_squads()

-- ---- 1) assignments with nothing pointing at them ---------------------------

-- every item id something still claims. Missing one here would free an item that is
-- genuinely in use, so this is deliberately generous: a reference in any of these places
-- keeps the assignment, even a reference that is itself stale.
local function collect_references()
    local refs = {}
    local function add(id) if id and id >= 0 then refs[id] = true end end
    local function add_all(vec) for _, id in ipairs(vec) do add(id) end end

    for _, squad in ipairs(squads) do
        for _, position in ipairs(squad.positions) do
            local eq = position.equipment
            add_all(eq.assigned_items)
            add(eq.quiver) add(eq.backpack) add(eq.flask)
            -- uniform is one vector of specs per uniform category; `assigned` holds the
            -- items DF picked for the slot, `item` a specific item you chose yourself
            for i = 0, #eq.uniform - 1 do
                for _, spec in ipairs(eq.uniform[i]) do
                    add(spec.item)
                    add_all(spec.assigned)
                end
            end
        end
        local ammo = squad.ammo
        add_all(ammo.ammo_items)
        add_all(ammo.train_weapon_free)
        add_all(ammo.train_weapon_inuse)
        for _, spec in ipairs(ammo.ammunition) do add_all(spec.assigned) end
    end

    -- hunters and the work weapons handed to civilians
    add_all(equipment.work_weapons)
    add_all(equipment.ammo_items)
    for _, spec in ipairs(equipment.hunter_ammunition) do add_all(spec.assigned) end

    -- what soldiers themselves are carrying the assignment for; a unit can still hold a
    -- uniform item after the squad record has moved on, and that is not ours to break
    for _, unit in ipairs(df.global.world.units.active) do
        if unit.military.squad_id >= 0 then
            local u = unit.uniform
            for i = 0, #u.uniforms - 1 do add_all(u.uniforms[i]) end
            add_all(u.uniform_pickup)
            add_all(u.uniform_drop)
        end
    end

    return refs
end

local refs = collect_references()
local freed, dropped = {}, {}

for item_type = 0, #equipment.items_assigned - 1 do
    local assigned = equipment.items_assigned[item_type]
    -- descending: erasing shifts everything after it
    for i = #assigned - 1, 0, -1 do
        local id = assigned[i]
        if not refs[id] then
            local item = df.item.find(id)
            local what = ('%s %d'):format(df.item_type[item_type], id)
            if item then
                table.insert(freed, ('%s -- %s'):format(what, describe(item)))
            else
                table.insert(dropped, what)
            end
            if not dry then
                assigned:erase(i)
                -- items_unassigned is kept sorted by id; DF binary-searches it
                if item then utils.insert_sorted(equipment.items_unassigned[item_type], id) end
            end
        end
    end
end

-- ---- 2) military gear a citizen has claimed as personal property ------------

-- what the squad equipment screen hands out
local EQUIPMENT_TYPE = {
    [df.item_type.WEAPON] = true, [df.item_type.SHIELD] = true,
    [df.item_type.AMMO] = true,   [df.item_type.QUIVER] = true,
    [df.item_type.FLASK] = true,  [df.item_type.BACKPACK] = true,
    [df.item_type.ARMOR] = true,  [df.item_type.HELM] = true,
    [df.item_type.SHOES] = true,  [df.item_type.GLOVES] = true,
    [df.item_type.PANTS] = true,
}
-- those five armour slots double as ordinary clothing, and `armorlevel` is what separates a
-- breastplate from a robe. The clothes a dwarf owns are their own business -- confiscating
-- those is `cleanowned`'s job -- so only real armour counts here, plus artifacts, which are
-- worth asking about whatever they turn out to be.
local ARMOR_SLOT = {
    [df.item_type.ARMOR] = true, [df.item_type.HELM] = true, [df.item_type.SHOES] = true,
    [df.item_type.GLOVES] = true, [df.item_type.PANTS] = true,
}

local function is_military_gear(item)
    local item_type = item:getType()
    if not EQUIPMENT_TYPE[item_type] then return false end
    if not ARMOR_SLOT[item_type] or item.flags.artifact then return true end
    local subtype = item.subtype
    return subtype and subtype.armorlevel and subtype.armorlevel > 0
end

-- entity_material_category -> "does this material qualify". Only used to say WHICH uniform
-- slot is waiting for an item; a class we cannot judge just means we say nothing.
local MATERIAL_CLASS = {
    [df.entity_material_category.Clothing] = function() return true end,
    [df.entity_material_category.Armor] = function(m) return m.flags.IS_METAL end,
    [df.entity_material_category.WeaponMelee] = function(m) return m.flags.IS_METAL end,
    [df.entity_material_category.WeaponRanged] = function(m) return m.flags.IS_METAL end,
    [df.entity_material_category.Pick] = function(m) return m.flags.IS_METAL end,
    [df.entity_material_category.AmmoMetal] = function(m) return m.flags.IS_METAL end,
    [df.entity_material_category.Anvil] = function(m) return m.flags.IS_METAL end,
    [df.entity_material_category.Chain] = function(m) return m.flags.IS_METAL end,
    [df.entity_material_category.Leather] = function(m) return m.flags.LEATHER end,
    [df.entity_material_category.PlantFiber] = function(m) return m.flags.THREAD_PLANT end,
    [df.entity_material_category.Silk] = function(m) return m.flags.SILK end,
    [df.entity_material_category.Wool] = function(m) return m.flags.YARN end,
    [df.entity_material_category.Cloth] = function(m)
        return m.flags.THREAD_PLANT or m.flags.SILK or m.flags.YARN
    end,
    [df.entity_material_category.Wood] = function(m) return m.flags.WOOD end,
    [df.entity_material_category.Stone] = function(m) return m.flags.IS_STONE end,
    [df.entity_material_category.Bone] = function(m) return m.flags.BONE end,
    [df.entity_material_category.Shell] = function(m) return m.flags.SHELL end,
    [df.entity_material_category.Pearl] = function(m) return m.flags.PEARL end,
    [df.entity_material_category.Horn] = function(m) return m.flags.HORN end,
    [df.entity_material_category.Gem] = function(m) return m.flags.IS_GEM end,
}

local function spec_matches(spec, item)
    if spec.item_type ~= -1 and item:getType() ~= spec.item_type then return false end
    if spec.item_subtype ~= -1 and item:getSubtype() ~= spec.item_subtype then return false end
    if spec.mattype ~= -1 then
        if item:getMaterial() ~= spec.mattype then return false end
        if spec.matindex ~= -1 and item:getMaterialIndex() ~= spec.matindex then return false end
    end
    if spec.material_class ~= -1 then
        local test = MATERIAL_CLASS[spec.material_class]
        if not test then return false end
        local mat = dfhack.matinfo.decode(item)
        if not mat or not test(mat.material) then return false end
    end
    return true
end

-- every uniform slot still waiting for an item, so we can name the one an owned item would fill
local function unfilled_specs()
    local out = {}
    for _, squad in ipairs(squads) do
        for pos_idx, position in ipairs(squad.positions) do
            local eq = position.equipment
            for i = 0, #eq.uniform - 1 do
                for _, spec in ipairs(eq.uniform[i]) do
                    if #spec.assigned == 0 then
                        table.insert(out, {spec = spec, squad = squad, position = pos_idx})
                    end
                end
            end
        end
    end
    return out
end

local function squad_name(squad)
    if squad.alias ~= '' then return squad.alias end
    return dfhack.translation.translateName(squad.name, true)
end

-- owned gear sitting in the unassigned lists, deduplicated: one item is listed under several
-- categories (a helm is both HELM and ANY_GOES_IN_ARMORSTAND)
local function owned_gear()
    local seen, out = {}, {}
    for item_type = 0, #equipment.items_unassigned - 1 do
        for _, id in ipairs(equipment.items_unassigned[item_type]) do
            if not seen[id] then
                seen[id] = true
                local item = df.item.find(id)
                if item and item.flags.owned and is_military_gear(item) then
                    -- a visitor's own sword is not ours to confiscate, and a mercenary
                    -- stripped of their weapon is a mercenary with a grudge
                    local owner = dfhack.items.getOwner(item)
                    if owner and dfhack.units.isCitizen(owner) then
                        table.insert(out, {item = item, owner = owner})
                    end
                end
            end
        end
    end
    return out
end

local claimed = {}
do
    local specs = unfilled_specs()
    for _, entry in ipairs(owned_gear()) do
        local wanted
        for _, candidate in ipairs(specs) do
            if spec_matches(candidate.spec, entry.item) then wanted = candidate break end
        end
        local holder = dfhack.items.getHolderUnit(entry.item)
        table.insert(claimed, {
            item = entry.item,
            text = ('%s -- claimed by %s%s%s%s'):format(
                describe(entry.item),
                dfhack.units.getReadableName(entry.owner),
                holder and (', carried by ' .. dfhack.units.getReadableName(holder)) or '',
                wanted and (', wanted by %s position %d'):format(
                    squad_name(wanted.squad), wanted.position + 1) or '',
                entry.item.flags.forbid and ' (and forbidden)' or ''),
        })
    end
end

if unclaim and not dry then
    for _, entry in ipairs(claimed) do dfhack.items.setOwner(entry.item, nil) end
end

-- ---- tell DF to look again --------------------------------------------------

if not dry and (#freed > 0 or #dropped > 0 or (unclaim and #claimed > 0)) then
    local update = equipment.update
    update.weapon, update.armor, update.shoes, update.shield, update.helm = true, true, true, true, true
    update.gloves, update.ammo, update.pants, update.backpack, update.quiver = true, true, true, true, true
end

-- ---- report -----------------------------------------------------------------

local function list(entries)
    if verbose then for _, e in ipairs(entries) do print('    ' .. (type(e) == 'table' and e.text or e)) end end
end

if #freed == 0 and #dropped == 0 then
    print('fix/assigned-equipment: no phantom assignments -- every assigned item is still spoken for.')
else
    act('%d assignment%s with nothing pointing at %s:', #freed + #dropped,
        #freed + #dropped == 1 and '' or 's', #freed + #dropped == 1 and 'it' or 'them')
    if #freed > 0 then
        act('  %d item%s returned to the equipment lists', #freed, #freed == 1 and '' or 's')
        list(freed)
    end
    if #dropped > 0 then
        act('  %d id%s dropped -- the item no longer exists', #dropped, #dropped == 1 and '' or 's')
        list(dropped)
    end
end

if #claimed > 0 then
    local n, plural = #claimed, #claimed == 1 and '' or 's'
    if unclaim and not dry then
        act('%d piece%s of gear unclaimed -- the equipment manager can hand %s out now:',
            n, plural, n == 1 and 'it' or 'them')
    else
        print(('%d piece%s of military gear %s personal property, which is why the squad lists ' ..
            'never offer %s -- rerun with --unclaim to drop the claim%s:'):format(
            n, plural, n == 1 and 'is' or 'are', n == 1 and 'it' or 'them', plural))
    end
    for _, entry in ipairs(claimed) do print('    ' .. entry.text) end
elseif verbose then
    print('No citizen is sitting on military gear -- nothing owned that a squad could be given.')
end
