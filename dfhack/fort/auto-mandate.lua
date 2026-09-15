-- Auto-queue manager work orders to satisfy nobles' production (Make) mandates.
--@module = true
--@enable = true
--[[
Queues a manager work order for each unfulfilled "Make" mandate, choosing the
cheapest / most renewable material the item can be made from:

    * craft / jewelry items (amulet, ring, ...) -> copper (else any metal, else wood)
    * furniture & wooden goods                  -> wood
    * metal gear (weapons, greaves, mail shirts) -> copper
    * GARMENTS (trousers, socks, robes)         -> a cloth or leather category, never metal:
                                                   one item_type covers both the armoury and
                                                   the wardrobe and only the subtype says which
    * coins (minted from a metal bar)           -> copper (else any metal bar)
    * cages                                     -> copper (else any metal bar, else wood):
                                                   a metal cage is worth far more to the
                                                   noble and cannot burn, but a fort with
                                                   no bars must still be able to comply
    * stone goods (mechanisms, statues, querns,
      millstones, slabs)                        -> obsidian if the fort has usable
                                                   boulders of it, else whichever
                                                   unrestricted stone it has most of,
                                                   else unconstrained

If a mandate demands a specific material, that material is used instead.

Obsidian is preferred for stone goods because it is worthless to trade and endlessly
renewable from a magma/water casting setup, so spending it on a noble's whim costs
nothing. Failing that it takes whichever stone the fort has MOST boulders of, which is the
one it can least miss -- on a fort cut out of gabbro that is gabbro, without having to name
it. Any stone the stone-use settings hold back as economic (obsidian is one of DF's defaults)
is skipped: an order pinned to a stone the masons will not touch is worse than an open one,
since an unmade mandate is a punished mandate. Run `auto-mandate`
and the reason is printed next to the order.

Every order queued is announced in the report log -- who mandated it, and what was
ordered ("Mandate from Ducim Rimtar: work order queued for 3 mail shirts (copper)").
The background service has nowhere else to say so, since its console output goes to a
DFHack window nobody is watching mid-game.

Usage:
    auto-mandate                 queue orders for current mandates, once
    enable auto-mandate          run in the background, re-checking periodically
    disable auto-mandate         stop the background service

Safe to run repeatedly: it never double-queues a mandate that already has a
matching order. The enabled state persists with the fort.
]]

local GLOBAL_KEY = 'auto-mandate'

local CYCLE_DAYS = 1

-- item_type token -> { job token, material policy, kind }
--   kind 'sub'   : set order.item_subtype (forge jobs pick the specific gear)
--   kind 'fixed' : the job implies the item; set neither
-- CW = copper if there is any, else any metal, else WOOD. For goods a carpenter and a
-- metalsmith can both make: the metal one is worth far more to the noble who mandated it and
-- will not burn, but a fort with no bars must still be able to fulfil the mandate, and an
-- unmade mandate is a punished mandate.
local W, C, A, S, CW = 'wood', 'copper', 'any', 'stone', 'copper_else_wood'
-- G = GEAR: the material is decided by the mandated SUBTYPE, not the item type. Metal-capable
-- pieces (greaves, high boots, mail shirts) take the copper policy; garments (trousers, socks,
-- robes) are left unpinned so the clothier or the leather works can take the job.
local G = 'gear'
local RAW = {
    -- jewelry/craft goods: use the SPECIFIC make-job (NOT generic "make crafts",
    -- which makes a random item and would not satisfy the mandate)
    -- JEWELRY IS METAL, not wood. A wooden earring is legal and worthless -- the noble who
    -- mandated it gets a trinket worth three dwarfbucks, and the fort spends a log on it --
    -- so these follow the cage rule instead: copper if there is any, then any metal, then
    -- wood, so a fort with no bars can still comply.
    {'AMULET', 'MakeAmulet', CW, 'fixed'}, {'RING', 'MakeRing', CW, 'fixed'},
    {'BRACELET', 'MakeBracelet', CW, 'fixed'}, {'EARRING', 'MakeEarring', CW, 'fixed'},
    {'CROWN', 'MakeCrown', CW, 'fixed'}, {'SCEPTER', 'MakeScepter', CW, 'fixed'},
    {'FIGURINE', 'MakeFigurine', W, 'fixed'},
    {'TOY', 'MakeToy', W, 'fixed'}, {'GOBLET', 'MakeGoblet', W, 'fixed'},
    {'FLASK', 'MakeFlask', W, 'fixed'}, {'CAGE', 'MakeCage', CW, 'fixed'},
    {'BARREL', 'MakeBarrel', W, 'fixed'}, {'BUCKET', 'MakeBucket', W, 'fixed'},
    {'ANIMALTRAP', 'MakeAnimalTrap', W, 'fixed'}, {'TOTEM', 'MakeTotem', A, 'fixed'},
    {'DOOR', 'ConstructDoor', W, 'fixed'}, {'FLOODGATE', 'ConstructFloodgate', W, 'fixed'},
    {'BED', 'ConstructBed', W, 'fixed'}, {'CHAIR', 'ConstructThrone', W, 'fixed'},
    {'COFFIN', 'ConstructCoffin', W, 'fixed'}, {'TABLE', 'ConstructTable', W, 'fixed'},
    {'BOX', 'ConstructChest', W, 'fixed'}, {'CABINET', 'ConstructCabinet', W, 'fixed'},
    {'ARMORSTAND', 'ConstructArmorStand', W, 'fixed'}, {'WEAPONRACK', 'ConstructWeaponRack', W, 'fixed'},
    {'BIN', 'ConstructBin', W, 'fixed'}, {'HATCH_COVER', 'ConstructHatchCover', W, 'fixed'},
    {'BLOCKS', 'ConstructBlocks', W, 'fixed'},
    {'WEAPON', 'MakeWeapon', C, 'sub'},
    -- ARMOR / HELM / PANTS / GLOVES / SHOES each span the armoury AND the wardrobe, so the
    -- SUBTYPE picks the material, not the item type -- see metal_capable.
    {'ARMOR', 'MakeArmor', G, 'sub'},
    {'HELM', 'MakeHelm', G, 'sub'}, {'PANTS', 'MakePants', G, 'sub'},
    {'GLOVES', 'MakeGloves', G, 'sub'}, {'SHOES', 'MakeShoes', G, 'sub'},
    {'TRAPCOMP', 'MakeTrapComponent', C, 'sub'}, {'CHAIN', 'MakeChain', C, 'fixed'},
    -- coins: the MintCoins job strikes a stack from a metal bar (item implied -> 'fixed'); a
    -- coin mandate rarely names a metal, so default to the cheap-metal policy (copper, else any bar)
    {'COIN', 'MintCoins', C, 'fixed'},
    {'SHIELD', 'MakeShield', W, 'sub'}, {'AMMO', 'MakeAmmo', W, 'sub'},
    {'STATUE', 'ConstructStatue', S, 'fixed'}, {'TRAPPARTS', 'ConstructMechanisms', S, 'fixed'},
    -- Mason's-workshop goods. Never a metal policy: the mason makes these from a boulder and no
    -- forge job produces them, so pinning a metal would queue an order no workshop in the fort
    -- could ever work.
    {'QUERN', 'ConstructQuern', S, 'fixed'}, {'MILLSTONE', 'ConstructMillstone', S, 'fixed'},
    {'SLAB', 'ConstructSlab', S, 'fixed'},
}

local MAP = {}
for _, e in ipairs(RAW) do
    local it = df.item_type[e[1]]
    local job = df.job_type[e[2]]
    if it and job then MAP[it] = {job = job, mat = e[3], kind = e[4]} end
end

local function order_target(m, map)
    local it, sub = -1, -1
    if map.kind == 'sub' then sub = m.item_subtype end
    return it, sub
end

-- ---- material availability (cheap, via per-type item lists) ----------------

local function wood_logs()
    return #df.global.world.items.other.WOOD
end

-- HOW MANY, not whether. A mandate for ten earrings backed by one copper bar is an order that
-- stalls after the first, and a stalled mandate is a punished mandate -- so every choice below
-- asks for enough to finish the job and moves on to the next material when the fort is short.
local function bars_of(mat_type, mat_index)
    local n = 0
    for _, it in ipairs(df.global.world.items.other.BAR) do
        if it.mat_type == mat_type and it.mat_index == mat_index then n = n + (it.stack_size or 1) end
    end
    return n
end

-- Every METAL the fort holds bars of, cheapest first.
--
-- Two traps here, both found in this fort's own stock. `items.other.BAR` is not a metal list:
-- it holds coal and pearlash too (28 and 9 bars of them here), so a bare scan offers to forge
-- an earring out of coke. And a metal that cannot be made into items -- bismuth, an alloy
-- ingredient -- is no better. So the list is filtered to IS_METAL plus ITEMS_HARD, the same
-- test `quick-order` uses to reject impossible orders.
--
-- Cheapest first, because this tool spends materials on a noble's whim: value ascending, ties
-- broken by whichever there is more of. Sorting by quantity alone happily forges silver
-- trinkets while the copper sits there.
local function metal_stocks()
    local by, out = {}, {}
    for _, it in ipairs(df.global.world.items.other.BAR) do
        local key = it.mat_type .. ':' .. it.mat_index
        if by[key] == nil then
            local usable, value = false, 0
            pcall(function()
                local mi = dfhack.matinfo.decode(it.mat_type, it.mat_index)
                local mat = mi and mi.material
                if mat and mat.flags.IS_METAL and mat.flags.ITEMS_HARD then
                    usable = true
                    value = mat.material_value or 0
                end
            end)
            if usable then
                by[key] = {mat_type = it.mat_type, mat_index = it.mat_index, n = 0, value = value}
                out[#out + 1] = by[key]
            else
                by[key] = false
            end
        end
        if by[key] then by[key].n = by[key].n + (it.stack_size or 1) end
    end
    table.sort(out, function(a, b)
        if a.value ~= b.value then return a.value < b.value end
        return a.n > b.n
    end)
    return out
end

-- the best metal for `amount` items: copper if there is enough, else the most plentiful metal
-- that has enough, else the most plentiful metal there is (better a short order than none)
function pick_metal(amount)   -- module-level: checkable from the command line
    local cu = dfhack.matinfo.find('COPPER')
    if cu and bars_of(cu.type, cu.index) >= amount then return cu.type, cu.index, 'copper' end
    local stocks = metal_stocks()
    for _, m in ipairs(stocks) do
        if m.n >= amount then
            local info = dfhack.matinfo.decode(m.mat_type, m.mat_index)
            return m.mat_type, m.mat_index, info and info:toString() or 'metal'
        end
    end
    local m = stocks[1]
    if m then
        local info = dfhack.matinfo.decode(m.mat_type, m.mat_index)
        return m.mat_type, m.mat_index,
               ('%s (only %d bar%s)'):format(info and info:toString() or 'metal', m.n,
                                             m.n == 1 and '' or 's')
    end
end

-- A stone for stone goods -- but only when the masons would actually pick it up. Returns the
-- matinfo, or nil plus the reason it was passed over.
--
-- A stone flagged in `economic_stone` is held back by the fort's stone-use settings for its
-- industrial purpose (obsidian is one of DF's defaults, alongside the ores, gems and flux).
-- Pinning an order to a held-back stone risks queueing work nobody picks up, and an unmade
-- mandate is a PUNISHED mandate -- so a restricted stone counts as "not available" and we try
-- the next one instead.
local function usable_stone(token, amount)
    local st = dfhack.matinfo.find(token)
    local name = token:lower()
    if not st then return nil, ('no %s in this world'):format(name) end
    local econ = df.global.plotinfo.economic_stone
    -- economic_stone is a 0/1 vector, NOT booleans -- and 0 is truthy in Lua, so a bare
    -- `if econ[i]` reads every stone as restricted. Compare explicitly.
    if st.index < #econ and econ[st.index] == 1 then
        return nil, ('%s is restricted in the stone-use settings'):format(name)
    end
    local n = 0
    for _, it in ipairs(df.global.world.items.other.BOULDER) do
        if it.mat_type == st.type and it.mat_index == st.index then n = n + 1 end
    end
    if n >= (amount or 1) then return st end
    if n > 0 then return nil, ('only %d %s boulder%s'):format(n, name, n == 1 and '' or 's') end
    return nil, ('no %s boulders in stock'):format(name)
end

-- The stone to spend on a whim: whichever the fort has MOST of, among the ones its own
-- stone-use settings have not held back.
--
-- Most plentiful is the right rule for the same reason cheapest is right for metal -- it is the
-- stone the fort can least miss, and on a fort cut out of gabbro that is gabbro without having
-- to name it. Economic stones are skipped exactly as obsidian is: an order pinned to a stone
-- the masons will not touch is worse than an open one.
local function pick_stone(amount)
    local econ = df.global.plotinfo.economic_stone
    local by, out = {}, {}
    for _, it in ipairs(df.global.world.items.other.BOULDER) do
        if it.mat_type == 0 then
            local key = it.mat_index
            if by[key] == nil then
                local ok = false
                if not (key < #econ and econ[key] == 1) then
                    pcall(function()
                        local mi = dfhack.matinfo.decode(0, key)
                        ok = mi and mi.material.flags.IS_STONE or false
                    end)
                end
                if ok then
                    by[key] = {mat_index = key, n = 0}
                    out[#out + 1] = by[key]
                else
                    by[key] = false
                end
            end
            if by[key] then by[key].n = by[key].n + 1 end
        end
    end
    table.sort(out, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.mat_index < b.mat_index          -- stable when two piles are the same size
    end)
    local function name_of(idx)
        local mi = dfhack.matinfo.decode(0, idx)
        return mi and mi:toString() or 'stone'
    end
    for _, st in ipairs(out) do
        if st.n >= amount then return 0, st.mat_index, name_of(st.mat_index) end
    end
    local st = out[1]
    if st then                              -- nothing has enough: the biggest pile, and say so
        return 0, st.mat_index, name_of(st.mat_index),
               ('only %d boulder%s'):format(st.n, st.n == 1 and '' or 's')
    end
end

-- is this material in stock as a craftable input (bar/boulder/log/block)?
local function material_in_stock(mt, mi)
    for _, name in ipairs({'BAR', 'BOULDER', 'WOOD', 'BLOCKS'}) do
        local list = df.global.world.items.other[name]
        for i = 0, #list - 1 do
            local it = list[i]
            if it.mat_type == mt and it.mat_index == mi then return true end
        end
    end
    return false
end

-- can this order actually be worked right now (input material on hand)?
local function order_fulfillable(o)
    if o.material_category.wood then return wood_logs() > 0 end
    if o.mat_type and o.mat_type >= 0 then return material_in_stock(o.mat_type, o.mat_index) end
    return true   -- no material constraint: made from whatever is available
end

-- a matching order that is actually working toward the mandate right now:
-- it must be ACTIVE (its conditions are met -- e.g. not "only while < 10 in
-- stock" when 10 already exist) and have its input material on hand
local function has_fulfillable_order(job, it, sub)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == job and o.item_type == it and o.item_subtype == sub
            and o.status.active and order_fulfillable(o)
        then
            return true
        end
    end
    return false
end

-- item_type -> the itemdef vector holding its subtype names, so a forge order reads
-- "3 mail shirts" rather than "3 armor". (fort/mandate-notification keeps its own copy of
-- this map to describe the MANDATE; here it describes the ORDER, which is not always the
-- same thing -- see order_label.)
local SUBTYPE_VEC = {
    [df.item_type.WEAPON]   = 'weapons',
    [df.item_type.ARMOR]    = 'armor',
    [df.item_type.SHOES]    = 'shoes',
    [df.item_type.GLOVES]   = 'gloves',
    [df.item_type.HELM]     = 'helms',
    [df.item_type.PANTS]    = 'pants',
    [df.item_type.SHIELD]   = 'shields',
    [df.item_type.AMMO]     = 'ammo',
    [df.item_type.TRAPCOMP] = 'trapcomps',
    [df.item_type.TOY]      = 'toys',
}

-- The itemdef behind a mandate's subtype, or nil when the mandate named no subtype.
local function subtype_def(m)
    local vec = SUBTYPE_VEC[m.item_type]
    if not vec or not m.item_subtype or m.item_subtype < 0 then return nil end
    return df.global.world.raws.itemdefs[vec][m.item_subtype]
end

-- CAN THIS PIECE OF GEAR BE MADE OF METAL AT ALL? One item_type covers both the armoury and
-- the wardrobe -- PANTS is greaves AND trousers, SHOES is high boots AND socks, ARMOR is a
-- mail shirt AND a robe -- and only the SUBTYPE says which. The raws answer it outright: a
-- metal-capable piece carries the METAL flag (greaves: HARD, METAL, BARRED, SHAPED) and a
-- garment does not (trousers: SOFT, LEATHER, WOVEN_THREAD).
--
-- Pinning copper to a garment is the bug this exists to stop, and NOT because the order is
-- impossible -- DF takes it. The forge makes the trousers out of copper and hands the noble a
-- metal garment: this fort had SIX copper trousers in it, quality 4 and 5, made by three of
-- its own dwarves, with bars spent on clothing a clothier would have woven for free.
local function metal_capable(m)
    local def = subtype_def(m)
    if not def then return false end
    local ok, metal = pcall(function() return def.props.flags.METAL end)
    return ok and metal == true
end

-- what a garment may be made of, from its own raws: SOFT means it can be woven, LEATHER means
-- it can be cut from a hide. Trousers are both; a sock is only SOFT.
local function garment_categories(def)
    local out = {}
    local ok = pcall(function()
        if def.props.flags.LEATHER then out[#out + 1] = 'leather' end
        if def.props.flags.SOFT then
            out[#out + 1] = 'plant'; out[#out + 1] = 'yarn'; out[#out + 1] = 'silk'
        end
    end)
    if not ok or #out == 0 then out = {'plant', 'yarn', 'silk', 'leather'} end
    return out
end

-- Usable stock per garment category. Same rule as the metal and wood counts above: what is
-- forbidden, claimed by a job, owned, rotten or an artifact is not stock.
local function garment_stocks()
    local function usable(it)
        return not it.flags.forbid and not it.flags.dump and not it.flags.in_job
            and not it.flags.rotten and not it.flags.owned and not it.flags.artifact
    end
    local n = {plant = 0, silk = 0, yarn = 0, leather = 0}
    for _, it in ipairs(df.global.world.items.other.CLOTH or {}) do
        if usable(it) then
            local mi = dfhack.matinfo.decode(it)
            local f = mi and mi.material and mi.material.flags
            local c = f and (f.SILK and 'silk' or f.YARN and 'yarn' or 'plant') or 'plant'
            n[c] = n[c] + (it.stack_size or 1)
        end
    end
    for _, it in ipairs(df.global.world.items.other.SKIN_TANNED or {}) do
        if usable(it) then n.leather = n.leather + (it.stack_size or 1) end
    end
    return n
end

-- pick a material the order can actually be made from. Returns a description, or
-- nil if it cannot be fulfilled at all (so the caller skips it).
-- Pick a material the order can actually be made from, IN THE AMOUNT THE MANDATE ASKS FOR.
-- Returns a description, or nil if it cannot be fulfilled at all (so the caller skips it).
--
-- Every branch asks "have I got enough for all of them", not "have I got one", and falls
-- through to the next material when the answer is no. A mandate is a deadline with a
-- punishment on the end of it: an order pinned to a material that runs out after the third
-- earring is worse than an order made of something duller that finishes.
-- module-level so a running fort can be asked what it would choose, without queueing
function choose_material(o, policy, m, amount)
    amount = math.max(1, amount or 1)
    -- a mandate that demands a specific material: honour it (no substitution -- the noble
    -- asked for that, and a substitute does not satisfy the mandate however much of it we have)
    if m.mat_type and m.mat_type >= 0 then
        o.mat_type = m.mat_type
        o.mat_index = m.mat_index
        local mi = dfhack.matinfo.decode(m.mat_type, m.mat_index)
        return mi and mi:toString() or 'specified material'
    end
    if policy == G then
        if metal_capable(m) then
            local mt, mi, name = pick_metal(amount)
            if mt then
                o.mat_type, o.mat_index = mt, mi
                return name
            end
            return nil   -- metal gear and no metal: cannot fulfil
        end
        -- A GARMENT. Leaving the material open is NOT enough -- the forge can take an
        -- unpinned MakePants and hand back copper trousers, which is how six of them got
        -- made here -- so the order is pinned to a material CATEGORY instead, which no metal
        -- belongs to. One category, not several: every order blueprint DFHack ships sets
        -- exactly one, and a combination is unproven.
        local def = subtype_def(m)
        if not def then return 'any material (mandate named no subtype)' end
        local stocks = garment_stocks()
        local allowed = garment_categories(def)
        local pick, pickn
        for _, c in ipairs(allowed) do            -- enough for the whole mandate, most first
            local have = stocks[c] or 0
            if have >= amount and (not pick or have > pickn) then pick, pickn = c, have end
        end
        if not pick then                          -- short everywhere: take the deepest pile
            for _, c in ipairs(allowed) do
                local have = stocks[c] or 0
                if not pick or have > pickn then pick, pickn = c, have end
            end
        end
        o.material_category[pick] = true
        return ('%s (%d in stock)'):format(pick, pickn or 0)
    elseif policy == W then
        if wood_logs() >= amount then
            o.material_category.wood = true
            return 'wood'
        end
        local mt, mi, name = pick_metal(amount)
        if mt then                                  -- no wood: metal will do for furniture
            o.mat_type, o.mat_index = mt, mi
            return name .. ' (not enough wood)'
        end
        return 'any material'   -- nothing to pin to: leave unconstrained (stone/bone/...)
    elseif policy == C then
        local mt, mi, name = pick_metal(amount)
        if mt then
            o.mat_type, o.mat_index = mt, mi
            return name
        end
        return nil   -- no metal at all: cannot fulfil
    elseif policy == CW then
        -- copper first, then any metal with enough bars, then wood: the metal one is worth far
        -- more to the noble who mandated it, but must never make the mandate impossible
        local mt, mi, name = pick_metal(amount)
        if mt and not name:find('only %d') then
            o.mat_type, o.mat_index = mt, mi
            return name
        end
        if wood_logs() >= amount then
            o.material_category.wood = true
            return mt and 'wood (not enough metal bars)' or 'wood (no metal bars)'
        end
        if mt then                                  -- short of both: the metal is worth more
            o.mat_type, o.mat_index = mt, mi
            return name
        end
        return 'any material'
    elseif policy == S then
        -- Obsidian first: worthless to trade and endlessly renewable from a magma/water cast,
        -- so spending it on a whim costs nothing. GABBRO next -- the commonest dull stone in a
        -- fort cut out of it, and no more valuable than the floor it came from. Only when
        -- neither is available (or the stone settings hold it back) is the order left open,
        -- which is the one thing that cannot fail outright.
        local ob, why = usable_stone('OBSIDIAN', amount)
        if ob then
            o.mat_type, o.mat_index = ob.type, ob.index
            return 'obsidian'
        end
        local mt, mi, name, short = pick_stone(amount)
        if mt then
            o.mat_type, o.mat_index = mt, mi
            -- one parenthetical, not two: why obsidian was passed over, and (if it applies)
            -- that even this pile is smaller than the mandate
            return ('%s (%s)'):format(name, short and (why .. '; ' .. short) or why)
        end
        return 'any material (' .. why .. ')'
    end
    return 'any material'   -- A: unconstrained (uses any available stone/etc.)
end

local function item_label(m)
    local tok = df.item_type[m.item_type]
    return tok and tok:lower():gsub('_', ' ') or 'goods'
end

-- ---- naming the order for the announcement --------------------------------

-- Names what the ORDER will make, count-correct. Only 'sub' orders carry a subtype: a
-- 'fixed' job makes whatever the workshop offers (a TOY mandate names one toy, but
-- MakeToy is not pinned to it), so naming the mandate's subtype there would describe an
-- order we did not queue.
local function order_label(m, map)
    local n = m.amount_remaining
    if map.kind == 'sub' then
        local vec = SUBTYPE_VEC[m.item_type]
        local def = vec and m.item_subtype >= 0 and df.global.world.raws.itemdefs[vec][m.item_subtype]
        if def then
            local one, many = def.name, def.name_plural
            local name = (n == 1) and (one ~= '' and one or many) or (many ~= '' and many or one)
            if name ~= '' then return name end
        end
    end
    local name = item_label(m)
    -- item tokens are singular ('cage', 'statue') bar the few already plural ('blocks',
    -- 'shoes', 'trapparts'), which must not collect a second s
    if n ~= 1 and name:sub(-1) ~= 's' then name = name .. 's' end
    return name
end

local function noble_name(m)
    local ok, name = pcall(function()
        return m.unit and dfhack.translation.translateName(dfhack.units.getVisibleName(m.unit))
    end)
    if ok and name and name ~= '' then return name end
    return 'a noble'
end

-- exposed for other tools (e.g. the mandate notification): is there already a
-- manager order that would fulfil this Make mandate?
function has_order_for(m)
    if m.mode ~= df.mandate_type.Make then return false end
    local map = MAP[m.item_type]
    if not map then return false end
    local it, sub = order_target(m, map)
    return has_fulfillable_order(map.job, it, sub)
end

-- An announcement per order queued, in the report log like auto-elf-chop's. The
-- background service is silent otherwise -- its console output goes to a DFHack window
-- nobody is watching mid-game -- so this is the only place the fort is told that a
-- mandate is being answered, and with what. Fired where the order is inserted, so the
-- one-shot command announces on the same terms as the service. pcall'd: a naming failure
-- must never take the queuing pass down with it.
local function announce_order(m, desc)
    pcall(dfhack.gui.showAnnouncement,
        ('Mandate from %s: work order queued for %s.'):format(noble_name(m), desc),
        COLOR_LIGHTGREEN, true)
end

-- scan all Make mandates and queue orders; returns lists of {queued, existing, skipped}
local function scan_and_queue()
    local mandates = df.global.world.mandates.all
    local queued, skipped, existing = {}, {}, {}
    for i = 0, #mandates - 1 do
        local m = mandates[i]
        if m.mode == df.mandate_type.Make and m.amount_remaining > 0 then
            local map = MAP[m.item_type]
            local label = item_label(m)
            if not map then
                table.insert(skipped, label)
            else
                local it, sub = order_target(m, map)
                if has_fulfillable_order(map.job, it, sub) then
                    table.insert(existing, label)
                else
                    local o = df.manager_order:new()
                    o.job_type = map.job
                    o.item_type = it
                    o.item_subtype = sub
                    o.amount_total = m.amount_remaining
                    o.amount_left = m.amount_remaining
                    o.frequency = 0
                    o.status.validated = true
                    o.status.active = true
                    local matdesc = choose_material(o, map.mat, m, m.amount_remaining)
                    if matdesc then
                        local mo = df.global.world.manager_orders
                        o.id = mo.manager_order_next_id
                        mo.manager_order_next_id = o.id + 1
                        mo.all:insert('#', o)
                        local desc = ('%d %s (%s)'):format(
                            m.amount_remaining, order_label(m, map), matdesc)
                        table.insert(queued, desc)
                        announce_order(m, desc)
                    else
                        o:delete()
                        table.insert(skipped, label .. ' (no material available)')
                    end
                end
            end
        end
    end
    return queued, existing, skipped
end

-- the active manager order currently fulfilling this Make mandate, or nil
local function order_for_mandate(m)
    local map = MAP[m.item_type]
    if not map then return nil end
    local it, sub = order_target(m, map)
    local all = df.global.world.manager_orders.all
    for i = 0, #all - 1 do
        local o = all[i]
        if o.job_type == map.job and o.item_type == it and o.item_subtype == sub and o.status.active then
            return o
        end
    end
end

-- Run every mandate order's workshop jobs at TOP priority (job.flags.do_now -- what the "Make top
-- priority" toggle sets). Noble mandates have a DEADLINE and a punishment for missing it, and the
-- forge is often saturated with other prioritized work -- notably military-uniforms marks ALL its
-- gear jobs do_now -- which otherwise starves the mandate so the item never gets made. Matched by
-- job.order_id so only mandate orders' jobs are touched. Mirrors military-uniforms' own pass.
local function prioritize_mandate_jobs()
    local ids = {}
    local mandates = df.global.world.mandates.all
    for i = 0, #mandates - 1 do
        local m = mandates[i]
        if m.mode == df.mandate_type.Make and m.amount_remaining > 0 then
            local o = order_for_mandate(m)
            if o then ids[o.id] = true end
        end
    end
    if not next(ids) then return end
    local link = df.global.world.jobs.list.next
    local guard = 0
    while link and guard < 6000 do
        guard = guard + 1
        local j = link.item
        if j and j.order_id and ids[j.order_id] and not j.flags.do_now then
            j.flags.do_now = true
        end
        link = link.next
    end
end

-- ---- enable / background service machinery --------------------------------

enabled = enabled or false

function isEnabled()
    return enabled
end

-- a background cycle: queue silently, but report anything newly queued
local function do_cycle()
    if not dfhack.world.isFortressMode() then return end
    local queued = scan_and_queue()
    prioritize_mandate_jobs()
    if #queued > 0 then
        print(('auto-mandate: queued %d order%s for new mandates:'):format(
            #queued, #queued == 1 and '' or 's'))
        for _, s in ipairs(queued) do print('  + ' .. s) end
    end
end

local function persist()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {enabled = enabled})
end

-- We drive the daily cycle off a per-frame heartbeat gated on the game calendar,
-- NOT repeat-util's tick/day timeouts: on this build those count rendered frames
-- (many calendar ticks each) and fire only every ~3 game-days, so "daily" never
-- happened. A 'frames' timeout fires every frame (~sub-tick granularity, verified)
-- so checking the calendar delta gives an accurate once-per-day trigger.
local DAY_TICKS = 1200 * CYCLE_DAYS
local last_run = nil

-- Generation guard so only the newest heartbeat loop survives. Held in dfhack.internal, not
-- a local: `reqscript` builds fresh locals on reload, so a local counter strands the previous
-- chunk's heartbeat holding a generation nothing can bump -- and this loop queues orders, so a
-- stranded one goes on filling mandates with the old code beside the new.
local function hb_gen(set)
    if set ~= nil then dfhack.internal.auto_mandate_hb_gen = set end
    return dfhack.internal.auto_mandate_hb_gen or 0
end

local function now_abs()
    return df.global.cur_year * 403200 + df.global.cur_year_tick
end

local function start()
    enabled = true
    last_run = nil               -- run on the next heartbeat
    local my_gen = hb_gen() + 1
    hb_gen(my_gen)
    local prio = 0
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen() then return end   -- stale/stopped: end loop
        local now = now_abs()
        if not last_run or now - last_run >= DAY_TICKS then
            last_run = now
            do_cycle()
        end
        -- keep mandate jobs top-priority ~once a second (jobs get posted between daily cycles)
        prio = prio + 1
        if prio >= 50 then prio = 0; pcall(prioritize_mandate_jobs) end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen(hb_gen() + 1)         -- invalidate any running heartbeat loop
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode()
            and dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false}).enabled
        then
            start()
        end
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

-- exported so it can be driven via reqscript (the `enable` command goes through
-- run_script, which on this build can serve a stale cached copy)
function set_enabled(on)
    if on then start() else stop() end
    enabled = on
    dfhack.persistent.saveSiteData(GLOBAL_KEY, {enabled = enabled})
    return enabled
end

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then
        qerror('auto-mandate can only be enabled in fortress mode')
    end
    if dfhack_flags.enable_state then start() else stop() end
    persist()
    print('auto-mandate: ' .. (enabled and 'enabled (background)' or 'disabled'))
else
    -- one-shot: queue now and print a full summary
    if not dfhack.world.isFortressMode() then
        qerror('auto-mandate only works in fortress mode')
    end
    local queued, existing, skipped = scan_and_queue()
    prioritize_mandate_jobs()
    if #queued == 0 and #existing == 0 and #skipped == 0 then
        print('auto-mandate: no production mandates to fill.')
    else
        if #queued > 0 then
            print(('auto-mandate: queued %d work order%s:'):format(#queued, #queued == 1 and '' or 's'))
            for _, s in ipairs(queued) do print('  + ' .. s) end
        end
        if #existing > 0 then
            print(('  (%d mandate%s already had a matching order)'):format(
                #existing, #existing == 1 and '' or 's'))
        end
        if #skipped > 0 then
            print('  skipped (no known recipe): ' .. table.concat(skipped, ', '))
        end
    end
end
