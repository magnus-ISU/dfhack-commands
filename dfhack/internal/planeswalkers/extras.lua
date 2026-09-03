-- The finer state of a fort, for fort/planeswalkers: who owns which room,
-- which zone is which guildhall or temple, who holds which noble position,
-- what each dwarf has killed, and the images engraved on artifacts.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local match = reqscript('internal/planeswalkers/match')
local units = reqscript('internal/planeswalkers/units')

-- ---- names (language_name in/out, shared with units) ------------------------

function name_out(name) return units.name_out_pub(name) end
function name_in(dst, rec, ctx) return units.name_in_pub(dst, rec, ctx) end

-- ---- kills ------------------------------------------------------------------

local function race_tokens(race, caste)
    if not race or race < 0 or race >= #df.global.world.raws.creatures.all then return nil end
    local craw = df.global.world.raws.creatures.all[race]
    local ct = caste and caste >= 0 and craw.caste[caste] and craw.caste[caste].caste_id or nil
    return craw.creature_id, ct, craw.flags.GENERATED and true or false,
           match.adult_size(craw, caste)
end

-- {r=race token, c=caste, g=generated, s=size, u=undead bits, n=count}, one
-- per species killed. Specific historical-figure kills stay behind (events
-- are world-local), the species tallies are what the kill list shows anyway.
function kills_out(hf)
    local ok, k = pcall(function() return hf.info.kills end)
    if not ok or not k or #k.killed_race == 0 then return nil end
    local out = {}
    for i = 0, #k.killed_race - 1 do
        local rt, ct, gen, sz = race_tokens(k.killed_race[i], k.killed_caste[i])
        if rt then
            table.insert(out, {
                r = rt, c = ct, g = gen or nil, s = sz,
                u = k.killed_undead[i] and k.killed_undead[i].whole or 0,
                n = k.killed_count[i],
            })
        end
    end
    return #out > 0 and out or nil
end

local function resolve_kill_race(ctx, rec)
    local r, c = units.resolve_race(ctx, rec.r, rec.c)
    if r then return r, c or 0 end
    if rec.g then
        local gi = match.match_generated(ctx, rec.r, rec.s)
        if gi then return gi, 0 end
    end
    return nil
end

function kills_in(ctx, hf, recs)
    if not recs or #recs == 0 then return 0 end
    local n = 0
    local ok, err = pcall(function()
        if not hf.info then hf.info = df.historical_figure_info:new() end
        if not hf.info.kills then hf.info.kills = df.historical_kills:new() end
        local k = hf.info.kills
        for _, rec in ipairs(recs) do
            local r, c = resolve_kill_race(ctx, rec)
            if r then
                k.killed_race:insert('#', r)
                k.killed_caste:insert('#', c)
                k.killed_underground_region:insert('#', -1)
                k.killed_region:insert('#', -1)
                k.killed_site:insert('#', -1)
                -- a vector of bitfields takes no insert; grow it and set the bits
                k.killed_undead:resize(#k.killed_undead + 1)
                k.killed_undead[#k.killed_undead - 1].whole = rec.u or 0
                k.killed_count:insert('#', rec.n or 1)
                n = n + 1
            else
                common.add_skip(ctx, 'kill-species-missing-in-world', rec.r)
            end
        end
    end)
    if not ok then common.add_skip(ctx, 'kills-restore-failed', tostring(err)) end
    return n
end

-- ---- noble positions ----------------------------------------------------------

local function fort_entities()
    local out = {}
    local site = df.historical_entity.find(df.global.plotinfo.group_id)
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    if site then out.site = site end
    if civ then out.civ = civ end
    return out
end

local function position_code(ent, position_id)
    for _, p in ipairs(ent.positions.own) do
        if p.id == position_id then return p.code end
    end
end

-- every position held by a figure of this fort, on the site government and
-- on the civilisation: {ent='site'|'civ', code='MAYOR', hf=<old hf id>}
function positions_out(hf_set)
    local out = {}
    for which, ent in pairs(fort_entities()) do
        for _, a in ipairs(ent.positions.assignments) do
            if a.histfig >= 0 and hf_set[a.histfig] then
                local code = position_code(ent, a.position_id)
                if code then
                    table.insert(out, {ent = which, code = code, hf = a.histfig})
                end
            end
        end
    end
    return out
end

function positions_phase(ctx)
    return {
        name = 'noble positions',
        step = function(job)
            local data = common.read_json(ctx.dir .. '/positions.json')
            if not data then return true end
            local ents = fort_entities()
            local n = 0
            for _, rec in ipairs(data.list or {}) do
                local hf = ctx.hf_map and ctx.hf_map[rec.hf]
                local ent = ents[rec.ent]
                if hf and ent then
                    local pos_id
                    for _, p in ipairs(ent.positions.own) do
                        if p.code == rec.code then pos_id = p.id break end
                    end
                    local slot
                    if pos_id then
                        for _, a in ipairs(ent.positions.assignments) do
                            if a.position_id == pos_id and (a.histfig < 0 or not slot) then
                                slot = a
                                if a.histfig < 0 then break end
                            end
                        end
                    end
                    if slot then
                        local ok, err = pcall(function()
                            slot.histfig = hf.id
                            local l = df.histfig_entity_link_positionst:new()
                            l.entity_id = ent.id
                            l.link_strength = 100
                            l.assignment_id = slot.id
                            l.start_year = df.global.cur_year
                            hf.entity_links:insert('#', l)
                        end)
                        if ok then n = n + 1
                        else common.add_skip(ctx, 'position-assign-failed', tostring(err)) end
                    else
                        common.add_skip(ctx, 'position-missing-in-world', rec.ent .. ':' .. rec.code)
                    end
                elseif not hf then
                    common.add_skip(ctx, 'position-holder-not-restored', rec.code)
                end
            end
            ctx.positions_restored = n
            if n > 0 then print(('planeswalkers: %d noble/administrator position(s) reassigned'):format(n)) end
            return true
        end,
    }
end

-- ---- zone owners, locations, door locks ---------------------------------------

local function location_out(bld)
    if bld.location_id < 0 or bld.site_id ~= df.global.plotinfo.site_id then return nil end
    local site = df.world_site.find(bld.site_id)
    if not site then return nil end
    for _, ab in ipairs(site.buildings) do
        if ab.id == bld.location_id then
            local kind = tostring(ab._type):match('abstract_building_(.+)st>')
            local rec = {id = ab.id, kind = kind}
            pcall(function() rec.name = name_out(ab.name) end)
            pcall(function() rec.prof = df.profession[ab.contents.profession] end)
            pcall(function() rec.deity_type = df.religious_practice_type[ab.deity_type] end)
            return rec
        end
    end
end

-- extra fields on a Civzone record at save time
function zone_out(bld, rec)
    if bld.assigned_unit_id >= 0 then rec.owner = bld.assigned_unit_id end
    if #bld.assigned_units > 0 then
        rec.owners = {}
        for _, id in ipairs(bld.assigned_units) do table.insert(rec.owners, id) end
    end
    rec.loc = location_out(bld)
end

local function create_location(ctx, loc)
    local site = df.world_site.find(df.global.plotinfo.site_id)
    if not site then return nil, 'no site' end
    local cls = df['abstract_building_' .. loc.kind .. 'st']
    if not cls then return nil, 'unknown location kind ' .. tostring(loc.kind) end
    local ab = cls:new()
    ab.id = site.next_building_id
    site.next_building_id = ab.id + 1
    ab.site_id = site.id
    ab.site_owner_id = df.global.plotinfo.group_id
    ab.parent_building_id = -1
    local template = #site.buildings > 0 and site.buildings[0] or nil
    if template then
        ab.pos.x, ab.pos.y = template.pos.x, template.pos.y
        pcall(function() ab.flags:resize(#template.flags) end)
    else
        pcall(function() ab.flags:resize(8) end)
    end
    pcall(function() if loc.name then name_in(ab.name, loc.name, ctx) end end)
    pcall(function()
        if loc.prof and df.profession[loc.prof] then ab.contents.profession = df.profession[loc.prof] end
    end)
    pcall(function()
        -- a temple's deity is a figure of the old world: dedicate to none
        ab.deity_type = -1
        ab.deity_data.practice_id = -1
    end)
    site.buildings:insert('#', ab)
    return ab
end

function owners_phase(ctx)
    return {
        name = 'room owners, locations, door locks',
        step = function(job)
            local blds = common.read_json(ctx.dir .. '/buildings.json') or {list = {}}
            local owners, locs, locks = 0, 0, 0
            ctx.loc_map = {}
            for _, rec in ipairs(blds.list) do
                local bld = ctx.bld_map and ctx.bld_map[rec.id]
                if bld then
                    if rec.type == 'Civzone' then
                        local changed = false
                        if rec.owner then
                            local u = ctx.unit_map and ctx.unit_map[rec.owner]
                            if u then
                                bld.assigned_unit_id = u.id
                                owners = owners + 1
                                changed = true
                            else
                                common.add_skip(ctx, 'room-owner-not-restored', rec.subtype_name)
                            end
                        end
                        for _, oid in ipairs(rec.owners or {}) do
                            local u = ctx.unit_map and ctx.unit_map[oid]
                            if u then bld.assigned_units:insert('#', u.id); changed = true end
                        end
                        if rec.loc then
                            local ab = ctx.loc_map[rec.loc.id]
                            if ab == nil then
                                local okc, res, err = pcall(create_location, ctx, rec.loc)
                                ab = okc and res or false
                                if not ab then
                                    common.add_skip(ctx, 'location-create-failed',
                                                    tostring(okc and err or res))
                                else
                                    locs = locs + 1
                                end
                                ctx.loc_map[rec.loc.id] = ab
                            end
                            if ab then
                                bld.location_id = ab.id
                                bld.site_id = ab.site_id
                                changed = true
                            end
                        end
                        if changed then
                            pcall(function() dfhack.buildings.notifyCivzoneModified(bld) end)
                        end
                    elseif rec.type == 'Door' and rec.door_flags then
                        pcall(function() bld.door_flags.whole = rec.door_flags end)
                        locks = locks + 1
                    elseif rec.type == 'Hatch' and rec.hatch_flags then
                        pcall(function() bld.hatch_flags.whole = rec.hatch_flags end)
                        locks = locks + 1
                    end
                end
            end
            print(('planeswalkers: %d room owner(s), %d location(s) (guildhalls/temples/...), ' ..
                   '%d door/hatch state(s) restored'):format(owners, locs, locks))
            ctx.owners_report = {owners = owners, locs = locs}
            return true
        end,
    }
end

-- ---- art images ---------------------------------------------------------------

local function find_image(chunk_id, subid)
    for _, ch in ipairs(df.global.world.art_image_chunks.all) do
        if ch.id == chunk_id then
            local m = ch.images[subid]
            return m and m.art_image or nil
        end
    end
end

local function shape_token(idx)
    local s = df.global.world.raws.descriptors.shapes[idx]
    return s and s.id or nil
end

-- serialise an engraved/decorative image: what is depicted, in tokens
function image_out(chunk_id, subid)
    local im = find_image(chunk_id, subid)
    if not im then return nil end
    local out = {elements = {}, properties = {}, q = im.quality}
    pcall(function() out.name = name_out(im.name) end)
    pcall(function()
        local mi = dfhack.matinfo.decode(im.mat_type, im.mat_index)
        out.mat = mi and mi:getToken() or nil
    end)
    for _, el in ipairs(im.elements) do
        local e = {n = el.count}
        if df.art_image_element_creaturest:is_instance(el) then
            e.k = 'creature'
            e.r, e.c, e.g, e.s = race_tokens(el.race, el.caste)
        elseif df.art_image_element_itemst:is_instance(el) then
            e.k = 'item'
            e.t = df.item_type[el.item_type]
            if el.item_type >= 0 and el.item_subtype >= 0 then
                local ok, def = pcall(dfhack.items.getSubtypeDef, el.item_type, el.item_subtype)
                e.st = ok and def and def.id or nil
            end
            local mi = dfhack.matinfo.decode(el.mat_type, el.mat_index)
            e.mat = mi and mi:getToken() or nil
        elseif df.art_image_element_plantst:is_instance(el) then
            e.k = 'plant'
            local pr = df.plant_raw.find(el.plant_id)
            e.p = pr and pr.id or nil
        elseif df.art_image_element_treest:is_instance(el) then
            e.k = 'tree'
            local pr = df.plant_raw.find(el.plant_id)
            e.p = pr and pr.id or nil
        elseif df.art_image_element_shapest:is_instance(el) then
            e.k = 'shape'
            e.sh = shape_token(el.shape_id)
            e.adj = el.shape_adj
        else
            e.k = 'unknown'
        end
        table.insert(out.elements, e)
    end
    for _, pr in ipairs(im.properties) do
        if df.art_image_property_transitive_verbst:is_instance(pr) then
            table.insert(out.properties, {k = 'trans', s = pr.subject, o = pr.object,
                                          v = df.art_image_property_verb[pr.verb]})
        elseif df.art_image_property_intransitive_verbst:is_instance(pr) then
            table.insert(out.properties, {k = 'intrans', s = pr.subject,
                                          v = df.art_image_property_verb[pr.verb]})
        end
    end
    return out
end

-- DF hands out image slots from world.worldgen's running chunk id/offset
-- (500 images per chunk, one file each); a chunk that does not exist yet is
-- created the way DF would on its first image
local function free_image_slot()
    local chunks = df.global.world.art_image_chunks.all
    local wg = df.global.world.worldgen
    local id, off = wg.next_art_image_chunk_id, wg.next_art_image_chunk_offset
    if off >= 500 then id, off = id + 1, 0 end
    local ch
    for _, c in ipairs(chunks) do
        if c.id == id then ch = c break end
    end
    if not ch then
        ch = df.art_image_chunk:new()
        ch.id = id
        chunks:insert('#', ch)
    end
    -- the slot DF would use next; if something sits there, take the first free one
    local slot = off
    if ch.images[slot].art_image ~= nil then
        slot = nil
        for s = 0, 499 do
            if ch.images[s].art_image == nil then slot = s break end
        end
        if not slot then return nil end
    end
    wg.next_art_image_chunk_id = id
    wg.next_art_image_chunk_offset = slot + 1
    return ch, slot
end

-- rebuild an image in this world; returns chunk id, subid (or nil + reason).
-- Elements naming a figure of the old world become a generic creature of
-- that race; anything the world cannot name is dropped and reported.
function image_in(ctx, rec)
    local ch, slot = free_image_slot()
    if not ch then return nil, 'no free art image slot' end
    local im = df.art_image:new()
    im.id, im.subid = ch.id, slot
    im.quality = math.min(rec.q or 0, 5)
    im.artist = -1
    im.site = df.global.plotinfo.site_id
    im.event = -1
    im.year = df.global.cur_year
    im.season_tick = 0
    pcall(function()
        local mi = rec.mat and dfhack.matinfo.find(rec.mat)
        im.mat_type = mi and mi.type or -1
        im.mat_index = mi and mi.index or -1
    end)
    pcall(function() if rec.name then name_in(im.name, rec.name, ctx) end end)
    -- element indices are referenced by the properties: keep a map old->new
    local remap, kept = {}, 0
    for i, e in ipairs(rec.elements or {}) do
        local el
        if e.k == 'creature' and e.r then
            local r, c = resolve_kill_race(ctx, {r = e.r, c = e.c, g = e.g, s = e.s})
            if r then
                el = df.art_image_element_creaturest:new()
                el.race, el.caste, el.histfig = r, c or -1, -1
            end
        elseif e.k == 'item' and e.t and df.item_type[e.t] then
            el = df.art_image_element_itemst:new()
            el.item_type = df.item_type[e.t]
            el.item_subtype = -1
            if e.st then
                local ok, st = pcall(dfhack.items.findSubtype, e.t .. ':' .. e.st)
                if ok and st and st >= 0 then el.item_subtype = st end
            end
            local mi = e.mat and dfhack.matinfo.find(e.mat)
            el.mat_type = mi and mi.type or -1
            el.mat_index = mi and mi.index or -1
            el.item_id = -1
        elseif (e.k == 'plant' or e.k == 'tree') and e.p then
            local pid
            for i2, pr in ipairs(df.global.world.raws.plants.all) do
                if pr.id == e.p then pid = i2 break end
            end
            if pid then
                el = (e.k == 'plant' and df.art_image_element_plantst or df.art_image_element_treest):new()
                el.plant_id = pid
            end
        elseif e.k == 'shape' and e.sh then
            local sid
            for i2, s in ipairs(df.global.world.raws.descriptors.shapes) do
                if s.id == e.sh then sid = i2 break end
            end
            if sid then
                el = df.art_image_element_shapest:new()
                el.shape_id, el.shape_adj = sid, e.adj or 0
            end
        end
        if el then
            el.count = e.n or 1
            im.elements:insert('#', el)
            remap[i - 1] = kept
            kept = kept + 1
        else
            common.add_skip(ctx, 'image-element-dropped', e.k .. ':' .. tostring(e.r or e.t or e.p or e.sh))
        end
    end
    if kept == 0 then
        im:delete()  -- never inserted anywhere: safe to free
        return nil, 'no depictable element'
    end
    for _, p in ipairs(rec.properties or {}) do
        local verb = p.v and df.art_image_property_verb[p.v]
        if verb and remap[p.s] ~= nil then
            if p.k == 'trans' and remap[p.o] ~= nil then
                local pr = df.art_image_property_transitive_verbst:new()
                pr.subject, pr.object, pr.verb = remap[p.s], remap[p.o], verb
                im.properties:insert('#', pr)
            elseif p.k == 'intrans' then
                local pr = df.art_image_property_intransitive_verbst:new()
                pr.subject, pr.verb = remap[p.s], verb
                im.properties:insert('#', pr)
            end
        end
    end
    ch.images[slot].art_image = im
    ctx.images_restored = (ctx.images_restored or 0) + 1
    return ch.id, slot
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
