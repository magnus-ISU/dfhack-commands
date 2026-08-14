-- Save a whole fort to disk and restore it in a different world.
--@module = true
--[[
fort/planeswalkers

Snapshot the current fort (terrain, buildings, stockpiles, zones, units, items,
artifacts, histfig web) into $DF/dfhack-config/scripts/data/planeswalkers/<name>/,
and reconstruct a snapshot on a fresh embark in ANOTHER world. Cross-world identity
is kept via raw token strings (never world-local numeric ids); procedurally
generated content (forgotten beasts, necromancer secrets) is mapped best-effort to
the destination world's own equivalents.

Both save and load run as chunked background jobs pumped from an overlay (the game
stays paused and responsive); progress prints to the DFHack console.

Usage::

    fort/planeswalkers save [name]        snapshot the current fort
    fort/planeswalkers load               list snapshots
    fort/planeswalkers load <name> --i-saved [--force]
                                          restore <name> here (destination embark
                                          must be at least as large as the source;
                                          make a manual DF save first -- there is
                                          no rollback)
    fort/planeswalkers list               list snapshots
    fort/planeswalkers delete <name> --yes
    fort/planeswalkers status             job progress / restored-from marker
    fort/planeswalkers cancel             abort the running job
    fort/planeswalkers step               pump the job once by hand (debug)
    fort/planeswalkers spike <n>          dev: run de-risk spike n
]]

local overlay = require('plugins.overlay')

local function req(mod) return reqscript('internal/planeswalkers/' .. mod) end
local common = req('common')

local GLOBAL_KEY = 'planeswalkers'

-- ---- overlay pump: runs the current job even while the game is paused -------

PumpOverlay = defclass(PumpOverlay, overlay.OverlayWidget)
PumpOverlay.ATTRS{
    desc = 'Drives fort/planeswalkers save/load jobs in the background.',
    default_enabled = true,
    viewscreens = 'dwarfmode',
    overlay_onupdate_max_freq_seconds = 0,
    default_pos = {x = -1, y = -1},
    frame = {w = 1, h = 1},
}

function PumpOverlay:overlay_onupdate()
    if common.current_job() then common.pump() end
end

OVERLAY_WIDGETS = {pump = PumpOverlay}

-- ---- actions ---------------------------------------------------------------

local function fort_name()
    local site = df.global.world.world_data.active_site[0]
    local n = site and common.u(dfhack.translation.translateName(site.name)) or 'fort'
    n = n:lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
    return n ~= '' and n or 'fort'
end

local function require_fort()
    if not dfhack.world.isFortressMode() or not dfhack.isMapLoaded() then
        qerror('planeswalkers: needs a loaded fortress')
    end
end

local function do_save(name)
    require_fort()
    name = name or (fort_name() .. '-' .. os.date('%Y%m%d-%H%M'))
    if not common.valid_name(name) then
        qerror('planeswalkers: bad name (use letters/digits/-_.): ' .. tostring(name))
    end
    if dfhack.filesystem.isdir(common.snap_dir(name)) then
        qerror('planeswalkers: snapshot already exists: ' .. name)
    end
    dfhack.filesystem.mkdir_recursive(common.snap_dir(name))

    local terrain = req('terrain')
    local map = df.global.world.map
    local ctx = {
        name = name,
        dir = common.snap_dir(name),
        legend_tt = common.Legend.new(),
        legend_mat = common.Legend.new(),
        skips = {},
        manifest = {
            v = 1,
            format_version = common.FORMAT_VERSION,
            name = name,
            world = common.u(dfhack.translation.translateName(df.global.world.world_data.name)),
            fort = fort_name(),
            created = os.date('%Y-%m-%d %H:%M:%S'),
            df_version = dfhack.getDFVersion(),
            dims = {
                bx = map.x_count_block, by = map.y_count_block, bz = map.z_count_block,
                surface = terrain.find_surface_z(),
            },
            counts = {},
            complete = {},
        },
        close_all = function(self)
            if self.tiles_f then self.tiles_f:close(); self.tiles_f = nil end
        end,
    }

    local phases = terrain.save_phases(ctx)
    common.start_job('save ' .. name, phases, ctx, function()
        common.write_json(ctx.dir .. '/legend.json',
            {v = 1, tiletypes = ctx.legend_tt.list, mats = ctx.legend_mat.list})
        common.write_json(ctx.dir .. '/manifest.json', ctx.manifest)
        common.print_skips(ctx)
        print(('planeswalkers: snapshot "%s" written to %s'):format(name, ctx.dir))
    end)
end

local function print_list()
    local snaps = common.list_snapshots()
    if #snaps == 0 then
        print('planeswalkers: no snapshots yet (fort/planeswalkers save)')
        return snaps
    end
    print(('%-32s %-24s %-9s %-6s %s'):format('name', 'world', 'size', 'done', 'created'))
    for i, s in ipairs(snaps) do
        local m = s.manifest
        local complete = m.complete and m.complete.terrain and 'yes' or 'PARTIAL'
        print(('%2d. %-28s %-24s %3dx%-3dx%-3d %-6s %s'):format(i, s.name,
            m.world or '?', m.dims.bx, m.dims.by, m.dims.bz, complete, m.created or '?'))
    end
    return snaps
end

local function do_load(name, ...)
    local flags = {}
    for _, a in ipairs({name, ...}) do flags[a] = true end
    if not name or name:match('^%-%-') then
        print_list()
        print('\nload with: fort/planeswalkers load <name> --i-saved')
        return
    end
    require_fort()
    -- accept a list index as the name
    if name:match('^%d+$') then
        local snaps = common.list_snapshots()
        local pick = snaps[tonumber(name)]
        if pick then name = pick.name end
    end
    local dir = common.snap_dir(name)
    local mf = common.read_json(dir .. '/manifest.json')
    if not mf then qerror('planeswalkers: no snapshot named ' .. name) end
    if mf.format_version ~= common.FORMAT_VERSION then
        qerror(('planeswalkers: snapshot format v%s, this build reads v%d')
            :format(tostring(mf.format_version), common.FORMAT_VERSION))
    end
    if not (mf.complete and mf.complete.terrain and mf.complete.constructions) then
        qerror('planeswalkers: snapshot is incomplete (the save was aborted); refusing')
    end
    if mf.world == common.u(dfhack.translation.translateName(df.global.world.world_data.name))
        and not flags['--force'] then
        qerror('planeswalkers: this snapshot came from THIS world; --force to restore anyway')
    end
    if not flags['--i-saved'] then
        qerror('planeswalkers: make a manual DF save first (there is NO rollback), then\n' ..
               're-run with --i-saved:  fort/planeswalkers load ' .. name .. ' --i-saved')
    end
    if #df.global.world.buildings.all > 1 and not flags['--force'] then
        qerror(('planeswalkers: this fort already has %d buildings; load onto a FRESH ' ..
                'embark, or --force to overwrite anyway'):format(#df.global.world.buildings.all))
    end

    local terrain = req('terrain')
    local anchor, err = terrain.compute_anchor(mf.dims)
    if not anchor then qerror('planeswalkers: ' .. err) end

    local legends = common.read_json(dir .. '/legend.json') or {}
    local ctx = {
        name = name,
        dir = dir,
        manifest = mf,
        anchor = anchor,
        legend_tt = common.Legend.new(legends.tiletypes),
        legend_mat = common.Legend.new(legends.mats),
        skips = {},
        close_all = function(self)
            if self.tiles_f then self.tiles_f:close(); self.tiles_f = nil end
        end,
    }

    dfhack.persistent.saveSiteData(GLOBAL_KEY,
        {state = 'loading', from = name, world = mf.world, when = os.date('%Y-%m-%d %H:%M:%S')})

    print(('planeswalkers: restoring "%s" (%dx%d blocks) anchored at block %d,%d, ' ..
           'surface z %d -> %d'):format(name, mf.dims.bx, mf.dims.by,
           anchor.off_bx, anchor.off_by, mf.dims.surface, anchor.dest_surface))

    local phases = terrain.load_phases(ctx)
    common.start_job('load ' .. name, phases, ctx, function()
        dfhack.persistent.saveSiteData(GLOBAL_KEY,
            {state = 'done', from = name, world = mf.world, when = os.date('%Y-%m-%d %H:%M:%S')})
        common.print_skips(ctx)
        local cx = anchor.off_x + mf.dims.bx * 8
        local cy = anchor.off_y + mf.dims.by * 8
        dfhack.gui.revealInDwarfmodeMap(xyz2pos(cx, cy, anchor.dest_surface), true)
        print(('planeswalkers: fort "%s" restored; SAVE NOW and reload to verify')
            :format(name))
    end)
end

local function do_delete(name, confirm)
    if not name or not common.valid_name(name) then qerror('delete: need a snapshot name') end
    if confirm ~= '--yes' then qerror('delete: add --yes to really delete ' .. name) end
    local dir = common.snap_dir(name)
    if not dfhack.filesystem.isdir(dir) then qerror('no snapshot named ' .. name) end
    for _, e in ipairs(dfhack.filesystem.listdir_recursive(dir) or {}) do
        if not e.isdir then os.remove(e.path) end
    end
    for _, e in ipairs(dfhack.filesystem.listdir_recursive(dir) or {}) do
        if e.isdir then dfhack.filesystem.rmdir(e.path) end
    end
    dfhack.filesystem.rmdir(dir)
    print('planeswalkers: deleted ' .. name)
end

local function do_status()
    local js = common.job_status()
    if js then print('planeswalkers: RUNNING ' .. js) return end
    print('planeswalkers: no job running')
    if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
        local marker = dfhack.persistent.getSiteData(GLOBAL_KEY)
        if marker and marker.state then
            print(('  this fort: restore "%s" from world "%s" -- %s (%s)')
                :format(marker.from or '?', marker.world or '?', marker.state,
                        marker.when or '?'))
        end
    end
end

local function do_cancel()
    if common.cancel_job() then print('planeswalkers: job cancelled')
    else print('planeswalkers: nothing running') end
end

local function do_step()
    if not common.pump(1000) then print('planeswalkers: nothing (left) to pump') end
end

local function do_spike(n, ...)
    req('spikes').run(tonumber(n) or qerror('spike: numeric spike id required'), ...)
end

local ACTIONS = {
    save = do_save, load = do_load, list = print_list, delete = do_delete,
    status = do_status, cancel = do_cancel, step = do_step, spike = do_spike,
}

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local action = args[1] or 'list'
local fn = ACTIONS[action]
if not fn then
    qerror(('planeswalkers: unknown action "%s" (save|load|list|delete|status|cancel)')
        :format(action))
end
fn(table.unpack(args, 2))
