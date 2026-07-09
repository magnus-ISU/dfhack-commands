-- Parse freeform text ("3 steel swords", "make soap from tallow", "collect sand")
-- into a manager work order, and offer a text box + live autocomplete on the Work
-- Orders screen. This file is the PARSER/RESOLVER core (dry-run testable) plus the
-- overlay UI.
--@module = true
--[[
    quick-order <text>            dry-run: print what it resolved to
    quick-order --create <text>   actually create the order (one-time)

Grammar:
  [r] <amount?> <material descriptor?> <item-or-job>
  * leading r / rN  -> repeating
  * amount: digits, rN, or a spelled number (one..twenty, a/an); default 1
  * material descriptor: a category (wood/wooden/cloth), a class (stone/rock/metal/
    glass), a specific material (gabbro/steel), and/or a property (magma safe)
  * item-or-job: fuzzy, matched against EVERY orderable thing --
      - reactions the fort is allowed (make soap from tallow, brew drink from plant,
        make steel bars, make X dye, instruments...) -> a CustomReaction order
      - fixed-material items (bed, coffin, mechanism, statue, crafts...)
      - weapons/armor/ammo/tools/trapcomps (by subtype, e.g. "short sword")
      - processing/gathering jobs (collect sand, milk, shear, melt, cut gems, meal)
  Matching is a subsequence scorer, so partials and dropped words work
  ("soap" -> make soap from tallow, "steel bars" -> make steel bars, not barrels).
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local MAGMA_TEMP = 12000

-- ---- text helpers --------------------------------------------------------

local function norm(s) return (s or ''):lower():gsub('[%-_]', ' ') end
local function singular(w) return (#w > 3 and w:sub(-1) == 's') and w:sub(1, -2) or w end
local function toks_of(s) local t = {}; for w in norm(s):gmatch('%S+') do t[#t + 1] = w end; return t end

-- ---- vocab: items / jobs / reactions -------------------------------------

-- fixed-material items: the job implies the item. {name, item_type, job}
local FIXED = {
    {'mechanism', 'TRAPPARTS', 'ConstructMechanisms'}, {'door', 'DOOR', 'ConstructDoor'},
    {'floodgate', 'FLOODGATE', 'ConstructFloodgate'}, {'bed', 'BED', 'ConstructBed'},
    {'chair', 'CHAIR', 'ConstructThrone'}, {'throne', 'CHAIR', 'ConstructThrone'},
    {'coffin', 'COFFIN', 'ConstructCoffin'}, {'casket', 'COFFIN', 'ConstructCoffin'},
    {'table', 'TABLE', 'ConstructTable'},
    {'chest', 'BOX', 'ConstructChest'}, {'box', 'BOX', 'ConstructChest'},
    {'cabinet', 'CABINET', 'ConstructCabinet'}, {'armor stand', 'ARMORSTAND', 'ConstructArmorStand'},
    {'weapon rack', 'WEAPONRACK', 'ConstructWeaponRack'}, {'bin', 'BIN', 'ConstructBin'},
    {'barrel', 'BARREL', 'MakeBarrel'}, {'bucket', 'BUCKET', 'MakeBucket'},
    {'cage', 'CAGE', 'MakeCage'}, {'statue', 'STATUE', 'ConstructStatue'},
    {'block', 'BLOCKS', 'ConstructBlocks'}, {'blocks', 'BLOCKS', 'ConstructBlocks'},
    {'hatch cover', 'HATCH_COVER', 'ConstructHatchCover'}, {'grate', 'GRATE', 'ConstructGrate'},
    {'amulet', 'AMULET', 'MakeAmulet'}, {'ring', 'RING', 'MakeRing'},
    {'bracelet', 'BRACELET', 'MakeBracelet'}, {'earring', 'EARRING', 'MakeEarring'},
    {'crown', 'CROWN', 'MakeCrown'}, {'scepter', 'SCEPTER', 'MakeScepter'},
    {'figurine', 'FIGURINE', 'MakeFigurine'}, {'goblet', 'GOBLET', 'MakeGoblet'},
    {'toy', 'TOY', 'MakeToy'}, {'flask', 'FLASK', 'MakeFlask'}, {'totem', 'TOTEM', 'MakeTotem'},
}

-- subtype-bearing item classes: itemdef vector -> {job, item_type}
local SUBTYPED = {
    weapons = {'MakeWeapon', 'WEAPON'}, armor = {'MakeArmor', 'ARMOR'},
    helms = {'MakeHelm', 'HELM'}, pants = {'MakePants', 'PANTS'},
    gloves = {'MakeGloves', 'GLOVES'}, shoes = {'MakeShoes', 'SHOES'},
    shields = {'MakeShield', 'SHIELD'}, ammo = {'MakeAmmo', 'AMMO'},
    tools = {'MakeTool', 'TOOL'}, trapcomps = {'MakeTrapComponent', 'TRAPCOMP'},
}

-- processing / gathering jobs (no makeable "item"; the job IS the order). Each may
-- carry several natural-language aliases. Material is optional (e.g. cut gems FROM
-- glass) and never forced.
local SPECIAL = {
    {job = 'CollectSand',     names = {'collect sand', 'gather sand', 'sand'}},
    {job = 'MilkCreature',    names = {'milk creature', 'milk animal', 'milk'}},
    {job = 'ShearCreature',   names = {'shear creature', 'shear animal', 'shear'}},
    {job = 'MeltMetalObject', names = {'melt metal object', 'melt object', 'melt item', 'melt'}},
    {job = 'CutGems',         names = {'cut gems', 'cut gem', 'cut glass'}},
    {job = 'EncrustWithGems', names = {'encrust with gems', 'encrust gems'}},
    {job = 'MillPlants',      names = {'mill plants', 'mill plant', 'mill'}},
    {job = 'ProcessPlants',   names = {'process plants', 'process plant'}},
    {job = 'ProcessPlantsBag',names = {'process plant to bag', 'process to bag'}},
    {job = 'ProcessPlantsVial',names = {'process plant to vial', 'extract to vial'}},
    {job = 'ProcessPlantsBarrel', names = {'process plant to barrel', 'extract to barrel'}},
    {job = 'RenderFat',       names = {'render fat', 'make tallow', 'render'}},
    {job = 'MakeCheese',      names = {'make cheese', 'cheese'}},
    {job = 'PrepareRawFish',  names = {'prepare raw fish', 'prepare fish', 'clean fish'}},
    {job = 'ExtractFromPlants',      names = {'extract from plants', 'extract plants'}},
    {job = 'ExtractFromRawFish',     names = {'extract from raw fish', 'extract fish'}},
    {job = 'ExtractFromLandAnimal',  names = {'extract from land animal', 'extract animal'}},
    {job = 'CatchLiveFish',   names = {'catch live fish', 'catch fish'}},
}

local vocab  -- built once: list of entries
-- entry = {name, kind='job'|'reaction', job, item_type=-1, item_subtype=-1,
--          reaction_name=nil, mat=nil, needs_mat=bool}

local function add_job(v, name, job, itype, sub, needs_mat)
    if not name or name == '' then return end
    local j = df.job_type[job]
    if not j then return end
    v[#v + 1] = {name = norm(name), kind = 'job', job = j,
                 item_type = itype and df.item_type[itype] or -1,
                 item_subtype = sub or -1, needs_mat = needs_mat and true or false}
end

local function build_vocab()
    if vocab then return vocab end
    local v = {}
    for _, e in ipairs(FIXED) do add_job(v, e[1], e[3], e[2], -1, true) end
    for vecname, spec in pairs(SUBTYPED) do
        local vec = df.global.world.raws.itemdefs[vecname]
        for i = 0, #vec - 1 do
            local def = vec[i]
            add_job(v, def.name, spec[1], spec[2], def.subtype, true)
            if def.name_plural and def.name_plural ~= def.name then
                add_job(v, def.name_plural, spec[1], spec[2], def.subtype, true)
            end
        end
    end
    for _, sp in ipairs(SPECIAL) do
        if df.job_type[sp.job] then
            for _, nm in ipairs(sp.names) do add_job(v, nm, sp.job, nil, -1, false) end
        end
    end
    -- meals: one PrepareMeal job, quality baked into mat_type (2 easy, 3 fine, 4 lavish;
    -- mat_index -1). Bare "meal"/"cook" default to lavish.
    if df.job_type.PrepareMeal then
        for _, ml in ipairs({
            {q = 4, names = {'lavish meal', 'meal', 'cook', 'cook meal'}},
            {q = 3, names = {'fine meal'}},
            {q = 2, names = {'easy meal', 'poor meal'}},
        }) do
            for _, nm in ipairs(ml.names) do
                v[#v + 1] = {name = norm(nm), kind = 'job', job = df.job_type.PrepareMeal,
                    item_type = -1, item_subtype = -1, needs_mat = false,
                    mat = {mat_type = ml.q, mat_index = -1}}
            end
        end
    end
    -- raw/rough glass: MakeRawGlass with the glass colour baked in as the material
    if df.job_type.MakeRawGlass then
        for _, g in ipairs({
            {'raw green glass', 'GLASS_GREEN'}, {'rough green glass', 'GLASS_GREEN'},
            {'raw clear glass', 'GLASS_CLEAR'}, {'rough clear glass', 'GLASS_CLEAR'},
            {'raw crystal glass', 'GLASS_CRYSTAL'}, {'rough crystal glass', 'GLASS_CRYSTAL'},
        }) do
            local mi = dfhack.matinfo.find(g[2])
            if mi then
                v[#v + 1] = {name = g[1], kind = 'job', job = df.job_type.MakeRawGlass,
                    item_type = -1, item_subtype = -1, needs_mat = false,
                    mat = {mat_type = mi.type, mat_index = mi.index}}
            end
        end
    end
    -- fort-orderable REACTIONS: permitted to this civ (source_enid -1 = universal,
    -- or == our civ) and NOT an adventure-mode reaction (ADV_* category, e.g. the
    -- "make wooden bed" carpentry ones -- fort furniture goes through the jobs above).
    local civ = df.global.plotinfo.civ_id
    local R = df.global.world.raws.reactions.reactions
    for i = 0, #R - 1 do
        local r = R[i]
        if (r.source_enid == -1 or r.source_enid == civ)
            and r.name ~= '' and not r.category:match('^ADV') then
            v[#v + 1] = {name = norm(r.name), kind = 'reaction',
                         job = df.job_type.CustomReaction, reaction_name = r.code,
                         item_type = -1, item_subtype = -1, needs_mat = false}
        end
    end
    vocab = v
    return v
end

-- ---- vocab: materials ----------------------------------------------------

-- words that are a job material_category (also usable as the "material" itself)
local CATEGORY_WORDS = {
    wood = 'wood', wooden = 'wood', cloth = 'cloth', silk = 'silk', leather = 'leather',
    bone = 'bone', shell = 'shell', yarn = 'yarn', pearl = 'pearl',
}
-- bare classes that are NOT order materials -> must resolve to a concrete one
local CLASS_WORDS = {stone = 'stone', rock = 'stone', metal = 'metal', glass = 'glass'}

local material_vocab
local function build_material_vocab()
    if material_vocab then return material_vocab end
    local m = {}
    local i = 0
    while df.inorganic_raw.find(i) do
        local ir = df.inorganic_raw.find(i)
        local name = ir.id:lower():gsub('_', ' ')
        local f = ir.material.flags
        m[name] = {mat_type = 0, mat_index = i,
                   is_metal = f.IS_METAL or false, is_stone = f.IS_STONE or false}
        i = i + 1
    end
    for _, g in ipairs({{'clear glass', 'GLASS_CLEAR'}, {'green glass', 'GLASS_GREEN'},
                        {'crystal glass', 'GLASS_CRYSTAL'}}) do
        local mi = dfhack.matinfo.find(g[2])
        if mi then m[g[1]] = {mat_type = mi.type, mat_index = mi.index, is_glass = true} end
    end
    -- plants, by their STRUCTURAL material -- lets "pig tail process plant" name the plant
    -- (ProcessPlants order with mat = <plant>:STRUCTURAL, e.g. 419:174)
    local plants = df.global.world.raws.plants.all
    for i = 0, #plants - 1 do
        local p = plants[i]
        local nm = (p.name or ''):lower()
        if nm ~= '' and not m[nm] then
            local mi = dfhack.matinfo.find(p.id .. ':STRUCTURAL')
            if mi then m[nm] = {mat_type = mi.type, mat_index = mi.index, is_plant = true} end
        end
    end
    material_vocab = m
    return m
end

local function is_magma_safe(mat_type, mat_index)
    local mi = dfhack.matinfo.decode(mat_type, mat_index)
    if not mi then return false end
    local h = mi.material.heat
    return h.melting_point > MAGMA_TEMP and h.boiling_point > MAGMA_TEMP
end

-- ---- fuzzy matching ------------------------------------------------------

-- Subsequence prefix scorer: every query word must prefix-match a name word, in
-- order (words may be skipped in the name -- so "soap" hits "make soap from tallow"
-- and "steel bars" hits "make steel bars"). 0 = reject. Higher = tighter match.
local function score_name(query, name)
    query, name = norm(query), norm(name)
    if query == name then return 100 end
    local q, n = toks_of(query), toks_of(name)
    if #q == 0 or #q > #n then
        -- allow query longer than name only via a whole-string substring (rare)
        return (name:find(query, 1, true) and 50) or 0
    end
    local i, matched, gaps, first = 1, 0, 0, nil
    for _, qt in ipairs(q) do
        local qs = singular(qt)
        local found
        for k = i, #n do
            local nt = n[k]
            if nt:sub(1, #qt) == qt or singular(nt):sub(1, #qs) == qs then found = k; break end
        end
        if not found then return 0 end
        matched = matched + 1
        if not first then first = found end
        gaps = gaps + (found - i)
        i = found + 1
    end
    local sc = 90 - (#n - matched) * 4 - gaps * 2
    if #q == #n then sc = sc + 6 end          -- query covered the whole name
    return math.max(sc, 1)
end

-- bare weapon nouns -> the typical military item
local ALIAS = {sword = 'short sword', axe = 'battle axe', hammer = 'war hammer',
    warhammer = 'war hammer', greataxe = 'great axe', bolt = 'bolts', arrow = 'arrows'}

-- best vocab entry for a list of right-side tokens; returns entry, score
local function best_item(tokens)
    if #tokens == 0 then return nil, 0 end
    local query = table.concat(tokens, ' ')
    if not query:find(' ') and ALIAS[singular(query)] then
        local want = ALIAS[singular(query)]
        for _, it in ipairs(build_vocab()) do if it.name == want then return it, 100 end end
    end
    local best, bs = nil, 0
    for _, it in ipairs(build_vocab()) do
        local s = score_name(query, it.name)
        -- tie-break toward shorter names (fewer words) so "bed" beats "trap bed" etc.
        if s > bs or (s == bs and best and #it.name < #best.name) then best, bs = it, s end
    end
    return best, bs
end

-- ---- material descriptor resolution --------------------------------------

local PROPERTY_WORDS = {['magma safe'] = 'magma', ['fire safe'] = 'fire', fireproof = 'fire',
    ['magma proof'] = 'magma'}

-- resolve left-side tokens -> {kind='category'|'specific'|'class'|'none', ...}
local function resolve_material(tokens, item, want_in_stock)
    local mats = build_material_vocab()
    local constraint
    local toks = {}
    for _, t in ipairs(tokens) do toks[#toks + 1] = norm(t) end
    local i, rest = 1, {}
    while i <= #toks do
        local two = toks[i] .. ' ' .. (toks[i + 1] or '')
        if PROPERTY_WORDS[two] then constraint = PROPERTY_WORDS[two]; i = i + 2
        elseif PROPERTY_WORDS[toks[i]] then constraint = PROPERTY_WORDS[toks[i]]; i = i + 1
        elseif toks[i] == 'made' or toks[i] == 'of' or toks[i] == 'from' then i = i + 1
        else rest[#rest + 1] = toks[i]; i = i + 1 end
    end

    if #rest == 0 and not constraint then return {kind = 'none'} end

    local class
    for _, w in ipairs(rest) do if CLASS_WORDS[w] then class = CLASS_WORDS[w] end end

    local function find_specific()
        if mats[table.concat(rest, ' ')] then return table.concat(rest, ' ') end
        for k = 1, #rest - 1 do
            local sp = rest[k] .. ' ' .. rest[k + 1]
            if mats[sp] then return sp end
        end
        for _, w in ipairs(rest) do if not CLASS_WORDS[w] and mats[w] then return w end end
    end

    local spec = find_specific()
    if spec then
        local mt = mats[spec]
        if constraint == 'magma' and not is_magma_safe(mt.mat_type, mt.mat_index) then
            return nil, ('%s is not magma-safe'):format(spec)
        end
        return {kind = 'specific', name = spec, mat_type = mt.mat_type, mat_index = mt.mat_index}
    end
    for _, w in ipairs(rest) do
        if CATEGORY_WORDS[w] then return {kind = 'category', category = CATEGORY_WORDS[w]} end
    end
    if class or constraint then
        local cls = class or 'stone'
        return {kind = 'class', class = cls, constraint = constraint,
                picked = want_in_stock and want_in_stock(cls, constraint, item)}
    end
    return nil, ('unknown material "%s"'):format(table.concat(rest, ' '))
end

-- ---- top-level parse -----------------------------------------------------

local WORDNUM = {one=1,two=2,three=3,four=4,five=5,six=6,seven=7,eight=8,nine=9,ten=10,
    eleven=11,twelve=12,fifteen=15,twenty=20,['a']=1,['an']=1,['dozen']=12}

-- redundant leading verbs to drop (reactions keep "make" in their own names, so
-- stripping the user's "make"/"prepare"/... still subsequence-matches them, and it
-- lets bare job names like "lavish meal" or "barrel" match). NOT the meaningful job
-- verbs (collect/milk/melt/cut/brew/process/shear) -- those stay.
local VERB = {make=1, prepare=1, cook=1, construct=1, forge=1, craft=1, build=1,
    produce=1, manufacture=1, create=1}

local STRONG = 80   -- a whole-phrase match this good wins outright (no material split)

local function slice(t, a, b) local o = {}; for k = a, b do o[#o + 1] = t[k] end; return o end

local function parse(input)
    local tokens = toks_of(input)
    if #tokens == 0 then return nil, 'empty' end

    local repeating = false
    local t1 = tokens[1]
    local rnum = t1:match('^r(%d+)$')
    if t1 == 'r' then repeating = true; table.remove(tokens, 1)
    elseif rnum then repeating = true; tokens[1] = rnum end

    local amount
    for idx, w in ipairs(tokens) do
        if w:match('^%d+$') then amount = tonumber(w); table.remove(tokens, idx); break
        elseif WORDNUM[w] then amount = WORDNUM[w]; table.remove(tokens, idx); break end
    end
    amount = amount or 1

    if #tokens > 1 and VERB[tokens[1]] then table.remove(tokens, 1) end
    if #tokens == 0 then return nil, 'no item' end

    local function ret(item, left, iscore)
        return {repeating = repeating, amount = amount, item = item, left = left, iscore = iscore}
    end

    -- 1) whole phrase as the item/reaction. A strong match wins outright, so
    --    "make steel bars" -> the reaction, never "steel" + "bars"->barrel.
    local witem, wscore = best_item(tokens)
    if witem and wscore >= STRONG then return ret(witem, {}, wscore) end

    -- 2) otherwise split: material may sit before OR after the item ("steel bed",
    --    "cut gems from glass"). Every boundary, both directions; material must
    --    resolve (or we fall back to ignoring those words, heavily penalised).
    local best
    local function consider(item_toks, mat_toks, item, iscore)
        local m, ignored = {kind = 'none'}, 0
        if #mat_toks > 0 then
            local r = resolve_material(mat_toks, item, most_in_stock)
            if r then m = r else ignored = #mat_toks end   -- unresolvable words -> ignore (penalised)
        end
        local total = iscore + #item_toks * 3 - #mat_toks - ignored * 10
        if not best or total > best.total then
            best = {total = total, item = item, left = (m.kind == 'none') and {} or mat_toks,
                    iscore = iscore}
        end
    end
    for cut = 1, #tokens - 1 do
        local L, Rt = slice(tokens, 1, cut), slice(tokens, cut + 1, #tokens)
        local ia, sa = best_item(Rt); if ia and sa > 0 then consider(Rt, L, ia, sa) end   -- material first
        local ib, sb = best_item(L);  if ib and sb > 0 then consider(L, Rt, ib, sb) end   -- material after
    end
    if witem and wscore > 0 then consider(tokens, {}, witem, wscore) end   -- whole phrase, no material

    if not best then return nil, 'no item recognized' end
    return ret(best.item, best.left, best.iscore)
end

-- can a metal/stone of this mat_index be forged into this item class?
local function mat_makes(item_type, mat_index)
    local ir = df.inorganic_raw.find(mat_index)
    if not ir then return false end
    local f = ir.material.flags
    local T = df.item_type
    if item_type == T.WEAPON then return f.ITEMS_WEAPON or f.ITEMS_WEAPON_RANGED or f.ITEMS_DIGGER
    elseif item_type == T.AMMO then return f.ITEMS_AMMO
    elseif item_type == T.ARMOR or item_type == T.HELM or item_type == T.PANTS
        or item_type == T.GLOVES or item_type == T.SHOES then return f.ITEMS_ARMOR end
    return true
end

-- ---- material legality ---------------------------------------------------
-- Body-armour subtypes carry material flags on their itemdef: METAL (breastplate),
-- LEATHER (leather armour), SOFT (cloth cloak/robe). A cloak is SOFT|LEATHER with NO
-- METAL flag, so "iron cloak" must be rejected; obsidian lacks ITEMS_ARMOR, so
-- "obsidian shoes" is caught by mat_makes.
local ARMOR_DEFVEC = {}
for t, vn in pairs({ARMOR = 'armor', HELM = 'helms', PANTS = 'pants',
                    GLOVES = 'gloves', SHOES = 'shoes'}) do
    if df.item_type[t] then ARMOR_DEFVEC[df.item_type[t]] = vn end
end
local function armor_flags(item)
    local vn = ARMOR_DEFVEC[item.item_type]
    if not vn or (item.item_subtype or -1) < 0 then return nil end
    local vec = df.global.world.raws.itemdefs[vn]
    for i = 0, #vec - 1 do if vec[i].subtype == item.item_subtype then return vec[i].props.flags end end
end

local WEAPONISH = {}   -- forged, metal-only goods
for _, t in ipairs({'WEAPON', 'AMMO'}) do if df.item_type[t] then WEAPONISH[df.item_type[t]] = true end end
local SHIELD_T = df.item_type.SHIELD

-- legality of a concrete inorganic (mt=0) on a restricted item
local function legal_inorganic(item, mi)
    local ir = df.inorganic_raw.find(mi)
    local ismetal = ir and ir.material.flags.IS_METAL
    if WEAPONISH[item.item_type] or ARMOR_DEFVEC[item.item_type] then
        if not mat_makes(item.item_type, mi) then
            return false, ('%s cannot be made into %s'):format(
                (ir and ir.id:lower():gsub('_', ' ')) or 'that', item.name)
        end
    end
    if item.item_type == SHIELD_T and not ismetal then
        return false, item.name .. ' can only be metal or wood'
    end
    if ismetal then
        local af = armor_flags(item)
        if af and not af.METAL then return false, item.name .. ' cannot be made of metal' end
    end
    return true
end

-- is the resolved material m legal for this item? returns true, or false + reason.
-- Only weapons/ammo, body armour, and shields are policed; furniture/crafts take anything.
local function legal_material(item, m)
    local it = item.item_type
    if not (WEAPONISH[it] or ARMOR_DEFVEC[it] or it == SHIELD_T) then return true end
    if m.kind == 'specific' or (m.kind == 'class' and m.picked) then
        local mt = m.kind == 'specific' and m.mat_type or m.picked.mat_type
        local mi = m.kind == 'specific' and m.mat_index or m.picked.mat_index
        if mt ~= 0 then return false, item.name .. ' cannot be made of that material' end
        return legal_inorganic(item, mi)
    elseif m.kind == 'class' then                -- no concrete pick: judge the class
        if m.class ~= 'metal' then return false, item.name .. ' cannot be made of ' .. m.class end
        return true                              -- metal is legal; stock is create_order's problem
    elseif m.kind == 'category' then             -- wood / leather / cloth / silk / yarn
        if WEAPONISH[it] then return false, item.name .. ' must be metal' end
        if it == SHIELD_T then
            if m.category ~= 'wood' then return false, item.name .. ' can only be metal or wood' end
            return true
        end
        local af = armor_flags(item)
        if af then
            if m.category == 'wood' then return false, item.name .. ' cannot be made of wood' end
            if m.category == 'leather' and not af.LEATHER then return false, item.name .. ' cannot be made of leather' end
            if (m.category == 'cloth' or m.category == 'silk' or m.category == 'yarn')
                and not af.SOFT then return false, item.name .. ' cannot be made of ' .. m.category end
        end
    end
    return true
end

-- pick the most-abundant concrete material of a class in stock that can make this item.
-- stone -> boulders, metal -> bars, glass -> the raw-glass materials.
function most_in_stock(class, constraint, item)
    if class == 'glass' then
        local mats = build_material_vocab()
        return mats['clear glass'] and {mat_type = mats['clear glass'].mat_type,
            mat_index = mats['clear glass'].mat_index, name = 'clear glass', count = 0}
    end
    local list = (class == 'stone' and df.global.world.items.other.BOULDER)
        or (class == 'metal' and df.global.world.items.other.BAR) or nil
    if not list then return nil end
    local econ = (class == 'stone') and df.global.plotinfo.economic_stone or nil
    local counts, fallback = {}, {}
    for _, it in ipairs(list) do
        if it.mat_type == 0 and ((constraint ~= 'magma') or is_magma_safe(0, it.mat_index))
            and (class ~= 'metal' or (df.inorganic_raw.find(it.mat_index)
                 and df.inorganic_raw.find(it.mat_index).material.flags.IS_METAL))
            and (not item or item.item_type == -1 or mat_makes(item.item_type, it.mat_index))
        then
            fallback[it.mat_index] = (fallback[it.mat_index] or 0) + it.stack_size
            if not (econ and econ[it.mat_index]) then
                counts[it.mat_index] = (counts[it.mat_index] or 0) + it.stack_size
            end
        end
    end
    local function pick(t) local b, bn; for mi, n in pairs(t) do if not bn or n > bn then b, bn = mi, n end end; return b, bn end
    local best, bestn = pick(counts)
    if not best then best, bestn = pick(fallback) end
    if not best then return nil end
    local ir = df.inorganic_raw.find(best)
    return {mat_type = 0, mat_index = best,
            name = ir and ir.id:lower():gsub('_', ' ') or '?', count = bestn}
end

-- bare (no-material) items that should default to WOOD -- either wood-only (bed) or
-- containers that can't be made of stone (barrel/bucket/bin/cage) so a stone default
-- would be an invalid order
local DEFAULT_WOOD = {}
for _, n in ipairs({'bed', 'barrel', 'bucket', 'bin', 'cage', 'weapon rack', 'armor stand'}) do
    DEFAULT_WOOD[n] = true
end
local METAL_ITEMS = {}
for _, t in ipairs({'WEAPON', 'AMMO', 'ARMOR', 'HELM', 'PANTS', 'GLOVES', 'SHOES', 'SHIELD'}) do
    METAL_ITEMS[df.item_type[t]] = true
end

-- when a material-requiring job is given no material, pick a sensible default
local function default_material(item)
    if DEFAULT_WOOD[item.name] then return {kind = 'category', category = 'wood'} end
    -- body armour: honour what the piece can actually be (a cloak is leather/cloth, not metal)
    local af = armor_flags(item)
    if af then
        if not af.METAL then
            if af.LEATHER then return {kind = 'category', category = 'leather'} end
            if af.SOFT then return {kind = 'category', category = 'cloth'} end
        end
    end
    if METAL_ITEMS[item.item_type] then
        local p = most_in_stock('metal', nil, item)
        if p then return {kind = 'specific', name = p.name, mat_type = p.mat_type, mat_index = p.mat_index} end
    end
    local p = most_in_stock('stone', nil, item)
    if p then return {kind = 'specific', name = p.name, mat_type = p.mat_type, mat_index = p.mat_index} end
    return {kind = 'category', category = 'wood'}   -- last resort
end

-- ---- resolve (parse + material) ------------------------------------------

-- returns a resolved plan {amount, repeating, item, mat, matname, desc} or nil,err
local function resolve(input)
    local p, err = parse(input)
    if not p then return nil, err end
    local item = p.item
    local mat, matname
    if item.kind == 'reaction' or item.mat then
        -- reaction bakes its own material; raw-glass items carry a baked mat
        mat = {kind = 'none'}
    else
        local m, merr = resolve_material(p.left, item, most_in_stock)
        if not m then return nil, merr end
        if m.kind == 'none' and item.needs_mat then m = default_material(item) end
        local ok, why = legal_material(item, m)
        if not ok then return nil, why end
        mat = m
        if m.kind == 'specific' then matname = m.name
        elseif m.kind == 'category' then matname = 'any ' .. m.category
        elseif m.kind == 'class' then matname = m.picked and m.picked.name or nil end
    end
    return {amount = p.amount, repeating = p.repeating, item = item, iscore = p.iscore,
            mat = mat, matname = matname, left = p.left}
end

-- a short human description of a resolved plan
local function plan_desc(plan)
    local base
    if plan.item.kind == 'reaction' then base = plan.item.name
    elseif plan.matname then base = plan.matname .. ' ' .. plan.item.name
    else base = plan.item.name end
    return ('%s%dx %s'):format(plan.repeating and 'r' or '', plan.amount, base)
end

-- ---- order creation ------------------------------------------------------

function create_order(input)
    local plan, err = resolve(input)
    if not plan then return nil, err end
    local item = plan.item

    local o = df.manager_order:new()
    o.job_type = item.job
    o.item_type = -1
    o.item_subtype = item.item_subtype or -1
    o.mat_type, o.mat_index = -1, -1
    o.reaction_name = item.kind == 'reaction' and item.reaction_name or ''

    if item.mat then                          -- baked material (raw glass)
        o.mat_type, o.mat_index = item.mat.mat_type, item.mat.mat_index
    elseif item.kind ~= 'reaction' then
        local m = plan.mat
        if m.kind == 'specific' then
            o.mat_type, o.mat_index = m.mat_type, m.mat_index
        elseif m.kind == 'category' then
            o.material_category[m.category] = true
        elseif m.kind == 'class' then
            if not m.picked then
                o:delete()
                return nil, ('no %s%s in stock'):format(m.constraint and (m.constraint .. '-safe ') or '', m.class)
            end
            o.mat_type, o.mat_index = m.picked.mat_type, m.picked.mat_index
        end
    end

    o.amount_total, o.amount_left = plan.amount, plan.amount
    o.frequency = plan.repeating and df.workquota_frequency_type.Monthly or df.workquota_frequency_type.OneTime
    o.status.validated = true
    o.status.active = true

    local mo = df.global.world.manager_orders
    o.id = mo.manager_order_next_id
    mo.manager_order_next_id = o.id + 1
    mo.all:insert(0, o)
    return plan_desc(plan)
end

-- expose for dry-run / tests / UI preview
function dry_run(input)
    local plan, err = resolve(input)
    if not plan then return {error = err} end
    return {repeating = plan.repeating, amount = plan.amount, item = plan.item,
            item_score = plan.iscore, mat = plan.mat, matname = plan.matname,
            desc = plan_desc(plan)}
end

-- top N candidate item/reaction names for a raw query (for autocomplete)
function candidates(input, n)
    local tokens = toks_of(input)
    -- strip a leading r / amount so autocomplete reflects the item words
    if tokens[1] and (tokens[1] == 'r' or tokens[1]:match('^r?%d+$')) then table.remove(tokens, 1) end
    for idx, w in ipairs(tokens) do
        if w:match('^%d+$') or WORDNUM[w] then table.remove(tokens, idx); break end
    end
    if #tokens == 0 then return {} end
    -- score every vocab entry against the best right-hand span
    local scored = {}
    for _, it in ipairs(build_vocab()) do
        local best = 0
        for cut = 0, #tokens - 1 do
            local right = {}
            for k = cut + 1, #tokens do right[#right + 1] = tokens[k] end
            local s = #right > 0 and score_name(table.concat(right, ' '), it.name) or 0
            if s > best then best = s end
        end
        if best > 0 then scored[#scored + 1] = {name = it.name, score = best, kind = it.kind} end
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return #a.name < #b.name
    end)
    local out = {}
    local seen = {}
    for _, e in ipairs(scored) do
        if not seen[e.name] then seen[e.name] = true; out[#out + 1] = e end
        if #out >= (n or 3) then break end
    end
    return out
end

-- ---- overlay: text box + autocomplete on the Work Orders screen ----------

local function is_mouse_key(keys)
    return keys._MOUSE_L or keys._MOUSE_R or keys._MOUSE_M
        or keys.CONTEXT_SCROLL_UP or keys.CONTEXT_SCROLL_DOWN
end

QuickOrderOverlay = defclass(QuickOrderOverlay, overlay.OverlayWidget)
QuickOrderOverlay.ATTRS{
    desc = 'Type "3 steel swords" / "make soap from tallow" to create a manager order by text.',
    default_pos = {x = 113, y = -7},
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/WORK_ORDERS/Default',
    frame = {w = 42, h = 6},
    version = 2,
}

function QuickOrderOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, h = 6},
            frame_style = gui.MEDIUM_FRAME,
            frame_background = gui.CLEAR_PEN,
            frame_title = 'new order',
            subviews = {
                widgets.Label{                          -- autocomplete, ABOVE the field
                    view_id = 'auto',
                    frame = {t = 0, l = 0, r = 0, h = 1},
                    text = {{text = '', pen = COLOR_GRAY}},
                },
                widgets.EditField{
                    view_id = 'edit',
                    frame = {t = 1, l = 0, r = 0},
                    label_text = '> ',
                    on_change = self:callback('on_change'),
                    on_submit = self:callback('submit'),
                },
                widgets.Label{
                    view_id = 'status',
                    frame = {t = 3, l = 0, r = 0},
                    text = {{text = 'e.g. "3 steel short swords", "collect sand", "r2 gabbro mechanism"',
                             pen = COLOR_GRAY}},
                },
            },
        },
    }
end

-- live autocomplete: show what the text currently resolves to, plus a couple of
-- alternative matches, above the field
function QuickOrderOverlay:on_change(text)
    local auto = self.subviews.auto
    if not text or text == '' then auto:setText({{text = '', pen = COLOR_GRAY}}); return end
    local r = dry_run(text)
    if r and not r.error then
        auto:setText({{text = '\215 ' .. r.desc, pen = COLOR_GREEN}})
    else
        local cands = candidates(text, 3)
        if #cands > 0 then
            local names = {}
            for _, c in ipairs(cands) do names[#names + 1] = c.name end
            auto:setText({{text = '? ' .. table.concat(names, '  |  '), pen = COLOR_YELLOW}})
        else
            auto:setText({{text = '? no match', pen = COLOR_LIGHTRED}})
        end
    end
end

function QuickOrderOverlay:render(dc)
    local now = dfhack.getTickCount()
    if not self._last_render or now - self._last_render > 500 then
        self.subviews.edit:setFocus(true)
    end
    self._last_render = now
    QuickOrderOverlay.super.render(self, dc)
end

function QuickOrderOverlay:submit(text)
    local desc, err = create_order(text)
    if desc then
        self.subviews.status:setText({{text = '+ ' .. desc, pen = COLOR_GREEN}})
        self.subviews.edit:setText('')
        self.subviews.auto:setText({{text = '', pen = COLOR_GRAY}})
    else
        self.subviews.status:setText({{text = 'x ' .. (err or 'failed'), pen = COLOR_LIGHTRED}})
    end
end

function QuickOrderOverlay:onInput(keys)
    local edit = self.subviews.edit
    if keys._MOUSE_R and edit.focus then edit:setFocus(false); return true end
    if QuickOrderOverlay.super.onInput(self, keys) then return true end
    if keys._MOUSE_L and edit.focus then edit:setFocus(false); return false end
    if edit.focus and not is_mouse_key(keys) then return true end
end

OVERLAY_WIDGETS = {entry = QuickOrderOverlay}

if dfhack_flags.module then return end

-- ---- command line --------------------------------------------------------

local args = {...}
local do_create = false
local parts = {}
for _, a in ipairs(args) do
    if a == '--create' then do_create = true else parts[#parts + 1] = a end
end
local input = table.concat(parts, ' ')

if do_create then
    local desc, err = create_order(input)
    if desc then print('created: ' .. desc) else dfhack.printerr('failed: ' .. tostring(err)) end
    return
end

local r = dry_run(input)
if r.error then dfhack.printerr('parse failed: ' .. r.error); return end
print(('%s  (item "%s", kind=%s, score=%d)'):format(r.desc, r.item.name, r.item.kind, r.item_score))
if r.item.kind == 'reaction' then
    print('  reaction: ' .. r.item.reaction_name)
elseif r.mat then
    local m = r.mat
    if m.kind == 'specific' then print(('  material: %s (%d:%d)'):format(m.name, m.mat_type, m.mat_index))
    elseif m.kind == 'category' then print('  material: any ' .. m.category)
    elseif m.kind == 'class' then
        print(('  material: %s'):format(m.picked and m.picked.name or ('no ' .. m.class .. ' in stock')))
    else print('  material: (none / any)') end
end
