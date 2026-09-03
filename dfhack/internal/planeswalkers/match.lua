-- Best-effort cross-world matching of procedurally generated content:
-- generated races (forgotten beasts, titans, demons, night creatures...) and
-- necromancer secrets. Exact identity cannot cross worlds; we map to the
-- destination world's nearest equivalent and keep names.
--@module = true

local common = reqscript('internal/planeswalkers/common')

-- generated creature tokens share recognizable stems per procedural class
local GEN_STEMS = {
    'FORGOTTEN_BEAST', 'TITAN', 'DEMON', 'NIGHT_CREATURE', 'BOGEYMAN',
    'ANGEL', 'WEREBEAST', 'EXPERIMENT', 'HF',
}

-- the letters before the first digit: FORGOTTEN_BEAST_, DEMON_, HFEXP, HF...
local function stem_of(token)
    local lead = token:match('^([%a_]-)%d')
    if lead and #lead > 0 then return lead end
    for _, s in ipairs(GEN_STEMS) do
        if token:find(s, 1, true) == 1 then return s end
    end
    return token:match('^([%a_]+)_%d') or token
end

-- a material token the destination lacks, mapped to its nearest local one:
-- a generated creature's material goes to the closest local creature of the
-- same kind (same material name when it has one), a divine metal to any
-- local divine metal. Returns a matinfo or nil.
function resolve_mat_token(ctx, tok)
    if not tok then return nil end
    local mi = dfhack.matinfo.find(tok)
    if mi then return mi end
    ctx.mat_token_cache = ctx.mat_token_cache or {}
    local hit = ctx.mat_token_cache[tok]
    if hit ~= nil then return hit or nil end
    local out
    local race, mat = tok:match('^CREATURE:([^:]+):(.+)$')
    if race then
        local gi = match_generated(ctx, race, 0)
        local craw = gi and df.global.world.raws.creatures.all[gi]
        if craw then
            out = dfhack.matinfo.find('CREATURE:' .. craw.creature_id .. ':' .. mat)
            if not out then
                -- no such material on the stand-in: its first material
                for _, m in ipairs(craw.material) do
                    out = dfhack.matinfo.find('CREATURE:' .. craw.creature_id .. ':' .. m.id)
                    if out then break end
                end
            end
        end
    elseif tok:match('^INORGANIC:DIVINE_') then
        for _, raw in ipairs(df.global.world.raws.inorganics.all) do
            if raw.id:match('^DIVINE_') then out = dfhack.matinfo.find('INORGANIC:' .. raw.id) break end
        end
    end
    if out then common.add_skip(ctx, 'material-substituted', tok .. ' -> ' .. out:getToken()) end
    ctx.mat_token_cache[tok] = out or false
    return out
end

local SUBTYPE_CATEGORY = {
    WEAPON = 'weapons', ARMOR = 'armor', SHOES = 'shoes', SHIELD = 'shields',
    HELM = 'helms', GLOVES = 'gloves', AMMO = 'ammo', TRAPCOMP = 'trapcomps',
    PANTS = 'pants', TOOL = 'tools', INSTRUMENT = 'instruments', TOY = 'toys',
    SIEGEAMMO = 'siege_ammo', FOOD = 'food',
}

-- an item subtype token, or the local equivalent of a world-generated one:
-- divine gear is "HF<deity> EI1<set><kind><n>" in every world, only the deity
-- number differs, so the same suffix on any local deity is the same piece
function resolve_subtype(ctx, item_type_name, st)
    if not st then return -1 end
    local ok, v = pcall(dfhack.items.findSubtype, item_type_name .. ':' .. st)
    if ok and v and v ~= -1 then return v end
    ctx.subtype_cache = ctx.subtype_cache or {}
    local key = item_type_name .. ':' .. st
    local hit = ctx.subtype_cache[key]
    if hit ~= nil then return hit end
    local found = -1
    local suffix = st:match('^HF%d+ (.+)$')
    local cat = SUBTYPE_CATEGORY[item_type_name]
    if suffix and cat then
        for i, def in ipairs(df.global.world.raws.itemdefs[cat]) do
            if def.id:match('^HF%d+ ' .. suffix:gsub('%p', '%%%0') .. '$') then
                found = def.subtype
                common.add_skip(ctx, 'subtype-substituted', key .. ' -> ' .. def.id)
                break
            end
        end
    end
    ctx.subtype_cache[key] = found
    return found
end

function adult_size(craw, caste)
    local c = craw.caste[caste or 0] or craw.caste[0]
    if not c then return 0 end
    -- misc.adult_size is what tells a vault's colossal guardian (1,000,000)
    -- from a rank-and-file angel (6-9k); body_size_2 is a fallback
    local ok, sz = pcall(function() return c.misc.adult_size end)
    if ok and sz and sz > 0 then return sz end
    local ok2, sz2 = pcall(function() return c.body_size_2 end)
    return ok2 and sz2 or 0
end

-- a token with its numerals removed: 'HF595 DIVINE_2' -> 'HF DIVINE_', which
-- every world's angels share, while experiments ('HFEXP E_HUM') do not
local function skeleton(token) return (token:gsub('%d+', '')) end

-- match a generated race by class stem + closest adult body size
function match_generated(ctx, token, want_size)
    ctx.gen_cache = ctx.gen_cache or {}
    local key = token .. ':' .. tostring(want_size)
    local hit = ctx.gen_cache[key]
    if hit ~= nil then
        if hit then return hit end
        return nil
    end
    local stem = stem_of(token)
    local skel = skeleton(token)
    local best, best_d
    -- first the creatures of exactly the same kind (same token skeleton), by
    -- closest adult size: an archangel's kill lands on an archangel, an
    -- angel's on an angel; then anything of the same stem
    for pass = 1, 2 do
        for i, craw in ipairs(df.global.world.raws.creatures.all) do
            local id = craw.creature_id
            if craw.flags.GENERATED and ((pass == 1 and skeleton(id) == skel)
                                          or (pass == 2 and id:find(stem, 1, true) == 1)) then
                local d = math.abs(adult_size(craw) - (want_size or 0))
                if not best or d < best_d then best, best_d = i, d end
            end
        end
        if best then break end
    end
    ctx.gen_cache[key] = best or false
    if best then
        common.add_skip(ctx, 'generated-race-substituted',
            token .. ' -> ' .. df.global.world.raws.creatures.all[best].creature_id)
    end
    return best
end

-- ---- necromancer secrets ---------------------------------------------------

-- find a destination interaction whose source is a secret with overlapping
-- spheres (e.g. DEATH -> the dest world's own necromancy secret)
local function find_secret_interaction(spheres)
    local want = {}
    for _, s in ipairs(spheres or {}) do want[s] = true end
    local best, best_overlap = nil, 0
    for _, inter in ipairs(df.global.world.raws.interactions) do
        for _, src in ipairs(inter.sources) do
            if df.interaction_source_secretst:is_instance(src) then
                local overlap = 0
                for _, sp in ipairs(src.spheres) do
                    if want[df.sphere_type[sp]] then overlap = overlap + 1 end
                end
                if overlap > best_overlap then best, best_overlap = inter, overlap end
            end
        end
    end
    return best
end

-- give hf (and its unit, if any) the dest world's equivalent secret powers
function bind_curse(ctx, hf, curse_rec)
    local inter = find_secret_interaction(curse_rec.spheres)
    if not inter then
        common.add_skip(ctx, 'secret-unmatched-in-world',
                        table.concat(curse_rec.spheres or {}, ','))
        return false
    end
    local ok, err = pcall(function()
        local curse = hf.info.curse
        if not curse then
            hf.info.curse = df.historical_figure_info.T_curse:new()
            curse = hf.info.curse
        end
        curse.active_interactions:insert('#', inter)
        for _, ce in ipairs(inter.sources) do
            if df.interaction_source_secretst:is_instance(ce) then
                -- learning the secret is what DF records; effects follow from
                -- the interaction pointer itself
                break
            end
        end
    end)
    if ok then
        common.add_skip(ctx, 'secret-rebound',
                        table.concat(curse_rec.spheres or {}, ','))
        return true
    end
    common.add_skip(ctx, 'secret-rebind-failed', tostring(err))
    return false
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
