-- Terrain save/load for fort/planeswalkers: packed tile records, vein/material
-- capture, constructions. Chunked via common.lua's pipeline driver.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local tiletypes = require('plugins.tiletypes')
local tilemat = require('tile-material')

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

-- top of the world's deep structure (semi-molten rock / eerie pits): the
-- magma sea and the underworld live at and below this z. Neither survives
-- transplanting -- painting one world's hell into another's rock breaches
-- the underworld and releases its demons -- so save and load both stop
-- above it. Sampled like find_surface_z; +2 margin for the sea's surface.
function find_deep_top_z()
    local map = df.global.world.map
    local top = -1
    for x = 8, map.x_count - 1, 16 do
        for y = 8, map.y_count - 1, 16 do
            for z = math.min(map.z_count - 1, 80), 0, -1 do
                if z <= top then break end
                local tt = dfhack.maps.getTileType(x, y, z)
                if tt == df.tiletype.SemiMoltenRock or tt == df.tiletype.EeriePit then
                    top = z
                    break
                end
            end
        end
    end
    return top >= 0 and top + 2 or -1
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

-- layer-stone token for an exposed tile, cached per (region, geolayer).
-- returns token, is_soil (is_soil = the inorganic really has the SOIL flag;
-- deep cavern-floor tiles often have geolayers pointing at STONE layers)
local function layer_mat_token(ctx, x, y, geolayer)
    local rx, ry = dfhack.maps.getTileBiomeRgn(xyz2pos(x, y, 0))
    if not rx then return nil end
    local key = rx .. ':' .. ry .. ':' .. geolayer
    local hit = ctx.layer_cache[key]
    if hit ~= nil then
        if hit then return hit.tok, hit.soil end
        return nil
    end
    local tok, soil = nil, false
    local rgn = dfhack.maps.getRegionBiome(rx, ry)
    if rgn then
        local geo = df.world_geo_biome.find(rgn.geo_index)
        if geo and geo.layers[geolayer] then
            local midx = geo.layers[geolayer].mat_index
            tok = inorganic_token(midx)
            local raw = df.global.world.raws.inorganics.all[midx]
            soil = raw and raw.flags.SOIL and true or false
        end
    end
    ctx.layer_cache[key] = tok and {tok = tok, soil = soil} or false
    return tok, soil
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
            local tt_out, mat_idx, flags = tt, 0, 0
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
            elseif mat_cat == df.tiletype_material.CONSTRUCTION then
                -- the construction record carries the material; painting anything
                -- here would clobber the constructed tiletype (seen: obsidian
                -- hospital walls turning into the under-vein's stone)
            else
                -- dispatch strictly by the tiletype's material category, the way
                -- tile-material (and DF) resolve tiles: a stone cluster event
                -- overlapping a FEATURE tile must NOT claim it (that bug recorded
                -- most of an adamantine spire as gabbro)
                local k = x * 16 + y
                if mat_cat == df.tiletype_material.SOIL then
                    -- soil (incl. hidden sand/clay pockets): pin the layer material,
                    -- restored by remapping the tile's geolayer in the destination.
                    -- Only when the layer really is soil -- deep "soil" tiles with
                    -- stone geolayers must not claim scarce soil layer slots.
                    local tok, is_soil = layer_mat_token(ctx, bx * 16 + x, by * 16 + y,
                                                         d.geolayer_index)
                    if tok and is_soil then
                        mat_idx = ctx.legend_mat:intern(tok)
                        flags = 1
                    end
                elseif mat_cat == df.tiletype_material.MINERAL then
                    if veins and veins[k] ~= nil then
                        local tok = inorganic_token(veins[k])
                        if tok then mat_idx = ctx.legend_mat:intern(tok) end
                    end
                elseif mat_cat == df.tiletype_material.LAVA_STONE then
                    mat_idx = ctx.legend_mat:intern('INORGANIC:OBSIDIAN')
                elseif mat_cat == df.tiletype_material.FEATURE then
                    -- adamantine spires etc: restore as a mineable vein of the
                    -- feature's material (the feature itself can't cross worlds)
                    local ok, mi = pcall(tilemat.GetFeatureMat, bx * 16 + x, by * 16 + y, z)
                    local tok
                    if ok and mi then
                        local ok2, t = pcall(function() return mi:getToken() end)
                        if ok2 then tok = t end
                    end
                    if tok then
                        mat_idx = ctx.legend_mat:intern(tok)
                    else
                        common.add_skip(ctx, 'feature-mat-unresolved')
                    end
                elseif not d.hidden and mat_cat == df.tiletype_material.STONE then
                    -- exposed natural stone: pin the source layer material
                    local tok = layer_mat_token(ctx, bx * 16 + x, by * 16 + y, d.geolayer_index)
                    if tok then mat_idx = ctx.legend_mat:intern(tok) end
                end
            end
            recs[#recs + 1] = string.pack(common.TILE_REC,
                ctx.legend_tt:intern(df.tiletype[tt_out]),
                mat_idx, common.pack_dsgn(d), flags)
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
            ctx.deep_top = find_deep_top_z()
            ctx.manifest.dims.deep_top = ctx.deep_top
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
                if z <= ctx.deep_top then
                    -- the magma sea and the underworld stay home
                    ctx.tiles_f:write(common.ZERO_BLOCK)
                else
                    ctx.tiles_f:write(save_block(ctx, dfhack.maps.getBlock(bx, by, z), bx, by, z))
                end
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

-- find duplicate layers in each dest geo biome: tiles get remapped onto the
-- first copy (identical material, no visual change), freeing the dup slots to
-- be rewritten as source soil layers (geolayer_index is 4 bits -- 16 slots max)
local function build_geo_remaps(ctx)
    ctx.geo_remap, ctx.geo_free = {}, {}
    for gi, geo in ipairs(df.global.world.world_data.geo_biomes) do
        local seen, remap, free = {}, nil, {}
        for i = 0, #geo.layers - 1 do
            local l = geo.layers[i]
            local raw = df.global.world.raws.inorganics.all[l.mat_index]
            local bogus_soil = l.type == df.geo_layer_type.SOIL
                and not (raw and raw.flags.SOIL)
            local k = l.type .. ':' .. l.mat_index
            if bogus_soil then
                -- a SOIL-typed layer of stone (left by an earlier bad restore):
                -- reclaim the slot outright
                table.insert(free, i)
            elseif seen[k] ~= nil then
                remap = remap or {}
                remap[i] = seen[k]
                table.insert(free, i)
            else
                seen[k] = i
            end
        end
        ctx.geo_remap[gi] = remap
        ctx.geo_free[gi] = free
    end
end

local function block_geo_index(bx, by)
    local rx, ry = dfhack.maps.getTileBiomeRgn(xyz2pos(bx * 16 + 8, by * 16 + 8, 0))
    if not rx then return nil end
    local rgn = dfhack.maps.getRegionBiome(rx, ry)
    return rgn and rgn.geo_index or nil
end

-- point a soil tile's geolayer at a dest geo-biome layer of the right material,
-- appending a new layer to the geo biome if it has none (soil material is
-- resolved through the geolayer -- vein events are IGNORED for soil tiles)
local function set_soil_layer(ctx, x, y, z, midx)
    local rx, ry = dfhack.maps.getTileBiomeRgn(xyz2pos(x, y, z))
    if not rx then return false end
    local rgn = dfhack.maps.getRegionBiome(rx, ry)
    if not rgn then return false end
    local key = rgn.geo_index .. ':' .. midx
    ctx.geo_cache = ctx.geo_cache or {}
    local li = ctx.geo_cache[key]
    if li == nil then
        local geo = df.world_geo_biome.find(rgn.geo_index)
        if not geo then ctx.geo_cache[key] = false return false end
        for i = 0, #geo.layers - 1 do
            if geo.layers[i].mat_index == midx then li = i break end
        end
        if not li then
            -- rewrite a freed duplicate slot as this exact soil
            local free = ctx.geo_free and ctx.geo_free[rgn.geo_index]
            if free and #free > 0 then
                li = table.remove(free, 1)
                local layer = geo.layers[li]
                layer.type = df.geo_layer_type.SOIL
                layer.mat_index = midx
            end
        end
        if not li and #geo.layers < 16 then  -- geolayer_index is 4 bits
            local layer = df.world_geo_layer:new()
            layer.type = df.geo_layer_type.SOIL
            layer.mat_index = midx
            layer.top_height = 0
            layer.bottom_height = -1
            geo.layers:insert('#', layer)
            li = #geo.layers - 1
        end
        if not li then
            -- geo biome full: approximate with the nearest same-class soil layer
            local want_sand = df.global.world.raws.inorganics.all[midx].flags.SOIL_SAND
                and true or false
            local soil_any
            for i = 0, #geo.layers - 1 do
                local l = geo.layers[i]
                if l.type == df.geo_layer_type.SOIL then
                    local raw = df.global.world.raws.inorganics.all[l.mat_index]
                    soil_any = soil_any or i
                    local is_sand = raw and raw.flags.SOIL_SAND and true or false
                    if is_sand == want_sand then
                        li = i
                        break
                    end
                end
            end
            li = li or soil_any
            if li then
                common.add_skip(ctx, 'soil-mat-approximated', inorganic_token(midx))
            else
                common.add_skip(ctx, 'soil-mat-unrestorable', inorganic_token(midx))
                li = false
            end
        end
        ctx.geo_cache[key] = li
    end
    if li == false then return false end
    local block = dfhack.maps.getTileBlock(x, y, z)
    if not block then return false end
    block.designation[x % 16][y % 16].geolayer_index = li
    return true
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
    if z <= (ctx.dest_deep_top or -1) then
        -- never touch THIS world's magma sea / underworld structure
        ctx.deep_clipped = (ctx.deep_clipped or 0) + 1
        return
    end
    local bx, by = src_bx + anchor.off_bx, src_by + anchor.off_by
    local block = dfhack.maps.getBlock(bx, by, z)
    if not block then
        ctx.no_block = (ctx.no_block or 0) + 1
        return
    end
    -- dedup this block's geolayer references so hijacked dup slots are unused
    local remap = ctx.geo_remap and ctx.geo_remap[block_geo_index(bx, by) or -1]
    if remap then
        for x = 0, 15 do
            local dscol = block.designation[x]
            for y = 0, 15 do
                local r = remap[dscol[y].geolayer_index]
                if r then dscol[y].geolayer_index = r end
            end
        end
    end
    local off = 1
    local touched = false
    for x = 0, 15 do
        local ttcol, dscol = block.tiletype[x], block.designation[x]
        for y = 0, 15 do
            local tt_idx, mat_idx, dbits, rflags = string.unpack(common.TILE_REC, data, off)
            off = off + common.TILE_REC_SIZE
            local tt = resolve_tt(ctx, tt_idx)
            -- pre-guard snapshots carry the source's deep structure: importing
            -- another world's hell breaches this one's -- drop those tiles
            if tt == df.tiletype.SemiMoltenRock or tt == df.tiletype.EeriePit then
                ctx.deep_dropped = (ctx.deep_dropped or 0) + 1
                tt = nil
            end
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
                        string.pack('<I2I2I2I2B', bx * 16 + x, by * 16 + y, z, mat_idx, rflags)
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
            ctx.dest_deep_top = find_deep_top_z()
            ctx.paint_list = {}
            ctx.mat_cache, ctx.tt_cache = {}, {}
            build_geo_remaps(ctx)
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
            if ctx.deep_clipped then
                common.add_skip(ctx, 'blocks-below-magma-sea-untouched')
                ctx.skips['blocks-below-magma-sea-untouched'].n = ctx.deep_clipped
            end
            if ctx.deep_dropped then
                common.add_skip(ctx, 'source-underworld-tiles-dropped')
                ctx.skips['source-underworld-tiles-dropped'].n = ctx.deep_dropped
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'geolayer dedup (unrestored z)',
        init = function(job)
            -- z-levels the restore doesn't cover still reference the dup slots
            -- we hijack; remap them too so hijacked layers change nothing there
            job.zlist = {}
            local a = ctx.anchor
            for z = 0, df.global.world.map.z_count - 1 do
                local sz = z - a.off_z
                if sz < 0 or sz >= ctx.src.bz then table.insert(job.zlist, z) end
            end
            job.zi, job.bi = 1, 0
        end,
        total = function(job) return #job.zlist end,
        pos = function(job) return job.zi end,
        step = function(job, deadline)
            local map = df.global.world.map
            local nb = map.x_count_block * map.y_count_block
            while job.zi <= #job.zlist do
                local z = job.zlist[job.zi]
                while job.bi < nb do
                    local bx, by = job.bi % map.x_count_block, job.bi // map.x_count_block
                    local remap = ctx.geo_remap[block_geo_index(bx, by) or -1]
                    if remap then
                        local block = dfhack.maps.getBlock(bx, by, z)
                        if block then
                            for x = 0, 15 do
                                local dscol = block.designation[x]
                                for y = 0, 15 do
                                    local r = remap[dscol[y].geolayer_index]
                                    if r then dscol[y].geolayer_index = r end
                                end
                            end
                        end
                    end
                    job.bi = job.bi + 1
                    if dfhack.getTickCount() >= deadline then return false end
                end
                job.bi = 0
                job.zi = job.zi + 1
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
                local x, y, z, mat_idx, rflags = string.unpack('<I2I2I2I2B',
                    ctx.paint_list[job.paint_cursor])
                job.paint_cursor = job.paint_cursor + 1
                local midx = resolve_mat(ctx, mat_idx)
                if midx and rflags & 1 == 1 then
                    -- soil: keep the soil tiletype, remap the tile's geolayer so
                    -- the tile resolves as the source soil (e.g. sand)
                    set_soil_layer(ctx, x, y, z, midx)
                elseif midx then
                    local tt = dfhack.maps.getTileType(x, y, z)
                    local attrs = df.tiletype.attrs[tt]
                    if attrs.material == df.tiletype_material.CONSTRUCTION then
                        goto continue  -- never repaint a construction tile
                    end
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
                ::continue::
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
                if z >= 1 and z < df.global.world.map.z_count - 1
                    and z > (ctx.dest_deep_top or -1) then
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
            -- the destination's own units can end up inside the restored
            -- terrain (the surface shape changed under them) -- dig them out
            for _, u in ipairs(df.global.world.units.active) do
                local tt = dfhack.maps.getTileType(u.pos.x, u.pos.y, u.pos.z)
                if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.WALL then
                    local moved = false
                    for z = u.pos.z + 1, df.global.world.map.z_count - 2 do
                        local t2 = dfhack.maps.getTileType(u.pos.x, u.pos.y, z)
                        if t2 and df.tiletype.attrs[t2].shape ~= df.tiletype_shape.WALL then
                            dfhack.units.teleport(u, xyz2pos(u.pos.x, u.pos.y, z))
                            moved = true
                            break
                        end
                    end
                    if not moved and ctx.spawn_anchor then
                        dfhack.units.teleport(u, ctx.spawn_anchor)
                    end
                    common.add_skip(ctx, 'unit-unstuck-from-wall')
                end
            end
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
