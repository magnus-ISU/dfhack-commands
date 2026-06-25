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

Items with no make-job are listed as unmakeable and skipped.

When the fort has a hospital, it ALSO offers orders for the supplies a hospital needs --
splints, crutches, buckets, thread, cloth, soap, and plaster powder. Every choice names
the item it makes. Soap options are spelled out ("from tallow [animal fat]" / "from oil
[plants]") and queue their prerequisites -- the ash->lye chain, plus a render-fat order
when you pick tallow. Item supplies keep a target stock; soap/plaster are one-time batches
(their outputs can't be counted cleanly by material) you can set to repeat.

For every order it creates, if the workshop that would make it ISN'T BUILT (e.g. no Soap
Maker's Workshop, Ashery, Kiln, Loom, Farmer's Workshop, Kitchen, or the right
forge/mason's/carpenter's for the chosen material), it warns you which to build.

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
    ConstructSplint         = {wood = true, metal = true},   -- hospital supply
    ConstructCrutch         = {wood = true, metal = true},   -- hospital supply
}

-- jobs restricted to SPECIFIC materials (by inorganic raw id), overriding the class list:
-- anvils can only be forged from iron or steel. Each is offered as its own choice.
local JOB_MATERIALS = {
    ForgeAnvil = {'IRON', 'STEEL'},
}

-- Supplies a hospital wants kept stocked. When the fort has a hospital, planner-orders
-- offers an order for each of these that has none yet. Three kinds:
--   item     -- pick a material (wood/metal), keep `target` in stock
--   job      -- one production method, no material choice, keep `target` in stock
--   reaction -- a workshop reaction; choose among `options`. Reactions whose output can't
--               be counted cleanly by material (soap, plaster) are queued as a one-time
--               batch (you can set them to repeat). `chain` queues prerequisite orders.
local HOSPITAL_SUPPLIES = {
    {supply = 'Splints',  kind = 'item', job = 'ConstructSplint', cond_item = 'SPLINT', target = 5},
    {supply = 'Crutches', kind = 'item', job = 'ConstructCrutch', cond_item = 'CRUTCH', target = 5},
    {supply = 'Buckets',  kind = 'item', job = 'MakeBucket',      cond_item = 'BUCKET', target = 3},
    {supply = 'Thread',   kind = 'job',  job = 'ProcessPlants',   cond_item = 'THREAD', target = 10,
        note = 'Processed from farmable plants (e.g. pig tails) at a Farmer\'s Workshop.'},
    {supply = 'Cloth',    kind = 'job',  job = 'WeaveCloth',      cond_item = 'CLOTH',  target = 10,
        note = 'Woven from thread at a Loom.'},
    {supply = 'Soap', kind = 'reaction', target = 5, makes = 'soap (a bar)',
        note = 'Cleans wounds (prevents infection). Needs LYE + a fat source; each option\n'
            .. 'also queues its prerequisites (ash->lye, and rendering fat for tallow).',
        options = {
            -- `also` entries are prerequisite job_types (MakeAsh/MakeLye) or reaction codes
            -- (RENDER_FAT); each gets its own one-time batch order if not already present.
            {label = 'Soap from tallow [animal fat]', reaction = 'MAKE_SOAP_FROM_TALLOW',
                also = {'MakeAsh', 'MakeLye', 'RENDER_FAT'}},
            {label = 'Soap from oil [plants]', reaction = 'MAKE_SOAP_FROM_OIL',
                also = {'MakeAsh', 'MakeLye'}},
        }},
    {supply = 'Plaster powder', kind = 'reaction', target = 5, makes = 'plaster powder',
        note = 'For casts on broken bones. Needs GYPSUM stone (alabaster / selenite /\n'
            .. 'gypsum).',
        options = {
            {label = 'Plaster powder from gypsum', reaction = 'MAKE_PLASTER_POWDER'},
        }},
}

-- does the fort have a hospital? (hospitals are LOCATIONS, not zones)
local function hospital_exists()
    local site = dfhack.world.getCurrentSite()
    if not site then return false end
    for _, loc in ipairs(site.buildings) do
        if df.abstract_building_hospitalst:is_instance(loc) then return true end
    end
    return false
end

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
    -- each choice names the item being made, e.g. "Cabinet: Steel [magma-safe]"
    local function add(label, mt, mi, wood)
        if gap.magma_required and not is_magma_safe(mt, mi) then return end
        local safe = is_magma_safe(mt, mi)
        out[#out + 1] = {text = gap.name .. ': ' .. label .. (safe and ' [magma-safe]' or ''),
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
        out[#out + 1] = {text = gap.name .. ': Rock (any stone)', mat_type = 0, mat_index = -1}
    end
    if classes.wood and not gap.magma_required then
        out[#out + 1] = {text = gap.name .. ': Wooden', mat_type = -1, mat_index = -1, wood = true}
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

-- ---- workshop requirements (warn if the needed shop isn't built) ------------

-- jobs/reactions with a fixed workshop, keyed by job_type name OR reaction code.
-- {label, ws=workshop_type} | {fu=furnace_type} | {def=building_def code}.
local FIXED_WS = {
    MakeAsh               = {label = 'a Wood Furnace',         fu = df.furnace_type.WoodFurnace},
    MakeLye               = {label = 'an Ashery',              ws = df.workshop_type.Ashery},
    ProcessPlants         = {label = "a Farmer's Workshop",    ws = df.workshop_type.Farmers},
    WeaveCloth            = {label = 'a Loom',                 ws = df.workshop_type.Loom},
    ConstructMechanisms   = {label = "a Mechanic's Workshop",  ws = df.workshop_type.Mechanics},
    RENDER_FAT            = {label = 'a Kitchen',              ws = df.workshop_type.Kitchen},
    MAKE_SOAP_FROM_TALLOW = {label = "a Soap Maker's Workshop", def = 'SOAP_MAKER'},
    MAKE_SOAP_FROM_OIL    = {label = "a Soap Maker's Workshop", def = 'SOAP_MAKER'},
    MAKE_PLASTER_POWDER   = {label = 'a Kiln',                 fu = df.furnace_type.Kiln},
}

-- is a workshop/furnace satisfying `req` built? (req may be nil -> "no requirement")
local function ws_exists(req)
    if not req then return true end
    for _, b in ipairs(df.global.world.buildings.all) do
        local t = b:getType()
        if req.ws and t == df.building_type.Workshop and b:getSubtype() == req.ws then return true end
        if req.fu and t == df.building_type.Furnace and b:getSubtype() == req.fu then return true end
        if req.def and t == df.building_type.Workshop and b:getSubtype() == df.workshop_type.Custom then
            local d = df.building_def.find(b:getCustomType())
            if d and d.code == req.def then return true end
        end
    end
    return false
end

-- the workshop a (job-name or reaction-code) `name` runs at, given the chosen material.
-- Fixed-shop jobs/reactions use FIXED_WS; everything else routes by material class.
local function workshop_for(name, choice)
    if FIXED_WS[name] then return FIXED_WS[name] end
    if not choice then return nil end
    if name == 'MakeTool' then          -- tools: metal at the forge, else craftsdwarf's
        if not choice.wood and choice.mat_type == 0 and choice.mat_index >= 0 then
            local info = dfhack.matinfo.decode(0, choice.mat_index)
            if info and info.material.flags.IS_METAL then
                return {label = "a Metalsmith's Forge", ws = df.workshop_type.MetalsmithsForge}
            end
        end
        return {label = "a Craftsdwarf's Workshop", ws = df.workshop_type.Craftsdwarfs}
    end
    if choice.wood then return {label = "a Carpenter's Workshop", ws = df.workshop_type.Carpenters} end
    if choice.mat_type == 0 then        -- inorganic: metal -> forge, otherwise stone -> mason
        if choice.mat_index >= 0 then
            local info = dfhack.matinfo.decode(0, choice.mat_index)
            if info and info.material.flags.IS_METAL then
                return {label = "a Metalsmith's Forge", ws = df.workshop_type.MetalsmithsForge}
            end
        end
        return {label = "a Mason's Workshop", ws = df.workshop_type.Masons}
    end
    if choice.mat_type and choice.mat_type > 0 then     -- builtin glass
        return {label = 'a Glass Furnace', fu = df.furnace_type.GlassFurnace}
    end
end

-- make-jobs this tool understands, for checking EXISTING orders' workshops. FIXED_WS
-- handles fixed-shop jobs/reactions; these are the material-routed make-jobs.
local MANAGED_JOBS = {MakeTool = true, ConstructSplint = true, ConstructCrutch = true}
for _, jn in pairs(ITEM_JOB) do MANAGED_JOBS[jn] = true end

-- the workshop an existing manager order runs at (nil if it's not one we understand)
local function order_workshop(o)
    local jn = df.job_type[o.job_type]
    if jn == 'CustomReaction' then return FIXED_WS[o.reaction_name] end   -- only our reactions
    if FIXED_WS[jn] then return FIXED_WS[jn] end
    if MANAGED_JOBS[jn] then
        return workshop_for(jn, {mat_type = o.mat_type, mat_index = o.mat_index, wood = o.material_category.wood})
    end
end

-- workshops that existing orders need but which aren't built yet (sorted labels). Lets the
-- notification stay up after orders are queued until the player builds the shops to run them.
local function missing_workshops()
    local miss = {}
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local req = order_workshop(all[i])
        if req and not ws_exists(req) then miss[req.label] = true end
    end
    local list = {}
    for label in pairs(miss) do list[#list + 1] = label end
    table.sort(list)
    return list
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

-- has the fort already got an order for this hospital supply?
local function hospital_has_order(spec)
    if spec.kind == 'reaction' then
        local want = {}
        for _, o in ipairs(spec.options) do want[o.reaction] = true end
        local all = df.global.world.manager_orders.all
        for i = 0, #all - 1 do
            if all[i].job_type == df.job_type.CustomReaction and want[all[i].reaction_name] then return true end
        end
        return false
    end
    return has_order(df.job_type[spec.job], -1)
end

-- turn a HOSPITAL_SUPPLIES spec into a gap the dialog understands
local function make_hospital_gap(spec)
    local g = {name = spec.supply, kind = spec.kind, note = spec.note, amount = spec.target}
    if spec.kind == 'reaction' then
        g.options, g.chain = spec.options, spec.chain
    else
        g.job_type = df.job_type[spec.job]
        g.order_subtype = -1
        g.cond_item_type = df.item_type[spec.cond_item]
        g.cond_subtype = -1
        g.cond_compare = df.logic_condition_type.LessThan   -- keep `target` in stock
        g.cond_val = spec.target
    end
    return g
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
        if not has_order(e.job_type, e.order_subtype) then e.kind = 'build'; gaps[#gaps + 1] = e end
    end
    table.sort(gaps, function(a, b) return a.name < b.name end)
    -- when the fort has a hospital, also offer orders for the supplies it needs
    if hospital_exists() then
        for _, spec in ipairs(HOSPITAL_SUPPLIES) do
            if not hospital_has_order(spec) then gaps[#gaps + 1] = make_hospital_gap(spec) end
        end
    end
    table.sort(unmakeable)
    return {gaps = gaps, unmakeable = unmakeable, missing = missing_workshops()}
end

-- light per-frame cache (the notify message runs often)
local cache = {frame = -1}
local function get_scan()
    local fc = df.global.world.frame_counter
    if cache.frame ~= fc then cache.frame = fc; cache.result = scan() end
    return cache.result
end

-- ---- order creation ---------------------------------------------------------

-- general manager-order builder. p: job_type, [reaction_name], [item_subtype], [mat_type,
-- mat_index, wood], amount, [frequency], [cond={compare,val,item_type,item_subtype}]
local function add_order(p)
    local mo = df.global.world.manager_orders
    local o = df.manager_order:new()
    o.id = mo.manager_order_next_id
    mo.manager_order_next_id = o.id + 1
    o.job_type = p.job_type
    if p.reaction_name then o.reaction_name = p.reaction_name end
    o.item_type = df.item_type.NONE             -- product is set by job_type (+ subtype/reaction)
    o.item_subtype = p.item_subtype or -1
    o.mat_type = p.mat_type or -1
    o.mat_index = p.mat_index or -1
    if p.wood then o.material_category.wood = true end
    o.amount_total, o.amount_left = p.amount, p.amount
    o.frequency = p.frequency or df.workquota_frequency_type.Daily
    o.workshop_id = -1
    o.status.validated, o.status.active = true, true
    if p.cond then
        o.item_conditions:insert('#', {new = df.manager_order_condition_item,
            compare_type = p.cond.compare, compare_val = p.cond.val,
            item_type = p.cond.item_type, item_subtype = p.cond.item_subtype or -1,
            mat_type = -1, mat_index = -1})
    end
    mo.all:insert('#', o)       -- actually add it to the manager order list
    return o
end

-- is there already a manager order for this reaction code?
local function reaction_ordered(code)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        if all[i].job_type == df.job_type.CustomReaction and all[i].reaction_name == code then return true end
    end
    return false
end

-- item/job gap (planned buildings: make 5 at exactly 0; hospital item/job: keep `target`).
-- Returns a list of missing-workshop labels for the order just created.
local function create_order(gap, choice)
    add_order{
        job_type = gap.job_type, item_subtype = gap.order_subtype,
        mat_type = choice.mat_type, mat_index = choice.mat_index, wood = choice.wood,
        amount = gap.amount or ORDER_AMOUNT, frequency = df.workquota_frequency_type.Daily,
        cond = {compare = gap.cond_compare or df.logic_condition_type.Exactly,
                val = gap.cond_val or 0, item_type = gap.cond_item_type, item_subtype = gap.cond_subtype},
    }
    local req = workshop_for(df.job_type[gap.job_type], choice)
    if req and not ws_exists(req) then return {req.label} end
    return {}
end

-- reaction gap (soap/plaster): a one-time batch of the chosen reaction, plus the option's
-- prerequisites (`also`: job_types like MakeAsh/MakeLye, or reaction codes like RENDER_FAT),
-- each queued once if not already present. No count condition (outputs can't be counted
-- cleanly by material) -- it's a batch you can set to repeat. Returns missing-workshop labels.
local function create_reaction(gap, opt)
    local missing = {}
    local function note_ws(name)
        local req = FIXED_WS[name]
        if req and not ws_exists(req) then missing[req.label] = true end
    end
    -- the chosen soap/plaster reaction
    add_order{job_type = df.job_type.CustomReaction, reaction_name = opt.reaction,
              amount = gap.amount, frequency = df.workquota_frequency_type.OneTime}
    note_ws(opt.reaction)
    -- its prerequisites
    for _, name in ipairs(opt.also or {}) do
        local jt = df.job_type[name]
        if jt then                                      -- a job_type (MakeAsh / MakeLye)
            if not has_order(jt, -1) then
                add_order{job_type = jt, amount = gap.amount, frequency = df.workquota_frequency_type.OneTime}
            end
        elseif not reaction_ordered(name) then          -- a reaction code (RENDER_FAT)
            add_order{job_type = df.job_type.CustomReaction, reaction_name = name,
                      amount = gap.amount, frequency = df.workquota_frequency_type.OneTime}
        end
        note_ws(name)
    end
    local list = {}
    for label in pairs(missing) do list[#list + 1] = label end
    return list
end

-- ---- dialog -----------------------------------------------------------------

-- the missing workshops a reaction gap's options would need (union over options + their
-- prerequisites), as a "not built: a, b" string, or '' if all present
local function reaction_ws_warning(gap)
    local miss = {}
    for _, o in ipairs(gap.options) do
        for _, name in ipairs({o.reaction, table.unpack(o.also or {})}) do
            local req = FIXED_WS[name]
            if req and not ws_exists(req) then miss[req.label] = true end
        end
    end
    local list = {}
    for label in pairs(miss) do list[#list + 1] = label end
    table.sort(list)
    return #list > 0 and ('\n\n!! Not built yet: ' .. table.concat(list, ', ')) or ''
end

-- the choices + title + body text for a gap, by kind
local function gap_prompt(gap, i, total)
    local kind = gap.kind or 'build'
    if kind == 'reaction' then
        local choices = {}
        for _, o in ipairs(gap.options) do choices[#choices + 1] = {text = o.label, reaction = o.reaction, also = o.also} end
        return choices, ('Hospital supply: %s  (%d/%d)'):format(gap.name, i, total),
            (gap.note or '')
                .. ('\n\nMakes: %s. Queues a one-time batch of %d (set it to repeat for a steady supply):'):format(gap.makes or gap.name:lower(), gap.amount)
                .. reaction_ws_warning(gap)
    elseif kind == 'job' then
        local req = FIXED_WS[df.job_type[gap.job_type]]
        local warn = (req and not ws_exists(req)) and ('\n\n!! Not built yet: ' .. req.label) or ''
        return {{text = ('Make %s: keep ~%d in stock'):format(gap.name:lower(), gap.amount), mat_type = -1, mat_index = -1}},
            ('Hospital supply: %s  (%d/%d)'):format(gap.name, i, total), (gap.note or '') .. warn
    elseif kind == 'item' then  -- hospital item (pick material)
        return material_choices(gap), ('Hospital supply: %s  (%d/%d)'):format(gap.name, i, total),
            ('Makes %s; pick a material; keeps ~%d in stock.'):format(gap.name:lower(), gap.amount)
    else  -- planned-building gap
        return material_choices(gap), ('Missing: %s  (%d/%d)'):format(gap.name, i, total),
            ('%d planned building(s) need a %s but no order makes one.\nPick a material to make %d (repeats when you hit 0):')
                :format(gap.count, gap.name, ORDER_AMOUNT)
                .. (gap.magma_required and '\nThis building requires a MAGMA-SAFE item.' or '')
    end
end

-- walk the gaps one at a time, each with its picker + Skip/Cancel. `made` collects what
-- was created; `warns` collects missing-workshop labels across all created orders.
local function process(gaps, i, made, warns)
    made, warns = made or {}, warns or {}
    if i > #gaps then
        if #made > 0 then
            dfhack.println('planner-orders: created ' .. #made .. ' order(s): ' .. table.concat(made, ', '))
        end
        local wl = {}
        for label in pairs(warns) do wl[#wl + 1] = label end
        table.sort(wl)
        if #wl > 0 then
            local msg = 'planner-orders: build these workshops\n\n'
                .. 'These orders are queued, but the workshop to make them ISN\'T BUILT yet:\n  '
                .. table.concat(wl, '\n  ') .. '\n\nBuild them and the orders will run.'
            dfhack.printerr('planner-orders: missing workshops -> ' .. table.concat(wl, ', '))
            dlg.showMessage('', msg)
        end
        return
    end
    local gap = gaps[i]
    local choices, title, text = gap_prompt(gap, i, #gaps)
    choices[#choices + 1] = {text = '-- Skip this item --', action = 'skip'}
    choices[#choices + 1] = {text = '-- Cancel (stop) --', action = 'cancel'}
    dlg.ListBox{
        -- header goes in the window body, not on the top border
        text = title .. '\n\n' .. text, with_filter = true, choices = choices,
        on_select = function(_, choice)
            if choice.action == 'cancel' then return end
            if choice.action ~= 'skip' then
                local missing
                if (gap.kind or 'build') == 'reaction' then
                    missing = create_reaction(gap, choice)
                    made[#made + 1] = choice.text
                else
                    missing = create_order(gap, choice)
                    made[#made + 1] = (choice.text or gap.name):gsub(' %[magma%-safe%]', '')
                end
                for _, label in ipairs(missing or {}) do warns[label] = true end
            end
            process(gaps, i + 1, made, warns)
        end,
        on_cancel = function() end,   -- Esc = stop the whole walk
    }:show()
end

local function show_dialog()
    local result = get_scan()
    if #result.gaps == 0 then
        -- no gaps left, but maybe orders are queued whose workshop isn't built
        if #result.missing > 0 then
            dlg.showMessage('', 'planner-orders\n\nAll items have orders, but these workshops aren\'t built'
                .. ' yet -- the orders can\'t run until they are:\n  ' .. table.concat(result.missing, '\n  '))
        else
            local extra = #result.unmakeable > 0
                and ('\n\nUnmakeable (no make-job): ' .. table.concat(result.unmakeable, ', ')) or ''
            dlg.showMessage('', 'planner-orders\n\nNo planned items are missing a manager order.' .. extra)
        end
        return
    end
    process(result.gaps, 1)
end

-- ---- notification message ---------------------------------------------------
-- Stays up while there are gaps OR while a queued order's workshop isn't built.

local function message()
    if not dfhack.world.isFortressMode() then return end
    local r = get_scan()
    local parts = {}
    if #r.gaps == 1 then parts[#parts + 1] = r.gaps[1].name .. ' needs a manager order'
    elseif #r.gaps > 1 then parts[#parts + 1] = ('%d items/supplies need manager orders'):format(#r.gaps) end
    if #r.missing > 0 then parts[#parts + 1] = 'build ' .. table.concat(r.missing, ', ') end
    if #parts == 0 then return end
    return table.concat(parts, '; ')
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
        if (g.kind or 'build') == 'build' then
            print(('  - %-16s x%d  -> %s%s'):format(g.name, g.count, df.job_type[g.job_type],
                g.magma_required and '  (magma-safe required)' or ''))
        else
            print(('  - %-16s [hospital %s]'):format(g.name, g.kind))
        end
    end
    if #r.unmakeable > 0 then print('  unmakeable: ' .. table.concat(r.unmakeable, ', ')) end
    if #r.missing > 0 then print('  workshops needed but NOT built: ' .. table.concat(r.missing, ', ')) end
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
