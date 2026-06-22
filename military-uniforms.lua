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

-- ---- order service: queue gear when soldiers get a (steel) uniform ----------

local MAKE_JOB = {
    [df.item_type.ARMOR]  = df.job_type.MakeArmor,
    [df.item_type.HELM]   = df.job_type.MakeHelm,
    [df.item_type.PANTS]  = df.job_type.MakePants,
    [df.item_type.GLOVES] = df.job_type.MakeGloves,
    [df.item_type.SHOES]  = df.job_type.MakeShoes,
    [df.item_type.SHIELD] = df.job_type.MakeShield,
    [df.item_type.WEAPON] = df.job_type.MakeWeapon,
}

-- bump a matching active order by 1, else create a new one (amount 1) at the top
local function bump_order(job, subtype, mattype, matindex)
    local mo = df.global.world.manager_orders
    for i = 0, #mo.all - 1 do
        local o = mo.all[i]
        if o.job_type == job and o.item_subtype == subtype and o.mat_type == mattype
            and o.mat_index == matindex and o.status.active
        then
            o.amount_total = o.amount_total + 1
            o.amount_left = o.amount_left + 1
            return
        end
    end
    local o = df.manager_order:new()
    o.job_type, o.item_type, o.item_subtype = job, -1, subtype
    o.mat_type, o.mat_index = mattype, matindex
    o.amount_total, o.amount_left = 1, 1
    o.frequency = 0
    o.status.validated, o.status.active = true, true
    o.id = mo.manager_order_next_id
    mo.manager_order_next_id = o.id + 1
    mo.all:insert(0, o)
end

-- the makeable, specific-material (steel) gear items of a filled position; or nil
local function position_gear(pos)
    if pos.occupant < 0 then return nil end
    local items = {}
    for slot = 0, 6 do
        local v = pos.equipment.uniform[slot]
        for j = 0, #v - 1 do
            local s = v[j]
            if MAKE_JOB[s.item_type] and s.item_subtype >= 0 and s.mattype >= 0 then
                items[#items + 1] = {job = MAKE_JOB[s.item_type], sub = s.item_subtype,
                                     mt = s.mattype, mi = s.matindex}
            end
        end
    end
    return #items > 0 and items or nil
end

local function gear_sig(pos, items)
    local p = {tostring(pos.occupant)}
    for _, it in ipairs(items) do p[#p + 1] = it.job .. '/' .. it.sub .. '/' .. it.mt .. '/' .. it.mi end
    return table.concat(p, ';')
end

processed = processed or nil   -- "squad:pos" -> last-ordered signature (dedup)

-- queue gear for newly-outfitted soldiers (once per soldier+uniform); count made
function queue_gear()
    if not dfhack.world.isFortressMode() then return 0 end
    if not processed then processed = {} end
    local fort = df.global.plotinfo.group_id
    local made = 0
    for s = 0, #df.global.world.squads.all - 1 do
        local sq = df.global.world.squads.all[s]
        if sq.entity_id == fort then
            for p = 0, #sq.positions - 1 do
                local items = position_gear(sq.positions[p])
                if items then
                    local key = sq.id .. ':' .. p
                    local sig = gear_sig(sq.positions[p], items)
                    if processed[key] ~= sig then
                        for _, it in ipairs(items) do bump_order(it.job, it.sub, it.mt, it.mi); made = made + 1 end
                        processed[key] = sig
                    end
                end
            end
        end
    end
    return made
end

-- ---- enable / background service --------------------------------------------

local GLOBAL_KEY = 'military-uniforms'
local DAY_TICKS = 1200
enabled = enabled or false
local last_run, hb_gen = nil, 0

function isEnabled() return enabled end

local function do_cycle()
    local n = queue_gear()
    if n > 0 then print(('military-uniforms: queued %d gear order(s) for newly-outfitted soldiers'):format(n)) end
end

-- per-frame heartbeat gated on the calendar (repeat-util's tick timers are
-- unreliable on this build; see auto-mandate), runs the cycle ~once a game-day
local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my = hb_gen
    local function hb()
        if not enabled or my ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= DAY_TICKS then last_run = now; do_cycle() end
        dfhack.timeout(1, 'frames', hb)
    end
    hb()
end

local function stop() enabled = false; hb_gen = hb_gen + 1 end

function set_enabled(on)
    if on then start() else stop() end
    enabled = on
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {enabled = enabled})
    return enabled
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        processed = nil
        if dfhack.world.isFortressMode()
            and dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false}).enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop(); processed = nil
    end
end

if dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then qerror('military-uniforms only works in fortress mode') end
    set_enabled(dfhack_flags.enable_state)
    print('military-uniforms: order service ' .. (enabled and 'enabled (background)' or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then qerror('military-uniforms only works in fortress mode') end

local args = {...}
if args[1] == 'orders' then
    local n = queue_gear()
    print(('military-uniforms: queued %d gear order(s) for outfitted soldiers'):format(n))
    return
end

local made, deleted = create_steel_uniforms()
print(('military-uniforms: created %d steel uniform templates:'):format(#made))
for _, n in ipairs(made) do print('  + ' .. n) end
if #deleted > 0 then
    print(('  deleted %d default metal uniform%s:'):format(#deleted, #deleted == 1 and '' or 's'))
    for _, n in ipairs(deleted) do print('    - ' .. n) end
end
