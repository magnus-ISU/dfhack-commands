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

local function inorganic_token(idx)
    local raw = df.global.world.raws.inorganics.all[idx]
    return raw and ('INORGANIC:' .. raw.id) or nil
end

-- tile record flag bits (the 7th byte of common.TILE_REC)
local TF_SOIL = 1       -- material is a soil layer, restored via geolayer remap
local TF_TUBE = 2       -- tile belonged to an adamantine tube feature at the source

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

-- the hell ceiling: the world's bottom is slade floor, then the open
-- underworld (demons!), capped by a semi-molten-rock ceiling, with the magma
-- sea band above that. The magma sea band is fair game -- a fort's deepest
-- workshops and tombs live there, and the save's own layers replace it on
-- load -- but nothing may ever open a path into the underworld: one open
-- tile punched through its ceiling releases the destination's demons.
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

-- bx/by/z are ABSOLUTE block coords in this map; grass records (and the
-- caller's tile records) are stored relative to the snapshot footprint
local function save_block(ctx, block, bx, by, z)
    if not block then return common.ZERO_BLOCK end
    local o = ctx.origin
    save_grass(ctx, block, bx - o.bx, by - o.by, z)
    local veins = vein_grid(block)
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
                local tok, is_soil = layer_mat_token(ctx, bx * 16 + x, by * 16 + y,
                                                     d.geolayer_index)
                if tok and is_soil then
                    mat_idx = ctx.legend_mat:intern(tok)
                    flags = flags | TF_SOIL
                end
            elseif PLANT_MATS[mat_cat] then
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
                        flags = flags | TF_SOIL
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
    local o = ctx.origin
    local nb = o.wb * o.hb * map.z_count_block
    local phases = {}

    table.insert(phases, {
        name = 'terrain',
        init = function(job)
            ctx.layer_cache = {}
            -- everything is saved, hell included; the loader decides what may
            -- be applied. The lowest hell-ceiling z is the cross-world
            -- alignment datum for same-size (underworld-anchored) restores.
            ctx.deep_top = select(2, find_deep_top_z(o))
            ctx.manifest.dims.deep_top = ctx.deep_top
            ctx.tiles_f = io.open(ctx.dir .. '/tiles.bin', 'wb')
            ctx.grass_f = io.open(ctx.dir .. '/grass.bin', 'wb')
            -- header flag bit 0: tile records carry TF_TUBE; bit 1: designation
            -- bits carry flow_forbid
            ctx.tiles_f:write(string.pack(common.HEADER_FMT, 'PWT1',
                o.wb, o.hb, map.z_count_block,
                ctx.manifest.dims.surface, 3))
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
                ctx.tiles_f:write(save_block(ctx, dfhack.maps.getBlock(bx, by, z), bx, by, z))
                job.block_cursor = i + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            ctx.tiles_f:close()
            ctx.tiles_f = nil
            ctx.grass_f:close()
            ctx.grass_f = nil
            if ctx.plant_degraded and ctx.plant_degraded > 0 then
                common.add_skip(ctx, 'plant-tiles-degraded (regrow naturally)', nil)
                ctx.skips['plant-tiles-degraded (regrow naturally)'].n = ctx.plant_degraded
            end
            ctx.manifest.counts.grass = ctx.grass_count or 0
            ctx.manifest.complete.grass = true
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
                if not common.in_footprint(ctx, c.pos.x, c.pos.y) then goto continue end
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

-- the source's lowest hell-ceiling z, for underworld alignment: stored in
-- the manifest at save time; older snapshots are scanned for the first
-- z-slab of tiles.bin that contains a semi-molten tile
local function src_deep_top(src_dims, dir, legend_tt)
    if src_dims.deep_top and src_dims.deep_top >= 0 then return src_dims.deep_top end
    local smr
    for i, tok in ipairs(legend_tt and legend_tt.list or {}) do
        if tok == 'SemiMoltenRock' then smr = i break end
    end
    if not smr then return nil end
    local f = io.open(dir .. '/tiles.bin', 'rb')
    if not f then return nil end
    f:read(common.HEADER_SIZE)
    local per_z = src_dims.bx * src_dims.by
    local needle = string.pack('<I2', smr)
    for z = 0, src_dims.bz - 1 do
        local slab = f:read(common.BLOCK_SIZE * per_z)
        if not slab then break end
        local at = 1
        while true do
            at = slab:find(needle, at, true)
            if not at then break end
            -- the tiletype index is the first field of each 7-byte record;
            -- reject matches that straddle other fields
            if (at - 1) % common.TILE_REC_SIZE == 0 then
                f:close()
                return z
            end
            at = at + 1
        end
    end
    f:close()
    return nil
end

-- compute placement of the source volume in the destination map.
-- returns offsets in tiles (block-aligned horizontally) or nil, err.
--
-- Same-size embarks anchor at the UNDERWORLD, not the surface: both hells
-- sit at the same z, the whole footprint is replaced column for column
-- (anchor.full), and the destination keeps its own underworld feature and
-- demons while taking the source's geometry. The surface then lands wherever
-- the source's column height puts it -- edge cliffs against the neighbouring
-- world tiles are the accepted cost. Mismatched sizes fall back to surface
-- anchoring with the hell-ceiling guards.
function compute_anchor(src_dims, dir, legend_tt)
    local map = df.global.world.map
    if map.x_count_block < src_dims.bx or map.y_count_block < src_dims.by then
        return nil, ('destination embark (%dx%d blocks) is smaller than the source (%dx%d)')
            :format(map.x_count_block, map.y_count_block, src_dims.bx, src_dims.by)
    end
    if map.x_count_block == src_dims.bx and map.y_count_block == src_dims.by then
        local _, dest_min = find_deep_top_z()
        local src_min = src_deep_top(src_dims, dir, legend_tt)
        if dest_min and dest_min >= 0 and src_min then
            local off_z = dest_min - src_min
            return {
                off_x = 0, off_y = 0, off_bx = 0, off_by = 0,
                off_z = off_z,
                dest_surface = src_dims.surface + off_z,
                full = true,
            }
        end
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

local function load_block(ctx, data, src_bx, src_by, src_z)
    local anchor = ctx.anchor
    local z = src_z + anchor.off_z
    if z < 1 or z >= df.global.world.map.z_count - 1 then
        ctx.z_clipped = (ctx.z_clipped or 0) + 1
        return
    end
    local mixed = false
    if not ctx.anchor.full then
        -- surface-anchored (mismatched sizes): the two hells sit at different
        -- z, so the destination's must be protected tile by tile
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
    -- a destination spire under the incoming terrain: every tile the source
    -- writes leaves the tube's registration, so no source tile can ever read
    -- as a breach of a tube that no longer exists there
    local tube = block_is_tube(ctx, block)
    local off = 1
    local touched = false
    for x = 0, 15 do
        local ttcol, dscol = block.tiletype[x], block.designation[x]
        for y = 0, 15 do
            local tt_idx, mat_idx, dbits, rflags = string.unpack(common.TILE_REC, data, off)
            off = off + common.TILE_REC_SIZE
            local tt = resolve_tt(ctx, tt_idx)
            -- surface-anchored mode only: the source's underworld shape would
            -- land mid-rock as a second hell, so its glowing-pit tiles are
            -- dropped (semi-molten rock still transfers as solid filler). In
            -- full (underworld-anchored) mode the hells overlap, so the
            -- source's hell geometry replaces the destination's outright.
            if tt == df.tiletype.EeriePit and not ctx.anchor.full then
                ctx.deep_dropped = (ctx.deep_dropped or 0) + 1
                tt = nil
            end
            if tt and mixed then
                -- write only strictly ABOVE this column's own ceiling: the
                -- ceiling tile itself stays unmineable semi-molten rock and
                -- the hell interior below it is never entered
                local c = column_ceiling(ctx, bx * 16 + x, by * 16 + y)
                if c < 0 or z <= c then
                    ctx.hell_guarded = (ctx.hell_guarded or 0) + 1
                    tt = nil
                end
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
                if ctx.src.flags & 2 == 2 then d.flow_forbid = bits.flow_forbid end
                if bits.liquid_type == 1 and bits.flow_size > 0 and z > (ctx.magma_zmax or -1) then
                    ctx.magma_zmax = z
                end
                if tube and d.feature_local then
                    d.feature_local = false
                    ctx.tube_disarmed = (ctx.tube_disarmed or 0) + 1
                end
                -- a spire's own adamantine is not painted as a vein here: the
                -- spires phase registers it on a tube feature and only paints
                -- what could not be registered
                local spire = gather_spire_tile(ctx, bx * 16 + x, by * 16 + y, z,
                                                tt, mat_idx, rflags)
                if mat_idx ~= 0 and not spire then
                    ctx.paint_list[#ctx.paint_list + 1] =
                        string.pack('<I2I2I2I2B', bx * 16 + x, by * 16 + y, z, mat_idx, rflags)
                end
            end
        end
    end
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
        dfhack.maps.enableBlockUpdates(block, true, true)
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

-- ---- the magma sea and the underworld: layer registration -------------------
-- DF keeps the magma sea full by refilling, at the map edges, the tiles it
-- knows belong to the magma-core layer: the block's global_feature and each
-- tile's feature_global bit, within the layer's z band per embark square.
-- Imported terrain keeps the destination's registration, which describes the
-- destination's sea, not the one that arrived; magma outside it simply flows
-- off the map (a whole sea was gone within a few seasons). This pass
-- registers every magma tile on the magma-core layer, every hell tile on the
-- underworld layer, and widens each layer's z band to what is actually there.

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

local function is_hell_tile(tt)
    local a = df.tiletype.attrs[tt]
    return tt == df.tiletype.EeriePit or tt == df.tiletype.GlowingBarrier
        or tt == df.tiletype.GlowingFloor or a.material == df.tiletype_material.FEATURE
end

-- refill: also put back the liquid the snapshot recorded (a sea that already
-- drained), from tiles.bin
-- global_feature_sq: a block registered on a layer also names WHICH world
-- tile of that layer applies, as an index into the layer's region_coords.
-- DF assigns squares near a world-tile boundary to the neighbouring tile's
-- entry, so the index is taken from a block DF itself registered in the same
-- embark square (any layer, translated by world coordinate), falling back to
-- the block's own region_pos. Without it a registered block is not part of
-- the sea for DF, and the sea runs off the map edges (measured: walling the
-- edges stopped the loss; nothing else did).
local function square_world_coords(zmax)
    local map = df.global.world.map
    local regions = df.global.world.world_data.underground_regions
    local out = {}
    for z = 0, zmax do
        for by = 0, map.y_count_block - 1 do
            for bx = 0, map.x_count_block - 1 do
                local sqk = (bx * 16 // 48) .. ':' .. (by * 16 // 48)
                if not out[sqk] then
                    local b = dfhack.maps.getBlock(bx, by, z)
                    if b and b.global_feature >= 0 and b.global_feature_sq >= 0 then
                        local r = regions[b.global_feature]
                        if r and b.global_feature_sq < #r.region_coords.x then
                            out[sqk] = {r.region_coords.x[b.global_feature_sq],
                                        r.region_coords.y[b.global_feature_sq]}
                        end
                    end
                end
            end
        end
    end
    return out
end

local function layer_sq_index(gidx, wx, wy)
    local r = df.global.world.world_data.underground_regions[gidx]
    if not r then return -1 end
    for i = 0, #r.region_coords.x - 1 do
        if r.region_coords.x[i] == wx and r.region_coords.y[i] == wy then return i end
    end
    return -1
end

function magma_sea_phase(ctx, refill)
    return {
        name = refill and 'magma sea (refill + register)' or 'magma sea (register)',
        init = function(job)
            job.magma, job.hell = layer_features()
            job.sq_coords = square_world_coords(math.min(df.global.world.map.z_count - 2, 60))
            job.sq_index = {}  -- 'gidx:sqk' -> index
            job.zmax = math.min(df.global.world.map.z_count - 2,
                                math.max(ctx.magma_zmax or 0, (ctx.dest_deep_top or 0) + 20, 40))
            job.z = 0
            job.by = 0
            job.sq = {}  -- per embark square: {mmin, mmax, hmin, hmax}
            job.registered, job.refilled, job.statics = 0, 0, 0
            -- a snapshot without the flow_forbid bit (or a repair): make the
            -- sea static the way DF generates it, or it runs off the map edges
            job.make_static = refill or not (ctx.src and ctx.src.flags & 2 == 2)
            if refill and ctx.dir then
                job.f = io.open(ctx.dir .. '/tiles.bin', 'rb')
                job.src = read_header(job.f)
            end
        end,
        total = function(job) return job.zmax + 1 end,
        pos = function(job) return job.z end,
        step = function(job, deadline)
            local map = df.global.world.map
            local a = ctx.anchor
            while job.z <= job.zmax do
                local z = job.z
                while job.by < map.y_count_block do
                    local by = job.by
                    for bx = 0, map.x_count_block - 1 do
                        local block = dfhack.maps.getBlock(bx, by, z)
                        if block then
                            if job.f then
                                -- the snapshot's liquid on this block, if it covers it
                                local sbx, sby, sz = bx - a.off_bx, by - a.off_by, z - a.off_z
                                if sbx >= 0 and sby >= 0 and sz >= 0 and sbx < job.src.bx
                                    and sby < job.src.by and sz < job.src.bz then
                                    local i = (sz * job.src.by + sby) * job.src.bx + sbx
                                    job.f:seek('set', common.HEADER_SIZE + i * common.BLOCK_SIZE)
                                    local data = job.f:read(common.BLOCK_SIZE)
                                    if data then
                                        local off = 1
                                        for x = 0, 15 do
                                            for y = 0, 15 do
                                                local _, _, dbits = string.unpack(common.TILE_REC, data, off)
                                                off = off + common.TILE_REC_SIZE
                                                local bits = common.unpack_dsgn(dbits)
                                                if bits.liquid_type == 1 and bits.flow_size > 0 then
                                                    local tt = block.tiletype[x][y]
                                                    if df.tiletype.attrs[tt].shape ~= df.tiletype_shape.WALL then
                                                        local d = block.designation[x][y]
                                                        if d.flow_size < bits.flow_size or not (d.liquid_type == true or d.liquid_type == 1) then
                                                            d.flow_size = bits.flow_size
                                                            d.liquid_type = 1
                                                            job.refilled = job.refilled + 1
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            local nm, nh = 0, 0
                            for x = 0, 15 do
                                local dcol, tcol = block.designation[x], block.tiletype[x]
                                for y = 0, 15 do
                                    local d = dcol[y]
                                    -- the one-bit liquid_type reads back as a boolean
                                    local magma = d.flow_size > 0 and (d.liquid_type == true or d.liquid_type == 1)
                                    local hell = is_hell_tile(tcol[y])
                                    if magma and job.magma then
                                        if not d.feature_global then job.registered = job.registered + 1 end
                                        d.feature_global = true
                                        nm = nm + 1
                                        if job.make_static and not d.flow_forbid then
                                            d.flow_forbid = true
                                            job.statics = job.statics + 1
                                        end
                                    elseif hell and job.hell then
                                        d.feature_global = true
                                        nh = nh + 1
                                    end
                                    if magma or hell then
                                        local sqk = (bx * 16 // 48) .. ':' .. (by * 16 // 48)
                                        local sq = job.sq[sqk] or {}
                                        job.sq[sqk] = sq
                                        if magma then
                                            sq.mmin = math.min(sq.mmin or z, z); sq.mmax = math.max(sq.mmax or z, z)
                                        else
                                            sq.hmin = math.min(sq.hmin or z, z); sq.hmax = math.max(sq.hmax or z, z)
                                        end
                                    end
                                end
                            end
                            -- a block belongs to one layer: the sea where it holds
                            -- magma, hell where it holds hell and no magma
                            local function assign(layer)
                                block.global_feature = layer.gidx
                                local sqk = (bx * 16 // 48) .. ':' .. (by * 16 // 48)
                                local key = layer.gidx .. ':' .. sqk
                                local idx = job.sq_index[key]
                                if idx == nil then
                                    local wc = job.sq_coords[sqk]
                                    idx = wc and layer_sq_index(layer.gidx, wc[1], wc[2]) or -1
                                    if idx < 0 then
                                        idx = layer_sq_index(layer.gidx, block.region_pos.x, block.region_pos.y)
                                    end
                                    job.sq_index[key] = idx
                                end
                                block.global_feature_sq = idx
                            end
                            if nm > 0 and job.magma then
                                assign(job.magma)
                            elseif nh > 0 and job.hell and block.global_feature < 0 then
                                assign(job.hell)
                            end
                        end
                    end
                    job.by = by + 1
                    if dfhack.getTickCount() >= deadline then return false end
                end
                job.by = 0
                job.z = z + 1
            end
            if job.f then job.f:close() job.f = nil end
            -- the layers' z bands per embark square (16 entries for a 4x4
            -- embark, in square order x-major as DF lays them out)
            local function set_band(feat, key_min, key_max)
                if not feat or not feat.init.feature then return end
                local ft = feat.init.feature
                local w = df.global.world.map.x_count // 48
                for i = 0, #ft.min_map_z - 1 do
                    local sx, sy = i // math.max(1, (#ft.min_map_z // math.max(1, w))), i % math.max(1, (#ft.min_map_z // math.max(1, w)))
                    local sq = job.sq[sx .. ':' .. sy]
                    if sq and sq[key_min] then
                        ft.min_map_z[i] = math.min(ft.min_map_z[i], sq[key_min])
                        ft.max_map_z[i] = math.max(ft.max_map_z[i], sq[key_max])
                    end
                end
            end
            pcall(set_band, job.magma, 'mmin', 'mmax')
            pcall(set_band, job.hell, 'hmin', 'hmax')
            ctx.magma_report = ('magma sea: %d tile(s) newly registered to the magma layer, %d made static%s')
                :format(job.registered, job.statics, refill and (', %d tile(s) refilled'):format(job.refilled) or '')
            print('planeswalkers: ' .. ctx.magma_report)
            return true
        end,
    }
end

function load_phases(ctx)
    local phases = {}

    table.insert(phases, {
        name = 'terrain shapes',
        init = function(job)
            ctx.tiles_f = io.open(ctx.dir .. '/tiles.bin', 'rb')
            ctx.src = read_header(ctx.tiles_f)
            ctx.dest_deep_top, ctx.dest_deep_min = find_deep_top_z()
            ctx.paint_list = {}
            ctx.spire_feat, ctx.spire_hint = {}, {}
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
                common.add_skip(ctx, 'blocks-below-hell-ceiling-untouched')
                ctx.skips['blocks-below-hell-ceiling-untouched'].n = ctx.deep_clipped
            end
            if ctx.deep_dropped then
                common.add_skip(ctx, 'source-underworld-tiles-dropped')
                ctx.skips['source-underworld-tiles-dropped'].n = ctx.deep_dropped
            end
            if ctx.hell_guarded then
                common.add_skip(ctx, 'tiles-at-hell-ceiling-guarded')
                ctx.skips['tiles-at-hell-ceiling-guarded'].n = ctx.hell_guarded
            end
            return true
        end,
    })

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

    -- before the veins are painted: a registered spire keeps its FEATURE
    -- tiles, and only what could not be registered joins the paint list
    if not ctx.no_spires then table.insert(phases, spires_phase(ctx)) end

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
                if midx and ctx.anchor.full then
                    -- imported slade keeps its FEATURE tiletype and resolves
                    -- through the destination's own underworld feature;
                    -- painting it as a vein would make hell's floor mineable
                    local raw = df.global.world.raws.inorganics.all[midx]
                    if raw and raw.id == 'SLADE' then goto continue end
                end
                if midx and rflags & 1 == 1 then
                    -- soil: keep the soil tiletype, remap the tile's geolayer so
                    -- the tile resolves as the source soil (e.g. sand)
                    set_soil_layer(ctx, x, y, z, midx)
                elseif midx then
                    local tt = dfhack.maps.getTileType(x, y, z)
                    local attrs = df.tiletype.attrs[tt]
                    if attrs.material == df.tiletype_material.CONSTRUCTION
                        or df.tiletype[tt]:find('Constructed') then
                        goto continue  -- never repaint a construction tile
                    end
                    local raw = df.global.world.raws.inorganics.all[midx]
                    if raw and raw.flags.SOIL_ANY then
                        -- a soil recorded off a stone-shaped tile's geolayer: pin it
                        -- the soil way; the tiletypes plugin refuses soils as veins
                        set_soil_layer(ctx, x, y, z, midx)
                        goto continue
                    end
                    if not raw or raw.material.flags.IS_METAL then
                        -- same test the tiletypes plugin applies (it logs each refusal)
                        common.add_skip(ctx, 'material-not-paintable-stone', raw and raw.id or midx)
                        goto continue
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

    table.insert(phases, magma_sea_phase(ctx, false))

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
                local plant_index = resolve_plant(ctx, pidx, depth)
                if plant_index then
                    apply_grass(ctx, bx, by, z, plant_index, amounts)
                    ctx.grass_applied = (ctx.grass_applied or 0) + 1
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
        end,
        total = function(job) return #job.cons.list end,
        pos = function(job) return job.con_cursor end,
        step = function(job, deadline)
            local a = ctx.anchor
            while job.con_cursor <= #job.cons.list do
                local c = job.cons.list[job.con_cursor]
                job.con_cursor = job.con_cursor + 1
                local z = c.z + a.off_z
                local deep_ok = true
                if not a.full then
                    deep_ok = z > (ctx.dest_deep_min or -1)
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
                if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.WALL then
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
            return true
        end,
    })

    return phases
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
