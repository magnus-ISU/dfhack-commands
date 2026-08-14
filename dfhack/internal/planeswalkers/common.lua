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
--   mat legend idx (0 = dest-native material), designation bits, spare.
-- blocks in z-major order: for z 0..z_count-1, for by, for bx.

TILE_REC = '<I2I2I2B'
TILE_REC_SIZE = 7
BLOCK_SIZE = TILE_REC_SIZE * 256
HEADER_FMT = '<c4I2I2I2I2I2'
HEADER_SIZE = 14
ZERO_BLOCK = string.rep(string.pack(TILE_REC, 0, 0, 0, 0), 256)

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
    }
end

-- ---- chunked pipeline driver ------------------------------------------------
-- One job at a time, pumped from the overlay (which runs even while paused) or
-- from `fort/planeswalkers step`. Each phase: {name=..., init=fn(job)?,
-- step=fn(job, deadline_ms) -> done?, total=fn(job)?, pos=fn(job)?}.
-- Keep the job in dfhack.internal so a script reload doesn't orphan it.

local function jobs() return dfhack.internal end

function current_job() return jobs().planeswalkers_job end

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
    }
    print(('planeswalkers: %s started (%d phases); game stays paused until done')
        :format(label, #phases))
end

BUDGET_MS = 30

function pump(budget_ms)
    local job = current_job()
    if not job then return false end
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
    -- periodic progress line
    job = current_job()
    if job and dfhack.getTickCount() - job.last_report > 2000 then
        job.last_report = dfhack.getTickCount()
        local phase = job.phases[job.phase_idx]
        local extra = ''
        if phase and phase.pos and phase.total then
            local p, t = phase.pos(job), phase.total(job)
            if t and t > 0 then extra = (' %d/%d (%d%%)'):format(p, t, p * 100 // t) end
        end
        print(('planeswalkers: %s: %s%s'):format(job.label, phase and phase.name or '?', extra))
    end
    return current_job() ~= nil
end

function job_status()
    local job = current_job()
    if not job then return nil end
    local phase = job.phases[job.phase_idx]
    return ('%s: phase %d/%d (%s)'):format(job.label, job.phase_idx, #job.phases,
                                           phase and phase.name or '?')
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
