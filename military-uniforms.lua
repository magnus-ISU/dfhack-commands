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

-- ---- order service: queue the gear each squad soldier's uniform requires -----

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local GLOBAL_KEY = 'military-uniforms'
local DAY_TICKS = 1200
local BARS_PER_ITEM = 1   -- metal gear (armour/weapon) = ~1 bar each

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

local function new_condition(cmp, val, item_type, subtype, mat_type, mat_index)
    local c = df.manager_order_condition_item:new()
    c.compare_type, c.compare_val = cmp, val
    c.item_type, c.item_subtype = item_type or -1, subtype or -1
    c.mat_type, c.mat_index = mat_type or -1, mat_index or -1
    return c
end

local function clear_conditions(o)
    for i = #o.item_conditions - 1, 0, -1 do
        local c = o.item_conditions[i]
        o.item_conditions:erase(i)
        c:delete()
    end
end

-- a repeating Daily order making ONE of the item at a time, re-enqueued while
-- stock < need and there is at least one metal bar of the material (NO fuel
-- condition). Only the condition threshold tracks `need`; each run makes a single
-- unit. Reuses a matching repeating order if present, else creates one on top.
local function ensure_order(r, need)
    local mo = df.global.world.manager_orders
    local job = MAKE_JOB[r.item_type]
    local o
    for i = 0, #mo.all - 1 do
        local x = mo.all[i]
        if x.job_type == job and x.item_subtype == r.subtype and x.mat_type == r.mat_type
            and x.mat_index == r.mat_index
            and x.frequency == df.workquota_frequency_type.Daily and #x.item_conditions > 0
        then o = x; break end
    end
    if not o then
        o = df.manager_order:new()
        o.job_type, o.item_type, o.item_subtype = job, -1, r.subtype
        o.mat_type, o.mat_index = r.mat_type, r.mat_index
        o.id = mo.manager_order_next_id
        mo.manager_order_next_id = o.id + 1
        mo.all:insert(0, o)
    end
    o.frequency = df.workquota_frequency_type.Daily
    o.amount_total, o.amount_left = 1, 1        -- always forge just one per enqueue
    o.status.validated, o.status.active = true, true
    clear_conditions(o)
    o.item_conditions:insert('#', new_condition(df.logic_condition_type.LessThan, need,
        r.item_type, r.subtype, r.mat_type, r.mat_index))   -- while stock < need
    o.item_conditions:insert('#', new_condition(df.logic_condition_type.AtLeast, BARS_PER_ITEM,
        df.item_type.BAR, -1, r.mat_type, r.mat_index))      -- and a metal bar is available
end

-- mark non-masterwork, non-artifact copies of required items for melting, so
-- they get re-forged for another shot at masterwork
local function melt_inferior(req)
    local want = {}
    for k in pairs(req) do want[k] = true end
    local marked = 0
    for _, it in ipairs(df.global.world.items.all) do
        if not it.flags.melt and it:getQuality() < df.item_quality.Masterful
            and dfhack.items.getGeneralRef(it, df.general_ref_type.IS_ARTIFACT) == nil
            and dfhack.items.canMelt(it)
        then
            local key = ('%d/%d/%d/%d'):format(it:getType(), it:getSubtype(), it.mat_type, it.mat_index)
            if want[key] and dfhack.items.markForMelting(it) then marked = marked + 1 end
        end
    end
    return marked
end

-- ---- enable state: two toggles, persisted -----------------------------------

state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.queue == nil then state.queue = false end
        if state.masterwork == nil then state.masterwork = false end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

function isEnabled() return load_state().queue end

local function run_cycle()
    if not dfhack.world.isFortressMode() then return end
    load_state()
    if not state.queue then return end
    local req = compute_required()
    for _, r in pairs(req) do ensure_order(r, r.count + (state.masterwork and 1 or 0)) end
    if state.masterwork then melt_inferior(req) end
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
        if not load_state().queue or my ~= hb_gen() then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= DAY_TICKS then last_run = now; run_cycle() end
        dfhack.timeout(1, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

-- set a toggle; turning Queue on starts the service; either change re-runs now
function set_toggle(name, val)
    load_state()
    state[name] = val
    save_state()
    if name == 'queue' then
        if val then start_heartbeat() else stop_heartbeat() end
    end
    if state.queue then run_cycle() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and load_state().queue then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- overlay: two toggles on the squad equipment screen ---------------------

MilitaryUniformOverlay = defclass(MilitaryUniformOverlay, overlay.OverlayWidget)
MilitaryUniformOverlay.ATTRS{
    desc = 'Toggles to auto-queue squad gear orders and upgrade gear to masterwork.',
    default_pos = {x = -99, y = 4},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Equipment/Default',
    frame = {w = 36, h = 4},
}

function MilitaryUniformOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, h = 4},
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
            },
        },
    }
end

function MilitaryUniformOverlay:render(dc)
    load_state()
    self.subviews.queue:setOption(state.queue)
    self.subviews.masterwork:setOption(state.masterwork)
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
    local req = compute_required()
    local n = 0
    for _, r in pairs(req) do ensure_order(r, r.count + (state.masterwork and 1 or 0)); n = n + 1 end
    local melted = state.masterwork and melt_inferior(req) or 0
    print(('military-uniforms: refreshed %d gear order(s)%s'):format(
        n, melted > 0 and (', melted '..melted..' inferior') or ''))
    return
end

local made, deleted = create_steel_uniforms()
print(('military-uniforms: created %d steel uniform templates:'):format(#made))
for _, n in ipairs(made) do print('  + ' .. n) end
if #deleted > 0 then
    print(('  deleted %d default metal uniform%s:'):format(#deleted, #deleted == 1 and '' or 's'))
    for _, n in ipairs(deleted) do print('    - ' .. n) end
end
