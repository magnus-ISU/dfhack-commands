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
soap, plaster powder, and TRACTION BENCHES. Thread/cloth here are the GENERAL orders
(process/weave any plant, keep a target stock). Soap comes as tallow or oil and queues its
prerequisites (the ash->lye chain, plus render-fat for tallow). Most supplies are a REPEATING
order held at a target by its own conditions -- soap runs a batch of 30 whenever soap bars
drop under 10.

TRACTION BENCHES come as FOUR asks: the bench itself (a no-material "assemble" order, as
above) and one each for its table, mechanism and chain, so the parts actually get made. The
fort is held at 3 benches, counting ones already BUILT into the hospital -- those are the
point, not spare stock. The part asks appear only while benches are still wanted and you are
short of LOOSE parts (a table built into the dining hall is not a part you can use), and a
part is skipped when a planned building has already raised its own ask for the same job.

Table and mechanism are ONE-TIME batches for exactly the shortfall -- a "keep N tables in
stock" order would read the fort's existing dining tables as satisfying it and never make
anything. The CHAIN is the exception and is KEPT STOCKED, because restraints and wells spend
chains too: its condition counts only chains ON THE GROUND (the `on_ground` item flag), so
chains already bolted into a bench, well or restraint don't hold the order shut. It also
offers an UNTYPED choice alongside the metals -- a bench takes a rope or a chain, and pinning
no material lets DF weave or forge whichever it has.

The FIBRE CLOTH CHAINS (yarn and silk) offer one weave order PER KIND of thread (each
creature's wool and each spider's silk is its own material): Daily x1 WeaveCloth pinned to that
material, keeping 5 cloth of it, running only while more than 3 of that thread is on hand --
and only offered once that thread passes 3. One at a time so a batch never drains the fibre.

Separately, the PIG-TAIL CLOTH CHAIN offers orders that specifically target pig tails (via
their conditions): "Pig tail thread" (Daily x5 ProcessPlants while pig tail plants > 8) and
"Pig tail cloth" (Daily x10 WeaveCloth while pig tail cloth < 30 and pig tail thread > 8) --
offered whenever you have that step's workshop AND any pig tails on hand. It's independent of
the general hospital thread/cloth, so both can exist at once.

It also runs standing-order checks and warns when a useful repeating order is missing;
accepting creates it (all conditioned so they only run when sensible):
  - Good meals: presses sweet pods into DWARVEN SYRUP (Farmer's Workshop, while an unrotten
    sweet pod and an EMPTY barrel are on hand) and cooks LAVISH MEALS (Kitchen, while over
    100 cookable solid ingredients are in stock). A dwarf's "eat good meals" need only
    clears on a preferred food or a meal worth over 20, and a meal is worth about what its
    ingredients are -- syrup is material value 20 against plump helmet's 2.
  - Milling: cave wheat -> dwarven flour and sweet pods -> dwarven sugar (both value-20
    cooking ingredients), dimple cups -> dimple dye, one order each at a Quern/Millstone,
    gated on that plant plus an EMPTY bag. Adds a pig-tail CLOTH BAG order alongside, since
    every mill job consumes a bag. Milling returns the seeds, so it costs no seed stock.
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
  - Adamantine: a ladder, climbed one rung at a time -- keep 3 raw boulders always, then 3
    wafers (ADAMANTINE_WAFERS at a Smelter), then 3 thread (extract at a Craftsdwarf's
    Workshop), then 3 cloth (Loom), then 9 wafers for a true adamantine throne, and everything
    past that stays a raw boulder. Thread is the input to both wafers and cloth, so a rung that
    needs thread and has none asks for extraction first -- the same rung taking its first step.
    The boulder reserve is a floor, never a target: it is what stops a lucky vein being spent
    down to the last lump. Posted as JOBS rather than manager orders, because the caps have to
    count adamantine you have set ASIDE -- a forbidden wafer is still a wafer, and an order
    gated on a condition cannot see one, so it would extract more to replace what is merely
    reserved. Say yes once and the whole ladder is managed for you thereafter.

For every order it creates, if the workshop that would make it ISN'T BUILT (e.g. no Soap
Maker's Workshop, Ashery, Kiln, Loom, Farmer's Workshop, Kitchen, Still, or the right
forge/mason's/carpenter's for the chosen material), it warns you which to build.

Every ask can be IGNORED permanently -- press `i` on it in the status screen, or
`planner-orders ignore <name>`. An ignored ask is still scanned, it is just never offered, so
un-ignoring resumes it immediately. The list survives save/reload;
`planner-orders disable` clears it.

`planner-orders gui` opens a STATUS SCREEN listing every ask this tool knows about:
    PENDING  offered right now        IGNORED  permanently dismissed
    WAITING  precondition not met     DONE     applicable, orders already exist
Enter creates the selected pending ask, `i` toggles ignore, `r` refreshes.

Run `planner-orders` to register the notification (idempotent; add to dfhack.init or
magnus-scripts to load each session). `planner-orders list` prints the gaps; `planner-orders
now` opens the dialog immediately.
]]

local NAME = 'planner_orders'

-- A few orders are offered ONCE per fort and never again. A normal "does this order exist?"
-- check would re-offer them the moment the player deletes one, which turns a helpful nudge
-- into a nag -- deleting it IS the answer. So the fact that we already offered is persisted
-- with the site instead of inferred from the order list.
-- Permanently dismissed asks, by the name the player sees. Persisted with the site: an ask
-- you have declined is a decision, not a transient state, so it must survive a reload. Kept
-- separate from the once-only flags because these are reversible (`planner-orders disable`).
local IGNORE_KEY = 'planner-orders/ignore'
local function ignore_set()
    local d = dfhack.persistent.getSiteData(IGNORE_KEY, {})
    return type(d) == 'table' and d or {}
end
local function is_ignored(name) return ignore_set()[name] == true end
local function set_ignored(name, on)
    local d = ignore_set()
    d[name] = on and true or nil
    pcall(dfhack.persistent.saveSiteData, IGNORE_KEY, d)
end
local function clear_ignores()
    local d, n = ignore_set(), 0
    for _ in pairs(d) do n = n + 1 end
    pcall(dfhack.persistent.saveSiteData, IGNORE_KEY, {})
    return n
end
local function ignored_names()
    local out = {}
    for k in pairs(ignore_set()) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local ONCE_KEY = 'planner-orders/once'
local function offered_once(flag)
    local d = dfhack.persistent.getSiteData(ONCE_KEY, {})
    return type(d) == 'table' and d[flag] == true
end
local function mark_offered(flag)
    local d = dfhack.persistent.getSiteData(ONCE_KEY, {})
    if type(d) ~= 'table' then d = {} end
    d[flag] = true
    pcall(dfhack.persistent.saveSiteData, ONCE_KEY, d)
end

-- Asks the player has handed over for good. An ask like "cut gems" is not a one-off gap, it is
-- a standing preference -- once you have said yes to cutting the surplus, saying it again every
-- time the pile creeps over the line is nagging, not helping. Accepting such an ask records the
-- decision here and the tool does the work itself from then on, silently.
local AUTO_KEY = 'planner-orders/auto'
local function auto_set()
    local d = dfhack.persistent.getSiteData(AUTO_KEY, {})
    return type(d) == 'table' and d or {}
end
local function is_auto(name) return auto_set()[name] == true end
local function set_auto(name, on)
    local d = auto_set()
    d[name] = on and true or nil
    pcall(dfhack.persistent.saveSiteData, AUTO_KEY, d)
end
local function clear_autos()
    local d, n = auto_set(), 0
    for _ in pairs(d) do n = n + 1 end
    pcall(dfhack.persistent.saveSiteData, AUTO_KEY, {})
    return n
end
local function auto_names()
    local out = {}
    for k in pairs(auto_set()) do out[#out + 1] = k end
    table.sort(out)
    return out
end

local dlg = require('gui.dialogs')
local gui = require('gui')
local widgets = require('gui.widgets')
local bp = require('plugins.buildingplan')

local ORDER_AMOUNT = 1
local MAGMA_TEMP = 12000          -- a material is magma-safe if it survives this (deg U)
local BREW_TARGET = 200           -- keep at least this many drinks / seeds via brewing
local BREW_AMOUNT = 30            -- brew jobs queued per cycle while under target
local COAL_MAT = 7                -- builtin material for coal bars (charcoal AND coke = fuel)
local FUEL_TARGET = 20            -- make fuel (charcoal/coke) while under this many bars
local SOAP_CAP = 10               -- keep this many soap bars (the standing soap order's gate)
local TRACTION_TARGET = 3         -- traction benches a hospital wants (and hence parts to build them)
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

-- items of `type_name` in the fort. `free_only` skips anything already installed as a
-- building: a table in the dining hall and a chain on a restraint are not parts you can
-- assemble anything from. Typed vectors, so this stays cheap.
local function item_stock(type_name, free_only)
    local vec = df.global.world.items.other[type_name]
    if not vec then return 0 end
    local n = 0
    for _, it in ipairs(vec) do
        if not (it.flags.garbage_collect or it.flags.removed)
            and not (free_only and it.flags.in_building) then n = n + 1 end
    end
    return n
end

-- How many more traction benches the hospital wants. Installed benches COUNT here (unlike
-- the parts above) -- a bench built into the hospital is the thing we were trying to get,
-- not a spare part sitting in a stockpile.
local function traction_shortfall()
    return math.max(0, TRACTION_TARGET - item_stock('TRACTION_BENCH', false))
end

-- A bench-part ask: offered only while benches are still wanted AND you don't have enough
-- LOOSE parts to assemble them, and it asks for exactly the shortfall. Returns nil (= don't
-- offer) rather than 0, so a fort with 30 dining tables is never nagged about tables.
local function traction_part(type_name)
    return function()
        local want = traction_shortfall()
        if want == 0 then return nil end
        local short = want - item_stock(type_name, true)
        return short > 0 and short or nil
    end
end

-- Supplies a hospital wants kept stocked. When the fort has a hospital, planner-orders
-- offers an order for each of these that has none yet. Four kinds:
--   item     -- pick a material (wood/metal), keep `target` in stock (or a one-off batch
--               with `once`, for parts you want N of exactly once)
--   job      -- one production method, no material choice, keep `target` in stock
--   assemble -- built out of other ITEMS rather than a material (traction bench); the
--               components come from JOB_COMPONENTS and gate the order
--   reaction -- a workshop reaction; choose among `options`. Soap and plaster get REPEATING
--               orders held at a target by their own conditions. `also` queues the
--               prerequisite orders an option needs.
-- `plan` (optional) computes the amount at scan time and returns nil to withhold the ask.
local HOSPITAL_SUPPLIES = {
    {supply = 'Splints',  kind = 'item', job = 'ConstructSplint', cond_item = 'SPLINT', target = 5},
    {supply = 'Crutches', kind = 'item', job = 'ConstructCrutch', cond_item = 'CRUTCH', target = 5},
    -- Traction benches, then their three parts. The bench is ASSEMBLED from items, so its
    -- ask carries no material; each part is a normal material-picked order for exactly the
    -- shortfall, offered only while benches are still wanted and the loose parts are short.
    {supply = 'Traction benches', kind = 'assemble', job = 'ConstructTractionBench',
        cond_item = 'TRACTION_BENCH', plan = traction_shortfall,
        note = 'Immobilises a patient with a broken bone so a doctor can set it -- without\n'
            .. 'one, compound fractures never heal properly. Assembled at a Mechanic\'s\n'
            .. 'Workshop from a table + a mechanism + a rope or chain; the three parts are\n'
            .. 'offered as their own asks straight after this one.'},
    {supply = 'Traction bench table', kind = 'item', job = 'ConstructTable', cond_item = 'TABLE',
        once = true, plan = traction_part('TABLE'),
        note = 'A LOOSE table for the traction bench (a table already built into a dining\n'
            .. 'hall cannot be used).'},
    {supply = 'Traction bench mechanism', kind = 'item', job = 'ConstructMechanisms',
        cond_item = 'TRAPPARTS', once = true, plan = traction_part('TRAPPARTS'),
        note = 'A mechanism for the traction bench, made at a Mechanic\'s Workshop.'},
    -- The chain is the one part kept STOCKED rather than made once: chains are spent by
    -- restraints and wells as well as benches, so a standing reserve is what stops the bench
    -- orders stalling. It counts only chains ON THE GROUND (flags3.on_ground) -- a chain bolted
    -- into a restraint or an assembled bench is not one you can build with, and counting those
    -- is exactly what would leave the order permanently satisfied and idle.
    {supply = 'Traction bench chain', kind = 'item', job = 'MakeChain', cond_item = 'CHAIN',
        target = TRACTION_TARGET, plan = traction_part('CHAIN'), cond_flags3 = {'on_ground'},
        any_material = 'Rope or chain, any material',
        note = 'The bench takes a chain OR a rope, so this offers both: a specific metal forges\n'
            .. 'a chain, and the untyped choice pins no material at all -- DF fills it with\n'
            .. 'whatever is to hand, cloth rope or metal chain alike.\n\n'
            .. ('Keeps %d LOOSE chains in stock (ones already built into a restraint, well or\n'):format(TRACTION_TARGET)
            .. 'bench do not count towards it).'},
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
        note = 'Cleans wounds. Needs lye + a fat source; queues those prerequisites too.\n'
            .. 'Repeats a batch of 30 whenever you have under 10 soap bars.',
        options = {
            -- `also` entries are prerequisite job_types (MakeAsh/MakeLye) or reaction codes
            -- (RENDER_FAT); each gets its own one-time batch order if not already present.
            -- `standing`: a repeating order gated on the soap-bar count instead of a batch.
            {label = 'Soap from tallow [animal fat]', reaction = 'MAKE_SOAP_FROM_TALLOW',
                standing = {cap = SOAP_CAP}, also = {'MakeAsh', 'MakeLye', 'RENDER_FAT'}},
            {label = 'Soap from oil [plants]', reaction = 'MAKE_SOAP_FROM_OIL',
                standing = {cap = SOAP_CAP}, also = {'MakeAsh', 'MakeLye'}},
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

-- Stock the fort can actually put into a job. An ask must never name something you do not
-- have: a suggestion that reads "you have 40 pale blue devil silk thread" when the looms have
-- none of it is worse than no suggestion, because accepting it creates an order that cannot run.
--
-- The trap that prompted this: an uncollected COBWEB is an item_threadst too -- DF stores a
-- cavern web as THREAD of the spider's silk, flagged `spider_web` -- so a naive scan reported
-- thousands of "cave spider silk thread" for a fort whose looms had ten. A web is not thread
-- until a dwarf gathers it. The rest are the ordinary "exists but is not yours to use" cases.
local function usable_stock(it)
    local f = it.flags
    return not (f.spider_web or f.forbid or f.dump or f.hostile or f.trader or f.artifact
                or f.rotten or f.garbage_collect or f.removed or f.encased or f.construction)
end

-- any pig tail plants on hand? (GRASS_TAIL_PIG -- the fort's thread crop)
local function pig_tails_present()
    for _, it in ipairs(df.global.world.items.other.PLANT) do
        if usable_stock(it) then
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
        if not FIBRE_FINISHED[it:getType()] and usable_stock(it) then
            local m = dfhack.matinfo.decode(it)
            if m and m.material and m.material.flags[df.material_flags.YARN] then return true end
        end
    end
    return false
end

-- Every distinct thread material of a fibre family (yarn, silk) in the fort, with how much of
-- it is on hand.
--
-- A fibre family is not a material: each creature's wool is its own material, and so is each
-- spider's silk, so a fort can hold three unrelated silks and two unrelated wools. One
-- class-wide weave order (matching on the yarn/silk flag) would let the loom pick whichever it
-- liked and keep re-weaving the abundant fibre while a scarcer one sat untouched -- so each
-- material gets its own order, pinned to that material the way the adamantine weave already is.
--
-- Counts sum stack_size, which is what a manager-order condition measures.
local FIBRE_MIN = 3          -- offer/run only while MORE than this much of that thread is held
local FIBRE_CLOTH_CAP = 5    -- keep this many cloth of each thread material

local FIBRE_FAMILIES = {
    {name = 'Yarn cloth', flag = df.material_flags.YARN, label = 'yarn (wool/hair)'},
    {name = 'Silk cloth', flag = df.material_flags.SILK, label = 'silk'},
}

local function fibre_threads(flag)
    local by = {}
    for _, it in ipairs(df.global.world.items.other.THREAD) do
        if usable_stock(it) then
            local m = dfhack.matinfo.decode(it)
            if m and m.material and m.material.flags[flag] then
                local key = m.type .. ':' .. m.index
                local e = by[key]
                if not e then
                    e = {type = m.type, index = m.index, name = m:toString(), n = 0}
                    by[key] = e
                end
                e.n = e.n + (it.stack_size or 1)
            end
        end
    end
    local out = {}
    for _, e in pairs(by) do out[#out + 1] = e end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
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
    -- an UNTYPED choice, offered first where the gap asks for one: no material pinned at all,
    -- so DF fills the order from whatever it has. For a traction bench chain that is the whole
    -- point -- a woven rope and a forged chain both fit, and neither is a material "class" the
    -- picker below can express.
    if gap.any_material and not gap.magma_required then
        out[#out + 1] = {text = gap.name .. ': ' .. gap.any_material, mat_type = -1, mat_index = -1}
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
    MakePotashFromAsh     = {label = 'an Ashery',              ws = df.workshop_type.Ashery},
    MAKE_PEARLASH         = {label = 'a Kiln',                 fu = df.furnace_type.Kiln},
    MakeRawGlass          = {label = 'a Glass Furnace',        fu = df.furnace_type.GlassFurnace},
    CutGlass              = {label = "a Jeweler's Workshop",  ws = df.workshop_type.Jewelers},
    CutGems               = {label = "a Jeweler's Workshop",  ws = df.workshop_type.Jewelers},
    ProcessPlants         = {label = "a Farmer's Workshop",    ws = df.workshop_type.Farmers},
    ProcessPlantsBarrel   = {label = "a Farmer's Workshop",    ws = df.workshop_type.Farmers},
    PROCESS_PLANT_TO_BAG  = {label = "a Farmer's Workshop",    ws = df.workshop_type.Farmers},
    CollectSand           = {label = 'a Glass Furnace',         fu = df.furnace_type.GlassFurnace},
    PRESS_OIL             = {label = 'a Screw Press',          def = 'SCREW_PRESS'},
    SpinThread            = {label = "a Farmer's Workshop",    ws = df.workshop_type.Farmers},
    WeaveCloth            = {label = 'a Loom',                 ws = df.workshop_type.Loom},
    ConstructBag          = {label = 'a Leather Works',        ws = df.workshop_type.Leatherworks},
    -- cloth bags are sewn at a Clothier's, not a Leather Works (same ConstructBag job, so
    -- this is a synthetic key -- order_workshop picks between them by material)
    ConstructBagCloth     = {label = "a Clothier's Shop",      ws = df.workshop_type.Clothiers},
    MillPlants            = {label = 'a Quern or Millstone',   ws = df.workshop_type.Quern,
                             ws2 = df.workshop_type.Millstone},
    PrepareMeal           = {label = 'a Kitchen',              ws = df.workshop_type.Kitchen},
    ConstructMechanisms   = {label = "a Mechanic's Workshop",  ws = df.workshop_type.Mechanics},
    ConstructTractionBench= {label = "a Mechanic's Workshop",  ws = df.workshop_type.Mechanics},
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
        -- ws2: a second workshop that satisfies the same requirement (quern OR millstone)
        if req.ws2 and t == df.building_type.Workshop and st == req.ws2 then return true end
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
    -- bags: leather ones are sewn at a Leather Works, cloth ones at a Clothier's
    if jn == 'ConstructBag' then
        return o.material_category.leather and FIXED_WS.ConstructBag or FIXED_WS.ConstructBagCloth
    end
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
local STANDING_INFO   -- forward decl: their names, assigned alongside STANDING below

local function item_label(item_type)
    if df.item_type[item_type] == 'TRAPPARTS' then return 'Mechanism' end   -- game calls it a mechanism
    local n = df.item_type[item_type] or 'item'
    n = n:lower():gsub('_', ' ')
    return n:sub(1, 1):upper() .. n:sub(2)
end

-- the tool subtypes this fort's civ knows how to make, as a set. nil = no civ to ask, which
-- means "don't filter" rather than "nothing is allowed".
local permitted_tools_cache, permitted_tools_civ
local function permitted_tools()
    local civ = df.global.plotinfo.civ_id
    if permitted_tools_cache ~= nil and permitted_tools_civ == civ then return permitted_tools_cache end
    local ent = df.historical_entity.find(civ)
    local set = nil
    if ent then
        local ok, vec = pcall(function() return ent.resources.tool_type end)
        if ok and vec and #vec > 0 then
            set = {}
            for _, st in ipairs(vec) do set[st] = true end
        end
    end
    permitted_tools_cache, permitted_tools_civ = set or false, civ
    return set
end

-- a TOOL filter (nest box, jug, pot, hive, ...) identifies its tool by item_subtype or,
-- more often, by a required tool_use. Resolve to (tooldef_idx, display name).
-- The tool_use scan takes the first def in the raws with that use, which is not necessarily
-- one this civ can make -- several races define their own jug or pot. Prefer a def the civ
-- actually knows, so the ask never offers an order no workshop here can fill.
local function resolve_tool(f)
    local tools = df.global.world.raws.itemdefs.tools
    if f.item_subtype and f.item_subtype >= 0 and tools[f.item_subtype] then
        return f.item_subtype, tools[f.item_subtype].name
    end
    if f.has_tool_use and f.has_tool_use >= 0 then
        local allowed, fallback_i, fallback_n = permitted_tools(), nil, nil
        for i = 0, #tools - 1 do
            for _, u in ipairs(tools[i].tool_use) do
                if u == f.has_tool_use then
                    if not allowed or allowed[tools[i].subtype] then return i, tools[i].name end
                    if not fallback_i then fallback_i, fallback_n = i, tools[i].name end
                end
            end
        end
        return fallback_i, fallback_n   -- nothing permitted matched: name it anyway, as before
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
local function make_hospital_gap(spec, amount)
    local g = {name = spec.supply, kind = spec.kind, note = spec.note,
               amount = amount or spec.target, title = spec.title or 'Hospital supply'}
    if spec.kind == 'reaction' then
        g.options, g.chain = spec.options, spec.chain
    else
        g.once = spec.once                                  -- one-off batch, not keep-stocked
        g.job_type = df.job_type[spec.job]
        g.order_subtype = -1
        g.cond_item_type = df.item_type[spec.cond_item]
        g.cond_subtype = -1
        g.cond_compare = df.logic_condition_type.LessThan   -- keep `target` in stock
        g.cond_val = spec.target
        g.leather = spec.leather                            -- make it from leather
        g.cond_empty = spec.cond_empty                      -- count only EMPTY items (bags)
        g.cond_flags3 = spec.cond_flags3                    -- item-state match (on_ground: loose only)
        g.any_material = spec.any_material                  -- offer an untyped "any material" choice
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
        -- a planned building may already have raised a gap for the same job (a table, a
        -- mechanism); one ask for it is enough, so don't stack a hospital one on top
        local planned_jobs = {}
        for _, g in ipairs(gaps) do if g.job_type then planned_jobs[g.job_type] = true end end
        for _, spec in ipairs(HOSPITAL_SUPPLIES) do
            -- `plan` supplies both the amount and the decision to offer at all (traction
            -- benches and their parts); everything else uses its fixed target.
            local amount = spec.plan and spec.plan() or spec.target
            -- offer the supply when there's no order pending AND -- for soap/plaster, whose
            -- stock is counted here in Lua rather than by the ask itself -- you're low on it.
            if amount and amount > 0 and not hospital_has_order(spec)
                and not (spec.job and planned_jobs[df.job_type[spec.job]])
                and (not spec.count or reaction_stock(spec) < spec.target) then
                gaps[#gaps + 1] = make_hospital_gap(spec, amount)
            end
        end
    end
    -- standing-order checks (brewing, fuel, smelting per-ore, barrels/bins, melting, ...).
    -- A source either yields a ready gap (it set its own kind, e.g. a material-picker 'item'
    -- gap) or a {name, note, shops, build} descriptor we wrap as a single-confirm 'standing'.
    local active_groups = {}
    for i, source in ipairs(STANDING) do
        local group = STANDING_INFO[i] and STANDING_INFO[i].name or ('check ' .. i)
        local produced = source()
        if #produced > 0 then active_groups[group] = true end
        for _, g in ipairs(produced) do
            local gap = g.kind and g or {name = g.name, kind = 'standing', producer = g}
            gap.group = group
            gaps[#gaps + 1] = gap
        end
    end
    -- An ignored ask still gets SCANNED -- we just do not offer it. The status screen needs
    -- to show what is being suppressed, and re-offering has to resume the moment it is
    -- un-ignored, so the decision is applied here at the end rather than inside each check.
    local offered, ignored = {}, {}
    for _, g in ipairs(gaps) do
        if is_ignored(g.name) then ignored[#ignored + 1] = g else offered[#offered + 1] = g end
    end
    table.sort(unmakeable)
    return {gaps = offered, ignored = ignored, active_groups = active_groups,
            unmakeable = unmakeable, missing = missing_workshops()}
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

-- Drop the cache so the very next read re-scans. Needed after we change something the scan
-- depends on (creating an order, ignoring an ask) -- otherwise the status screen would show a
-- stale answer for up to the TTL and look broken.
local function invalidate_scan()
    cache.frame, cache.t, cache.result = nil, nil, nil
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
        -- flags1 item-state match (unrotten / millable / processable_to_barrel / cookable /
        -- solid ...): counts only items in that state, the way DF's own hand-made orders do
        -- ("more than 100 cookable solid unrotten ingredients", "an unrotten millable plant")
        if c.flags1 then
            local cond = o.item_conditions[#o.item_conditions - 1]
            for _, fl in ipairs(c.flags1) do cond.flags1[fl] = true end
        end
        -- flags2 material-class match (yarn / hair_wool / silk / plant): count only items of that
        -- fibre class, so a "yarn cloth" order counts wool/hair cloth across every creature at once
        if c.flags2 then
            local cond = o.item_conditions[#o.item_conditions - 1]
            for _, fl in ipairs(c.flags2) do cond.flags2[fl] = true end
        end
        -- flags3 item-state match. `on_ground` is the one that matters here: it counts only
        -- items lying loose (a stockpile counts, a fitting bolted into a building does not),
        -- which is the difference between "3 chains in stock" and "3 chains already spent".
        if c.flags3 then
            local cond = o.item_conditions[#o.item_conditions - 1]
            for _, fl in ipairs(c.flags3) do cond.flags3[fl] = true end
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
    elseif gap.once then
        -- a one-off batch (traction bench parts): make exactly this many, then stop. A
        -- keep-stocked condition is wrong for these -- the fort's existing dining tables
        -- would satisfy it and nothing would ever be made.
        conds = {}
        amount = gap.amount or ORDER_AMOUNT
        freq = df.workquota_frequency_type.OneTime
    else
        conds = {{compare = gap.cond_compare or df.logic_condition_type.Exactly,
                  val = gap.cond_val or 0, item_type = gap.cond_item_type, item_subtype = gap.cond_subtype,
                  empty = gap.cond_empty, flags3 = gap.cond_flags3}}
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

-- reaction gap (soap/plaster): a repeating order for the chosen reaction, held at a target by
-- its own conditions, plus the option's prerequisites (`also`: job_types like MakeAsh/MakeLye,
-- or reaction codes like RENDER_FAT), each queued once if not already present as a one-time
-- batch the soap-chain check later turns repeating. Returns missing-workshop labels.
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
    elseif opt.standing then
        -- soap: a STANDING order matching the hand-made one -- a batch of 30 whenever soap
        -- bars run under 10. flags2.soap counts soap of ANY material, not just the builtin.
        add_order{job_type = df.job_type.CustomReaction, reaction_name = opt.reaction,
            amount = gap.amount, frequency = df.workquota_frequency_type.Daily,
            conds = {C('LessThan', opt.standing.cap, df.item_type.BAR, nil, nil, nil, {'soap'})}}
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
-- ---- posting jobs directly ---------------------------------------------------
--
-- Some asks post JOBS rather than manager orders, because a manager order's conditions cannot
-- express what they need. The one that forced this: "cut gems while more than 10 rough gems
-- remain" is a condition on item_type ROUGH, and DF counts every ROUGH item under that --
-- raw glass and raw adamantine included. This fort had 20 "rough" items and exactly ONE gem,
-- so the order was permanently satisfied and cut nothing. There is no material class for
-- "gem" in a condition, so the count has to be done here and the work posted directly.

local function find_shop(req)
    if not req then return nil end
    for _, b in ipairs(df.global.world.buildings.all) do
        local t, st = b:getType(), b:getSubtype()
        if req.ws and t == df.building_type.Workshop
            and (st == req.ws or st == WS_MAGMA_ALT[req.ws]) then return b end
        if req.ws2 and t == df.building_type.Workshop and st == req.ws2 then return b end
        if req.fu and t == df.building_type.Furnace
            and (st == req.fu or st == FU_MAGMA_ALT[req.fu]) then return b end
        if req.def and t == df.building_type.Workshop and st == df.workshop_type.Custom then
            local d = df.building_def.find(b:getCustomType())
            if d and d.code == req.def then return b end
        end
    end
end

-- how many jobs of this type are already queued anywhere in the fort, so clicking an ask
-- twice does not double the pile
local function jobs_queued(job_type, reaction)
    local n = 0
    local link = df.global.world.jobs.list.next
    while link do
        local j = link.item
        if j and j.job_type == job_type
            and (not reaction or j.reaction_name == reaction) then n = n + 1 end
        link = link.next
    end
    return n
end

-- Post one job into `shop`. `items` is a list of job_item specs; each becomes a reagent, and
-- DF fetches them the way it would for a manager-dispatched job.
local function post_job(shop, spec)
    if not shop then return nil end
    local job = dfhack.job.createLinked()
    job.job_type = spec.job_type
    job.mat_type = spec.mat_type or -1
    job.mat_index = spec.mat_index or -1
    job.item_subtype = spec.item_subtype or -1
    if spec.reaction then job.reaction_name = spec.reaction end
    for _, it in ipairs(spec.items or {}) do
        local jitem = df.job_item:new()
        jitem.item_type = it.item_type or -1
        jitem.item_subtype = it.item_subtype or -1
        jitem.mat_type = it.mat_type or -1
        jitem.mat_index = it.mat_index or -1
        jitem.quantity = it.quantity or 1
        jitem.min_dimension = it.min_dimension or -1
        if it.vector_id then jitem.vector_id = it.vector_id end
        job.job_items.elements:insert('#', jitem)
    end
    dfhack.job.assignToWorkshop(job, shop)
    return job
end

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
local POTASH_MAT, PEARLASH_MAT = 8, 10
local GLASS_CLEAR_MAT = 4        -- builtin material id for clear glass
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
local function F1(c, ...) c.flags1 = {...}; return c end   -- item-state flags on a condition
-- which links each soap reaction needs (tallow soap also renders fat)
local SOAP_CHAIN = {
    MAKE_SOAP_FROM_TALLOW = {'MakeAsh', 'MakeLye', 'RENDER_FAT'},
    MAKE_SOAP_FROM_OIL    = {'MakeAsh', 'MakeLye'},
}

-- ---- the food chain (syrup + lavish meals, milling) -------------------------

-- a plant's material by raw id and part: STRUCTURAL is the plant item itself, MILL the
-- milled product, EXTRACT the pressed/processed liquid. The MILL slot is a different
-- material index per plant (dimple dye sits in another slot than dwarven flour), so always
-- look it up instead of computing it.
local function plant_mat(id, part) return dfhack.matinfo.find('PLANT:' .. id .. ':' .. part) end

-- Is a HARVESTED plant of this crop actually on hand?
--
-- Seeds deliberately do NOT count. They used to -- the idea being "we could grow it" -- but an
-- ask should never name something the fort does not have: offering to mill cave wheat off the
-- back of a single seed puts a crop you have never harvested in front of you, and accepting
-- creates an order that cannot run. Wait until the first harvest; the ask appears then.
--
-- Only usable stock counts, for the same reason a cobweb is not thread: a plant that is
-- forbidden, dumped, a trader's, or rotting in a refuse pile is not one you can mill or press.
local function plant_stock(idx)
    for _, it in ipairs(df.global.world.items.other.PLANT) do
        if it:getMaterialIndex() == idx and usable_stock(it) then return true end
    end
    return false
end

-- plants worth grinding. Flour and sugar are material value 20 -- ten times a plump helmet --
-- which is what gets a meal over the "good meal" bar; dimple dye is for the Dyer's, not food.
-- `cap = nil` means UNCAPPED: mill it for as long as the plant and a bag are there.
-- Dwarven sugar is left uncapped on purpose. It and dwarven syrup are both material value
-- 20 and both come from the same sweet pods, so the two orders compete for one crop -- and
-- an uncapped syrup order will take every pod the moment it is harvested. Sugar is the more
-- useful of the two (it cooks into the same value without tying up a barrel), so sugar runs
-- freely and syrup is the one held to a ceiling.
local MILL_PLANTS = {
    {id = 'GRASS_WHEAT_CAVE',    plant = 'cave wheat',  makes = 'dwarven flour', cap = 30},
    {id = 'POD_SWEET',           plant = 'sweet pods',  makes = 'dwarven sugar', cap = nil},
    {id = 'MUSHROOM_CUP_DIMPLE', plant = 'dimple cups', makes = 'dimple dye',    cap = 20},
}
local SYRUP_CAP = 100      -- stop pressing syrup once this much is in stock
local ROCK_NUT_MIN = 100   -- only press nuts for oil above this many (it eats the seeds)
local GLASS_WOOD_MIN = 50  -- pearlash chain starts at wood; only offer with a real surplus
local GLASS_KEEP = 5       -- keep this many ash / potash / pearlash bars
local GLASS_BATCH = 5      -- one-time batch: raw clear glass, then cut it to gems
local ROUGH_GEM_MIN = 10   -- start cutting once the rough GEM pile is bigger than this
-- ONE cut gem job at a time, ever. A jeweler with ten queued jobs is a jeweler doing nothing
-- else, and there is no hurry: the next one is posted when this one is finished.
local ADAM_RESERVE = 3     -- adamantine: raw boulders never extracted, whatever else is short
local ADAM_KEEP = 3        -- adamantine: keep this many wafers, then thread, then cloth
local ADAM_THRONE = 9      -- ...but hold this many WAFERS once the rest is stocked and there
                           -- are this many raw boulders spare: nine is a true throne
local ADAM_BATCH = 1       -- ...one job at a time, so an order reads 1/1, not 3/3

-- Every bag-consuming order must leave a FLOOR of empty bags behind, or whichever job runs
-- first eats the last bag and starves the rest -- this fort hit 0 empty bags because milling
-- sugar kept claiming them the moment they were sewn. Three jobs compete for the pool today
-- (collect sand, process plant to bag, mill), so a floor of 5 leaves room for each plus spare;
-- if more bag users are ever added the floor grows with them.
local BAG_JOBS = 3         -- collect sand, process plant to bag, mill plants
local BAG_MIN = (BAG_JOBS > 3) and (BAG_JOBS + 1) or 5
local MILL_BAG_TARGET = 15    -- keep more empty bags than the leather-bag ask (10) wants, so
                              -- a satisfied leather order still leaves milling a bag to use

-- PrepareMeal's mat_type is the ingredient count: 2 = easy, 3 = fine, 4 = lavish
local LAVISH = 4
local function lavish_meal_ordered()
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        if all[i].job_type == df.job_type.PrepareMeal and all[i].mat_type == LAVISH then return true end
    end
    return false
end

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
    function()   -- fibre cloth: ONE weave order per kind of yarn thread and per kind of silk
        if not ws_exists(FIXED_WS['WeaveCloth']) then return {} end      -- Loom
        local asks = {}
        for _, fam in ipairs(FIBRE_FAMILIES) do
            local todo = {}
            for _, y in ipairs(fibre_threads(fam.flag)) do
                -- only once that fibre is actually accumulating: below the gate the order
                -- could never run anyway, and offering it would just be noise
                if y.n > FIBRE_MIN
                    and not order_exists_mat(df.job_type.WeaveCloth, y.type, y.index) then
                    todo[#todo + 1] = y
                end
            end
            if #todo > 0 then
                local lines = {}
                for _, y in ipairs(todo) do
                    lines[#lines + 1] = ('  * Weave %s thread -> cloth, Daily x1, while under %d %s cloth\n    and more than %d of that thread (you have %d).')
                        :format(y.name, FIBRE_CLOTH_CAP, y.name, FIBRE_MIN, y.n)
                end
                asks[#asks + 1] = {name = fam.name, shops = {'WeaveCloth'},
                    note = ('Weaves %s thread into cloth at a Loom -- one order per KIND, since every\n'):format(fam.label)
                        .. 'source has its own material and a single class-wide order would let the loom\n'
                        .. 'keep re-weaving whichever fibre happened to be most abundant while a scarcer\n'
                        .. 'one sat untouched.\n\n'
                        .. 'Each runs ONE AT A TIME, so a batch never drains the thread you were saving,\n'
                        .. 'and only while that thread is above ' .. FIBRE_MIN .. '.\n\n'
                        .. 'Creates (each only if missing):\n' .. table.concat(lines, '\n'),
                    build = function()
                        for _, y in ipairs(todo) do
                            add_order{job_type = df.job_type.WeaveCloth,
                                mat_type = y.type, mat_index = y.index, amount = 1, frequency = Daily,
                                conds = {C('LessThan', FIBRE_CLOTH_CAP, df.item_type.CLOTH, y.type, y.index),
                                         C('GreaterThan', FIBRE_MIN, df.item_type.THREAD, y.type, y.index)}}
                        end
                        return missing_shops({'WeaveCloth'})
                    end}
            end
        end
        return asks
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
    function()   -- good meals: dwarven syrup + lavish meals (the "eat good meals" need)
        local sweet = plant_mat('POD_SWEET', 'STRUCTURAL')
        if not sweet then return {} end
        -- only offer the press while sweet pods (or their seeds) are actually around
        local need_syrup = plant_stock(sweet.index)
            and not order_exists_mat(df.job_type.ProcessPlantsBarrel, sweet.type, sweet.index)
        local need_meal = not lavish_meal_ordered()
        if not (need_syrup or need_meal) then return {} end
        local shops = {}
        if need_syrup then shops[#shops + 1] = 'ProcessPlantsBarrel' end
        if need_meal then shops[#shops + 1] = 'PrepareMeal' end
        return {{name = 'Good meals', shops = shops,
            note = 'Dwarves have an "eat good meals" need (from the IMMODERATION facet). In a fort it\n'
                .. 'clears two ways only: eating a PREFERRED food (or a preferred booze cooked into a\n'
                .. 'meal), or eating any meal worth OVER 20. Unprepared food is not the problem as\n'
                .. 'such -- raw plants just are not worth enough. A meal is worth roughly what its\n'
                .. 'ingredients are worth, and plump helmets, tallow and meat are material value 2-8,\n'
                .. 'so ordinary roasts land around 2-6 per portion and never satisfy anybody. Dwarven\n'
                .. 'syrup, pressed from sweet pods, is material value 20 -- putting it in a lavish meal\n'
                .. 'is the cheapest way over the bar. This matters most for RETIRED ADVENTURERS: they\n'
                .. 'are created with no preferences at all, so meal value is their only route.\n\n'
                .. 'Creates (each only if missing):\n'
                .. ('  * Process sweet pods to barrel -> dwarven syrup, Daily x1, while under %d\n'):format(SYRUP_CAP)
                .. '    syrup, with an unrotten sweet pod and an EMPTY barrel on hand. Capped\n'
                .. '    because syrup and sugar compete for the same pods and sugar is worth more\n'
                .. '    to you; the sugar order is uncapped.\n'
                .. '  * Prepare Lavish Meal, Daily x10, while over 100 cookable solid ingredients are\n'
                .. '    in stock.',
            build = function()
                if need_syrup then
                    local syrup = plant_mat('POD_SWEET', 'EXTRACT')
                    local conds = {
                        F1(C('GreaterThan', 0, df.item_type.PLANT, sweet.type, sweet.index),
                           'unrotten', 'processable_to_barrel'),
                        EMPTY(C('GreaterThan', 0, df.item_type.BARREL))}
                    -- Ceiling on syrup: it and dwarven sugar compete for the same pods, and
                    -- without one the press takes every pod forever (this fort reached 67
                    -- barrels against 3 sugar).
                    if syrup then
                        table.insert(conds, 1,
                            C('LessThan', SYRUP_CAP, df.item_type.LIQUID_MISC, syrup.type, syrup.index))
                    end
                    add_order{job_type = df.job_type.ProcessPlantsBarrel,
                        mat_type = sweet.type, mat_index = sweet.index, amount = 1,
                        frequency = Daily, conds = conds}
                end
                if need_meal then
                    add_order{job_type = df.job_type.PrepareMeal, mat_type = LAVISH,
                        amount = 10, frequency = Daily,
                        conds = {F1(C('GreaterThan', 100, df.item_type.NONE),
                                    'unrotten', 'cookable', 'solid')}}
                end
                return missing_shops(shops)
            end}}
    end,
    function()   -- process plant to bag (quarry bush -> leaves) + the bags it consumes
        local bush = plant_mat('BUSH_QUARRY', 'STRUCTURAL')
        if not bush or not plant_stock(bush.index) then return {} end
        local need_job = not reaction_ordered('PROCESS_PLANT_TO_BAG')
        local pt = pigtail_mat()
        local need_bags = pt and pig_tails_present()
            and not order_exists_mat(df.job_type.ConstructBag, pt.type, pt.index)
        if not (need_job or need_bags) then return {} end
        local shops, lines = {}, {}
        if need_job then
            shops[#shops + 1] = 'PROCESS_PLANT_TO_BAG'
            lines[#lines + 1] = ('  * Process plant to bag, Daily x1, while an unrotten plant is on hand\n    and over %d bags are EMPTY.'):format(BAG_MIN)
        end
        if need_bags then
            shops[#shops + 1] = 'ConstructBagCloth'
            lines[#lines + 1] = ('  * Sew pig tail cloth into bags, Daily x5, while under %d empty bags and\n    pig tail cloth is on hand.'):format(MILL_BAG_TARGET)
        end
        return {{name = 'Process plant to bag', shops = shops,
            note = 'Quarry bushes process into cookable leaves and give back their rock nut\n'
                .. 'seeds.\n\n'
                .. ('Runs one at a time and only while over %d bags are empty, so it cannot strip\n'):format(BAG_MIN)
                .. 'the bags that milling and sand collection also need.\n\n'
                .. 'Creates (each only if missing):\n' .. table.concat(lines, '\n'),
            build = function()
                if need_job then
                    add_order{reaction_name = 'PROCESS_PLANT_TO_BAG',
                        job_type = df.job_type.CustomReaction, amount = 1, frequency = Daily,
                        conds = {
                            EMPTY(C('GreaterThan', BAG_MIN, df.item_type.BAG)),
                            F1(C('GreaterThan', 0, df.item_type.PLANT), 'unrotten')}}
                end
                if need_bags then
                    add_order{job_type = df.job_type.ConstructBag,
                        mat_type = pt.type, mat_index = pt.index, amount = 5, frequency = Daily,
                        conds = {
                            EMPTY(C('LessThan', MILL_BAG_TARGET, df.item_type.BAG)),
                            C('GreaterThan', 0, df.item_type.CLOTH, pt.type, pt.index)}}
                end
                return missing_shops(shops)
            end}}
    end,
    function()   -- collect sand, once there is a glass furnace to use it
        if not ws_exists(FIXED_WS['CollectSand']) then return {} end
        if has_order(df.job_type.CollectSand, -1) then return {} end
        return {{name = 'Collect sand', shops = {},
            note = 'Sand is free and endless, and each load needs an EMPTY BAG to carry it.\n\n'
                .. 'You must place a "Gather Sand" activity zone on sandy floor first -- without\n'
                .. 'one the job has nowhere to go and the order never runs.\n\n'
                .. ('Creates: Collect sand, Daily x2, while at most 10 sand is held and at least %d\n  bags are empty.'):format(BAG_MIN),
            build = function()
                add_order{job_type = df.job_type.CollectSand, amount = 2, frequency = Daily,
                    conds = {
                        F1(C('AtMost', 10, df.item_type.NONE), 'sand_bearing'),
                        EMPTY(C('AtLeast', BAG_MIN, df.item_type.BAG))}}
                return {}
            end}}
    end,
    function()   -- pearlash: the one thing clear glass needs that green glass does not
        -- Gate on the raw inputs, not the intermediates: the whole chain starts at wood, and
        -- sand only has to exist at all (the collect-sand order keeps it topped up).
        if #df.global.world.items.other.WOOD <= GLASS_WOOD_MIN then return {} end
        local sand = 0
        for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
            local ok, sb = pcall(function() return it:isSandBearing() end)
            if ok and sb then sand = sand + 1; break end
        end
        if sand == 0 then return {} end
        local need_ash    = not has_order(df.job_type.MakeAsh, -1)
        local need_potash = not has_order(df.job_type.MakePotashFromAsh, -1)
        local need_pearl  = not reaction_ordered('MAKE_PEARLASH')
        if not (need_ash or need_potash or need_pearl) then return {} end
        -- The glass batch rides along with the chain it depends on -- it never raises the ask
        -- by itself. Pearlash is the thing worth prompting about; the raw glass and the gems
        -- are just what you do with it once the chain exists. Still once per fort: delete
        -- either order and it stays deleted.
        local need_glass = not offered_once('clear_glass_batch')
        local shops, lines = {}, {}
        if need_ash then
            shops[#shops + 1] = 'MakeAsh'
            lines[#lines + 1] = ('  * Make ash from wood, while under %d ash.'):format(GLASS_KEEP)
        end
        if need_potash then
            shops[#shops + 1] = 'MakePotashFromAsh'
            lines[#lines + 1] = ('  * Make potash from ash, while under %d potash.'):format(GLASS_KEEP)
        end
        if need_pearl then
            shops[#shops + 1] = 'MAKE_PEARLASH'
            lines[#lines + 1] = ('  * Make pearlash from potash, while under %d pearlash.'):format(GLASS_KEEP)
        end
        if need_glass then
            shops[#shops + 1] = 'MakeRawGlass'
            shops[#shops + 1] = 'CutGlass'
            lines[#lines + 1] = ('  * Make %d raw clear glass (one-time).'):format(GLASS_BATCH)
            lines[#lines + 1] = ('  * Cut %d clear glass to gems (one-time). Offered once -- delete\n    them and they will not come back.'):format(GLASS_BATCH)
        end
        return {{name = 'Pearlash (clear glass)', shops = shops,
            note = 'Clear glass takes SAND + PEARLASH; green glass takes sand alone. Clear is worth\n'
                .. 'more and makes better windows, so the only thing standing between you and it is\n'
                .. 'a pearlash supply.\n\n'
                .. 'Pearlash comes off the end of a wood chain: wood -> ash (Wood Furnace) -> potash\n'
                .. '(Ashery) -> pearlash (Kiln). These orders keep each step stocked so the glass\n'
                .. 'furnace always has pearlash to hand.\n\n'
                .. (need_glass and ('It also queues a ONE-TIME batch to put the chain straight to use: %d raw clear\nglass, and %d of it cut to gems. Those two are offered once per fort -- delete them\nand they will not come back.\n\n'):format(GLASS_BATCH, GLASS_BATCH) or '')
                .. 'Creates (each only if missing):\n' .. table.concat(lines, '\n'),
            build = function()
                if need_ash then
                    add_order{job_type = df.job_type.MakeAsh, amount = 5, frequency = Daily,
                        conds = {C('LessThan', GLASS_KEEP, df.item_type.BAR, ASH_MAT),
                                 C('GreaterThan', 0, df.item_type.WOOD)}}
                end
                if need_potash then
                    add_order{job_type = df.job_type.MakePotashFromAsh, amount = 5, frequency = Daily,
                        conds = {C('LessThan', GLASS_KEEP, df.item_type.BAR, POTASH_MAT),
                                 C('GreaterThan', 0, df.item_type.BAR, ASH_MAT)}}
                end
                if need_pearl then
                    add_order{reaction_name = 'MAKE_PEARLASH',
                        job_type = df.job_type.CustomReaction, amount = 5, frequency = Daily,
                        conds = {C('LessThan', GLASS_KEEP, df.item_type.BAR, PEARLASH_MAT),
                                 C('GreaterThan', 0, df.item_type.BAR, POTASH_MAT)}}
                end
                if need_glass then
                    -- GLASS_CLEAR is a BUILTIN material (type 4, no index), not an inorganic
                    add_order{job_type = df.job_type.MakeRawGlass,
                        mat_type = GLASS_CLEAR_MAT, mat_index = -1,
                        amount = GLASS_BATCH, frequency = OneTime}
                    add_order{job_type = df.job_type.CutGlass,
                        mat_type = GLASS_CLEAR_MAT, mat_index = -1,
                        amount = GLASS_BATCH, frequency = OneTime}
                    mark_offered('clear_glass_batch')
                end
                return missing_shops(shops)
            end}}
    end,
    function()   -- cut gems: turn the rough surplus into cut stones
        -- Counted by MATERIAL, not by item type. `items.other.ROUGH` holds raw glass and raw
        -- adamantine as well as gems, and so does a manager order's ROUGH condition -- which is
        -- why the old order sat permanently satisfied on a fort with one gem in it.
        local by_mat, total = {}, 0
        for _, it in ipairs(df.global.world.items.other.ROUGH) do
            if usable_stock(it) then
                local mi = dfhack.matinfo.decode(it)
                local gem = false
                if mi then pcall(function() gem = mi.material.flags.IS_GEM end) end
                if gem then
                    local n = it.stack_size or 1
                    local key = it:getMaterialIndex()
                    by_mat[key] = (by_mat[key] or 0) + n
                    total = total + n
                end
            end
        end
        if total <= ROUGH_GEM_MIN then return {} end
        -- One at a time, always: nothing is posted while a cut gem job is still outstanding.
        if jobs_queued(df.job_type.CutGems) > 0 then return {} end

        -- post ONE job, against the biggest pile of a single gem material
        local function cut_one()
            local shop = find_shop(FIXED_WS.CutGems)
            if not shop then return missing_shops({'CutGems'}) end
            local best, best_n
            for idx, n in pairs(by_mat) do
                if not best_n or n > best_n then best, best_n = idx, n end
            end
            if not best then return end
            post_job(shop, {job_type = df.job_type.CutGems,
                items = {{item_type = df.item_type.ROUGH, mat_type = 0,
                          mat_index = best, quantity = 1}}})
        end

        -- Already answered. Cutting the surplus is a standing preference, not a fresh question
        -- every time the pile creeps back over the line -- asking again each time was the
        -- whole complaint. So do it, say nothing, and offer no gap.
        if is_auto('Cut gems') then
            cut_one()
            return {}
        end

        return {{name = 'Cut gems', shops = {'CutGems'},
            note = ('You have %d rough GEMS (DF counts %d "rough" items here -- the rest is raw\n'):format(
                    total, #df.global.world.items.other.ROUGH)
                .. 'glass and raw adamantine, which is why a manager order gated on rough stone\n'
                .. 'sits satisfied and cuts nothing). Cut gems are worth far more and are what a\n'
                .. 'jeweler encrusts with.\n\n'
                .. 'Say yes ONCE and this is handled from then on: a single Cut Gem job at the\n'
                .. 'jeweler, pinned to a gem you actually have, posted again whenever that one is\n'
                .. ('finished and the pile is still over %d. Never more than one job at a time, no\n'):format(ROUGH_GEM_MIN)
                .. 'manager order left running on a condition that cannot tell a gem from a lump\n'
                .. 'of glass, and no second ask. `planner-orders disable` hands it back.',
            build = function()
                set_auto('Cut gems')
                return cut_one()
            end}}
    end,
    function()   -- rock nut oil: only once nuts have really piled up, since it EATS the seeds
        local seed = plant_mat('BUSH_QUARRY', 'SEED')
        if not seed then return {} end
        local nuts = 0
        for _, it in ipairs(df.global.world.items.other.SEEDS) do
            if it:getMaterial() == seed.type and it:getMaterialIndex() == seed.index
                and usable_stock(it) then nuts = nuts + (it.stack_size or 1) end
        end
        if nuts <= ROCK_NUT_MIN then return {} end
        local need_paste = not reaction_ordered('MILL_SEEDS_NUTS_TO_PASTE')
        local need_press = not reaction_ordered('PRESS_OIL')
        -- soap-from-oil is only worth prompting when you have actually chosen that route
        local soap_oil = reaction_ordered('MAKE_SOAP_FROM_OIL')
        if not (need_paste or need_press) then return {} end
        local shops, lines = {}, {}
        if need_paste then
            shops[#shops + 1] = 'MillPlants'
            lines[#lines + 1] = ('  * Mill seeds/nuts to paste, Daily x1, while over %d rock nuts.'):format(ROCK_NUT_MIN)
        end
        if need_press then
            shops[#shops + 1] = 'PRESS_OIL'
            lines[#lines + 1] = ('  * Press liquid from paste -> rock nut oil, Daily x1, while over %d\n    rock nuts.'):format(ROCK_NUT_MIN)
        end
        return {{name = soap_oil and 'Rock nut oil (for your soap)' or 'Rock nut oil', shops = shops,
            note = ('You have %d rock nuts. Unlike every other dwarven crop process, this one\n'):format(nuts)
                .. 'CONSUMES the seeds rather than returning them -- rock nuts ARE the input -- so it\n'
                .. ('only offers itself once you are over %d and can spare them.\n\n'):format(ROCK_NUT_MIN)
                .. 'Two steps: mill the nuts into paste at a Quern/Millstone, then press the paste\n'
                .. 'into oil at a Screw Press. Both run ONE at a time, checked daily, so the pile\n'
                .. 'drains slowly and stops the moment it drops back under the threshold.\n\n'
                .. (soap_oil
                    and 'Your soap is set to be made FROM OIL, so this is the chain that feeds it.\n\n'
                    or 'Rock nut oil is material value 5; its main use is soap (you can also get\nsoap from tallow, which costs no seeds).\n\n')
                .. 'Creates (each only if missing):\n' .. table.concat(lines, '\n'),
            build = function()
                if need_paste then
                    add_order{reaction_name = 'MILL_SEEDS_NUTS_TO_PASTE',
                        job_type = df.job_type.CustomReaction, amount = 1, frequency = Daily,
                        conds = {C('GreaterThan', ROCK_NUT_MIN, df.item_type.SEEDS, seed.type, seed.index)}}
                end
                if need_press then
                    add_order{reaction_name = 'PRESS_OIL',
                        job_type = df.job_type.CustomReaction, amount = 1, frequency = Daily,
                        conds = {C('GreaterThan', ROCK_NUT_MIN, df.item_type.SEEDS, seed.type, seed.index)}}
                end
                return missing_shops(shops)
            end}}
    end,
    function()   -- milling: flour / sugar / dye, plus the bags every mill job consumes
        local todo = {}
        for _, m in ipairs(MILL_PLANTS) do
            local plant, prod = plant_mat(m.id, 'STRUCTURAL'), plant_mat(m.id, 'MILL')
            if plant and prod and plant_stock(plant.index)
                and not order_exists_mat(df.job_type.MillPlants, plant.type, plant.index) then
                todo[#todo + 1] = {spec = m, plant = plant, prod = prod}
            end
        end
        -- the bag leg is offered whenever milling is (or already is) happening, since a mill
        -- job with no empty bag just stalls
        local pt = pigtail_mat()
        local need_bags = pt and pig_tails_present()
            and not order_exists_mat(df.job_type.ConstructBag, pt.type, pt.index)
            and (#todo > 0 or has_order(df.job_type.MillPlants, -1))
        if #todo == 0 and not need_bags then return {} end
        local shops = {}
        if #todo > 0 then shops[#shops + 1] = 'MillPlants' end
        if need_bags then shops[#shops + 1] = 'ConstructBagCloth' end
        local lines = {}
        for _, t in ipairs(todo) do
            lines[#lines + 1] = t.spec.cap
                and ('  * Mill %s -> %s, Daily x5, while under %d %s, an unrotten\n    millable plant on hand, and over %d EMPTY bags to grind into.')
                    :format(t.spec.plant, t.spec.makes, t.spec.cap, t.spec.makes, BAG_MIN)
                or ('  * Mill %s -> %s, Daily x5, UNCAPPED -- runs while an unrotten millable\n    plant is on hand and over %d EMPTY bags to grind into.')
                    :format(t.spec.plant, t.spec.makes, BAG_MIN)
        end
        if need_bags then
            lines[#lines + 1] = ('  * Sew pig tail cloth into bags, Daily x5, while under %d empty bags and pig\n    tail cloth is on hand.')
                :format(MILL_BAG_TARGET)
        end
        return {{name = 'Milling', shops = shops,
            note = 'Milling grinds a plant into a powder, in a bag: cave wheat -> dwarven flour and\n'
                .. 'sweet pods -> dwarven sugar are both material value 20 (a plump helmet is 2), so\n'
                .. 'they are what lifts a lavish meal over the "good meal" bar; dimple cups -> dimple\n'
                .. 'dye is for dyeing thread and cloth, not for the kitchen.\n\n'
                .. 'Milling costs you NO SEEDS -- the job returns the seeds of every plant it grinds.\n'
                .. '(Cooking a raw plant is what destroys its seeds.) Each job does consume one EMPTY\n'
                .. 'bag, though, which is why the pig tail bag order comes with it.\n\n'
                .. 'Creates (each only if missing):\n' .. table.concat(lines, '\n'),
            build = function()
                for _, t in ipairs(todo) do
                    local conds = {
                        F1(C('GreaterThan', 0, df.item_type.PLANT, t.plant.type, t.plant.index),
                           'unrotten', 'millable'),
                        EMPTY(C('GreaterThan', BAG_MIN, df.item_type.BAG))}
                    if t.spec.cap then
                        table.insert(conds, 1,
                            C('LessThan', t.spec.cap, df.item_type.POWDER_MISC, t.prod.type, t.prod.index))
                    end
                    add_order{job_type = df.job_type.MillPlants,
                        mat_type = t.plant.type, mat_index = t.plant.index, amount = 5,
                        frequency = Daily, conds = conds}
                end
                if need_bags then
                    add_order{job_type = df.job_type.ConstructBag,
                        mat_type = pt.type, mat_index = pt.index, amount = 5, frequency = Daily,
                        conds = {
                            EMPTY(C('LessThan', MILL_BAG_TARGET, df.item_type.BAG)),
                            C('GreaterThan', 0, df.item_type.CLOTH, pt.type, pt.index)}}
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
    function()   -- adamantine: a priority ladder, and what is left stays raw
        -- TWO distinct inorganics: RAW_ADAMANTINE is the mined boulder (the extract INPUT);
        -- ADAMANTINE is the processed material (thread / wafer / cloth -- the products).
        local RAW, ADAM = inorg_idx('RAW_ADAMANTINE'), inorg_idx('ADAMANTINE')
        if not RAW or not ADAM then return {} end
        if not boulder_present(RAW) then return {} end    -- only while raw adamantine is on hand
        local THREAD, CLOTH = df.item_type.THREAD, df.item_type.CLOTH

        -- Posted as JOBS, not as manager orders on conditions. The caps are exactly what a
        -- condition cannot express honestly here: FORBIDDEN adamantine still counts. A
        -- forbidden wafer is stock you own -- fort/help-mood forbids items for a mood, a
        -- stockpile may hold some aside -- and a chain that ignores it extracts more boulders
        -- to replace what is only set aside. So every count below includes forbidden items,
        -- and the jobs already queued count too, so nothing is ordered twice.
        local function stock(item_type, mat_index)
            local n = 0
            for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
                if it:getType() == item_type and it:getMaterial() == 0
                    and it:getMaterialIndex() == mat_index then
                    local f = it.flags
                    -- forbidden: counted. destroyed or somebody else's: not.
                    if not (f.dump or f.garbage_collect or f.removed or f.hostile
                            or f.trader or f.foreign or f.artifact) then
                        n = n + (it.stack_size or 1)
                    end
                end
            end
            return n
        end

        local wafers   = stock(df.item_type.BAR, ADAM)
        local cloth    = stock(CLOTH, ADAM)
        local thread   = stock(THREAD, ADAM)
        local boulders = stock(df.item_type.BOULDER, RAW)
        local qw = jobs_queued(df.job_type.CustomReaction, 'ADAMANTINE_WAFERS')
        local qc = jobs_queued(df.job_type.WeaveCloth)
        local qt = jobs_queued(df.job_type.ExtractMetalStrands)

        -- The three steps as closures, so the managed path and the ask post exactly the same
        -- work. Each is a no-op without its workshop rather than an error.
        local function do_wafers(n)
            local shop = find_shop(FIXED_WS.ADAMANTINE_WAFERS)
            if shop then
                for _ = 1, n do
                    post_job(shop, {job_type = df.job_type.CustomReaction,
                                    reaction = 'ADAMANTINE_WAFERS'})
                end
            end
            return missing_shops({'ADAMANTINE_WAFERS'})
        end
        local function do_cloth(n)
            local shop = find_shop(FIXED_WS.WeaveCloth)
            if shop then
                for _ = 1, n do
                    post_job(shop, {job_type = df.job_type.WeaveCloth, mat_type = 0, mat_index = ADAM,
                        items = {{item_type = THREAD, mat_type = 0, mat_index = ADAM, quantity = 1}}})
                end
            end
            return missing_shops({'WeaveCloth'})
        end
        local function do_thread(n)
            local shop = find_shop(FIXED_WS.ExtractMetalStrands)
            if shop then
                for _ = 1, n do
                    post_job(shop, {job_type = df.job_type.ExtractMetalStrands, mat_type = 0, mat_index = RAW,
                        items = {{item_type = df.item_type.BOULDER, mat_type = 0,
                                  mat_index = RAW, quantity = 1}}})
                end
            end
            return missing_shops({'ExtractMetalStrands'})
        end

        -- THE LADDER. One rung at a time, in this order, and never more than the rung asks
        -- for:
        --
        --   1. keep %d raw boulders, always -- extraction never eats into them
        --   2. %d wafers
        --   3. %d thread
        --   4. %d cloth
        --   5. %d wafers, a true adamantine throne
        --   6. everything past that stays a raw boulder
        --
        -- Thread is the input to both wafers and cloth, so a rung that needs thread and has
        -- none asks for extraction instead -- that is not skipping ahead, it is the same rung
        -- taking its first step. Working one rung at a time is what stops the fort spending a
        -- whole vein on the first thing it can make.
        local spare = boulders - ADAM_RESERVE - qt      -- boulders extraction may still take

        local function rung()
            local function via_thread(short, kind)
                if thread > 0 then return {kind = kind, n = math.min(short, thread)} end
                return {kind = 'thread', n = short}
            end
            if wafers + qw < ADAM_KEEP then
                return via_thread(ADAM_KEEP - wafers - qw, 'wafers')
            end
            if thread + qt < ADAM_KEEP then
                return {kind = 'thread', n = ADAM_KEEP - thread - qt}
            end
            if cloth + qc < ADAM_KEEP then
                return via_thread(ADAM_KEEP - cloth - qc, 'cloth')
            end
            if wafers + qw < ADAM_THRONE then
                return via_thread(ADAM_THRONE - wafers - qw, 'wafers')
            end
        end

        local step = rung()
        if not step then return {} end
        if step.kind == 'thread' then
            -- the boulder reserve is a floor, not a target: it is the one rung that is never
            -- spent, so a lucky vein is not turned into furniture down to the last lump
            step.n = math.min(step.n, spare)
            if step.n <= 0 then return {} end
        end

        local WHERE = {wafers = 'Adamantine wafers', cloth = 'Adamantine cloth',
                       thread = 'Adamantine thread'}
        local SHOP = {wafers = 'ADAMANTINE_WAFERS', cloth = 'WeaveCloth',
                      thread = 'ExtractMetalStrands'}
        local DO = {wafers = do_wafers, cloth = do_cloth, thread = do_thread}

        -- Handed over for good, like cut gems. This chain HAS to be run by posting jobs rather
        -- than by manager orders -- the caps count adamantine you have set aside, and a
        -- condition cannot see a forbidden wafer -- which means the work only happens when
        -- something posts it. Asking again every time the stock dips is asking the same
        -- question over and over; saying yes once says it for the whole ladder.
        if is_auto('Adamantine') then
            DO[step.kind](step.n)
            return {}
        end

        local ladder = ('  1. keep %d raw boulders, always\n'):format(ADAM_RESERVE)
            .. ('  2. %d wafers\n'):format(ADAM_KEEP)
            .. ('  3. %d thread\n'):format(ADAM_KEEP)
            .. ('  4. %d cloth\n'):format(ADAM_KEEP)
            .. ('  5. %d wafers -- a true adamantine throne\n'):format(ADAM_THRONE)
            .. '  6. the rest stays raw\n'
        return {{name = WHERE[step.kind], shops = {SHOP[step.kind]},
            note = ('You have %d wafers, %d thread, %d cloth, %d raw boulders (forbidden\ncounted).\n\n'):format(
                    wafers, thread, cloth, boulders)
                .. 'The adamantine ladder, one rung at a time:\n' .. ladder .. '\n'
                .. ('Creates: %d %s JOB(S) -- the next rung.\n\n'):format(step.n, WHERE[step.kind]:lower())
                .. 'Posted as jobs rather than a repeating order so the caps can count stock you\n'
                .. 'have set aside -- a forbidden wafer is still a wafer, and an order that\n'
                .. 'cannot see it would mine and extract more to replace it.\n\n'
                .. 'Say yes ONCE and the whole ladder is handled from then on, with nothing more\n'
                .. 'asked. `planner-orders disable` hands it back.',
            build = function()
                set_auto('Adamantine')
                return DO[step.kind](step.n)
            end}}
    end,
}

-- Names for the standing checks above, in the same order, so the status screen can list every
-- ask this tool knows about -- including the ones that produced nothing this scan. `ready` is
-- an optional cheap re-test of the check's own precondition: false means "not applicable yet",
-- absent means "assume applicable", which lets the screen tell WAITING apart from DONE.
STANDING_INFO = {
    {name = 'Pig tail thread',        blocked = function()
        if not pig_tails_present() then return 'no pig tail plants on hand' end end,
                                      done  = function() return order_targets_pigtail(df.job_type.ProcessPlants) end},
    {name = 'Pig tail cloth',         blocked = function()
        if not pig_tails_present() then return 'no pig tail plants on hand' end end,
                                      done  = function() return order_targets_pigtail(df.job_type.WeaveCloth) end},
    {name = 'Spin thread',            blocked = function()
        if not hair_wool_present() then return 'no raw wool or hair to spin' end end,
                                      done  = function() return has_order(df.job_type.SpinThread, -1) end},
    {name = 'Fibre cloth',            blocked = function()
        if not ws_exists(FIXED_WS['WeaveCloth']) then return 'no Loom built' end end},
    {name = 'Soap chain'},
    {name = 'Good meals'},
    {name = 'Process plant to bag',   blocked = function()
        local b = plant_mat('BUSH_QUARRY', 'STRUCTURAL')
        if not (b and plant_stock(b.index)) then return 'no quarry bushes on hand' end end,
                                      done  = function() return reaction_ordered('PROCESS_PLANT_TO_BAG') end},
    {name = 'Collect sand',           blocked = function()
        if not ws_exists(FIXED_WS['CollectSand']) then return 'no Glass Furnace built' end end,
                                      done  = function() return has_order(df.job_type.CollectSand, -1) end},
    {name = 'Pearlash (clear glass)', done  = function()
        return has_order(df.job_type.MakePotashFromAsh, -1) and reaction_ordered('MAKE_PEARLASH') end,
                                      blocked = function()
        local w = #df.global.world.items.other.WOOD
        if w <= GLASS_WOOD_MIN then
            return ('only %d wood logs, needs over %d'):format(w, GLASS_WOOD_MIN) end end},
    -- counted by MATERIAL and judged by queued JOBS, matching the ask itself. Counting
    -- `items.other.ROUGH` here reported "19 rough gems" for a fort holding one, because
    -- raw glass and raw adamantine are ROUGH items too.
    {name = 'Cut gems',               done  = function()
        -- managed counts as done: there is no gap to chase, the tool posts the jobs
        return is_auto('Cut gems') or jobs_queued(df.job_type.CutGems) > 0 end,
                                      blocked = function()
        local n = 0
        for _, it in ipairs(df.global.world.items.other.ROUGH) do
            if usable_stock(it) then
                local mi = dfhack.matinfo.decode(it)
                local gem = false
                if mi then pcall(function() gem = mi.material.flags.IS_GEM end) end
                if gem then n = n + (it.stack_size or 1) end
            end
        end
        if n <= ROUGH_GEM_MIN then
            return ('only %d rough gems, needs over %d'):format(n, ROUGH_GEM_MIN) end end},
    {name = 'Rock nut oil',           done  = function()
        return reaction_ordered('MILL_SEEDS_NUTS_TO_PASTE') and reaction_ordered('PRESS_OIL') end,
                                      blocked = function()
        local sd = plant_mat('BUSH_QUARRY', 'SEED')
        if not sd then return 'no quarry bush in this world' end
        local n = 0
        for _, it in ipairs(df.global.world.items.other.SEEDS) do
            if it:getMaterial() == sd.type and it:getMaterialIndex() == sd.index
                and usable_stock(it) then n = n + (it.stack_size or 1) end
        end
        if n <= ROCK_NUT_MIN then
            return ('only %d rock nuts, needs over %d'):format(n, ROCK_NUT_MIN) end end},
    {name = 'Milling'},
    {name = 'Brewing'},
    {name = 'Charcoal',               blocked = function()
        if #df.global.world.items.other.WOOD == 0 then return 'no wood to burn' end end},
    {name = 'Coke'},
    {name = 'Containers',             blocked = function()
        if not ws_exists{ws = df.workshop_type.Carpenters} then
            return "no Carpenter's Workshop built" end end},
    {name = 'Cages'},
    {name = 'Smelting'},
    {name = 'Melting',                blocked = function()
        if melt_count() == 0 then return 'nothing is marked for melting' end end},
    {name = 'Adamantine',             blocked = function()
        local RAW = inorg_idx('RAW_ADAMANTINE')
        if not RAW or not boulder_present(RAW) then return 'no raw adamantine on hand' end end,
                                      done  = function()
        if is_auto('Adamantine') then return true end   -- managed: the tool posts the work
        -- "done" is now the chain being AT ITS CAP, not a manager order existing: the asks
        -- post jobs, and stock counts include forbidden items the same way they do.
        local RAW, ADAM = inorg_idx('RAW_ADAMANTINE'), inorg_idx('ADAMANTINE')
        if not (RAW and ADAM) then return false end
        local function stock(item_type)
            local n = 0
            for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
                if it:getType() == item_type and it:getMaterial() == 0
                    and it:getMaterialIndex() == ADAM then
                    local f = it.flags
                    if not (f.dump or f.garbage_collect or f.removed or f.hostile
                            or f.trader or f.foreign or f.artifact) then
                        n = n + (it.stack_size or 1)
                    end
                end
            end
            return n
        end
        local wafers, cloth, thread = stock(df.item_type.BAR), stock(df.item_type.CLOTH), stock(df.item_type.THREAD)
        if not (cloth >= ADAM_KEEP and thread >= ADAM_KEEP and wafers >= ADAM_KEEP) then return false end
        -- the raised throne target applies here too, or the status would call the chain
        -- finished while it is still working up to nine wafers
        local boulders = 0
        for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
            if it:getType() == df.item_type.BOULDER and it:getMaterial() == 0
                and it:getMaterialIndex() == RAW then
                local f = it.flags
                if not (f.dump or f.garbage_collect or f.removed or f.hostile
                        or f.trader or f.foreign or f.artifact) then boulders = boulders + 1 end
            end
        end
        if boulders >= ADAM_THRONE then return wafers >= ADAM_THRONE end
        return true end},
}
if #STANDING_INFO ~= #STANDING then
    qerror(('planner-orders: %d standing checks but %d names -- they must stay in step')
        :format(#STANDING, #STANDING_INFO))
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
        return choices, ('%s: %s  (%d/%d)'):format(gap.title or 'Hospital supply', gap.name, i, total),
            (gap.note or '')
                .. ('\n\nMakes %s, as a repeating order:'):format(gap.makes or gap.name:lower())
                .. reaction_ws_warning(gap)
    elseif kind == 'job' then
        local req = FIXED_WS[df.job_type[gap.job_type]]
        local warn = (req and not ws_exists(req)) and ('\n\n!! Not built yet: ' .. req.label) or ''
        return {{text = ('Make %s: keep ~%d in stock'):format(gap.name:lower(), gap.amount), mat_type = -1, mat_index = -1}},
            ('%s: %s  (%d/%d)'):format(gap.title or 'Hospital supply', gap.name, i, total), (gap.note or '') .. warn
    elseif kind == 'assemble' then  -- built from other ITEMS, so there is no material to pick
        local comp = JOB_COMPONENTS[df.job_type[gap.job_type]]
        local req = FIXED_WS[df.job_type[gap.job_type]]
        local warn = (req and not ws_exists(req)) and ('\n\n!! Not built yet: ' .. req.label) or ''
        return {{text = ('Assemble %d from %s'):format(gap.amount, comp.desc), mat_type = -1, mat_index = -1}},
            ('%s: %s  (%d/%d)'):format(gap.title or 'Hospital supply', gap.name, i, total),
            (gap.note or '') .. warn
    elseif kind == 'item' then  -- material-picked stock item (hospital supply, container, ...)
        local body = gap.once
            and ('Makes %d; pick a material.'):format(gap.amount)
            or ('Makes %s; pick a material; keeps ~%d in stock.'):format(gap.name:lower(), gap.amount)
        return material_choices(gap), ('%s: %s  (%d/%d)'):format(gap.title or 'Make', gap.name, i, total),
            (gap.note and (gap.note .. '\n\n') or '') .. body
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
-- Apply ONE creation choice to ONE gap. Shared by the step-through walk and the inline
-- buttons on the planner screen, so both create orders through exactly the same path.
-- Returns (missing-workshop labels, a human label for what was made).
function apply_choice(gap, choice)
    local kind = gap.kind or 'build'
    if kind == 'reaction' then
        return create_reaction(gap, choice), choice.text
    elseif kind == 'standing' then
        return gap.producer.build(), gap.name:lower() .. ' orders'
    end
    return create_order(gap, choice), (choice.text or gap.name):gsub(' %[magma%-safe%]', '')
end

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
                local missing, label = apply_choice(gap, choice)
                made[#made + 1] = label
                for _, w in ipairs(missing or {}) do warns[w] = true end
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

-- ---- the planner screen -----------------------------------------------------
--
-- ONE screen, opened by the notification. Left sidebar = every ask this tool knows about and
-- its state; right pane = the selected ask's own description.
--
-- Four states, and the honest limits of each:
--   PENDING  -- offered right now (it is in scan's gap list)
--   IGNORED  -- permanently dismissed; still scanned, just not offered
--   WAITING  -- the check's precondition is not met yet (no quarry bush, too few rock nuts)
--   DONE     -- applicable, but produced nothing, i.e. its orders already exist
--
-- WAITING vs DONE comes from the optional `ready` probe in STANDING_INFO. Where a check has no
-- probe we cannot tell them apart from outside, so it reports DONE -- "nothing to do" either
-- way, which is what the player acts on.
local function status_rows()
    local r = get_scan()
    local rows, seen = {}, {}
    local function add(name, state, gap, reason)
        if seen[name] then return end
        seen[name] = true
        rows[#rows + 1] = {name = name, state = state, gap = gap, reason = reason}
    end
    for _, g in ipairs(r.gaps) do add(g.name, 'PENDING', g) end
    for _, g in ipairs(r.ignored) do add(g.name, 'IGNORED', g) end
    for _, n in ipairs(ignored_names()) do add(n, 'IGNORED') end
    for _, info in ipairs(STANDING_INFO or {}) do
        if not r.active_groups[info.name] then
            -- `done` wins over `blocked`: once the orders exist the ask is satisfied, whether
            -- or not its trigger still holds. Cut gems idling at exactly its 10-gem reserve is
            -- DONE, not WAITING -- the order is there and will fire when the pile grows.
            local state, reason = 'DONE', nil
            local settled = false
            if info.done then
                local good, v = pcall(info.done)
                settled = good and v and true or false
            end
            if not settled and info.blocked then
                local good, why = pcall(info.blocked)
                if good and why then state, reason = 'WAITING', why end
            end
            add(info.name, state, nil, reason)
        end
    end
    local ORDER = {PENDING = 1, IGNORED = 2, WAITING = 3, DONE = 4}
    table.sort(rows, function(a, b)
        if a.state ~= b.state then return ORDER[a.state] < ORDER[b.state] end
        return a.name < b.name
    end)
    return rows, r
end

local STATE_PEN = {PENDING = COLOR_LIGHTGREEN, IGNORED = COLOR_DARKGREY,
                   WAITING = COLOR_BROWN,      DONE = COLOR_GREY}

-- Re-flow a note to the pane width.
--
-- The notes are hand-wrapped to ~78 columns, so naively re-wrapping them to a narrower pane
-- double-wraps: every source line becomes a full line plus a three-word orphan. So paragraphs
-- (runs of plain lines between blanks) are JOINED first and then wrapped fresh. Lines that
-- carry their own shape -- indented text and "  * " bullets -- are left alone and only hard-cut
-- if they genuinely overrun.
local function wrap_lines(text, width)
    local function cut(line, into)
        while #line > width do
            local at = line:sub(1, width + 1):match('.*()%s') or width
            into[#into + 1] = line:sub(1, at - 1)
            line = line:sub(at):gsub('^%s+', '')
        end
        into[#into + 1] = line
    end
    local out, para = {}, {}
    local function flush()
        if #para == 0 then return end
        cut(table.concat(para, ' '), out)
        para = {}
    end
    for raw in (text .. '\n'):gmatch('([^\n]*)\n') do
        if raw == '' then
            flush()
            out[#out + 1] = ''
        elseif raw:match('^%s') then          -- keeps its own indentation/bullet shape
            flush()
            cut(raw, out)
        else
            para[#para + 1] = raw
        end
    end
    flush()
    return out
end

local SIDE_W = 34

PlannerWindow = defclass(PlannerWindow, widgets.Window)
PlannerWindow.ATTRS{frame_title = 'planner-orders', frame = {w = 104, h = 40}, resizable = true}

function PlannerWindow:init()
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = {
            {text = 'click a button to act', pen = COLOR_GREY}, {text = '    '},
            {text = 'i', pen = COLOR_LIGHTCYAN}, {text = ' ignore/un-ignore   '},
            {text = 'r', pen = COLOR_LIGHTCYAN}, {text = ' refresh   '},
            {text = 'Esc', pen = COLOR_LIGHTCYAN}, {text = ' close'}}},
        widgets.List{view_id = 'side', frame = {t = 2, l = 0, w = SIDE_W, b = 2},
            on_select = function(_, c) self:preview(c) end},
        -- the description is a LIST of wrapped lines rather than a label: lists scroll for
        -- free, and these notes run well past any pane height
        widgets.List{view_id = 'desc', frame = {t = 2, l = SIDE_W + 2, r = 0, b = 11}},
        -- actions live INLINE beside the description, rebuilt for whatever is selected --
        -- there is no second screen to step into and no hidden Enter binding
        widgets.Panel{view_id = 'acts', frame = {l = SIDE_W + 2, r = 0, b = 2, h = 8}},
        widgets.Label{view_id = 'foot', frame = {b = 0, l = 0, r = 0, h = 1}, text = ''},
    }
    self:refresh()
end

function PlannerWindow:refresh(keep)
    local rows, r = status_rows()
    self.rows = rows
    local choices, n = {}, {PENDING = 0, IGNORED = 0, WAITING = 0, DONE = 0}
    for _, row in ipairs(rows) do
        n[row.state] = (n[row.state] or 0) + 1
        choices[#choices + 1] = {row = row, text = {
            {text = ('%-8s'):format(row.state), pen = STATE_PEN[row.state]},
            {text = row.name}}}
    end
    if #choices == 0 then choices = {{text = '(nothing to show)'}} end
    self.subviews.side:setChoices(choices, keep or self.subviews.side:getSelected())
    self.subviews.foot:setText({
        {text = ('%d pending, %d ignored, %d waiting, %d done')
            :format(n.PENDING, n.IGNORED, n.WAITING, n.DONE), pen = COLOR_GREY},
        {text = #r.missing > 0 and ('   not built: ' .. table.concat(r.missing, ', ')) or '',
         pen = COLOR_YELLOW}})
    self:preview(self.subviews.side:getChoices()[self.subviews.side:getSelected()])
end

-- Read-only. Selecting an ask shows the same description it leads with when it offers itself;
-- it deliberately offers NO actions here. Asks share dependencies -- ash feeds both soap and
-- pearlash -- so an "undo" on one entry could quietly break another.
function PlannerWindow:preview(choice)
    local row = choice and choice.row
    local w = math.max(20, (self.frame_rect and self.frame_rect.width or 104) - SIDE_W - 6)
    local body
    if not row then
        body = ''
    elseif row.gap then
        local _, title, text = gap_prompt(row.gap, 1, 1)
        body = (title or row.name) .. '\n\n' .. (text or '')
        if row.state == 'IGNORED' then
            body = body .. '\n\n[IGNORED -- press i to start offering this again]'
        end
    elseif row.state == 'WAITING' then
        body = row.name .. '\n\nNot offered yet -- ' .. (row.reason or 'its precondition is not met')
            .. '.\n\nIt will offer itself as soon as that changes.'
    else
        body = row.name .. '\n\nNothing to do: the orders this would create already exist.'
    end
    local lines = {}
    for _, l in ipairs(wrap_lines(body, w)) do lines[#lines + 1] = {text = l} end
    self.subviews.desc:setChoices(lines, 1)
    self:rebuild_actions(row)
end

-- Build the inline buttons for whatever is selected.
--   PENDING  every creation option the ask offers, then Skip / Ignore / Quit
--   IGNORED  the same options, then Skip / Un-ignore
--   DONE / WAITING  nothing -- there is no action to take
local function button_labels(gap)
    local out = {}
    if not gap then return out end
    local ok, choices = pcall(gap_prompt, gap, 1, 1)
    if ok and choices then
        for _, c in ipairs(choices) do out[#out + 1] = c end
    end
    return out
end

function PlannerWindow:rebuild_actions(row)
    local acts = self.subviews.acts
    for i = #acts.subviews, 1, -1 do acts.subviews[i] = nil end
    acts.subviews = {}
    -- relayout from the WINDOW: the panel has no parent rect of its own during init, and
    -- laying out a detached panel throws
    local function relayout() pcall(function() self:updateLayout() end) end
    if not row or row.state == 'DONE' or row.state == 'WAITING' then
        relayout()
        return
    end
    local views, t = {}, 0
    local function button(label, pen, fn)
        -- HotkeyLabel, not TextButton: TextButton wraps one in a BannerPanel, and the panel
        -- is what draws the [brackets]. Same click behaviour, no frame.
        views[#views + 1] = widgets.HotkeyLabel{
            frame = {t = t, l = 0, h = 1},
            label = label, text_pen = pen, on_activate = fn}
        t = t + 1
    end
    for _, c in ipairs(button_labels(row.gap)) do
        local text = type(c.text) == 'table' and (c.text[1] and c.text[1].text or '?') or tostring(c.text)
        button('Create: ' .. text, COLOR_LIGHTGREEN, function() self:do_create(row, c) end)
    end
    button('Skip', COLOR_GREY, function() self:do_skip() end)
    if row.state == 'IGNORED' then
        button('Un-ignore', COLOR_LIGHTCYAN, function() self:do_ignore(row, false) end)
    else
        button('Ignore', COLOR_BROWN, function() self:do_ignore(row, true) end)
        button('Quit', COLOR_LIGHTRED, function() self:do_quit() end)
    end
    acts:addviews(views)
    relayout()
end

function PlannerWindow:do_create(row, choice)
    if not (row and row.gap) then return end
    local sel = self.subviews.side:getSelected()
    local missing = apply_choice(row.gap, choice)
    if missing and #missing > 0 then
        dfhack.printerr('planner-orders: not built -> ' .. table.concat(missing, ', '))
    end
    invalidate_scan()
    self:refresh(sel)
end

function PlannerWindow:do_skip()
    local list = self.subviews.side
    local n = #list:getChoices()
    if n > 0 then list:setSelected(math.min(list:getSelected() + 1, n)) end
    self:preview(list:getChoices()[list:getSelected()])
end

function PlannerWindow:do_ignore(row, on)
    set_ignored(row.name, on)
    invalidate_scan()
    self:refresh(self.subviews.side:getSelected())
end

function PlannerWindow:do_quit()
    local ok, scr = pcall(dfhack.gui.getCurViewscreen, true)
    if ok and scr then dfhack.screen.dismiss(scr) end
end

function PlannerWindow:toggle_ignore()
    local choice = self.subviews.side:getChoices()[self.subviews.side:getSelected()]
    local row = choice and choice.row
    if not row or row.state == 'DONE' or row.state == 'WAITING' then return end
    self:do_ignore(row, row.state ~= 'IGNORED')
end

function PlannerWindow:onInput(keys)
    if keys.CUSTOM_I then self:toggle_ignore(); return true end
    if keys.CUSTOM_R then invalidate_scan(); self:refresh(self.subviews.side:getSelected()); return true end
    return PlannerWindow.super.onInput(self, keys)
end

PlannerScreen = defclass(PlannerScreen, gui.ZScreen)
PlannerScreen.ATTRS{focus_path = 'planner-orders/status'}
function PlannerScreen:init() self:addviews{PlannerWindow{}} end
function PlannerScreen:onDismiss() status_view = nil end

status_view = status_view or nil
-- This script is not a module, so every CLI invocation gets a FRESH environment and the global
-- above is always nil on entry -- it cannot dedupe across runs. Ask the game what is on screen.
local function show_status()
    local ok, up = pcall(dfhack.gui.matchFocusString, 'dfhack/lua/planner-orders/status')
    if ok and up then return end
    status_view = PlannerScreen{}:show()
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
    entry.on_click = show_status
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
    if #r.ignored > 0 then
        local n = {}
        for _, g in ipairs(r.ignored) do n[#n + 1] = g.name end
        print('  ignored: ' .. table.concat(n, ', '))
    end
    local managed = auto_names()
    if #managed > 0 then print('  managed for you: ' .. table.concat(managed, ', ')) end
    if #r.unmakeable > 0 then print('  unmakeable: ' .. table.concat(r.unmakeable, ', ')) end
    if #r.missing > 0 then print('  workshops needed but NOT built: ' .. table.concat(r.missing, ', ')) end
    return
elseif arg == 'now' then
    if not dfhack.world.isFortressMode() then qerror('planner-orders: load a fort first') end
    show_dialog()
    return
elseif arg == 'gui' then
    if not dfhack.world.isFortressMode() then qerror('planner-orders: load a fort first') end
    show_status()
    return
elseif arg == 'disable' then
    -- `disable` clears the ignore list rather than switching the tool off: there is nothing to
    -- switch off (the notification registers itself), and un-ignoring everything is the one
    -- destructive thing worth a command of its own.
    if not dfhack.world.isFortressMode() then qerror('planner-orders: load a fort first') end
    local n = clear_ignores()
    local a = clear_autos()
    invalidate_scan()
    print(('planner-orders: cleared %d ignored ask%s and %d managed one%s; all will be offered again.')
        :format(n, n == 1 and '' or 's', a, a == 1 and '' or 's'))
    return
elseif arg == 'ignore' or arg == 'unignore' then
    if not dfhack.world.isFortressMode() then qerror('planner-orders: load a fort first') end
    local name = table.concat({select(2, ...)}, ' ')
    if name == '' then qerror('usage: planner-orders ' .. arg .. ' <ask name>') end
    set_ignored(name, arg == 'ignore')
    invalidate_scan()
    print(('planner-orders: %s "%s"'):format(arg == 'ignore' and 'ignoring' or 'un-ignoring', name))
    return
end

register()
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register() end
end
print('planner-orders: "' .. NAME .. '" notification registered.')
print('Click it (gui/notify panel) to create manager orders for planned-building items.')
print('`planner-orders list` prints the gaps; `planner-orders now` opens the dialog.')
print('`planner-orders gui` opens the status screen; `planner-orders disable` clears ignores.')
