-- Let idle dwarves satisfy crafting needs at FORGES (trains smithing, not stonecraft).
--@module = true
--@enable = true
--[[
idle-smiths

DFHack's stock `idle-crafting` adds "allow idle dwarves to satisfy crafting needs" to
Craftsdwarf's workshops -- but that trains stonecrafting / bone carving. This is the same
feature for the METALSMITH'S FORGE and MAGMA FORGE: dwarves with an unmet "craft object"
need get a forging job instead, training weaponsmithing / armorsmithing / metalcrafting.

MOOD-MAXIMIZING SPLIT: dwarves are divided evenly and consistently between armorsmithing
and weaponsmithing with NO stored state -- all adult citizens ranked by skill lean
(armorsmith - weaponsmith, ties by unit id); top half are armorsmiths, bottom half
weaponsmiths. Existing smiths keep their side and the split self-reinforces (the first
assignment trains that side). A forge with ALL FIVE labors permitted (an untouched
profile) makes armor/weapons ONLY, per that split; a forge with both smithing labors on a
trimmed profile uses the split too. A trimmed profile with TRAPPING enabled makes CAGES.

Like the original, it RESPECTS the "Permitted General Work Orders" labor toggles on the
forge's Workers tab: only permitted labors are used, chosen at random among
  * Weaponsmithing  -> forge a weapon (random type your civilization can make); when the
                       chosen metal is SILVER, only war hammers and maces (silver is blunt)
  * Armorsmithing   -> forge a cheap one-bar armor piece: helm, gauntlets, high boots
                       (NEVER low boots)
  * Metalcrafting   -> random trinkets (crafts) or a goblet
  * Blacksmithing   -> random furniture (bins/barrels/buckets/cages/chains/traps at 1 bar;
                       doors/floodgates/hatches/coffers/cabinets/thrones/tables/statues at
                       3 bars) -- plus anvils, IRON ONLY (skipped when out of iron bars)
So: to train armor+weapon smiths only, disable the other labors on that forge's Workers tab.

Metal choice: only IRON, COPPER, SILVER, or BRONZE is ever used -- per job category, whichever
LEGAL metal currently has the most bars in the fort. Legality comes from the material's real
item flags: armor needs ITEMS_ARMOR (silver has none -- silver armor is never queued), weapons
ITEMS_WEAPON, furniture/crafts/cages ITEMS_HARD. Anvils excepted: always iron (ITEMS_ANVIL).

SOLDIERS UNDER ORDERS ARE LEFT ALONE. A dwarf whose squad is carrying out an order -- or who
holds an individual one -- is doing that order, however badly they want to craft, so they are
never handed a forge job and the squad never arrives one dwarf short. It is checked both when
the slow scan picks candidates and again when a forge is actually paired with a dwarf, since
an order can be given in between; the moment the order ends they are a candidate again. An
off-duty soldier with no order on them is fair game, as before.

The toggle appears on the forge's Workers tab, exactly like the original's. A forge with a
workshop master assigned cannot be used. Job scheduling mirrors idle-crafting: a slow scan
buckets dwarves by how badly they need to craft (same 500/1000/10000 thresholds), a fast
loop pairs the neediest available dwarf with a free toggled forge.

Usage:
    idle-smiths [status]        statistics + configured forges
    idle-smiths thresholds <list>  need thresholds (default 500,1000,10000)
    disable idle-smiths         clear all forge toggles

Requires the stock idle-crafting script (present in any standard DFHack install) -- its
need-measuring helpers are reused.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local repeatutil = require('repeat-util')
local orders = require('plugins.orders')
local idle = reqscript('idle-crafting')   -- getCraftingNeed, canAccessWorkshop, weightedChoice

local GLOBAL_KEY = 'idle-smiths'

local FORGE_TYPES = {
    [df.workshop_type.MetalsmithsForge] = true,
    [df.workshop_type.MagmaForge] = true,
}
local FORGE_WEAPON = df.unit_labor.FORGE_WEAPON
local FORGE_ARMOR = df.unit_labor.FORGE_ARMOR
local METAL_CRAFT = df.unit_labor.METAL_CRAFT

enabled = enabled or false
function isEnabled() return enabled end

allowed = allowed or {}     -- forge id -> frame of last scheduled job (-1 = none this round)
failing = failing or {}     -- forge id -> true (skip until next main loop)
watched = watched or {}     -- threshold idx -> set of unit ids
thresholds = thresholds or {10000, 1000, 500}

local function persist_state()
    local persistable = {}
    for id in pairs(allowed) do persistable[tostring(id)] = -1 end
    dfhack.persistent.saveSiteData(GLOBAL_KEY,
        {enabled = enabled, allowed = persistable, thresholds = thresholds})
end

local function load_state()
    local d = dfhack.persistent.getSiteData(GLOBAL_KEY, {})
    enabled = d.enabled or false
    thresholds = d.thresholds or {10000, 1000, 500}
    allowed = {}
    for id in pairs(d.allowed or {}) do allowed[tonumber(id)] = -1 end
end

---the forge for an id, or nil
local function locateForge(id)
    local b = df.building.find(id)
    if df.building_workshopst:is_instance(b) and FORGE_TYPES[b.type] then return b end
    return nil
end

-- ---- job selection ----------------------------------------------------------

local FORGE_FURNITURE = df.unit_labor.FORGE_FURNITURE

-- Only these metals are ever used, whichever has the MOST bars in the fort.
-- (Anvils are the exception: iron only -- DF restricts anvil metals anyway.)
local ALLOWED_METALS = {'IRON', 'COPPER', 'SILVER', 'BRONZE'}
local metal_idx_cache
local function allowed_metal_indexes()
    if metal_idx_cache then return metal_idx_cache end
    metal_idx_cache = {}
    for _, name in ipairs(ALLOWED_METALS) do
        local mi = dfhack.matinfo.find(name)
        if mi then metal_idx_cache[name] = mi.index end
    end
    return metal_idx_cache
end

---bar counts per allowed metal; returns counts by name
local function metal_supply()
    local idxs = allowed_metal_indexes()
    local by_index, counts = {}, {}
    for name, idx in pairs(idxs) do by_index[idx] = name; counts[name] = 0 end
    for _, it in ipairs(df.global.world.items.other[df.items_other_id.BAR]) do
        if it.mat_type == 0 and by_index[it.mat_index] and not it.flags.forbid then
            counts[by_index[it.mat_index]] = counts[by_index[it.mat_index]] + 1
        end
    end
    return counts
end

---does this metal's material carry the given inorganic flag (ITEMS_ARMOR etc.)?
local metal_flag_cache
local function metal_has(name, flag)
    metal_flag_cache = metal_flag_cache or {}
    local f = metal_flag_cache[name]
    if not f then
        local mi = dfhack.matinfo.find(name)
        f = mi and mi.material.flags or {}
        metal_flag_cache[name] = f
    end
    return f[flag] and true or false
end

---most-supplied metal that is LEGAL for the given item flag (silver has no
---ITEMS_ARMOR -- silver armor is not a real item); nil if no legal bars at all
local function best_for(counts, flag)
    local best
    for name, n in pairs(counts) do
        if n > 0 and metal_has(name, flag) and (not best or n > counts[best]) then
            best = name
        end
    end
    return best
end

-- one-bar itemdef choices per category, from what OUR civilization can make.
-- Weapons: anything non-training. Armor-family: only material_size <= 3 pieces
-- (1 bar), never low boots. Furniture: fixed table below.
local choice_cache
local function civ_choices()
    if choice_cache then return choice_cache end
    local ent
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.civ_id then ent = e break end
    end
    local c = {weapon = {}, silver_weapon = {}, armor = {}}
    if ent then
        local r = ent.resources
        for _, idx in ipairs(r.weapon_type) do
            local d = df.global.world.raws.itemdefs.weapons[idx]
            if d and not d.flags.TRAINING then
                c.weapon[#c.weapon + 1] = {job = df.job_type.MakeWeapon, sub = idx, bars = 1}
                -- silver is only good blunt: silver weapon jobs are war hammers / maces only
                local id = tostring(d.id)
                if id == 'ITEM_WEAPON_HAMMER_WAR' or id == 'ITEM_WEAPON_MACE' then
                    c.silver_weapon[#c.silver_weapon + 1] = {job = df.job_type.MakeWeapon, sub = idx, bars = 1}
                end
            end
        end
        local families = {
            {r.armor_type,  'armor',  df.job_type.MakeArmor},
            {r.helm_type,   'helms',  df.job_type.MakeHelm},
            {r.gloves_type, 'gloves', df.job_type.MakeGloves},
            {r.shoes_type,  'shoes',  df.job_type.MakeShoes},
            {r.pants_type,  'pants',  df.job_type.MakePants},
        }
        for _, f in ipairs(families) do
            for _, idx in ipairs(f[1]) do
                local d = df.global.world.raws.itemdefs[f[2]][idx]
                -- METAL flag: forgeable at all (a cloak has armorlevel 1 but is cloth/leather
                -- only -- forging one in metal creates an illegal item). Low boots: never.
                if d and d.material_size <= 3 and (d.armorlevel or 1) > 0
                    and d.props and d.props.flags and d.props.flags.METAL
                    and tostring(d.id) ~= 'ITEM_SHOES_BOOTS_LOW' then
                    c.armor[#c.armor + 1] = {job = f[3], sub = idx, bars = 1}
                end
            end
        end
    end
    choice_cache = c
    return c
end

-- blacksmithing (FORGE_FURNITURE): random furniture. Small containers cost 1 bar,
-- large furniture 3. Anvils are in the pool but IRON ONLY (skipped without iron bars).
local FURNITURE = {
    {job = 'ConstructBin',        bars = 1}, {job = 'MakeBarrel',    bars = 1},
    {job = 'MakeBucket',          bars = 1}, {job = 'MakeCage',      bars = 1},
    {job = 'MakeChain',           bars = 1}, {job = 'MakeAnimalTrap',bars = 1},
    {job = 'ConstructDoor',       bars = 3}, {job = 'ConstructFloodgate', bars = 3},
    {job = 'ConstructHatchCover', bars = 3}, {job = 'ConstructChest', bars = 3},
    {job = 'ConstructCabinet',    bars = 3}, {job = 'ConstructThrone', bars = 3},
    {job = 'ConstructTable',      bars = 3}, {job = 'ConstructStatue', bars = 3},
    {job = 'ForgeAnvil',          bars = 3, anvil = true},
}

---create a forging job and hand it to the unit. Mirrors idle-crafting's job creation;
---the job_item shape matches a real manager-dispatched forge job (BAR, quantity 150
---per bar, min_dimension 150).
local function forge_job(unit, forge, job_type, subtype, mat_index, bars)
    local job = dfhack.job.createLinked()
    job.job_type = job_type
    job.item_subtype = subtype or -1
    job.mat_type = 0
    job.mat_index = mat_index

    local jitem = df.job_item:new()
    jitem.item_type = df.item_type.BAR
    jitem.mat_type = 0
    jitem.mat_index = mat_index
    jitem.quantity = 150 * (bars or 1)
    jitem.min_dimension = 150
    jitem.vector_id = df.job_item_vector_id.BAR
    job.job_items.elements:insert('#', jitem)

    dfhack.job.assignToWorkshop(job, forge)
    return dfhack.job.addWorker(job, unit)
end

local TRAPPER = df.unit_labor.TRAPPER

-- ---- the stateless armorsmith/weaponsmith split -------------------------------
-- To maximize moodable skills, dwarves are divided evenly and CONSISTENTLY between
-- armorsmithing and weaponsmithing -- without storing anything. All adult citizens
-- are ranked by skill LEAN (armorsmith skill - weaponsmith skill, ties by unit id);
-- the top half are armorsmiths, the bottom half weaponsmiths. The split is even by
-- construction, existing smiths keep their side, and it self-reinforces: a dwarf's
-- first assignment trains that side, cementing their lean for every later pass.
local split_cache
local function smith_side(unit)
    if not split_cache then
        local list = {}
        for _, u in ipairs(dfhack.units.getCitizens(true, false)) do
            if dfhack.units.isAdult(u) then
                local a = dfhack.units.getNominalSkill(u, df.job_skill.FORGE_ARMOR, true)
                local w = dfhack.units.getNominalSkill(u, df.job_skill.FORGE_WEAPON, true)
                list[#list + 1] = {id = u.id, lean = a - w}
            end
        end
        table.sort(list, function(x, y)
            if x.lean ~= y.lean then return x.lean > y.lean end
            return x.id < y.id
        end)
        split_cache = {}
        local half = math.ceil(#list / 2)
        for i, e in ipairs(list) do
            split_cache[e.id] = (i <= half) and 'armor' or 'weapon'
        end
    end
    return split_cache[unit.id] or ((unit.id % 2 == 0) and 'armor' or 'weapon')
end

---weapon pool for a given metal (silver = hammers/maces only)
local function weapon_pool(c, metal)
    return (metal == 'SILVER') and c.silver_weapon or c.weapon
end

---pool + metal for a dwarf's split side, falling back to the other side when its
---pool is empty or no metal in stock may legally make it (e.g. only silver bars:
---no armor side -- silver armor is not a thing)
local function side_pool(unit, c, best_armor, best_weapon)
    local wpool = best_weapon and weapon_pool(c, best_weapon) or {}
    local sides = {
        armor  = (best_armor and #c.armor > 0) and {list = c.armor, mat = best_armor} or nil,
        weapon = #wpool > 0 and {list = wpool, mat = best_weapon} or nil,
    }
    local side = smith_side(unit)
    return sides[side] or sides[side == 'armor' and 'weapon' or 'armor']
end

---pick a permitted job for this forge and THIS dwarf;
---returns job_type, subtype, mat_index, bars -- or nil
local function select_forge_job(forge, unit)
    local counts = metal_supply()
    -- per-category legal best: each job category uses the most-supplied metal
    -- that may LEGALLY make it (silver bars never produce armor jobs)
    local best_weapon = best_for(counts, 'ITEMS_WEAPON')
    local best_armor = best_for(counts, 'ITEMS_ARMOR')
    local best_hard = best_for(counts, 'ITEMS_HARD')    -- furniture/crafts/cages
    if not (best_weapon or best_armor or best_hard) then
        return nil                                -- no iron/copper/silver/bronze bars at all
    end
    local idxs = allowed_metal_indexes()
    local blocked = forge.profile.blocked_labors
    local c = civ_choices()
    local w_on, a_on = not blocked[FORGE_WEAPON], not blocked[FORGE_ARMOR]
    local c_on, f_on = not blocked[METAL_CRAFT], not blocked[FORGE_FURNITURE]
    local t_on = not blocked[TRAPPER]
    local all5 = w_on and a_on and c_on and f_on and t_on

    local pools = {}
    if all5 then
        -- an untouched default profile: mood-maximizing armor/weapons ONLY,
        -- side chosen by the dwarf's split
        local p = side_pool(unit, c, best_armor, best_weapon)
        if p then pools[#pools + 1] = p end
    elseif t_on then
        -- trapping deliberately enabled on a trimmed profile: this forge makes CAGES
        if best_hard then
            pools[#pools + 1] = {list = {{job = df.job_type.MakeCage, sub = -1, bars = 1}},
                                 mat = best_hard}
        end
    else
        if w_on and a_on then
            -- both smithing labors: the dwarf's split decides, not chance
            local p = side_pool(unit, c, best_armor, best_weapon)
            if p then pools[#pools + 1] = p end
        elseif w_on and best_weapon then
            local p = weapon_pool(c, best_weapon)
            if #p > 0 then pools[#pools + 1] = {list = p, mat = best_weapon} end
        elseif a_on and best_armor and #c.armor > 0 then
            pools[#pools + 1] = {list = c.armor, mat = best_armor}
        end
        if c_on and best_hard then
            -- metalcrafting: random trinkets (MakeCrafts rolls figurines/amulets/...)
            -- or a goblet
            pools[#pools + 1] = {list = {
                {job = df.job_type.MakeCrafts, sub = -1, bars = 1},
                {job = df.job_type.MakeGoblet, sub = -1, bars = 1},
            }, mat = best_hard}
        end
        if f_on and best_hard then
            local fpool = {}
            for _, f in ipairs(FURNITURE) do
                if df.job_type[f.job] and (not f.anvil or (idxs.IRON and counts.IRON >= f.bars)) then
                    fpool[#fpool + 1] = f
                end
            end
            if #fpool > 0 then pools[#pools + 1] = {list = fpool, mat = best_hard} end
        end
    end
    if #pools == 0 then return nil end
    local pool = pools[math.random(#pools)]
    local pick = pool.list[math.random(#pool.list)]
    local jt = type(pick.job) == 'string' and df.job_type[pick.job] or pick.job
    local mat = pick.anvil and idxs.IRON or idxs[pool.mat]
    return jt, pick.sub or -1, mat, pick.bars
end

---a forge that can't take idle jobs: has a master, or permits none of our labors
local function invalidProfile(forge)
    local p = forge.profile
    return (#p.permitted_workers > 0) or
        (p.blocked_labors[FORGE_WEAPON] and p.blocked_labors[FORGE_ARMOR]
            and p.blocked_labors[METAL_CRAFT] and p.blocked_labors[FORGE_FURNITURE]
            and p.blocked_labors[TRAPPER])
end

---A SOLDIER UNDER ORDERS IS NOT IDLE, whatever their craft need says. A station, patrol,
---kill or training order is the thing they are supposed to be doing, and handing them a
---forge job pulls them off it -- the squad arrives one dwarf short, and on a kill order
---that dwarf is walking to a workshop while the rest fight.
---
---Both scopes count: `squad.orders` is the order given to the whole squad, and a member can
---also carry an individual one in their own position's `orders`. Either means busy.
---
---A citizen can belong to a squad that is not this fort's (a soldier who joined keeps the
---squad_id of their old civ's squad), so a missing squad record is treated as no orders
---rather than an error.
local function under_military_order(unit)
    local squad_id = unit.military and unit.military.squad_id or -1
    if squad_id < 0 then return false end
    local squad = df.squad.find(squad_id)
    if not squad then return false end
    if #squad.orders > 0 then return true end
    for _, pos in ipairs(squad.positions) do
        if #pos.orders > 0 and pos.occupant >= 0 then
            local hf = df.historical_figure.find(pos.occupant)
            if hf and hf.unit_id == unit.id then return true end
        end
    end
    return false
end

-- ---- scheduling loops (mirroring idle-crafting) ------------------------------

local function stop()
    enabled = false
    repeatutil.cancel(GLOBAL_KEY .. 'main')
    repeatutil.cancel(GLOBAL_KEY .. 'unit')
end

local function checkForForge()
    if not next(allowed) then stop() end
end

local function processUnit(forge, idx, unit_id)
    local unit = df.unit.find(unit_id)
    if not unit or unit.flags1.caged or unit.flags1.chained
        or idle.getCraftingNeed(unit, -1) < 0 then
        watched[idx][unit_id] = nil
        return false
    elseif not idle.canAccessWorkshop(unit, forge) then
        return false
    elseif not dfhack.units.isJobAvailable(unit) then
        return false
    elseif under_military_order(unit) then
        -- checked again HERE, not just in the slow scan: an order can be given in the
        -- minutes between that scan and this pairing. Left in `watched`, so the moment the
        -- order is over they are a candidate again.
        return false
    end
    local job_type, subtype, mat, bars = select_forge_job(forge, unit)
    if not job_type then
        print('idle-smiths: no usable job (no iron/copper/silver/bronze bars, or no permitted labor)')
        failing[forge.id] = true
        return false
    end
    local success = forge_job(unit, forge, job_type, subtype, mat, bars)
    if success then
        print(('idle-smiths: assigned %s to %s'):format(df.job_type[job_type],
            dfhack.df2console(dfhack.units.getReadableName(unit))))
        watched[idx][unit_id] = nil
        allowed[forge.id] = df.global.world.frame_counter
    end
    return true
end

local function unit_loop()
    local current_frame = df.global.world.frame_counter
    for forge_id, last_job_frame in pairs(allowed) do
        if failing[forge_id] then goto next_forge end
        local forge = locateForge(forge_id)
        if not forge or invalidProfile(forge) then
            allowed[forge_id] = nil
            goto next_forge
        end
        if #forge.jobs > 0 then goto next_forge end
        if (last_job_frame >= 0) and (current_frame < last_job_frame + 60) then
            failing[forge_id] = true
            goto next_forge
        end
        for idx in ipairs(thresholds) do
            for unit_id in pairs(watched[idx] or {}) do
                if processUnit(forge, idx, unit_id) then goto next_forge end
            end
        end
        ::next_forge::
    end
    local any = false
    for _, set in pairs(watched) do if next(set) then any = true break end end
    if not any then repeatutil.cancel(GLOBAL_KEY .. 'unit') end
    checkForForge()
    persist_state()
end

local function main_loop()
    checkForForge()
    if not enabled then return end
    failing = {}
    for forge_id in pairs(allowed) do allowed[forge_id] = -1 end
    choice_cache = nil
    split_cache = nil    -- recompute the armor/weapon split against current skills

    watched = {}
    local watching = false
    for idx in ipairs(thresholds) do watched[idx] = {} end
    for _, unit in ipairs(dfhack.units.getCitizens(true, false)) do
        local need = not under_military_order(unit) and idle.getCraftingNeed(unit, nil)
        if need then
            for idx, threshold in ipairs(thresholds) do
                if need > threshold then
                    watched[idx][unit.id] = true
                    watching = true
                    break
                end
            end
        end
    end
    if watching then
        repeatutil.scheduleUnlessAlreadyScheduled(GLOBAL_KEY .. 'unit', 53, 'ticks', unit_loop)
    end
end

local function start(enable)
    enabled = enable or enabled
    if enabled then
        repeatutil.scheduleUnlessAlreadyScheduled(GLOBAL_KEY .. 'main', 8419, 'ticks', main_loop)
    end
end

---run one scan + assignment pass right now (testing/manual kick; the background loops
---normally do this on their own cadence)
function force_cycle()
    main_loop()
    unit_loop()
end

---cancel any scheduled loops (which may hold closures over an OLD copy of this code --
---reqscript does not restart repeat-util callbacks) and reschedule with the current code
function restart_service()
    repeatutil.cancel(GLOBAL_KEY .. 'main')
    repeatutil.cancel(GLOBAL_KEY .. 'unit')
    if next(allowed) then
        enabled = true
        start(true)
    end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        return
    end
    if sc ~= SC_MAP_LOADED or df.global.gamemode ~= df.game_mode.DWARF then return end
    load_state()
    start()
end

-- ---- overlay: the toggle on the forge's Workers tab --------------------------

IdleSmithsOverlay = defclass(IdleSmithsOverlay, overlay.OverlayWidget)
IdleSmithsOverlay.ATTRS{
    desc = "Adds an idle-crafting toggle to Metalsmith's and Magma forges.",
    default_pos = {x = -39, y = 41},
    version = 1,
    default_enabled = true,
    viewscreens = {
        'dwarfmode/ViewSheets/BUILDING/Workshop/MetalsmithsForge/Workers',
        'dwarfmode/ViewSheets/BUILDING/Workshop/MagmaForge/Workers',
    },
    frame = {w = 58, h = 1},
    visible = orders.can_set_labors,
}

function IdleSmithsOverlay:init()
    self:addviews{
        widgets.BannerPanel{
            frame = {l = 0, w = 54},
            subviews = {
                widgets.CycleHotkeyLabel{
                    view_id = 'leisure_toggle',
                    frame = {t = 0, l = 1, r = 1},
                    label = 'Allow idle dwarves to satisfy crafting needs:',
                    key = 'CUSTOM_I',
                    options = {
                        {label = 'yes', value = true, pen = COLOR_GREEN},
                        {label = 'no', value = false},
                    },
                    initial_option = 'no',
                    on_change = self:callback('onClick'),
                    enabled = function()
                        local bld = dfhack.gui.getSelectedBuilding(true)
                        if not bld then return end
                        return not invalidProfile(bld)
                    end,
                },
            },
        },
    }
end

function IdleSmithsOverlay:onClick(new, _)
    local forge = dfhack.gui.getSelectedBuilding(true)
    allowed[forge.id] = new and -1 or nil
    if new and not enabled then start(true) end
    if not next(allowed) then stop() end
    persist_state()
    -- don't make the player wait for the (~7 game hours) slow scan: serve the first
    -- needy idle dwarf right away when a forge is toggled on
    if new then pcall(force_cycle) end
end

function IdleSmithsOverlay:onRenderBody(painter)
    local forge = dfhack.gui.getSelectedBuilding(true)
    if not forge then return end
    self.subviews.leisure_toggle:setOption(allowed[forge.id] and true or false)
end

OVERLAY_WIDGETS = {idlesmiths = IdleSmithsOverlay}

-- ---- command line -----------------------------------------------------------

if dfhack_flags.module then
    return
end

if df.global.gamemode ~= df.game_mode.DWARF then
    qerror('idle-smiths requires a loaded fortress')
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then
        qerror('enable idle-smiths by toggling it on a forge\'s Workers tab')
    else
        allowed = {}
        stop()
        persist_state()
        return
    end
end

load_state()
local args = {...}
if not args[1] or args[1] == 'status' then
    local n = 0
    for _ in pairs(allowed) do n = n + 1 end
    print(('idle-smiths: %s with %d forge%s configured'):format(
        enabled and 'enabled' or 'disabled', n, n == 1 and '' or 's'))
    local needy = 0
    for _, unit in ipairs(dfhack.units.getCitizens(true, false)) do
        if idle.getCraftingNeed(unit, nil) then needy = needy + 1 end
    end
    print(('  citizens with an unmet crafting need: %d'):format(needy))
    print(('  need thresholds: %s'):format(table.concat(thresholds, ',')))
elseif args[1] == 'thresholds' then
    local argparse = require('argparse')
    thresholds = argparse.numberList(args[2], 'thresholds')
    table.sort(thresholds, function(a, b) return a > b end)
    print(('idle-smiths: thresholds set to %s'):format(table.concat(thresholds, ',')))
elseif args[1] == 'disable' then
    allowed = {}
    stop()
end
persist_state()
