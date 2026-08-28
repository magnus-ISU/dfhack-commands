-- Buildings / stockpiles / zones save+load for fort/planeswalkers.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local stockpiles = require('plugins.stockpiles')

local STOCKPILES_DIR = dfhack.getConfigPath() .. '/stockpiles'

-- ---- save ------------------------------------------------------------------

local function extents_out(bld)
    local room = bld.room
    if not room or not room.extents then return nil end
    local n = room.width * room.height
    local s = {}
    for i = 0, n - 1 do s[#s + 1] = tostring(room.extents[i]) end
    return {x = room.x, y = room.y, w = room.width, h = room.height,
            bits = table.concat(s)}
end

local function mat_token_of(mat_type, mat_index)
    local mi = dfhack.matinfo.decode(mat_type, mat_index)
    return mi and mi:getToken() or nil
end

local function subtype_token(item_type, item_subtype)
    if item_subtype < 0 then return nil end
    local ok, def = pcall(dfhack.items.getSubtypeDef, item_type, item_subtype)
    return ok and def and def.id or nil
end

local function save_one(ctx, bld)
    local btype = bld:getType()
    if btype == df.building_type.Wagon then return nil end
    -- world.buildings.all can contain buildings from OTHER previously-loaded
    -- sites (adventurer travels); their coords belong to other maps. Most of
    -- the fort's own buildings carry site_id -1 (DF only stamps some paths),
    -- so only a DIFFERENT non-negative site id marks a foreigner
    if bld.site_id >= 0 and bld.site_id ~= df.global.plotinfo.site_id then
        return nil
    end
    local rec = {
        id = bld.id,
        type = df.building_type[btype],
        subtype = bld:getSubtype(),
        x = bld.x1, y = bld.y1, z = bld.z,
        w = bld.x2 - bld.x1 + 1, h = bld.y2 - bld.y1 + 1,
        cx = bld.centerx - bld.x1, cy = bld.centery - bld.y1,
        mat = mat_token_of(bld.mat_type, bld.mat_index),
        name = bld.name and #bld.name > 0 and common.u(bld.name) or nil,
        extents = extents_out(bld),
    }
    local custom = bld:getCustomType()
    if custom >= 0 then
        local cdef = df.building_def.find(custom)
        rec.custom = cdef and cdef.code or nil
        if not rec.custom then
            common.add_skip(ctx, 'building-custom-def-unresolved', rec.type)
            return nil
        end
    end
    local ok, dir = pcall(function() return bld.direction end)
    if ok then rec.direction = dir end

    if btype == df.building_type.Stockpile then
        rec.caps = {
            barrels = bld.storage.max_barrels,
            bins = bld.storage.max_bins,
            wheelbarrows = bld.storage.max_wheelbarrows,
        }
        rec.give_to, rec.take_from = {}, {}
        for _, b in ipairs(bld.links.give_to_pile) do table.insert(rec.give_to, b.id) end
        for _, b in ipairs(bld.links.take_from_pile) do table.insert(rec.take_from, b.id) end
        -- settings via the stockpiles plugin's token-based protobuf format
        local tmp = 'planeswalkers_tmp'
        local okx, err = pcall(stockpiles.export_settings, tmp, {id = bld.id})
        if okx then
            local f = io.open(STOCKPILES_DIR .. '/' .. tmp .. '.dfstock', 'rb')
            if f then
                local bytes = f:read('a')
                f:close()
                local out = io.open(ctx.dir .. '/pile_' .. bld.id .. '.dfstock', 'wb')
                out:write(bytes)
                out:close()
                rec.settings = 'pile_' .. bld.id .. '.dfstock'
            end
        else
            common.add_skip(ctx, 'stockpile-settings-export-failed', tostring(err))
        end
    elseif btype == df.building_type.Civzone then
        rec.subtype_name = df.civzone_type[bld:getSubtype()]
        -- pen/pond/gather/archery/tomb settings live in the zone_settings
        -- union (two ints); spec_sub_flag carries per-type UI toggles
        pcall(function()
            rec.zs1 = bld.zone_settings.whole.i1
            rec.zs2 = bld.zone_settings.whole.i2
            rec.spec = bld.spec_sub_flag.whole
        end)
    elseif btype == df.building_type.Door then
        rec.door_flags = bld.door_flags.whole
    elseif btype == df.building_type.FarmPlot then
        rec.crops = {}
        for season = 0, 3 do
            local pid = bld.plant_id[season]
            local plant = pid >= 0 and df.global.world.raws.plants.all[pid]
            rec.crops[season + 1] = plant and plant.id or ''
        end
    elseif btype == df.building_type.Trap then
        rec.trap_type = df.trap_type[bld.trap_type]
        if bld.trap_type == df.trap_type.Lever then
            rec.lever_targets = {}
            for _, mech in ipairs(bld.linked_mechanisms) do
                for _, ref in ipairs(mech.general_refs) do
                    if df.general_ref_building_holderst:is_instance(ref) then
                        table.insert(rec.lever_targets, ref.building_id)
                    end
                end
            end
        end
    end

    -- construction components (what the building is made of); stockpiles and
    -- other non-actual buildings have no contained_items field at all
    if df.building_actual:is_instance(bld) then
        rec.components = {}
        for _, ci in ipairs(bld.contained_items) do
            if ci.use_mode == 2 and ci.item then
                table.insert(rec.components, {
                    t = df.item_type[ci.item:getType()],
                    st = subtype_token(ci.item:getType(), ci.item:getSubtype()),
                    mat = mat_token_of(ci.item:getMaterial(), ci.item:getMaterialIndex()),
                })
            end
        end
    end
    return rec
end

function save_phases(ctx)
    return {{
        name = 'buildings',
        init = function(job)
            job.blds = {v = 1, list = {}}
            job.bld_cursor = 0
        end,
        total = function() return #df.global.world.buildings.all end,
        pos = function(job) return job.bld_cursor end,
        step = function(job, deadline)
            local all = df.global.world.buildings.all
            while job.bld_cursor < #all do
                local ok, rec = pcall(save_one, ctx, all[job.bld_cursor])
                if ok and rec then
                    table.insert(job.blds.list, rec)
                elseif not ok then
                    common.add_skip(ctx, 'building-save-error', tostring(rec))
                end
                job.bld_cursor = job.bld_cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            common.write_json(ctx.dir .. '/buildings.json', job.blds)
            ctx.manifest.counts.buildings = #job.blds.list
            ctx.manifest.complete.buildings = true
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function make_extents(rec, a)
    if not rec.extents then return nil end
    local e = rec.extents
    local n = e.w * e.h
    local buf = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', n))
    for i = 0, n - 1 do
        buf[i] = tonumber(e.bits:sub(i + 1, i + 1)) or 0
    end
    return {x = rec.x + a.off_x, y = rec.y + a.off_y, width = e.w, height = e.h,
            extents = buf}
end

local creator_unit = common.creator_unit

local function mint_component(ctx, comp)
    local itype = df.item_type[comp.t]
    if not itype then return nil end
    local isub = -1
    if comp.st then
        local ok, v = pcall(dfhack.items.findSubtype, comp.t .. ':' .. comp.st)
        if ok and v and v ~= -1 then isub = v end
    end
    local mt, mi = 0, -1
    if comp.mat then
        local minfo = dfhack.matinfo.find(comp.mat)
        if minfo then mt, mi = minfo.type, minfo.index
        else common.add_skip(ctx, 'component-mat-missing', comp.mat) end
    end
    -- no_floor=false: limbo-created items cannot be attached to buildings
    local items = dfhack.items.createItem(creator_unit(), itype, isub, mt, mi, false)
    local item = items and items[1]
    if type(item) == 'table' then item = item[1] end
    return common.unproject(item)
end

-- mirror of build-now.lua's instant completion
local function complete_build(bld, items)
    for _, job in ipairs(bld.jobs) do
        dfhack.job.removeJob(job)
        break
    end
    for _, item in ipairs(items) do
        if not item.flags.in_building then
            local use = bld:getType() == df.building_type.Construction and 0 or 2
            dfhack.items.moveToBuilding(item, bld, use)
        end
    end
    if bld:needsDesign() then
        local design = bld.design
        design.flags.built = true
        design.hitpoints = 80640
        design.max_hitpoints = 80640
    end
    bld:setBuildStage(bld:getMaxBuildStage())
    dfhack.buildings.completeBuild(bld)
end

local function resolve_custom(ctx, code)
    ctx.custom_cache = ctx.custom_cache or {}
    local hit = ctx.custom_cache[code]
    if hit ~= nil then return hit or nil end
    for i, cdef in ipairs(df.global.world.raws.buildings.all) do
        if cdef.code == code then
            ctx.custom_cache[code] = cdef.id
            return cdef.id
        end
    end
    ctx.custom_cache[code] = false
    return nil
end

local function load_one(ctx, rec)
    local a = ctx.anchor
    local btype = df.building_type[rec.type]
    if not btype then
        common.add_skip(ctx, 'building-type-unknown', rec.type)
        return
    end
    local z = rec.z + a.off_z
    if z < 1 or z >= df.global.world.map.z_count - 1 then
        common.add_skip(ctx, 'building-clipped-at-z-edge', rec.type)
        return
    end
    local pos = xyz2pos(rec.x + a.off_x, rec.y + a.off_y, z)
    local custom = -1
    if rec.custom then
        custom = resolve_custom(ctx, rec.custom) or -1
        if custom == -1 then
            common.add_skip(ctx, 'building-custom-missing-in-world', rec.custom)
            return
        end
    end

    if btype == df.building_type.Stockpile or btype == df.building_type.Civzone then
        local args = {
            type = btype, abstract = true, pos = pos,
            width = rec.w, height = rec.h,
            fields = {room = make_extents(rec, a)},
        }
        if btype == df.building_type.Civzone then
            args.subtype = rec.subtype_name and df.civzone_type[rec.subtype_name] or rec.subtype
            args.fields.assigned_unit_id = -1
        end
        local bld, err = dfhack.buildings.constructBuilding(args)
        if not bld then
            common.add_skip(ctx, 'building-place-failed', rec.type .. ': ' .. tostring(err))
            return
        end
        if rec.name then bld.name = common.fromu(rec.name) end
        if btype == df.building_type.Stockpile then
            if rec.caps then
                bld.storage.max_barrels = rec.caps.barrels
                bld.storage.max_bins = rec.caps.bins
                bld.storage.max_wheelbarrows = rec.caps.wheelbarrows
            end
            if rec.settings then
                local f = io.open(ctx.dir .. '/' .. rec.settings, 'rb')
                if f then
                    local bytes = f:read('a')
                    f:close()
                    dfhack.filesystem.mkdir_recursive(STOCKPILES_DIR)
                    local out = io.open(STOCKPILES_DIR .. '/planeswalkers_tmp.dfstock', 'wb')
                    out:write(bytes)
                    out:close()
                    local ok, err2 = pcall(stockpiles.import_settings, 'planeswalkers_tmp',
                                           {id = bld.id, mode = 'set'})
                    if not ok then
                        common.add_skip(ctx, 'stockpile-settings-import-failed', tostring(err2))
                    end
                end
            end
        else
            pcall(function()
                if rec.zs1 then bld.zone_settings.whole.i1 = rec.zs1 end
                if rec.zs2 then bld.zone_settings.whole.i2 = rec.zs2 end
                if rec.spec then bld.spec_sub_flag.whole = rec.spec end
            end)
            pcall(function() dfhack.buildings.notifyCivzoneModified(bld) end)
        end
        ctx.bld_map[rec.id] = bld
        return
    end

    -- farm plots and roads are built from nothing: let the filters path make
    -- the (item-less) construct job, then complete it
    if btype == df.building_type.FarmPlot or btype == df.building_type.RoadPaved
        or btype == df.building_type.RoadDirt then
        local args = {
            type = btype, subtype = rec.subtype, pos = pos,
            width = rec.w, height = rec.h,
            fields = {room = make_extents(rec, a)},
        }
        local bld, err = dfhack.buildings.constructBuilding(args)
        if not bld then
            common.add_skip(ctx, 'building-place-failed', rec.type .. ': ' .. tostring(err))
            return
        end
        complete_build(bld, {})
        if rec.name then bld.name = common.fromu(rec.name) end
        if rec.crops and btype == df.building_type.FarmPlot then
            for season = 0, 3 do
                local pid = -1
                local code = rec.crops[season + 1]
                if code and code ~= '' then
                    for i, plant in ipairs(df.global.world.raws.plants.all) do
                        if plant.id == code then pid = i break end
                    end
                    if pid == -1 then common.add_skip(ctx, 'crop-missing-in-world', code) end
                end
                bld.plant_id[season] = pid
            end
        end
        ctx.bld_map[rec.id] = bld
        return
    end

    -- regular building: mint its components and build instantly
    local items = {}
    for _, comp in ipairs(rec.components or {}) do
        local item = mint_component(ctx, comp)
        if item then table.insert(items, item) end
    end
    if #items == 0 then
        -- some furniture buildings record no components; mint the obvious
        -- matching item (Statue -> STATUE etc.) so the build has substance
        local guess = df.item_type[rec.type:upper()] and rec.type:upper() or 'BOULDER'
        local item = mint_component(ctx, {t = guess, mat = rec.mat})
        if not item then
            -- material may be missing/none (e.g. farm plots): any stone will do
            item = mint_component(ctx, {t = 'BOULDER', mat = 'INORGANIC:MICROCLINE'})
        end
        if item then table.insert(items, item) end
    end
    local args = {
        type = btype, subtype = rec.subtype, custom = custom, pos = pos,
        width = rec.w, height = rec.h,
        items = items,  -- possibly empty; never abstract for actual buildings
    }
    if rec.direction then args.direction = rec.direction end
    local bld, err = dfhack.buildings.constructBuilding(args)
    if not bld then
        for _, item in ipairs(items) do dfhack.items.remove(item) end
        common.add_skip(ctx, 'building-place-failed', rec.type .. ': ' .. tostring(err))
        return
    end
    complete_build(bld, items)
    if rec.name then bld.name = common.fromu(rec.name) end
    if rec.door_flags and btype == df.building_type.Door then
        bld.door_flags.whole = rec.door_flags
    end
    if rec.crops and btype == df.building_type.FarmPlot then
        for season = 0, 3 do
            local pid = -1
            local code = rec.crops[season + 1]
            if code and code ~= '' then
                for i, plant in ipairs(df.global.world.raws.plants.all) do
                    if plant.id == code then pid = i break end
                end
                if pid == -1 then common.add_skip(ctx, 'crop-missing-in-world', code) end
            end
            bld.plant_id[season] = pid
        end
    end
    ctx.bld_map[rec.id] = bld
end

-- the destination embark comes with furniture of its own -- the wagon above
-- all; with --force, a whole previous fort. Remove every building that
-- predates the restore: stored items (the embark supplies) drop to the
-- ground, construction components (the wagon's logs) are deleted outright.
function clear_phase(ctx)
    return {
        name = 'clear old buildings',
        init = function(job)
            job.old = {}
            for _, b in ipairs(df.global.world.buildings.all) do
                table.insert(job.old, b)
            end
            job.cursor = 1
        end,
        total = function(job) return #job.old end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            while job.cursor <= #job.old do
                local bld = job.old[job.cursor]
                job.cursor = job.cursor + 1
                local ok, err = pcall(function()
                    local pos = xyz2pos(bld.centerx, bld.centery, bld.z)
                    if df.building_actual:is_instance(bld) then
                        for i = #bld.contained_items - 1, 0, -1 do
                            local ci = bld.contained_items[i]
                            -- one stuck item must not strand the rest
                            pcall(function()
                                if ci.use_mode == 2 then
                                    dfhack.items.remove(ci.item)
                                else
                                    dfhack.items.moveToGround(ci.item, pos)
                                end
                            end)
                        end
                        -- deconstruct() only QUEUES a dwarf job for a built
                        -- building; zeroing the stage takes DFHack's
                        -- immediate-destruction path instead
                        pcall(function() bld.construction_stage = 0 end)
                    end
                    dfhack.buildings.deconstruct(bld)
                end)
                if not ok then
                    common.add_skip(ctx, 'old-building-not-cleared', tostring(err))
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    }
end

function load_phases(ctx)
    local phases = {}
    table.insert(phases, {
        name = 'buildings',
        init = function(job)
            job.blds = common.read_json(ctx.dir .. '/buildings.json') or {list = {}}
            job.bld_cursor = 1
            ctx.bld_map = {}
        end,
        total = function(job) return #job.blds.list end,
        pos = function(job) return job.bld_cursor end,
        step = function(job, deadline)
            while job.bld_cursor <= #job.blds.list do
                local rec = job.blds.list[job.bld_cursor]
                job.bld_cursor = job.bld_cursor + 1
                local ok, err = pcall(load_one, ctx, rec)
                if not ok then
                    common.add_skip(ctx, 'building-load-error',
                                    (rec.type or '?') .. ': ' .. tostring(err))
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    })
    table.insert(phases, {
        name = 'building links',
        init = function(job)
            job.blds = job.blds or common.read_json(ctx.dir .. '/buildings.json') or {list = {}}
        end,
        step = function(job)
            local lever_links = 0
            for _, rec in ipairs(job.blds.list) do
                local bld = ctx.bld_map[rec.id]
                if bld then
                    -- a zone placed before the furniture inside it never saw
                    -- that furniture: re-notify every zone now that all
                    -- buildings exist so contained_buildings/relations link up
                    if df.building_civzonest:is_instance(bld) then
                        pcall(function() dfhack.buildings.notifyCivzoneModified(bld) end)
                    end
                    for _, tid in ipairs(rec.give_to or {}) do
                        local target = ctx.bld_map[tid]
                        if target then
                            bld.links.give_to_pile:insert('#', target)
                            target.links.take_from_pile:insert('#', bld)
                        end
                    end
                    if rec.lever_targets and #rec.lever_targets > 0 then
                        lever_links = lever_links + #rec.lever_targets
                    end
                end
            end
            if lever_links > 0 then
                common.add_skip(ctx, 'lever-links-not-restored (relink by hand)')
                ctx.skips['lever-links-not-restored (relink by hand)'].n = lever_links
            end
            return true
        end,
    })
    return phases
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
