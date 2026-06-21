-- Parse freeform text ("3 steel swords", "magma safe rock mechanism") into a
-- manager work order. This file is the PARSER/RESOLVER core (dry-run testable);
-- order creation + the Work Orders screen UI come next.
--@module = true
--[[
    quick-order <text>            dry-run: print what it resolved to
    quick-order --create <text>   actually create the order (one-time)

Grammar (see README "work-orders quick text input" plan):
  [r] <amount?> <material descriptor?> <item>
  * leading r / rN  -> repeating
  * amount: digits, rN, or a spelled number (one..twenty, a/an); default 1
  * material descriptor: a category (wood), a concrete class (stone/metal/glass),
    a specific material (gabbro/steel), and/or a property (magma safe, fire safe)
  * item: fuzzy, may be abbreviated (short s -> short sword)
]]

local MAGMA_TEMP = 12000

-- ---- vocab: items --------------------------------------------------------

-- fixed-job items (job implies the item); name -> {job, item_type, subtype=-1}
local FIXED = {
    {'mechanism', 'TRAPPARTS', 'ConstructMechanisms'}, {'door', 'DOOR', 'ConstructDoor'},
    {'floodgate', 'FLOODGATE', 'ConstructFloodgate'}, {'bed', 'BED', 'ConstructBed'},
    {'chair', 'CHAIR', 'ConstructThrone'}, {'throne', 'CHAIR', 'ConstructThrone'},
    {'coffin', 'COFFIN', 'ConstructCoffin'}, {'table', 'TABLE', 'ConstructTable'},
    {'chest', 'BOX', 'ConstructChest'}, {'box', 'BOX', 'ConstructChest'},
    {'cabinet', 'CABINET', 'ConstructCabinet'}, {'armor stand', 'ARMORSTAND', 'ConstructArmorStand'},
    {'weapon rack', 'WEAPONRACK', 'ConstructWeaponRack'}, {'bin', 'BIN', 'ConstructBin'},
    {'barrel', 'BARREL', 'MakeBarrel'}, {'bucket', 'BUCKET', 'MakeBucket'},
    {'cage', 'CAGE', 'MakeCage'}, {'statue', 'STATUE', 'ConstructStatue'},
    {'block', 'BLOCKS', 'ConstructBlocks'}, {'blocks', 'BLOCKS', 'ConstructBlocks'},
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

local item_vocab  -- list of {name, job, item_type, item_subtype}

local function add_item(vocab, name, job, itype, sub)
    if not name or name == '' then return end
    local j, it = df.job_type[job], df.item_type[itype]
    if not j or not it then return end
    vocab[#vocab + 1] = {name = name:lower(), job = j, item_type = it, item_subtype = sub or -1}
end

local function build_item_vocab()
    if item_vocab then return item_vocab end
    local v = {}
    for _, e in ipairs(FIXED) do add_item(v, e[1], e[3], e[2], -1) end
    for vecname, spec in pairs(SUBTYPED) do
        local vec = df.global.world.raws.itemdefs[vecname]
        for i = 0, #vec - 1 do
            local def = vec[i]
            add_item(v, def.name, spec[1], spec[2], def.subtype)
            if def.name_plural and def.name_plural ~= def.name then
                add_item(v, def.name_plural, spec[1], spec[2], def.subtype)
            end
        end
    end
    item_vocab = v
    return v
end

-- ---- vocab: materials ----------------------------------------------------

-- job_material_category flags that double as a "material" word
local CATEGORY_WORDS = {
    wood = 'wood', cloth = 'cloth', silk = 'silk', leather = 'leather',
    bone = 'bone', shell = 'shell', yarn = 'yarn', pearl = 'pearl',
}
-- bare classes that are NOT order materials -> must resolve to a concrete one
local CLASS_WORDS = {stone = 'stone', rock = 'stone', metal = 'metal', glass = 'glass'}

local material_vocab  -- name -> {mat_type, mat_index, is_metal, is_stone}

local function build_material_vocab()
    if material_vocab then return material_vocab end
    local m = {}
    local i = 0
    while df.inorganic_raw.find(i) do
        local ir = df.inorganic_raw.find(i)
        local name = ir.id:lower():gsub('_', ' ')
        local f = ir.material.flags
        m[name] = {mat_type = 0, mat_index = i,
                   is_metal = f.IS_METAL or false,
                   is_stone = f.IS_STONE or false}
        i = i + 1
    end
    -- glass builtins
    for _, g in ipairs({{'clear glass', 'GLASS_CLEAR'}, {'green glass', 'GLASS_GREEN'},
                        {'crystal glass', 'GLASS_CRYSTAL'}}) do
        local mi = dfhack.matinfo.find(g[2])
        if mi then m[g[1]] = {mat_type = mi.type, mat_index = mi.index, is_glass = true} end
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

local function norm(s) return (s or ''):lower():gsub('[%-]', ' ') end
local function singular(w) return (#w > 3 and w:sub(-1) == 's') and w:sub(1, -2) or w end

-- score how well query matches name (0 = no match, higher = better)
local function score_name(query, name)
    query, name = norm(query), norm(name)
    if query == name then return 100 end
    local qs, ns = singular(query), singular(name)
    if qs == ns then return 95 end
    -- per-word prefix: every query word is a prefix of the matching name word
    local qw, nw = {}, {}
    for w in query:gmatch('%S+') do qw[#qw + 1] = w end
    for w in name:gmatch('%S+') do nw[#nw + 1] = w end
    if #qw <= #nw then
        local ok = true
        for k = 1, #qw do
            local a, b = singular(qw[k]), nw[#nw - #qw + k]  -- align to the end
            if not (b:sub(1, #a) == a or singular(b):sub(1, #a) == a) then ok = false break end
        end
        if ok then return 80 - (#nw - #qw) end  -- prefer fewer extra words
    end
    if name:find(query, 1, true) then return 60 end
    return 0
end

-- bare weapon nouns -> the typical military item (per the spec: sword=short sword)
local ALIAS = {sword = 'short sword', axe = 'battle axe', hammer = 'war hammer',
    warhammer = 'war hammer', greataxe = 'great axe'}

-- best item for a list of right-side tokens
local function best_item(tokens)
    if #tokens == 0 then return nil, 0 end
    local query = table.concat(tokens, ' ')
    if not query:find(' ') and ALIAS[singular(query)] then
        local want = ALIAS[singular(query)]
        for _, it in ipairs(build_item_vocab()) do
            if it.name == want then return it, 100 end
        end
    end
    local best, bs = nil, 0
    for _, it in ipairs(build_item_vocab()) do
        local s = score_name(query, it.name)
        if s > bs then best, bs = it, s end
    end
    return best, bs
end

-- ---- material descriptor resolution --------------------------------------

local PROPERTY_WORDS = {['magma safe'] = 'magma', ['fire safe'] = 'fire', fireproof = 'fire'}

-- resolve left-side tokens -> {kind='category'|'specific'|'class'|'none', ...}
-- plus constraints; returns nil,reason on failure
local function resolve_material(tokens, item, want_in_stock)
    local mats = build_material_vocab()
    -- pull property phrases (1- and 2-word) out
    local constraint
    local toks = {}
    for _, t in ipairs(tokens) do toks[#toks + 1] = norm(t) end
    local i = 1
    local rest = {}
    while i <= #toks do
        local two = toks[i] .. ' ' .. (toks[i + 1] or '')
        if PROPERTY_WORDS[two] then constraint = PROPERTY_WORDS[two]; i = i + 2
        elseif PROPERTY_WORDS[toks[i]] then constraint = PROPERTY_WORDS[toks[i]]; i = i + 1
        elseif toks[i] == 'made' or toks[i] == 'of' then i = i + 1
        else rest[#rest + 1] = toks[i]; i = i + 1 end
    end

    if #rest == 0 and not constraint then
        return {kind = 'none'}  -- no material specified
    end

    -- a bare class word present (stone/rock/metal/glass)? remember it but it
    -- never blocks a specific match (e.g. "gabbro rock" -> gabbro)
    local class
    for _, w in ipairs(rest) do if CLASS_WORDS[w] then class = CLASS_WORDS[w] end end

    -- find a SPECIFIC material via spans: full phrase, then 2-word spans
    -- (pig iron, clear glass), then single tokens (skipping bare class words)
    local function find_specific()
        if mats[table.concat(rest, ' ')] then return table.concat(rest, ' ') end
        for k = 1, #rest - 1 do
            local sp = rest[k] .. ' ' .. rest[k + 1]
            if mats[sp] then return sp end
        end
        for _, w in ipairs(rest) do
            if not CLASS_WORDS[w] and mats[w] then return w end
        end
    end

    local spec = find_specific()
    if spec then
        local mt = mats[spec]
        if constraint and not is_magma_safe(mt.mat_type, mt.mat_index) then
            return nil, ('%s is not %s-safe'):format(spec, constraint)
        end
        return {kind = 'specific', name = spec, mat_type = mt.mat_type, mat_index = mt.mat_index}
    end
    -- category flag (wood/cloth/...)?
    for _, w in ipairs(rest) do
        if CATEGORY_WORDS[w] then return {kind = 'category', category = CATEGORY_WORDS[w]} end
    end
    -- bare class (stone/metal/glass) or a lone constraint -> concrete resolution
    if class or constraint then
        local cls = class or 'stone'
        return {kind = 'class', class = cls, constraint = constraint,
                picked = want_in_stock and want_in_stock(cls, constraint, item)}
    end
    return nil, ('unknown material "%s"'):format(table.concat(rest, ' '))
end

-- ---- top-level parse -----------------------------------------------------

local WORDNUM = {one=1,two=2,three=3,four=4,five=5,six=6,seven=7,eight=8,nine=9,
    ten=10,eleven=11,twelve=12,['a']=1,['an']=1}

local function parse(input)
    local s = norm(input):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil, 'empty' end
    local tokens = {}
    for w in s:gmatch('%S+') do tokens[#tokens + 1] = w end

    -- leading r / rN -> repeating
    local repeating = false
    local t1 = tokens[1]
    local rnum = t1:match('^r(%d+)$')
    if t1 == 'r' then repeating = true; table.remove(tokens, 1)
    elseif rnum then repeating = true; tokens[1] = rnum end

    -- amount
    local amount
    for idx, w in ipairs(tokens) do
        if w:match('^%d+$') then amount = tonumber(w); table.remove(tokens, idx); break
        elseif WORDNUM[w] then amount = WORDNUM[w]; table.remove(tokens, idx); break end
    end
    amount = amount or 1

    if #tokens == 0 then return nil, 'no item' end

    -- fuzzy split: try every boundary, score (item right, material left)
    local best
    for cut = 0, #tokens - 1 do
        local left, right = {}, {}
        for k = 1, cut do left[#left + 1] = tokens[k] end
        for k = cut + 1, #tokens do right[#right + 1] = tokens[k] end
        local item, iscore = best_item(right)
        if item and iscore > 0 then
            local matscore = (#left == 0) and 1 or 5  -- mild bias toward consuming words as material
            local total = iscore + matscore
            if not best or total > best.total then
                best = {total = total, item = item, iscore = iscore, left = left}
            end
        end
    end
    if not best then return nil, 'no item recognized' end

    return {repeating = repeating, amount = amount, item = best.item,
            left = best.left, iscore = best.iscore}, nil
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
    return true  -- mechanisms/furniture/etc: any hard material
end

-- pick the most-abundant concrete material of a class in stock that can actually
-- make this item (constraint-aware). stone -> boulders, metal -> bars.
function most_in_stock(class, constraint, item)
    local list = (class == 'stone' and df.global.world.items.other.BOULDER)
        or (class == 'metal' and df.global.world.items.other.BAR) or nil
    if not list then return nil end
    local counts = {}
    for _, it in ipairs(list) do
        if it.mat_type == 0 and ((not constraint) or is_magma_safe(0, it.mat_index))
            and (not item or mat_makes(item.item_type, it.mat_index))
        then
            counts[it.mat_index] = (counts[it.mat_index] or 0) + it.stack_size
        end
    end
    local best, bestn
    for mi, n in pairs(counts) do if not bestn or n > bestn then best, bestn = mi, n end end
    if not best then return nil end
    local ir = df.inorganic_raw.find(best)
    return {mat_type = 0, mat_index = best,
            name = ir and ir.id:lower():gsub('_', ' ') or '?', count = bestn}
end

-- expose for dry-run / tests / future UI
function dry_run(input)
    local p, err = parse(input)
    if not p then return {error = err} end
    local mat, merr = resolve_material(p.left, p.item, most_in_stock)
    return {repeating = p.repeating, amount = p.amount,
            item = p.item, item_score = p.iscore,
            material = mat, material_error = merr}
end

if dfhack_flags.module then return end

-- command: dry-run print
local args = {...}
local create = false
local parts = {}
for _, a in ipairs(args) do
    if a == '--create' then create = true else parts[#parts + 1] = a end
end
local input = table.concat(parts, ' ')
local r = dry_run(input)
if r.error then dfhack.printerr('parse failed: ' .. r.error); return end
print(('repeating=%s amount=%d'):format(tostring(r.repeating), r.amount))
print(('item: %s (job=%s type=%s sub=%d) score=%d'):format(
    r.item.name, df.job_type[r.item.job], df.item_type[r.item.item_type], r.item.item_subtype, r.item_score))
if r.material_error then
    print('material: FAILED -- ' .. r.material_error)
else
    local m = r.material
    if m.kind == 'specific' then print(('material: %s (specific, %d:%d)'):format(m.name, m.mat_type, m.mat_index))
    elseif m.kind == 'category' then print('material: any ' .. m.category .. ' (category)')
    elseif m.kind == 'class' then
        if m.picked then print(('material: %s (%d in stock; most-numerous %s%s)'):format(
            m.picked.name, m.picked.count, m.constraint and (m.constraint .. '-safe ') or '', m.class))
        else print(('material: no %s%s in stock'):format(
            m.constraint and (m.constraint .. '-safe ') or '', m.class)) end
    else print('material: (unspecified)') end
end
