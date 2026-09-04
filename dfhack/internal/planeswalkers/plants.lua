-- Trees, saplings and shrubs for fort/planeswalkers. A plant is a world-local
-- object, so each is saved as what it is and where and rebuilt through the
-- plant plugin. A full tree also carries its generated trunk/branch/root
-- layout (plant_tree_info) and the tree tiles it stamps on the map; both are
-- saved verbatim into trees.bin and rebuilt in place, so a carried tree is
-- the same tree -- not a sapling regrown into a different shape.
--@module = true

local common = reqscript('internal/planeswalkers/common')

local FILE = '/plants.json'
local TREES = '/trees.bin'

-- trees.bin: per tree, at the byte offset the plants.json record names --
--   <I2I2I2I2I2 dim_x dim_y body_height roots_depth local_trunk_height
--   body: body_height rows of dim_x*dim_y uint16 (plant_tree_tile.whole)
--   extents: 4 arrays (x1, x2, y1, y2) of body_height int16
--   roots: roots_depth rows of dim_x*dim_y uint8 (plant_root_tile.whole)
--   <I4 n, then n x <i2i2i2I2 dx dy dz tiletype-legend-index (tree tiles,
--   relative to the plant's position)
local TREE_HDR = '<I2I2I2I2I2'

-- address of a df object / primitive array
local function addr_of(obj)
    local _, a = obj:sizeof()
    return a
end

-- read the pointer stored in a pointer-typed field or array slot
local function ptr_at(addr)
    return df.reinterpret_cast('uintptr_t', addr).value
end

local function tree_out(ctx, p, t)
    local n = t.dim_x * t.dim_y
    local parts = {string.pack(TREE_HDR, t.dim_x, t.dim_y, t.body_height, t.roots_depth,
                               t.local_trunk_height)}
    local body = addr_of(t.body)
    for zi = 0, t.body_height - 1 do
        local row = df.reinterpret_cast('uint16_t', ptr_at(body + zi * 8))
        local vals = {}
        for i = 0, n - 1 do vals[i + 1] = string.pack('<I2', row:_displace(i).value) end
        parts[#parts + 1] = table.concat(vals)
    end
    for _, name in ipairs({'extent_x1', 'extent_x2', 'extent_y1', 'extent_y2'}) do
        local arr = t[name]
        local vals = {}
        for zi = 0, t.body_height - 1 do vals[zi + 1] = string.pack('<i2', arr:_displace(zi).value) end
        parts[#parts + 1] = table.concat(vals)
    end
    local roots = addr_of(t.roots)
    for zi = 0, t.roots_depth - 1 do
        local row = df.reinterpret_cast('uint8_t', ptr_at(roots + zi * 8))
        local vals = {}
        for i = 0, n - 1 do vals[i + 1] = string.pack('<I1', row:_displace(i).value) end
        parts[#parts + 1] = table.concat(vals)
    end
    -- the tree's tiles: every tree-material tile inside its bounds
    local x0, y0 = p.pos.x - (t.dim_x >> 1), p.pos.y - (t.dim_y >> 1)
    local tiles = {}
    local map = df.global.world.map
    for z = p.pos.z - t.roots_depth, p.pos.z + t.body_height - 1 do
        if z >= 0 and z < map.z_count then
            for y = y0, y0 + t.dim_y - 1 do
                for x = x0, x0 + t.dim_x - 1 do
                    local block = dfhack.maps.getTileBlock(x, y, z)
                    if block then
                        local tt = block.tiletype[x % 16][y % 16]
                        if df.tiletype.attrs[tt].material == df.tiletype_material.TREE then
                            tiles[#tiles + 1] = string.pack('<i2i2i2I2', x - p.pos.x, y - p.pos.y,
                                z - p.pos.z, ctx.legend_tt:intern(df.tiletype[tt]))
                        end
                    end
                end
            end
        end
    end
    parts[#parts + 1] = string.pack('<I4', #tiles)
    parts[#parts + 1] = table.concat(tiles)
    return table.concat(parts)
end

-- rebuild a plant_tree_info from its trees.bin record. The arrays are plain
-- new[]-style allocations DF frees with delete[] when the tree dies or is
-- felled; DFHack's df.new allocates them the same way.
local function set_ptr(obj, field, arr)
    df.reinterpret_cast('uintptr_t', addr_of(obj:_field(field))).value = addr_of(arr)
end

local function tree_in(f, off)
    f:seek('set', off)
    local dx, dy, bh, rd, lth = string.unpack(TREE_HDR, f:read(10))
    local n = dx * dy
    local t = df.plant_tree_info:new()
    t.dim_x, t.dim_y, t.body_height, t.roots_depth, t.local_trunk_height = dx, dy, bh, rd, lth
    local body = df.new('uintptr_t', math.max(1, bh))
    for zi = 0, bh - 1 do
        local row = df.new('uint16_t', n)
        local data = f:read(n * 2)
        for i = 0, n - 1 do row[i] = string.unpack('<I2', data, i * 2 + 1) end
        body[zi] = addr_of(row)
    end
    set_ptr(t, 'body', body)
    for _, name in ipairs({'extent_x1', 'extent_x2', 'extent_y1', 'extent_y2'}) do
        local arr = df.new('int16_t', math.max(1, bh))
        local data = f:read(bh * 2)
        for zi = 0, bh - 1 do arr[zi] = string.unpack('<i2', data, zi * 2 + 1) end
        set_ptr(t, name, arr)
    end
    local roots = df.new('uintptr_t', math.max(1, rd))
    for zi = 0, rd - 1 do
        local row = df.new('uint8_t', n)
        local data = f:read(n)
        for i = 0, n - 1 do row[i] = string.unpack("<I1", data, i + 1) end
        roots[zi] = addr_of(row)
    end
    set_ptr(t, 'roots', roots)
    local ntiles = string.unpack('<I4', f:read(4))
    local tiles = f:read(ntiles * 8) or ''
    return t, tiles, ntiles
end

local function paint_tree_tiles(ctx, p, tiles, ntiles)
    local map = df.global.world.map
    local painted = 0
    for i = 0, ntiles - 1 do
        local dx, dy, dz, ti = string.unpack('<i2i2i2I2', tiles, i * 8 + 1)
        local name = ctx.legend_tt:get(ti)
        local tt = name and df.tiletype[name]
        local x, y, z = p.pos.x + dx, p.pos.y + dy, p.pos.z + dz
        if tt and z >= 0 and z < map.z_count then
            local block = dfhack.maps.getTileBlock(x, y, z)
            if block then
                block.tiletype[x % 16][y % 16] = tt
                painted = painted + 1
            end
        end
    end
    return painted
end

function save_phases(ctx)
    return {{
        name = 'plants',
        init = function(job)
            job.out = {v = 2, list = {}}
            job.cursor = 0
            job.trees = 0
            job.tf = io.open(ctx.dir .. TREES, 'wb')
            job.toff = 0
        end,
        total = function(job) return #df.global.world.plants.all end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local o = ctx.origin
            local all = df.global.world.plants.all
            while job.cursor < #all do
                local p = all[job.cursor]
                job.cursor = job.cursor + 1
                if common.in_footprint(ctx, p.pos.x, p.pos.y) then
                    local ok, err = pcall(function()
                        local raw = df.plant_raw.find(p.material)
                        if raw then
                            local tree = p.tree_info ~= nil
                            local rec = {
                                x = p.pos.x - o.x, y = p.pos.y - o.y, z = p.pos.z,
                                id = raw.id, tree = tree or nil, ptype = p.type,
                                grow = p.grow_counter, hp = p.hitpoints,
                                dead = p.damage_flags.dead or nil,
                            }
                            if tree and job.tf then
                                local blob = tree_out(ctx, p, p.tree_info)
                                rec.ti = job.toff
                                job.tf:write(blob)
                                job.toff = job.toff + #blob
                                job.trees = job.trees + 1
                            end
                            table.insert(job.out.list, rec)
                        end
                    end)
                    if not ok then common.add_skip(ctx, 'plant-save-error', tostring(err)) end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            if job.tf then job.tf:close() job.tf = nil end
            common.write_json(ctx.dir .. FILE, job.out)
            ctx.manifest.counts.plants = #job.out.list
            print(('planeswalkers: %d plant(s) saved (%d trees with their layout)'):format(#job.out.list, job.trees))
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

local function run_quiet(...)
    local args = {...}
    local ok, res = pcall(function() return dfhack.run_command_silent(table.unpack(args)) end)
    return ok and res or ''
end

function load_phases(ctx)
    return {{
        name = 'plants',
        init = function(job)
            job.data = common.read_json(ctx.dir .. FILE) or {list = {}}
            job.cursor = 1
            job.made, job.grown, job.rebuilt = 0, 0, 0
            job.to_grow = {}
            if dfhack.filesystem.exists(ctx.dir .. TREES) then
                job.tf = io.open(ctx.dir .. TREES, 'rb')
            end
        end,
        total = function(job) return #job.data.list + 1 end,
        pos = function(job) return job.cursor end,
        step = function(job, deadline)
            local a = ctx.anchor
            local map = df.global.world.map
            while job.cursor <= #job.data.list do
                local rec = job.data.list[job.cursor]
                job.cursor = job.cursor + 1
                local x, y, z = rec.x + a.off_x, rec.y + a.off_y, rec.z + a.off_z
                if z >= 1 and z < map.z_count - 1 and not rec.dead then
                    local before = #df.global.world.plants.all
                    local pos = ('%d,%d,%d'):format(x, y, z)
                    local out = run_quiet('plant', 'create', rec.id, pos, '-c')
                    if #df.global.world.plants.all > before then
                        job.made = job.made + 1
                        local p = df.global.world.plants.all[#df.global.world.plants.all - 1]
                        local rebuilt = false
                        if rec.tree and rec.ti and job.tf then
                            -- the tree as it was: its layout, then its tiles
                            local ok, err = pcall(function()
                                local t, tiles, ntiles = tree_in(job.tf, rec.ti)
                                p.tree_info = t
                                if rec.ptype then p.type = rec.ptype end
                                paint_tree_tiles(ctx, p, tiles, ntiles)
                            end)
                            if ok then
                                rebuilt = true
                                job.rebuilt = job.rebuilt + 1
                            else
                                common.add_skip(ctx, 'tree-layout-error', rec.id .. ' ' .. tostring(err))
                            end
                        end
                        pcall(function()
                            if rec.hp then p.hitpoints = rec.hp end
                            if rec.grow and (rebuilt or not rec.tree) then p.grow_counter = rec.grow end
                        end)
                        if rec.tree and not rebuilt then table.insert(job.to_grow, pos) end
                    else
                        common.add_skip(ctx, 'plant-not-placed', rec.id .. ' ' .. (out:match('[^\n]+') or ''))
                    end
                end
                if dfhack.getTickCount() >= deadline then return false end
            end
            -- grow the saplings that were trees, one command each (the plugin
            -- takes a position), against the deadline
            while #job.to_grow > 0 do
                local pos = table.remove(job.to_grow)
                run_quiet('plant', 'grow', pos)
                job.grown = job.grown + 1
                if dfhack.getTickCount() >= deadline then return false end
            end
            if job.tf then job.tf:close() job.tf = nil end
            ctx.plants_report = ('%d plant(s) placed, %d tree(s) rebuilt with their layout, %d regrown from saplings')
                :format(job.made, job.rebuilt, job.grown)
            print('planeswalkers: ' .. ctx.plants_report)
            return true
        end,
    }}
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
