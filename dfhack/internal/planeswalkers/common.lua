-- Shared plumbing for fort/planeswalkers: snapshot paths/manifest/legends,
-- packed binary tile IO, and the chunked pipeline driver.
--@module = true

local json = require('json')

SNAP_ROOT = dfhack.getDFPath() .. '/dfhack-config/scripts/data/planeswalkers'
LAST_OPERATION_REPORT = SNAP_ROOT .. '/last-operation.json'
-- Version 2 added the source magma boundary. Version 3 stores the source
-- magma-core blocks separately so they can replace the destination sea safely.
-- The loader retains compatibility with v2 snapshots (without source magma).
-- v4 stores ordinary terrain at every Z-level except actual magma-core blocks.
-- v5 adds per-tile current and normal temperature grids.
-- v3 snapshots omitted all non-magma terrain below the magma sea's upper edge,
-- which produced missing caverns and unsupported terrain on restore.
FORMAT_VERSION = 5

-- DF strings are cp437; JSON must be UTF-8 (json.decode_file hard-rejects otherwise)
function u(s) return dfhack.df2utf(s or '') end
function fromu(s) return dfhack.utf2df(s or '') end

-- Convert UTF-8 text to DF's internal string encoding without silently keeping
-- replacement glyphs. Returns (converted, exact); callers can substitute a
-- readable foreign-* label when the destination codepage cannot represent it.
function fromu_checked(s, fallback)
    s = s or ''
    local converted = dfhack.utf2df(s)
    if dfhack.df2utf(converted) ~= s then
        return dfhack.utf2df(fallback or 'foreign name'), false
    end
    return converted, true
end

function snap_dir(name) return SNAP_ROOT .. '/' .. name end


-- Remove a snapshot directory, including incomplete and nested data. This is
-- intentionally independent of manifest validity: partial saves must be
-- manageable even when no manifest was ever written.
function remove_tree(path)
    if not dfhack.filesystem.exists(path) then return true end
    if not dfhack.filesystem.isdir(path) then
        local ok, err = os.remove(path)
        if not ok and dfhack.filesystem.exists(path) then
            return false, ('could not remove %s: %s'):format(path, tostring(err))
        end
        return true
    end
    for _, entry in ipairs(dfhack.filesystem.listdir(path) or {}) do
        local child = path .. '/' .. entry
        local ok, err = remove_tree(child)
        if not ok then return false, err end
    end
    local ok, err = dfhack.filesystem.rmdir(path)
    if not ok and dfhack.filesystem.isdir(path) then
        return false, ('could not remove directory %s: %s'):format(path, tostring(err))
    end
    return true
end
-- Immediate snapshot entries, including .pending and .replaced directories.
-- The public snapshot browser intentionally continues to show only complete
-- snapshots; delete-list uses this lower-level inventory for cleanup.
function list_snapshot_dirs()
    local out = {}
    if not dfhack.filesystem.isdir(SNAP_ROOT) then return out end
    for _, entry in ipairs(dfhack.filesystem.listdir(SNAP_ROOT) or {}) do
        local path = SNAP_ROOT .. '/' .. entry
        if dfhack.filesystem.isdir(path) then
            local base = entry:gsub('%.pending$', ''):gsub('%.replaced$', ''):gsub('%.publish_failed$', '')
            out[#out + 1] = {name = entry, base = base, path = path}
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

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

-- Ordinary fortress terrain is saved above the source magma boundary. The
-- magma-core blocks themselves are stored separately in magma.bin and restored
-- by the dedicated magma phases.
function above_source_magma(ctx, z)
    return ctx.source_magma_top == nil or z > ctx.source_magma_top
end

function above_transfer_cutoff(ctx, z)
    return ctx.transfer_min_z == nil or z >= ctx.transfer_min_z
end

-- nearest tile of the footprint to (x, y)
function clamp_to_footprint(ctx, x, y)
    local o = ctx.origin
    return math.max(o.x, math.min(o.x + o.w - 1, x)),
           math.max(o.y, math.min(o.y + o.h - 1, y))
end

function valid_name(name)
    return type(name) == 'string' and name:match('^[%w_%-%.]+$')
        and name ~= '' and name ~= '.' and name ~= '..' and name ~= '_spike'
        and not name:match('%.pending$') and not name:match('%.replaced$')
end

function write_json(path, data)
    local parent = path:match('^(.*)/[^/]+$')
    if parent and parent ~= '' then
        local ok, err = pcall(dfhack.filesystem.mkdir_recursive, parent)
        if not ok then
            error(('could not create JSON parent directory %s: %s')
                :format(parent, tostring(err)))
        end
    end
    local ok, err = pcall(json.encode_file, data, path, {pretty = false})
    if not ok then
        error(('could not write JSON file %s: %s'):format(path, tostring(err)))
    end
    if not dfhack.filesystem.exists(path) then
        error('JSON encoder did not create the expected file: ' .. path)
    end
    local decoded, decode_err = read_json(path)
    if decoded == nil then
        error(('JSON write verification failed for %s: %s')
            :format(path, tostring(decode_err)))
    end
    return true
end

function read_json(path)
    if not dfhack.filesystem.exists(path) then return nil, 'file does not exist: ' .. path end
    local ok, data, decode_err = pcall(json.decode_file, path)
    if not ok then return nil, tostring(data) end
    if data == nil then
        return nil, tostring(decode_err or 'JSON decoder returned no data')
    end
    return data
end
-- ---- durable last-operation report -----------------------------------------
-- The report is kept outside individual snapshot folders so the latest save
-- or load remains inspectable after changing worlds, and so a failed load can
-- still leave a useful report even though the destination is partially changed.
local function persist_operation_report(report)
    if not report then return false end
    local ok, err = pcall(write_json, LAST_OPERATION_REPORT, report)
    if not ok then
        dfhack.printerr('planeswalkers: could not persist operation report: ' .. tostring(err))
        return false
    end
    return true
end

function begin_operation_report(kind, name, metadata)
    local report = {
        version = 1, kind = kind, name = name, state = 'running',
        started_at = os.date('%Y-%m-%d %H:%M:%S'),
        started_tick = dfhack.getTickCount(),
        metadata = metadata or {}, phase_history = {}, phase_times = {},
    }
    dfhack.internal.planeswalkers_operation_report = report
    persist_operation_report(report)
    return report
end

function current_operation_report()
    return dfhack.internal.planeswalkers_operation_report
end

function update_operation_report(report, fields)
    if not report then return false end
    for k, v in pairs(fields or {}) do report[k] = v end
    report.updated_at = os.date('%Y-%m-%d %H:%M:%S')
    return persist_operation_report(report)
end

local function copy_skip_report(skips)
    local out = {}
    for category, entry in pairs(skips or {}) do
        out[category] = {n = entry.n or 0, examples = {}}
        for i, example in ipairs(entry.examples or {}) do
            if i > 3 then break end
            out[category].examples[i] = tostring(example)
        end
    end
    return out
end

local function compact_item_audit(audit)
    if type(audit) ~= 'table' then return nil end
    local out = {
        final_checked = audit.final_checked,
        final_unresolved = audit.final_unresolved,
        capture_errors = audit.capture_errors,
        capture_error = audit.capture_error,
        stages = {},
    }
    for stage_name, stage in pairs(audit.stages or {}) do
        local compact = {
            checked = stage.checked or 0,
            mismatched = stage.mismatched or 0,
            by_reason = {},
            info = stage.info,
        }
        for reason, bucket in pairs(stage.by_reason or {}) do
            local entry = {n = bucket.n or 0, examples = {}}
            for i, sample in ipairs(bucket.examples or {}) do
                if i > 2 then break end
                local expected = sample.expected or {}
                local actual = sample.actual or {}
                entry.examples[i] = {
                    id = sample.id,
                    type = sample.item_type,
                    stage = sample.stage,
                    reason = reason,
                    description = sample.description,
                    expected = expected.token or expected.source_material,
                    actual = actual.decoded_token,
                    pos = actual.x and {actual.x, actual.y, actual.z} or nil,
                }
            end
            compact.by_reason[reason] = entry
        end
        out.stages[stage_name] = compact
    end
    return out
end

function finish_operation_report(ctx, state, reason, failed_phase, job)
    local report
    if ctx then report = ctx.operation_report else report = current_operation_report() end
    if not report or report.state ~= 'running' then return false end
    local previous_phase = report.current_phase
    report.state = state or 'failed'
    report.finished_at = os.date('%Y-%m-%d %H:%M:%S')
    report.current_phase = nil
    if report.state == 'failed' then
        report.failed_phase = failed_phase or (ctx and ctx.last_failed_phase) or previous_phase or 'unknown'
    elseif previous_phase or failed_phase then
        report.ended_phase = failed_phase or previous_phase
    end
    if reason and tostring(reason) ~= '' then report.failure = tostring(reason) end
    if ctx then
        report.last_completed_phase = ctx.last_completed_phase or report.last_completed_phase
        report.skips = copy_skip_report(ctx.skips)
        if ctx.item_audit then report.item_audit = compact_item_audit(ctx.item_audit) end
        if ctx.report_summary then report.summary = ctx.report_summary end
        if ctx.report_advanced then report.advanced = ctx.report_advanced end
        if ctx.manifest and ctx.manifest.counts then report.counts = ctx.manifest.counts end
        report.metrics = report.metrics or {}
        for _, key in ipairs({'items_restored', 'units_restored', 'buildings_restored',
                              'trees_restored', 'plants_restored', 'held_attached',
                              'held_at_end', 'owned_restored', 'components_reminted'}) do
            if ctx[key] ~= nil then report.metrics[key] = ctx[key] end
        end
    end
    if job then
        report.phase_times = job.phase_times or report.phase_times or {}
        report.phase_count = #job.phases
        report.elapsed_seconds = math.max(0, dfhack.getTickCount() - (job.started or report.started_tick or dfhack.getTickCount())) / 1000
        local current = job.phases and job.phases[job.phase_idx]
        if state ~= 'success' and not report.failed_phase then
            report.failed_phase = current and current.name or nil
        end
    elseif report.started_tick then
        report.elapsed_seconds = math.max(0, dfhack.getTickCount() - report.started_tick) / 1000
    end
    report.started_tick = nil -- not a stable value across a game restart
    report.updated_at = report.finished_at
    persist_operation_report(report)
    return true
end

function fail_active_operation_report(reason, phase)
    local report = current_operation_report()
    if not report or report.state ~= 'running' then return false end
    return finish_operation_report(nil, 'failed', reason, phase or report.current_phase or 'preflight', nil)
end

function read_last_operation_report()
    return read_json(LAST_OPERATION_REPORT)
end

function compact_last_operation_report()
    local report, err = read_last_operation_report()
    if not report then
        return false, err or 'no readable last-operation report'
    end
    if report.item_audit then
        report.item_audit = compact_item_audit(report.item_audit)
    end
    for _, entry in pairs(report.skips or {}) do
        local examples = entry.examples or {}
        while #examples > 3 do table.remove(examples) end
    end
    local ok, write_err = pcall(persist_operation_report, report)
    if not ok or write_err == false then
        return false, tostring(write_err or 'could not write compact report')
    end
    return true
end

function list_snapshots()
    local out = {}
    if not dfhack.filesystem.isdir(SNAP_ROOT) then return out end
    -- Snapshot directories are immediate children of SNAP_ROOT. Avoid a recursive
    -- listing here: nested folders and stale pending/replacement directories must
    -- never be mistaken for completed snapshots.
    for _, name in ipairs(dfhack.filesystem.listdir(SNAP_ROOT) or {}) do
        if not name:match('%.pending$') and not name:match('%.replaced$')
            and not name:match('%.publish_failed$') then
            local dir = snap_dir(name)
            if dfhack.filesystem.isdir(dir) then
                local mf = read_json(dir .. '/manifest.json')
                local complete = mf and mf.complete
                local valid_fort = complete and complete.terrain and complete.constructions
                local valid_party = complete and complete.units and complete.items
                if mf and (not mf.name or mf.name == name) and (valid_fort or valid_party) then
                    table.insert(out, {name = name, manifest = mf})
                end
            end
        end
    end
    table.sort(out, function(a, b)
        return (a.manifest.created or '') < (b.manifest.created or '')
    end)
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

-- heat.bin stores current and normal temperature for every tile, in source
-- block order. Temperatures are block state, not tile designations.
HEAT_REC = '<I2I2'
HEAT_REC_SIZE = 4
HEAT_BLOCK_SIZE = HEAT_REC_SIZE * 256
ZERO_HEAT_BLOCK = string.rep(string.pack(HEAT_REC, 0, 0), 256)

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
        | (d.water_table and 1 or 0) << 11  -- aquifer tile
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
        water_table = (bits >> 11) & 1 == 1,
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
        finish_operation_report(j.ctx, 'interrupted', 'world changed while the job was active',
            j.phases[j.phase_idx] and j.phases[j.phase_idx].name or 'unknown', j)
        if j.ctx and j.ctx.on_abort then
            pcall(j.ctx.on_abort, j.ctx, 'world changed while the job was active')
        end
        dfhack.printerr(('planeswalkers: dropped stale job %q left over from a ' ..
            'previous world'):format(tostring(j.label)))
        return nil
    end
    return j
end

function cancel_job()
    local j = current_job()
    jobs().planeswalkers_job = nil
    if j and j.ctx and j.ctx.close_all then pcall(j.ctx.close_all, j.ctx) end
    if j then
        local phase = j.phases[j.phase_idx] and j.phases[j.phase_idx].name or 'unknown'
        finish_operation_report(j.ctx, 'cancelled', 'cancelled by user', phase, j)
    end
    if j and j.ctx and j.ctx.on_abort then pcall(j.ctx.on_abort, j.ctx, 'cancelled') end
    return j ~= nil
end

function start_job(label, phases, ctx, on_done)
    if current_job() then qerror('planeswalkers: a job is already running (' ..
        current_job().label .. '); `fort/planeswalkers cancel` first') end
    local job = {
        label = label, phases = phases, ctx = ctx, on_done = on_done,
        phase_idx = 1, inited = false, last_report = dfhack.getTickCount(),
        started = dfhack.getTickCount(), keep_paused = true,
        phase_started = dfhack.getTickCount(), phase_times = {},
        world_token = world_token(),
    }
    jobs().planeswalkers_job = job
    if ctx and ctx.operation_report then
        update_operation_report(ctx.operation_report, {
            state = 'running', phase_count = #phases, label = label,
            current_phase = phases[1] and phases[1].name or 'finishing',
        })
    end
    print(('planeswalkers: %s started (%d phases); game stays paused until done')
        :format(label, #phases))
end

-- The game is deliberately paused while a job runs. A slightly larger pump
-- budget reduces total restore time without introducing a long blocking pass.
-- Phase timings are printed at completion so this can be tuned from real runs.
BUDGET_MS = 75

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
            if not job.phase_notified then
                if job.ctx and job.ctx.operation_report then
                    update_operation_report(job.ctx.operation_report, {
                        current_phase = phase.name, phase_index = job.phase_idx,
                    })
                end
                if job.ctx and job.ctx.on_phase_start then
                    pcall(job.ctx.on_phase_start, job.ctx, phase.name)
                end
                job.phase_notified = true
            end
            if not job.inited then
                job.phase_started = dfhack.getTickCount()
                if phase.init then phase.init(job) end
                job.inited = true
            end
            if phase.step(job, deadline) then
                job.phase_times = job.phase_times or {}
                local phase_ms = dfhack.getTickCount() - (job.phase_started or dfhack.getTickCount())
                job.phase_times[#job.phase_times + 1] = {
                    name = phase.name, ms = phase_ms,
                }
                if job.ctx then
                    job.ctx.last_completed_phase = phase.name
                    if job.ctx.on_phase_complete then
                        pcall(job.ctx.on_phase_complete, job.ctx, phase.name)
                    end
                    if job.ctx.operation_report then
                        job.ctx.operation_report.phase_history = job.ctx.operation_report.phase_history or {}
                        table.insert(job.ctx.operation_report.phase_history, {
                            name = phase.name, state = 'complete', elapsed_seconds = phase_ms / 1000,
                        })
                        update_operation_report(job.ctx.operation_report, {
                            current_phase = nil, last_completed_phase = phase.name,
                            phase_times = job.phase_times,
                        })
                    end
                end
                print(('planeswalkers: %s: %s done (%.2fs)')
                    :format(job.label, phase.name, phase_ms / 1000))
                job.phase_idx = job.phase_idx + 1
                job.inited = false
                job.phase_notified = false
                job.phase_started = dfhack.getTickCount()
                if not job.phases[job.phase_idx] then
                    jobs().planeswalkers_job = nil
                    table.sort(job.phase_times, function(a, b) return a.ms > b.ms end)
                    if job.on_done then
                        local done_ok, done_err = pcall(job.on_done, job)
                        if not done_ok then
                            local reason = 'completion callback failed: ' .. tostring(done_err)
                            if job.ctx then
                                job.ctx.last_failed_phase = 'completion callback'
                                finish_operation_report(job.ctx, 'failed', reason, 'completion callback', job)
                                if job.ctx.close_all then pcall(job.ctx.close_all, job.ctx) end
                                -- A save may already have been atomically published
                                -- before a nonessential completion notification fails.
                                -- Do not write pending.json into that valid snapshot.
                                if job.ctx.on_abort and not job.ctx.published then
                                    pcall(job.ctx.on_abort, job.ctx, reason)
                                end
                            end
                            dfhack.printerr(('planeswalkers: %s ABORTED while completing: %s')
                                :format(job.label, tostring(done_err)))
                            return
                        end
                    end
                    finish_operation_report(job.ctx, 'success', nil, nil, job)
                    print(('planeswalkers: %s FINISHED in %.1fs'):format(job.label,
                        (dfhack.getTickCount() - job.started) / 1000))
                    for i = 1, math.min(5, #job.phase_times) do
                        local p = job.phase_times[i]
                        print(('planeswalkers: slow phase: %s (%.2fs)')
                            :format(p.name, p.ms / 1000))
                    end
                    return
                end
            end
        end
    end)
    if not ok then
        jobs().planeswalkers_job = nil
        local failed_phase = job.phases[job.phase_idx] and job.phases[job.phase_idx].name or '?'
        if job.ctx then job.ctx.last_failed_phase = failed_phase end
        if job.ctx and job.ctx.close_all then pcall(job.ctx.close_all, job.ctx) end
        finish_operation_report(job.ctx, 'failed', tostring(err), failed_phase, job)
        if job.ctx and job.ctx.on_abort then pcall(job.ctx.on_abort, job.ctx, tostring(err)) end
        dfhack.printerr(('planeswalkers: %s ABORTED in phase %s: %s'):format(
            job.label, failed_phase, tostring(err)))
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
    local p = job_progress()
    if not p then return nil end
    local progress = p.percent and (' %d%%'):format(p.percent) or ''
    return ('%s: phase %d/%d (%s)%s; elapsed %.1fs'):format(
        p.label, p.phase_idx, p.phase_count, p.phase_name, progress, p.elapsed / 1000)
end

-- Safe, read-only progress data for the in-game overlay and `status` command.
-- Phase totals are not always known until init() has run, so the overlay must
-- tolerate an indeterminate phase rather than calling total() prematurely.
function job_progress()
    local job = current_job()
    if not job then return nil end
    local phase = job.phases[job.phase_idx]
    local p = {
        label = job.label,
        phase_idx = job.phase_idx,
        phase_count = #job.phases,
        phase_name = phase and phase.name or 'finishing',
        elapsed = dfhack.getTickCount() - job.started,
        paused = job.keep_paused,
        percent = nil,
        position = nil,
        total = nil,
    }
    if phase and job.inited and phase.pos and phase.total then
        local ok, pos, total = pcall(function()
            return phase.pos(job), phase.total(job)
        end)
        if ok and type(pos) == 'number' and type(total) == 'number' and total > 0 then
            p.position, p.total = pos, total
            p.percent = math.max(0, math.min(100, math.floor(pos * 100 / total)))
        end
    end
    return p
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
