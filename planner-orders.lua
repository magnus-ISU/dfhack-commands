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

Picking a material creates a manager order that makes 1 of the item in that material,
repeating daily but gated on a condition so it only runs when you have EXACTLY 0 of that
item (any material). Components work the same way: a ballista's planned slot asks for
"ballista parts", so you get a ConstructBallistaParts order. A planned traction bench asks
for the assembled TRACTION_BENCH item: a single "assemble" choice (no material) creating a
ConstructTractionBench order, gated on a table + mechanism being in stock (chain/rope can't
be one condition) -- made at a Mechanic's Workshop.

Items with no make-job are listed as unmakeable and skipped.

When the fort has a hospital, it ALSO offers orders for the supplies a hospital needs --
splints, crutches, buckets, thread, cloth, empty leather bags (to hold plaster powder),
soap, and plaster powder. These thread/cloth are the GENERAL orders (process/weave any plant,
keep a target stock). Every choice names
the item it makes. Soap options are spelled out ("from tallow [animal fat]" / "from oil
[plants]") and queue their prerequisites -- the ash->lye chain, plus a render-fat order
when you pick tallow. Item supplies keep a target stock; soap/plaster are one-time batches
(their outputs can't be counted cleanly by material) you can set to repeat.

Separately, the PIG-TAIL CLOTH CHAIN offers orders that specifically target pig tails (via
their conditions): "Pig tail thread" (Daily x5 ProcessPlants while pig tail plants > 8) and
"Pig tail cloth" (Daily x10 WeaveCloth while pig tail cloth < 30 and pig tail thread > 8) --
offered whenever you have that step's workshop AND any pig tails on hand. It's independent of
the general hospital thread/cloth, so both can exist at once.

It also runs standing-order checks and warns when a useful repeating order is missing;
accepting creates it (all conditioned so they only run when sensible):
  - Brewing: two "brew drink from plant" orders -- under 200 drinks / under 200 seeds, each
    only while you have at least 1 barrel and 1 plant.
  - Charcoal: makes 20 while you have fewer than 20 fuel bars.
  - Coke: from your bituminous coal / lignite (at a Smelter) while fuel is low.
  - Smelting: a SEPARATE ask per metal ore you have (so each ore is offered as you find it),
    smelting it while that metal < 10 bars; plus pig iron (< 10) and steel (< 100) asks
    when you have iron ore -- each checks ingredients.
  - Containers (barrels, bins, buckets, wheelbarrows): a material-picked keep-stocked order
    each (wood or metal, e.g. copper), only offered when you have a Carpenter's Workshop.
  - Cages: once any cage trap is built, a material-picked (wood/metal/glass) order keeping
    5 EMPTY cages on hand, so sprung traps always have a cage to re-arm with.
  - Soap chain: if a soap order exists but a prerequisite link (ash, lye, or rendered fat)
    has no order, create a REPEATING order for it -- ash (keep 3, needs wood), lye (keep 3,
    needs ash + an empty bucket), render fat (keep under 20 tallow, needs fat) -- so the
    chain self-sustains instead of draining a one-time batch.
  - Melting: a melt order when items are marked for melting but nothing melts them.
  - Adamantine: once you have raw adamantine, three keep-1-in-stock orders -- extract raw
    adamantine into thread (Craftsdwarf's Workshop), smelt thread into wafers (ADAMANTINE_WAFERS
    at a Smelter), and weave thread into cloth (Loom) -- each targeting adamantine specifically
    (mat 0/25) and gated so they only run while their input is on hand.

For every order it creates, if the workshop that would make it ISN'T BUILT (e.g. no Soap
Maker's Workshop, Ashery, Kiln, Loom, Farmer's Workshop, Kitchen, Still, or the right
forge/mason's/carpenter's for the chosen material), it warns you which to build.

Run `planner-orders` to register the notification (idempotent; add to dfhack.init or
magnus-scripts to load each session). `planner-orders list` prints the gaps; `planner-orders
now` opens the dialog immediately.
]]

local NAME = 'planner_orders'
local dlg = require('gui.dialogs')
local bp = require('plugins.buildingplan')

local ORDER_AMOUNT = 1
local MAGMA_TEMP = 12000          -- a material is magma-safe if it survives this (deg U)
local BREW_TARGET = 200           -- keep at least this many drinks / seeds via brewing
local BREW_AMOUNT = 30            -- brew jobs queued per cycle while under target
local COAL_MAT = 7                -- builtin material for coal bars (charcoal AND coke = fuel)
local FUEL_TARGET = 20            -- make fuel (charcoal/coke) while under this many bars
local SMELT_CAP = 10              -- stop smelting an ORE once the metal has this many bars
local METAL_CAP = 100             -- steel cap (steel isn't ore-smelted, so kept higher)
local PIG_IRON_CAP = 10           -- pig iron is an intermediate -- keep only a few

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
    TRACTION_BENCH = 'ConstructTractionBench',
    -- intentionally unmapped (no single make-job): WOOD (chopped), BAR (smelted per ore),
    -- SMALLGEM (gem-specific), INSTRUMENT (custom reactions/parts).
}

-- jobs with NO material choice: the item is assembled from component items instead.
-- The planned-building ask offers a single "assemble" choice, and the order is gated
-- on the strictly-required components being in stock (chain OR rope can't be expressed
-- as one manager condition, so that leg isn't checked).
local JOB_COMPONENTS = {
    ConstructTractionBench = {
        desc = 'a table + a mechanism + a chain/rope',
        conds = {{'AtLeast', 1, 'TABLE'}, {'AtLeast', 1, 'TRAPPARTS'}},
    },
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

-- All tools share the MakeTool job, but individual tools permit different materials (encoded in
-- their raw def flags). Most notably HARD_MAT / GLASS_MAT tools (pedestals, display cases, nest
-- boxes, jugs, pots, ...) can be made from GLASS, which the MakeTool default omits. For a
-- glass-capable tool, offer glass on top of the usual stone/wood/metal; otherwise fall back to
-- JOB_CLASSES.MakeTool.
local function tool_classes(subtype)
    local t = df.global.world.raws.itemdefs.tools[subtype]
    if t and t.flags and (t.flags.HARD_MAT or t.flags.GLASS_MAT) then
        return {stone = true, wood = true, metal = true, glass = true}
    end
    return nil
end

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
    -- buckets are handled by the general container asks (carpenter-gated material picker)
    -- Thread/Cloth here are the GENERAL orders (process/weave any plant, keep target in stock);
    -- exists_fn ignores the pig-tail-specific orders so both can coexist (see order_targets_pigtail)
    {supply = 'Thread',   kind = 'job',  job = 'ProcessPlants',   cond_item = 'THREAD', target = 10,
        exists_generic = 'ProcessPlants',
        note = 'Processed from farmable plants (e.g. pig tails) at a Farmer\'s Workshop.'},
    {supply = 'Cloth',    kind = 'job',  job = 'WeaveCloth',      cond_item = 'CLOTH',  target = 10,
        exists_generic = 'WeaveCloth',
        note = 'Woven from thread at a Loom.'},
    {supply = 'Empty leather bags', kind = 'job', job = 'ConstructBag', cond_item = 'BAG', target = 10,
        leather = true, cond_empty = true,
        note = 'Empty bags to hold plaster powder for casts (plaster is milled INTO a bag,\n'
            .. 'so without empties the plaster reaction stalls). Made from leather at a\n'
            .. 'Leather Works; keeps ~10 EMPTY bags in stock.'},
    {supply = 'Soap', kind = 'reaction', target = 30, makes = 'soap (a bar)',
        count = {item_type = 'BAR', mat_id = 'SOAP'},   -- soap bars: BAR of the SOAP material
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
    {supply = 'Plaster powder', kind = 'reaction', target = 30, makes = 'plaster powder',
        count = {item_type = 'POWDER_MISC', mat_id = 'PLASTER'},   -- POWDER_MISC of INORGANIC:PLASTER
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

-- The PIG-TAIL cloth chain (separate from the general hospital thread/cloth): orders that
-- specifically target pig tails via their conditions -- process pig tails into thread while
-- you have a surplus of plants, weave that thread into cloth. Suggested whenever you have the
-- workshop for that step AND any pig tails on hand (the exact orders are built in STANDING).

-- the pig tail's THREAD material {type, index} -- what pig-tail plant/thread/cloth items are
local function pigtail_mat()
    return dfhack.matinfo.find('PLANT:GRASS_TAIL_PIG:THREAD')
end

-- any pig tail plants on hand? (GRASS_TAIL_PIG -- the fort's thread crop)
local function pig_tails_present()
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if it:getType() == df.item_type.PLANT then
            local m = dfhack.matinfo.decode(it)
            if m and m.plant and m.plant.id == 'GRASS_TAIL_PIG' then return true end
        end
    end
    return false
end

-- is there a manager order of `job_type` that specifically targets pig tails (a condition on
-- the pig-tail thread material)? Distinguishes the pig-tail orders from the general ones.
local function order_targets_pigtail(job_type)
    local pt = pigtail_mat()
    if not pt then return false end
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == job_type then
            for _, c in ipairs(o.item_conditions) do
                if c.mat_type == pt.type and c.mat_index == pt.index then return true end
            end
        end
    end
    return false
end

-- is there a GENERAL (non-pig-tail) manager order of `job_type`? (so the general hospital
-- thread/cloth ask re-offers even while a pig-tail order exists, and vice-versa)
local function has_generic_order(job_type)
    local pt = pigtail_mat()
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == job_type then
            local pigtail = false
            for _, c in ipairs(o.item_conditions) do
                if pt and c.mat_type == pt.type and c.mat_index == pt.index then pigtail = true; break end
            end
            if not pigtail then return true end
        end
    end
    return false
end

-- The WOOL/HAIR (yarn) textile chain, mirroring the pig-tail chain but for animal fibre:
-- spin raw hair/wool into yarn thread, then weave that thread into yarn cloth. Wool/hair spans
-- every creature, so the orders target the material CLASS via the condition's flags2 (yarn /
-- hair_wool) rather than one specific material the way the pig-tail chain does.

-- raw hair/wool on hand to SPIN? Sheared wool already comes off as THREAD (that's yarn thread,
-- woven directly), so the spin step is for raw fibre that is NOT yet thread or a finished good.
local FIBRE_FINISHED = {   -- item types that are woven/finished (so NOT raw spinnable fibre)
    [df.item_type.THREAD] = true, [df.item_type.CLOTH] = true, [df.item_type.ARMOR] = true,
    [df.item_type.GLOVES] = true, [df.item_type.SHOES] = true, [df.item_type.PANTS] = true,
    [df.item_type.HELM] = true, [df.item_type.QUIVER] = true, [df.item_type.BAG] = true,
    [df.item_type.CHAIN] = true, [df.item_type.CORPSEPIECE] = true, [df.item_type.CORPSE] = true,
}
local function hair_wool_present()
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if not FIBRE_FINISHED[it:getType()] then
            local m = dfhack.matinfo.decode(it)
            if m and m.material and m.material.flags[df.material_flags.YARN] then return true end
        end
    end
    return false
end

-- yarn thread on hand to WEAVE? (spun wool/hair -- item_type THREAD, material flagged YARN)
local function yarn_thread_present()
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if it:getType() == df.item_type.THREAD then
            local m = dfhack.matinfo.decode(it)
            if m and m.material and m.material.flags[df.material_flags.YARN] then return true end
        end
    end
    return false
end

-- is there a WeaveCloth order that specifically targets YARN cloth (a condition with the yarn
-- flag)? Distinguishes it from the general / pig-tail weave orders, like order_targets_pigtail.
local function weave_targets_yarn()
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == df.job_type.WeaveCloth then
            for _, c in ipairs(o.item_conditions) do
                if c.flags2.yarn then return true end
            end
        end
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
    local classes = gap.classes or JOB_CLASSES[jobname] or DEFAULT_CLASSES
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
    SpinThread            = {label = "a Farmer's Workshop",    ws = df.workshop_type.Farmers},
    WeaveCloth            = {label = 'a Loom',                 ws = df.workshop_type.Loom},
    ConstructBag          = {label = 'a Leather Works',        ws = df.workshop_type.Leatherworks},
    ConstructMechanisms   = {label = "a Mechanic's Workshop",  ws = df.workshop_type.Mechanics},
    RENDER_FAT            = {label = 'a Kitchen',              ws = df.workshop_type.Kitchen},
    MAKE_SOAP_FROM_TALLOW = {label = "a Soap Maker's Workshop", def = 'SOAP_MAKER'},
    MAKE_SOAP_FROM_OIL    = {label = "a Soap Maker's Workshop", def = 'SOAP_MAKER'},
    MAKE_PLASTER_POWDER   = {label = 'a Kiln',                 fu = df.furnace_type.Kiln},
    BREW_DRINK_FROM_PLANT = {label = 'a Still',                ws = df.workshop_type.Still},
    ConstructTractionBench = {label = "a Mechanic's Workshop", ws = df.workshop_type.Mechanics},
    MakeCharcoal          = {label = 'a Wood Furnace',         fu = df.furnace_type.WoodFurnace},
    BITUMINOUS_COAL_TO_COKE = {label = 'a Smelter',            fu = df.furnace_type.Smelter},
    LIGNITE_TO_COKE       = {label = 'a Smelter',              fu = df.furnace_type.Smelter},
    SmeltOre              = {label = 'a Smelter',              fu = df.furnace_type.Smelter},
    ExtractMetalStrands   = {label = "a Craftsdwarf's Workshop", ws = df.workshop_type.Craftsdwarfs},
    ADAMANTINE_WAFERS     = {label = 'a Smelter',              fu = df.furnace_type.Smelter},
    PIG_IRON_MAKING       = {label = 'a Smelter',              fu = df.furnace_type.Smelter},
    STEEL_MAKING          = {label = 'a Smelter',              fu = df.furnace_type.Smelter},
    MeltMetalObject       = {label = 'a Smelter',              fu = df.furnace_type.Smelter},
}

-- a magma workshop/furnace satisfies the same requirement as its basic counterpart
-- (a Magma Forge IS a forge, a Magma Smelter IS a smelter, etc.), so having only the
-- magma version must still count as "you have that shop".
local WS_MAGMA_ALT = {[df.workshop_type.MetalsmithsForge] = df.workshop_type.MagmaForge}
local FU_MAGMA_ALT = {
    [df.furnace_type.Smelter]      = df.furnace_type.MagmaSmelter,
    [df.furnace_type.GlassFurnace] = df.furnace_type.MagmaGlassFurnace,
    [df.furnace_type.Kiln]         = df.furnace_type.MagmaKiln,
}

-- is a workshop/furnace satisfying `req` built? (req may be nil -> "no requirement")
local function ws_exists(req)
    if not req then return true end
    for _, b in ipairs(df.global.world.buildings.all) do
        local t = b:getType()
        local st = b:getSubtype()
        if req.ws and t == df.building_type.Workshop
            and (st == req.ws or st == WS_MAGMA_ALT[req.ws]) then return true end
        if req.fu and t == df.building_type.Furnace
            and (st == req.fu or st == FU_MAGMA_ALT[req.fu]) then return true end
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

-- is there already a manager order for this reaction code?
local function reaction_ordered(code)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        if all[i].job_type == df.job_type.CustomReaction and all[i].reaction_name == code then return true end
    end
    return false
end

local STANDING   -- forward decl: the standing-order producers, defined after order helpers

local function item_label(item_type)
    if df.item_type[item_type] == 'TRAPPARTS' then return 'Mechanism' end   -- game calls it a mechanism
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
    -- thread/cloth: only a GENERAL (non-pig-tail) order counts, so this ask and the separate
    -- pig-tail ask don't block each other
    if spec.exists_generic then return has_generic_order(df.job_type[spec.exists_generic]) end
    return has_order(df.job_type[spec.job], -1)
end

-- current stock of a reaction supply we can't keep-stock with a manager condition (soap,
-- plaster): count finished items in Lua by item_type + material id. Cheap enough at scan time.
local function reaction_stock(spec)
    if not spec.count then return 0 end
    local want_type = df.item_type[spec.count.item_type]
    local n = 0
    for _, it in ipairs(df.global.world.items.all) do
        if it:getType() == want_type and not it.flags.garbage_collect then
            local m = dfhack.matinfo.decode(it)
            if m and m.material and m.material.id == spec.count.mat_id then
                n = n + it:getStackSize()
            end
        end
    end
    return n
end

-- turn a supply spec (hospital or textile) into a gap the dialog understands
local function make_hospital_gap(spec)
    local g = {name = spec.supply, kind = spec.kind, note = spec.note, amount = spec.target,
               title = spec.title or 'Hospital supply'}
    if spec.kind == 'reaction' then
        g.options, g.chain = spec.options, spec.chain
    else
        g.job_type = df.job_type[spec.job]
        g.order_subtype = -1
        g.cond_item_type = df.item_type[spec.cond_item]
        g.cond_subtype = -1
        g.cond_compare = df.logic_condition_type.LessThan   -- keep `target` in stock
        g.cond_val = spec.target
        g.leather = spec.leather                            -- make it from leather
        g.cond_empty = spec.cond_empty                      -- count only EMPTY items (bags)
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
                                    cond_subtype = tsub, classes = tool_classes(tsub)}, magma)
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
            -- offer the supply when there's no order pending AND -- for the one-time soap/plaster
            -- batches we can't keep-stock with a manager condition -- you're actually low on it.
            -- This is the "script re-triggers a fresh batch when needed" approach.
            if not hospital_has_order(spec)
                and (not spec.count or reaction_stock(spec) < spec.target) then
                gaps[#gaps + 1] = make_hospital_gap(spec)
            end
        end
    end
    -- standing-order checks (brewing, fuel, smelting per-ore, barrels/bins, melting, ...).
    -- A source either yields a ready gap (it set its own kind, e.g. a material-picker 'item'
    -- gap) or a {name, note, shops, build} descriptor we wrap as a single-confirm 'standing'.
    for _, source in ipairs(STANDING) do
        for _, g in ipairs(source()) do
            gaps[#gaps + 1] = g.kind and g or {name = g.name, kind = 'standing', producer = g}
        end
    end
    table.sort(unmakeable)
    return {gaps = gaps, unmakeable = unmakeable, missing = missing_workshops()}
end

-- Cache the (expensive) scan so the ~1/second notification refresh doesn't re-walk buildings,
-- items, IN_PLAY and every manager order each time. NOTE: this is a wall-clock TTL, NOT a
-- frame-counter cache -- frame_counter advances every tick, so a per-frame cache hits only while
-- PAUSED and thrashes (full re-scan every refresh) while unpaused. Planned-item order gaps change
-- slowly, so a few seconds' staleness is fine (a queued order clears its gap within the TTL).
local SCAN_TTL_MS = 5000
local cache = {frame = nil, t = nil}
local function get_scan()
    local fc = df.global.world.frame_counter or 0
    local now = dfhack.getTickCount()
    -- reuse when no game tick has advanced since our last call (the game is PAUSED, or a second
    -- call in one frame -> nothing changed, zero work) OR when we scanned within the TTL. Only a
    -- call that is BOTH on a new frame AND past the TTL re-runs the (expensive) scan.
    if cache.result and (fc == cache.frame or (cache.t and now - cache.t < SCAN_TTL_MS)) then
        cache.frame = fc
        return cache.result
    end
    cache.frame, cache.t, cache.result = fc, now, scan()
    return cache.result
end

-- ---- order creation ---------------------------------------------------------

-- a condition spec. compare is a logic_condition_type name string.
local function C(compare, val, item_type, mat_type, mat_index, reaction_class, flags2)
    return {compare = df.logic_condition_type[compare], val = val, item_type = item_type or -1,
            item_subtype = -1, mat_type = mat_type or -1, mat_index = mat_index or -1,
            reaction_class = reaction_class, flags2 = flags2}   -- flags2: list of material-class flag names
end

-- general manager-order builder. p: job_type, [reaction_name], [item_subtype], [mat_type,
-- mat_index, wood], amount, [frequency], [cond={compare,val,item_type,item_subtype}] and/or
-- [conds={C(...), ...}] for several conditions.
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
    if p.leather then o.material_category.leather = true end
    o.amount_total, o.amount_left = p.amount, p.amount
    o.frequency = p.frequency or df.workquota_frequency_type.Daily
    if p.max_workshops then o.max_workshops = p.max_workshops end   -- cap concurrent workshops
    o.workshop_id = -1
    o.status.validated, o.status.active = true, true
    local conds = p.conds or (p.cond and {p.cond}) or {}
    for _, c in ipairs(conds) do
        o.item_conditions:insert('#', {new = df.manager_order_condition_item,
            compare_type = c.compare, compare_val = c.val,
            item_type = c.item_type or -1, item_subtype = c.item_subtype or -1,
            mat_type = c.mat_type or -1, mat_index = c.mat_index or -1,
            reaction_class = c.reaction_class or ''})
        -- `empty` counts only EMPTY items (e.g. keep N empty barrels/bins, not N total)
        if c.empty then o.item_conditions[#o.item_conditions - 1].flags1.empty = true end
        -- flags2 material-class match (yarn / hair_wool / silk / plant): count only items of that
        -- fibre class, so a "yarn cloth" order counts wool/hair cloth across every creature at once
        if c.flags2 then
            local cond = o.item_conditions[#o.item_conditions - 1]
            for _, fl in ipairs(c.flags2) do cond.flags2[fl] = true end
        end
    end
    mo.all:insert('#', o)       -- actually add it to the manager order list
    return o
end

-- item/job gap (planned buildings: make at exactly 0; hospital item/job: keep `target`).
-- Returns a list of missing-workshop labels for the order just created.
local function create_order(gap, choice)
    local comp = JOB_COMPONENTS[df.job_type[gap.job_type]]
    local conds, amount, freq
    if comp then
        -- Component-assembled item (traction bench): the finished item is ASSEMBLED IN PLACE
        -- and, once installed, still counts as an item -- so an "Exactly 0 finished item"
        -- condition would be permanently false (an installed bench blocks it) and nothing
        -- gets made. Instead make one PER unfilled planned building, gated only on the
        -- components being on hand, as a one-time batch (re-offered if more get planned).
        conds = {}
        for _, c in ipairs(comp.conds) do conds[#conds + 1] = C(c[1], c[2], df.item_type[c[3]]) end
        amount = gap.count or gap.amount or ORDER_AMOUNT
        freq = df.workquota_frequency_type.OneTime
    else
        conds = {{compare = gap.cond_compare or df.logic_condition_type.Exactly,
                  val = gap.cond_val or 0, item_type = gap.cond_item_type, item_subtype = gap.cond_subtype,
                  empty = gap.cond_empty}}
        amount = gap.amount or ORDER_AMOUNT
        freq = df.workquota_frequency_type.Daily
    end
    add_order{
        job_type = gap.job_type, item_subtype = gap.order_subtype,
        mat_type = choice.mat_type, mat_index = choice.mat_index, wood = choice.wood,
        leather = gap.leather,
        amount = amount, frequency = freq,
        conds = conds,
    }
    local req = (gap.ws_for and gap.ws_for(choice)) or workshop_for(df.job_type[gap.job_type], choice)
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
    if opt.reaction == 'MAKE_PLASTER_POWDER' then
        -- plaster: a STANDING order (not a one-time batch) matching the hand-made one -- make 1
        -- whenever plaster powder < 30 AND a GYPSUM boulder (reaction-class, any gypsum stone) and
        -- an empty bag are on hand
        local plaster = dfhack.matinfo.find('INORGANIC:PLASTER')
        local bag = C('GreaterThan', 0, df.item_type.BAG); bag.empty = true
        add_order{job_type = df.job_type.CustomReaction, reaction_name = opt.reaction,
            amount = 1, frequency = df.workquota_frequency_type.Daily,
            conds = {
                C('GreaterThan', 0, df.item_type.BOULDER, nil, nil, 'GYPSUM'),
                C('LessThan', 30, df.item_type.POWDER_MISC, plaster and plaster.type, plaster and plaster.index),
                bag,
            }}
    else
        add_order{job_type = df.job_type.CustomReaction, reaction_name = opt.reaction,
                  amount = gap.amount, frequency = df.workquota_frequency_type.OneTime}
    end
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

-- ---- standing-order producers (brewing, fuel, smelting, melting) ------------

-- the missing-workshop labels for a set of FIXED_WS keys (jobs/reactions)
local function missing_shops(keys)
    local seen, out = {}, {}
    for _, k in ipairs(keys) do
        local req = FIXED_WS[k]
        if req and not ws_exists(req) and not seen[req.label] then seen[req.label] = true; out[#out + 1] = req.label end
    end
    table.sort(out)
    return out
end

-- is there a BOULDER of inorganic `idx` on hand?
local function boulder_present(idx)
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if it:getType() == df.item_type.BOULDER and it:getMaterial() == 0 and it:getMaterialIndex() == idx then return true end
    end
    return false
end

-- distinct metal ores present as boulders -> {idx = ore inorganic, metal = primary output metal idx}
local function present_metal_ores()
    local seen, out = {}, {}
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
        if it:getType() == df.item_type.BOULDER and it:getMaterial() == 0 then
            local mi = it:getMaterialIndex()
            if mi >= 0 and not seen[mi] then
                seen[mi] = true
                local raw = df.inorganic_raw.find(mi)
                if raw and #raw.metal_ore.mat_index > 0 then
                    out[#out + 1] = {idx = mi, metal = raw.metal_ore.mat_index[0], name = raw.id}
                end
            end
        end
    end
    return out
end

-- a SmeltOre order already smelting ore inorganic `idx`?
local function smelt_order_exists(idx)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        if all[i].job_type == df.job_type.SmeltOre and all[i].mat_index == idx then return true end
    end
    return false
end

-- an order of this job_type already targeting inorganic material (mt, mi)? (used to tell an
-- adamantine WeaveCloth/ExtractMetalStrands order apart from silk/yarn/other weaves)
local function order_exists_mat(job_type, mt, mi)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == job_type and o.mat_type == mt and o.mat_index == mi then return true end
    end
    return false
end

local function melt_count()
    local n = 0
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do if it.flags.melt then n = n + 1 end end
    return n
end

local function inorg_idx(id)
    local a = df.global.world.raws.inorganics.all
    for i = 0, #a - 1 do if a[i].id == id then return i end end
end

local BAR, BOULDER = df.item_type.BAR, df.item_type.BOULDER
local Daily, OneTime = df.workquota_frequency_type.Daily, df.workquota_frequency_type.OneTime

-- readable lower-case name for an inorganic id ("LIMONITE" -> "limonite")
local function mat_name(idx)
    local raw = df.inorganic_raw.find(idx)
    return raw and raw.id:lower():gsub('_', ' ') or ('material ' .. tostring(idx))
end

-- containers offered (material-picked) when a Carpenter's Workshop is built. `tool` marks
-- a tool item (made via MakeTool with a tooldef subtype, e.g. the wheelbarrow).
local CONTAINERS = {
    {name = 'Barrels',      job = 'MakeBarrel',   item = 'BARREL'},
    {name = 'Bins',         job = 'ConstructBin', item = 'BIN'},
    {name = 'Buckets',      job = 'MakeBucket',   item = 'BUCKET'},
    {name = 'Wheelbarrows', job = 'MakeTool',     item = 'TOOL', tool = 'ITEM_TOOL_WHEELBARROW'},
}

-- the tooldef subtype index for a tool id (e.g. ITEM_TOOL_WHEELBARROW), or nil
local function tool_subtype(id)
    local tools = df.global.world.raws.itemdefs.tools
    for i = 0, #tools - 1 do if tools[i].id == id then return i end end
end

-- containers are made at a Carpenter's (wood) or a Metalsmith's Forge (metal)
local function container_ws(choice)
    if choice.wood then return {label = "a Carpenter's Workshop", ws = df.workshop_type.Carpenters} end
    return {label = "a Metalsmith's Forge", ws = df.workshop_type.MetalsmithsForge}
end

-- soap's prerequisite chain. Each link is created as a REPEATING (Daily) manager order
-- that keeps its product stocked via conditions -- so the chain self-sustains instead of
-- draining a one-time batch and silently breaking. Amounts + conditions mirror DF's own
-- suggested conditions. ASH/LYE are builtin materials (ash bars, lye liquid).
local ASH_MAT, LYE_MAT = 9, 11
local function EMPTY(c) c.empty = true; return c end   -- count only EMPTY items
local CHAIN_LINK = {
    MakeAsh = {job = 'MakeAsh', amount = 3, conds = {
        C('LessThan', 3, df.item_type.BAR, ASH_MAT),         -- keep 3 ash bars
        C('GreaterThan', 1, df.item_type.WOOD),              -- while wood is available
    }},
    MakeLye = {job = 'MakeLye', amount = 3, conds = {
        C('LessThan', 3, df.item_type.LIQUID_MISC, LYE_MAT), -- keep 3 lye
        C('GreaterThan', 0, df.item_type.BAR, ASH_MAT),      -- while ash is on hand
        EMPTY(C('GreaterThan', 0, df.item_type.BUCKET)),     -- and an empty bucket to hold it
    }},
    RENDER_FAT = {reaction = 'RENDER_FAT', amount = 30, conds = {
        C('LessThan', 20, df.item_type.GLOB),                -- keep under 20 tallow globs
        C('GreaterThan', 0, df.item_type.GLOB),              -- while fat globs are available
    }},
}
-- which links each soap reaction needs (tallow soap also renders fat)
local SOAP_CHAIN = {
    MAKE_SOAP_FROM_TALLOW = {'MakeAsh', 'MakeLye', 'RENDER_FAT'},
    MAKE_SOAP_FROM_OIL    = {'MakeAsh', 'MakeLye'},
}

-- each STANDING entry is a function returning a list of gap descriptors
-- {name, note, shops, build} for the orders currently worth offering. The smelting source
-- yields ONE gap per ore (plus pig iron / steel), so each ore is asked for as you get it.
STANDING = {
    function()   -- pig-tail thread: process pig tails into thread while plants are plentiful
        if not pig_tails_present() then return {} end
        if not ws_exists(FIXED_WS['ProcessPlants']) then return {} end   -- Farmer's Workshop
        if order_targets_pigtail(df.job_type.ProcessPlants) then return {} end
        return {{name = 'Pig tail thread', shops = {'ProcessPlants'},
            note = 'Processes pig tails into thread at a Farmer\'s Workshop -- Daily x5, running\n'
                .. 'while you have more than 8 pig tail plants (keeps a plant reserve).',
            build = function()
                local pt = pigtail_mat()
                add_order{job_type = df.job_type.ProcessPlants, amount = 5, frequency = Daily,
                    conds = {C('GreaterThan', 8, df.item_type.PLANT, pt.type, pt.index)}}
                return missing_shops({'ProcessPlants'})
            end}}
    end,
    function()   -- pig-tail cloth: weave pig-tail thread into cloth
        if not pig_tails_present() then return {} end
        if not ws_exists(FIXED_WS['WeaveCloth']) then return {} end      -- Loom
        if order_targets_pigtail(df.job_type.WeaveCloth) then return {} end
        return {{name = 'Pig tail cloth', shops = {'WeaveCloth'},
            note = 'Weaves pig tail thread into cloth at a Loom -- Daily x10, running while you\n'
                .. 'have under 30 pig tail cloth and more than 8 pig tail thread.',
            build = function()
                local pt = pigtail_mat()
                add_order{job_type = df.job_type.WeaveCloth, amount = 10, frequency = Daily,
                    conds = {C('LessThan', 30, df.item_type.CLOTH, pt.type, pt.index),
                             C('GreaterThan', 8, df.item_type.THREAD, pt.type, pt.index)}}
                return missing_shops({'WeaveCloth'})
            end}}
    end,
    function()   -- spin thread: spin raw hair/wool into yarn thread at a Farmer's Workshop
        if not hair_wool_present() then return {} end                   -- raw fibre on hand to spin
        if has_order(df.job_type.SpinThread, -1) then return {} end
        return {{name = 'Spin thread', shops = {'SpinThread'},         -- prompts the Farmer's Workshop if absent
            note = 'Spins raw hair/wool into yarn thread at a Farmer\'s Workshop -- Daily x5,\n'
                .. 'running while you have under 30 yarn thread. Offers to build the Farmer\'s\n'
                .. 'Workshop too if you don\'t have one.',
            build = function()
                add_order{job_type = df.job_type.SpinThread, amount = 5, frequency = Daily,
                    conds = {C('LessThan', 30, df.item_type.THREAD, nil, nil, nil, {'yarn'})}}
                return missing_shops({'SpinThread'})
            end}}
    end,
    function()   -- yarn cloth: weave yarn (wool/hair) thread into cloth at a Loom
        if not yarn_thread_present() then return {} end
        if not ws_exists(FIXED_WS['WeaveCloth']) then return {} end      -- Loom
        if weave_targets_yarn() then return {} end
        return {{name = 'Yarn cloth', shops = {'WeaveCloth'},
            note = 'Weaves yarn (wool/hair) thread into cloth at a Loom -- Daily x5, running\n'
                .. 'while you have under 30 yarn cloth and more than 8 yarn thread (a small batch\n'
                .. 'so it does not run the yarn thread dry).',
            build = function()
                add_order{job_type = df.job_type.WeaveCloth, amount = 5, frequency = Daily,
                    conds = {C('LessThan', 30, df.item_type.CLOTH, nil, nil, nil, {'yarn'}),
                             C('GreaterThan', 8, df.item_type.THREAD, nil, nil, nil, {'yarn'})}}
                return missing_shops({'WeaveCloth'})
            end}}
    end,
    function()   -- soap chain integrity: keep the repeating ash/lye/(fat) orders alive
        local missing, shops, names, seen = {}, {}, {}, {}
        for code, links in pairs(SOAP_CHAIN) do
            if reaction_ordered(code) then
                for _, id in ipairs(links) do
                    local link = CHAIN_LINK[id]
                    local present = link.job and has_order(df.job_type[link.job], -1)
                        or (link.reaction and reaction_ordered(link.reaction))
                    if not present and not seen[id] then
                        seen[id] = true
                        missing[#missing + 1] = link
                        shops[#shops + 1] = id
                        names[#names + 1] = id
                    end
                end
            end
        end
        if #missing == 0 then return {} end
        return {{name = 'Soap chain', shops = shops,
            note = 'Soap is queued but part of its chain has no order: ' .. table.concat(names, ', ')
                .. '.\nCreates a REPEATING order for each missing link (wood->ash->lye, and'
                .. '\nrendering fat for tallow), each kept stocked by its own conditions.',
            build = function()
                for _, link in ipairs(missing) do
                    if link.job then
                        add_order{job_type = df.job_type[link.job], amount = link.amount,
                            frequency = Daily, conds = link.conds}
                    else
                        add_order{job_type = df.job_type.CustomReaction, reaction_name = link.reaction,
                            amount = link.amount, frequency = Daily, conds = link.conds}
                    end
                end
                return missing_shops(shops)
            end}}
    end,
    function()   -- brewing: keep drinks & seeds stocked (each brew needs a barrel + a plant)
        if reaction_ordered('BREW_DRINK_FROM_PLANT') then return {} end
        return {{name = 'Brewing', shops = {'BREW_DRINK_FROM_PLANT'},
            note = 'Nothing brews plants into drink. Adds two repeating brew orders: one runs while\n'
                .. 'you have under 200 drinks, one while under 200 seeds (brewing returns seeds).\n'
                .. 'Each only runs while you have at least 1 barrel and at least 1 plant.',
            build = function()
                for _, item in ipairs({df.item_type.DRINK, df.item_type.SEEDS}) do
                    add_order{job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT',
                        amount = BREW_AMOUNT, frequency = Daily, conds = {
                            C('LessThan', BREW_TARGET, item), C('AtLeast', 1, df.item_type.BARREL),
                            C('AtLeast', 1, df.item_type.PLANT)}}
                end
                return missing_shops({'BREW_DRINK_FROM_PLANT'})
            end}}
    end,
    function()   -- charcoal: keep fuel topped up
        if has_order(df.job_type.MakeCharcoal, -1) then return {} end
        return {{name = 'Charcoal', shops = {'MakeCharcoal'},
            note = ('Makes 20 charcoal whenever you have fewer than %d fuel (charcoal/coke) bars.'):format(FUEL_TARGET),
            build = function()
                add_order{job_type = df.job_type.MakeCharcoal, amount = 20, frequency = Daily,
                    conds = {C('LessThan', FUEL_TARGET, BAR, COAL_MAT)}}
                return missing_shops({'MakeCharcoal'})
            end}}
    end,
    function()   -- coke: from bituminous coal / lignite at a Smelter while fuel is low
        if not (boulder_present(196) or boulder_present(197)) then return {} end
        if reaction_ordered('BITUMINOUS_COAL_TO_COKE') or reaction_ordered('LIGNITE_TO_COKE') then return {} end
        return {{name = 'Coke', shops = {'BITUMINOUS_COAL_TO_COKE'},
            note = ('Makes coke from your bituminous coal / lignite (at a Smelter) while you have\n'
                .. 'fewer than %d fuel bars and at least 1 of that coal.'):format(FUEL_TARGET),
            build = function()
                if boulder_present(196) then
                    add_order{job_type = df.job_type.CustomReaction, reaction_name = 'BITUMINOUS_COAL_TO_COKE',
                        amount = 20, frequency = Daily, conds = {C('AtLeast', 1, BOULDER, 0, 196), C('LessThan', FUEL_TARGET, BAR, COAL_MAT)}}
                end
                if boulder_present(197) then
                    add_order{job_type = df.job_type.CustomReaction, reaction_name = 'LIGNITE_TO_COKE',
                        amount = 20, frequency = Daily, conds = {C('AtLeast', 1, BOULDER, 0, 197), C('LessThan', FUEL_TARGET, BAR, COAL_MAT)}}
                end
                return missing_shops({'BITUMINOUS_COAL_TO_COKE'})
            end}}
    end,
    function()   -- containers (barrels/bins/buckets/wheelbarrows) -- only with a Carpenter's
        if not ws_exists{ws = df.workshop_type.Carpenters} then return {} end
        local out = {}
        for _, c in ipairs(CONTAINERS) do
            local sub = c.tool and tool_subtype(c.tool) or -1   -- wheelbarrow = a tool subtype
            if (not c.tool or sub) and not has_order(df.job_type[c.job], sub) then
                out[#out + 1] = {name = c.name, kind = 'item', title = 'Storage',
                    classes = {wood = true, metal = true},      -- wood or metal (e.g. copper)
                    ws_for = container_ws,                       -- wood -> carpenter, metal -> forge
                    job_type = df.job_type[c.job], order_subtype = sub,
                    cond_item_type = df.item_type[c.item], cond_subtype = sub,
                    -- keep ~10 EMPTY of each container available (empty = ready to fill),
                    -- rather than capping the total count
                    cond_compare = df.logic_condition_type.LessThan, cond_val = 10, cond_empty = true,
                    amount = 10}
            end
        end
        return out
    end,
    function()   -- cage traps: keep empty cages stocked so sprung traps can re-arm
        if has_order(df.job_type.MakeCage, -1) then return {} end
        local traps = 0
        for _, b in ipairs(df.global.world.buildings.other.TRAP) do
            if b.trap_type == df.trap_type.CageTrap then traps = traps + 1 end
        end
        if traps == 0 then return {} end
        return {{name = 'Cages', kind = 'item', title = 'Cage traps',
            classes = {wood = true, metal = true, glass = true},
            job_type = df.job_type.MakeCage, order_subtype = -1,
            cond_item_type = df.item_type.CAGE,
            -- keep 5 EMPTY cages on hand (a caged critter's cage can't re-arm a trap)
            cond_compare = df.logic_condition_type.LessThan, cond_val = 5, cond_empty = true,
            amount = 5}}
    end,
    function()   -- smelting: ONE ask per metal ore you have, plus pig iron and steel
        local out, have_iron_ore = {}, false
        for _, ore in ipairs(present_metal_ores()) do
            if ore.metal == inorg_idx('IRON') then have_iron_ore = true end
            if not smelt_order_exists(ore.idx) then
                local o = ore                                   -- capture for the closure
                out[#out + 1] = {name = 'Smelt ' .. mat_name(o.idx), shops = {'SmeltOre'},
                    note = ('Smelts %s into %s while you have at least 1 %s ore and under %d %s bars.')
                        :format(mat_name(o.idx), mat_name(o.metal), mat_name(o.idx), SMELT_CAP, mat_name(o.metal)),
                    build = function()
                        add_order{job_type = df.job_type.SmeltOre, mat_type = 0, mat_index = o.idx,
                            amount = 10, frequency = Daily, conds = {
                                C('AtLeast', 1, BOULDER, 0, o.idx), C('LessThan', SMELT_CAP, BAR, 0, o.metal)}}
                        return missing_shops({'SmeltOre'})
                    end}
            end
        end
        if have_iron_ore and not reaction_ordered('PIG_IRON_MAKING') then
            out[#out + 1] = {name = 'Pig iron', shops = {'PIG_IRON_MAKING'},
                note = ('Makes pig iron (needs iron + flux + fuel) while you have at least 1 iron bar\n'
                    .. 'and under %d pig iron bars. Only the iron is gated, so it starts as soon as you\n'
                    .. 'can make one -- flux/fuel are left to the workshop.'):format(PIG_IRON_CAP),
                build = function()
                    local iron, pig = inorg_idx('IRON'), inorg_idx('PIG_IRON')
                    add_order{job_type = df.job_type.CustomReaction, reaction_name = 'PIG_IRON_MAKING',
                        amount = 5, frequency = Daily, conds = {
                            C('AtLeast', 1, BAR, 0, iron), C('LessThan', PIG_IRON_CAP, BAR, 0, pig)}}
                    return missing_shops({'PIG_IRON_MAKING'})
                end}
        end
        if have_iron_ore and not reaction_ordered('STEEL_MAKING') then
            out[#out + 1] = {name = 'Steel', shops = {'STEEL_MAKING'},
                note = ('Makes steel (needs iron + pig iron + flux + fuel) while you have at least 1 of\n'
                    .. 'each metal and under %d steel bars. Only the metals are gated, so it starts as\n'
                    .. 'soon as you can make one -- flux/fuel are left to the workshop.'):format(METAL_CAP),
                build = function()
                    local iron, pig, steel = inorg_idx('IRON'), inorg_idx('PIG_IRON'), inorg_idx('STEEL')
                    add_order{job_type = df.job_type.CustomReaction, reaction_name = 'STEEL_MAKING',
                        amount = 5, frequency = Daily, conds = {
                            C('AtLeast', 1, BAR, 0, iron), C('AtLeast', 1, BAR, 0, pig),
                            C('LessThan', METAL_CAP, BAR, 0, steel)}}
                    return missing_shops({'STEEL_MAKING'})
                end}
        end
        return out
    end,
    function()   -- melting: process items marked for melting
        if melt_count() == 0 or has_order(df.job_type.MeltMetalObject, -1) then return {} end
        return {{name = 'Melting', shops = {'MeltMetalObject'},
            note = 'Some items are marked for melting but nothing is melting them. Adds a melt\n'
                .. 'order that runs while there is anything to melt.',
            build = function()
                -- the "anything to melt" condition: GreaterThan 0 with item_type = NONE, which
                -- DF reads on a melt order as "items available to melt".
                add_order{job_type = df.job_type.MeltMetalObject, amount = 30, frequency = Daily,
                    max_workshops = 1,   -- cap it at one Smelter so melting doesn't hog every shop
                    conds = {C('GreaterThan', 0, df.item_type.NONE)}}
                return missing_shops({'MeltMetalObject'})
            end}}
    end,
    function()   -- adamantine: keep 1 thread / 1 wafer / 1 cloth once you have raw adamantine
        local ADAM = 25                                   -- ADAMANTINE inorganic index
        if not boulder_present(ADAM) then return {} end   -- only while raw adamantine is on hand
        local THREAD, CLOTH = df.item_type.THREAD, df.item_type.CLOTH
        local out = {}
        -- extraction: raw adamantine -> adamantine thread (keep 1), at a Craftsdwarf's Workshop
        if not order_exists_mat(df.job_type.ExtractMetalStrands, 0, ADAM) then
            out[#out + 1] = {name = 'Adamantine thread', shops = {'ExtractMetalStrands'},
                note = 'Extracts adamantine strands from raw adamantine into thread at a\n'
                    .. "Craftsdwarf's Workshop -- keeps 1 adamantine thread in stock, running while\n"
                    .. 'you have raw adamantine to extract.',
                build = function()
                    add_order{job_type = df.job_type.ExtractMetalStrands, mat_type = 0, mat_index = ADAM,
                        amount = 1, frequency = Daily, conds = {
                            C('LessThan', 1, THREAD, 0, ADAM),      -- keep 1 adamantine thread
                            C('AtLeast', 1, BOULDER, 0, ADAM)}}     -- while raw adamantine is on hand
                    return missing_shops({'ExtractMetalStrands'})
                end}
        end
        -- wafers: smelt adamantine thread -> wafers (keep 1), via the ADAMANTINE_WAFERS reaction
        if not reaction_ordered('ADAMANTINE_WAFERS') then
            out[#out + 1] = {name = 'Adamantine wafers', shops = {'ADAMANTINE_WAFERS'},
                note = 'Smelts adamantine thread into wafers at a Smelter -- keeps 1 adamantine wafer\n'
                    .. 'in stock, running while you have adamantine thread to smelt.',
                build = function()
                    add_order{job_type = df.job_type.CustomReaction, reaction_name = 'ADAMANTINE_WAFERS',
                        amount = 1, frequency = Daily, conds = {
                            C('LessThan', 1, BAR, 0, ADAM),         -- keep 1 adamantine wafer (a bar)
                            C('GreaterThan', 0, THREAD, 0, ADAM)}}  -- while adamantine thread is on hand
                    return missing_shops({'ADAMANTINE_WAFERS'})
                end}
        end
        -- cloth: weave adamantine thread -> cloth (keep 1), at a Loom
        if not order_exists_mat(df.job_type.WeaveCloth, 0, ADAM) then
            out[#out + 1] = {name = 'Adamantine cloth', shops = {'WeaveCloth'},
                note = 'Weaves adamantine thread into cloth at a Loom -- keeps 1 adamantine cloth in\n'
                    .. 'stock, running while you have adamantine thread to weave.',
                build = function()
                    add_order{job_type = df.job_type.WeaveCloth, mat_type = 0, mat_index = ADAM,
                        amount = 1, frequency = Daily, conds = {
                            C('LessThan', 1, CLOTH, 0, ADAM),       -- keep 1 adamantine cloth
                            C('GreaterThan', 0, THREAD, 0, ADAM)}}  -- while adamantine thread is on hand
                    return missing_shops({'WeaveCloth'})
                end}
        end
        return out
    end,
}

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
        return choices, ('%s: %s  (%d/%d)'):format(gap.title or 'Hospital supply', gap.name, i, total),
            (gap.note or '')
                .. ('\n\nMakes: %s. Queues a one-time batch of %d (set it to repeat for a steady supply):'):format(gap.makes or gap.name:lower(), gap.amount)
                .. reaction_ws_warning(gap)
    elseif kind == 'job' then
        local req = FIXED_WS[df.job_type[gap.job_type]]
        local warn = (req and not ws_exists(req)) and ('\n\n!! Not built yet: ' .. req.label) or ''
        return {{text = ('Make %s: keep ~%d in stock'):format(gap.name:lower(), gap.amount), mat_type = -1, mat_index = -1}},
            ('%s: %s  (%d/%d)'):format(gap.title or 'Hospital supply', gap.name, i, total), (gap.note or '') .. warn
    elseif kind == 'item' then  -- material-picked stock item (hospital supply, container, ...)
        return material_choices(gap), ('%s: %s  (%d/%d)'):format(gap.title or 'Make', gap.name, i, total),
            ('Makes %s; pick a material; keeps ~%d in stock.'):format(gap.name:lower(), gap.amount)
    elseif kind == 'standing' then  -- a standing-order producer (brewing/fuel/smelting/melting)
        local miss = missing_shops(gap.producer.shops or {})
        local warn = #miss > 0 and ('\n\n!! Not built yet: ' .. table.concat(miss, ', ')) or ''
        return {{text = 'Create ' .. gap.name:lower() .. ' order(s)', standing = true}},
            ('%s  (%d/%d)'):format(gap.name, i, total), (gap.producer.note or '') .. warn
    else  -- planned-building gap
        local comp = JOB_COMPONENTS[df.job_type[gap.job_type]]
        if comp then    -- assembled from components: no material to pick
            local req = FIXED_WS[df.job_type[gap.job_type]]
            local warn = (req and not ws_exists(req)) and ('\n\n!! Not built yet: ' .. req.label) or ''
            return {{text = ('Assemble from %s'):format(comp.desc), mat_type = -1, mat_index = -1}},
                ('Missing: %s  (%d/%d)'):format(gap.name, i, total),
                ('%d planned building(s) need a %s but no order makes one.\nAssembled from %s (repeats when you hit 0):')
                    :format(gap.count, gap.name, comp.desc) .. warn
        end
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
                local kind = gap.kind or 'build'
                if kind == 'reaction' then
                    missing = create_reaction(gap, choice)
                    made[#made + 1] = choice.text
                elseif kind == 'standing' then
                    missing = gap.producer.build()
                    made[#made + 1] = gap.name:lower() .. ' orders'
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
            print(('  - %-16s [%s]'):format(g.name,
                g.kind == 'standing' and 'standing order' or ((g.title or 'hospital'):lower() .. ' ' .. g.kind)))
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
