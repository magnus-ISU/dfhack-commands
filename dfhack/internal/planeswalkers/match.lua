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

local function stem_of(token)
    for _, s in ipairs(GEN_STEMS) do
        if token:find(s, 1, true) == 1 then return s end
    end
    return token:match('^([%a_]+)_%d') or token
end

function adult_size(craw, caste)
    local c = craw.caste[caste or 0] or craw.caste[0]
    if not c then return 0 end
    local ok, sz = pcall(function() return c.body_size_2 end)
    return ok and sz or 0
end

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
    local best, best_d
    for i, craw in ipairs(df.global.world.raws.creatures.all) do
        if craw.flags.GENERATED and craw.creature_id:find(stem, 1, true) == 1 then
            local d = math.abs(adult_size(craw) - (want_size or 0))
            if not best or d < best_d then best, best_d = i, d end
        end
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
