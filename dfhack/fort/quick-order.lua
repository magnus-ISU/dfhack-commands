-- Parse freeform text ("3 steel swords", "make soap from tallow", "collect sand")
-- into a manager work order, and offer a text box + live autocomplete on the Work
-- Orders screen. This file is the PARSER/RESOLVER core (dry-run testable) plus the
-- overlay UI.
--@module = true
--[[
    quick-order <text>            dry-run: print what it resolved to
    quick-order --create <text>   actually create the order

Grammar:
  [r] <amount?> <material descriptor?> <item-or-job>
  * leading r / rN  -> repeating "keep N in stock" order: checked DAILY, gated on a
                       condition so it only runs while fewer than N of the output item
                       exist (counts the OUTPUT item -- matching subtype/material class,
                       never the inputs). "collect webs" counts SILK THREAD (webs become
                       silk thread when picked up). "collect sand" counts SAND-bearing bags
                       (native `sand_bearing` flag); "bin"/"barrel" count only EMPTY ones
                       (native `empty` flag), so a shelf full of packed bins doesn't satisfy
                       it. Jobs with no countable product (mint coins, butcher...) are still
                       REFUSED (make a one-time order instead).
  * amount: digits, rN, or a spelled number (one..twenty, a/an); default 1
  * material descriptor: a category (wood/wooden/cloth), a class (stone/rock/metal/
    glass), a specific material (gabbro/steel), and/or a property (magma safe)
  * item-or-job: fuzzy, matched against EVERY orderable thing --
      - reactions the fort is allowed (make soap from tallow, brew drink from plant,
        make steel bars, make X dye, instruments...) -> a CustomReaction order
      - fixed-material items (bed, coffin, mechanism, statue, crafts...)
      - weapons/armor/ammo/tools/trapcomps (by subtype, e.g. "short sword") -- ONLY the
        subtypes YOUR CIV knows how to make: a dwarf fort will not accept "long sword" or
        "scimitar", since no workshop here could ever fill that order. Read from the civ's
        entity resources (weapon_type + digger_type + training_weapon_type, armor_type,
        helm/pants/gloves/shoes/shield/ammo/tool/trapcomp_type), so picks and training
        weapons stay available and a modded civ gets its own list.
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
    {'mug', 'GOBLET', 'MakeGoblet'}, {'cup', 'GOBLET', 'MakeGoblet'},   -- mug/cup are goblet items
    {'toy', 'TOY', 'MakeToy'}, {'flask', 'FLASK', 'MakeFlask'}, {'totem', 'TOTEM', 'MakeTotem'},
    {'quern', 'QUERN', 'ConstructQuern'}, {'millstone', 'MILLSTONE', 'ConstructMillstone'},
    -- chain and rope are one item type: metal at the forge is a chain, cloth/silk/yarn at the
    -- clothier's is a rope. "chain" takes the usual default material (metal); "rope" is left
    -- UNTYPED (needs_mat false) so a bare "rope" pins no material at all and DF fills it from
    -- whatever is to hand -- which is also what leaves room for a mod's own rope reaction to
    -- stay in the suggestion list beside it. Naming a material still works on either word.
    {'chain', 'CHAIN', 'MakeChain'}, {'rope', 'CHAIN', 'MakeChain', false},
    {'slab', 'SLAB', 'ConstructSlab'}, {'splint', 'SPLINT', 'ConstructSplint'},
    {'crutch', 'CRUTCH', 'ConstructCrutch'}, {'traction bench', 'TRACTION_BENCH', 'ConstructTractionBench'},
    {'pipe section', 'PIPE_SECTION', 'MakePipeSection'}, {'anvil', 'ANVIL', 'ForgeAnvil'},
    {'window', 'WINDOW', 'MakeWindow'}, {'animal trap', 'ANIMALTRAP', 'MakeAnimalTrap'},
}

-- subtype-bearing item classes: itemdef vector -> {job, item_type, permission vectors}
-- The third field lists the `historical_entity.resources.*_type` vectors that say which
-- subtypes THIS CIVILISATION knows how to make. Without it the vocabulary is every itemdef in
-- the raws, so a dwarf fort would cheerfully accept "long sword" or "scimitar" and queue an
-- order no workshop can ever fill. Weapons need three vectors, not one: picks live in
-- `digger_type` and the wooden training gear in `training_weapon_type`.
local SUBTYPED = {
    weapons = {'MakeWeapon', 'WEAPON', {'weapon_type', 'digger_type', 'training_weapon_type'}},
    armor = {'MakeArmor', 'ARMOR', {'armor_type'}},
    helms = {'MakeHelm', 'HELM', {'helm_type'}}, pants = {'MakePants', 'PANTS', {'pants_type'}},
    gloves = {'MakeGloves', 'GLOVES', {'gloves_type'}}, shoes = {'MakeShoes', 'SHOES', {'shoes_type'}},
    shields = {'MakeShield', 'SHIELD', {'shield_type'}}, ammo = {'MakeAmmo', 'AMMO', {'ammo_type'}},
    tools = {'MakeTool', 'TOOL', {'tool_type'}},
    trapcomps = {'MakeTrapComponent', 'TRAPCOMP', {'trapcomp_type'}},
}

-- the subtypes this fort's civ is allowed to make from `vectors`, as a set; nil means "no
-- civ to ask" (worldless or a broken entity), which leaves the vocabulary unfiltered rather
-- than silently emptying it
local function permitted_subtypes(vectors)
    local ent = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not ent then return nil end
    local set, any = {}, false
    for _, vname in ipairs(vectors) do
        local ok, vec = pcall(function() return ent.resources[vname] end)
        if ok and vec then
            for _, st in ipairs(vec) do set[st] = true; any = true end
        end
    end
    return any and set or nil
end

-- processing / gathering jobs (no makeable "item"; the job IS the order). Each may
-- carry several natural-language aliases. Material handling mirrors DF's own work-order
-- DETAILS screen: jobs whose orders have no material row there (gathering, butchering,
-- milking/shearing, melting, rendering, charcoal/ash/lye/potash, ...) are flagged
-- `nomat` -- a material descriptor makes the parse REJECT that interpretation ("raw
-- green glass collect sand" must not become a collect-sand order). Jobs that DO carry
-- a legal material detail keep it optional: weave (silk/yarn/adamantine), mint (metal),
-- cut/encrust gems (specific stone/gem/glass), mill / process plants (specific plant).
local SPECIAL = {
    {job = 'CollectSand', nomat = true,     names = {'collect sand', 'gather sand', 'sand'}},
    -- webs become SILK THREAD the moment they're picked up, so a repeating collect-webs
    -- order can "keep N in stock" by counting silk thread (item_type THREAD, silk material).
    {job = 'CollectWebs', nomat = true,     names = {'collect webs', 'collect web', 'gather webs', 'collect silk', 'gather silk'},
                              product = {item_type = 'THREAD', flags2 = {'silk'}}},
    {job = 'CollectClay', nomat = true,     names = {'collect clay', 'gather clay'}},
    {job = 'CollectHiveProducts', nomat = true, names = {'collect hive products', 'collect honey', 'harvest hive', 'gather hive'}},
    {job = 'ButcherAnimal', nomat = true,   names = {'butcher animal', 'butcher an animal', 'butcher'}},
    {job = 'WeaveCloth',      names = {'weave cloth', 'weave', 'make cloth'}},
    {job = 'MakeCharcoal', nomat = true,    names = {'make charcoal', 'burn charcoal', 'charcoal'}},
    {job = 'MakeAsh', nomat = true,         names = {'make ash', 'burn ash'}},
    {job = 'MakeLye', nomat = true,         names = {'make lye', 'lye'}},
    {job = 'MakePotashFromLye', nomat = true, names = {'make potash from lye', 'potash from lye'}},
    {job = 'MakePotashFromAsh', nomat = true, names = {'make potash from ash', 'make potash', 'potash'}},
    {job = 'ExtractMetalStrands', nomat = true, names = {'extract metal strands', 'extract strands', 'process adamantine'}},
    {job = 'MintCoins',       names = {'mint coins', 'make coins', 'mint'}},
    {job = 'MilkCreature', nomat = true,    names = {'milk creature', 'milk animal', 'milk'}},
    {job = 'ShearCreature', nomat = true,   names = {'shear creature', 'shear animal', 'shear'}},
    {job = 'MeltMetalObject', nomat = true, names = {'melt metal object', 'melt object', 'melt item', 'melt'}},
    {job = 'CutGems',         names = {'cut gems', 'cut gem', 'cut glass'}},
    {job = 'EncrustWithGems', names = {'encrust with gems', 'encrust gems'}},
    {job = 'MillPlants',      names = {'mill plants', 'mill plant', 'mill'}},
    {job = 'ProcessPlants',   names = {'process plants', 'process plant'}},
    {job = 'ProcessPlantsBag',names = {'process plant to bag', 'process to bag'}},
    {job = 'ProcessPlantsVial',names = {'process plant to vial', 'extract to vial'}},
    {job = 'ProcessPlantsBarrel', names = {'process plant to barrel', 'extract to barrel'}},
    {job = 'RenderFat', nomat = true,       names = {'render fat', 'make tallow', 'render'}},
    {job = 'MakeCheese', nomat = true,      names = {'make cheese', 'cheese'}},
    {job = 'PrepareRawFish', nomat = true,  names = {'prepare raw fish', 'prepare fish', 'clean fish'}},
    {job = 'ExtractFromPlants',      names = {'extract from plants', 'extract plants'}},
    {job = 'ExtractFromRawFish', nomat = true,     names = {'extract from raw fish', 'extract fish'}},
    {job = 'ExtractFromLandAnimal', nomat = true,  names = {'extract from land animal', 'extract animal'}},
    {job = 'CatchLiveFish', nomat = true,   names = {'catch live fish', 'catch fish'}},
}

local vocab, vocab_civ  -- built once PER CIV: the permitted-subtype filter is civ-specific
-- entry = {name, kind='job'|'reaction', job, item_type=-1, item_subtype=-1,
--          reaction_name=nil, mat=nil, needs_mat=bool}

local function add_job(v, name, job, itype, sub, needs_mat)
    if not name or name == '' then return end
    local j = df.job_type[job]
    if not j then return end
    local e = {name = norm(name), kind = 'job', job = j,
               item_type = itype and df.item_type[itype] or -1,
               item_subtype = sub or -1, needs_mat = needs_mat and true or false}
    v[#v + 1] = e
    return e
end

local function build_vocab()
    if vocab and vocab_civ == df.global.plotinfo.civ_id then return vocab end
    local v = {}
    -- e[4] == false marks an entry that needs NO material (an untyped order); anything else
    -- (including a missing 4th field) takes the usual default-material treatment
    for _, e in ipairs(FIXED) do add_job(v, e[1], e[3], e[2], -1, e[4] ~= false) end
    for vecname, spec in pairs(SUBTYPED) do
        local vec = df.global.world.raws.itemdefs[vecname]
        local allowed = permitted_subtypes(spec[3])
        for i = 0, #vec - 1 do
            local def = vec[i]
            -- skip procedurally-generated, entity-sourced itemdefs (source_enid ~= -1) -- these are
            -- instrument parts etc. ("zurko block", "ispig blocks") whose random names otherwise
            -- pollute matching with un-orderable junk that outscores the real item.
            local ok, senid = pcall(function() return def.source_enid end)
            -- ...and skip anything this civ has no knowledge of: a subtype outside its entity
            -- resources can be named but never made, and an order for one just sits there
            if (not ok or senid == -1) and (not allowed or allowed[def.subtype]) then
                add_job(v, def.name, spec[1], spec[2], def.subtype, true)   -- singular only (scorer handles plurals)
            end
        end
    end
    for _, sp in ipairs(SPECIAL) do
        if df.job_type[sp.job] then
            for _, nm in ipairs(sp.names) do
                local e = add_job(v, nm, sp.job, nil, -1, false)
                if e and sp.product then e.product = sp.product end   -- countable output for repeats
                if e and sp.nomat then e.nomat = true end             -- order carries no material detail
            end
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
    -- cache each entry's name tokens + singulars once, so ranking never re-tokenizes
    for _, e in ipairs(v) do
        e.ntoks, e.nsings = {}, {}
        for w in e.name:gmatch('%S+') do
            e.ntoks[#e.ntoks + 1] = w; e.nsings[#e.nsings + 1] = singular(w)
        end
    end
    vocab, vocab_civ = v, df.global.plotinfo.civ_id
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
        local f = ir.material.flags
        local entry = {mat_type = 0, mat_index = i,
                       is_metal = f.IS_METAL or false, is_stone = f.IS_STONE or false}
        -- key on the id ("PEWTER_LAY" -> "pewter lay") AND on the material's DISPLAY name
        -- ("lay pewter"). The display name is what the player types/sees, and for alloys it's
        -- word-reordered from the id (fine/trifle/lay pewter), so keying on the id alone missed them.
        m[ir.id:lower():gsub('_', ' ')] = entry
        local ok, sn = pcall(function() return ir.material.state_name.Solid end)
        if ok and type(sn) == 'string' and sn ~= '' and not m[sn:lower()] then
            m[sn:lower()] = entry
        end
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

-- same scorer but on PRE-TOKENIZED inputs (query tokens + singulars, and a vocab entry's
-- cached name tokens/singulars). Hot path -- nothing is allocated or re-tokenized per call.
local function score_toks(qtoks, qsings, ntoks, nsings)
    local nq, nn = #qtoks, #ntoks
    if nq == 0 or nq > nn then return 0 end
    local i, matched, gaps = 1, 0, 0
    for x = 1, nq do
        local qt, qs = qtoks[x], qsings[x]
        local lqt, lqs = #qt, #qs
        local found
        for k = i, nn do
            if ntoks[k]:sub(1, lqt) == qt or nsings[k]:sub(1, lqs) == qs then found = k; break end
        end
        if not found then return 0 end
        matched = matched + 1; gaps = gaps + (found - i); i = found + 1
    end
    local sc = 90 - (nn - matched) * 4 - gaps * 2
    if nq == nn then sc = sc + 6 end
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

local function slice(t, a, b) local o = {}; for k = a, b do o[#o + 1] = t[k] end; return o end

-- split raw input into (repeating, amount, item+material tokens), dropping a leading
-- r/rN, a numeric/spelled amount, and a redundant leading verb ("make lavish meal").
local function parse_head(input)
    local tokens = toks_of(input)
    local repeating = false
    if tokens[1] then
        local rnum = tokens[1]:match('^r(%d+)$')
        if tokens[1] == 'r' then repeating = true; table.remove(tokens, 1)
        elseif rnum then repeating = true; tokens[1] = rnum end
    end
    local amount
    for idx, w in ipairs(tokens) do
        if w:match('^%d+$') then amount = tonumber(w); table.remove(tokens, idx); break
        elseif WORDNUM[w] then amount = WORDNUM[w]; table.remove(tokens, idx); break end
    end
    if #tokens > 1 and VERB[tokens[1]] then table.remove(tokens, 1) end
    return repeating, amount or 1, tokens
end

-- how well a span of item words matches a vocab entry (cached tokens; bare-noun alias)
local function item_score(sp, item)
    if #sp.toks == 1 then
        local a = ALIAS[sp.sings[1]]
        if a and item.name == a then return 100 end
    end
    return score_toks(sp.toks, sp.sings, item.ntoks, item.nsings)
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
-- CHAIN covers both chains (forged metal) and ropes (woven cloth/silk/yarn). Nothing else makes
-- one: no stone chains, no wooden or bone ones.
local CHAIN_T = df.item_type.CHAIN
local CHAIN_SOFT = {cloth = true, silk = true, yarn = true}

-- weapons with the CAN_STONE flag (short sword, dagger, spear...) can be KNAPPED from
-- stone at the craftsdwarf's -- so "obsidian short sword" is legal even though obsidian
-- can't be forged. Cached per weapon subtype.
local weapon_can_stone_set
local function weapon_can_stone(item)
    if item.item_type ~= df.item_type.WEAPON then return false end
    if not weapon_can_stone_set then
        weapon_can_stone_set = {}
        local wv = df.global.world.raws.itemdefs.weapons
        for i = 0, #wv - 1 do if wv[i].flags.CAN_STONE then weapon_can_stone_set[wv[i].subtype] = true end end
    end
    return weapon_can_stone_set[item.item_subtype] or false
end

-- can a concrete inorganic (mat_index) actually be made into this item?
local function can_make_inorganic(item, mi)
    local ir = df.inorganic_raw.find(mi)
    if not ir then return false end
    local f = ir.material.flags
    local it = item.item_type
    if it == df.item_type.WEAPON then
        if f.ITEMS_WEAPON or f.ITEMS_WEAPON_RANGED or f.ITEMS_DIGGER then return true end
        return (f.IS_STONE and weapon_can_stone(item)) or false      -- knapped stone weapon
    elseif it == df.item_type.AMMO then
        return f.ITEMS_AMMO or false
    elseif ARMOR_DEFVEC[it] then
        if not f.ITEMS_ARMOR then return false end                    -- stone can't make armour
        if f.IS_METAL then local af = armor_flags(item); if af and not af.METAL then return false end end
        return true
    elseif it == SHIELD_T then
        return f.IS_METAL or false                                    -- shields: metal (wood via category)
    elseif it == CHAIN_T then
        return (f.IS_METAL and f.ITEMS_HARD) or false                 -- chains are forged; stone can't
    end
    -- everything else (furniture, crafts, containers, tools...): a METAL must be forgeable into
    -- hard items (ITEMS_HARD). Pure alloy-ingredient metals like bismuth (no ITEMS_HARD) can't --
    -- only their alloys (bismuth BRONZE) can. Stone and other inorganics pass (made at the mason's).
    if f.IS_METAL and not f.ITEMS_HARD then return false end
    return true
end

-- is the resolved material m legal for this item? returns true, or false + reason.
-- A CONCRETE material (typed, or class-picked from stock) is checked for EVERY item (so a metal
-- that can't be forged into items -- bismuth -- is rejected for a pedestal, not just for a sword).
-- Bare class/category words are only policed on weapons/ammo/armour/shields; furniture/crafts take
-- any class.
local function legal_material(item, m)
    local it = item.item_type
    local policed = WEAPONISH[it] or ARMOR_DEFVEC[it] or it == SHIELD_T or it == CHAIN_T
    if m.kind == 'specific' or (m.kind == 'class' and m.picked) then
        local mt = m.kind == 'specific' and m.mat_type or m.picked.mat_type
        local mi = m.kind == 'specific' and m.mat_index or m.picked.mat_index
        if mt == 0 then                          -- concrete inorganic (stone/metal): must fit the item
            if not can_make_inorganic(item, mi) then
                local nm = (df.inorganic_raw.find(mi) and df.inorganic_raw.find(mi).id:lower():gsub('_', ' ')) or 'that material'
                return false, ('%s cannot be made of %s'):format(item.name, nm)
            end
            return true
        end
        -- concrete non-inorganic (glass): fine for furniture/crafts, not for forged combat items
        if policed then return false, ('%s cannot be made of that material'):format(item.name) end
        return true
    end
    if not policed then return true end          -- bare class/category on furniture/crafts: anything goes
    if m.kind == 'class' then                    -- no concrete pick: judge the class
        if m.class == 'metal' then
            if ARMOR_DEFVEC[it] then local af = armor_flags(item); if af and not af.METAL then return false, item.name .. ' cannot be made of metal' end end
            return true
        elseif m.class == 'stone' then
            if it == df.item_type.WEAPON and weapon_can_stone(item) then return true end
            return false, item.name .. ' cannot be made of stone'
        else
            return false, item.name .. ' cannot be made of ' .. m.class
        end
    elseif m.kind == 'category' then             -- wood / leather / cloth / silk / yarn
        if WEAPONISH[it] then return false, item.name .. ' must be metal or stone' end
        if it == CHAIN_T then                    -- a woven rope: thread goods only
            if not CHAIN_SOFT[m.category] then
                return false, item.name .. ' can only be metal, cloth, silk or yarn'
            end
            return true
        end
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

-- cached per-class stock tally (mat_index -> stack count). The world scan is expensive,
-- so we keep it for a few seconds -- material abundance changes slowly.
local stock_cache = {}
local function stock_counts(class, constraint)
    local key = class .. '/' .. tostring(constraint)
    local now = dfhack.getTickCount()
    local c = stock_cache[key]
    if c and (now - c.t) < 3000 then return c end
    local list = (class == 'stone' and df.global.world.items.other.BOULDER)
        or (class == 'metal' and df.global.world.items.other.BAR) or nil
    local counts, fallback = {}, {}
    if list then
        local econ = (class == 'stone') and df.global.plotinfo.economic_stone or nil
        for _, it in ipairs(list) do
            if it.mat_type == 0 and ((constraint ~= 'magma') or is_magma_safe(0, it.mat_index))
                and (class ~= 'metal' or (df.inorganic_raw.find(it.mat_index)
                     and df.inorganic_raw.find(it.mat_index).material.flags.IS_METAL))
            then
                fallback[it.mat_index] = (fallback[it.mat_index] or 0) + it.stack_size
                if not (econ and econ[it.mat_index]) then
                    counts[it.mat_index] = (counts[it.mat_index] or 0) + it.stack_size
                end
            end
        end
    end
    c = {t = now, counts = counts, fallback = fallback}
    stock_cache[key] = c
    return c
end

-- pick the most-abundant concrete material of a class in stock that can make this item.
-- The world scan is cached; the per-item can_make filter runs on the cached tally.
function most_in_stock(class, constraint, item)
    if class == 'glass' then
        local mats = build_material_vocab()
        return mats['clear glass'] and {mat_type = mats['clear glass'].mat_type,
            mat_index = mats['clear glass'].mat_index, name = 'clear glass', count = 0}
    end
    local c = stock_counts(class, constraint)
    local function pick(t)
        local b, bn
        for mi, n in pairs(t) do
            if (not item or item.item_type == -1 or can_make_inorganic(item, mi)) and (not bn or n > bn) then
                b, bn = mi, n
            end
        end
        return b, bn
    end
    local best, bestn = pick(c.counts)
    if not best then best, bestn = pick(c.fallback) end
    if not best then return nil end
    local ir = df.inorganic_raw.find(best)
    return {mat_type = 0, mat_index = best,
            name = ir and ir.id:lower():gsub('_', ' ') or '?', count = bestn}
end

-- bare (no-material) items that should default to WOOD -- either wood-only (bed) or
-- containers that can't be made of stone (barrel/bucket/bin/cage)
local DEFAULT_WOOD = {}
for _, n in ipairs({'bed', 'barrel', 'bucket', 'bin', 'cage', 'weapon rack', 'armor stand'}) do
    DEFAULT_WOOD[n] = true
end
local METAL_ITEMS = {}
for _, t in ipairs({'WEAPON', 'AMMO', 'ARMOR', 'HELM', 'PANTS', 'GLOVES', 'SHOES', 'SHIELD', 'CHAIN'}) do
    METAL_ITEMS[df.item_type[t]] = true
end

-- when a material-requiring job is given no material, pick a sensible default CLASS (no
-- world scan -- the concrete material is chosen later, only for the order that's created)
local function default_material(item)
    if DEFAULT_WOOD[item.name] then return {kind = 'category', category = 'wood'} end
    local af = armor_flags(item)
    if af and not af.METAL then
        if af.LEATHER then return {kind = 'category', category = 'leather'} end
        if af.SOFT then return {kind = 'category', category = 'cloth'} end
    end
    if METAL_ITEMS[item.item_type] then return {kind = 'class', class = 'metal'} end
    return {kind = 'class', class = 'stone'}
end

-- ---- resolve / rank (parse + material + legality) ------------------------

-- Build a legal plan for `item` made with material words `mattoks`, or nil if the
-- material is unresolvable OR illegal for the item (this is what keeps illegal combos
-- like "obsidian shoe" out of the suggestions entirely).
-- returns plan, or (nil) for an invalid split, or (nil, reason) when the split matched
-- but the material is illegal for the item (so the caller can report why)
local function build_plan(item, mattoks)
    if item.kind == 'reaction' or item.mat then
        -- a reaction / baked-material item takes NO material descriptor; leftover words
        -- mean this isn't the right interpretation (e.g. "iron cloak" is not "make iron bars")
        if #mattoks > 0 then return nil end
        return {item = item, mat = {kind = 'none'}}
    end
    if item.nomat and #mattoks > 0 then
        -- this job's work order carries no material detail in DF (collect sand, butcher,
        -- melt, ...): a material descriptor means this interpretation is wrong
        return nil, ('"%s" takes no material'):format(item.name)
    end
    -- no material words -> skip the (allocating) resolver entirely; this is the common case
    local m = (#mattoks == 0) and {kind = 'none'} or resolve_material(mattoks, item, nil)
    if not m then return nil end
    if m.kind == 'none' and item.needs_mat then m = default_material(item) end
    local ok, why = legal_material(item, m)
    if not ok then return nil, why end
    local matname
    if m.kind == 'specific' then matname = m.name
    elseif m.kind == 'category' then matname = 'any ' .. m.category
    elseif m.kind == 'class' then matname = ('any %s%s'):format(m.constraint and (m.constraint .. '-safe ') or '', m.class) end
    return {item = item, mat = m, matname = matname}
end

-- fill in a concrete material for a class plan (world scan) -- only for the plan(s) we
-- actually show or create, so the per-keystroke ranking stays cheap
local function enrich(plan)
    if plan and plan.mat and plan.mat.kind == 'class' and not plan.mat.picked then
        local p = most_in_stock(plan.mat.class, plan.mat.constraint, plan.item)
        if p then plan.mat.picked = p; plan.matname = p.name end
    end
    return plan
end

-- the order-identity signature of a plan, so different phrasings of the same order dedup
local function plan_sig(plan)
    local it = plan.item
    if it.kind == 'reaction' then return 'rxn:' .. it.reaction_name end
    local m = it.mat or plan.mat
    local mk = it.mat and (it.mat.mat_type .. ':' .. it.mat.mat_index)
        or (m.kind == 'specific' and (m.mat_type .. ':' .. m.mat_index))
        or (m.kind == 'category' and ('cat:' .. m.category))
        or (m.kind == 'class' and ('cls:' .. m.class)) or 'any'
    return ('job:%d/%d/%s'):format(it.job, it.item_subtype or -1, mk)
end

-- rank all vocab entries against the item+material tokens; sorted list of legal
-- {plan, score}, best first, deduped by order identity. Illegal combos are dropped.
-- returns (sorted legal {plan,score} list, best-illegal {s,why}). The illegal note lets
-- resolve() say WHY the closest match is invalid ("sword cannot be made of stone")
-- instead of silently substituting an unrelated legal item.
local function rank(tokens)
    local nT = #tokens
    -- precompute the (item span, material span) splits ONCE -- they depend only on the query,
    -- not on the vocab entry, so we never allocate slices inside the per-entry loop
    local splits, seen = {}, {}
    for cut = 0, nT do
        for dir = 1, 2 do
            local itemtoks, mattoks
            if dir == 1 then itemtoks, mattoks = slice(tokens, cut + 1, nT), slice(tokens, 1, cut)
            else itemtoks, mattoks = slice(tokens, 1, cut), slice(tokens, cut + 1, nT) end
            local k = table.concat(itemtoks, ' ') .. '\1' .. table.concat(mattoks, ' ')
            if #itemtoks > 0 and not seen[k] then
                seen[k] = true
                local sings = {}
                for x = 1, #itemtoks do sings[x] = singular(itemtoks[x]) end
                splits[#splits + 1] = {toks = itemtoks, sings = sings, mat = mattoks}
            end
        end
    end

    local acc, illegal = {}, nil
    for _, it in ipairs(build_vocab()) do
        for _, sp in ipairs(splits) do
            local s = item_score(sp, it)
            if s > 0 then
                -- score the SPLIT, legal or not, so the illegal note is comparable with the
                -- legal plans: a one-word exact hit that leaves three words to the material
                -- ("rope" out of "rope from braided leather") must not outrank a reaction whose
                -- name covers the whole phrase, and only `total` accounts for that coverage
                local total = s + #sp.toks * 3 - #sp.mat
                if #sp.mat == 0 and s >= 60 then total = total + 14 end   -- favour whole-phrase
                local plan, why = build_plan(it, sp.mat)
                if plan then
                    local key = plan_sig(plan)
                    if not acc[key] or total > acc[key].score then
                        acc[key] = {plan = plan, score = total, s = s}
                    end
                elseif why and (not illegal or total > illegal.total) then
                    illegal = {s = s, total = total, why = why}
                end
            end
        end
    end
    local out = {}
    for _, e in pairs(acc) do out[#out + 1] = e end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return #a.plan.item.name < #b.plan.item.name
    end)
    return out, illegal
end

-- if the closest ITEM match was rejected for legality and it matched the query better than
-- the best legal plan, that illegal item is what the user meant -> surface its reason instead
-- of a tangential legal match ("obsidian war hammer" -> the reason, not an obsidian instrument)
local function illegal_wins(ranked, illegal)
    return illegal and (#ranked == 0 or illegal.total > ranked[1].score)
end

-- returns the best resolved plan {amount, repeating, item, mat, matname, iscore, ranked} or nil,err
local function resolve(input)
    local repeating, amount, tokens = parse_head(input)
    if #tokens == 0 then return nil, 'no item' end
    local ranked, illegal = rank(tokens)
    if illegal_wins(ranked, illegal) then return nil, illegal.why end
    if #ranked == 0 then return nil, 'no match' end
    local top = enrich(ranked[1].plan)
    return {amount = amount, repeating = repeating, item = top.item, mat = top.mat,
            matname = top.matname, iscore = ranked[1].score, ranked = ranked}
end

-- Some repeating orders count a special native condition FLAG instead of a plain item count. DF's
-- manager-order item condition exposes flags for exactly these: `empty` counts only EMPTY containers
-- (an available bin/barrel, not one already packed full of goods), and `sand_bearing` counts bags of
-- sand. So "keep 20 empty bins" / "keep 100 sand" become native LessThan conditions with the flag set
-- -- no background service needed. Map job -> the flags1 field its repeat-count condition must set.
local COUNT_FLAG1 = {
    [df.job_type.ConstructBin] = 'empty',
    [df.job_type.MakeBarrel]   = 'empty',
    [df.job_type.CollectSand]  = 'sand_bearing',
}

-- what item a repeating "keep N in stock" order should count. FIXED/SUBTYPED items count
-- their own type+subtype; jobs in COUNT_FLAG1 add a native condition flag (empty bins/barrels,
-- sand-bearing bags) -- collect sand counts ANY sand-bearing item (item_type -1 + the flag); a
-- SPECIAL job with a `product` spec (e.g. collect webs -> silk thread) counts that; everything else
-- (reactions, most gather/process jobs) has no countable product -> nil (repeat refused).
local function count_spec(item)
    local f1 = COUNT_FLAG1[item.job]
    if (item.item_type or -1) >= 0 then
        return {item_type = item.item_type, item_subtype = item.item_subtype or -1, flags1 = f1}
    end
    if f1 then   -- flag-only product (collect sand): count any item bearing the flag, any type/material
        return {item_type = -1, item_subtype = -1, flags1 = f1}
    end
    local p = item.product
    if p then
        local it = df.item_type[p.item_type]
        if it then
            return {item_type = it, item_subtype = p.item_subtype or -1, flags2 = p.flags2,
                    mat_type = p.mat_type or -1, mat_index = p.mat_index or -1}
        end
    end
    return nil
end

-- a short human description of a resolved plan
local function plan_desc(plan)
    local base
    if plan.item.kind == 'reaction' then base = plan.item.name
    elseif plan.matname then base = plan.matname .. ' ' .. plan.item.name
    else base = plan.item.name end
    local amount = plan.amount or 1
    if plan.repeating then
        if count_spec(plan.item) then
            return ('keep %dx %s stocked'):format(amount, base)   -- daily, only if below N
        end
        return ('%dx %s — can\'t keep in stock'):format(amount, base)  -- no countable product
    end
    return ('%dx %s'):format(amount, base)
end

-- ---- order creation ------------------------------------------------------

-- how many finished items ONE job of this order produces (so amount_total can count jobs, not
-- items). Stone/metal blocks come 4 at a time; glass blocks 1; flasks and goblets/mugs 3.
local function order_yield(o)
    local jt = o.job_type
    if jt == df.job_type.ConstructBlocks then
        local mi = dfhack.matinfo.decode(o.mat_type, o.mat_index)
        if mi and mi.material and mi.material.flags and mi.material.flags.IS_GLASS then return 1 end
        return 4
    elseif jt == df.job_type.MakeFlask or jt == df.job_type.MakeGoblet then
        return 3
    end
    return 1
end

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
            local picked = m.picked or most_in_stock(m.class, m.constraint, item)
            if not picked then
                o:delete()
                return nil, ('no %s%s in stock'):format(m.constraint and (m.constraint .. '-safe ') or '', m.class)
            end
            o.mat_type, o.mat_index = picked.mat_type, picked.mat_index
        end
    end

    -- amount_total counts JOBS, not finished items. Some jobs yield several per run (stone/metal
    -- blocks 4, glass blocks 1, flasks + goblets/mugs 3), so divide the requested item count by the
    -- yield and round up: "197 blocks" -> 50 jobs (200 blocks), not 197 jobs (788 blocks).
    -- REPEATING orders top up in batches of at most 10 ITEMS: the stock condition still targets
    -- the full requested amount, but each (daily) trigger only queues ~10 -- "r200 blocks" keeps
    -- the stock hovering at 200-209, instead of queueing 200 more and oscillating 200-399.
    local batch = plan.amount
    if plan.repeating and batch > 10 then batch = 10 end
    local jobs = math.ceil(batch / order_yield(o))
    o.amount_total, o.amount_left = jobs, jobs
    if plan.repeating then
        -- Repeating = "keep `amount` of the OUTPUT item in stock". Checked DAILY, but a stock
        -- condition gates it so it only runs while we have fewer than `amount` of the item
        -- (matching subtype AND the order's own material). Never looks at the input materials. If
        -- the job has no single countable product, we refuse rather than making a blind repeat.
        local cs = count_spec(plan.item)
        if not cs then
            o:delete()
            return nil, ('can\'t keep "%s" in stock: no countable product'):format(plan.item.name)
        end
        o.frequency = df.workquota_frequency_type.Daily
        o.item_conditions:insert('#', {new = df.manager_order_condition_item,
            compare_type = df.logic_condition_type.LessThan, compare_val = plan.amount,
            item_type = cs.item_type, item_subtype = cs.item_subtype or -1,
            -- count the order's OWN material: "keep 50 obsidian blocks" must not be satisfied by
            -- 50 granite blocks. (For webs -> silk thread the order has no material; flags2 below
            -- handles the material class instead.)
            mat_type = o.mat_type, mat_index = o.mat_index, reaction_class = ''})
        if cs.flags2 then   -- material-class match (e.g. count only SILK thread, not plant thread)
            local cond = o.item_conditions[#o.item_conditions - 1]
            for _, fl in ipairs(cs.flags2) do cond.flags2[fl] = true end
        end
        if cs.flags1 then   -- native condition flag: 'empty' (only empty bins/barrels) / 'sand_bearing'
            o.item_conditions[#o.item_conditions - 1].flags1[cs.flags1] = true
        end
    else
        o.frequency = df.workquota_frequency_type.OneTime
    end
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

-- up to N legal candidate order descriptions for a raw query (for autocomplete)
function candidates(input, n)
    local repeating, amount, tokens = parse_head(input)
    if #tokens == 0 then return {} end
    local ranked, illegal = rank(tokens)
    if illegal_wins(ranked, illegal) then return {} end   -- intended item is illegal: no suggestions
    local out, seen = {}, {}
    for _, e in ipairs(ranked) do
        enrich(e.plan)
        local d = plan_desc({item = e.plan.item, matname = e.plan.matname,
                             amount = amount, repeating = repeating})
        if not seen[d] then seen[d] = true; out[#out + 1] = d end
        if #out >= (n or 5) then break end
    end
    return out
end

-- ---- overlay: text box + autocomplete on the Work Orders screen ----------

local function is_mouse_key(keys)
    return keys._MOUSE_L or keys._MOUSE_R or keys._MOUSE_M
        or keys.CONTEXT_SCROLL_UP or keys.CONTEXT_SCROLL_DOWN
end

local HINT = 'e.g. "3 steel short swords", "collect sand", "r2 gabbro mechanism"'

QuickOrderOverlay = defclass(QuickOrderOverlay, overlay.OverlayWidget)
QuickOrderOverlay.ATTRS{
    desc = 'Type "3 steel swords" / "make soap from tallow" to create a manager order by text.',
    default_pos = {x = 113, y = -6},
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/WORK_ORDERS/Default',
    frame = {w = 42, h = 5},                       -- base height (no suggestions); grows upward
    overlay_onupdate_max_freq_seconds = 0,
    version = 3,
}

function QuickOrderOverlay:init()
    self:addviews{
        widgets.Panel{
            frame = {t = 0, l = 0, r = 0, b = 0},  -- fill the (dynamically sized) widget
            frame_style = gui.MEDIUM_FRAME,
            frame_background = gui.CLEAR_PEN,
            frame_title = 'new order',
            subviews = {
                widgets.Label{                     -- suggestions / hint, ABOVE the field (fills the top)
                    view_id = 'auto',
                    frame = {t = 0, l = 0, r = 0, b = 2},
                    text = {{text = HINT, pen = COLOR_GRAY}},
                },
                widgets.EditField{                 -- the field sits just above the bottom (stable)
                    view_id = 'edit',
                    frame = {b = 1, l = 0, r = 0, h = 1},
                    label_text = '> ',
                    on_change = self:callback('on_change'),
                    on_submit = self:callback('submit'),
                },
                widgets.Label{                     -- submit feedback, bottom line
                    view_id = 'status',
                    frame = {b = 0, l = 0, r = 0, h = 1},
                    text = {{text = '', pen = COLOR_GRAY}},
                },
            },
        },
    }
end

-- the box is `nsug + 4` tall (border 2 + suggestions + field + status), min 5. Height is
-- applied in overlay_onupdate so the framework's frame-change detector re-lays it out.
function QuickOrderOverlay:set_suggestions(tokens, nsug)
    self.subviews.auto:setText(tokens)
    self._want_h = math.max(1, nsug) + 4
end

-- live autocomplete: each legal candidate on its own line; the top one (what Enter makes)
-- in green. Illegal/no-match inputs show the reason in red -- and are never suggested.
function QuickOrderOverlay:on_change(text)
    if not text or text == '' then
        self:set_suggestions({{text = HINT, pen = COLOR_GRAY}}, 0)
        return
    end
    local cands = candidates(text, 5)
    if #cands == 0 then
        local r = dry_run(text)
        self:set_suggestions({{text = '\215 ' .. (r.error or 'no match'), pen = COLOR_LIGHTRED}}, 1)
        return
    end
    local tokens = {}
    for i, d in ipairs(cands) do
        if i > 1 then tokens[#tokens + 1] = NEWLINE end   -- bare string separator -> real line break
        tokens[#tokens + 1] = {text = (i == 1 and '\215 ' or '  ') .. d,
                               pen = (i == 1) and COLOR_GREEN or COLOR_GRAY}
    end
    self:set_suggestions(tokens, #cands)
end

function QuickOrderOverlay:overlay_onupdate()
    if self._want_h and self.frame.h ~= self._want_h then self.frame.h = self._want_h end
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
        self:set_suggestions({{text = HINT, pen = COLOR_GRAY}}, 0)
    else
        self.subviews.status:setText({{text = 'x ' .. (err or 'failed'), pen = COLOR_LIGHTRED}})
    end
end

function QuickOrderOverlay:onInput(keys)
    local edit = self.subviews.edit
    if edit.focus and keys.LEAVESCREEN then edit:setFocus(false); return true end   -- Esc unfocuses
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
