-- Adventurer creation: replace the default starting items with a proper kit.
--@module = true
--[[
embark/adventurer-default-items
===============================

Tags: adventure | embark | items

Run on the **Equipment** page of adventurer creation.  Clears the default picks
and buys, if the civilization offers them:

- full copper gear: breastplate, mail shirt, helm, 2 gauntlets, 2 high boots,
  greaves, shield, and your trained weapon (whatever weapon the archetype's
  default loadout held; a short sword if it held none)
- a quiver
- a backpack -- skipped when DF's free adventurer kit already granted one
- 5 food, strawberries preferred, else any berry, else the first plant food

Whatever points remain then upgrade, in order: weapon to iron; then to bronze:
gauntlets, high boots, greaves, helm, breastplate, mail shirt; then weapon to
steel (when the civ actually offers steel); then shield to bronze.  Leftover
points stay unspent.

Why data surgery instead of driving the UI: the Available/Your Items list rows
ignore fed mouse events (hardware-hover-gated, like the adv context menu), so
the picker cannot be clicked programmatically.  Everything DF's own click
handler would do is replicated instead, and every piece of it was verified
live on this build:

- `csheet.s_item[cat]` holds the picked items as real item objects registered
  in `world.items.all` and NOWHERE else (no `items.other` buckets), at pos
  (-30000,-30000,-30000), quality 0, `flags.foreign` set, maker_race = the
  adventurer's race (so armor is correctly sized).
- `csheet.etl.list[cat]` lists what the civ offers as (item_type, item_subtype,
  mattype, matindex) tuples; s_item and etl.list share the same 107 category
  indices (11 weapons, 16-21 armor slots, 29/30/31 meat/fish/plants, 46 flasks,
  47 quivers, 48 backpacks).
- an item's point cost is exactly `dfhack.items.getItemBaseValue(type, subtype,
  mat, matindex)` (times stack size for food), so removing and adding items
  keeps `eqpet_points` accounting exact.

    embark/adventurer-default-items       run it on the Equipment page
]]

local CAT = {
    WEAPON = 11, ARMOR = 16, HELM = 17, GLOVES = 18, SHOES = 19,
    PANTS = 20, SHIELD = 21, CHEESE = 26, MEAT = 29, FISH = 30,
    PLANT = 31, QUIVER = 47, BACKPACK = 48,
}

-- per-category item class and itemdef lookup for constructing picks
local CLASS = {
    [CAT.WEAPON] = df.item_weaponst,   [CAT.ARMOR] = df.item_armorst,
    [CAT.HELM] = df.item_helmst,       [CAT.GLOVES] = df.item_glovesst,
    [CAT.SHOES] = df.item_shoesst,     [CAT.PANTS] = df.item_pantsst,
    [CAT.SHIELD] = df.item_shieldst,   [CAT.QUIVER] = df.item_quiverst,
    [CAT.BACKPACK] = df.item_backpackst, [CAT.PLANT] = df.item_plantst,
}
local DEFS = {
    [CAT.WEAPON] = df.itemdef_weaponst, [CAT.ARMOR] = df.itemdef_armorst,
    [CAT.HELM] = df.itemdef_helmst,     [CAT.GLOVES] = df.itemdef_glovesst,
    [CAT.SHOES] = df.itemdef_shoesst,   [CAT.PANTS] = df.itemdef_pantsst,
    [CAT.SHIELD] = df.itemdef_shieldst,
}

local function sheet()
    local vs = dfhack.gui.getCurViewscreen(true)
    while vs and not df.viewscreen_setupadventurest:is_instance(vs) do vs = vs.parent end
    if not vs or vs.mode ~= 5 then return end
    local idx = vs.active_sheet_index
    if idx < 0 or idx >= #vs.csheet then idx = 0 end
    return vs.csheet[idx]
end

local function matname(e)
    local ok, mi = pcall(dfhack.matinfo.decode, e.mattype, e.matindex)
    return ok and mi and mi:toString() or '?'
end

local function cost_of(e, n)
    return dfhack.items.getItemBaseValue(e.item_type, e.item_subtype,
        e.mattype, e.matindex) * (n or 1)
end

-- the civ's offer for (category, itemdef id, material name); any of the last
-- two may be nil to match anything
local function offered(cs, cat, def_id, mat)
    local list = cs.etl.list[cat]
    local defs = DEFS[cat]
    for i = 0, #list - 1 do
        local e = list[i]
        local ok = true
        if def_id then
            local d = defs and defs.find(e.item_subtype)
            ok = d and d.id == def_id
        end
        if ok and mat and matname(e) ~= mat then ok = false end
        if ok then return e end
    end
end

-- first material of `ladder` the civ offers for this piece
local function best_mat(cs, cat, def_id, ladder)
    for _, m in ipairs(ladder) do
        local e = offered(cs, cat, def_id, m)
        if e then return e end
    end
    return offered(cs, cat, def_id, nil)      -- anything at all
end

-- ---- item construction ------------------------------------------------------

-- Everything the picker's own items carry, measured live: registered in
-- world.items.all only, pos nowhere, foreign flag, maker_race = adventurer race.
local function build_item(cs, cat, e, stack)
    local it = CLASS[cat]:new()
    it.id = df.global.item_next_id
    df.global.item_next_id = df.global.item_next_id + 1
    if DEFS[cat] then it.subtype = DEFS[cat].find(e.item_subtype) end
    it.mat_type, it.mat_index = e.mattype, e.matindex
    it.pos.x, it.pos.y, it.pos.z = -30000, -30000, -30000
    it.flags.foreign = true
    if stack and stack > 1 then it.stack_size = stack end
    pcall(function() it.maker_race = cs.race end)     -- food items have no maker
    df.global.world.items.all:insert('#', it)
    cs.s_item[cat]:insert('#', it)
    return it
end

local function remove_item(cs, cat, idx)
    local it = cs.s_item[cat][idx]
    cs.s_item[cat]:erase(idx)
    local all = df.global.world.items.all
    for i = #all - 1, 0, -1 do
        if all[i].id == it.id then all:erase(i) break end
    end
    it:delete()
end

-- ---- the plan ---------------------------------------------------------------

local COPPER_FIRST = {'copper', 'bronze', 'iron'}

local function run()
    local cs = sheet()
    if not cs then
        qerror('run this during adventurer creation (Equipment page)')
    end

    -- trained weapon = whatever weapon the default loadout holds; sword if none
    local weapon_def = 'ITEM_WEAPON_SWORD_SHORT'
    if #cs.s_item[CAT.WEAPON] > 0 then
        local w = cs.s_item[CAT.WEAPON][0]
        if w.subtype then weapon_def = w.subtype.id end
    end

    -- refund every current pick
    local refunded = 0
    for cat = 0, #cs.etl.list - 1 do
        local vec = cs.s_item[cat]
        for i = #vec - 1, 0, -1 do
            local it = vec[i]
            refunded = refunded + dfhack.items.getItemBaseValue(it:getType(),
                it:getSubtype(), it.mat_type, it.mat_index) * math.max(1, it.stack_size)
            remove_item(cs, cat, i)
        end
    end
    local points = cs.eqpet_points + refunded

    -- the base kit, in buy-priority order
    local plan = {}   -- {cat=, entry=, count=, label=}
    local function want(cat, def_id, count, label)
        local e = best_mat(cs, cat, def_id, COPPER_FIRST)
        if not e then
            print(('  no %s offered by this civilization -- skipped'):format(label))
            return
        end
        plan[#plan + 1] = {cat = cat, entry = e, count = count or 1, label = label}
    end
    want(CAT.WEAPON, weapon_def, 1, 'weapon (' .. weapon_def .. ')')
    want(CAT.SHOES, 'ITEM_SHOES_BOOTS', 2, 'high boots')
    want(CAT.PANTS, 'ITEM_PANTS_GREAVES', 1, 'greaves')
    want(CAT.ARMOR, 'ITEM_ARMOR_BREASTPLATE', 1, 'breastplate')
    want(CAT.ARMOR, 'ITEM_ARMOR_MAIL_SHIRT', 1, 'mail shirt')
    want(CAT.GLOVES, 'ITEM_GLOVES_GAUNTLETS', 2, 'gauntlets')
    want(CAT.HELM, 'ITEM_HELM_HELM', 1, 'helm')
    want(CAT.SHIELD, 'ITEM_SHIELD_SHIELD', 1, 'shield')
    do
        local e = offered(cs, CAT.QUIVER, nil, nil)
        if e then plan[#plan + 1] = {cat = CAT.QUIVER, entry = e, count = 1, label = 'quiver'} end
    end
    -- DF's free adventurer kit sometimes includes a backpack (a picker-style
    -- item in world.items outside s_item); only buy one when it doesn't.
    -- In an existing world items.all is huge, so only look when it's tiny --
    -- worst case we spend 10 points on a spare backpack.
    local have_free_backpack = false
    local all = df.global.world.items.all
    if #all < 1000 then
        for i = 0, #all - 1 do
            local it = all[i]
            if it:getType() == df.item_type.BACKPACK
                    and it.pos.x == -30000 and it.flags.foreign then
                have_free_backpack = true break
            end
        end
    end
    if not have_free_backpack then
        local e = offered(cs, CAT.BACKPACK, nil, nil)
        if e then plan[#plan + 1] = {cat = CAT.BACKPACK, entry = e, count = 1, label = 'backpack'} end
    end
    -- 5 food: strawberries > any berry > first plant food
    do
        local list, pick = cs.etl.list[CAT.PLANT], nil
        for _, pat in ipairs({'strawberr', 'berr'}) do
            for i = 0, #list - 1 do
                if matname(list[i]):lower():find(pat, 1, true) then pick = list[i] break end
            end
            if pick then break end
        end
        if not pick and #list > 0 then pick = list[0] end
        if not pick then
            for _, cat in ipairs({CAT.MEAT, CAT.FISH, CAT.CHEESE}) do
                if #cs.etl.list[cat] > 0 then
                    pick = cs.etl.list[cat][0]
                    plan[#plan + 1] = {cat = cat, entry = pick, count = 1, stack = 5, label = 'food'}
                    pick = nil
                    break
                end
            end
        else
            plan[#plan + 1] = {cat = CAT.PLANT, entry = pick, count = 1, stack = 5,
                label = 'food (' .. matname(pick) .. ')'}
        end
    end

    -- buy the base kit
    local bought = {}
    for _, p in ipairs(plan) do
        local c = cost_of(p.entry, (p.stack or 1)) * p.count
        if c <= points then
            for _ = 1, p.count do build_item(cs, p.cat, p.entry, p.stack) end
            points = points - c
            bought[#bought + 1] = p
            print(('  %-28s %s%s  %d pts'):format(p.label, matname(p.entry),
                p.count > 1 and (' x' .. p.count) or '', c))
        else
            print(('  cannot afford %s (%d pts, %d left) -- skipped'):format(p.label, c, points))
        end
    end

    -- upgrades, in the requested order; each replaces the bought items in place
    local function upgrade(label_pat, mat)
        for _, p in ipairs(bought) do
            if p.label:find(label_pat, 1, true) and matname(p.entry) ~= mat then
                local e = offered(cs, p.cat, p.entry.item_subtype
                        and DEFS[p.cat] and DEFS[p.cat].find(p.entry.item_subtype).id or nil, mat)
                if e then
                    local delta = (cost_of(e) - cost_of(p.entry)) * p.count
                    if delta <= points then
                        local vec = cs.s_item[p.cat]
                        for i = #vec - 1, 0, -1 do
                            if vec[i].mat_type == p.entry.mattype
                                    and vec[i].mat_index == p.entry.matindex
                                    and vec[i]:getSubtype() == p.entry.item_subtype then
                                remove_item(cs, p.cat, i)
                            end
                        end
                        for _ = 1, p.count do build_item(cs, p.cat, e, p.stack) end
                        points = points - delta
                        p.entry = e
                        print(('  upgraded %s to %s (+%d pts)'):format(p.label, mat, delta))
                    end
                end
            end
        end
    end
    upgrade('weapon', 'iron')
    for _, piece in ipairs({'gauntlets', 'high boots', 'greaves', 'helm', 'breastplate', 'mail shirt'}) do
        upgrade(piece, 'bronze')
    end
    upgrade('weapon', 'steel')
    upgrade('shield', 'bronze')

    cs.eqpet_points = points
    cs.scroll_position_item = 0
    print(('embark/adventurer-default-items: done, %d points left over'):format(points))
end

if dfhack_flags.module then return end
run()
