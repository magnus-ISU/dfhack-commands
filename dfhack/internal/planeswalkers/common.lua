-- Shared plumbing for fort/planeswalkers: snapshot paths/manifest/legends,
-- packed binary tile IO, and the chunked pipeline driver.
--@module = true

local json = require('json')

SNAP_ROOT = dfhack.getDFPath() .. '/dfhack-config/scripts/data/planeswalkers'
FORMAT_VERSION = 1

-- DF strings are cp437; JSON must be UTF-8 (json.decode_file hard-rejects otherwise)
function u(s) return dfhack.df2utf(s or '') end
function fromu(s) return dfhack.utf2df(s or '') end

function snap_dir(name) return SNAP_ROOT .. '/' .. name end

-- ---- footprint: the part of this map a save covers ---------------------------
-- Whole map by default. A fort that was itself restored here from a snapshot
-- smaller than the embark keeps that original size and area when it is saved
-- again: the footprint is then the rectangle it was restored into, and every
-- coordinate written is relative to its corner.

function whole_map_origin()
    local map = df.global.world.map
    return {bx = 0, by = 0, wb = map.x_count_block, hb = map.y_count_block,
            x = 0, y = 0, w = map.x_count, h = map.y_count}
end

function footprint_origin(anchor)
    local map = df.global.world.map
    if not anchor or not anchor.bx or not anchor.by then return nil end
    local bx, by = anchor.off_bx or 0, anchor.off_by or 0
    if bx < 0 or by < 0 or bx + anchor.bx > map.x_count_block
        or by + anchor.by > map.y_count_block then
        return nil
    end
    if anchor.bx == map.x_count_block and anchor.by == map.y_count_block then
        return nil  -- same size: nothing to cut
    end
    return {bx = bx, by = by, wb = anchor.bx, hb = anchor.by,
            x = bx * 16, y = by * 16, w = anchor.bx * 16, h = anchor.by * 16}
end

function in_footprint(ctx, x, y)
    local o = ctx.origin
    return x >= o.x and x < o.x + o.w and y >= o.y and y < o.y + o.h
end

-- nearest tile of the footprint to (x, y)
function clamp_to_footprint(ctx, x, y)
    local o = ctx.origin
    return math.max(o.x, math.min(o.x + o.w - 1, x)),
           math.max(o.y, math.min(o.y + o.h - 1, y))
end

function valid_name(name)
    return type(name) == 'string' and name:match('^[%w_%-%.]+$') and name ~= '_spike'
end

function write_json(path, data)
    dfhack.filesystem.mkdir_recursive(path:match('^(.*)/[^/]+$'))
    json.encode_file(data, path, {pretty = false})
end

function read_json(path)
    if not dfhack.filesystem.exists(path) then return nil end
    local ok, data = pcall(json.decode_file, path)
    if ok then return data end
    return nil
end

function list_snapshots()
    local out = {}
    if not dfhack.filesystem.isdir(SNAP_ROOT) then return out end
    for _, e in ipairs(dfhack.filesystem.listdir_recursive(SNAP_ROOT, 0) or {}) do
        if e.isdir then
            local name = e.path:match('[^/]+$')
            local mf = read_json(snap_dir(name) .. '/manifest.json')
            if mf then table.insert(out, {name = name, manifest = mf}) end
        end
    end
    table.sort(out, function(a, b) return (a.manifest.created or '') < (b.manifest.created or '') end)
    return out
end

-- ---- legends: intern tokens, store lists, resolve back ----------------------
-- idx 0 is always "absent/native"; idx >= 1 indexes .list (1-based).

Legend = Legend or {}
Legend.__index = Legend

function Legend.new(tbl)
    local self = setmetatable({list = {}, map = {}}, Legend)
    for i, tok in ipairs(tbl or {}) do
        self.list[i] = tok
        self.map[tok] = i
    end
    return self
end

function Legend:intern(tok)
    local i = self.map[tok]
    if not i then
        i = #self.list + 1
        self.list[i] = tok
        self.map[tok] = i
    end
    return i
end

function Legend:get(i) return self.list[i] end

-- ---- packed tile records ----------------------------------------------------
-- header: '<c4 I2 I2 I2 I2 I2' = magic PWT1, dim_bx, dim_by, z_count, surface_z, flags
-- per block: 256 x '<I2 I2 I2 B' = tiletype legend idx (0 = leave dest tile alone),
--   mat legend idx (0 = dest-native material), designation bits, flags
--   (bit 0 soil layer, bit 1 tile of an adamantine tube feature).
-- blocks in z-major order: for z 0..z_count-1, for by, for bx.

TILE_REC = '<I2I2I2B'
TILE_REC_SIZE = 7
BLOCK_SIZE = TILE_REC_SIZE * 256
HEADER_FMT = '<c4I2I2I2I2I2'
HEADER_SIZE = 14
ZERO_BLOCK = string.rep(string.pack(TILE_REC, 0, 0, 0, 0), 256)

-- grass.bin: one record per (block, grass plant) that has any coverage.
-- header '<I2 I2 I2 I2 B' = block x, block y, z, plant legend idx,
-- the plant's underground_depth_min (for substituting a same-depth grass when
-- the destination world lacks the exact plant), then 256 raw amount bytes in
-- x-major order. Grass lives in block_square_event_grassst, not in the tile
-- record, so it rides in its own file rather than widening TILE_REC.
GRASS_REC = '<I2I2I2I2B'
GRASS_REC_SIZE = 9
GRASS_AMOUNT_SIZE = 256

-- designation bit packing (16 bits)
function pack_dsgn(d)
    return d.flow_size
        | (d.liquid_type and 1 or 0) << 3
        | (d.hidden and 1 or 0) << 4
        | (d.subterranean and 1 or 0) << 5
        | (d.light and 1 or 0) << 6
        | (d.outside and 1 or 0) << 7
        | (d.water_stagnant and 1 or 0) << 8
        | (d.water_salt and 1 or 0) << 9
        | (d.flow_forbid and 1 or 0) << 10  -- the magma sea is STATIC; without this it runs off the map
end

function unpack_dsgn(bits)
    return {
        flow_size = bits & 7,
        liquid_type = (bits >> 3) & 1,
        hidden = (bits >> 4) & 1 == 1,
        subterranean = (bits >> 5) & 1 == 1,
        light = (bits >> 6) & 1 == 1,
        outside = (bits >> 7) & 1 == 1,
        water_stagnant = (bits >> 8) & 1 == 1,
        water_salt = (bits >> 9) & 1 == 1,
        flow_forbid = (bits >> 10) & 1 == 1,
    }
end

-- ---- chunked pipeline driver ------------------------------------------------
-- One job at a time, pumped from the overlay (which runs even while paused) or
-- from `fort/planeswalkers step`. Each phase: {name=..., init=fn(job)?,
-- step=fn(job, deadline_ms) -> done?, total=fn(job)?, pos=fn(job)?}.
-- Keep the job in dfhack.internal so a script reload doesn't orphan it.

local function jobs() return dfhack.internal end

-- dfhack.internal outlives the world, which is what keeps a job alive across a
-- script reload -- but it also means a job left behind by world A is still sitting
-- there when world B loads. The overlay pump runs every frame in dwarfmode, so on
-- the next embark it would resume that job against a ctx full of freed world-A
-- handles, forcing pause_state=true every frame while it did. Stamp every job with
-- a token that is replaced on each map load; a job whose token no longer matches is
-- from a dead world and gets dropped instead of pumped.
function new_world_token()
    jobs().planeswalkers_world_token = {}
    return jobs().planeswalkers_world_token
end

function world_token()
    return jobs().planeswalkers_world_token or new_world_token()
end

function current_job()
    local j = jobs().planeswalkers_job
    if not j then return nil end
    if j.world_token ~= world_token() then
        jobs().planeswalkers_job = nil
        if j.ctx and j.ctx.close_all then pcall(j.ctx.close_all, j.ctx) end
        dfhack.printerr(('planeswalkers: dropped stale job %q left over from a ' ..
            'previous world'):format(tostring(j.label)))
        return nil
    end
    return j
end

function cancel_job()
    local j = current_job()
    jobs().planeswalkers_job = nil
    return j ~= nil
end

function start_job(label, phases, ctx, on_done)
    if current_job() then qerror('planeswalkers: a job is already running (' ..
        current_job().label .. '); `fort/planeswalkers cancel` first') end
    jobs().planeswalkers_job = {
        label = label, phases = phases, ctx = ctx, on_done = on_done,
        phase_idx = 1, inited = false, last_report = dfhack.getTickCount(),
        started = dfhack.getTickCount(), keep_paused = true,
        world_token = world_token(),
    }
    print(('planeswalkers: %s started (%d phases); game stays paused until done')
        :format(label, #phases))
end

BUDGET_MS = 30

local function pump_inner(budget_ms)
    local job = current_job()
    if not job then return false end
    -- every phase reads the live map/unit/item vectors; pumping without them is
    -- how a half-finished job turns into a freeze rather than an error
    if not dfhack.world.isFortressMode() or not dfhack.isMapLoaded() then
        return false
    end
    if job.keep_paused then df.global.pause_state = true end
    local deadline = dfhack.getTickCount() + (budget_ms or BUDGET_MS)
    local ok, err = pcall(function()
        while dfhack.getTickCount() < deadline do
            local phase = job.phases[job.phase_idx]
            if not phase then return end
            if not job.inited then
                if phase.init then phase.init(job) end
                job.inited = true
            end
            if phase.step(job, deadline) then
                print(('planeswalkers: %s: %s done'):format(job.label, phase.name))
                job.phase_idx = job.phase_idx + 1
                job.inited = false
                if not job.phases[job.phase_idx] then
                    jobs().planeswalkers_job = nil
                    if job.on_done then job.on_done(job) end
                    print(('planeswalkers: %s FINISHED in %.1fs'):format(job.label,
                        (dfhack.getTickCount() - job.started) / 1000))
                    return
                end
            end
        end
    end)
    if not ok then
        jobs().planeswalkers_job = nil
        if job.ctx and job.ctx.close_all then pcall(job.ctx.close_all, job.ctx) end
        dfhack.printerr(('planeswalkers: %s ABORTED in phase %s: %s'):format(
            job.label, job.phases[job.phase_idx] and job.phases[job.phase_idx].name or '?',
            tostring(err)))
        return false
    end
    -- periodic progress line. Everything here must be error-proof: pump runs
    -- inside the overlay's update, and a Lua error escaping it took DF down
    -- with a double-free abort (the next phase's total() was read before its
    -- init had run, on a job field that init creates).
    job = current_job()
    if job and dfhack.getTickCount() - job.last_report > 2000 then
        job.last_report = dfhack.getTickCount()
        local phase = job.phases[job.phase_idx]
        local extra = ''
        if phase and job.inited and phase.pos and phase.total then
            local okp, p, t = pcall(function() return phase.pos(job), phase.total(job) end)
            if okp and p and t and t > 0 then
                extra = (' %d/%d (%d%%)'):format(p, t, p * 100 // t)
            end
        end
        pcall(print, ('planeswalkers: %s: %s%s'):format(job.label, phase and phase.name or '?', extra))
    end
    return current_job() ~= nil
end

function pump(budget_ms)
    local ok, res = pcall(pump_inner, budget_ms)
    if ok then return res end
    dfhack.printerr('planeswalkers: pump error: ' .. tostring(res))
    return false
end

function job_status()
    local job = current_job()
    if not job then return nil end
    local phase = job.phases[job.phase_idx]
    return ('%s: phase %d/%d (%s)'):format(job.label, job.phase_idx, #job.phases,
                                           phase and phase.name or '?')
end

-- ---- item minting helpers ----------------------------------------------------

-- Items are created at their creator's feet. A creator left hovering over open
-- space (the terrain was just rewritten under everyone) turns every minted
-- item into a FALLING PROJECTILE flagged in_job -- and building construction
-- refuses in_job items, which once silently failed all 1000+ buildings of a
-- restore. Mint at a unit standing on walkable ground whenever one exists.
local function solid_at(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return false end
    local shape = df.tiletype.attrs[tt].shape
    return shape ~= df.tiletype_shape.EMPTY and df.tiletype_shape.attrs[shape].walkable
end

-- find solid, walkable ground near (x, y): same column first, then a widening
-- square, a band of z-levels around the given one
function find_ground_near(x, y, z, radius, zspan)
    radius, zspan = radius or 24, zspan or 12
    for r = 0, radius, 2 do
        for dz = 0, zspan do
            for _, zz in ipairs(dz == 0 and {z} or {z - dz, z + dz}) do
                if zz >= 1 and zz < df.global.world.map.z_count - 1 then
                    for dx = -r, r, 2 do
                        for dy = -r, r, 2 do
                            if math.max(math.abs(dx), math.abs(dy)) == r
                                and solid_at(x + dx, y + dy, zz) then
                                return xyz2pos(x + dx, y + dy, zz)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- a citizen standing on solid ground; when none does (the whole surface was
-- just rewritten under the embark party), the first one is moved onto the
-- nearest solid tile -- an item minted mid-air or inside rock is a falling
-- projectile, which no building will accept
function creator_unit(near)
    local fallback
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        fallback = fallback or u
        if solid_at(u.pos.x, u.pos.y, u.pos.z) then return u end
    end
    if fallback then
        local p = near or fallback.pos
        local ground = find_ground_near(p.x, p.y, p.z)
        if ground then
            dfhack.units.teleport(fallback, ground)
            print(('planeswalkers: no citizen on solid ground; moved %s to %d,%d,%d to mint items')
                :format(dfhack.units.getReadableName(fallback), ground.x, ground.y, ground.z))
        end
    end
    return fallback
end

-- strip falling-projectile state off a freshly minted item (all candidate
-- creators airborne): unlink its projectile record and clear in_job so it can
-- be attached to buildings, containers and inventories again
function unproject(item)
    if not item or not item.flags.in_job then return item end
    local prev = df.global.world.projectiles.all
    local cur = prev.next
    while cur do
        if cur.item and cur.item.item == item then
            prev.next = cur.next
            if cur.next then cur.next.prev = prev end
            -- unlink only. Deleting the projectile from Lua and then its list
            -- link was a double free: DF's projectile destructor frees the
            -- link itself (SIGABRT "double free detected in tcache", traced
            -- to exactly this spot). The two orphaned records are a leak DF
            -- never sees.
            break
        end
        prev, cur = cur, cur.next
    end
    for i = #item.general_refs - 1, 0, -1 do
        if df.general_ref_projectile:is_instance(item.general_refs[i]) then
            item.general_refs[i]:delete()
            item.general_refs:erase(i)
        end
    end
    item.flags.in_job = false
    return item
end

-- report accumulator: ctx.report is {line, line, ...}; skips grouped by reason
function add_skip(ctx, category, detail)
    ctx.skips = ctx.skips or {}
    local c = ctx.skips[category] or {n = 0, examples = {}}
    c.n = c.n + 1
    if #c.examples < 3 and detail then
        detail = tostring(detail):gsub('%s+', ' '):sub(1, 100)
        table.insert(c.examples, detail)
    end
    ctx.skips[category] = c
end

function print_skips(ctx)
    if not ctx.skips or not next(ctx.skips) then return end
    print('planeswalkers: skipped/degraded:')
    for cat, c in pairs(ctx.skips) do
        local ex = #c.examples > 0 and (' (e.g. ' .. table.concat(c.examples, ', ') .. ')') or ''
        print(('  %-28s %d%s'):format(cat, c.n, ex))
    end
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
