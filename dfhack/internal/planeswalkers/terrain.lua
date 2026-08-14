-- Terrain save/load for fort/planeswalkers: packed tile records, vein/material
-- capture, constructions. Chunked via common.lua's pipeline driver.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local tiletypes = require('plugins.tiletypes')

local PLANT_MATS = {
    [df.tiletype_material.TREE] = true,
    [df.tiletype_material.MUSHROOM] = true,
    [df.tiletype_material.ROOT] = true,
    [df.tiletype_material.PLANT] = true,
    [df.tiletype_material.GRASS_LIGHT] = true,
    [df.tiletype_material.GRASS_DARK] = true,
    [df.tiletype_material.GRASS_DRY] = true,
    [df.tiletype_material.GRASS_DEAD] = true,
}

local function inorganic_token(idx)
    local raw = df.global.world.raws.inorganics.all[idx]
    return raw and ('INORGANIC:' .. raw.id) or nil
end

-- median of sampled highest-non-empty z: the cross-world alignment anchor
function find_surface_z()
    local map = df.global.world.map
    local zs = {}
    for x = 8, map.x_count - 1, 16 do
        for y = 8, map.y_count - 1, 16 do
            for z = map.z_count - 2, 0, -1 do
                local tt = dfhack.maps.getTileType(x, y, z)
                if tt and df.tiletype.attrs[tt].shape ~= df.tiletype_shape.EMPTY then
                    table.insert(zs, z)
                    break
                end
            end
        end
    end
    table.sort(zs)
    return zs[math.max(1, #zs // 2)] or 0
end

-- layer-stone token for an exposed tile, cached per (region, geolayer)
local function layer_mat_token(ctx, x, y, geolayer)
    local rx, ry = dfhack.maps.getTileBiomeRgn(xyz2pos(x, y, 0))
    if not rx then return nil end
    local key = rx .. ':' .. ry .. ':' .. geolayer
    local hit = ctx.layer_cache[key]
    if hit ~= nil then return hit or nil end
    local tok = nil
    local rgn = dfhack.maps.getRegionBiome(rx, ry)
    if rgn then
        local geo = df.world_geo_biome.find(rgn.geo_index)
        if geo and geo.layers[geolayer] then
            tok = inorganic_token(geo.layers[geolayer].mat_index)
        end
    end
    ctx.layer_cache[key] = tok or false
    return tok
end

-- ---- save ------------------------------------------------------------------

local VEIN_PRIORITY = {}  -- inclusion flag -> priority (higher wins)

local function vein_grid(block)
    -- 16x16 grid of inorganic indices from this block's mineral events
    local grid, prio = nil, nil
    for _, ev in ipairs(block.block_events) do
        if df.block_square_event_mineralst:is_instance(ev) then
            local p = ev.flags.cluster_one and 4 or ev.flags.cluster_small and 3
                or ev.flags.vein and 2 or 1
            for x = 0, 15 do
                for y = 0, 15 do
                    if dfhack.maps.getTileAssignment(ev.tile_bitmask, x, y) then
                        grid = grid or {}
                        prio = prio or {}
                        local k = x * 16 + y
                        if not prio[k] or p >= prio[k] then
                            grid[k], prio[k] = ev.inorganic_mat, p
                        end
                    end
                end
            end
        end
    end
    return grid
end

local function save_block(ctx, block, bx, by, z)
    if not block then return common.ZERO_BLOCK end
    local veins = vein_grid(block)
    local recs = {}
    local surface = ctx.manifest.dims.surface
    for x = 0, 15 do
        local ttcol, dscol = block.tiletype[x], block.designation[x]
        for y = 0, 15 do
            local tt = ttcol[y]
            local d = dscol[y]
            local attrs = df.tiletype.attrs[tt]
            local mat_cat = attrs.material
            local tt_out, mat_idx = tt, 0
            if PLANT_MATS[mat_cat] then
                -- trees/plants don't transfer; degrade to what's underneath
                ctx.plant_degraded = (ctx.plant_degraded or 0) + 1
                local shape = attrs.shape
                if shape == df.tiletype_shape.FLOOR or shape == df.tiletype_shape.SAPLING
                    or shape == df.tiletype_shape.SHRUB then
                    tt_out = df.tiletype.SoilFloor1
                else
                    tt_out = df.tiletype.OpenSpace
                end
            else
                local k = x * 16 + y
                if veins and veins[k] ~= nil then
                    local tok = inorganic_token(veins[k])
                    if tok then mat_idx = ctx.legend_mat:intern(tok) end
                elseif mat_cat == df.tiletype_material.LAVA_STONE then
                    mat_idx = ctx.legend_mat:intern('INORGANIC:OBSIDIAN')
                elseif not d.hidden and (mat_cat == df.tiletype_material.STONE
                        or mat_cat == df.tiletype_material.SOIL) then
                    -- exposed natural stone/soil: pin the source layer material
                    local tok = layer_mat_token(ctx, bx * 16 + x, by * 16 + y, d.geolayer_index)
                    if tok then mat_idx = ctx.legend_mat:intern(tok) end
                elseif mat_cat == df.tiletype_material.FEATURE then
                    common.add_skip(ctx, 'feature-mat-left-native')
                end
            end
            recs[#recs + 1] = string.pack(common.TILE_REC,
                ctx.legend_tt:intern(df.tiletype[tt_out]),
                mat_idx, common.pack_dsgn(d), 0)
        end
    end
    return table.concat(recs)
end

function save_phases(ctx)
    local map = df.global.world.map
    local nb = map.x_count_block * map.y_count_block * map.z_count_block
    local phases = {}

    table.insert(phases, {
        name = 'terrain',
        init = function(job)
            ctx.layer_cache = {}
            ctx.tiles_f = io.open(ctx.dir .. '/tiles.bin', 'wb')
            ctx.tiles_f:write(string.pack(common.HEADER_FMT, 'PWT1',
                map.x_count_block, map.y_count_block, map.z_count_block,
                ctx.manifest.dims.surface, 0))
            job.block_cursor = 0
        end,
        total = function() return nb end,
        pos = function(job) return job.block_cursor end,
        step = function(job, deadline)
            local bw, bh = map.x_count_block, map.y_count_block
            while job.block_cursor < nb do
                local i = job.block_cursor
                local z = i // (bw * bh)
                local by = (i % (bw * bh)) // bw
                local bx = i % bw
                ctx.tiles_f:write(save_block(ctx, dfhack.maps.getBlock(bx, by, z), bx, by, z))
                job.block_cursor = i + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.tiles_f:close()
            ctx.tiles_f = nil
            if ctx.plant_degraded and ctx.plant_degraded > 0 then
                common.add_skip(ctx, 'plant-tiles-degraded (regrow naturally)', nil)
                ctx.skips['plant-tiles-degraded (regrow naturally)'].n = ctx.plant_degraded
            end
            ctx.manifest.complete.terrain = true
            return true
        end,
    })

    table.insert(phases, {
        name = 'constructions',
        step = function(job)
            local out = {v = 1, list = {}}
            for _, c in ipairs(df.global.world.event.constructions) do
                local mi = dfhack.matinfo.decode(c.mat_type, c.mat_index)
                table.insert(out.list, {
                    x = c.pos.x, y = c.pos.y, z = c.pos.z,
                    item_type = df.item_type[c.item_type],
                    item_subtype = c.item_subtype,
                    mat = mi and mi:getToken() or nil,
                    original_tile = df.tiletype[c.original_tile],
                })
            end
            common.write_json(ctx.dir .. '/constructions.json', out)
            ctx.manifest.counts.constructions = #out.list
            ctx.manifest.complete.constructions = true
            return true
        end,
    })

    return phases
end

-- ---- load ------------------------------------------------------------------

local function read_header(f)
    local magic, bx, by, bz, surface, flags = string.unpack(common.HEADER_FMT,
        f:read(common.HEADER_SIZE))
    if magic ~= 'PWT1' then qerror('planeswalkers: bad tiles.bin magic') end
    return {bx = bx, by = by, bz = bz, surface = surface, flags = flags}
end

-- compute placement of the source volume in the destination map.
-- returns offsets in tiles (block-aligned horizontally) or nil, err.
function compute_anchor(src_dims)
    local map = df.global.world.map
    if map.x_count_block < src_dims.bx or map.y_count_block < src_dims.by then
        return nil, ('destination embark (%dx%d blocks) is smaller than the source (%dx%d)')
            :format(map.x_count_block, map.y_count_block, src_dims.bx, src_dims.by)
    end
    local off_bx = (map.x_count_block - src_dims.bx) // 2
    local off_by = (map.y_count_block - src_dims.by) // 2
    local dest_surface = find_surface_z()
    return {
        off_x = off_bx * 16, off_y = off_by * 16,
        off_bx = off_bx, off_by = off_by,
        off_z = dest_surface - src_dims.surface,
        dest_surface = dest_surface,
    }
end

local function resolve_mat(ctx, idx)
    if idx == 0 then return nil end
    local hit = ctx.mat_cache[idx]
    if hit ~= nil then return hit or nil end
    local tok = ctx.legend_mat:get(idx)
    local mi = tok and dfhack.matinfo.find(tok)
    if mi and mi.type == 0 then
        ctx.mat_cache[idx] = mi.index
        return mi.index
    end
    ctx.mat_cache[idx] = false
    common.add_skip(ctx, 'material-missing-in-world', tok)
    return nil
end

local function resolve_tt(ctx, idx)
    if idx == 0 then return nil end
    local hit = ctx.tt_cache[idx]
    if hit ~= nil then return hit or nil end
    local key = ctx.legend_tt:get(idx)
    local v = key and df.tiletype[key]
    ctx.tt_cache[idx] = v or false
    if not v then common.add_skip(ctx, 'tiletype-unknown', key) end
    return v
end

local function load_block(ctx, data, src_bx, src_by, src_z)
    local anchor = ctx.anchor
    local z = src_z + anchor.off_z
    if z < 1 or z >= df.global.world.map.z_count - 1 then
        ctx.z_clipped = (ctx.z_clipped or 0) + 1
        return
    end
    local bx, by = src_bx + anchor.off_bx, src_by + anchor.off_by
    local block = dfhack.maps.getBlock(bx, by, z)
    if not block then
        ctx.no_block = (ctx.no_block or 0) + 1
        return
    end
    local off = 1
    local touched = false
    for x = 0, 15 do
        local ttcol, dscol = block.tiletype[x], block.designation[x]
        for y = 0, 15 do
            local tt_idx, mat_idx, dbits = string.unpack(common.TILE_REC, data, off)
            off = off + common.TILE_REC_SIZE
            local tt = resolve_tt(ctx, tt_idx)
            if tt then
                touched = true
                ttcol[y] = tt
                local d = dscol[y]
                local bits = common.unpack_dsgn(dbits)
                d.flow_size = bits.flow_size
                d.liquid_type = bits.liquid_type
                d.hidden = bits.hidden
                d.subterranean = bits.subterranean
                d.light = bits.light
                d.outside = bits.outside
                d.water_stagnant = bits.water_stagnant
                d.water_salt = bits.water_salt
                if mat_idx ~= 0 then
                    ctx.paint_list[#ctx.paint_list + 1] =
                        string.pack('<I2I2I2I2', bx * 16 + x, by * 16 + y, z, mat_idx)
                end
            end
        end
    end
    if touched then dfhack.maps.enableBlockUpdates(block, true, true) end
end

function load_phases(ctx)
    local phases = {}

    table.insert(phases, {
        name = 'terrain shapes',
        init = function(job)
            ctx.tiles_f = io.open(ctx.dir .. '/tiles.bin', 'rb')
            ctx.src = read_header(ctx.tiles_f)
            ctx.paint_list = {}
            ctx.mat_cache, ctx.tt_cache = {}, {}
            job.block_cursor = 0
            job.nb = ctx.src.bx * ctx.src.by * ctx.src.bz
        end,
        total = function(job) return job.nb end,
        pos = function(job) return job.block_cursor end,
        step = function(job, deadline)
            local s = ctx.src
            while job.block_cursor < job.nb do
                local data = ctx.tiles_f:read(common.BLOCK_SIZE)
                if not data then break end
                local i = job.block_cursor
                local z = i // (s.bx * s.by)
                local by = (i % (s.bx * s.by)) // s.bx
                local bx = i % s.bx
                load_block(ctx, data, bx, by, z)
                job.block_cursor = i + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.tiles_f:close()
            ctx.tiles_f = nil
            if ctx.z_clipped then
                common.add_skip(ctx, 'blocks-clipped-at-z-edge')
                ctx.skips['blocks-clipped-at-z-edge'].n = ctx.z_clipped
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'materials/veins',
        init = function(job) job.paint_cursor = 1 end,
        total = function() return #ctx.paint_list end,
        pos = function(job) return job.paint_cursor end,
        step = function(job, deadline)
            while job.paint_cursor <= #ctx.paint_list do
                local x, y, z, mat_idx = string.unpack('<I2I2I2I2',
                    ctx.paint_list[job.paint_cursor])
                job.paint_cursor = job.paint_cursor + 1
                local midx = resolve_mat(ctx, mat_idx)
                if midx then
                    local tt = dfhack.maps.getTileType(x, y, z)
                    local attrs = df.tiletype.attrs[tt]
                    local d = select(1, dfhack.maps.getTileFlags(xyz2pos(x, y, z)))
                    tiletypes.tiletypes_setTile(xyz2pos(x, y, z), {
                        shape = attrs.shape,
                        material = df.tiletype_material.STONE,
                        special = attrs.special == df.tiletype_special.NONE and
                                  df.tiletype_special.NORMAL or attrs.special,
                        variant = attrs.variant,
                        hidden = d.hidden and 1 or 0,
                        light = d.light and 1 or 0,
                        subterranean = d.subterranean and 1 or 0,
                        skyview = d.outside and 1 or 0,
                        aquifer = -1, autocorrect = 0,
                        stone_material = midx,
                        vein_type = df.inclusion_type.CLUSTER,
                    })
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'constructions',
        init = function(job)
            job.cons = common.read_json(ctx.dir .. '/constructions.json') or {list = {}}
            job.con_cursor = 1
        end,
        total = function(job) return #job.cons.list end,
        pos = function(job) return job.con_cursor end,
        step = function(job, deadline)
            local a = ctx.anchor
            while job.con_cursor <= #job.cons.list do
                local c = job.cons.list[job.con_cursor]
                job.con_cursor = job.con_cursor + 1
                local z = c.z + a.off_z
                if z >= 1 and z < df.global.world.map.z_count - 1 then
                    local mi = c.mat and dfhack.matinfo.find(c.mat)
                    local con = df.construction:new()
                    con.pos.x, con.pos.y, con.pos.z = c.x + a.off_x, c.y + a.off_y, z
                    con.item_type = df.item_type[c.item_type] or df.item_type.BOULDER
                    con.item_subtype = c.item_subtype or -1
                    if mi then
                        con.mat_type, con.mat_index = mi.type, mi.index
                    else
                        con.mat_type, con.mat_index = 0, -1
                        if c.mat then common.add_skip(ctx, 'construction-mat-missing', c.mat) end
                    end
                    con.original_tile = df.tiletype[c.original_tile] or df.tiletype.OpenSpace
                    if not dfhack.constructions.insert(con) then
                        con:delete()
                        common.add_skip(ctx, 'construction-pos-occupied')
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'map cleanup',
        step = function(job)
            df.global.world.reindex_pathfinding = true
            df.global.gps.force_full_display_count = 1
            dfhack.run_command('fix/occupancy')
            return true
        end,
    })

    return phases
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
