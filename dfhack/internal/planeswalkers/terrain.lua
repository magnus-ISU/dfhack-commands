-- Terrain save/load for fort/planeswalkers: packed tile records, vein/material
-- capture, constructions. Chunked via common.lua's pipeline driver.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local tiletypes = require('plugins.tiletypes')
local tilemat = require('tile-material')

-- trees and shrubs are world-local plant instances that cannot cross; their
-- tiles degrade to what is underneath
local PLANT_MATS = {
    [df.tiletype_material.TREE] = true,
    [df.tiletype_material.MUSHROOM] = true,
    [df.tiletype_material.ROOT] = true,
    [df.tiletype_material.PLANT] = true,
}

-- grass DOES cross: the tiletype is generic (GrassLightFloor1 &c) and the plant
-- behind it is a per-block block_square_event_grassst, saved to grass.bin. This
-- covers surface grass and the subterranean grasses alike -- cave moss, floor
-- fungi and underlichen are all [GRASS] plant raws, so a cavern floor carries
-- its moss over the same way a meadow carries its bentgrass.
local GRASS_MATS = {
    [df.tiletype_material.GRASS_LIGHT] = true,
    [df.tiletype_material.GRASS_DARK] = true,
    [df.tiletype_material.GRASS_DRY] = true,
    [df.tiletype_material.GRASS_DEAD] = true,
}

local BROOK_TILE_IDS = {}
for _, name in ipairs({'BrookS', 'BrookTop1', 'BrookTop2', 'BrookTop3', 'BrookTop4'}) do
    local id = df.tiletype[name]
    if id ~= nil then BROOK_TILE_IDS[id] = true end
end

local function is_brook_tile(tt)
    return tt ~= nil and BROOK_TILE_IDS[tt] == true
end

-- Coordinate keys are used by load_block() before the later magma-phase
-- declarations in this module. Keep these helpers above their first closure
-- so Lua captures the local functions instead of resolving nil globals.
local function block_key(bx, by, z)
    return ('%d:%d:%d'):format(bx, by, z)
end

local function tile_key(x, y, z)
    return ('%d:%d:%d'):format(x, y, z)
end


-- Remove world-local claims from a tile whose terrain identity is being
-- replaced. Mineral event bitmasks can otherwise keep assigning an old
-- destination material to the new tile after the restore finishes.
local function clear_tile_claims(block, x, y)
    local d = block.designation[x][y]
    d.feature_global = false
    d.feature_local = false
    for _, ev in ipairs(block.block_events) do
        if df.block_square_event_mineralst:is_instance(ev) then
            dfhack.maps.setTileAssignment(ev.tile_bitmask, x, y, false)
        end
    end
end

local function refresh_block_feature_refs(block)
    local has_global, has_local = false, false
    for x = 0, 15 do
        for y = 0, 15 do
            local d = block.designation[x][y]
            if d.feature_global then has_global = true end
            if d.feature_local then has_local = true end
            if has_global and has_local then break end
        end
        if has_global and has_local then break end
    end
    if not has_global then
        block.global_feature = -1
        block.global_feature_sq = -1
    end
    if not has_local then block.local_feature = -1 end
end

local function inorganic_token(idx)
    local raw = df.global.world.raws.inorganics.all[idx]
    return raw and ('INORGANIC:' .. raw.id) or nil
end

-- Tile record flag bits (the 7th byte of common.TILE_REC). The unused
-- upper five bits preserve mineral inclusion type, lava-stone provenance,
-- and the source event's discovery state without changing the snapshot format.
local TF_SOIL = 1
local TF_TUBE = 2
local TF_STONE_PAINT = 4
local TF_VEIN_TYPE_SHIFT = 3
local TF_VEIN_TYPE_MASK = 0x38
local TF_LAVA_STONE = 0x40
local TF_VEIN_DISCOVERED = 0x80

local VEIN_CLUSTER = 0
local VEIN = 1
local VEIN_CLUSTER_SMALL = 2
local VEIN_CLUSTER_ONE = 3
local VEIN_UNSPECIFIED = 4

-- is this block's local feature an adamantine spire ("deep special tube")?
-- Local features are indexed per world tile, so the lookup goes through the
-- block's own region_pos. Cached per (region, index).
function block_is_tube(ctx, block)
    local lf = block.local_feature
    if lf < 0 then return false end
    local key = block.region_pos.x .. ':' .. block.region_pos.y .. ':' .. lf
    ctx.tube_lf = ctx.tube_lf or {}
    local v = ctx.tube_lf[key]
    if v == nil then
        local ok, init = pcall(dfhack.maps.getLocalInitFeature, block.region_pos, lf)
        v = ok and init ~= nil and df.feature_init_deep_special_tubest:is_instance(init)
            or false
        ctx.tube_lf[key] = v
    end
    return v
end

-- the map rectangle (tiles, inclusive-exclusive) the sampling scans cover:
-- the whole map unless a footprint was given
local function scan_rect(rect)
    local map = df.global.world.map
    if rect then return rect.x, rect.y, rect.x + rect.w, rect.y + rect.h end
    return 0, 0, map.x_count, map.y_count
end

-- Return the highest Z-level registered to the magma-core global feature.
-- Do not search for arbitrary magma liquid: workshops and channels can occur
-- far above the sea. Use the block's feature registration rather than its
-- remaining liquid, so draining the sea does not move the boundary downward.
local function magma_feature_idx()
    local features = df.global.world.features
    local magma_gidx
    for i = 0, #features.map_features - 1 do
        local init = features.map_features[i]
        if df.feature_init_magma_core_from_layerst:is_instance(init) then
            magma_gidx = features.feature_global_idx[i]
            break
        end
    end
    return magma_gidx
end

function find_magma_top_z(rect)
    local map = df.global.world.map
    local magma_gidx = magma_feature_idx()
    if magma_gidx == nil or magma_gidx < 0 then return -1 end

    local x0, y0, x1, y1 = scan_rect(rect)
    local bx0 = math.max(0, x0 // 16)
    local by0 = math.max(0, y0 // 16)
    local bx1 = math.min(map.x_count_block, (x1 + 15) // 16)
    local by1 = math.min(map.y_count_block, (y1 + 15) // 16)
    for z = map.z_count - 1, 0, -1 do
        for by = by0, by1 - 1 do
            for bx = bx0, bx1 - 1 do
                local block = dfhack.maps.getBlock(bx, by, z)
                if block and block.global_feature == magma_gidx then
                    return z
                end
            end
        end
    end
    return -1
end

-- Lowest block registered to the magma core. Keeping this bound in the
-- surface-alignment calculation prevents the imported sea from being clipped
-- at the bottom when the destination surface is substantially lower.
function find_magma_bottom_z(rect)
    local map = df.global.world.map
    local magma_gidx = magma_feature_idx()
    if magma_gidx == nil or magma_gidx < 0 then return -1 end
    local x0, y0, x1, y1 = scan_rect(rect)
    local bx0 = math.max(0, x0 // 16)
    local by0 = math.max(0, y0 // 16)
    local bx1 = math.min(map.x_count_block, (x1 + 15) // 16)
    local by1 = math.min(map.y_count_block, (y1 + 15) // 16)
    for z = 0, map.z_count - 1 do
        for by = by0, by1 - 1 do
            for bx = bx0, bx1 - 1 do
                local block = dfhack.maps.getBlock(bx, by, z)
                if block and block.global_feature == magma_gidx then return z end
            end
        end
    end
    return -1
end

-- the hell ceiling: the world's bottom is slade floor, then the open
-- underworld (demons!), capped by a semi-molten-rock ceiling, with the magma
-- sea band above that. The magma boundary is detected separately and neither
-- source nor destination magma levels are overwritten. Nothing may ever open
-- a path into the underworld: one open tile punched through its ceiling
-- releases the destination's demons.
-- Per column the ceiling is the first semi-molten tile scanning UP from the
-- bottom; it undulates several z across the map, so return both extremes:
-- everything at or below the LOWEST sampled ceiling is hard off-limits, and
-- the band up to the HIGHEST needs per-tile care (see load_block).
-- Returns max_ceiling_z, min_ceiling_z (-1, -1 if the world has no deep).
function find_deep_top_z(rect)
    local map = df.global.world.map
    local maxc, minc = -1, math.huge
    local x0, y0, x1, y1 = scan_rect(rect)
    for x = x0 + 8, x1 - 1, 16 do
        for y = y0 + 8, y1 - 1, 16 do
            for z = 0, math.min(map.z_count - 1, 80) do
                local tt = dfhack.maps.getTileType(x, y, z)
                if tt == df.tiletype.SemiMoltenRock then
                    if z > maxc then maxc = z end
                    if z < minc then minc = z end
                    break
                end
            end
        end
    end
    if maxc < 0 then return -1, -1 end
    return maxc, minc
end

-- median of sampled highest-non-empty z: the cross-world alignment anchor
function find_surface_z(rect)
    local map = df.global.world.map
    local zs = {}
    local x0, y0, x1, y1 = scan_rect(rect)
    for x = x0 + 8, x1 - 1, 16 do
        for y = y0 + 8, y1 - 1, 16 do
            for z = map.z_count - 2, 0, -1 do
                local tt = dfhack.maps.getTileType(x, y, z)
                if tt then
                    local a = df.tiletype.attrs[tt]
                    local m = a.material
                    if a.shape ~= df.tiletype_shape.EMPTY
                        and m ~= df.tiletype_material.TREE
                        and m ~= df.tiletype_material.ROOT
                        and m ~= df.tiletype_material.PLANT
                        and m ~= df.tiletype_material.MUSHROOM
                        and m ~= df.tiletype_material.CONSTRUCTION then
                        table.insert(zs, z)
                        break
                    end
                end
            end
        end
    end
    table.sort(zs)
    return zs[math.max(1, #zs // 2)] or 0
end

-- Highest occupied tile anywhere inside the footprint. Unlike find_surface_z,
-- this deliberately uses the maximum rather than the median: it is used to
-- ensure Z-preserving placement does not clip the fortress roof/mountain peaks.
function find_highest_nonempty_z(rect)
    local map = df.global.world.map
    local x0, y0, x1, y1 = scan_rect(rect)
    local bx0 = math.max(0, x0 // 16)
    local by0 = math.max(0, y0 // 16)
    local bx1 = math.min(map.x_count_block, (x1 + 15) // 16)
    local by1 = math.min(map.y_count_block, (y1 + 15) // 16)

    for z = map.z_count - 2, 1, -1 do
        for by = by0, by1 - 1 do
            for bx = bx0, bx1 - 1 do
                local block = dfhack.maps.getBlock(bx, by, z)
                if block then
                    for x = 0, 15 do
                        local col = block.tiletype[x]
                        for y = 0, 15 do
                            local tt = col[y]
                            local attrs = df.tiletype.attrs[tt]
                            if attrs and attrs.shape ~= df.tiletype_shape.EMPTY then
                                return z
                            end
                        end
                    end
                end
            end
        end
    end
    return 1
end

-- Older magma-cutoff snapshots do not have dims.top_z. Recover the value from
-- their packed terrain stream so they can be restored without requiring a new
-- snapshot. The tiletype index is the first I2 in each 7-byte tile record.
local function snapshot_highest_nonempty_z(src_dims, dir, legend_tt)
    local f = io.open(dir .. '/tiles.bin', 'rb')
    if not f then return nil end
    f:read(common.HEADER_SIZE)
    local per_z = src_dims.bx * src_dims.by
    local slab_size = common.BLOCK_SIZE * per_z

    for z = src_dims.bz - 1, 0, -1 do
        f:seek('set', common.HEADER_SIZE + z * slab_size)
        local slab = f:read(slab_size)
        if not slab then break end
        for off = 1, #slab, common.TILE_REC_SIZE do
            local tt_idx = string.unpack('<I2', slab, off)
            if tt_idx ~= 0 then
                local token = legend_tt:get(tt_idx)
                local tt = token and df.tiletype[token]
                local attrs = tt and df.tiletype.attrs[tt]
                if attrs and attrs.shape ~= df.tiletype_shape.EMPTY then
                    f:close()
                    return z
                end
            end
        end
    end
    f:close()
    return nil
end

-- Resolve the actual geological region for this tile. Map blocks can contain
-- several biomes; block.region_pos alone is not enough. The DFHack API maps the
-- tile's designation.biome through region_offset before returning its region.
local function tile_geo_context(ctx, block, x, y, z)
    if not block then return nil end
    local d = block.designation[x % 16][y % 16]
    ctx.tile_geo_cache = ctx.tile_geo_cache or {}
    local bkey = block.map_pos.x .. ':' .. block.map_pos.y .. ':' .. z .. ':' .. d.biome
    local cached = ctx.tile_geo_cache[bkey]
    if cached ~= nil then return cached or nil end

    local ok, rx, ry = pcall(dfhack.maps.getTileBiomeRgn, xyz2pos(x, y, z))
    if not ok or rx == nil or ry == nil then
        ctx.tile_geo_cache[bkey] = false
        return nil
    end
    local region_ok, region = pcall(dfhack.maps.getRegionBiome, rx, ry)
    if not region_ok or not region then
        ctx.tile_geo_cache[bkey] = false
        return nil
    end

    ctx.lava_stone_cache = ctx.lava_stone_cache or {}
    local rkey = rx .. ':' .. ry
    local lava_stone = ctx.lava_stone_cache[rkey]
    if lava_stone == nil then
        lava_stone = false
        for _, detail in ipairs(df.global.world.world_data.midmap_data.region_details) do
            if detail.pos.x == rx and detail.pos.y == ry then
                lava_stone = detail.lava_stone
                break
            end
        end
        ctx.lava_stone_cache[rkey] = lava_stone
    end

    local geo_index = region.geo_index
    local info = {
        rx = rx, ry = ry, geo_index = geo_index,
        geo = geo_index ~= nil and df.world_geo_biome.find(geo_index) or nil,
        lava_stone = lava_stone ~= false and lava_stone or nil,
    }
    ctx.tile_geo_cache[bkey] = info
    return info
end

-- Layer material for a specific tile. Returns token, is_soil, material index.
-- Mineral events are deliberately ignored: this reads only the underlying
-- geological layer selected by the tile's own biome and geolayer index.
local function layer_mat_token(ctx, block, x, y, z)
    if not block then return nil end
    local info = tile_geo_context(ctx, block, x, y, z)
    if not info or not info.geo then return nil end
    local geolayer = block.designation[x % 16][y % 16].geolayer_index
    local key = info.rx .. ':' .. info.ry .. ':' .. geolayer
    ctx.layer_cache = ctx.layer_cache or {}
    local hit = ctx.layer_cache[key]
    if hit ~= nil then
        if hit then return hit.tok, hit.soil, hit.midx end
        return nil
    end
    local layer = info.geo.layers[geolayer]
    if not layer then
        ctx.layer_cache[key] = false
        return nil
    end
    local midx = layer.mat_index
    local tok = inorganic_token(midx)
    local raw = df.global.world.raws.inorganics.all[midx]
    local soil = raw and raw.flags.SOIL and true or false
    ctx.layer_cache[key] = tok and {tok = tok, soil = soil, midx = midx} or false
    return tok, soil, midx
end

local function lava_stone_material(ctx, block, x, y, z)
    local info = tile_geo_context(ctx, block, x, y, z)
    if not info then return nil end
    return info.lava_stone
end

-- ---- save ------------------------------------------------------------------

local function vein_grid(block)
    -- Capture the same material winner as tile-material.GetVeinMat(): cluster,
    -- vein, small cluster, one-tile cluster, then untyped; the last event wins
    -- equal-priority ties. Preserve the winning event's inclusion flags and
    -- discovery state separately from its material priority.
    local grid, types, discovered, priorities
    for _, ev in ipairs(block.block_events) do
        if df.block_square_event_mineralst:is_instance(ev) then
            local priority
            if ev.flags.cluster then priority = 1
            elseif ev.flags.vein then priority = 2
            elseif ev.flags.cluster_small then priority = 3
            elseif ev.flags.cluster_one then priority = 4
            else priority = 5 end

            local code
            if ev.flags.cluster_small then code = VEIN_CLUSTER_SMALL
            elseif ev.flags.cluster_one then code = VEIN_CLUSTER_ONE
            elseif ev.flags.vein then code = VEIN
            elseif ev.flags.cluster then code = VEIN_CLUSTER
            else code = VEIN_UNSPECIFIED end

            for x = 0, 15 do
                for y = 0, 15 do
                    if dfhack.maps.getTileAssignment(ev.tile_bitmask, x, y) then
                        local k = x * 16 + y
                        if not priorities or not priorities[k] or priority >= priorities[k] then
                            grid = grid or {}
                            types = types or {}
                            discovered = discovered or {}
                            priorities = priorities or {}
                            grid[k] = ev.inorganic_mat
                            types[k] = code
                            discovered[k] = ev.flags.discovered and true or false
                            priorities[k] = priority
                        end
                    end
                end
            end
        end
    end
    return grid, types, discovered
end

-- one grass.bin record per grass event in this block that actually covers
-- something (worldgen leaves plenty of all-zero events behind)
local function save_grass(ctx, block, bx, by, z)
    if not ctx.grass_f then return end
    for _, ev in ipairs(block.block_events) do
        if df.block_square_event_grassst:is_instance(ev) then
            local pr = df.plant_raw.find(ev.plant_index)
            if pr then
                local rows, any = {}, false
                for x = 0, 15 do
                    local col = ev.amount[x]
                    local row = {}
                    for y = 0, 15 do
                        local a = col[y]
                        if a > 0 then any = true end
                        row[y + 1] = a
                    end
                    rows[x + 1] = string.char(table.unpack(row))
                end
                if any then
                    ctx.grass_f:write(string.pack(common.GRASS_REC, bx, by, z,
                        ctx.legend_plant:intern(pr.id),
                        math.max(0, math.min(255, pr.underground_depth_min))))
                    ctx.grass_f:write(table.concat(rows))
                    ctx.grass_count = (ctx.grass_count or 0) + 1
                end
            end
        end
    end
end

-- Preserve both DF temperature grids. temperature_1 is the current tile
-- temperature and temperature_2 is its normal/base temperature.
local function save_heat_block(block)
    if not block then return common.ZERO_HEAT_BLOCK end
    local out = {}
    for x = 0, 15 do
        local c1, c2 = block.temperature_1[x], block.temperature_2[x]
        for y = 0, 15 do
            out[#out + 1] = string.pack(common.HEAT_REC, c1[y], c2[y])
        end
    end
    return table.concat(out)
end

-- bx/by/z are ABSOLUTE block coords in this map; grass records (and the
-- caller's tile records) are stored relative to the snapshot footprint
local function save_block(ctx, block, bx, by, z, include_magma)
    -- Only magma-core blocks are kept out of the ordinary terrain stream.
    -- Lower non-magma blocks (caverns, rock, and fortress terrain) still need
    -- to be copied even when they share Z-levels with the magma sea.
    if not include_magma and block and ctx.source_magma_gidx
        and block.global_feature == ctx.source_magma_gidx then
        return common.ZERO_BLOCK
    end
    if not block then return common.ZERO_BLOCK end
    local o = ctx.origin
    if not include_magma then save_grass(ctx, block, bx - o.bx, by - o.by, z) end
    -- Mineral event grids are expensive to build. Most blocks have no mineral
    -- tiletypes, so defer the scan until one is actually encountered.
    local veins, vein_types, vein_discovered
    local recs = {}
    local surface = ctx.manifest.dims.surface
    -- a spire's tiles are flagged so the loader can rebuild the feature
    -- around exactly them, hollow core and all
    local tube = block_is_tube(ctx, block)
    for x = 0, 15 do
        local ttcol, dscol = block.tiletype[x], block.designation[x]
        for y = 0, 15 do
            local tt = ttcol[y]
            local d = dscol[y]
            local attrs = df.tiletype.attrs[tt]
            local mat_cat = attrs.material
            local tt_out, mat_idx, flags = tt, 0, 0
            if tube and d.feature_local then flags = TF_TUBE end
            if GRASS_MATS[mat_cat] then
                -- keep the grass tiletype as it stands (grass.bin carries the
                -- plant behind it) and pin the soil under it the same way a
                -- bare soil tile is pinned -- but ONLY when the layer really is
                -- soil, because a non-soil pin takes the vein-paint path, which
                -- would repaint the tile as plain stone and eat the grass
                local tok, is_soil = layer_mat_token(ctx, block, bx * 16 + x, by * 16 + y, z)
                if tok and is_soil then
                    mat_idx = ctx.legend_mat:intern(tok)
                    flags = flags | TF_SOIL
                end
            elseif PLANT_MATS[mat_cat] then
                local shape = attrs.shape
                if mat_cat == df.tiletype_material.TREE
                    or mat_cat == df.tiletype_material.ROOT
                    or mat_cat == df.tiletype_material.MUSHROOM then
                    -- Keep trunk/root geometry as a safe fallback. The plants
                    -- phase rebuilds the live plant object and exact tree layout.
                    -- Degrading these tiles to OpenSpace caused surface holes
                    -- and unsupported terrain when plant creation failed.
                    tt_out = tt
                elseif shape == df.tiletype_shape.FLOOR or shape == df.tiletype_shape.SAPLING
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
                    local tok, is_soil = layer_mat_token(ctx, block, bx * 16 + x, by * 16 + y, z)
                    if tok and is_soil then
                        mat_idx = ctx.legend_mat:intern(tok)
                        flags = flags | TF_SOIL
                    end
                elseif mat_cat == df.tiletype_material.MINERAL then
                    if not veins then
                        veins, vein_types, vein_discovered = vein_grid(block)
                    end
                    if veins and veins[k] ~= nil then
                        local tok = inorganic_token(veins[k])
                        if tok then
                            mat_idx = ctx.legend_mat:intern(tok)
                            local code = vein_types[k] or VEIN_CLUSTER
                            flags = flags | (code << TF_VEIN_TYPE_SHIFT)
                            if vein_discovered[k] then flags = flags | TF_VEIN_DISCOVERED end
                        else
                            common.add_skip(ctx, 'mineral-material-unresolved',
                                ('%d,%d,%d'):format(bx * 16 + x, by * 16 + y, z))
                        end
                    else
                        common.add_skip(ctx, 'mineral-event-missing-material',
                            ('%d,%d,%d'):format(bx * 16 + x, by * 16 + y, z))
                    end
                elseif mat_cat == df.tiletype_material.LAVA_STONE then
                    local lava_idx = lava_stone_material(ctx, block,
                        bx * 16 + x, by * 16 + y, z)
                    local tok = lava_idx ~= nil and inorganic_token(lava_idx) or nil
                    if tok then
                        mat_idx = ctx.legend_mat:intern(tok)
                        flags = flags | TF_LAVA_STONE
                    else
                        common.add_skip(ctx, 'lava-stone-material-unresolved',
                            ('%d,%d,%d'):format(bx * 16 + x, by * 16 + y, z))
                    end
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
                elseif mat_cat == df.tiletype_material.STONE then
                    -- Read the material DF currently resolves for this tile,
                    -- rather than trusting a possibly stale source geolayer
                    -- index. The destination receives an explicit tiletypes
                    -- stone-material assignment, including hidden stone, so
                    -- later reveals cannot expose unrelated destination geology.
                    local wx, wy = bx * 16 + x, by * 16 + y
                    local tok
                    local ok, mi = pcall(tilemat.GetTileMat, wx, wy, z)
                    if ok and mi then
                        local ok_token, resolved = pcall(function() return mi:getToken() end)
                        if ok_token then tok = resolved end
                    end
                    if not tok then
                        tok = layer_mat_token(ctx, block, wx, wy, z)
                    end
                    if tok then
                        mat_idx = ctx.legend_mat:intern(tok)
                        flags = flags | TF_STONE_PAINT
                    else
                        common.add_skip(ctx, 'stone-material-unresolved',
                            ('%d,%d,%d'):format(wx, wy, z))
                    end
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
    local o = ctx.origin
    local nb = o.wb * o.hb * map.z_count_block
    local phases = {}

    table.insert(phases, {
        name = 'terrain',
        init = function(job)
            ctx.layer_cache = {}
            -- The magma sea is a worldgen feature, not fortress terrain. Keep
            -- the fixed-size tile stream indexed, but write empty records for
            -- every source level at or below its upper boundary.
            ctx.deep_top = select(2, find_deep_top_z(o))
            ctx.manifest.dims.deep_top = ctx.deep_top
            ctx.source_magma_top = ctx.source_magma_top or find_magma_top_z(o)
            if ctx.source_magma_top < 0 then
                qerror('planeswalkers: could not identify the source magma sea; refusing to save an unsafe snapshot')
            end
            ctx.source_magma_min = ctx.source_magma_min or find_magma_bottom_z(o)
            if ctx.source_magma_min < 0 then
                qerror('planeswalkers: could not identify the bottom of the source magma sea')
            end
            ctx.manifest.dims.magma_top = ctx.source_magma_top
            ctx.manifest.dims.magma_min = ctx.source_magma_min
            ctx.source_magma_gidx = magma_feature_idx()
            if not ctx.source_magma_gidx or ctx.source_magma_gidx < 0 then
                qerror('planeswalkers: source magma feature index is unavailable')
            end
            local function open_output(filename)
                local f, err = io.open(ctx.dir .. '/' .. filename, 'wb')
                if not f then qerror(('planeswalkers: cannot create %s: %s')
                    :format(filename, tostring(err))) end
                return f
            end
            ctx.tiles_f = open_output('tiles.bin')
            ctx.grass_f = open_output('grass.bin')
            ctx.magma_f = open_output('magma.bin')
            ctx.heat_f = open_output('heat.bin')
            -- header flag bit 0: tile records carry TF_TUBE; bit 1: designation
            -- bits carry flow_forbid; bit 2: they carry water_table (aquifer)
            ctx.tiles_f:write(string.pack(common.HEADER_FMT, 'PWT1',
                o.wb, o.hb, map.z_count_block,
                ctx.manifest.dims.surface, 7))
            ctx.magma_f:write(string.pack(common.HEADER_FMT, 'PWM1',
                o.wb, o.hb, map.z_count_block,
                ctx.manifest.dims.surface, 7))
            ctx.heat_f:write(string.pack(common.HEADER_FMT, 'PWH1',
                o.wb, o.hb, map.z_count_block,
                ctx.manifest.dims.surface, 1))
            ctx.magma_block_count = 0
            job.block_cursor = 0
        end,
        total = function() return nb end,
        pos = function(job) return job.block_cursor end,
        step = function(job, deadline)
            local bw, bh = o.wb, o.hb
            while job.block_cursor < nb do
                local i = job.block_cursor
                local z = i // (bw * bh)
                local by = (i % (bw * bh)) // bw + o.by
                local bx = i % bw + o.bx
                local block = dfhack.maps.getBlock(bx, by, z)
                ctx.tiles_f:write(save_block(ctx, block, bx, by, z))
                ctx.heat_f:write(save_heat_block(block))
                -- The magma core is saved sparsely and independently from the
                -- ordinary terrain stream. A block record preserves its exact
                -- tile geometry, material references, liquid depth and static
                -- flow flags. The sparse index is the block's z-major offset.
                if block and block.global_feature == ctx.source_magma_gidx then
                    ctx.magma_f:write(string.pack('<I4', i))
                    ctx.magma_f:write(save_block(ctx, block, bx, by, z, true))
                    ctx.magma_block_count = ctx.magma_block_count + 1
                end
                job.block_cursor = i + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.tiles_f:close()
            ctx.tiles_f = nil
            ctx.grass_f:close()
            ctx.grass_f = nil
            ctx.magma_f:close()
            ctx.magma_f = nil
            ctx.heat_f:close()
            ctx.heat_f = nil
            if (ctx.magma_block_count or 0) < 1 then
                qerror('planeswalkers: no source magma-core blocks were captured; refusing to write a loadable-looking snapshot')
            end
            if ctx.plant_degraded and ctx.plant_degraded > 0 then
                common.add_skip(ctx, 'plant-tiles-degraded (regrow naturally)', nil)
                ctx.skips['plant-tiles-degraded (regrow naturally)'].n = ctx.plant_degraded
            end
            ctx.manifest.counts.grass = ctx.grass_count or 0
            ctx.manifest.counts.magma_blocks = ctx.magma_block_count or 0
            ctx.manifest.complete.grass = true
            ctx.manifest.complete.magma = (ctx.magma_block_count or 0) > 0
            ctx.manifest.complete.heat = true
            ctx.manifest.counts.heat_blocks = nb
            ctx.manifest.complete.terrain = true
            return true
        end,
    })

    table.insert(phases, {
        name = 'constructions',
        step = function(job)
            local out = {v = 1, list = {}}
            local o = ctx.origin
            for _, c in ipairs(df.global.world.event.constructions) do
                local mi = dfhack.matinfo.decode(c.mat_type, c.mat_index)
                if not common.in_footprint(ctx, c.pos.x, c.pos.y)
                    or c.pos.z < (ctx.source_magma_min or 1) then goto continue end
                table.insert(out.list, {
                    x = c.pos.x - o.x, y = c.pos.y - o.y, z = c.pos.z,
                    item_type = df.item_type[c.item_type],
                    item_subtype = c.item_subtype,
                    mat = mi and mi:getToken() or nil,
                    original_tile = df.tiletype[c.original_tile],
                })
                ::continue::
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

-- Validate the sparse magma snapshot before a restore starts changing the
-- destination map. This catches truncated files, mismatched dimensions and
-- duplicate/out-of-range block indices while rollback is still unnecessary.
function validate_magma_snapshot(dir, manifest)
    local path = dir .. '/magma.bin'
    local f = io.open(path, 'rb')
    if not f then return false, 'source magma file is missing or unreadable' end
    local ok, err = pcall(function()
        local header = f:read(common.HEADER_SIZE)
        if not header or #header ~= common.HEADER_SIZE then
            error('source magma file has a truncated header')
        end
        local magic, bx, by, bz = string.unpack(common.HEADER_FMT, header)
        if magic ~= 'PWM1' then error('source magma file has an invalid header') end
        local dims = manifest.dims or {}
        if bx ~= dims.bx or by ~= dims.by or bz ~= dims.bz then
            error('source magma dimensions do not match the snapshot manifest')
        end
        if type(dims.magma_min) ~= 'number' or type(dims.magma_top) ~= 'number'
            or dims.magma_min < 0 or dims.magma_top < dims.magma_min then
            error('snapshot manifest has invalid source magma Z boundaries')
        end
        local count = manifest.counts and manifest.counts.magma_blocks
        if type(count) ~= 'number' or count < 1 then
            error('snapshot manifest has no source magma block records')
        end
        local expected_size = common.HEADER_SIZE + count * (4 + common.BLOCK_SIZE)
        local actual_size = f:seek('end')
        if actual_size ~= expected_size then
            error(('source magma file size mismatch (expected %d bytes, found %d)')
                :format(expected_size, actual_size or -1))
        end
        local last = -1
        for i = 0, count - 1 do
            f:seek('set', common.HEADER_SIZE + i * (4 + common.BLOCK_SIZE))
            local raw = f:read(4)
            if not raw or #raw ~= 4 then error('source magma file has a truncated block index') end
            local index = string.unpack('<I4', raw)
            if index <= last or index >= bx * by * bz then
                error('source magma file has duplicate, unordered or out-of-range block indices')
            end
            last = index
        end
    end)
    f:close()
    if not ok then return false, tostring(err) end
    return true
end

-- Validate the dense heat stream before modifying the destination. Older v4
-- snapshots remain readable, but they cannot restore source temperature grids.
function validate_heat_snapshot(dir, manifest)
    local path = dir .. '/heat.bin'
    local f = io.open(path, 'rb')
    if not f then return false, 'source heat file is missing or unreadable' end
    local ok, err = pcall(function()
        local header = f:read(common.HEADER_SIZE)
        if not header or #header ~= common.HEADER_SIZE then error('source heat file has a truncated header') end
        local magic, bx, by, bz = string.unpack(common.HEADER_FMT, header)
        local dims = manifest.dims or {}
        if magic ~= 'PWH1' then error('source heat file has an invalid header') end
        if not (manifest.complete and manifest.complete.heat) then
            error('snapshot manifest does not mark heat data as complete')
        end
        if (manifest.counts and manifest.counts.heat_blocks) ~= bx * by * bz then
            error('snapshot heat block count does not match its dimensions')
        end
        if bx ~= dims.bx or by ~= dims.by or bz ~= dims.bz then
            error('source heat dimensions do not match the snapshot manifest')
        end
        local expected = common.HEADER_SIZE + bx * by * bz * common.HEAT_BLOCK_SIZE
        local actual = f:seek('end')
        if actual ~= expected then
            error(('source heat file size mismatch (expected %d bytes, found %d)')
                :format(expected, actual or -1))
        end
    end)
    f:close()
    if not ok then return false, tostring(err) end
    return true
end

-- compute placement of the source volume in the destination map.
-- returns offsets in tiles (block-aligned horizontally) or nil, err.
    -- Keep source Z-levels whenever possible. Only shift DOWN when the source's
    -- highest occupied tile would exceed the destination map ceiling.
function compute_anchor(src_dims, dir, legend_tt, preserve_depths)
    local map = df.global.world.map
    if map.x_count_block < src_dims.bx or map.y_count_block < src_dims.by then
        return nil, ('destination embark (%dx%d blocks) is smaller than the source (%dx%d)')
            :format(map.x_count_block, map.y_count_block, src_dims.bx, src_dims.by)
    end
    -- Horizontal placement is centered. Preserve the source fortress's
    -- internal Z spacing, but align its median surface with the destination
    -- embark's median surface to avoid a sheer terrain transition.
    local off_bx = (map.x_count_block - src_dims.bx) // 2
    local off_by = (map.y_count_block - src_dims.by) // 2
    local dest_rect = {
        x = off_bx * 16, y = off_by * 16,
        w = src_dims.bx * 16, h = src_dims.by * 16,
    }
    local dest_surface = find_surface_z(dest_rect)
    local source_surface = tonumber(src_dims.surface) or 0
    -- Legacy snapshots without a recorded surface retain their historical
    -- absolute-Z placement rather than being rejected.
    local ideal_off_z = source_surface >= 1 and (dest_surface - source_surface) or 0

    -- Keep the complete transferred fortress inside the destination's legal
    -- Z range where possible. Surface alignment is preferred, but the volume
    -- can be shifted upward to preserve its lower magma boundary; do_load()
    -- requests additional sky levels if that makes the roof exceed the map.
    local source_top_z = src_dims.top_z
    if type(source_top_z) ~= 'number' or source_top_z < 1 then
        source_top_z = snapshot_highest_nonempty_z(src_dims, dir, legend_tt)
    end
    -- OpenSpace magma tiles have an EMPTY tile shape, so the highest occupied
    -- terrain scan can miss the top of the magma feature. Its registered block
    -- boundary must also fit inside the destination map ceiling.
    if type(src_dims.magma_top) == 'number' then
        source_top_z = math.max(source_top_z or 1, src_dims.magma_top)
    end
    if type(source_top_z) ~= 'number' or source_top_z < 1 then
        return nil, 'could not determine the snapshot highest occupied Z-level; refusing a potentially clipped restore'
    end
    local dest_top_z = map.z_count - 2
    local max_off_z = dest_top_z - source_top_z
    local off_z = math.min(ideal_off_z, max_off_z)
    -- Do not reject a placement just because surface alignment would put the
    -- source magma floor below the map. Raise the complete origin volume to
    -- keep the magma floor in bounds; do_load() will then request extra top
    -- sky levels if this upward shift makes the roof exceed the map ceiling.
    if type(src_dims.magma_min) == 'number' and src_dims.magma_min + off_z < 1 then
        off_z = 1 - src_dims.magma_min
    end
    local surface_shift = off_z - ideal_off_z

    return {
        off_x = off_bx * 16, off_y = off_by * 16,
        off_bx = off_bx, off_by = off_by,
        off_z = off_z,
        dest_surface = dest_surface,
        source_top_z = source_top_z,
        surface_shift = surface_shift,
        full = false,
    }
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
            local layer = geo.layers[i]
            if layer.type == df.geo_layer_type.SOIL and layer.mat_index == midx then
                li = i
                break
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

-- Natural stone is restored through tiletypes_setTile() with an explicit
-- stone_material. Unlike geolayer_index, this creates/uses a tile-specific
-- mineral assignment when the destination's geological layer is different.
-- Geological layers are shared by every tile in a region biome and are not a
-- safe place to store imported per-tile stone identities.

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

-- this column's own hell ceiling (first semi-molten tile from the bottom),
-- cached; -1 = no ceiling found below the mixed band (adamantine spire tube
-- or the like) -- treated as "structure unknown, hands off"
local function column_ceiling(ctx, x, y)
    ctx.ceil_cache = ctx.ceil_cache or {}
    local k = x * 65536 + y
    local c = ctx.ceil_cache[k]
    if c == nil then
        c = -1
        for z = 0, (ctx.dest_deep_top or -1) + 1 do
            if dfhack.maps.getTileType(x, y, z) == df.tiletype.SemiMoltenRock then
                c = z
                break
            end
        end
        ctx.ceil_cache[k] = c
    end
    return c
end

-- cross-world spires ------------------------------------------------------
-- An adamantine spire is a "deep special tube" feature: the block points at
-- the feature (local_feature) and every tile of the spire -- the raw
-- adamantine and the hollow core alike -- carries designation.feature_local.
-- That registration is what makes DF treat a breach as THE breach: the
-- horde from below, the encased horror, the divine treasure and its guardian
-- all spawn off it. Two consequences for a transfer:
--   * the destination's own tubes must be DISARMED before the source's
--     terrain lands on them, or the moment an open source tile covers a
--     registered tube tile DF sees a breached spire and empties hell into the
--     fort (seen live: seven announcements and forty demons on load);
--   * the source's spires arrive as raw-adamantine FEATURE tiles with no
--     feature behind them, so they are re-registered onto the destination's
--     tube features (one per spire; extra spires get a freshly created tube),
--     and only then does digging into a carried spire do what it should.

local function spire_key(x, y, z) return (z * 4096 + y) * 4096 + x end
local function spire_unkey(k)
    return k % 4096, (k // 4096) % 4096, k // 4096 // 4096
end

local function mat_is_slade(ctx, mat_idx)
    ctx.slade_cache = ctx.slade_cache or {}
    local v = ctx.slade_cache[mat_idx]
    if v == nil then
        v = ctx.legend_mat:get(mat_idx) == 'INORGANIC:SLADE'
        ctx.slade_cache[mat_idx] = v
    end
    return v
end

-- note a source tile that is part of a spire. FEATURE-material tiles other
-- than slade are the spire's own adamantine; TF_TUBE-flagged tiles are
-- whatever the source's tube feature registered (hollow core included)
local function gather_spire_tile(ctx, x, y, z, tt, mat_idx, rflags)
    if ctx.no_spires then return false end  -- bisect: everything paints as a vein
    local is_feat = tt and mat_idx ~= 0
        and df.tiletype.attrs[tt].material == df.tiletype_material.FEATURE
        and not mat_is_slade(ctx, mat_idx)
    if is_feat then
        ctx.spire_feat[#ctx.spire_feat + 1] = string.pack('<I2I2I2I2I2', x, y, z, mat_idx, tt)
    end
    if rflags & 2 == 2 then
        ctx.spire_hint[#ctx.spire_hint + 1] = spire_key(x, y, z)
    end
    return is_feat
end

local function load_block(ctx, data, src_bx, src_by, src_z, heat_data)
    local anchor = ctx.anchor
    local z = src_z + anchor.off_z
    if z < 1 or z >= df.global.world.map.z_count - 1 then
        ctx.z_clipped = (ctx.z_clipped or 0) + 1
        return
    end
    if ctx.preserve_depths and z <= ctx.preserve_depths_cutoff then
        ctx.preserve_depths_blocks_skipped = (ctx.preserve_depths_blocks_skipped or 0) + 1
        return
    end
    local mixed = false
    if not ctx.anchor.full then
        -- The destination underworld is independently generated and must be
        -- protected tile by tile, even when source Z-levels are preserved.
        if z <= (ctx.dest_deep_min or -1) then
            -- at or below the lowest hell ceiling: never touched at all
            ctx.deep_clipped = (ctx.deep_clipped or 0) + 1
            return
        end
        -- the mixed band: above the lowest sampled ceiling but not safely
        -- above the highest (+1 margin for undulation the sampling missed);
        -- writes here go per-tile, strictly above each column's own ceiling
        mixed = z <= (ctx.dest_deep_top or -1) + 1
    end
    local bx, by = src_bx + anchor.off_bx, src_by + anchor.off_by
    local block = dfhack.maps.getBlock(bx, by, z)
        or dfhack.maps.ensureTileBlock(bx * 16, by * 16, z)
    if not block then
        ctx.no_block = (ctx.no_block or 0) + 1
        return
    end
    -- The destination magma feature remains native outside the imported
    -- footprint. Inside the footprint, origin terrain replaces destination
    -- magma blocks; magma.bin restores the complete origin sea afterwards as
    -- static, contained liquid without merging feature Z-bound grids.
    -- a destination spire under the incoming terrain: every tile the source
    -- writes leaves the tube's registration, so no source tile can ever read
    -- as a breach of a tube that no longer exists there
    local tube = block_is_tube(ctx, block)
    local zero_block = data == common.ZERO_BLOCK
    local open_space = df.tiletype.OpenSpace
    if zero_block and open_space == nil then
        qerror('planeswalkers: DF has no OpenSpace tiletype; cannot safely clear an empty origin block')
    end
    local off = 1
    local touched = false
    local block_has_aquifer = false
    local replaced_tiles = {}
    for x = 0, 15 do replaced_tiles[x] = {} end
    for x = 0, 15 do
        local ttcol, dscol = block.tiletype[x], block.designation[x]
        for y = 0, 15 do
            local tt_idx, mat_idx, dbits, rflags = string.unpack(common.TILE_REC, data, off)
            off = off + common.TILE_REC_SIZE
            local tt = zero_block and open_space or resolve_tt(ctx, tt_idx)
            -- The source's underworld shape is not copied into a destination
            -- with independently generated underworld geometry. Semi-molten
            -- rock still transfers as solid filler where the ceiling permits.
            if tt == df.tiletype.EeriePit and not ctx.anchor.full then
                ctx.deep_dropped = (ctx.deep_dropped or 0) + 1
                tt = nil
            end
            if tt and mixed then
                -- write only strictly ABOVE this column's own ceiling: the
                -- ceiling tile itself stays unmineable semi-molten rock and
                -- the hell interior below it is never entered
                local c = column_ceiling(ctx, bx * 16 + x, by * 16 + y)
                local fallback_ceiling = ctx.dest_footprint_deep_top or ctx.dest_deep_top or -1
                if (c >= 0 and z <= c + 1)
                    or (c < 0 and fallback_ceiling >= 0 and z <= fallback_ceiling + 1) then
                    ctx.hell_guarded = (ctx.hell_guarded or 0) + 1
                    tt = nil
                end
            end
            if tt then
                touched = true
                replaced_tiles[x][y] = true
                ttcol[y] = tt
                if heat_data then
                    local heat_off = (x * 16 + y) * common.HEAT_REC_SIZE + 1
                    local current_temp, normal_temp = string.unpack(common.HEAT_REC, heat_data, heat_off)
                    block.temperature_1[x][y] = current_temp
                    block.temperature_2[x][y] = normal_temp
                end
                local d = dscol[y]
                local bits = common.unpack_dsgn(dbits)
                -- This mode deliberately keeps the destination magma sea and
                -- does not rebuild source magma registrations. Strip any
                -- source magma liquid that happens to translate above the
                -- protected cutoff, or it would be an unregistered draining
                -- liquid in the imported area.
                if ctx.preserve_depths and bits.liquid_type == 1 then
                    if bits.flow_size > 0 then
                        ctx.preserve_depths_magma_tiles_skipped =
                            (ctx.preserve_depths_magma_tiles_skipped or 0) + 1
                    end
                    bits.flow_size = 0
                    bits.liquid_type = 0
                end
                d.flow_size = bits.flow_size
                d.liquid_type = bits.liquid_type
                d.hidden = bits.hidden
                d.subterranean = bits.subterranean
                d.light = bits.light
                d.outside = bits.outside
                d.water_stagnant = bits.water_stagnant
                d.water_salt = bits.water_salt
                d.flow_forbid = (ctx.src and (ctx.src.flags & 2 == 2)) and bits.flow_forbid or false
                -- Feature ownership is destination-world state. Imported tiles
                -- must not retain registrations that belonged to the old map.
                d.feature_global = false
                local had_local_feature = d.feature_local
                d.feature_local = false
                if tube and had_local_feature then
                    ctx.tube_disarmed = (ctx.tube_disarmed or 0) + 1
                end
                local world_x, world_y = bx * 16 + x, by * 16 + y
                local edge_x0, edge_y0 = anchor.off_x, anchor.off_y
                local edge_x1 = edge_x0 + ctx.manifest.dims.bx * 16 - 1
                local edge_y1 = edge_y0 + ctx.manifest.dims.by * 16 - 1
                local perimeter = world_x == edge_x0 or world_x == edge_x1
                    or world_y == edge_y0 or world_y == edge_y1
                if perimeter and not is_brook_tile(tt) then
                    -- Keep non-river edge liquids from spilling into the
                    -- larger destination or flowing over imported edge tiles.
                    d.flow_forbid = true
                end
                -- Initially contain imported magma, including local pools and
                -- channels. magma_restore_phase() later promotes only compatible
                -- magma-core tiles to the destination's native global feature.
                if not ctx.preserve_depths and bits.liquid_type == 1
                    and bits.flow_size > 0 then
                    d.flow_forbid = true
                    d.feature_global = false
                    ctx.source_magma_block_keys = ctx.source_magma_block_keys or {}
                    ctx.source_magma_block_keys[block_key(bx, by, z)] = true
                    ctx.source_magma_tile_keys = ctx.source_magma_tile_keys or {}
                    ctx.source_magma_tile_keys[tile_key(bx * 16 + x, by * 16 + y, z)] = true
                    ctx.magma_tiles_static = (ctx.magma_tiles_static or 0) + 1
                    if ctx.restoring_source_magma then
                        ctx.magma_tiles_restored = (ctx.magma_tiles_restored or 0) + 1
                    end
                end
                -- the aquifer is the source's, or none: the destination's own
                -- aquifer bits under an imported fort would flood its rooms
                if ctx.src.flags & 4 == 4 then d.water_table = bits.water_table
                else d.water_table = false end
                if d.water_table then block_has_aquifer = true end
                if bits.liquid_type == 1 and bits.flow_size > 0 and z > (ctx.magma_zmax or -1) then
                    ctx.magma_zmax = z
                end
                -- a spire's own adamantine is not painted as a vein here: the
                -- spires phase registers it on a tube feature and only paints
                -- what could not be registered
                local spire = gather_spire_tile(ctx, bx * 16 + x, by * 16 + y, z,
                                                tt, mat_idx, rflags)
                if mat_idx ~= 0 and not spire then
                    local rec = string.pack('<I2I2I2I2B', bx * 16 + x, by * 16 + y, z, mat_idx, rflags)
                    -- All non-soil material overrides, including ordinary
                    -- natural stone, use tile-specific material painting.
                    -- Never assign imported stone to a shared destination
                    -- geological layer.
                    ctx.paint_list[#ctx.paint_list + 1] = rec
                end
            end
        end
    end
    -- Remove destination mineral-event assignments from tiles whose geology
    -- was replaced. Leaving those bitmasks attached makes old and new mineral
    -- events compete for the same squares, which can look like rapid material
    -- flickering and can restore destination minerals over origin terrain.
    if touched then
        for _, ev in ipairs(block.block_events) do
            if df.block_square_event_mineralst:is_instance(ev) then
                for x = 0, 15 do
                    for y = 0, 15 do
                        if replaced_tiles[x][y] then
                            dfhack.maps.setTileAssignment(ev.tile_bitmask, x, y, false)
                        end
                    end
                end
            end
        end
    end
    -- Block feature indices are meaningful only while at least one tile still
    -- carries that registration. Preserve native registrations in mixed blocks;
    -- clear only stale block-level references with no remaining flagged tiles.
    local has_global, has_local = false, false
    for x = 0, 15 do
        for y = 0, 15 do
            local d = block.designation[x][y]
            if d.feature_global then has_global = true end
            if d.feature_local then has_local = true end
            if has_global and has_local then break end
        end
        if has_global and has_local then break end
    end
    if not has_global then
        block.global_feature = -1
        block.global_feature_sq = -1
    end
    if not has_local then block.local_feature = -1 end

    if tube then
        -- nothing of the destination's tube left in this block: unhook it
        local left = false
        for x = 0, 15 do
            local dscol = block.designation[x]
            for y = 0, 15 do
                if dscol[y].feature_local then left = true break end
            end
            if left then break end
        end
        if not left then block.local_feature = -1 end
    end
    if touched then
        block.flags.has_aquifer = block_has_aquifer
        block.flags.check_aquifer = block_has_aquifer
        -- the destination's own grass sat on terrain that no longer exists; left
        -- in place it would regrow through the imported fort (and colour tiles
        -- the source never had grass on). The grass phase writes the source's
        -- own coverage back over these blocks.
        for _, ev in ipairs(block.block_events) do
            if df.block_square_event_grassst:is_instance(ev) then
                for x = 0, 15 do
                    local col = ev.amount[x]
                    for y = 0, 15 do col[y] = 0 end
                end
            end
        end
        dfhack.maps.enableBlockUpdates(block, false, true)
    end
end

-- destination plant index for a saved grass legend entry. A world that never
-- generated the exact plant gets the closest local grass of the same depth band
-- (surface vs cavern layer), so imported moss stays moss.
local function resolve_plant(ctx, idx, depth)
    local hit = ctx.plant_cache[idx]
    if hit ~= nil then return hit or nil end
    local id = ctx.legend_plant:get(idx)
    local pi = id and ctx.plant_by_id[id]
    if not pi then
        local same_band
        for _, g in ipairs(ctx.grass_plants) do
            if g.depth == depth then pi = g.idx break end
            if not same_band and (g.depth > 0) == (depth > 0) then same_band = g.idx end
        end
        pi = pi or same_band
        common.add_skip(ctx, pi and 'grass-plant-substituted'
                                or 'grass-plant-missing-in-world', id)
    end
    ctx.plant_cache[idx] = pi or false
    return pi
end

local function apply_grass(ctx, bx, by, src_z, plant_index, amounts)
    local a = ctx.anchor
    local z = src_z + a.off_z
    if z < 1 or z >= df.global.world.map.z_count - 1 then return end
    if not common.above_transfer_cutoff(ctx, z) then return end
    if not a.full and z <= (ctx.dest_deep_min or -1) then return end
    local block = dfhack.maps.getBlock(bx + a.off_bx, by + a.off_by, z)
    if not block then return end
    local ev
    for _, e in ipairs(block.block_events) do
        if df.block_square_event_grassst:is_instance(e) and e.plant_index == plant_index then
            ev = e
            break
        end
    end
    if not ev then
        ev = df.block_square_event_grassst:new()
        ev.plant_index = plant_index
        block.block_events:insert('#', ev)
    end
    -- merge rather than assign: two source grasses can substitute onto the same
    -- destination plant, and the second must not erase the first's coverage
    local i = 1
    for x = 0, 15 do
        local col = ev.amount[x]
        for y = 0, 15 do
            local a = amounts:byte(i)
            if a > col[y] then col[y] = a end
            i = i + 1
        end
    end
end

-- the destination's tube features: {init=, local_idx=, cell='wx:wy'}
local function dest_tubes()
    local out = {}
    local fl = df.global.world.features
    for i = 0, #fl.map_features - 1 do
        local init = fl.map_features[i]
        if df.feature_init_deep_special_tubest:is_instance(init) then
            local cell
            local f = init.feature
            if f and #f.embark_pos.x > 0 then
                cell = (f.embark_pos.x[0] // 16) .. ':' .. (f.embark_pos.y[0] // 16)
            end
            table.insert(out, {init = init, local_idx = fl.feature_local_idx[i], cell = cell})
        end
    end
    return out
end

-- mint a new tube feature in the world tile `wx,wy` (modelled on `template`
-- when one exists) and register it on this map; returns {init, local_idx}
local function create_tube(wx, wy, template)
    local wd = df.global.world.world_data
    local shell = wd.feature_map[wx // 16]:_displace(wy // 16)
    if not shell.features then return nil, 'no feature map for the world tile' end
    local vec = shell.features.feature_init[wx % 16][wy % 16]
    local init = df.feature_init_deep_special_tubest:new()
    init.flags:resize(template and #template.flags or 8)
    init.start_depth = template and template.start_depth or df.layer_type.MagmaSea
    init.end_depth = template and template.end_depth or df.layer_type.Underworld
    init.mat_type = 0
    init.mat_index = template and template.mat_index or -1
    local feat = init:createFeature()
    if not init.feature then init.feature = feat end
    if not init.feature then
        return nil, 'createFeature returned nothing'  -- leaked on purpose: never free DF objects
    end
    init.feature.min_map_z:insert('#', -29977)
    init.feature.max_map_z:insert('#', -29977)
    vec:insert('#', init)
    local fl = df.global.world.features
    fl.map_features:insert('#', init)
    fl.feature_local_idx:insert('#', #vec - 1)
    fl.feature_global_idx:insert('#', -1)
    return {init = init, local_idx = #vec - 1, cell = wx .. ':' .. wy, created = true}
end

-- register one spire (a cluster of tile keys) on a tube feature
local function arm_spire(ctx, cluster, tube, midx)
    local map = df.global.world.map
    local init = tube.init
    init.mat_type = 0
    init.mat_index = midx
    init.flags.Discovered = false
    init.flags.Announced = false
    init.flags.AnnouncedFully = false
    local sqs, sq_list = {}, {}
    local sx0, sy0, sx1, sy1 = 16, 16, -1, -1
    for _, k in ipairs(cluster) do
        local x, y, z = spire_unkey(k)
        local block = dfhack.maps.getBlock(x // 16, y // 16, z)
        if block then
            block.designation[x % 16][y % 16].feature_local = true
            if block.local_feature ~= tube.local_idx then
                block.local_feature = tube.local_idx
            end
            ctx.spire_flagged[k] = true
            -- embark squares (48 tiles) the spire touches, absolute and
            -- relative to the world tile
            local ax, ay = map.region_x + x // 48, map.region_y + y // 48
            local sk = ax .. ':' .. ay
            if not sqs[sk] then
                sqs[sk] = true
                table.insert(sq_list, {ax, ay})
            end
            local rx, ry = ax % 16, ay % 16
            if rx < sx0 then sx0 = rx end
            if ry < sy0 then sy0 = ry end
            if rx > sx1 then sx1 = rx end
            if ry > sy1 then sy1 = ry end
        end
    end
    init.start_x, init.start_y, init.end_x, init.end_y = sx0, sy0, sx1, sy1
    local f = init.feature
    if f then
        f.embark_pos.x:resize(0)
        f.embark_pos.y:resize(0)
        for _, sq in ipairs(sq_list) do
            f.embark_pos.x:insert('#', sq[1])
            f.embark_pos.y:insert('#', sq[2])
        end
    end
end

-- connected components (26-neighbourhood) over a set of tile keys
local function cluster_keys(set)
    local clusters, seen = {}, {}
    for k in pairs(set) do
        if not seen[k] then
            seen[k] = true
            local comp, stack = {}, {k}
            while #stack > 0 do
                local c = table.remove(stack)
                comp[#comp + 1] = c
                local x, y, z = spire_unkey(c)
                for dz = -1, 1 do
                    for dy = -1, 1 do
                        for dx = -1, 1 do
                            local n = spire_key(x + dx, y + dy, z + dz)
                            if set[n] and not seen[n] then
                                seen[n] = true
                                stack[#stack + 1] = n
                            end
                        end
                    end
                end
            end
            table.insert(clusters, comp)
        end
    end
    table.sort(clusters, function(a, b) return #a > #b end)
    return clusters
end

-- phase: re-register the carried spires as live tube features
function spires_phase(ctx)
    return {
        name = 'adamantine spires',
        step = function(job)
            ctx.spire_flagged = {}
            local set, feat_at, mats = {}, {}, {}
            for _, rec in ipairs(ctx.spire_feat) do
                local x, y, z, mat_idx, tt = string.unpack('<I2I2I2I2I2', rec)
                local k = spire_key(x, y, z)
                set[k] = true
                feat_at[k] = {mat_idx, tt}
            end
            local have_hints = #ctx.spire_hint > 0
            for _, k in ipairs(ctx.spire_hint) do set[k] = true end
            if not next(set) then return true end
            local clusters = cluster_keys(set)
            if not have_hints then
                -- a snapshot from before the tube bit: the hollow core is not
                -- marked, so take the hidden open tiles inside each spire's
                -- per-level bounding box along with the adamantine
                for _, comp in ipairs(clusters) do
                    local bb = {}
                    for _, k in ipairs(comp) do
                        local x, y, z = spire_unkey(k)
                        local b = bb[z] or {x, y, x, y}
                        if x < b[1] then b[1] = x end
                        if y < b[2] then b[2] = y end
                        if x > b[3] then b[3] = x end
                        if y > b[4] then b[4] = y end
                        bb[z] = b
                    end
                    for z, b in pairs(bb) do
                        for x = b[1], b[3] do
                            for y = b[2], b[4] do
                                local k = spire_key(x, y, z)
                                if not set[k] then
                                    local tt = dfhack.maps.getTileType(x, y, z)
                                    local d = tt and dfhack.maps.getTileFlags(xyz2pos(x, y, z))
                                    if d and d.hidden
                                        and df.tiletype.attrs[tt].shape == df.tiletype_shape.EMPTY then
                                        set[k] = true
                                        comp[#comp + 1] = k
                                    end
                                end
                            end
                        end
                    end
                end
            end
            -- every cluster with adamantine in it is a spire. None is put on a
            -- tube feature any more: a spire's identity is its adamantine, its
            -- contents are world.event monitors, and a feature record is the
            -- one thing a retire/reclaim can lose (created ones vanish, and a
            -- reused one is a worldgen record whose position we would be
            -- rewriting). Plain veins survive anything.
            local tubes = {}
            local used = {}
            local reused, created, plain = 0, 0, 0
            for _, comp in ipairs(clusters) do
                local counts, best, best_n = {}, nil, 0
                for _, k in ipairs(comp) do
                    local fa = feat_at[k]
                    if fa then
                        counts[fa[1]] = (counts[fa[1]] or 0) + 1
                        if counts[fa[1]] > best_n then best, best_n = fa[1], counts[fa[1]] end
                    end
                end
                -- registered rock with no adamantine in it is not a spire
                if not best then goto next_cluster end
                local midx = resolve_mat(ctx, best)
                local tube
                if midx then
                    local x, y, z = spire_unkey(comp[1])
                    local block = dfhack.maps.getBlock(x // 16, y // 16, z)
                    local cell = block and (block.region_pos.x .. ':' .. block.region_pos.y)
                    for i, t in ipairs(tubes) do
                        if not used[i] and (t.cell == nil or t.cell == cell) then
                            used[i] = true
                            tube = t
                            reused = reused + 1
                            break
                        end
                    end
                    -- no free tube feature: this spire becomes plain raw-adamantine
                    -- veins. A feature created here does NOT survive retire/unretire
                    -- (DF rebuilds the world tile's feature list and the spire's
                    -- tiles turn into "unknown material"), so none is created.
                end
                if tube then
                    -- carried spires keep their FEATURE tiletypes; the feature
                    -- behind them now resolves the material
                    for _, k in ipairs(comp) do
                        local fa = feat_at[k]
                        if fa then
                            local x, y, z = spire_unkey(k)
                            local block = dfhack.maps.getBlock(x // 16, y // 16, z)
                            if block then block.tiletype[x % 16][y % 16] = fa[2] end
                        end
                    end
                    arm_spire(ctx, comp, tube, midx)
                else
                    plain = plain + 1
                end
                ::next_cluster::
            end
            -- whatever was not registered becomes an ordinary vein
            for _, rec in ipairs(ctx.spire_feat) do
                local x, y, z, mat_idx = string.unpack('<I2I2I2I2I2', rec)
                if not ctx.spire_flagged[spire_key(x, y, z)] then
                    ctx.paint_list[#ctx.paint_list + 1] =
                        string.pack('<I2I2I2I2B', x, y, z, mat_idx, 0)
                end
            end
            ctx.spire_report = ('%d spire(s) carried as raw-adamantine veins; %d tile(s) of ' ..
                'this world\'s own tubes disarmed'):format(plain, ctx.tube_disarmed or 0)
            print('planeswalkers: ' .. ctx.spire_report)
            return true
        end,
    }
end

-- standalone repair of a restored fort (fort/planeswalkers spires): the
-- destination's tubes are disarmed wherever they still hold tiles, and the
-- carried spires are located from the snapshot and re-registered
function spire_repair_phases(ctx)
    local phases = {}
    table.insert(phases, {
        name = 'disarm native tubes',
        init = function(job)
            job.bi = 0
            local map = df.global.world.map
            job.nb = map.x_count_block * map.y_count_block * map.z_count_block
            ctx.paint_list = ctx.paint_list or {}
        end,
        total = function(job) return job.nb end,
        pos = function(job) return job.bi end,
        step = function(job, deadline)
            local map = df.global.world.map
            local bw, bh = map.x_count_block, map.y_count_block
            while job.bi < job.nb do
                local i = job.bi
                local z = i // (bw * bh)
                local by = (i % (bw * bh)) // bw
                local bx = i % bw
                local block = dfhack.maps.getBlock(bx, by, z)
                if block and block.local_feature >= 0
                    and not dfhack.maps.getLocalInitFeature(block.region_pos, block.local_feature) then
                    -- a feature index nothing answers to (a tube created by an
                    -- earlier restore, gone after retire/unretire): unhook it; the
                    -- spire phase repaints its adamantine as veins
                    for x = 0, 15 do
                        for y = 0, 15 do block.designation[x][y].feature_local = false end
                    end
                    block.local_feature = -1
                    ctx.dangling_unhooked = (ctx.dangling_unhooked or 0) + 1
                elseif block and block_is_tube(ctx, block) then
                    local init = dfhack.maps.getLocalInitFeature(block.region_pos,
                                                                 block.local_feature)
                    for x = 0, 15 do
                        local dscol, ttcol = block.designation[x], block.tiletype[x]
                        for y = 0, 15 do
                            local d = dscol[y]
                            if d.feature_local then
                                d.feature_local = false
                                ctx.tube_disarmed = (ctx.tube_disarmed or 0) + 1
                                local attrs = df.tiletype.attrs[ttcol[y]]
                                if attrs.material == df.tiletype_material.FEATURE
                                    and not d.feature_global and init.mat_index >= 0 then
                                    -- the tube's own adamantine, nothing else
                                    -- left to resolve it: keep it as a vein
                                    tiletypes.tiletypes_setTile(
                                        xyz2pos(bx * 16 + x, by * 16 + y, z), {
                                        shape = attrs.shape,
                                        material = df.tiletype_material.STONE,
                                        special = attrs.special == df.tiletype_special.NONE
                                            and df.tiletype_special.NORMAL or attrs.special,
                                        variant = attrs.variant,
                                        hidden = d.hidden and 1 or 0,
                                        light = d.light and 1 or 0,
                                        subterranean = d.subterranean and 1 or 0,
                                        skyview = d.outside and 1 or 0,
                                        aquifer = -1, autocorrect = 0,
                                        stone_material = init.mat_index,
                                        vein_type = df.inclusion_type.CLUSTER,
                                    })
                                end
                            end
                        end
                    end
                    block.local_feature = -1
                    dfhack.maps.enableBlockUpdates(block, true, true)
                end
                job.bi = i + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.tube_lf = {}
            return true
        end,
    })
    table.insert(phases, {
        name = 'locate carried spires',
        init = function(job)
            ctx.tiles_f = io.open(ctx.dir .. '/tiles.bin', 'rb')
            ctx.src = read_header(ctx.tiles_f)
            ctx.tt_cache, ctx.mat_cache = {}, {}
            ctx.spire_feat, ctx.spire_hint = {}, {}
            job.block_cursor = 0
            job.nb = ctx.src.bx * ctx.src.by * ctx.src.bz
            ctx.terrain_blocks_expected = job.nb
        end,
        total = function(job) return job.nb end,
        pos = function(job) return job.block_cursor end,
        step = function(job, deadline)
            local s, a = ctx.src, ctx.anchor
            local map = df.global.world.map
            while job.block_cursor < job.nb do
                local data = ctx.tiles_f:read(common.BLOCK_SIZE)
                if not data then break end
                local i = job.block_cursor
                job.block_cursor = i + 1
                local z = i // (s.bx * s.by) + a.off_z
                if z >= 1 and z < map.z_count - 1 then
                    local by = (i % (s.bx * s.by)) // s.bx + a.off_by
                    local bx = i % s.bx + a.off_bx
                    local off = 1
                    for x = 0, 15 do
                        for y = 0, 15 do
                            local tt_idx, mat_idx, _, rflags = string.unpack(common.TILE_REC, data, off)
                            off = off + common.TILE_REC_SIZE
                            gather_spire_tile(ctx, bx * 16 + x, by * 16 + y, z,
                                              resolve_tt(ctx, tt_idx), mat_idx, rflags)
                        end
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.tiles_f:close()
            ctx.tiles_f = nil
            return true
        end,
    })
    table.insert(phases, spires_phase(ctx))
    table.insert(phases, {
        name = 'paint leftovers',
        step = function(job)
            for _, rec in ipairs(ctx.paint_list) do
                local x, y, z, mat_idx = string.unpack('<I2I2I2I2B', rec)
                local midx = resolve_mat(ctx, mat_idx)
                local tt = dfhack.maps.getTileType(x, y, z)
                if midx and tt then
                    local attrs = df.tiletype.attrs[tt]
                    local d = dfhack.maps.getTileFlags(xyz2pos(x, y, z))
                    tiletypes.tiletypes_setTile(xyz2pos(x, y, z), {
                        shape = attrs.shape, material = df.tiletype_material.STONE,
                        special = attrs.special == df.tiletype_special.NONE
                            and df.tiletype_special.NORMAL or attrs.special,
                        variant = attrs.variant,
                        hidden = d.hidden and 1 or 0, light = d.light and 1 or 0,
                        subterranean = d.subterranean and 1 or 0,
                        skyview = d.outside and 1 or 0,
                        aquifer = -1, autocorrect = 0,
                        stone_material = midx, vein_type = df.inclusion_type.CLUSTER,
                    })
                end
            end
            return true
        end,
    })
    return phases
end

-- ---- magma ownership and static-origin-magma validation ---------------------
-- The destination owns its global magma-core and underworld registrations.
-- Imported origin magma remains static and footprint-local; the two worlds'
-- feature bands are never merged or rewritten.

local function layer_features()
    local fl = df.global.world.features
    local magma, hell
    for i = 0, #fl.map_features - 1 do
        local fi = fl.map_features[i]
        if df.feature_init_magma_core_from_layerst:is_instance(fi) then
            magma = {init = fi, gidx = fl.feature_global_idx[i]}
        elseif df.feature_init_underworld_from_layerst:is_instance(fi) then
            hell = {init = fi, gidx = fl.feature_global_idx[i]}
        end
    end
    return magma, hell
end

-- Native magma registration is safe only when the translated source layer
-- fits wholly inside the destination's existing registered magma Z band.
-- We deliberately do not widen feature bounds: those bounds are world-global.
local function can_register_origin_magma(ctx)
    local gidx = ctx.dest_magma_gidx or -1
    local dmin, dmax = ctx.dest_magma_bottom, ctx.dest_magma_top
    local smin = (ctx.manifest.dims.magma_min or -1) + (ctx.anchor.off_z or 0)
    local smax = (ctx.manifest.dims.magma_top or -1) + (ctx.anchor.off_z or 0)
    return gidx >= 0 and dmin and dmax and dmin >= 0
        and smin >= dmin and smax <= dmax
end

-- Do not infer underworld membership from FEATURE material. That category also
-- includes adamantine tubes and unrelated world features. The native block's
-- registered global feature is the authoritative underworld identifier.

-- let the liquids REST: the load flags every block for liquid processing,
-- and a whole sea under processing churns -- surface tiles thin out and
-- evaporate, the rest flows after them, and the sea is gone within a season
-- (measured ~3 units/tick; a vanilla sea's blocks are never flagged and DF
-- flags the few it needs on its own). Cleared after the terrain and again at
-- the very end of the load.
function clear_liquid_flags(cutoff, rect, static_magma_tiles)
    local map = df.global.world.map
    local n = 0
    if static_magma_tiles then
        -- Prefer exact source-tile provenance. A destination underworld feature
        -- can share a map block with imported terrain; scanning for any
        -- flow_forbid magma tile would freeze native destination simulation too.
        local blocks = {}
        for key in pairs(static_magma_tiles) do
            local x, y, z = key:match('^(%-?%d+):(%-?%d+):(%-?%d+)$')
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if x and z > (cutoff or -1) then
                local block = dfhack.maps.getTileBlock(x, y, z)
                if block then blocks[block] = true end
            end
        end
        for block in pairs(blocks) do
            -- Liquid update flags are block-wide (16x16), not per-tile. Do not
            -- freeze a mixed block that still contains destination underworld
            -- liquid, source water, an aquifer, or any native feature. Imported
            -- magma is sealed at tile level; only a block made exclusively of
            -- source-static magma/ordinary dry terrain can safely be frozen.
            local can_freeze = block.global_feature < 0 and block.local_feature < 0
            if can_freeze then
                local block_x, block_y, bz = block.map_pos.x, block.map_pos.y, block.map_pos.z
                for x = 0, 15 do
                    for y = 0, 15 do
                        local d = block.designation[x][y]
                        local key = tile_key(block_x + x, block_y + y, bz)
                        if (d.flow_size > 0 and not static_magma_tiles[key])
                            or d.water_table
                            or ((d.feature_global or d.feature_local) and not static_magma_tiles[key]) then
                            can_freeze = false
                            break
                        end
                    end
                    if not can_freeze then break end
                end
            end
            if can_freeze and (block.flags.update_liquid or block.flags.update_liquid_twice) then
                block.flags.update_liquid = false
                block.flags.update_liquid_twice = false
                n = n + 1
            end
        end
        return n
    end

    -- Compatibility fallback for a repair/legacy context without tile keys.
    local bx0, by0, bx1, by1 = 0, 0, map.x_count_block, map.y_count_block
    if rect then
        bx0 = math.max(0, rect.x // 16)
        by0 = math.max(0, rect.y // 16)
        bx1 = math.min(map.x_count_block, (rect.x + rect.w + 15) // 16)
        by1 = math.min(map.y_count_block, (rect.y + rect.h + 15) // 16)
    end
    for z = math.max(0, (cutoff or -1) + 1), map.z_count - 1 do
        for by = by0, by1 - 1 do
            for bx = bx0, bx1 - 1 do
                local b = dfhack.maps.getBlock(bx, by, z)
                if b and (b.flags.update_liquid or b.flags.update_liquid_twice) then
                    local static_core = false
                    for x = 0, 15 do
                        local col = b.designation[x]
                        for y = 0, 15 do
                            local d = col[y]
                            if d.flow_size > 0
                                and (d.liquid_type == true or d.liquid_type == 1)
                                and d.flow_forbid then
                                static_core = true
                                break
                            end
                        end
                        if static_core then break end
                    end
                    if static_core then
                        b.flags.update_liquid = false
                        b.flags.update_liquid_twice = false
                        n = n + 1
                    end
                end
            end
        end
    end
    return n
end

function magma_sea_phase(ctx, refill)
    -- Validate static fallback tiles separately from tiles registered to the
    -- destination magma core. Both modes retain the destination underworld.
    return {
        name = refill and 'validate origin magma repair' or 'validate origin magma',
        init = function(job)
            job.keys = {}
            local seen = {}
            for key in pairs(ctx.source_magma_tile_keys or {}) do
                seen[key] = true
            end
            for key in pairs(ctx.registered_magma_tile_keys or {}) do
                seen[key] = true
            end
            for key in pairs(seen) do job.keys[#job.keys + 1] = key end
            table.sort(job.keys)
            job.cursor = 1
            job.checked, job.bad_feature, job.bad_flow, job.bad_underworld = 0, 0, 0, 0
        end,
        total = function(job) return #job.keys end,
        pos = function(job) return job.cursor - 1 end,
        step = function(job, deadline)
            while job.cursor <= #job.keys do
                local key = job.keys[job.cursor]
                local x, y, z = key:match('^(%-?%d+):(%-?%d+):(%-?%d+)$')
                x, y, z = tonumber(x), tonumber(y), tonumber(z)
                local block = x and dfhack.maps.getTileBlock(x, y, z) or nil
                if not block then
                    job.bad_feature = job.bad_feature + 1
                else
                    local d = block.designation[x % 16][y % 16]
                    if d.flow_size <= 0 or (d.liquid_type ~= true and d.liquid_type ~= 1) then
                        job.bad_feature = job.bad_feature + 1
                    elseif ctx.registered_magma_tile_keys and ctx.registered_magma_tile_keys[key] then
                        if not d.feature_global or d.flow_forbid or block.global_feature ~= ctx.dest_magma_gidx then
                            job.bad_flow = job.bad_flow + 1
                        end
                    elseif not d.flow_forbid or d.feature_global then
                        job.bad_flow = job.bad_flow + 1
                    end
                    if not ctx.anchor.full then
                        local ceiling = column_ceiling(ctx, x, y)
                        local fallback_ceiling = ctx.dest_footprint_deep_top
                            or ctx.dest_deep_top or -1
                        if (ceiling >= 0 and z <= ceiling + 1)
                            or (ceiling < 0 and fallback_ceiling >= 0
                                and z <= fallback_ceiling + 1) then
                            job.bad_underworld = job.bad_underworld + 1
                        end
                    end
                end
                job.checked = job.checked + 1
                job.cursor = job.cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.magma_report = ('origin magma: %d fallback tile(s) checked; %d tile(s) registered to the destination magma core; underworld registration preserved')
                :format(job.checked, (function() local n=0; for _ in pairs(ctx.registered_magma_tile_keys or {}) do n=n+1 end; return n end)())
            print('planeswalkers: ' .. ctx.magma_report)
            if job.bad_feature > 0 or job.bad_flow > 0 or job.bad_underworld > 0 then
                qerror(('planeswalkers: magma validation failed (%d missing/invalid tile(s), %d registration/flow fault(s), %d underworld collision(s))')
                    :format(job.bad_feature, job.bad_flow, job.bad_underworld))
            end
            return true
        end,
    }
end

-- Restore the origin's magma-core blocks inside the imported footprint.
-- The ordinary terrain pass has already replaced destination blocks in the
-- source volume; this sparse stream fills the source magma blocks back in.
-- Each record is a z-major source block index followed by one packed block.
-- Imported magma remains unregistered/static, while destination feature
-- registrations outside the footprint are left untouched.
function magma_restore_phase(ctx)
    local path = ctx.dir .. '/magma.bin'
    if ctx.preserve_depths or not dfhack.filesystem.exists(path) then return nil end
    return {
        name = 'restore complete origin magma sea',
        init = function(job)
            job.f = io.open(path, 'rb')
            if not job.f then qerror('planeswalkers: could not open magma.bin') end
            ctx.magma_f = job.f
            if ctx.manifest.format_version >= 5 then
                job.heat_f = io.open(ctx.dir .. '/heat.bin', 'rb')
                if not job.heat_f then qerror('planeswalkers: could not open heat.bin for magma blocks') end
                ctx.heat_f = job.heat_f
            end
            local header = job.f:read(common.HEADER_SIZE)
            if not header or #header ~= common.HEADER_SIZE then
                qerror('planeswalkers: truncated magma.bin header')
            end
            local magic, bx, by, bz, surface, flags = string.unpack(common.HEADER_FMT, header)
            if magic ~= 'PWM1' then qerror('planeswalkers: bad magma.bin magic') end
            job.src = {bx = bx, by = by, bz = bz, surface = surface, flags = flags}
            if bx ~= ctx.manifest.dims.bx or by ~= ctx.manifest.dims.by then
                qerror('planeswalkers: magma.bin dimensions do not match the snapshot manifest')
            end
            ctx.src = job.src
            job.restored = 0
            job.total_records = (ctx.manifest.counts and ctx.manifest.counts.magma_blocks) or 0
            job.per_z = bx * by
        end,
        total = function(job) return job.total_records end,
        pos = function(job) return job.restored end,
        step = function(job, deadline)
            while true do
                local index_data = job.f:read(4)
                if not index_data then
                    if job.restored ~= job.total_records then
                        qerror(('planeswalkers: magma.bin record count mismatch (manifest %d, file %d)')
                            :format(job.total_records, job.restored))
                    end
                    job.f:close()
                    job.f = nil
                    if job.heat_f then job.heat_f:close(); job.heat_f = nil end
                    ctx.heat_f = nil
                    ctx.magma_f = nil
                    ctx.magma_blocks_restored = job.restored
                    ctx.magma_restore_report = ('origin magma: restored %d complete magma-core block(s), %d fallback magma tile(s), and %d natively registered magma tile(s)')
                        :format(job.restored, (function() local n=0; for _ in pairs(ctx.source_magma_tile_keys or {}) do n=n+1 end; return n end)(), (function() local n=0; for _ in pairs(ctx.registered_magma_tile_keys or {}) do n=n+1 end; return n end)())
                    print('planeswalkers: ' .. ctx.magma_restore_report)
                    return true
                end
                if #index_data ~= 4 then qerror('planeswalkers: truncated magma.bin block index') end
                local data = job.f:read(common.BLOCK_SIZE)
                if not data or #data ~= common.BLOCK_SIZE then
                    qerror('planeswalkers: truncated magma.bin block data')
                end
                local index = string.unpack('<I4', index_data)
                if index >= job.per_z * job.src.bz then
                    qerror('planeswalkers: magma.bin contains an out-of-range block index')
                end
                if job.last_index and index <= job.last_index then
                    qerror('planeswalkers: magma.bin block indices are duplicated or out of order')
                end
                job.last_index = index
                local src_z = index // job.per_z
                local src_by = (index % job.per_z) // job.src.bx
                local src_bx = index % job.src.bx
                local heat_data
                if job.heat_f then
                    job.heat_f:seek('set', common.HEADER_SIZE + index * common.HEAT_BLOCK_SIZE)
                    heat_data = job.heat_f:read(common.HEAT_BLOCK_SIZE)
                    if not heat_data or #heat_data ~= common.HEAT_BLOCK_SIZE then
                        qerror('planeswalkers: truncated heat.bin magma block')
                    end
                end
                ctx.restoring_source_magma = true
                load_block(ctx, data, src_bx, src_by, src_z, heat_data)
                ctx.restoring_source_magma = false
                local dst_z = src_z + ctx.anchor.off_z
                local dst_bx, dst_by = src_bx + ctx.anchor.off_bx, src_by + ctx.anchor.off_by
                local block = (dst_z >= 1 and dst_z < df.global.world.map.z_count - 1)
                    and dfhack.maps.getBlock(dst_bx, dst_by, dst_z) or nil
                if block then
                    local native_ok = ctx.native_magma_registration
                        and (block.global_feature < 0 or block.global_feature == ctx.dest_magma_gidx)
                    local off = 1
                    for x = 0, 15 do
                        for y = 0, 15 do
                            local _, _, dbits = string.unpack(common.TILE_REC, data, off)
                            off = off + common.TILE_REC_SIZE
                            local bits = common.unpack_dsgn(dbits)
                            local d = block.designation[x][y]
                            if bits.liquid_type == 1 and bits.flow_size > 0
                                and d.flow_size > 0 and (d.liquid_type == true or d.liquid_type == 1)
                                and df.tiletype.attrs[block.tiletype[x][y]].shape ~= df.tiletype_shape.WALL then
                                local wx, wy = dst_bx * 16 + x, dst_by * 16 + y
                                local key = tile_key(wx, wy, dst_z)
                                local ceiling = column_ceiling(ctx, wx, wy)
                                local fallback_ceiling = ctx.dest_footprint_deep_top or ctx.dest_deep_top or -1
                                local safe = ctx.anchor.full or (ceiling >= 0 and dst_z > ceiling + 1)
                                    or (ceiling < 0 and (fallback_ceiling < 0 or dst_z > fallback_ceiling + 1))
                                if safe and native_ok then
                                    block.global_feature = ctx.dest_magma_gidx
                                    d.feature_global = true
                                    d.flow_forbid = false
                                    ctx.registered_magma_tile_keys = ctx.registered_magma_tile_keys or {}
                                    ctx.registered_magma_tile_keys[key] = true
                                    if ctx.source_magma_tile_keys then ctx.source_magma_tile_keys[key] = nil end
                                elseif safe then
                                    d.feature_global = false
                                    d.flow_forbid = true
                                    ctx.source_magma_tile_keys = ctx.source_magma_tile_keys or {}
                                    ctx.source_magma_tile_keys[key] = true
                                end
                            end
                        end
                    end
                end
                job.restored = job.restored + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
        end,
    }
end

-- Repair drained origin magma by restoring liquid depths as static liquid.
-- This does not modify the destination global magma feature or underworld.
function magma_refill_phase(ctx)
    local path = ctx.dir .. '/magma.bin'
    if not dfhack.filesystem.exists(path) then
        qerror('planeswalkers: this snapshot has no magma.bin; save it again with format v4')
    end
    return {
        name = 'restore static origin magma from snapshot',
        init = function(job)
            job.f = io.open(path, 'rb')
            if not job.f then qerror('planeswalkers: could not open magma.bin') end
            ctx.magma_f = job.f
            local magic, bx, by, bz, surface, flags = string.unpack(common.HEADER_FMT,
                job.f:read(common.HEADER_SIZE))
            if magic ~= 'PWM1' then qerror('planeswalkers: bad magma.bin magic') end
            job.src = {bx = bx, by = by, bz = bz, surface = surface, flags = flags}
            ctx.src = job.src
            job.cursor, job.refilled, job.unsafe_cleared = 0, 0, 0
            local magma = select(1, layer_features())
            job.magma_gidx = magma and magma.gidx or -1
            job.total_records = (ctx.manifest.counts and ctx.manifest.counts.magma_blocks) or 0
        end,
        total = function(job) return job.total_records end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local per_z, a = job.src.bx * job.src.by, ctx.anchor
            while true do
                local index_data = job.f:read(4)
                if not index_data then
                    if job.cursor ~= job.total_records then
                        qerror(('planeswalkers: magma.bin record count mismatch (manifest %d, file %d)')
                            :format(job.total_records, job.cursor))
                    end
                    job.f:close()
                    job.f = nil
                    ctx.magma_f = nil
                    ctx.magma_refilled = job.refilled
                    ctx.magma_refill_report = ('magma repair: restored %d static origin magma tile(s); cleared %d unsafe underworld-overlap tile(s)')
                        :format(job.refilled, job.unsafe_cleared)
                    return true
                end
                if #index_data ~= 4 then qerror('planeswalkers: truncated magma.bin block index') end
                local data = job.f:read(common.BLOCK_SIZE)
                if not data or #data ~= common.BLOCK_SIZE then
                    qerror('planeswalkers: truncated magma.bin block data')
                end
                local index = string.unpack('<I4', index_data)
                if index >= per_z * job.src.bz then
                    qerror('planeswalkers: magma.bin contains an out-of-range block index')
                end
                if job.last_index and index <= job.last_index then
                    qerror('planeswalkers: magma.bin block indices are duplicated or out of order')
                end
                job.last_index = index
                local z = index // per_z + a.off_z
                local by = (index % per_z) // job.src.bx + a.off_by
                local bx = index % job.src.bx + a.off_bx
                local block = (z >= 1 and z < df.global.world.map.z_count - 1)
                    and dfhack.maps.getBlock(bx, by, z) or nil
                if block then
                    ctx.source_magma_block_keys = ctx.source_magma_block_keys or {}
                    ctx.source_magma_block_keys[block_key(bx, by, z)] = true
                    ctx.source_magma_tile_keys = ctx.source_magma_tile_keys or {}
                    if z > (ctx.magma_zmax or -1) then ctx.magma_zmax = z end
                    local off = 1
                    for x = 0, 15 do
                        for y = 0, 15 do
                            local _, _, dbits = string.unpack(common.TILE_REC, data, off)
                            off = off + common.TILE_REC_SIZE
                            local bits = common.unpack_dsgn(dbits)
                            if bits.liquid_type == 1 and bits.flow_size > 0
                                and df.tiletype.attrs[block.tiletype[x][y]].shape
                                    ~= df.tiletype_shape.WALL then
                                local wx, wy = bx * 16 + x, by * 16 + y
                                local ceiling = column_ceiling(ctx, wx, wy)
                                local fallback_ceiling = ctx.dest_footprint_deep_top or ctx.dest_deep_top or -1
                                local d = block.designation[x][y]
                                local safe = (ceiling >= 0 and z > ceiling + 1)
                                    or (ceiling < 0 and (fallback_ceiling < 0 or z > fallback_ceiling + 1))
                                if safe then
                                    d.flow_size = bits.flow_size
                                    d.liquid_type = true
                                    d.flow_forbid = true
                                    d.feature_global = false
                                    ctx.source_magma_tile_keys[tile_key(wx, wy, z)] = true
                                    job.refilled = job.refilled + 1
                                else
                                    d.flow_size = 0
                                    d.liquid_type = false
                                    d.flow_forbid = false
                                    d.feature_global = false
                                    job.unsafe_cleared = job.unsafe_cleared + 1
                                end
                            end
                        end
                    end
                    if job.magma_gidx >= 0 and block.global_feature == job.magma_gidx then
                        refresh_block_feature_refs(block)
                    end
                end
                job.cursor = job.cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
        end,
    }
end

-- Smooth the exterior of a smaller imported footprint. The hard footprint is
-- never changed: this reshapes a broad transition in the destination map. The
-- target height blends from the imported edge to untouched destination terrain.
-- Full-map imports have no exterior transition and skip this.
local function surface_buffer_phase(ctx)
    local BUFFER_WIDTH = 96 -- two world-tile neighborhoods for a gradual transition
    local function surface_at(x, y)
        local map = df.global.world.map
        for z = map.z_count - 2, 1, -1 do
            local tt = dfhack.maps.getTileType(x, y, z)
            if tt then
                local a = df.tiletype.attrs[tt]
                local m = a.material
                if a.shape ~= df.tiletype_shape.EMPTY
                    and m ~= df.tiletype_material.TREE
                    and m ~= df.tiletype_material.ROOT
                    and m ~= df.tiletype_material.PLANT
                    and m ~= df.tiletype_material.MUSHROOM
                    and m ~= df.tiletype_material.CONSTRUCTION
                    and m ~= df.tiletype_material.FEATURE then
                    return z, tt
                end
            end
        end
        return nil
    end

    local function has_surface_liquid(x, y, surface_z)
        -- Rivers, brooks, waterfalls, and other surface liquid columns must
        -- retain their existing channel. Reshaping these columns cuts streams
        -- off at the imported-footprint seam and can redirect water over land.
        local map = df.global.world.map
        local lo = math.max(1, (surface_z or 1) - 3)
        local hi = math.min(map.z_count - 2, (surface_z or 1) + 1)
        for z = lo, hi do
            local block = dfhack.maps.getTileBlock(x, y, z)
            if block then
                local lx, ly = x % 16, y % 16
                if block.designation[lx][ly].flow_size > 0
                    or is_brook_tile(block.tiletype[lx][ly]) then
                    return true
                end
            end
        end
        return false
    end


    local function find_tiletype(material, shape)
        for i = 0, df.tiletype._last_item do
            local a = df.tiletype.attrs[i]
            if a.material == material and a.shape == shape then return i end
        end
        return nil
    end

    local function is_natural_wall(tt)
        if not tt then return false end
        local a = df.tiletype.attrs[tt]
        return a.shape == df.tiletype_shape.WALL
            and (a.material == df.tiletype_material.STONE
                or a.material == df.tiletype_material.SOIL)
    end


    return {
        name = 'surface buffer smoothing',
        init = function(job)
            local map, a = df.global.world.map, ctx.anchor
            local x0, y0 = a.off_x, a.off_y
            local x1 = x0 + ctx.manifest.dims.bx * 16
            local y1 = y0 + ctx.manifest.dims.by * 16
            job.tasks = {}
            job.changed = 0
            job.changed_blocks = {}
            if x0 <= 0 and y0 <= 0 and x1 >= map.x_count and y1 >= map.y_count then
                ctx.surface_buffer_report = 'surface buffer: skipped (the imported footprint fills the destination map)'
                job.skip = true
                return
            end

            -- Sample the imported edge after terrain restoration. Plant and
            -- construction tiles are ignored so tree canopies do not become
            -- the height of the terrain transition.
            local north, south, west, east = {}, {}, {}, {}
            for x = x0, x1 - 1 do
                local nz, nt = surface_at(x, y0)
                local sz, st = surface_at(x, y1 - 1)
                north[x - x0 + 1] = nz and {nz, nt} or nil
                south[x - x0 + 1] = sz and {sz, st} or nil
            end
            for y = y0, y1 - 1 do
                local wz, wt = surface_at(x0, y)
                local ez, et = surface_at(x1 - 1, y)
                west[y - y0 + 1] = wz and {wz, wt} or nil
                east[y - y0 + 1] = ez and {ez, et} or nil
            end

            local rx0, ry0 = math.max(0, x0 - BUFFER_WIDTH), math.max(0, y0 - BUFFER_WIDTH)
            local rx1, ry1 = math.min(map.x_count, x1 + BUFFER_WIDTH),
                                  math.min(map.y_count, y1 + BUFFER_WIDTH)
            for y = ry0, ry1 - 1 do
                for x = rx0, rx1 - 1 do
                    if x < x0 or x >= x1 or y < y0 or y >= y1 then
                        local dx = x < x0 and (x0 - x) or (x >= x1 and (x - x1 + 1) or 0)
                        local dy = y < y0 and (y0 - y) or (y >= y1 and (y - y1 + 1) or 0)
                        local dist = math.max(dx, dy)
                        if dist > 0 and dist <= BUFFER_WIDTH then
                            local source_z
                            if dx > 0 and dy == 0 then
                                local v = (y - y0) + 1
                                local edge = x < x0 and west[v] or east[v]
                                source_z = edge and edge[1]
                            elseif dy > 0 and dx == 0 then
                                local v = (x - x0) + 1
                                local edge = y < y0 and north[v] or south[v]
                                source_z = edge and edge[1]
                            else
                                local vx = math.max(1, math.min(x1 - x0, x < x0 and 1 or (x >= x1 and (x1 - x0) or (x - x0 + 1))))
                                local vy = math.max(1, math.min(y1 - y0, y < y0 and 1 or (y >= y1 and (y1 - y0) or (y - y0 + 1))))
                                local ex = x < x0 and west[vy] or east[vy]
                                local ey = y < y0 and north[vx] or south[vx]
                                if ex and ey then source_z = (ex[1] + ey[1]) / 2
                                elseif ex then source_z = ex[1]
                                elseif ey then source_z = ey[1] end
                            end
                            if source_z then
                                table.insert(job.tasks, {x = x, y = y, source_z = source_z, dist = dist})
                            end
                        end
                    end
                end
            end
            job.cursor = 1
            job.lowering_skipped = 0
            job.soil_wall = find_tiletype(df.tiletype_material.SOIL, df.tiletype_shape.WALL)
            job.soil_floor = df.tiletype.SoilFloor1
            job.soil_ramp = find_tiletype(df.tiletype_material.SOIL, df.tiletype_shape.RAMP)
            job.stone_wall = find_tiletype(df.tiletype_material.STONE, df.tiletype_shape.WALL)
            job.stone_floor = find_tiletype(df.tiletype_material.STONE, df.tiletype_shape.FLOOR)
            job.stone_ramp = find_tiletype(df.tiletype_material.STONE, df.tiletype_shape.RAMP)
        end,
        total = function(job) return #(job.tasks or {}) end,
        pos = function(job) return job.cursor or 0 end,
        step = function(job, deadline)
            if job.skip then return true end
            local map = df.global.world.map
            while job.cursor and job.cursor <= #job.tasks do
                local task = job.tasks[job.cursor]
                job.cursor = job.cursor + 1
                local x, y = task.x, task.y
                local dest_z, dest_tt = surface_at(x, y)
                if dest_z and not has_surface_liquid(x, y, dest_z) then
                    local t = math.min(1, task.dist / BUFFER_WIDTH)
                    local alpha = t * t * (3 - 2 * t)
                    local target_z = math.floor(task.source_z + (dest_z - task.source_z) * alpha + 0.5)
                    if math.abs(target_z - dest_z) > 1 then
                        -- Smoothing is deliberately non-excavating. Raising a
                        -- lower destination column can form a supported ramp;
                        -- lowering a high column would remove natural support
                        -- and was responsible for avoidable surface collapses.
                        if target_z < dest_z then
                            job.lowering_skipped = job.lowering_skipped + 1
                        else
                            local blocked = false
                            local ceiling = column_ceiling(ctx, x, y)
                            local fallback_ceiling = ctx.dest_footprint_deep_top or ctx.dest_deep_top or -1
                            local safe_bottom = ceiling >= 0 and (ceiling + 2)
                                or (fallback_ceiling >= 0 and (fallback_ceiling + 2) or 1)
                            if target_z < safe_bottom then blocked = true end
                            local below = dfhack.maps.getTileType(x, y, dest_z - 1)
                            if not is_natural_wall(below)
                                and not is_natural_wall(dest_tt) then
                                blocked = true
                            end
                            for z = dest_z + 1, target_z do
                                if blocked then break end
                                local tt = dfhack.maps.getTileType(x, y, z)
                                if tt and df.tiletype.attrs[tt].shape ~= df.tiletype_shape.EMPTY then
                                    blocked = true
                                end
                            end
                        if not blocked then
                            local mat = df.tiletype.attrs[dest_tt].material
                            local soil = mat == df.tiletype_material.SOIL
                                or mat == df.tiletype_material.GRASS_LIGHT
                                or mat == df.tiletype_material.GRASS_DARK
                                or mat == df.tiletype_material.GRASS_DRY
                                or mat == df.tiletype_material.GRASS_DEAD
                            local wall = soil and job.soil_wall or job.stone_wall
                            local floor = soil and job.soil_floor or job.stone_floor
                            local ramp = soil and job.soil_ramp or job.stone_ramp
                            local function set_tile(z, tt)
                                local block = dfhack.maps.getTileBlock(x, y, z)
                                    or dfhack.maps.ensureTileBlock(x, y, z)
                                if not block then return end
                                local lx, ly = x % 16, y % 16
                                block.tiletype[lx][ly] = tt
                                local d = block.designation[lx][ly]
                                d.flow_size = 0
                                d.liquid_type = false
                                d.flow_forbid = false
                                d.water_table = false
                                d.subterranean = false
                                d.outside = true
                                d.light = true
                                clear_tile_claims(block, lx, ly)
                                job.changed_blocks[block] = true
                            end
                            if wall and (ramp or floor) then
                                for z = dest_z + 1, target_z - 1 do set_tile(z, wall) end
                                -- A ramp gives units and liquids a gradual
                                -- surface connection instead of a sheer wall.
                                set_tile(target_z, ramp or floor)
                                job.changed = job.changed + 1
                            end
                        end
                    end
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            for block in pairs(job.changed_blocks) do refresh_block_feature_refs(block) end
            ctx.surface_buffer_report = ('surface buffer: built up %d supported exterior column(s) across a %d-tile transition; skipped %d columns that would have required excavation (no terrain was lowered)')
                :format(job.changed or 0, BUFFER_WIDTH, job.lowering_skipped or 0)
            return true
        end,
    }
end

-- Taper liquid channels into natural banks on both sides of the artificial
-- footprint seam. The collar remains the actual impermeable barrier; this pass
-- shapes the last few surface columns so pools and rivers do not end at a bare
-- vertical wall. Only surface water is shaped. Magma is handled by the magma
-- ownership rules and must never be mistaken for ordinary water.
local function liquid_transition_cap_phase(ctx)
    local function is_blocker(tt)
        if not tt then return false end
        local m = df.tiletype.attrs[tt].material
        return m == df.tiletype_material.TREE or m == df.tiletype_material.ROOT
            or m == df.tiletype_material.PLANT or m == df.tiletype_material.MUSHROOM
            or m == df.tiletype_material.CONSTRUCTION
    end
    return {
        name = 'surface-liquid transition containment',
        init = function(job)
            local map, a, dims = df.global.world.map, ctx.anchor, ctx.manifest.dims
            job.x0, job.y0 = a.off_x, a.off_y
            job.x1, job.y1 = a.off_x + dims.bx * 16, a.off_y + dims.by * 16
            job.tasks = {}
            job.changed, job.columns = 0, 0
            if job.x0 <= 0 and job.y0 <= 0 and job.x1 >= map.x_count and job.y1 >= map.y_count then
                job.skip = true
                ctx.liquid_cap_report = 'surface-liquid containment: skipped (the imported footprint fills the destination map)'
                return
            end
            for y = math.max(0, job.y0 - 5), math.min(map.y_count - 1, job.y1 + 4) do
                for x = math.max(0, job.x0 - 5), math.min(map.x_count - 1, job.x1 + 4) do
                    local inside = x >= job.x0 and x < job.x1 and y >= job.y0 and y < job.y1
                    local dist
                    if inside then
                        dist = math.min(x - job.x0, job.x1 - 1 - x, y - job.y0, job.y1 - 1 - y)
                    else
                        local dx = x < job.x0 and job.x0 - x or (x >= job.x1 and x - job.x1 + 1 or 0)
                        local dy = y < job.y0 and job.y0 - y or (y >= job.y1 and y - job.y1 + 1 or 0)
                        dist = math.max(dx, dy)
                    end
                    if (inside and dist <= 3) or (not inside and dist >= 3 and dist <= 5) then
                        job.tasks[#job.tasks + 1] = {x=x, y=y, inside=inside, dist=dist}
                    end
                end
            end
            job.cursor = 1
        end,
        total = function(job) return #job.tasks end,
        pos = function(job) return job.cursor - 1 end,
        step = function(job, deadline)
            if job.skip then return true end
            local map = df.global.world.map
            while job.cursor <= #job.tasks do
                local task = job.tasks[job.cursor]
                local x, y = task.x, task.y
                local surface_z
                for z = map.z_count - 2, 1, -1 do
                    local tt = dfhack.maps.getTileType(x, y, z)
                    if tt and not is_blocker(tt) then
                        local at = df.tiletype.attrs[tt]
                        if at.shape ~= df.tiletype_shape.EMPTY
                            and at.material ~= df.tiletype_material.FEATURE then
                            surface_z = z
                            break
                        end
                    end
                end
                if surface_z then
                    local local_ceiling = column_ceiling(ctx, x, y)
                    local fallback_ceiling = ctx.dest_footprint_deep_top or ctx.dest_deep_top or -1
                    local liquid_tiles = {}
                    local high
                    for z = math.max(1, surface_z - 16), math.min(map.z_count - 2, surface_z + 4) do
                        local block = dfhack.maps.getTileBlock(x, y, z)
                        if block then
                            local lx, ly = x % 16, y % 16
                            local d = block.designation[lx][ly]
                            local tt = block.tiletype[lx][ly]
                            local protected_deep = (local_ceiling >= 0 and z <= local_ceiling + 1)
                                or (local_ceiling < 0 and fallback_ceiling >= 0 and z <= fallback_ceiling + 1)
                            local water = d.flow_size > 0 and not d.liquid_type and not d.water_table
                            local brook = is_brook_tile(tt)
                            if (water or brook) and not protected_deep then
                                liquid_tiles[#liquid_tiles + 1] = d
                                high = high and math.max(high, z) or z
                            end
                        end
                    end
                    if high then
                        local strength = task.inside and math.max(0, 4 - task.dist)
                            or math.max(0, 6 - task.dist)
                        if strength > 0 then
                            for _, d in ipairs(liquid_tiles) do
                                -- Preserve the liquid itself. The bulkhead is
                                -- the physical seal; flow_forbid prevents these
                                -- source tiles from feeding across the seam.
                                if not d.flow_forbid then
                                    d.flow_forbid = true
                                    job.changed = job.changed + 1
                                end
                            end
                            job.columns = job.columns + 1
                        end
                    end
                end
                job.cursor = job.cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.liquid_cap_report = ('surface-liquid containment: protected %d wet surface column(s), set %d flow-forbid flag(s); retained all liquid and placed no unsupported artificial walls')
                :format(job.columns, job.changed)
            print('planeswalkers: ' .. ctx.liquid_cap_report)
            return true
        end,
    }
end

-- A sealed transition bulkhead separates the imported footprint from
-- destination caverns, aquifers, water, and magma. It instantiates a
-- continuous two-tile-wide wall starting two levels above the local destination
-- underworld ceiling (leaving one untouched buffer level) and reaching above
-- the higher adjacent surface/liquid level. Surface channels that cross this
-- artificial boundary are intentionally cut; liquid containment takes priority
-- over trying to connect unrelated world hydrology systems.
local function boundary_collar_phase(ctx)
    local function is_surface_tile(tt)
        if not tt then return false end
        local at = df.tiletype.attrs[tt]
        local m = at.material
        return at.shape ~= df.tiletype_shape.EMPTY
            and m ~= df.tiletype_material.TREE
            and m ~= df.tiletype_material.ROOT
            and m ~= df.tiletype_material.PLANT
            and m ~= df.tiletype_material.MUSHROOM
            and m ~= df.tiletype_material.CONSTRUCTION
            and m ~= df.tiletype_material.FEATURE
    end
    local function find_tiletype(material, shape)
        for i = 0, df.tiletype._last_item do
            local at = df.tiletype.attrs[i]
            if at.material == material and at.shape == shape then return i end
        end
    end
    return {
        name = 'underworld-safe boundary bulkhead',
        init = function(job)
            local map, a, dims = df.global.world.map, ctx.anchor, ctx.manifest.dims
            job.x0, job.y0 = a.off_x, a.off_y
            job.x1, job.y1 = a.off_x + dims.bx * 16 - 1, a.off_y + dims.by * 16 - 1
            job.changed, job.columns = 0, 0
            job.changed_blocks = {}
            job.surface_cache = {}
            job.columns_to_check = {}
            job.stone_wall = find_tiletype(df.tiletype_material.STONE, df.tiletype_shape.WALL)
            job.soil_wall = find_tiletype(df.tiletype_material.SOIL, df.tiletype_shape.WALL)
            if not job.stone_wall then error('could not find a stone wall tiletype for the boundary bulkhead') end
            local function surface_z(x, y)
                local key = x .. ':' .. y
                local cached = job.surface_cache[key]
                if cached ~= nil then return cached end
                local result = 1
                for z = map.z_count - 2, 1, -1 do
                    local tt = dfhack.maps.getTileType(x, y, z)
                    if is_surface_tile(tt) then result = z; break end
                end
                for z = map.z_count - 2, math.max(1, result - 6), -1 do
                    local b = dfhack.maps.getTileBlock(x, y, z)
                    if b then
                        local d = b.designation[x % 16][y % 16]
                        if d.flow_size > 0 then result = math.max(result, z) end
                    end
                end
                job.surface_cache[key] = result
                return result
            end
            job.tasks = {}
            local seen = {}
            local function add(x, y)
                if x < 0 or y < 0 or x >= map.x_count or y >= map.y_count then return end
                if x >= job.x0 and x <= job.x1 and y >= job.y0 and y <= job.y1 then return end
                local k = y * map.x_count + x
                if not seen[k] then seen[k] = true; job.tasks[#job.tasks + 1] = {x=x, y=y} end
            end
            for d = 1, 2 do
                for x = job.x0 - d, job.x1 + d do
                    add(x, job.y0 - d); add(x, job.y1 + d)
                end
                for y = job.y0 - d, job.y1 + d do
                    add(job.x0 - d, y); add(job.x1 + d, y)
                end
            end
            job.cursor = 1
            job.surface_z = surface_z
        end,
        total = function(job) return #(job.tasks or {}) end,
        pos = function(job) return job.cursor or 0 end,
        step = function(job, deadline)
            local map = df.global.world.map
            while job.cursor <= #job.tasks do
                local xy = job.tasks[job.cursor]
                local x, y = xy.x, xy.y
                local source_x = math.max(job.x0, math.min(job.x1, x))
                local source_y = math.max(job.y0, math.min(job.y1, y))
                local top = math.max(job.surface_z(x, y), job.surface_z(source_x, source_y)) + 2
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        local nx, ny = x + dx, y + dy
                        if nx >= 0 and ny >= 0 and nx < map.x_count and ny < map.y_count then
                            top = math.max(top, job.surface_z(nx, ny) + 1)
                        end
                    end
                end
                top = math.min(map.z_count - 2, top)
                -- Keep the independently generated underworld and its ceiling.
                local ceiling = column_ceiling(ctx, x, y)
                local bottom = ceiling >= 0 and (ceiling + 2)
                    or ((ctx.dest_deep_top or -1) >= 0 and (ctx.dest_deep_top + 2) or 1)
                bottom = math.max(1, bottom)
                job.columns_to_check[#job.columns_to_check + 1] = {x=x, y=y, bottom=bottom, top=top}
                if bottom <= top then
                    for z = bottom, top do
                        local block = dfhack.maps.getTileBlock(x, y, z)
                            or dfhack.maps.ensureTileBlock(x, y, z)
                        if block then
                            local lx, ly = x % 16, y % 16
                            local d = block.designation[lx][ly]
                            local current = block.tiletype[lx][ly]
                            local material = df.tiletype.attrs[current].material
                            local soil = material == df.tiletype_material.SOIL
                                or material == df.tiletype_material.GRASS_LIGHT
                                or material == df.tiletype_material.GRASS_DARK
                                or material == df.tiletype_material.GRASS_DRY
                                or material == df.tiletype_material.GRASS_DEAD
                            local wall = (soil and job.soil_wall) or job.stone_wall
                            if current ~= wall then
                                block.tiletype[lx][ly] = wall
                                job.changed = job.changed + 1
                            end
                            d.flow_size = 0
                            d.liquid_type = false
                            d.flow_forbid = true
                            d.water_table = false
                            clear_tile_claims(block, lx, ly)
                            job.changed_blocks[block] = true
                        end
                    end
                    job.columns = job.columns + 1
                end
                job.cursor = job.cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            for block in pairs(job.changed_blocks) do refresh_block_feature_refs(block) end
            ctx.boundary_seal_columns = job.columns_to_check
            ctx.boundary_seal_report = ('boundary bulkhead: sealed %d exterior columns with soil/stone walls; preserved the destination underworld below each local ceiling (%d tile changes)')
                :format(job.columns, job.changed)
            print('planeswalkers: ' .. ctx.boundary_seal_report)
            return true
        end,
    }
end


-- Validate the dangerous parts of the restored map before the load is reported
-- successful. This is intentionally strict: a broken boundary or unregistered
-- imported magma block is safer to report as a failed restore than to leave the
-- player with a fortress that silently drains or opens the underworld.
function integrity_phase(ctx)
    return {
        name = 'terrain integrity validation',
        init = function(job)
            job.collar = ctx.boundary_seal_columns or {}
            job.collar_i, job.collar_z = 1, nil
            job.magma_keys = {}
            local seen_magma = {}
            for key in pairs(ctx.source_magma_tile_keys or {}) do seen_magma[key] = true end
            for key in pairs(ctx.registered_magma_tile_keys or {}) do seen_magma[key] = true end
            for key in pairs(seen_magma) do job.magma_keys[#job.magma_keys + 1] = key end
            table.sort(job.magma_keys)
            job.magma_i = 1
            job.bad_collar, job.bad_magma, job.bad_underworld = 0, 0, 0
            job.checked_collar, job.checked_magma = 0, 0
        end,
        total = function(job)
            local n = 0
            for _, c in ipairs(job.collar) do n = n + math.max(0, c.top - c.bottom + 1) end
            return math.max(1, n + #job.magma_keys)
        end,
        pos = function(job) return job.checked_collar + job.checked_magma end,
        step = function(job, deadline)
            local map = df.global.world.map
            while job.collar_i <= #job.collar do
                local c = job.collar[job.collar_i]
                job.collar_z = job.collar_z or c.bottom
                while job.collar_z <= c.top do
                    local tt = dfhack.maps.getTileType(c.x, c.y, job.collar_z)
                    local block = dfhack.maps.getTileBlock(c.x, c.y, job.collar_z)
                    if not tt or df.tiletype.attrs[tt].shape ~= df.tiletype_shape.WALL or not block then
                        job.bad_collar = job.bad_collar + 1
                    else
                        local d = block.designation[c.x % 16][c.y % 16]
                        if d.flow_size > 0 or d.water_table then job.bad_collar = job.bad_collar + 1 end
                    end
                    job.checked_collar = job.checked_collar + 1
                    job.collar_z = job.collar_z + 1
                    if dfhack.getTickCount() >= deadline then return false end
                end
                job.collar_i = job.collar_i + 1
                job.collar_z = nil
            end
            while job.magma_i <= #job.magma_keys do
                local key = job.magma_keys[job.magma_i]
                local x, y, z = key:match('^(%-?%d+):(%-?%d+):(%-?%d+)$')
                x, y, z = tonumber(x), tonumber(y), tonumber(z)
                local block = x and dfhack.maps.getTileBlock(x, y, z) or nil
                if not block then
                    job.bad_magma = job.bad_magma + 1
                else
                    local d = block.designation[x % 16][y % 16]
                    local registered = ctx.registered_magma_tile_keys
                        and ctx.registered_magma_tile_keys[key]
                    if d.flow_size <= 0 or (d.liquid_type ~= true and d.liquid_type ~= 1)
                        or (registered and (not d.feature_global or d.flow_forbid
                            or block.global_feature ~= ctx.dest_magma_gidx))
                        or (not registered and (not d.flow_forbid or d.feature_global)) then
                        job.bad_magma = job.bad_magma + 1
                    end
                    if not ctx.anchor.full then
                        local ceiling = column_ceiling(ctx, x, y)
                        local fallback_ceiling = ctx.dest_footprint_deep_top
                            or ctx.dest_deep_top or -1
                        if (ceiling >= 0 and z <= ceiling + 1)
                            or (ceiling < 0 and fallback_ceiling >= 0
                                and z <= fallback_ceiling + 1) then
                            job.bad_underworld = job.bad_underworld + 1
                        end
                    end
                end
                job.checked_magma = job.checked_magma + 1
                job.magma_i = job.magma_i + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            local collar_total = 0
            for _, c in ipairs(job.collar) do collar_total = collar_total + math.max(0, c.top - c.bottom + 1) end
            ctx.terrain_integrity_report = ('terrain integrity: %d/%d boundary cells and %d/%d static magma tiles checked; %d boundary fault(s), %d magma fault(s), %d underworld collision(s)')
                :format(job.checked_collar, collar_total, job.checked_magma, #job.magma_keys,
                    job.bad_collar, job.bad_magma, job.bad_underworld)
            print('planeswalkers: ' .. ctx.terrain_integrity_report)
            if job.bad_collar > 0 or job.bad_magma > 0 or job.bad_underworld > 0 then
                qerror(('planeswalkers: terrain integrity validation failed (%d boundary, %d magma, %d underworld collision fault(s)); destination was modified but should not be treated as a completed transplant')
                    :format(job.bad_collar, job.bad_magma, job.bad_underworld))
            end
            return true
        end,
    }
end



function load_phases(ctx)
    local phases = {}

    -- Capture destination-only underworld ceilings before the terrain pass
    -- overwrites tiles. Lazy discovery after terrain restore can mistake an
    -- imported source SemiMoltenRock tile for a destination hell ceiling and
    -- falsely reject otherwise safe source magma as an underworld collision.
    table.insert(phases, {
        name = 'capture destination underworld ceilings',
        init = function(job)
            local a = ctx.anchor
            local rect = {
                x = a.off_x, y = a.off_y,
                w = ctx.manifest.dims.bx * 16,
                h = ctx.manifest.dims.by * 16,
            }
            if ctx.dest_deep_top == nil or ctx.dest_deep_min == nil then
                ctx.dest_deep_top, ctx.dest_deep_min = find_deep_top_z(rect)
            end
            ctx.ceil_cache = {}
            job.x0, job.y0 = rect.x, rect.y
            job.x1, job.y1 = rect.x + rect.w - 1, rect.y + rect.h - 1
            job.x, job.y = job.x0, job.y0
            job.columns = rect.w * rect.h
        end,
        total = function(job) return job.columns end,
        pos = function(job)
            return (job.y - job.y0) * (job.x1 - job.x0 + 1)
                + (job.x - job.x0)
        end,
        step = function(job, deadline)
            while job.y <= job.y1 do
                column_ceiling(ctx, job.x, job.y)
                job.x = job.x + 1
                if job.x > job.x1 then
                    job.x = job.x0
                    job.y = job.y + 1
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'terrain shapes',
        init = function(job)
            ctx.tiles_f = io.open(ctx.dir .. '/tiles.bin', 'rb')
            ctx.src = read_header(ctx.tiles_f)
            if ctx.manifest.format_version >= 5 then
                ctx.heat_f = io.open(ctx.dir .. '/heat.bin', 'rb')
                if not ctx.heat_f then qerror('planeswalkers: could not open heat.bin') end
                local hh = ctx.heat_f:read(common.HEADER_SIZE)
                if not hh or #hh ~= common.HEADER_SIZE then qerror('planeswalkers: truncated heat.bin header') end
                local hm, hbx, hby, hbz = string.unpack(common.HEADER_FMT, hh)
                if hm ~= 'PWH1' or hbx ~= ctx.src.bx or hby ~= ctx.src.by or hbz ~= ctx.src.bz then
                    qerror('planeswalkers: heat.bin header does not match tiles.bin')
                end
            end
            if ctx.dest_deep_top == nil or ctx.dest_deep_min == nil then
                local a = ctx.anchor
                local rect = {
                    x = a.off_x, y = a.off_y,
                    w = ctx.manifest.dims.bx * 16,
                    h = ctx.manifest.dims.by * 16,
                }
                ctx.dest_deep_top, ctx.dest_deep_min = find_deep_top_z(rect)
            end
            -- Cache the destination magma feature for diagnostics. Its feature
            -- and Z-bound grids remain untouched outside the imported footprint;
            -- source magma blocks inside the footprint are restored separately.
            local dest_magma = select(1, layer_features())
            ctx.dest_magma_gidx = dest_magma and dest_magma.gidx or -1
            -- Capture the complete destination band before replacing terrain.
            -- Never widen or rewrite the global feature bounds.
            ctx.dest_magma_top = find_magma_top_z(nil)
            ctx.dest_magma_bottom = find_magma_bottom_z(nil)
            ctx.native_magma_registration = can_register_origin_magma(ctx)
            ctx.magma_restore_report = ctx.native_magma_registration
                and 'global magma: imported magma fits inside the destination native Z band; registering compatible blocks'
                or 'global magma: imported magma is outside the destination native Z band; using static fallback' 
            ctx.paint_list = {}
            ctx.spire_feat, ctx.spire_hint = {}, {}
            ctx.mat_cache, ctx.tt_cache = {}, {}
            job.block_cursor = 0
            job.nb = ctx.src.bx * ctx.src.by * ctx.src.bz
            ctx.terrain_blocks_expected = job.nb
        end,
        total = function(job) return job.nb end,
        pos = function(job) return job.block_cursor end,
        step = function(job, deadline)
            local s = ctx.src
            while job.block_cursor < job.nb do
                local data = ctx.tiles_f:read(common.BLOCK_SIZE)
                if not data then break end
                local heat_data
                if ctx.heat_f then
                    heat_data = ctx.heat_f:read(common.HEAT_BLOCK_SIZE)
                    if not heat_data or #heat_data ~= common.HEAT_BLOCK_SIZE then
                        qerror('planeswalkers: heat.bin ended before tiles.bin')
                    end
                end
                local i = job.block_cursor
                local z = i // (s.bx * s.by)
                local by = (i % (s.bx * s.by)) // s.bx
                local bx = i % s.bx
                load_block(ctx, data, bx, by, z, heat_data)
                job.block_cursor = i + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.terrain_blocks_processed = job.block_cursor
            ctx.tiles_f:close()
            ctx.tiles_f = nil
            if ctx.heat_f then ctx.heat_f:close(); ctx.heat_f = nil end
            if ctx.z_clipped then
                common.add_skip(ctx, 'blocks-clipped-at-z-edge')
                ctx.skips['blocks-clipped-at-z-edge'].n = ctx.z_clipped
            end
            if ctx.deep_clipped then
                common.add_skip(ctx, 'blocks-below-hell-ceiling-untouched')
                ctx.skips['blocks-below-hell-ceiling-untouched'].n = ctx.deep_clipped
            end
            if ctx.magma_clipped then
                common.add_skip(ctx, 'blocks-at-or-below-magma-sea-boundary-not-transferred')
                ctx.skips['blocks-at-or-below-magma-sea-boundary-not-transferred'].n = ctx.magma_clipped
            end
            if ctx.deep_dropped then
                common.add_skip(ctx, 'origin-underworld-preserved-at-destination')
                ctx.skips['origin-underworld-preserved-at-destination'].n = ctx.deep_dropped
            end
            if ctx.hell_guarded then
                common.add_skip(ctx, 'tiles-at-hell-ceiling-guarded')
                ctx.skips['tiles-at-hell-ceiling-guarded'].n = ctx.hell_guarded
            end
            return true
        end,
    })

    -- Source magma-core blocks are omitted from tiles.bin and stored sparsely
    -- in magma.bin. Restore them after ordinary terrain has replaced the full
    -- source volume, but before material layers/veins are painted. The origin
    -- sea appears at its recorded depth immediately and remains static; the
    -- destination feature and its Z-bound arrays are not merged with it.
    local magma_phase = magma_restore_phase(ctx)
    if magma_phase then table.insert(phases, magma_phase) end

    -- Natural stone is painted alongside other explicit inorganic materials
    -- in the materials/veins phase below. Do not create or repurpose shared
    -- geological layers for imported stone: a region biome has only 16 shared
    -- layer slots, while an imported fort can contain many stone types.

    table.insert(phases, surface_buffer_phase(ctx))
    table.insert(phases, liquid_transition_cap_phase(ctx))
    table.insert(phases, boundary_collar_phase(ctx))

    if ctx.anchor.full then
        -- underworld anchoring can drop the whole source column relative to
        -- the destination's original terrain; anything of the destination
        -- left above the source's coverage would float in the imported sky
        table.insert(phases, {
            name = 'clear sky above coverage',
            init = function(job)
                job.z0 = math.max(1, ctx.src.bz + ctx.anchor.off_z)
                job.zi = job.z0
                job.bi = 0
            end,
            total = function(job)
                return math.max(0, df.global.world.map.z_count - job.z0)
            end,
            pos = function(job) return job.zi - job.z0 end,
            step = function(job, deadline)
                local map = df.global.world.map
                local nb = map.x_count_block * map.y_count_block
                while job.zi < map.z_count do
                    while job.bi < nb do
                        local bx, by = job.bi % map.x_count_block, job.bi // map.x_count_block
                        local block = dfhack.maps.getBlock(bx, by, job.zi)
                        if block then
                            local touched = false
                            for x = 0, 15 do
                                local ttcol, dscol = block.tiletype[x], block.designation[x]
                                for y = 0, 15 do
                                    local attrs = df.tiletype.attrs[ttcol[y]]
                                    if attrs.shape ~= df.tiletype_shape.EMPTY then
                                        touched = true
                                        ttcol[y] = df.tiletype.OpenSpace
                                        local d = dscol[y]
                                        d.flow_size = 0
                                        d.hidden = false
                                        d.subterranean = false
                                        d.outside = true
                                        d.light = true
                                    end
                                end
                            end
                            if touched then dfhack.maps.enableBlockUpdates(block, true, true) end
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
    end

    -- before the veins are painted: a registered spire keeps its FEATURE
    -- tiles, and only what could not be registered joins the paint list
    if not ctx.no_spires then table.insert(phases, spires_phase(ctx)) end

    -- Material category matching mirrors DFHack's TileTypes.cpp
    -- matchTileMaterial(): shape/special/direction/variant fallback followed
    -- by the two-step conversion through STONE. This keeps rough-hewn walls,
    -- boulders, fortifications, and brook tiles in a valid material category.
    local tile_match_tables
    local function build_tile_match_tables()
        if tile_match_tables then return end
        local tables = {}
        for tt = 0, df.tiletype._last_item do
            local a = df.tiletype.attrs[tt]
            if a and a.material ~= nil and a.shape ~= nil then
                local by_mat = tables[a.material] or {}; tables[a.material] = by_mat
                local by_shape = by_mat[a.shape] or {}; by_mat[a.shape] = by_shape
                local by_special = by_shape[a.special] or {}; by_shape[a.special] = by_special
                local by_dir = by_special[a.direction] or {}; by_special[a.direction] = by_dir
                by_dir[a.variant] = tt
            end
        end
        tile_match_tables = tables
    end

    local material_tiletype_cache = {}
    local function find_material_match(material, attrs)
        build_tile_match_tables()
        local by_mat = tile_match_tables[material]
        if not by_mat then return nil end

        local shape = attrs.shape
        local by_shape = by_mat[shape]
        if not by_shape then
            if shape == df.tiletype_shape.BROOK_BED then
                if by_mat[df.tiletype_shape.FORTIFICATION] then
                    shape = df.tiletype_shape.FORTIFICATION
                elseif by_mat[df.tiletype_shape.WALL] then
                    shape = df.tiletype_shape.WALL
                else return nil end
            elseif shape == df.tiletype_shape.FORTIFICATION then
                if by_mat[df.tiletype_shape.WALL] then shape = df.tiletype_shape.WALL else return nil end
            elseif shape == df.tiletype_shape.BROOK_TOP or shape == df.tiletype_shape.BOULDER
                or shape == df.tiletype_shape.PEBBLES then
                if by_mat[df.tiletype_shape.FLOOR] then shape = df.tiletype_shape.FLOOR else return nil end
            else
                return nil
            end
            by_shape = by_mat[shape]
        end

        local special = attrs.special
        local by_special = by_shape[special]
        if not by_special then
            if special == df.tiletype_special.TRACK and by_shape[df.tiletype_special.SMOOTH] then
                special = df.tiletype_special.SMOOTH
            elseif special == df.tiletype_special.NONE
                or special == df.tiletype_special.NORMAL
                or special == df.tiletype_special.SMOOTH
                or special == df.tiletype_special.WET
                or special == df.tiletype_special.FURROWED
                or special == df.tiletype_special.RIVER_SOURCE
                or special == df.tiletype_special.WATERFALL
                or special == df.tiletype_special.WORN_1
                or special == df.tiletype_special.WORN_2
                or special == df.tiletype_special.WORN_3
                or special == df.tiletype_special.TRACK then
                if by_shape[df.tiletype_special.NORMAL] then
                    special = df.tiletype_special.NORMAL
                elseif by_shape[df.tiletype_special.NONE] then
                    special = df.tiletype_special.NONE
                elseif by_shape[df.tiletype_special.SMOOTH] then
                    special = df.tiletype_special.SMOOTH
                else return nil end
            else
                return nil
            end
            by_special = by_shape[special]
        end

        local direction = attrs.direction
        local by_dir = by_special[direction]
        if not by_dir then
            by_dir = by_special['--------'] or by_special.NSEW or by_special['N-S-W-E-']
            if not by_dir then
                local first_key
                for k in pairs(by_special) do
                    if first_key == nil or tostring(k) < tostring(first_key) then first_key = k end
                end
                by_dir = first_key ~= nil and by_special[first_key] or nil
            end
        end
        if not by_dir then return nil end

        if by_dir[attrs.variant] ~= nil then return by_dir[attrs.variant] end
        local first_variant, first_tt
        for variant, tt in pairs(by_dir) do
            if first_variant == nil or variant < first_variant then
                first_variant, first_tt = variant, tt
            end
        end
        return first_tt
    end

    local function material_tiletype(source_tt, target_material)
        local key = source_tt .. ':' .. target_material
        local cached = material_tiletype_cache[key]
        if cached ~= nil then return cached or nil end
        local attrs = df.tiletype.attrs[source_tt]
        if not attrs then material_tiletype_cache[key] = false; return nil end
        local result = find_material_match(target_material, attrs)
        if result == nil and target_material ~= df.tiletype_material.STONE then
            local stone_tt = find_material_match(df.tiletype_material.STONE, attrs)
            if stone_tt then
                result = find_material_match(target_material, df.tiletype.attrs[stone_tt])
            end
        end
        material_tiletype_cache[key] = result or false
        return result
    end

    local function fallback_material_tiletype(ctx, job, block, x, y, z, target_material)
        local lx, ly = x % 16, y % 16
        local tt = block.tiletype[lx][ly]
        local attrs = df.tiletype.attrs[tt]
        local d = block.designation[lx][ly]
        local ok, painted = pcall(tiletypes.tiletypes_setTile, xyz2pos(x, y, z), {
            shape = attrs.shape, material = target_material,
            special = attrs.special, variant = attrs.variant,
            hidden = d.hidden and 1 or 0, light = d.light and 1 or 0,
            subterranean = d.subterranean and 1 or 0, skyview = d.outside and 1 or 0,
            aquifer = -1, autocorrect = 0,
        })
        local result = block.tiletype[lx][ly]
        local result_attrs = result and df.tiletype.attrs[result]
        if not ok or painted == false or not result_attrs
            or result_attrs.material ~= target_material then
            common.add_skip(ctx, 'material-tiletype-conversion-failed',
                ('%d,%d,%d -> %s'):format(x, y, z, tostring(target_material)))
            job.material_conversion_failures = (job.material_conversion_failures or 0) + 1
            return nil
        end
        return result
    end

    local function event_vein_code(ev)
        if ev.flags.cluster_small then return VEIN_CLUSTER_SMALL end
        if ev.flags.cluster_one then return VEIN_CLUSTER_ONE end
        if ev.flags.vein then return VEIN end
        if ev.flags.cluster then return VEIN_CLUSTER end
        return VEIN_UNSPECIFIED
    end

    local function set_event_flags(ev, code, discovered)
        ev.flags.cluster = code == VEIN_CLUSTER
        ev.flags.vein = code == VEIN
        ev.flags.cluster_small = code == VEIN_CLUSTER_SMALL
        ev.flags.cluster_one = code == VEIN_CLUSTER_ONE
        ev.flags.discovered = discovered and true or false
    end

    local function init_material_painter(job)
        job.paint_seen = {}
        job.pending_blocks = {}
        job.changed_blocks = {}
        job.flushed_blocks = 0
        job.dirty_cursor = 1
    end

    local function queue_material_paint(ctx, job, x, y, z, mat_idx, rflags)
        local coord = tile_key(x, y, z)
        local signature = mat_idx .. ':' .. rflags
        local previous = job.paint_seen[coord]
        if previous ~= nil then
            if previous ~= signature then
                common.add_skip(ctx, 'conflicting-material-record', coord)
                job.material_conflict_failures = (job.material_conflict_failures or 0) + 1
            end
            return
        end
        job.paint_seen[coord] = signature

        local midx = resolve_mat(ctx, mat_idx)
        if not midx then return end
        local raw = df.global.world.raws.inorganics.all[midx]
        if not raw then
            common.add_skip(ctx, 'material-not-paintable-stone', tostring(midx))
            return
        end
        if ctx.anchor and ctx.anchor.full and raw.id == 'SLADE' then return end
        if (rflags & TF_SOIL) ~= 0 or raw.flags.SOIL_ANY then
            if not set_soil_layer(ctx, x, y, z, midx) then
                common.add_skip(ctx, 'soil-layer-assignment-failed',
                    ('%s at %d,%d,%d'):format(raw.id, x, y, z))
            else
                local bkey = (z * df.global.world.map.y_count_block + (y // 16))
                    * df.global.world.map.x_count_block + (x // 16)
                job.changed_blocks[bkey] = dfhack.maps.getBlock(x // 16, y // 16, z)
            end
            return
        end
        if raw.material.flags.IS_METAL then
            common.add_skip(ctx, 'material-not-paintable-stone', raw.id)
            return
        end

        local map = df.global.world.map
        local bx, by = x // 16, y // 16
        local block = dfhack.maps.getBlock(bx, by, z)
        if not block then
            common.add_skip(ctx, 'mineral-paint-block-missing', coord)
            return
        end
        local lx, ly = x % 16, y % 16
        local tt = block.tiletype[lx][ly]
        local attrs = df.tiletype.attrs[tt]
        if attrs.material == df.tiletype_material.CONSTRUCTION
            or (df.tiletype[tt] and df.tiletype[tt]:find('Constructed')) then return end

        local vein_code = (rflags & TF_VEIN_TYPE_MASK) >> TF_VEIN_TYPE_SHIFT
        if vein_code > VEIN_UNSPECIFIED then vein_code = VEIN_CLUSTER end
        local source_stone = (rflags & TF_STONE_PAINT) ~= 0
            or attrs.material == df.tiletype_material.STONE
        local source_lava = (rflags & TF_LAVA_STONE) ~= 0
            or attrs.material == df.tiletype_material.LAVA_STONE
        local source_mineral = attrs.material == df.tiletype_material.MINERAL

        local target_material = df.tiletype_material.MINERAL
        if not source_mineral and (source_stone or source_lava) then
            local info = tile_geo_context(ctx, block, x, y, z)
            local layer_midx
            if info and info.geo then
                local layer = info.geo.layers[block.designation[lx][ly].geolayer_index]
                if layer then layer_midx = layer.mat_index end
            end
            local lava_midx = info and info.lava_stone or nil
            -- This is the same destination selection order as MapCache::setStoneAt:
            -- regional lava stone, then geological layer, otherwise a vein.
            if lava_midx ~= nil and lava_midx == midx then
                target_material = df.tiletype_material.LAVA_STONE
            elseif layer_midx ~= nil and layer_midx == midx then
                target_material = df.tiletype_material.STONE
            end
        end

        local target_tt = material_tiletype(tt, target_material)
        if not target_tt then
            target_tt = fallback_material_tiletype(ctx, job, block, x, y, z, target_material)
            if not target_tt then return end
        end

        local bkey = (z * map.y_count_block + by) * map.x_count_block + bx
        local pending = job.pending_blocks[bkey]
        if not pending then
            pending = {block = block, groups = {}, group_keys = {}, changed = {}, audit = {}}
            job.pending_blocks[bkey] = pending
            job.changed_blocks[bkey] = block
        end
        local local_key = lx * 16 + ly
        pending.changed[local_key] = {x = lx, y = ly}
        pending.audit[#pending.audit + 1] = {
            x = lx, y = ly, midx = midx, material = target_material,
            vein_code = vein_code, coord = coord,
        }

        local member = {x = lx, y = ly, tiletype = target_tt}
        if target_material == df.tiletype_material.MINERAL then
            local group_key = midx .. ':' .. vein_code
            local group = pending.groups[group_key]
            if not group then
                group = {midx = midx, vein_code = vein_code, discovered = false, members = {}}
                pending.groups[group_key] = group
                pending.group_keys[#pending.group_keys + 1] = group_key
            end
            if (rflags & TF_VEIN_DISCOVERED) ~= 0
                or not block.designation[lx][ly].hidden then
                group.discovered = true
            end
            group.members[#group.members + 1] = member
        else
            member.material = target_material
            pending.non_vein = pending.non_vein or {}
            pending.non_vein[#pending.non_vein + 1] = member
        end
    end

    local function flush_material_paints(ctx, job, deadline)
        if not job.flush_blocks then
            job.flush_blocks = {}
            for key in pairs(job.pending_blocks) do job.flush_blocks[#job.flush_blocks + 1] = key end
            table.sort(job.flush_blocks)
            job.flush_block_cursor = 1
            job.flush_done = 0
            job.flush_events = 0
            job.dirty_keys = {}
            for key in pairs(job.changed_blocks) do job.dirty_keys[#job.dirty_keys + 1] = key end
            table.sort(job.dirty_keys)
            job.dirty_count = #job.dirty_keys
        end

        while job.flush_block_cursor <= #job.flush_blocks do
            local bkey = job.flush_blocks[job.flush_block_cursor]
            local pending = job.pending_blocks[bkey]
            local block = pending.block

            -- Apply category tiletypes before event insertion. This means every
            -- tile is already classified as STONE/LAVA_STONE/MINERAL when the
            -- event masks become visible to DF.
            for _, member in ipairs(pending.non_vein or {}) do
                block.tiletype[member.x][member.y] = member.tiletype
            end
            for _, group_key in ipairs(pending.group_keys) do
                local group = pending.groups[group_key]
                for _, member in ipairs(group.members) do
                    block.tiletype[member.x][member.y] = member.tiletype
                end
            end

            -- First clear all old destination claims from every replaced tile.
            -- This is a distinct pass: clearing and merging in the same loop can
            -- erase a group assigned to an earlier event when a later event is
            -- visited.
            local event_count = #block.block_events
            for i = 0, event_count - 1 do
                local ev = block.block_events[i]
                if df.block_square_event_mineralst:is_instance(ev) then
                    for _, local_info in pairs(pending.changed) do
                        dfhack.maps.setTileAssignment(ev.tile_bitmask,
                            local_info.x, local_info.y, false)
                    end
                end
            end

            -- Reuse only a matching event that is now empty. Reusing an event
            -- that still owns untouched squares could change their discovered
            -- state when the imported group is added. All event references are
            -- consumed before any vector insertion occurs.
            local merged = {}
            for _, group_key in ipairs(pending.group_keys) do
                local group = pending.groups[group_key]
                for i = 0, event_count - 1 do
                    local ev = block.block_events[i]
                    if df.block_square_event_mineralst:is_instance(ev)
                        and ev.inorganic_mat == group.midx
                        and event_vein_code(ev) == group.vein_code then
                        local empty = true
                        for x = 0, 15 do
                            for y = 0, 15 do
                                if dfhack.maps.getTileAssignment(ev.tile_bitmask, x, y) then
                                    empty = false
                                    break
                                end
                            end
                            if not empty then break end
                        end
                        if empty then
                            set_event_flags(ev, group.vein_code, group.discovered)
                            for _, member in ipairs(group.members) do
                                dfhack.maps.setTileAssignment(ev.tile_bitmask,
                                    member.x, member.y, true)
                            end
                            merged[group] = true
                            break
                        end
                    end
                end
            end

            -- New events are fully initialized before insertion. No reference
            -- to an inserted event is retained across later vector operations.
            table.sort(pending.group_keys)
            for _, group_key in ipairs(pending.group_keys) do
                local group = pending.groups[group_key]
                if not merged[group] then
                    local inserted, insert_error = pcall(function()
                        local ev = df.block_square_event_mineralst:new()
                        ev.inorganic_mat = group.midx
                        for x = 0, 15 do
                            for y = 0, 15 do
                                dfhack.maps.setTileAssignment(ev.tile_bitmask, x, y, false)
                            end
                        end
                        set_event_flags(ev, group.vein_code, group.discovered)
                        for _, member in ipairs(group.members) do
                            dfhack.maps.setTileAssignment(ev.tile_bitmask,
                                member.x, member.y, true)
                        end
                        block.block_events:insert('#', ev)
                    end)
                    if not inserted then
                        common.add_skip(ctx, 'mineral-event-create-failed', tostring(insert_error))
                        job.material_event_failures = (job.material_event_failures or 0) + 1
                    else
                        job.flush_events = job.flush_events + 1
                    end
                end
            end

            -- Build a single claim index for this block. The previous audit
            -- rescanned every event for every material tile, making this stage
            -- scale as events x painted tiles.
            local event_claims = {}
            local final_event_count = #block.block_events
            for i = 0, final_event_count - 1 do
                local ev = block.block_events[i]
                if df.block_square_event_mineralst:is_instance(ev) then
                    local code = event_vein_code(ev)
                    for x = 0, 15 do
                        for y = 0, 15 do
                            if dfhack.maps.getTileAssignment(ev.tile_bitmask, x, y) then
                                local key = x * 16 + y
                                local claim = event_claims[key]
                                if not claim then
                                    claim = {count = 0, midx = ev.inorganic_mat, vein_code = code}
                                    event_claims[key] = claim
                                end
                                claim.count = claim.count + 1
                                if claim.midx ~= ev.inorganic_mat or claim.vein_code ~= code then
                                    claim.conflict = true
                                end
                            end
                        end
                    end
                end
            end

            -- Lightweight invariant audit: a mineral-backed tile must be
            -- MINERAL and be claimed by exactly one matching event. Layer-backed
            -- categories must match the geology/lava material selected above.
            for _, check in ipairs(pending.audit) do
                local tt = block.tiletype[check.x][check.y]
                local attrs = df.tiletype.attrs[tt]
                local ok = attrs.material == check.material
                local claim = event_claims[check.x * 16 + check.y]
                if ok and check.material == df.tiletype_material.MINERAL then
                    ok = claim ~= nil and claim.count == 1 and not claim.conflict
                        and claim.midx == check.midx and claim.vein_code == check.vein_code
                elseif ok and check.material == df.tiletype_material.STONE then
                    ok = claim == nil
                    if ok then
                        local info = tile_geo_context(ctx, block,
                            block.map_pos.x + check.x, block.map_pos.y + check.y, block.map_pos.z)
                        local layer = info and info.geo
                            and info.geo.layers[block.designation[check.x][check.y].geolayer_index]
                        ok = layer ~= nil and layer.mat_index == check.midx
                    end
                elseif ok and check.material == df.tiletype_material.LAVA_STONE then
                    ok = claim == nil
                    if ok then
                        local info = tile_geo_context(ctx, block,
                            block.map_pos.x + check.x, block.map_pos.y + check.y, block.map_pos.z)
                        ok = info ~= nil and info.lava_stone == check.midx
                    end
                end
                if not ok then
                    common.add_skip(ctx, 'material-assignment-audit-failed', check.coord)
                    job.material_audit_failures = (job.material_audit_failures or 0) + 1
                end
            end

            job.flush_done = job.flush_done + 1
            job.flush_block_cursor = job.flush_block_cursor + 1
            if dfhack.getTickCount() >= deadline then return false end
        end

        while job.dirty_cursor <= #job.dirty_keys do
            local key = job.dirty_keys[job.dirty_cursor]
            local block = job.changed_blocks[key]
            if block then dfhack.maps.enableBlockUpdates(block, true, true) end
            job.dirty_cursor = job.dirty_cursor + 1
            if dfhack.getTickCount() >= deadline then return false end
        end
        if #job.dirty_keys > 0 then df.global.world.reindex_pathfinding = true end
        local conversion_failures = job.material_conversion_failures or 0
        local event_failures = job.material_event_failures or 0
        local conflict_failures = job.material_conflict_failures or 0
        local audit_failures = job.material_audit_failures or 0
        if conversion_failures + event_failures + conflict_failures + audit_failures > 0 then
            qerror(('planeswalkers: material restore validation failed (tiletype conversions: %d; mineral events: %d; conflicting records: %d; tile audits: %d); restore stopped rather than leaving known inconsistent stone')
                :format(conversion_failures, event_failures, conflict_failures, audit_failures))
        end
        ctx.material_restore_report = ('materials: %d block(s) processed; %d mineral event(s) created; tile assignments verified')
            :format(job.flush_done, job.flush_events)
        print('planeswalkers: ' .. ctx.material_restore_report)
        return true
    end

    table.insert(phases, {
        name = 'materials/veins',
        init = function(job)
            job.paint_cursor = 1
            init_material_painter(job)
        end,
        total = function(job)
            local flush_total = job.flush_blocks and #job.flush_blocks or 0
            local dirty_total = job.dirty_keys and #job.dirty_keys or 0
            if not job.flush_blocks then
                for _ in pairs(job.pending_blocks or {}) do flush_total = flush_total + 1 end
            end
            if not job.dirty_keys then
                for _ in pairs(job.changed_blocks or {}) do dirty_total = dirty_total + 1 end
            end
            return #ctx.paint_list + flush_total + dirty_total
        end,
        pos = function(job)
            if not job.paint_done then return job.paint_cursor - 1 end
            return #ctx.paint_list + (job.flush_done or 0) + math.max(0, (job.dirty_cursor or 1) - 1)
        end,
        step = function(job, deadline)
            while job.paint_cursor <= #ctx.paint_list do
                local x, y, z, mat_idx, rflags = string.unpack('<I2I2I2I2B',
                    ctx.paint_list[job.paint_cursor])
                queue_material_paint(ctx, job, x, y, z, mat_idx, rflags)
                job.paint_cursor = job.paint_cursor + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            job.paint_done = true
            return flush_material_paints(ctx, job, deadline)
        end,
    })

    if not ctx.preserve_depths then table.insert(phases, magma_sea_phase(ctx, false)) end

    -- Seal only the imported perimeter and any vertical water shaft that has
    -- an uninterrupted open path into magma. This targets the known DF
    -- water-falling-into-magma cave-collapse notification loop without
    -- disabling the destination's unrelated liquid simulation.
    table.insert(phases, {
        name = 'liquid boundary and waterfall safety',
        init = function(job)
            local a, dims = ctx.anchor, ctx.manifest.dims
            job.x0, job.y0 = a.off_x, a.off_y
            job.x1, job.y1 = a.off_x + dims.bx * 16 - 1, a.off_y + dims.by * 16 - 1
            job.x, job.y = job.x0, job.y0
            job.columns = (job.x1 - job.x0 + 1) * (job.y1 - job.y0 + 1)
            job.sealed_edge, job.sealed_waterfall = 0, 0
            job.sealed_magma_neighbours = 0
        end,
        total = function(job) return job.columns end,
        pos = function(job) return (job.y - job.y0) * (job.x1 - job.x0 + 1) + (job.x - job.x0) end,
        step = function(job, deadline)
            local map = df.global.world.map
            while job.y <= job.y1 do
                local x, y = job.x, job.y
                local edge = x == job.x0 or x == job.x1 or y == job.y0 or y == job.y1
                local water_above = {}
                local ceiling = column_ceiling(ctx, x, y)
                local fallback_ceiling = ctx.dest_footprint_deep_top or ctx.dest_deep_top or -1
                local bottom_z = ceiling >= 0 and (ceiling + 2)
                    or (fallback_ceiling >= 0 and (fallback_ceiling + 2) or 1)
                for z = map.z_count - 2, math.max(1, bottom_z), -1 do
                    local block = dfhack.maps.getTileBlock(x, y, z)
                    if block then
                        local lx, ly = x % 16, y % 16
                        local tt = block.tiletype[lx][ly]
                        local d = block.designation[lx][ly]
                        local shape = df.tiletype.attrs[tt].shape
                        local liquid = d.flow_size > 0
                        local magma = liquid and (d.liquid_type == true or d.liquid_type == 1)
                        local water = liquid and not magma
                        local source_magma = ctx.source_magma_tile_keys
                            and ctx.source_magma_tile_keys[tile_key(x, y, z)]
                        if edge and (liquid or is_brook_tile(tt)) then
                            -- A perimeter seal prevents a destination brook or
                            -- river above the protected underworld from feeding
                            -- into the imported volume.
                            d.flow_forbid = true
                            if water or is_brook_tile(tt) then
                                job.sealed_edge = job.sealed_edge + 1
                            end
                        end
                        if water and shape == df.tiletype_shape.EMPTY then
                            water_above[#water_above + 1] = {block = block, x = lx, y = ly}
                        elseif source_magma then
                            if #water_above > 0 then
                                for _, p in ipairs(water_above) do
                                    p.block.designation[p.x][p.y].flow_forbid = true
                                    job.sealed_waterfall = job.sealed_waterfall + 1
                                end
                                water_above = {}
                            end
                        elseif magma or shape ~= df.tiletype_shape.EMPTY then
                            -- A native destination magma tile is never edited;
                            -- it merely stops this column's waterfall scan.
                            water_above = {}
                        end
                    else
                        water_above = {}
                    end
                end
                job.x = job.x + 1
                if job.x > job.x1 then job.x = job.x0; job.y = job.y + 1 end
                if dfhack.getTickCount() >= deadline then return false end
            end
            -- Liquid update flags are block-wide, so never freeze a whole
            -- 16x16 block merely because it contains one static origin magma
            -- tile. Seal the six face-neighbours of each imported magma tile
            -- instead. This keeps it from spreading while allowing unrelated
            -- destination underworld liquids in the same block to keep updating.
            local neighbour_offsets = {
                {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
            }
            local sealed_neighbours = {}
            for key in pairs(ctx.source_magma_tile_keys or {}) do
                local sx, sy, sz = key:match('^(%-?%d+):(%-?%d+):(%-?%d+)$')
                sx, sy, sz = tonumber(sx), tonumber(sy), tonumber(sz)
                if sx then
                    for _, offset in ipairs(neighbour_offsets) do
                        local nx, ny, nz = sx + offset[1], sy + offset[2], sz + offset[3]
                        local neighbour_key = tile_key(nx, ny, nz)
                        if not ctx.source_magma_tile_keys[neighbour_key]
                            and nx >= job.x0 and nx <= job.x1
                            and ny >= job.y0 and ny <= job.y1
                            and nz >= 1 and nz < map.z_count - 1 then
                            local ceiling = column_ceiling(ctx, nx, ny)
                            local fallback = ctx.dest_footprint_deep_top or ctx.dest_deep_top or -1
                            local safe = (ceiling >= 0 and nz > ceiling + 1)
                                or (ceiling < 0 and (fallback < 0 or nz > fallback + 1))
                            if safe and not sealed_neighbours[neighbour_key] then
                                local b = dfhack.maps.getTileBlock(nx, ny, nz)
                                if b then
                                    b.designation[nx % 16][ny % 16].flow_forbid = true
                                    sealed_neighbours[neighbour_key] = true
                                    job.sealed_magma_neighbours = job.sealed_magma_neighbours + 1
                                end
                            end
                        end
                    end
                end
            end
            ctx.liquid_safety_report = ('liquid safety: sealed %d perimeter water tile(s), %d waterfall tile(s), and %d neighbours around static origin magma')
                :format(job.sealed_edge, job.sealed_waterfall, job.sealed_magma_neighbours)
            print('planeswalkers: ' .. ctx.liquid_safety_report)
            return true
        end,
    })


    table.insert(phases, {
        name = 'grass/moss',
        init = function(job)
            ctx.grass_f = io.open(ctx.dir .. '/grass.bin', 'rb')  -- absent pre-grass snapshot
            ctx.plant_cache, ctx.plant_by_id, ctx.grass_plants = {}, {}, {}
            for i, pr in ipairs(df.global.world.raws.plants.all) do
                ctx.plant_by_id[pr.id] = i
                if pr.flags.GRASS then
                    table.insert(ctx.grass_plants,
                                 {idx = i, depth = pr.underground_depth_min})
                end
            end
            job.grass_done = 0
        end,
        total = function()
            return (ctx.manifest.counts and ctx.manifest.counts.grass) or 0
        end,
        pos = function(job) return job.grass_done end,
        step = function(job, deadline)
            while ctx.grass_f do
                local head = ctx.grass_f:read(common.GRASS_REC_SIZE)
                if not head or #head < common.GRASS_REC_SIZE then break end
                local amounts = ctx.grass_f:read(common.GRASS_AMOUNT_SIZE)
                if not amounts or #amounts < common.GRASS_AMOUNT_SIZE then break end
                local bx, by, z, pidx, depth = string.unpack(common.GRASS_REC, head)
                job.grass_done = job.grass_done + 1
                if not ctx.preserve_depths or (z + ctx.anchor.off_z) > ctx.preserve_depths_cutoff then
                    local plant_index = resolve_plant(ctx, pidx, depth)
                    if plant_index then
                        apply_grass(ctx, bx, by, z, plant_index, amounts)
                        ctx.grass_applied = (ctx.grass_applied or 0) + 1
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            if ctx.grass_f then
                ctx.grass_f:close()
                ctx.grass_f = nil
            end
            return true
        end,
    })

    table.insert(phases, {
        name = 'constructions',
        init = function(job)
            job.cons = common.read_json(ctx.dir .. '/constructions.json') or {list = {}}
            job.con_cursor = 1
            ctx.constructions_restored = 0
        end,
        total = function(job) return #job.cons.list end,
        pos = function(job) return job.con_cursor end,
        step = function(job, deadline)
            local a = ctx.anchor
            while job.con_cursor <= #job.cons.list do
                local c = job.cons.list[job.con_cursor]
                job.con_cursor = job.con_cursor + 1
                local z = c.z + a.off_z
                local deep_ok = common.above_transfer_cutoff(ctx, z)
                if ctx.preserve_depths then
                    deep_ok = deep_ok and z > ctx.preserve_depths_cutoff
                elseif not a.full then
                    deep_ok = deep_ok and z > (ctx.dest_deep_min or -1)
                    if deep_ok and z <= (ctx.dest_deep_top or -1) + 1 then
                        -- mixed band: same per-column ceiling rule as tiles
                        local cc = column_ceiling(ctx, c.x + a.off_x, c.y + a.off_y)
                        deep_ok = cc >= 0 and z > cc
                    end
                end
                if z >= 1 and z < df.global.world.map.z_count - 1
                    and deep_ok then
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
                        -- leaked on purpose rather than freed from Lua
                        common.add_skip(ctx, 'construction-pos-occupied')
                    else
                        ctx.constructions_restored = ctx.constructions_restored + 1
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
            local function open_at(x, y, z)
                local t = dfhack.maps.getTileType(x, y, z)
                return t and df.tiletype.attrs[t].shape ~= df.tiletype_shape.WALL
            end
            -- surface unsticking must land units ON something: a unit parked
            -- in mid-air makes every item minted at its feet a falling
            -- projectile (in_job), which building construction refuses
            local function walkable_at(x, y, z)
                local t = dfhack.maps.getTileType(x, y, z)
                if not t then return false end
                return df.tiletype_shape.attrs[df.tiletype.attrs[t].shape].walkable
            end
            -- a unit stuck deep down (an entombed demon above all) must stay
            -- down there: search sideways/downwards for open hell, never lift
            -- it up into the fort
            local function unstick_deep(u)
                for z = u.pos.z, math.max(1, u.pos.z - 4), -1 do
                    if z ~= u.pos.z and open_at(u.pos.x, u.pos.y, z) then
                        dfhack.units.teleport(u, xyz2pos(u.pos.x, u.pos.y, z))
                        return true
                    end
                    for r = 1, 12 do
                        for _, d in ipairs({{r,0},{-r,0},{0,r},{0,-r},{r,r},{r,-r},{-r,r},{-r,-r}}) do
                            if open_at(u.pos.x + d[1], u.pos.y + d[2], z) then
                                dfhack.units.teleport(u, xyz2pos(u.pos.x + d[1], u.pos.y + d[2], z))
                                return true
                            end
                        end
                    end
                end
                return false
            end
            local deep_z = (ctx.dest_deep_top or -1) + 1
            for _, u in ipairs(df.global.world.units.active) do
                local tt = dfhack.maps.getTileType(u.pos.x, u.pos.y, u.pos.z)
                if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.WALL
                    and not (ctx.preserve_depths and u.pos.z <= ctx.preserve_depths_cutoff) then
                    if u.pos.z <= deep_z then
                        -- a deep unit (an entombed demon above all) must NEVER
                        -- be lifted toward the fort: sideways or down into open
                        -- hell, or it stays walled in where it can hurt no one
                        if unstick_deep(u) then
                            common.add_skip(ctx, 'unit-unstuck-from-wall')
                        else
                            common.add_skip(ctx, 'deep-unit-left-entombed')
                        end
                    else
                        local moved = false
                        for z = u.pos.z + 1, df.global.world.map.z_count - 2 do
                            if walkable_at(u.pos.x, u.pos.y, z) then
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
            end
            df.global.world.reindex_pathfinding = true
            df.global.gps.force_full_display_count = 1
            dfhack.run_command('fix/occupancy')
            clear_liquid_flags(ctx.preserve_depths and ctx.preserve_depths_cutoff or nil, {
                x = ctx.anchor.off_x, y = ctx.anchor.off_y,
                w = ctx.manifest.dims.bx * 16, h = ctx.manifest.dims.by * 16,
            }, ctx.source_magma_tile_keys or {})
            return true
        end,
    })

    return phases
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
