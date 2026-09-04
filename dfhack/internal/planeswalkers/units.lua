-- Units + historical-figure graph save/load for fort/planeswalkers.
--@module = true

local common = reqscript('internal/planeswalkers/common')

-- ---- shared helpers --------------------------------------------------------

local function name_out(name)
    local words, pos = {}, {}
    for i = 0, 6 do
        words[i + 1] = name.words[i]
        pos[i + 1] = name.parts_of_speech[i]
    end
    return {
        first = common.u(name.first_name),
        nick = #name.nickname > 0 and common.u(name.nickname) or nil,
        words = words, pos = pos, lang = name.language,
        has = name.has_name,
        rendered = common.u(dfhack.translation.translateName(name)),
    }
end

local function name_in(dst, rec, ctx)
    if not rec then return end
    dst.first_name = common.fromu(rec.first or '')
    dst.nickname = common.fromu(rec.nick or '')
    dst.language = rec.lang or 0
    dst.has_name = rec.has and true or false
    local nwords = #df.global.world.raws.language.words
    local ok = true
    for i = 0, 6 do
        local w = rec.words[i + 1] or -1
        if w >= nwords then ok = false w = -1 end
        dst.words[i] = w
        dst.parts_of_speech[i] = rec.pos[i + 1] or 0
    end
    if rec.has and (not ok
        or common.u(dfhack.translation.translateName(dst)) ~= rec.rendered) then
        -- language tables differ; keep the literal rendering as the first name
        for i = 0, 6 do dst.words[i] = -1 end
        dst.first_name = common.fromu(rec.rendered)
        if ctx then common.add_skip(ctx, 'name-literalized', rec.rendered) end
    end
end

local function race_tokens(race, caste)
    if not race or race < 0 then return nil end  -- deities/forces have race -1
    local craw = df.global.world.raws.creatures.all[race]
    if not craw then return nil end
    local ct = caste and caste >= 0 and craw.caste[caste] and craw.caste[caste].caste_id or nil
    return craw.creature_id, ct, craw.flags.GENERATED and true or false
end

function resolve_race(ctx, rtoken, ctoken)
    ctx.race_cache = ctx.race_cache or {}
    local key = rtoken .. ':' .. tostring(ctoken)
    local hit = ctx.race_cache[key]
    if hit ~= nil then
        if hit then return hit.r, hit.c end
        return nil
    end
    for i, craw in ipairs(df.global.world.raws.creatures.all) do
        if craw.creature_id == rtoken then
            local caste = 0
            if ctoken then
                for ci, c in ipairs(craw.caste) do
                    if c.caste_id == ctoken then caste = ci break end
                end
            end
            ctx.race_cache[key] = {r = i, c = caste}
            return i, caste
        end
    end
    ctx.race_cache[key] = false
    return nil
end

-- ---- save ------------------------------------------------------------------

local function classify(u)
    if dfhack.units.isCitizen(u, true) then return 'citizen' end
    local ok = pcall(function() return dfhack.units.isPet(u) end)
    if (ok and dfhack.units.isPet(u)) or dfhack.units.isTame(u) then return 'pet' end
    -- livestock in 50.x: the fort's own animal with a training level, whether
    -- or not the old tame flag is set
    local okd, dom = pcall(function()
        return dfhack.units.isOwnCiv(u) or u.training_level ~= df.animal_training_level.WildUntamed
    end)
    if okd and dom then return 'pet' end
    if dfhack.units.isInvader(u) then return 'invader' end
    if dfhack.units.isMerchant(u) or dfhack.units.isForest(u) then return 'merchant' end
    if dfhack.units.isVisitor(u) then return 'visitor' end
    return 'wild'
end

-- shared with the extras module (location names, image names)
name_out_pub, name_in_pub = name_out, name_in

local function link_type_name(link)
    return tostring(link._type):match('histfig_hf_link_(%w+)st')
end

local function save_hf(ctx, hf, stub)
    local rtok, ctok = race_tokens(hf.race, hf.caste)
    local rec = {
        id = hf.id,
        name = name_out(hf.name),
        race = rtok, caste = ctok,
        sex = hf.sex,
        age = math.max(0, ctx.src_year - hf.born_year),
        dead = hf.died_year >= 0 or nil,
        stub = stub or nil,
    }
    if not stub then
        rec.links = {}
        for _, l in ipairs(hf.histfig_links) do
            local tn = link_type_name(l)
            if tn then
                table.insert(rec.links, {t = tn, hf = l.target_hf,
                                         s = l.link_strength})
            end
        end
        -- what this figure has killed, by species
        rec.kills = reqscript('internal/planeswalkers/extras').kills_out(hf)
        -- necromancer / curse signature (bound to dest world's secrets in M5)
        local okc, curse = pcall(function() return hf.info.curse end)
        if okc and curse and #curse.active_interactions > 0 then
            rec.curse = {spheres = {}}
            for _, ai in ipairs(curse.active_interactions) do
                for _, src in ipairs(ai.sources) do
                    if df.interaction_source_secretst:is_instance(src) then
                        for _, sp in ipairs(src.spheres) do
                            table.insert(rec.curse.spheres, df.sphere_type[sp])
                        end
                    end
                end
            end
        end
    end
    return rec
end

-- "was ever an adventurer" lives on the nemesis record, nowhere else (see
-- fort/rusty-legends). The flagarray may be unallocated: reading an index past
-- its length SIGSEGVs through a NULL bits pointer, so length-check first.
local function adventurer_bits(u)
    local nem = dfhack.units.getNemesis(u)
    if not nem then return nil end
    local ok, n = pcall(function() return #nem.flags end)
    if not ok or type(n) ~= 'number' then return nil end
    local bits = 0
    if n > df.nemesis_flags.ADVENTURER
        and nem.flags[df.nemesis_flags.ADVENTURER] then bits = bits | 1 end
    if n > df.nemesis_flags.ACTIVE_ADVENTURER
        and nem.flags[df.nemesis_flags.ACTIVE_ADVENTURER] then bits = bits | 2 end
    return bits > 0 and bits or nil
end

local function save_unit(ctx, u)
    local rtok, ctok, generated = race_tokens(u.race, u.caste)
    if not rtok then return nil end
    local rec = {
        id = u.id,
        hf = u.hist_figure_id >= 0 and u.hist_figure_id or nil,
        race = rtok, caste = ctok, generated = generated or nil,
        gsize = generated and reqscript('internal/planeswalkers/match')
            .adult_size(df.global.world.raws.creatures.all[u.race], u.caste) or nil,
        name = name_out(u.name),
        sex = u.sex,
        class = classify(u),
        age = math.max(0, ctx.src_year - u.birth_year),
        adv = adventurer_bits(u),
        prof = df.profession[u.profession],
        cprof = #u.custom_profession > 0 and common.u(u.custom_profession) or nil,
        tame = u.flags1.tame or nil,
        train = df.animal_training_level[u.training_level],
    }
    -- a unit wandering outside the saved footprint comes along regardless,
    -- pulled to the nearest tile inside it
    local px, py = u.pos.x, u.pos.y
    if not common.in_footprint(ctx, px, py) then
        px, py = common.clamp_to_footprint(ctx, px, py)
        common.add_skip(ctx, 'unit-outside-footprint-moved-in', rtok)
    end
    rec.x, rec.y, rec.z = px - ctx.origin.x, py - ctx.origin.y, u.pos.z
    -- labors
    local labors = {}
    for i = 0, #u.status.labors - 1 do
        labors[#labors + 1] = u.status.labors[i] and '1' or '0'
    end
    rec.labors = table.concat(labors)
    local soul = u.status.current_soul
    if soul then
        rec.skills = {}
        for _, sk in ipairs(soul.skills) do
            local tok = df.job_skill[sk.id]
            if tok then
                table.insert(rec.skills, {s = tok, r = sk.rating, x = sk.experience})
            end
        end
        rec.mental = {}
        for i = 0, #soul.mental_attrs - 1 do
            local a = soul.mental_attrs[i]
            rec.mental[i + 1] = {a.value, a.max_value}
        end
        rec.traits = {}
        for i = 0, #soul.personality.traits - 1 do
            rec.traits[i + 1] = soul.personality.traits[i]
        end
        rec.values = {}
        for _, v in ipairs(soul.personality.values) do
            table.insert(rec.values, {t = df.value_type[v.type], s = v.strength})
        end
    end
    rec.phys = {}
    for i = 0, #u.body.physical_attrs - 1 do
        local a = u.body.physical_attrs[i]
        rec.phys[i + 1] = {a.value, a.max_value}
    end
    -- appearance (same-version worlds: array layouts match per race/caste)
    local ap = u.appearance
    local function arr(v)
        local t = {}
        for i = 0, #v - 1 do t[i + 1] = v[i] end
        return t
    end
    rec.app = {
        bm = arr(ap.body_modifiers),
        bp = arr(ap.bp_modifiers),
        col = arr(ap.colors),
        size = ap.size_modifier,
    }
    local okg, genes = pcall(function() return ap.genes end)
    if okg and genes then
        rec.app.ga = arr(genes.appearance)
        rec.app.gc = arr(genes.colors)
    end
    -- relationships (unit ids; remapped on load)
    rec.rel = {}
    for i = 0, #u.relationship_ids - 1 do
        local rid = u.relationship_ids[i]
        if rid >= 0 then rec.rel[df.unit_relationship_type[i]] = rid end
    end
    return rec
end

function save_phases(ctx)
    return {{
        name = 'histfigs',
        step = function(job)
            ctx.src_year = df.global.cur_year
            ctx.manifest.src_year = ctx.src_year
            local out = {v = 1, list = {}}
            local in_set = {}
            local units = df.global.world.units.active
            for _, u in ipairs(units) do
                if u.hist_figure_id >= 0 then in_set[u.hist_figure_id] = true end
            end
            -- one hop: link targets outside the set become stubs
            local stubs = {}
            for hid in pairs(in_set) do
                local hf = df.historical_figure.find(hid)
                if hf then
                    for _, l in ipairs(hf.histfig_links) do
                        if not in_set[l.target_hf] then stubs[l.target_hf] = true end
                    end
                end
            end
            for hid in pairs(in_set) do
                local hf = df.historical_figure.find(hid)
                if hf then table.insert(out.list, save_hf(ctx, hf, false)) end
            end
            for hid in pairs(stubs) do
                local hf = df.historical_figure.find(hid)
                if hf then table.insert(out.list, save_hf(ctx, hf, true)) end
            end
            common.write_json(ctx.dir .. '/histfigs.json', out)
            -- noble/administrator positions held by figures of this fort
            local positions = reqscript('internal/planeswalkers/extras').positions_out(in_set)
            common.write_json(ctx.dir .. '/positions.json', {v = 1, list = positions})
            common.write_json(ctx.dir .. '/workdetails.json',
                              reqscript('internal/planeswalkers/extras').workdetails_out())
            ctx.manifest.counts.positions = #positions
            ctx.manifest.counts.histfigs = #out.list
            ctx.manifest.complete.histfigs = true
            return true
        end,
    }, {
        name = 'units',
        init = function(job)
            job.out = {v = 1, list = {}}
            job.cursor = 0
        end,
        total = function() return #df.global.world.units.active end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local vec = df.global.world.units.active
            while job.cursor < #vec do
                local u = vec[job.cursor]
                job.cursor = job.cursor + 1
                if not dfhack.units.isDead(u) then
                    local ok, rec = pcall(save_unit, ctx, u)
                    if ok and rec then table.insert(job.out.list, rec)
                    elseif not ok then
                        common.add_skip(ctx, 'unit-save-error', tostring(rec))
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            common.write_json(ctx.dir .. '/units.json', job.out)
            ctx.manifest.counts.units = #job.out.list
            ctx.manifest.complete.units = true
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function dest_birth_year(age) return df.global.cur_year - (age or 0) end

-- minimal dead/absent historical figure (createFigure recipe, trimmed)
local function mint_hf(ctx, rec)
    local r, c
    if rec.race then r, c = resolve_race(ctx, rec.race, rec.caste) end
    local hf = df.historical_figure:new()
    hf.id = df.global.hist_figure_next_id
    df.global.hist_figure_next_id = hf.id + 1
    hf.race = r or -1
    hf.caste = c or -1
    hf.sex = rec.sex or -1
    hf.appeared_year = dest_birth_year(rec.age)
    hf.born_year = dest_birth_year(rec.age)
    hf.born_seconds = 0
    hf.curse_year = -1; hf.curse_seconds = -1
    hf.old_year = df.global.cur_year + 100; hf.old_seconds = 0
    if rec.dead or rec.stub then
        hf.died_year = math.max(0, df.global.cur_year - 1)
        hf.died_seconds = 0
    else
        hf.died_year = -1; hf.died_seconds = -1
    end
    hf.civ_id = -1
    hf.population_id = -1
    hf.breed_id = -1
    hf.cultural_identity = -1
    hf.family_head_id = hf.id
    name_in(hf.name, rec.name, ctx)
    df.global.world.history.figures:insert('#', hf)
    return hf
end

local function write_skills(u, hf, skills)
    local soul = u.status.current_soul
    if not soul or not skills then return end
    -- snapshot order is the source soul's order (already ascending by id);
    -- re-sort defensively -- DF binary-searches these vectors
    local list = {}
    for _, sk in ipairs(skills) do
        local id = df.job_skill[sk.s]
        if id then table.insert(list, {id = id, r = sk.r, x = sk.x}) end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    for _, sk in ipairs(list) do
        soul.skills:insert('#', {new = true, id = sk.id, rating = sk.r,
                                 experience = sk.x})
        if hf and hf.info and hf.info.skills then
            local sp = hf.info.skills
            local total = 500 * sk.r + 100 * (sk.r * (sk.r - 1)) // 2 + sk.x
            local at = '#'
            for i, sid in ipairs(sp.skills) do
                if sid > sk.id then at = i break end
            end
            sp.skills:insert(at, sk.id)
            sp.points:insert(at, total)
        end
    end
end

local function write_body(u, rec)
    if rec.phys then
        for i = 0, math.min(#u.body.physical_attrs, #rec.phys) - 1 do
            u.body.physical_attrs[i].value = rec.phys[i + 1][1]
            u.body.physical_attrs[i].max_value = rec.phys[i + 1][2]
        end
    end
    local soul = u.status.current_soul
    if soul then
        if rec.mental then
            for i = 0, math.min(#soul.mental_attrs, #rec.mental) - 1 do
                soul.mental_attrs[i].value = rec.mental[i + 1][1]
                soul.mental_attrs[i].max_value = rec.mental[i + 1][2]
            end
        end
        if rec.traits then
            for i = 0, math.min(#soul.personality.traits, #rec.traits) - 1 do
                soul.personality.traits[i] = rec.traits[i + 1]
            end
        end
        if rec.values then
            soul.personality.values:resize(0)
            for _, v in ipairs(rec.values) do
                local vt = df.value_type[v.t]
                if vt then
                    soul.personality.values:insert('#', {new = true, type = vt,
                                                         strength = v.s})
                end
            end
        end
    end
    if rec.app then
        local ap = u.appearance
        local function warr(dst, src)
            if not src then return end
            for i = 0, math.min(#dst, #src) - 1 do dst[i] = src[i + 1] end
        end
        warr(ap.body_modifiers, rec.app.bm)
        warr(ap.bp_modifiers, rec.app.bp)
        warr(ap.colors, rec.app.col)
        if rec.app.size then ap.size_modifier = rec.app.size end
        local okg, genes = pcall(function() return ap.genes end)
        if okg and genes then
            warr(genes.appearance, rec.app.ga)
            warr(genes.colors, rec.app.gc)
        end
    end
end

local function safe_spawn_pos(ctx, rec)
    local a = ctx.anchor
    local x = rec.x + a.off_x
    local y = rec.y + a.off_y
    local z = math.max(1, math.min(df.global.world.map.z_count - 2, rec.z + a.off_z))
    local tt = dfhack.maps.getTileType(x, y, z)
    if tt and df.tiletype.attrs[tt].shape ~= df.tiletype_shape.WALL then
        return xyz2pos(x, y, z)
    end
    return ctx.spawn_anchor  -- fallback: beside an existing citizen
end

local function spawn_unit(ctx, rec)
    local r, c = resolve_race(ctx, rec.race, rec.caste)
    if not r and rec.generated then
        -- procedural race: substitute the closest generated creature here
        r = reqscript('internal/planeswalkers/match')
            .match_generated(ctx, rec.race, rec.gsize)
        c = 0
    end
    if not r then
        common.add_skip(ctx, rec.generated and 'unit-generated-race-unmatched'
                             or 'unit-race-missing-in-world', rec.race)
        return nil
    end
    local pos = safe_spawn_pos(ctx, rec)
    if not pos then
        common.add_skip(ctx, 'unit-no-spawn-pos', rec.race)
        return nil
    end
    local u = dfhack.units.create(r, c)
    if not u then
        common.add_skip(ctx, 'unit-create-failed', rec.race)
        return nil
    end
    -- proven in-play recipe: pos seed -> live -> active-insert -> teleport
    u.pos.x, u.pos.y, u.pos.z = pos.x, pos.y, pos.z
    u.flags1.inactive = false
    df.global.world.units.active:insert('#', u)
    dfhack.units.teleport(u, xyz2pos(pos.x, pos.y, pos.z))
    u.birth_year = dest_birth_year(rec.age)
    if rec.class == 'citizen' or rec.class == 'pet' then
        dfhack.units.makeown(u)
        if rec.class == 'pet' then
            -- livestock: the fort's own tame animal, at its training level
            pcall(function()
                u.flags1.tame = true
                u.civ_id = df.global.plotinfo.civ_id  -- makeown leaves an animal's civ unset
                local lvl = rec.train and df.animal_training_level[rec.train]
                if not lvl or lvl == df.animal_training_level.WildUntamed then
                    lvl = df.animal_training_level.Domesticated
                end
                u.training_level = lvl
            end)
        end
    else
        u.civ_id = -1
        if rec.class == 'invader' then
            pcall(function()
                u.flags1.marauder = true
                u.flags1.active_invader = true
            end)
        end
    end
    name_in(u.name, rec.name, ctx)
    local prof = rec.prof and df.profession[rec.prof]
    if prof then u.profession = prof; u.profession2 = prof end
    if rec.cprof then u.custom_profession = common.fromu(rec.cprof) end
    if rec.labors then
        for i = 0, math.min(#u.status.labors, #rec.labors) - 1 do
            u.status.labors[i] = rec.labors:sub(i + 1, i + 1) == '1'
        end
    end
    local hf = u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id)
    if hf then
        name_in(hf.name, rec.name, ctx)
        hf.born_year = u.birth_year
        hf.sex = rec.sex or hf.sex
    end
    write_skills(u, hf or nil, rec.skills)
    write_body(u, rec)
    if rec.adv then
        -- re-mark as a (retired) adventurer so DF's unretire list picks the
        -- unit up again. Only ADVENTURER is restored: ACTIVE_ADVENTURER means
        -- "being played right now" and must never be true in fort mode.
        local nem = dfhack.units.getNemesis(u)
        if nem then
            if #nem.flags <= df.nemesis_flags.ADVENTURER then
                nem.flags:resize(31)  -- same size DF allocates (modtools/create-unit)
            end
            nem.flags[df.nemesis_flags.ADVENTURER] = true
        else
            common.add_skip(ctx, 'adventurer-flag-lost-no-nemesis',
                            rec.name and rec.name.rendered)
        end
    end
    return u, hf
end

function load_phases(ctx)
    local phases = {}

    table.insert(phases, {
        name = 'units',
        init = function(job)
            job.units = common.read_json(ctx.dir .. '/units.json') or {list = {}}
            job.cursor = 1
            ctx.unit_map, ctx.hf_map = {}, {}
            df.global.pause_state = true
            local anchor = dfhack.units.getCitizens(true)[1]
            ctx.spawn_anchor = anchor and xyz2pos(anchor.pos.x, anchor.pos.y, anchor.pos.z)
        end,
        total = function(job) return #job.units.list end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            while job.cursor <= #job.units.list do
                local rec = job.units.list[job.cursor]
                job.cursor = job.cursor + 1
                local ok, u, hf = pcall(spawn_unit, ctx, rec)
                if ok and u then
                    ctx.unit_map[rec.id] = u
                    if rec.hf and hf then ctx.hf_map[rec.hf] = hf end
                    if rec.class ~= 'citizen' and rec.class ~= 'pet' then
                        common.add_skip(ctx, 'unit-restored-civless-' .. rec.class)
                    end
                elseif not ok then
                    common.add_skip(ctx, 'unit-load-error', tostring(u))
                end
                -- spawning is heavy; keep batches small
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'histfig stubs',
        init = function(job)
            job.hfs = common.read_json(ctx.dir .. '/histfigs.json') or {list = {}}
            job.cursor = 1
        end,
        total = function(job) return #job.hfs.list end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            while job.cursor <= #job.hfs.list do
                local rec = job.hfs.list[job.cursor]
                job.cursor = job.cursor + 1
                if not ctx.hf_map[rec.id] then
                    local ok, hf = pcall(mint_hf, ctx, rec)
                    if ok and hf then ctx.hf_map[rec.id] = hf
                    elseif not ok then
                        common.add_skip(ctx, 'histfig-mint-error', tostring(hf))
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'histfig links',
        init = function(job)
            job.hfs = job.hfs or common.read_json(ctx.dir .. '/histfigs.json') or {list = {}}
            job.cursor = 1
        end,
        total = function(job) return #job.hfs.list end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            while job.cursor <= #job.hfs.list do
                local rec = job.hfs.list[job.cursor]
                job.cursor = job.cursor + 1
                local hf = ctx.hf_map[rec.id]
                if hf and rec.links then
                    for _, l in ipairs(rec.links) do
                        local target = ctx.hf_map[l.hf]
                        local cls = df['histfig_hf_link_' .. l.t .. 'st']
                        if target and cls then
                            local link = cls:new()
                            link.target_hf = target.id
                            link.link_strength = l.s or 100
                            hf.histfig_links:insert('#', link)
                        elseif not cls then
                            common.add_skip(ctx, 'histfig-link-type-unknown', l.t)
                        end
                    end
                end
                if hf and rec.kills then
                    reqscript('internal/planeswalkers/extras').kills_in(ctx, hf, rec.kills)
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'curses',
        init = function(job)
            job.hfs = job.hfs or common.read_json(ctx.dir .. '/histfigs.json') or {list = {}}
        end,
        step = function(job)
            local match = reqscript('internal/planeswalkers/match')
            for _, rec in ipairs(job.hfs.list) do
                if rec.curse and #(rec.curse.spheres or {}) > 0 then
                    local hf = ctx.hf_map[rec.id]
                    if hf then match.bind_curse(ctx, hf, rec.curse) end
                end
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'unit relationships',
        init = function(job)
            job.units = job.units or common.read_json(ctx.dir .. '/units.json') or {list = {}}
        end,
        step = function(job)
            for _, rec in ipairs(job.units.list) do
                local u = ctx.unit_map[rec.id]
                if u and rec.rel then
                    for tname, old_id in pairs(rec.rel) do
                        local ti = df.unit_relationship_type[tname]
                        local target = ctx.unit_map[old_id]
                        if ti and target then
                            u.relationship_ids[ti] = target.id
                        end
                    end
                end
            end
            return true
        end,
    })

    return phases
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
