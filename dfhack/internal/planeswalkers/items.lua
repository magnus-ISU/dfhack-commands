-- Items + artifacts save/load for fort/planeswalkers.
--@module = true

local common = reqscript('internal/planeswalkers/common')

-- item types whose identity is a dead unit's body -- not restorable cross-world
local SKIP_TYPES = {
    [df.item_type.CORPSE] = 'corpses-not-restored',
    [df.item_type.CORPSEPIECE] = 'corpse-pieces-not-restored',
}

local function subtype_token(item)
    local st = item:getSubtype()
    if st < 0 then return nil end
    local ok, def = pcall(dfhack.items.getSubtypeDef, item:getType(), st)
    return ok and def and def.id or nil
end

local function race_token(race, caste)
    if not race or race < 0 then return nil end
    local craw = df.global.world.raws.creatures.all[race]
    if not craw then return nil end
    local ct = caste and caste >= 0 and craw.caste[caste] and craw.caste[caste].caste_id
    return craw.creature_id, ct
end

-- ---- save ------------------------------------------------------------------

local function save_one(ctx, item)
    local itype = item:getType()
    local skip = SKIP_TYPES[itype]
    if skip then
        common.add_skip(ctx, skip)
        return nil
    end
    if item.flags.in_building then return nil end       -- building components re-minted
    if item.flags.construction then return nil end
    if item.flags.garbage_collect then return nil end
    local mi = dfhack.matinfo.decode(item)
    local rec = {
        id = item.id,
        t = df.item_type[itype],
        st = subtype_token(item),
        mat = mi and mi:getToken() or nil,
        x = item.pos.x, y = item.pos.y, z = item.pos.z,
    }
    local stack = item:getStackSize()
    if stack and stack > 1 then rec.n = stack end
    local q = item:getQuality()
    if q and q > 0 then rec.q = q end
    local okw, wear = pcall(function() return item.wear end)
    if okw and wear and wear > 0 then rec.wear = wear end
    -- race-bearing items (eggs, fish, remains, vermin...)
    local okr, race = pcall(function() return item.race end)
    if okr and race then
        local rt, ct = race_token(race, select(2, pcall(function() return item.caste end)))
        if rt then rec.race, rec.caste = rt, ct
        else
            common.add_skip(ctx, 'item-race-unresolved', rec.t)
            return nil
        end
    end
    local okh, hand = pcall(function() return item.handedness end)
    if okh and hand then
        rec.hand = hand[0] and 1 or hand[1] and 2 or nil
    end
    -- flags worth keeping
    local f = item.flags
    rec.fl = (f.forbid and 1 or 0) | (f.dump and 2 or 0) | (f.melt and 4 or 0)
        | (f.hidden and 8 or 0) | (f.rotten and 16 or 0)
    if rec.fl == 0 then rec.fl = nil end
    if item.flags.artifact then rec.art = true end
    -- containment / holder edges
    for _, ref in ipairs(item.general_refs) do
        if df.general_ref_contained_in_itemst:is_instance(ref) then
            rec.in_item = ref.item_id
        elseif df.general_ref_building_holderst:is_instance(ref) then
            rec.in_bld = ref.building_id
        elseif df.general_ref_unit_holderst:is_instance(ref) then
            rec.on_unit = ref.unit_id
        end
    end
    -- improvements (decorations) best-effort
    local oki, imps = pcall(function() return item.improvements end)
    if oki and imps and #imps > 0 then
        rec.imp = {}
        for _, imp in ipairs(imps) do
            local imi = dfhack.matinfo.decode(imp.mat_type, imp.mat_index)
            table.insert(rec.imp, {
                t = tostring(imp._type):match('itemimprovement_(%w+)st') or 'generic',
                mat = imi and imi:getToken() or nil,
            })
        end
    end
    return rec
end

function save_phases(ctx)
    return {{
        name = 'items',
        init = function(job)
            job.items = {v = 1, list = {}}
            job.cursor = 0
        end,
        total = function() return #df.global.world.items.other.IN_PLAY end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local vec = df.global.world.items.other.IN_PLAY
            while job.cursor < #vec do
                local ok, rec = pcall(save_one, ctx, vec[job.cursor])
                if ok and rec then table.insert(job.items.list, rec)
                elseif not ok then common.add_skip(ctx, 'item-save-error', tostring(rec)) end
                job.cursor = job.cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            common.write_json(ctx.dir .. '/items.json', job.items)
            ctx.manifest.counts.items = #job.items.list
            ctx.manifest.complete.items = true
            return true
        end,
    }, {
        name = 'artifacts',
        step = function(job)
            local out = {v = 1, list = {}}
            for _, ar in ipairs(df.global.world.artifacts.all) do
                if ar.item then
                    local words, pos = {}, {}
                    for i = 0, 6 do
                        words[i + 1] = ar.name.words[i]
                        pos[i + 1] = ar.name.parts_of_speech[i]
                    end
                    table.insert(out.list, {
                        id = ar.id,
                        item = ar.item.id,
                        first = common.u(ar.name.first_name),
                        words = words,
                        pos = pos,
                        lang = ar.name.language,
                        rendered = common.u(dfhack.translation.translateName(ar.name)),
                    })
                end
            end
            common.write_json(ctx.dir .. '/artifacts.json', out)
            ctx.manifest.counts.artifacts = #out.list
            ctx.manifest.complete.artifacts = true
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function creator_unit()
    return dfhack.units.getCitizens(true)[1]
end

local function resolve_race(ctx, rtoken, ctoken)
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

local function create_one(ctx, rec)
    local itype = df.item_type[rec.t]
    if not itype then
        common.add_skip(ctx, 'item-type-unknown', rec.t)
        return nil
    end
    local isub = -1
    if rec.st then
        local ok, v = pcall(dfhack.items.findSubtype, rec.t .. ':' .. rec.st)
        if ok and v and v ~= -1 then isub = v
        else
            common.add_skip(ctx, 'item-subtype-missing', rec.t .. ':' .. rec.st)
            return nil
        end
    end
    local mt, mx = 0, -1
    if rec.mat then
        local minfo = dfhack.matinfo.find(rec.mat)
        if minfo then mt, mx = minfo.type, minfo.index
        else
            common.add_skip(ctx, 'item-mat-missing', rec.mat)
            return nil
        end
    end
    -- no_floor=false: items created "in limbo" can never be moved to ground,
    -- containers, buildings, or inventories -- create at the creator's feet
    -- and move into place immediately after
    local items = dfhack.items.createItem(creator_unit(), itype, isub, mt, mx, false)
    local item = items and items[1]
    if type(item) == 'table' then item = item[1] end
    if not item then
        common.add_skip(ctx, 'item-create-failed', rec.t)
        return nil
    end
    if rec.race then
        local r, c = resolve_race(ctx, rec.race, rec.caste)
        if r then
            pcall(function() item.race = r end)
            if c then pcall(function() item.caste = c end) end
        else
            common.add_skip(ctx, 'item-race-missing-in-world', rec.race)
        end
    end
    if rec.n then pcall(function() item:setStackSize(rec.n) end) end
    if rec.q then pcall(function() item:setQuality(math.min(rec.q, 5)) end) end
    if rec.wear then pcall(function() item.wear = rec.wear end) end
    if rec.hand then pcall(function() item:setGloveHandedness(rec.hand) end) end
    if rec.fl then
        local f = item.flags
        f.forbid = rec.fl & 1 == 1
        f.dump = rec.fl & 2 == 2
        f.melt = rec.fl & 4 == 4
        f.hidden = rec.fl & 8 == 8
        f.rotten = rec.fl & 16 == 16
    end
    return item
end

local function place_one(ctx, rec, item)
    local a = ctx.anchor
    if rec.in_item then
        local container = ctx.item_map[rec.in_item]
        if container and dfhack.items.moveToContainer(item, container) then return end
    elseif rec.in_bld then
        local bld = ctx.bld_map and ctx.bld_map[rec.in_bld]
        if bld and dfhack.items.moveToBuilding(item, bld, 0) then return end
    elseif rec.on_unit then
        local u = ctx.unit_map and ctx.unit_map[rec.on_unit]
        if u and dfhack.items.moveToInventory(item, u, 0) then return end
        common.add_skip(ctx, 'unit-held-item-grounded')
    end
    local z = math.max(1, math.min(df.global.world.map.z_count - 2, rec.z + a.off_z))
    dfhack.items.moveToGround(item, xyz2pos(rec.x + a.off_x, rec.y + a.off_y, z))
end

function load_phases(ctx)
    return {{
        name = 'items',
        init = function(job)
            job.items = common.read_json(ctx.dir .. '/items.json') or {list = {}}
            -- containers must exist before their contents: order by dependency
            local by_id = {}
            for _, rec in ipairs(job.items.list) do by_id[rec.id] = rec end
            local ordered, seen = {}, {}
            local function push(rec)
                if seen[rec.id] then return end
                seen[rec.id] = true
                if rec.in_item and by_id[rec.in_item] then push(by_id[rec.in_item]) end
                table.insert(ordered, rec)
            end
            for _, rec in ipairs(job.items.list) do push(rec) end
            job.ordered = ordered
            job.cursor = 1
            ctx.item_map = {}
        end,
        total = function(job) return #job.ordered end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            while job.cursor <= #job.ordered do
                local rec = job.ordered[job.cursor]
                job.cursor = job.cursor + 1
                local ok, item = pcall(create_one, ctx, rec)
                if ok and item then
                    ctx.item_map[rec.id] = item
                    local okp, err = pcall(place_one, ctx, rec, item)
                    if not okp then
                        common.add_skip(ctx, 'item-place-error', tostring(err))
                    end
                elseif not ok then
                    common.add_skip(ctx, 'item-load-error', tostring(item))
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    }, {
        name = 'artifacts',
        init = function(job)
            job.arts = common.read_json(ctx.dir .. '/artifacts.json') or {list = {}}
            job.cursor = 1
        end,
        total = function(job) return #job.arts.list end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local nwords = #df.global.world.raws.language.words
            while job.cursor <= #job.arts.list do
                local rec = job.arts.list[job.cursor]
                job.cursor = job.cursor + 1
                local item = ctx.item_map[rec.item]
                if item then
                    local ar = df.artifact_record:new()
                    ar.id = df.global.artifact_next_id
                    df.global.artifact_next_id = ar.id + 1
                    ar.item = item
                    ar.name.has_name = true
                    ar.name.first_name = common.fromu(rec.first or '')
                    ar.name.language = rec.lang or 0
                    local words_ok = true
                    for i = 0, 6 do
                        local w = rec.words[i + 1] or -1
                        if w >= nwords then words_ok = false w = -1 end
                        ar.name.words[i] = w
                        ar.name.parts_of_speech[i] = rec.pos[i + 1] or 0
                    end
                    if not words_ok or common.u(dfhack.translation.translateName(ar.name))
                        ~= rec.rendered then
                        -- language tables differ: fall back to the literal name
                        for i = 0, 6 do ar.name.words[i] = -1 end
                        ar.name.first_name = common.fromu(rec.rendered)
                        common.add_skip(ctx, 'artifact-name-literalized', rec.rendered)
                    end
                    df.global.world.artifacts.all:insert('#', ar)
                    local ref = df.general_ref_is_artifactst:new()
                    ref.artifact_id = ar.id
                    item.general_refs:insert('#', ref)
                    item.flags.artifact = true
                else
                    common.add_skip(ctx, 'artifact-item-missing', rec.rendered)
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
