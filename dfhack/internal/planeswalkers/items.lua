-- Items + artifacts save/load for fort/planeswalkers.
--@module = true

local common = reqscript('internal/planeswalkers/common')

-- Corpses are not safely reconstructible as their original unit-linked body
-- objects across worlds. Preserve them as race-aware REMAINS where possible.
local CORPSE_TYPES = {
    [df.item_type.CORPSE] = 'CORPSE',
    [df.item_type.CORPSEPIECE] = 'CORPSEPIECE',
}

local function subtype_token(item)
    local st = item:getSubtype()
    if st < 0 then return nil end
    local ok, def = pcall(dfhack.items.getSubtypeDef, item:getType(), st)
    return ok and def and def.id or nil
end

-- how a building holds this item: 2 = construction component, 0 = stored/displayed
local function holder_use_mode(item, bld_id)
    local bld = df.building.find(bld_id)
    if bld and df.building_actual:is_instance(bld) then
        for _, ci in ipairs(bld.contained_items) do
            if ci.item == item then return ci.use_mode end
        end
    end
    return nil
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
    local corpse_kind = CORPSE_TYPES[itype]
    local stored_type = corpse_kind and 'REMAINS' or df.item_type[itype]
    if corpse_kind and not df.item_type.REMAINS then
        common.add_skip(ctx, 'corpse-remains-type-unavailable', corpse_kind)
        return nil
    end
    if item.flags.construction then return nil end
    if item.flags.garbage_collect then return nil end
    -- outside the saved footprint: carried only if a unit holds it (its
    -- position is the holder's on load); anything lying there stays behind
    local px, py = item.pos.x, item.pos.y
    if not common.in_footprint(ctx, px, py) then
        local held = false
        for _, ref in ipairs(item.general_refs) do
            if df.general_ref_unit_holderst:is_instance(ref) then held = true break end
        end
        if not held then
            common.add_skip(ctx, 'item-outside-footprint', df.item_type[itype])
            return nil
        end
        px, py = common.clamp_to_footprint(ctx, px, py)
    end
    local mi = dfhack.matinfo.decode(item)
    local o = ctx.origin
    local rec = {
        id = item.id,
        t = stored_type,
        corpse_original = corpse_kind,
        st = subtype_token(item),
        mat = mi and mi:getToken() or nil,
        x = px - o.x, y = py - o.y, z = item.pos.z,
    }
    if corpse_kind then
        -- Retain the original corpse linkage and a readable description even
        -- though the destination currently receives a REMAINS approximation.
        local oku, unit_id = pcall(function() return item.unit_id end)
        if oku and type(unit_id) == 'number' and unit_id >= 0 then rec.corpse_unit_id = unit_id end
        local okbp, body_part = pcall(function() return item.body_part_id end)
        if okbp and type(body_part) == 'number' and body_part >= 0 then rec.corpse_body_part = body_part end
        local okd, description = pcall(dfhack.items.getReadableDescription, item)
        if okd and description then rec.corpse_description = description end
    end
    local stack = item:getStackSize()
    if stack and stack > 1 then rec.n = stack end
    local q = item:getQuality()
    if q and q > 0 then rec.q = q end
    local okw, wear = pcall(function() return item.wear end)
    if okw and wear and wear > 0 then rec.wear = wear end
    -- who made it (an hf id; resolved on load if that figure came along)
    local okm, mk = pcall(function() return item.maker end)
    if okm and mk and mk >= 0 then rec.mk = mk end
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
        elseif df.general_ref_unit_itemownerst:is_instance(ref) then
            rec.owner = ref.unit_id  -- a dwarf's own clothes stay theirs
        elseif df.general_ref_unit_holderst:is_instance(ref) then
            rec.on_unit = ref.unit_id
            local holder = df.unit.find(ref.unit_id)
            if holder then
                for _, inv in ipairs(holder.inventory) do
                    if inv.item == item then
                        rec.mode = inv.mode
                        rec.bp = inv.body_part_id
                        break
                    end
                end
            end
        end
    end
    if item.flags.in_building then
        -- construction components (use_mode 2) are re-minted by the buildings
        -- module; items merely stored or DISPLAYED in a building (use_mode 0)
        -- -- artifacts on pedestals above all -- are cargo and must transfer
        local use = rec.in_bld and holder_use_mode(item, rec.in_bld)
        if use ~= 0 and not item.flags.artifact then return nil end
    end
    -- improvements (decorations): these ARE the item's description text
    local oki, imps = pcall(function() return item.improvements end)
    if oki and imps and #imps > 0 then
        rec.imp = {}
        for _, imp in ipairs(imps) do
            local imi = dfhack.matinfo.decode(imp.mat_type, imp.mat_index)
            local e = {
                -- (.+)st> not (%w+): several type names contain underscores
                t = tostring(imp._type):match('itemimprovement_(.+)st>') or 'generic',
                mat = imi and imi:getToken() or nil,
            }
            if imp.quality > 0 then e.q = imp.quality end
            if imp.skill_rating > 0 then e.sr = imp.skill_rating end
            if df.itemimprovement_art_imagest:is_instance(imp) then
                -- the picture itself, in tokens, so it can be redrawn there
                local okimg, img = pcall(reqscript('internal/planeswalkers/extras').image_out,
                                         imp.image.id, imp.image.subid)
                if okimg then e.img = img end
            end
            if df.itemimprovement_itemspecificst:is_instance(imp) then
                e.spec = imp.type
            elseif df.itemimprovement_threadst:is_instance(imp)
                and imp.dye.mat_type >= 0 then
                local dmi = dfhack.matinfo.decode(imp.dye.mat_type, imp.dye.mat_index)
                e.dye = dmi and dmi:getToken() or nil
                if imp.dye.quality > 0 then e.dq = imp.dye.quality end
            end
            table.insert(rec.imp, e)
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
                local it = vec[job.cursor]
                local ok, rec = true, nil
                if not ctx.select or ctx.select.items[it.id] then
                    ok, rec = pcall(save_one, ctx, it)
                end
                if ok and rec then table.insert(job.items.list, rec)
                elseif not ok then common.add_skip(ctx, 'item-save-error', tostring(rec)) end
                job.cursor = job.cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            common.write_json(ctx.dir .. '/items.json', job.items)
            -- Keep a dedicated, forward-compatible corpse ledger. The ordinary
            -- item records already preserve position, material, race/caste and
            -- original corpse type; this file makes those records discoverable
            -- for a future DFHack-native corpse constructor without changing
            -- the current remains fallback.
            local corpse_ledger = {v = 1, list = {}}
            for _, rec in ipairs(job.items.list) do
                if rec.corpse_original then
                    corpse_ledger.list[#corpse_ledger.list + 1] = {
                        id = rec.id, original_type = rec.corpse_original,
                        race = rec.race, caste = rec.caste,
                        source_unit_id = rec.corpse_unit_id,
                        body_part_id = rec.corpse_body_part,
                        description = rec.corpse_description,
                        mat = rec.mat, x = rec.x, y = rec.y, z = rec.z,
                        flags = rec.fl, stack = rec.n,
                    }
                end
            end
            common.write_json(ctx.dir .. '/corpses.json', corpse_ledger)
            ctx.manifest.counts.corpses = #corpse_ledger.list
            ctx.manifest.complete.corpses = true
            ctx.captured_items = {}
            for _, rec in ipairs(job.items.list) do ctx.captured_items[rec.id] = true end
            ctx.manifest.counts.items = #job.items.list
            ctx.manifest.complete.items = true
            return true
        end,
    }, {
        name = 'artifacts',
        step = function(job)
            local out = {v = 1, list = {}}
            -- only artifacts physically present in the fort; the rest of the
            -- old world's artifacts (and their holders) stay behind
            for _, ar in ipairs(df.global.world.artifacts.all) do
                if ar.item and (not ctx.captured_items
                                or ctx.captured_items[ar.item.id]) then
                    local words, pos = {}, {}
                    for i = 0, 6 do
                        words[i + 1] = ar.name.words[i]
                        pos[i + 1] = ar.name.parts_of_speech[i]
                    end
                    table.insert(out.list, {
                        id = ar.id,
                        item = ar.item.id,
                        -- true artifact vs merely-named object (kill-named sword)
                        mood = ar.item.flags.artifact_mood,
                        owner = ar.owner_hf >= 0 and ar.owner_hf or nil,
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

local creator_unit = common.creator_unit

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

-- improvement types whose payload is world-local (art images, written content)
-- cannot cross worlds; everything else is re-minted type+material+quality
local IMP_SKIP = {
    art_image = 'improvement-image-lost',
    sewn_image = 'improvement-image-lost',
    image_set = 'improvement-image-lost',
    writing = 'improvement-writing-lost',
    pages = 'improvement-writing-lost',
    generic = 'improvement-type-unknown',
}

local function restore_improvements(ctx, rec, item)
    if not rec.imp then return end
    local ok0, imps = pcall(function() return item.improvements end)
    if not ok0 or not imps then
        common.add_skip(ctx, 'improvements-unsupported-on-item', rec.t)
        return
    end
    for _, e in ipairs(rec.imp) do
        local skip = IMP_SKIP[e.t or 'generic']
        local cls = not skip and df['itemimprovement_' .. e.t .. 'st'] or nil
        local minfo = e.mat and dfhack.matinfo.find(e.mat) or nil
        if e.t == 'art_image' and e.img then
            -- redraw the image in this world, then decorate with it
            local extras = reqscript('internal/planeswalkers/extras')
            local okc, err = pcall(function()
                local chunk, subid = extras.image_in(ctx, e.img, rec.id, item)
                if not chunk then error(subid) end
                local imp = df.itemimprovement_art_imagest:new()
                imp.mat_type = minfo and minfo.type or -1
                imp.mat_index = minfo and minfo.index or -1
                imp.maker = -1
                imp.masterpiece_event = -1
                imp.quality = math.min(e.q or 0, 5)
                imp.skill_rating = e.sr or 0
                imp.image.id, imp.image.subid = chunk, subid
                imp.image.civ_id = df.global.plotinfo.civ_id
                imp.image.site_id = df.global.plotinfo.site_id
                imps:insert('#', imp)
            end)
            if not okc then common.add_skip(ctx, 'improvement-image-lost', tostring(err)) end
        elseif skip then
            common.add_skip(ctx, skip, rec.t)
        elseif not cls then
            common.add_skip(ctx, 'improvement-type-unknown', e.t)
        elseif e.mat and not minfo then
            common.add_skip(ctx, 'improvement-mat-missing', e.mat)
        else
            local okc = pcall(function()
                local imp = cls:new()
                imp.mat_type = minfo and minfo.type or -1
                imp.mat_index = minfo and minfo.index or -1
                imp.maker = -1
                imp.masterpiece_event = -1
                imp.quality = math.min(e.q or 0, 5)
                imp.skill_rating = e.sr or 0
                if e.spec and df.itemimprovement_itemspecificst:is_instance(imp) then
                    imp.type = e.spec
                end
                if df.itemimprovement_threadst:is_instance(imp) then
                    local dm = e.dye and dfhack.matinfo.find(e.dye) or nil
                    imp.dye.mat_type = dm and dm.type or -1
                    imp.dye.mat_index = dm and dm.index or -1
                    imp.dye.dyer = -1
                    imp.dye.quality = e.dq or 0
                end
                imps:insert('#', imp)
            end)
            if not okc then common.add_skip(ctx, 'improvement-restore-failed', e.t) end
        end
    end
end

-- DF adds items to plotinfo.equipment.items_unassigned only at natural
-- creation/pickup, and every assignment picker (military specific weapons,
-- pedestal/display-case items, ...) is built from those id vectors -- an
-- unregistered item can never be assigned to anything. Restored ids ascend,
-- so appending keeps each bucket sorted (DF binary-searches them).
local function register_item(item)
    pcall(function()
        df.global.plotinfo.equipment.items_unassigned[item:getType()]:insert('#', item.id)
    end)
end

local function create_one(ctx, rec, is_retry)
    local itype = df.item_type[rec.t]
    if not itype then
        common.add_skip(ctx, 'item-type-unknown', rec.t)
        return nil
    end
    local match = reqscript('internal/planeswalkers/match')
    local isub = -1
    if rec.st then
        isub = match.resolve_subtype(ctx, rec.t, rec.st)
        if isub == -1 then
            common.add_skip(ctx, 'item-subtype-missing', rec.t .. ':' .. rec.st)
            return nil
        end
    end
    local caste_material = false
    pcall(function() caste_material = dfhack.items.isCasteMaterial(itype) end)

    local mt, mx = 0, -1
    local minfo
    if rec.mat then
        minfo = match.resolve_mat_token(ctx, rec.mat)
        if minfo then
            mt, mx = minfo.type, minfo.index
        elseif not caste_material then
            common.add_skip(ctx, 'item-mat-missing', rec.mat)
            return nil
        end
    end

    -- Caste-material item types (REMAINS, FISH, FISH_RAW, EGG, etc.) do not
    -- take a material type/index in createItem(). They take a creature raw
    -- index and caste index. Passing a tissue material pair here can create
    -- an item whose derived material disagrees with its saved race/caste.
    local create_mt, create_mx = mt, mx
    local resolved_race, resolved_caste
    if caste_material then
        local material_race
        if minfo then
            pcall(function()
                if minfo.creature then material_race = minfo.creature.creature_id end
            end)
        end
        if material_race then
            resolved_race, resolved_caste = resolve_race(ctx, material_race, rec.caste)
        end
        if not resolved_race and rec.race then
            resolved_race, resolved_caste = resolve_race(ctx, rec.race, rec.caste)
        end
        if not resolved_race then
            common.add_skip(ctx, 'item-race-missing-in-world', rec.race or rec.mat or rec.t)
            return nil
        end
        create_mt, create_mx = resolved_race, resolved_caste or 0
    end

    -- no_floor=false: items created "in limbo" can never be moved to ground,
    -- containers, buildings, or inventories -- create at the creator's feet
    -- and move into place immediately after
    local items = dfhack.items.createItem(creator_unit(), itype, isub,
                                          create_mt, create_mx, false)
    local item = items and items[1]
    if type(item) == 'table' then item = item[1] end
    if not item and itype == df.item_type.SEEDS
        and not (ctx.type_ok_mat and ctx.type_ok_mat[itype]) then
        -- createItem refuses many seed materials; probe the dest's plants for
        -- one it accepts so the overwrite fallback below has a base
        for _, plant in ipairs(df.global.world.raws.plants.all) do
            local pm = dfhack.matinfo.find('PLANT:' .. plant.id .. ':SEED')
            if pm then
                local probe = dfhack.items.createItem(creator_unit(), itype, -1,
                                                      pm.type, pm.index, false)
                local pi = probe and probe[1]
                if type(pi) == 'table' then pi = pi[1] end
                if pi then
                    dfhack.items.remove(pi)
                    ctx.type_ok_mat = ctx.type_ok_mat or {}
                    ctx.type_ok_mat[itype] = {pm.type, pm.index}
                    break
                end
            end
        end
    end
    if not item and not caste_material and ctx.type_ok_mat and ctx.type_ok_mat[itype] then
        -- createItem refuses some valid materials (e.g. surface-plant seeds):
        -- create with a known-good material for the type, then overwrite
        local fb = ctx.type_ok_mat[itype]
        items = dfhack.items.createItem(creator_unit(), itype, isub, fb[1], fb[2], false)
        item = items and items[1]
        if type(item) == 'table' then item = item[1] end
        if item then
            local okm = pcall(function()
                item.mat_type = mt
                item.mat_index = mx
            end)
            if not okm then common.add_skip(ctx, 'item-mat-overwrite-failed', rec.t) end
        end
    end
    if not item then
        if not is_retry then return nil, 'retry' end
        common.add_skip(ctx, 'item-create-failed', rec.t)
        return nil
    end
    common.unproject(item)
    -- Keep destination-world expectations. Material substitutions are allowed
    -- by match.resolve_mat_token(), so the audit must compare against the
    -- resolved token rather than the origin world's token in rec.mat.
    if rec.mat or caste_material then
        ctx.item_expected_material = ctx.item_expected_material or {}
        local expected = {
            type = minfo and minfo.type or nil,
            index = minfo and minfo.index or nil,
            token = nil,
            caste_material = caste_material,
            race = resolved_race,
            caste = resolved_caste,
            source_record_id = rec.id,
            snapshot_type = rec.t,
            snapshot_subtype = rec.st,
            source_material = rec.mat,
        }
        if minfo then
            local okt, token = pcall(function() return minfo:getToken() end)
            if okt then expected.token = token end
        end
        -- A substituted creature may not have the same tissue (e.g. shell,
        -- bone, or cartilage) as the origin creature. In that case the
        -- destination race/caste is the achievable equivalent; do not compare
        -- its derived tissue against the unrelated fallback material chosen by
        -- resolve_mat_token(). Exact material matches remain fully audited.
        if caste_material and (expected.token ~= rec.mat or rec.corpse_original) then
            -- CORPSE/CORPSEPIECE records are restored as REMAINS. REMAINS
            -- derives its displayed tissue from the destination creature/caste
            -- (often BONE), and cannot reliably preserve the source corpse
            -- piece's tissue (for example POND_TURTLE:SHELL). For these
            -- approximations, race/caste is the meaningful identity to audit;
            -- requiring the source tissue makes every such restore abort.
            expected.type, expected.index = nil, nil
        end
        ctx.item_expected_material[item.id] = expected
    end
    ctx.items_restored = (ctx.items_restored or 0) + 1
    if rec.corpse_original then
        ctx.corpses_approximated = (ctx.corpses_approximated or 0) + 1
        common.add_skip(ctx, 'corpse-approximated-as-remains', rec.corpse_original)
    end
    if not caste_material then
        ctx.type_ok_mat = ctx.type_ok_mat or {}
        if not ctx.type_ok_mat[itype] then ctx.type_ok_mat[itype] = {mt, mx} end
    end
    if caste_material then
        -- Reassert the same creature/caste used to construct the item.
        pcall(function()
            item.race = resolved_race
            item.caste = resolved_caste or 0
        end)
    elseif rec.race then
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
    -- createItem stamps the creator unit as maker, which reads as a wrong
    -- dwarf in descriptions: put the real maker back if they came along,
    -- else "an unknown artist"
    local okmk = pcall(function() return item.maker end)
    if okmk then
        local hf = rec.mk and ctx.hf_map and ctx.hf_map[rec.mk]
        pcall(function() item.maker = hf and hf.id or -1 end)
    end
    register_item(item)
    if rec.hand then pcall(function() item:setGloveHandedness(rec.hand) end) end
    if rec.fl then
        local f = item.flags
        f.forbid = rec.fl & 1 == 1
        f.dump = rec.fl & 2 == 2
        f.melt = rec.fl & 4 == 4
        f.hidden = rec.fl & 8 == 8
        f.rotten = rec.fl & 16 == 16
    end
    restore_improvements(ctx, rec, item)
    return item
end

-- Capture material state without changing the item. These snapshots make it
-- possible to distinguish a bad constructor from a placement/registration
-- side effect, while leaving the existing verification behavior untouched.
local function safe_item_state(item)
    local state = {id = item and item.id or -1}
    local ok_type, item_type = pcall(function() return item:getType() end)
    if ok_type then
        state.item_type_id = tonumber(item_type) or tostring(item_type)
        local ok_name, enum_name = pcall(function() return df.item_type[item_type] end)
        state.item_type = tostring((ok_name and enum_name) or item_type)
    else
        state.item_type = 'unknown'
    end
    local ok_sub, subtype = pcall(function() return item:getSubtype() end)
    if ok_sub then state.subtype_id = tonumber(subtype) or tostring(subtype) end
    local ok_fields, mat_type, mat_index = pcall(function()
        return item.mat_type, item.mat_index
    end)
    state.fields_available = ok_fields and mat_type ~= nil and mat_index ~= nil
    if state.fields_available then
        state.mat_type = tonumber(mat_type) or tostring(mat_type)
        state.mat_index = tonumber(mat_index) or tostring(mat_index)
    elseif not ok_fields then
        state.fields_error = tostring(mat_type)
    end
    local ok_decode, mi = pcall(dfhack.matinfo.decode, item)
    if ok_decode and mi then
        local ok_pair, mt, mx = pcall(function() return mi.type, mi.index end)
        if ok_pair then
            state.decoded_type, state.decoded_index = tonumber(mt) or tostring(mt), tonumber(mx) or tostring(mx)
        end
        local ok_token, token = pcall(function() return mi:getToken() end)
        if ok_token then state.decoded_token = token end
    elseif not ok_decode then
        state.decode_error = tostring(mi)
    end
    local ok_race, race = pcall(function() return item.race end)
    local ok_caste, caste = pcall(function() return item.caste end)
    if ok_race then state.race = tonumber(race) or tostring(race) end
    if ok_caste then state.caste = tonumber(caste) or tostring(caste) end
    local ok_pos, x, y, z = pcall(function() return item.pos.x, item.pos.y, item.pos.z end)
    if ok_pos then
        state.x, state.y, state.z = tonumber(x) or tostring(x), tonumber(y) or tostring(y), tonumber(z) or tostring(z)
    end
    local ok_stack, stack = pcall(function() return item:getStackSize() end)
    if ok_stack then state.stack = tonumber(stack) or tostring(stack) end
    local ok_desc, desc = pcall(dfhack.items.getReadableDescription, item)
    if ok_desc and desc then
        local ok_utf, utf_desc = pcall(common.u, desc)
        if ok_utf then state.description = utf_desc end
    end
    return state
end

local function item_audit_reasons(expected, actual)
    local reasons, info = {}, {}
    if expected.caste_material then
        if actual.race ~= expected.race then reasons[#reasons + 1] = 'creature_mismatch' end
        if actual.caste ~= expected.caste then reasons[#reasons + 1] = 'caste_mismatch' end
        if expected.type ~= nil then
            if actual.decoded_type == nil then
                info[#info + 1] = 'decoded_material_unavailable'
            elseif actual.decoded_type ~= expected.type or actual.decoded_index ~= expected.index then
                reasons[#reasons + 1] = 'decoded_material_mismatch'
            end
        end
    else
        if actual.fields_available then
            if actual.mat_type ~= expected.type or actual.mat_index ~= expected.index then
                reasons[#reasons + 1] = 'material_fields_mismatch'
            end
        else
            info[#info + 1] = 'generic_material_fields_unavailable'
        end
        if actual.decoded_type == nil then
            info[#info + 1] = 'decoded_material_unavailable'
        elseif actual.decoded_type ~= expected.type or actual.decoded_index ~= expected.index then
            reasons[#reasons + 1] = 'decoded_material_mismatch'
        end
    end
    return reasons, info
end

local function record_item_material_audit(ctx, item, stage_name)
    local expected = ctx.item_expected_material and ctx.item_expected_material[item.id]
    if not expected then return end
    local audit = ctx.item_audit or {stages = {}}
    ctx.item_audit = audit
    audit.stages = audit.stages or {}
    local stage = audit.stages[stage_name] or {
        checked = 0, mismatched = 0, by_type = {}, by_reason = {}, examples = {},
        info = {},
    }
    audit.stages[stage_name] = stage
    local actual = safe_item_state(item)
    local reasons, info = item_audit_reasons(expected, actual)
    local type_name = actual.item_type or tostring(expected.snapshot_type or 'unknown')
    local type_group = stage.by_type[type_name] or {checked = 0, mismatched = 0, by_reason = {}, examples = {}}
    stage.by_type[type_name] = type_group
    stage.checked = stage.checked + 1
    type_group.checked = type_group.checked + 1
    for _, reason in ipairs(info) do stage.info[reason] = (stage.info[reason] or 0) + 1 end
    if #reasons > 0 then
        stage.mismatched = stage.mismatched + 1
        type_group.mismatched = type_group.mismatched + 1
    end
    local sample = {
        id = actual.id, source_record_id = expected.source_record_id,
        item_type = type_name, subtype_id = actual.subtype_id,
        description = actual.description, stage = stage_name,
        expected = {token = expected.token, type = expected.type, index = expected.index,
                    caste_material = expected.caste_material, race = expected.race,
                    caste = expected.caste, source_material = expected.source_material,
                    snapshot_type = expected.snapshot_type, snapshot_subtype = expected.snapshot_subtype},
        actual = actual, reasons = reasons, info = info,
    }
    if #reasons > 0 then
        for _, reason in ipairs(reasons) do
            stage.by_reason[reason] = stage.by_reason[reason] or {n = 0, examples = {}}
            local bucket = stage.by_reason[reason]
            bucket.n = bucket.n + 1
            if #bucket.examples < 10 then bucket.examples[#bucket.examples + 1] = sample end
            type_group.by_reason[reason] = (type_group.by_reason[reason] or 0) + 1
        end
        if #stage.examples < 60 then stage.examples[#stage.examples + 1] = sample end
        if #type_group.examples < 8 then type_group.examples[#type_group.examples + 1] = sample end
    end
end

local function safe_record_item_material_audit(ctx, item, stage_name)
    local ok, err = pcall(record_item_material_audit, ctx, item, stage_name)
    if not ok then
        ctx.item_audit_capture_errors = (ctx.item_audit_capture_errors or 0) + 1
        ctx.item_audit_capture_error = tostring(err)
    end
end

local function verify_item_material(ctx, item)
    local expected = ctx.item_expected_material and ctx.item_expected_material[item.id]
    if not expected then return true end

    local function decoded_material()
        local ok, mi = pcall(dfhack.matinfo.decode, item)
        if not ok or not mi then return nil end
        local okv, mt, mx = pcall(function() return mi.type, mi.index end)
        if not okv then return nil end
        local okt, token = pcall(function() return mi:getToken() end)
        return {type = mt, index = mx, token = okt and token or nil}
    end

    local actual = decoded_material()
    if expected.caste_material then
        -- These item types are defined by a creature/caste pair, not by the
        -- generic mat_type/mat_index fields. Verify that identity first.
        local okr, race = pcall(function() return item.race end)
        local okc, caste = pcall(function() return item.caste end)
        local race_matches = okr and race == expected.race
        local caste_matches = okc and caste == expected.caste
        if not race_matches or not caste_matches then
            local okset = pcall(function()
                item.race = expected.race
                item.caste = expected.caste
            end)
            if okset then
                okr, race = pcall(function() return item.race end)
                okc, caste = pcall(function() return item.caste end)
                race_matches = okr and race == expected.race
                caste_matches = okc and caste == expected.caste
                actual = decoded_material()
            end
        end
        if not race_matches or not caste_matches then
            common.add_skip(ctx, 'item-material-verify-failed',
                ('item %d expected creature/caste %s/%s, got %s/%s'):format(
                    item.id, tostring(expected.race), tostring(expected.caste),
                    tostring(race), tostring(caste)))
            return false
        end
    else
        -- For ordinary material-bearing items, the DF material code pair is
        -- authoritative. Token strings can be normalized differently by DF,
        -- so compare the numeric pair instead of the origin token text.
        local ok_fields, mat_type, mat_index = pcall(function()
            return item.mat_type, item.mat_index
        end)
        local fields_available = ok_fields and mat_type ~= nil and mat_index ~= nil
        local fields_match = not fields_available
            or (mat_type == expected.type and mat_index == expected.index)
        local decoded_match = not actual or (actual.type == expected.type
            and actual.index == expected.index)

        if not fields_match or not decoded_match then
            local okset = false
            if fields_available then
                okset = pcall(function()
                    item.mat_type = expected.type
                    item.mat_index = expected.index
                end)
            end
            if okset then
                ok_fields, mat_type, mat_index = pcall(function()
                    return item.mat_type, item.mat_index
                end)
                fields_available = ok_fields and mat_type ~= nil and mat_index ~= nil
                fields_match = not fields_available
                    or (mat_type == expected.type and mat_index == expected.index)
                actual = decoded_material()
                decoded_match = not actual or (actual.type == expected.type
                    and actual.index == expected.index)
            end
        end

        if not fields_match or not decoded_match then
            common.add_skip(ctx, 'item-material-verify-failed',
                ('item %d expected %s [%s:%s], got %s [%s:%s]'):format(
                    item.id, expected.token or '?', tostring(expected.type),
                    tostring(expected.index), actual and (actual.token or '?') or 'unresolved',
                    tostring(actual and actual.type), tostring(actual and actual.index)))
            return false
        end
    end

    -- Caste-material items may also expose a decodable tissue material. Check
    -- it only when a destination equivalent was resolved; race/caste remains
    -- the primary constructor contract for these item types.
    if expected.caste_material and expected.type ~= nil and actual
        and (actual.type ~= expected.type or actual.index ~= expected.index) then
        common.add_skip(ctx, 'item-material-verify-failed',
            ('item %d expected %s [%s:%s], got %s [%s:%s]'):format(
                item.id, expected.token or '?', tostring(expected.type),
                tostring(expected.index), actual.token or '?', tostring(actual.type),
                tostring(actual.index)))
        return false
    end
    return true
end

local function place_one(ctx, rec, item)
    local a = ctx.anchor
    if rec.in_item then
        local container = ctx.item_map[rec.in_item]
        if container and dfhack.items.moveToContainer(item, container) then return end
    elseif rec.in_bld then
        local bld = ctx.bld_map and ctx.bld_map[rec.in_bld]
        if bld and dfhack.items.moveToBuilding(item, bld, 0) then
            -- items on pedestals/display cases are also listed by id
            if df.building_display_furniturest:is_instance(bld) then
                bld.displayed_items:insert('#', item.id)
            end
            return
        end
    elseif rec.on_unit then
        local u = ctx.unit_map and ctx.unit_map[rec.on_unit]
        if u and dfhack.items.moveToInventory(item, u, rec.mode or 0, rec.bp or -1) then
            -- the item was minted at the creator's feet; a held item whose
            -- position is not its wearer's is shed by DF on the next load
            -- (half a fort's clothing ended up in one heap that way)
            item.pos.x, item.pos.y, item.pos.z = u.pos.x, u.pos.y, u.pos.z
            ctx.held_attached = (ctx.held_attached or 0) + 1
            return
        end
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
                local ok, item, why = pcall(create_one, ctx, rec, job.retrying)
                if ok and item then
                    ctx.item_map[rec.id] = item
                    safe_record_item_material_audit(ctx, item, 'after_creation')
                    local okp, err = pcall(place_one, ctx, rec, item)
                    if not okp then
                        common.add_skip(ctx, 'item-place-error', tostring(err))
                    end
                    safe_record_item_material_audit(ctx, item, 'after_placement_before_repin')
                    -- Existing behavior retained for this diagnostic revision.
                    -- The report captures the item before this re-pin can mask
                    -- a constructor or placement mismatch.
                    verify_item_material(ctx, item)
                    safe_record_item_material_audit(ctx, item, 'after_placement_repin')
                    if rec.owner then
                        local owner = ctx.unit_map and ctx.unit_map[rec.owner]
                        if owner then
                            pcall(function()
                                local ref = df.general_ref_unit_itemownerst:new()
                                ref.unit_id = owner.id
                                item.general_refs:insert('#', ref)
                                item.flags.owned = true
                                owner.owned_items:insert('#', item.id)
                                ctx.owned_restored = (ctx.owned_restored or 0) + 1
                            end)
                        end
                    end
                elseif ok and why == 'retry' then
                    job.retry = job.retry or {}
                    table.insert(job.retry, rec)
                elseif not ok then
                    common.add_skip(ctx, 'item-load-error', tostring(item))
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            -- second chance for items whose material createItem refused: by now
            -- a known-good material per type is usually on record
            if not job.retrying and job.retry and #job.retry > 0 then
                job.ordered = job.retry
                job.retry = nil
                job.cursor = 1
                job.retrying = true
                return false
            end
            -- have DF re-validate its assignment registries now that they
            -- contain every restored item
            local upd = df.global.plotinfo.equipment.update
            for k in pairs(upd) do pcall(function() upd[k] = true end) end
            -- Final audit after every restored item is registered. This catches
            -- a material being changed by later placement/registration work,
            -- rather than only checking immediately after createItem().
            local final_checked, final_failed = 0, 0
            -- item_expected_material is keyed by the newly allocated destination
            -- item ID. item_map is keyed by the origin snapshot ID, so using the
            -- expected-material key to index item_map silently skipped almost
            -- every item whose destination ID differed from its origin ID.
            -- Walk the restored destination objects instead.
            local audited_ids = {}
            for _, item in pairs(ctx.item_map) do
                if item and not audited_ids[item.id]
                    and ctx.item_expected_material and ctx.item_expected_material[item.id] then
                    audited_ids[item.id] = true
                    safe_record_item_material_audit(ctx, item, 'after_registry_update_before_final_check')
                    if not verify_item_material(ctx, item) then
                        final_failed = final_failed + 1
                    end
                    safe_record_item_material_audit(ctx, item, 'after_final_check')
                    final_checked = final_checked + 1
                end
            end
            ctx.item_audit = ctx.item_audit or {stages = {}}
            ctx.item_audit.final_checked = final_checked
            ctx.item_audit.final_unresolved = final_failed
            ctx.item_audit.capture_errors = ctx.item_audit_capture_errors or 0
            ctx.item_audit.capture_error = ctx.item_audit_capture_error
            print(('planeswalkers: item material audit: %d restored item(s) checked, %d unresolved')
                :format(final_checked, final_failed))
            if final_failed > 0 then
                qerror(('planeswalkers: item material audit found %d unresolved item(s); restore stopped rather than leaving known incorrect item materials')
                    :format(final_failed))
            end
            local held = 0
            for _, u in ipairs(df.global.world.units.active) do held = held + #u.inventory end
            print(('planeswalkers: items: %d attached to units (%d held now across the map), %d ownerships restored')
                :format(ctx.held_attached or 0, held, ctx.owned_restored or 0))
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
            local attached = 0
            local function attach_one(rec)
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
                        ar.name.first_name = common.fromu('foreign artifact')
                        common.add_skip(ctx, 'artifact-name-foreignized', rec.rendered)
                    end
                    -- whereabouts: new() zero-inits these, which would point
                    -- at site 0 / hf 0 -- mark all unknown, then place the
                    -- artifact at THIS site so the Objects screen and legends
                    -- see it before DF's own tracker catches up
                    ar.site = df.global.plotinfo.site_id
                    ar.structure_local, ar.subregion, ar.feature_layer = -1, -1, -1
                    ar.last_local_bld_id, ar.site_building_profile = -1, -1
                    ar.storage_site, ar.storage_structure_local = -1, -1
                    ar.loss_region, ar.last_layer, ar.holder_hf = -1, -1, -1
                    ar.year, ar.season_tick = -1, -1
                    ar.abs_tile_x, ar.abs_tile_y, ar.abs_tile_z =
                        -1000000, -1000000, -1000000
                    local owner = rec.owner and ctx.hf_map and ctx.hf_map[rec.owner]
                    ar.owner_hf = owner and owner.id or -1
                    df.global.world.artifacts.all:insert('#', ar)
                    local ref = df.general_ref_is_artifactst:new()
                    ref.artifact_id = ar.id
                    item.general_refs:insert('#', ref)
                    item.flags.artifact = true
                    -- artifact_mood is what makes DF treat it as a true
                    -- artifact: the 10x value multiplier over masterwork and
                    -- the Objects->Artifacts listing (absent in old snapshots
                    -- -> assume true; explicit false = kill-named object)
                    item.flags.artifact_mood = rec.mood ~= false
                    attached = attached + 1
                else
                    common.add_skip(ctx, 'artifact-item-missing', rec.rendered)
                end
            end
            while job.cursor <= #job.arts.list do
                local rec = job.arts.list[job.cursor]
                job.cursor = job.cursor + 1
                -- one malformed record must not abort the whole restore
                local ok, err = pcall(attach_one, rec)
                if not ok then
                    common.add_skip(ctx, 'artifact-attach-error', tostring(err))
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.artifacts_restored = attached
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
