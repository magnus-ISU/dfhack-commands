-- Notify + one-click manager orders for planned-building items with no production.
--@module = false
--[[
planner-orders

Looks at every building placed with the building planner (the `buildingplan` plugin)
and finds the items those buildings still need (unfilled slots). For each needed item
that is NOT already produced by some manager order, it raises a notification in DFHack's
gui/notify panel ("N planned items have no manager order").

Clicking the notification walks you through each missing item (cabinet, armor stand,
ballista parts, ...). For each it shows the materials you can make it from:
    * the generics first -- Rock, Wooden, Copper, Iron, Steel (+ Green/Clear glass) --
      filtered to what that item can actually be made of (e.g. a Bed offers only Wooden);
    * then every other metal/stone you have in the fort;
    * magma-safe materials are tagged [magma-safe]; if the building itself requires a
      magma-safe item, only magma-safe materials are offered.
Each entry also has a "Skip this item" and a "Cancel" choice (Esc also cancels).

Picking a material creates a manager order that makes 5 of the item in that material,
repeating daily but gated on a condition so it only runs when you have EXACTLY 0 of that
item (any material). Components work the same way: a ballista's planned slot asks for
"ballista parts", so you get a ConstructBallistaParts order; a traction bench's slots ask
for its table/mechanism/chain, each handled on its own.

Items with no make-job (e.g. anvils) are listed as unmakeable and skipped.

Run `planner-orders` to register the notification (idempotent; add to dfhack.init or
magnus-scripts to load each session). `planner-orders list` prints the gaps; `planner-orders
now` opens the dialog immediately.
]]

local NAME = 'planner_orders'
local dlg = require('gui.dialogs')
local bp = require('plugins.buildingplan')

local ORDER_AMOUNT = 5
local MAGMA_TEMP = 12000          -- a material is magma-safe if it survives this (deg U)

-- needed-item type -> the job_type that produces it. (Furniture/components are made with
-- item_type = NONE on the order; the job_type alone determines the product.)
local ITEM_JOB = {
    DOOR = 'ConstructDoor', FLOODGATE = 'ConstructFloodgate', BED = 'ConstructBed',
    CHAIR = 'ConstructThrone', COFFIN = 'ConstructCoffin', TABLE = 'ConstructTable',
    BOX = 'ConstructChest', BIN = 'ConstructBin', ARMORSTAND = 'ConstructArmorStand',
    WEAPONRACK = 'ConstructWeaponRack', CABINET = 'ConstructCabinet', STATUE = 'ConstructStatue',
    CAGE = 'MakeCage', WINDOW = 'MakeWindow', CHAIN = 'MakeChain', BARREL = 'MakeBarrel',
    BUCKET = 'MakeBucket', HATCH_COVER = 'ConstructHatchCover', GRATE = 'ConstructGrate',
    QUERN = 'ConstructQuern', MILLSTONE = 'ConstructMillstone', SLAB = 'ConstructSlab',
    BALLISTAPARTS = 'ConstructBallistaParts', CATAPULTPARTS = 'ConstructCatapultParts',
    BALLISTAARROWHEAD = 'MakeBallistaArrowHead', TRAPPARTS = 'ConstructMechanisms',
    TRAPCOMP = 'MakeTrapComponent', PIPE_SECTION = 'MakePipeSection',
    ANVIL = 'ForgeAnvil', ANIMALTRAP = 'MakeAnimalTrap', BLOCKS = 'ConstructBlocks',
    BOLT_THROWER_PARTS = 'ConstructBoltThrowerParts',
    -- intentionally unmapped (no single make-job): WOOD (chopped), BAR (smelted per ore),
    -- SMALLGEM (gem-specific), INSTRUMENT (custom reactions/parts), TRACTION_BENCH
    -- (assembled in place from a table + mechanism + chain).
}

-- which material classes each job can be made from. Default (most furniture) is any of
-- stone/wood/metal/glass; the exceptions restrict to the materials DF actually allows.
local DEFAULT_CLASSES = {stone = true, wood = true, metal = true, glass = true}
local JOB_CLASSES = {
    ConstructBed       = {wood = true},                              -- beds: wood only
    MakeWindow         = {glass = true},                            -- glass windows
    MakeBarrel         = {wood = true, metal = true},
    MakeBucket         = {wood = true, metal = true},
    ConstructBin       = {wood = true, metal = true},
    MakeCage           = {wood = true, metal = true, glass = true}, -- cages: not stone
    ConstructStatue    = {stone = true, metal = true, glass = true},-- statues: not wood
    ConstructSlab      = {stone = true},
    ConstructQuern     = {stone = true},
    ConstructMillstone = {stone = true},
    ConstructMechanisms     = {stone = true, metal = true},
    ConstructBallistaParts  = {wood = true, metal = true},
    ConstructCatapultParts  = {wood = true, metal = true},
    MakeBallistaArrowHead   = {wood = true, metal = true},
    MakeTrapComponent       = {metal = true, wood = true},
    MakeChain               = {metal = true},
    MakeTool                = {stone = true, wood = true, metal = true},  -- nest boxes, jugs, pots, ...
    MakeAnimalTrap          = {wood = true, metal = true},
    ConstructBlocks         = {stone = true, wood = true, metal = true, glass = true},
    ConstructBoltThrowerParts = {wood = true, metal = true},
}

-- jobs restricted to SPECIFIC materials (by inorganic raw id), overriding the class list:
-- anvils can only be forged from iron or steel. Each is offered as its own choice.
local JOB_MATERIALS = {
    ForgeAnvil = {'IRON', 'STEEL'},
}

-- ---- materials --------------------------------------------------------------

-- inorganic material index by raw id (STEEL/COPPER/...), cached
local inorg_cache = {}
local function inorg(id)
    if inorg_cache[id] ~= nil then return inorg_cache[id] end
    local all = df.global.world.raws.inorganics.all
    for i = 0, #all - 1 do
        if all[i].id == id then inorg_cache[id] = i; return i end
    end
    inorg_cache[id] = false
    return false
end

-- a material survives magma if it neither melts nor boils below magma temperature
local function is_magma_safe(mat_type, mat_index)
    if not mat_type or mat_type < 0 then return false end   -- generic / wood category
    local info = dfhack.matinfo.decode(mat_type, mat_index)
    if not info then return false end
    local h = info.material.heat
    return h.melting_point > MAGMA_TEMP and h.boiling_point > MAGMA_TEMP
end

-- glass builtin material (GLASS_GREEN/GLASS_CLEAR/...) -> mat_type, mat_index
local function glass(id)
    local info = dfhack.matinfo.find(id)
    if info then return info.type, info.index end
end

-- distinct metal/stone materials present in the fort (metals from bars, stones from
-- boulders), so the picker can offer "any other material you have". Sorted by name.
local function fort_materials()
    local seen, out = {}, {}
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        local t = it:getType()
        if t == df.item_type.BAR or t == df.item_type.BOULDER then
            local mt, mi = it:getMaterial(), it:getMaterialIndex()
            if mt == 0 and mi >= 0 then
                local key = mt .. ':' .. mi
                if not seen[key] then
                    seen[key] = true
                    local info = dfhack.matinfo.decode(mt, mi)
                    if info then
                        local cls = info.material.flags.IS_METAL and 'metal'
                            or (info.material.flags.IS_STONE and 'stone' or nil)
                        if cls then
                            out[#out + 1] = {name = info:toString(), mat_type = mt, mat_index = mi, class = cls}
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- the ordered material choices for a gap (respecting allowed classes + magma requirement)
local function material_choices(gap)
    local jobname = df.job_type[gap.job_type]
    local classes = JOB_CLASSES[jobname] or DEFAULT_CLASSES
    local out, seen_metal = {}, {}
    local function add(label, mt, mi, wood)
        if gap.magma_required and not is_magma_safe(mt, mi) then return end
        local safe = is_magma_safe(mt, mi)
        out[#out + 1] = {text = label .. (safe and ' [magma-safe]' or ''),
                         mat_type = mt, mat_index = mi, wood = wood}
    end
    -- a job restricted to specific materials (e.g. anvils = iron/steel only): offer just
    -- those, nothing else.
    local specific = JOB_MATERIALS[jobname]
    if specific then
        for _, id in ipairs(specific) do
            local idx = inorg(id)
            if idx then add(id:sub(1, 1) .. id:sub(2):lower(), 0, idx) end
        end
        return out
    end
    -- generics first (Rock can't be promised magma-safe: it varies by stone, so it is
    -- dropped when the building requires magma safety)
    if classes.stone and not gap.magma_required then
        out[#out + 1] = {text = 'Rock (any stone)', mat_type = 0, mat_index = -1}
    end
    if classes.wood and not gap.magma_required then
        out[#out + 1] = {text = 'Wooden', mat_type = -1, mat_index = -1, wood = true}
    end
    if classes.metal then
        for _, id in ipairs({'COPPER', 'IRON', 'STEEL'}) do
            local idx = inorg(id)
            if idx then seen_metal[idx] = true; add(id:sub(1, 1) .. id:sub(2):lower(), 0, idx) end
        end
    end
    if classes.glass then
        add('Green glass', glass('GLASS_GREEN'))
        add('Clear glass', glass('GLASS_CLEAR'))
    end
    -- then any other metal/stone you have on hand
    for _, m in ipairs(fort_materials()) do
        if classes[m.class] and not (m.class == 'metal' and seen_metal[m.mat_index]) then
            add(m.name, m.mat_type, m.mat_index)
        end
    end
    return out
end

-- ---- scanning planned buildings --------------------------------------------

-- does a manager order already produce this? Match job_type, and for tools the specific
-- tool subtype too (all tools share MakeTool, so job_type alone isn't enough).
local function has_order(job_type, subtype)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == job_type and (not subtype or subtype < 0 or o.item_subtype == subtype) then
            return true
        end
    end
    return false
end

local function item_label(item_type)
    local n = df.item_type[item_type] or 'item'
    n = n:lower():gsub('_', ' ')
    return n:sub(1, 1):upper() .. n:sub(2)
end

-- a TOOL filter (nest box, jug, pot, hive, ...) identifies its tool by item_subtype or,
-- more often, by a required tool_use. Resolve to (tooldef_idx, display name).
local function resolve_tool(f)
    local tools = df.global.world.raws.itemdefs.tools
    if f.item_subtype and f.item_subtype >= 0 and tools[f.item_subtype] then
        return f.item_subtype, tools[f.item_subtype].name
    end
    if f.has_tool_use and f.has_tool_use >= 0 then
        for i = 0, #tools - 1 do
            for _, u in ipairs(tools[i].tool_use) do
                if u == f.has_tool_use then return i, tools[i].name end
            end
        end
    end
end

-- find every needed-but-unordered planned item. Returns {gaps=..., unmakeable=...}.
-- Each gap: {name, count, job_type, order_subtype, cond_item_type, cond_subtype,
--            magma_required}. order_subtype is the item_subtype to put on the order
-- (tooldef idx for tools, else -1); cond_* describes the real item to count for the
-- "exactly 0" condition (TOOL+subtype for tools, the item_type for furniture).
local function scan()
    local need, unmakeable, un_seen = {}, {}, {}
    local function bump(key, desc, magma)
        local e = need[key]
        if not e then desc.count = 0; need[key] = desc; e = desc end
        e.count = e.count + 1
        e.magma_required = e.magma_required or magma
    end
    local function unmake(label)
        if not un_seen[label] then un_seen[label] = true; unmakeable[#unmakeable + 1] = label end
    end
    for _, bld in ipairs(df.global.world.buildings.all) do
        if bp.isPlannedBuilding(bld) then
            local bt, sub, custom = bld:getType(), bld:getSubtype(), bld:getCustomType()
            for idx = 0, bp.get_num_filters(bt, sub, custom) - 1 do
                if bp.getQueuePosition(bld, idx) > 0 then          -- slot still unfilled
                    -- getQueuePosition is 0-based; get_job_item indexes a 1-based array
                    local f = bp.get_job_item(bt, sub, custom, idx + 1)
                    if f and f.item_type and f.item_type >= 0 then
                        local magma = (f.flags2 and f.flags2.magma_safe) or false
                        if f.item_type == df.item_type.TOOL then
                            local tsub, tname = resolve_tool(f)
                            if tsub then
                                bump('TOOL:' .. tsub, {name = tname, job_type = df.job_type.MakeTool,
                                    order_subtype = tsub, cond_item_type = df.item_type.TOOL,
                                    cond_subtype = tsub}, magma)
                            else unmake('Tool') end
                        else
                            local jobname = ITEM_JOB[df.item_type[f.item_type]]
                            local jt = jobname and df.job_type[jobname]
                            if jt then
                                bump('I:' .. f.item_type, {name = item_label(f.item_type), job_type = jt,
                                    order_subtype = -1, cond_item_type = f.item_type, cond_subtype = -1}, magma)
                            else unmake(item_label(f.item_type)) end
                        end
                    end
                    if f then f:delete() end
                end
            end
        end
    end
    local gaps = {}
    for _, e in pairs(need) do
        if not has_order(e.job_type, e.order_subtype) then gaps[#gaps + 1] = e end
    end
    table.sort(gaps, function(a, b) return a.name < b.name end)
    table.sort(unmakeable)
    return {gaps = gaps, unmakeable = unmakeable}
end

-- light per-frame cache (the notify message runs often)
local cache = {frame = -1}
local function get_scan()
    local fc = df.global.world.frame_counter
    if cache.frame ~= fc then cache.frame = fc; cache.result = scan() end
    return cache.result
end

-- ---- order creation ---------------------------------------------------------

local function create_order(gap, choice)
    local mo = df.global.world.manager_orders
    local o = df.manager_order:new()
    o.id = mo.manager_order_next_id
    mo.manager_order_next_id = o.id + 1
    o.job_type = gap.job_type
    o.item_type = df.item_type.NONE             -- product is set by job_type (+ subtype)
    o.item_subtype = gap.order_subtype          -- tooldef idx for tools, else -1
    o.mat_type = choice.mat_type
    o.mat_index = choice.mat_index
    if choice.wood then o.material_category.wood = true end
    o.amount_total = ORDER_AMOUNT
    o.amount_left = ORDER_AMOUNT
    o.frequency = df.workquota_frequency_type.Daily
    o.workshop_id = -1
    o.status.validated = true
    o.status.active = true
    -- only run while we have EXACTLY 0 of this item (any material)
    o.item_conditions:insert('#', {new = df.manager_order_condition_item,
        compare_type = df.logic_condition_type.Exactly, compare_val = 0,
        item_type = gap.cond_item_type, item_subtype = gap.cond_subtype, mat_type = -1, mat_index = -1})
    mo.all:insert('#', o)
end

-- ---- dialog -----------------------------------------------------------------

-- walk the gaps one at a time, each with its material picker + Skip/Cancel
local function process(gaps, i, made)
    made = made or {}
    if i > #gaps then
        if #made > 0 then
            dfhack.println('planner-orders: created ' .. #made .. ' order(s): ' .. table.concat(made, ', '))
        end
        return
    end
    local gap = gaps[i]
    local choices = material_choices(gap)
    choices[#choices + 1] = {text = '-- Skip this item --', action = 'skip'}
    choices[#choices + 1] = {text = '-- Cancel (stop) --', action = 'cancel'}
    dlg.ListBox{
        frame_title = ('Missing: %s  (%d/%d)'):format(gap.name, i, #gaps),
        text = ('%d planned building(s) need a %s but no order makes one.\nPick a material to make %d (repeats when you hit 0):')
            :format(gap.count, gap.name, ORDER_AMOUNT)
            .. (gap.magma_required and '\nThis building requires a MAGMA-SAFE item.' or ''),
        with_filter = true,
        choices = choices,
        on_select = function(_, choice)
            if choice.action == 'cancel' then return end
            if choice.action ~= 'skip' then
                create_order(gap, choice)
                made[#made + 1] = ('%s %s'):format(choice.text:gsub(' %[magma%-safe%]', ''), gap.name:lower())
            end
            process(gaps, i + 1, made)
        end,
        on_cancel = function() end,   -- Esc = stop the whole walk
    }:show()
end

local function show_dialog()
    local result = get_scan()
    if #result.gaps == 0 then
        local extra = #result.unmakeable > 0
            and ('\n\nUnmakeable (no make-job): ' .. table.concat(result.unmakeable, ', ')) or ''
        dlg.showMessage('planner-orders', 'No planned items are missing a manager order.' .. extra)
        return
    end
    process(result.gaps, 1)
end

-- ---- notification message ---------------------------------------------------

local function message()
    if not dfhack.world.isFortressMode() then return end
    local gaps = get_scan().gaps
    if #gaps == 0 then return end
    if #gaps == 1 then return ('Planned %s has no manager order'):format(gaps[1].name:lower()) end
    return ('%d planned items have no manager order'):format(#gaps)
end

-- ---- registration (mirrors needs-tomb-notification) -------------------------

local function register()
    local n = reqscript('internal/notify/notifications')
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Notifies when a building-planner item has no manager order to produce it.'
    entry.dwarf_fn = message
    entry.on_click = show_dialog
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

-- ---- entry point ------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'list' then
    if not dfhack.world.isFortressMode() then qerror('planner-orders: load a fort first') end
    local r = scan()
    print(('planner-orders: %d gap(s):'):format(#r.gaps))
    for _, g in ipairs(r.gaps) do
        print(('  - %-16s x%d  -> %s%s'):format(g.name, g.count, df.job_type[g.job_type],
            g.magma_required and '  (magma-safe required)' or ''))
    end
    if #r.unmakeable > 0 then print('  unmakeable: ' .. table.concat(r.unmakeable, ', ')) end
    return
elseif arg == 'now' then
    if not dfhack.world.isFortressMode() then qerror('planner-orders: load a fort first') end
    show_dialog()
    return
end

register()
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register() end
end
print('planner-orders: "' .. NAME .. '" notification registered.')
print('Click it (gui/notify panel) to create manager orders for planned-building items.')
print('`planner-orders list` prints the gaps; `planner-orders now` opens the dialog.')
