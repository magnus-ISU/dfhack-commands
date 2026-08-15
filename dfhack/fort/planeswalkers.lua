-- Save a whole fort to disk and restore it in a different world.
--@module = true
--[====[
fort/planeswalkers
==================

Tags: fort | armok | map | units | buildings

Command: "fort/planeswalkers"
    Carry a whole fort between worlds.

Carry a whole fort from one world to another. ``save`` writes the fort to disk;
``load`` rebuilds it on a fresh embark in a *different* world, dwarves and all.

What is carried
---------------

- **Terrain**: every tile of the fort's footprint -- stone layers, veins, sand,
  soil, adamantine, water and magma, plus dug-out and smoothed tiles and the
  hidden/light/outside flags. The magma sea and the underworld are NOT carried:
  each world keeps its own (transplanting one world's hell into another's rock
  breaches the underworld and lets its demons loose).
- **Constructions and buildings**: walls, floors, ramps and stairs; workshops,
  furnaces, doors, hatches, beds, tables, statues, wells, levers and traps, each
  with its own material.
- **Stockpiles and zones**, including stockpile category/material settings and
  container limits, and zone types and their sizes.
- **Items**: material, quality, wear, decorations, improvements, stack size, and
  containment (what is in which bin/barrel/cabinet, on which pedestal).
- **Artifacts**, named and described, and the historical figure that made them.
- **Units**: every dwarf, animal and visitor -- skills and their experience,
  attributes, personality, appearance, wounds, inventory, professions and
  labours, plus the surrounding historical-figure web (parents, spouses,
  children, kills, and retired adventurers, who stay unretirable on arrival).

Identity is stored as raw token strings, never world-local numeric ids, so a
destination world with the same raws/mods restores near-losslessly. Procedurally
generated content -- forgotten beasts, necromancer secrets, modded materials the
target world never generated -- is mapped to the closest local equivalent, or
skipped. Everything substituted or dropped is counted and printed as a
"skipped/degraded" report when the job finishes.

How it runs
-----------

Both save and load are chunked background jobs pumped by an overlay widget, so
DF stays responsive; the game is held paused for the duration. Progress prints
to the DFHack console every couple of seconds, and an in-game announcement fires
when a save or a load completes. ``status`` shows the current phase, ``cancel``
aborts, and ``step`` pumps one chunk by hand (debug).

Snapshots live in ``$DF/dfhack-config/scripts/data/planeswalkers/<name>/``.

Walkthrough
-----------

1. In the fort you want to carry, run ``fort/planeswalkers save``. A name is
   derived from the fort and the date unless you pass one. Wait for the "snapshot
   saved" notification.
2. Generate or load another world and embark. The new embark must be **at least
   as large** as the source fort's, and should be a fresh one -- loading wipes
   everything inside the old fort's footprint.
3. **Save the game manually.** There is no rollback.
4. ``fort/planeswalkers list`` to see what you have, then
   ``fort/planeswalkers load <name>`` (the list number works too). When the
   "fort restored" notification arrives, save and reload the fort so DF settles
   units and jobs.

Deleting snapshots you no longer want
-------------------------------------

``fort/planeswalkers list`` prints every snapshot with its world, embark size
and date. To remove one::

    fort/planeswalkers delete <name> --yes

``--yes`` is mandatory and there is no undo: the command erases
``dfhack-config/scripts/data/planeswalkers/<name>/`` and its contents. It only
touches that folder -- a fort already restored from the snapshot, and your DF
saves, are untouched. Snapshots are otherwise plain folders, so deleting one by
hand from that directory works just as well. A snapshot from an aborted save is
listed as ``PARTIAL`` and cannot be loaded; delete it the same way.

Usage::

    fort/planeswalkers                    show usage
    fort/planeswalkers save [name]        snapshot the current fort
    fort/planeswalkers list               list snapshots
    fort/planeswalkers load               list snapshots
    fort/planeswalkers load <name|number> [--force]
                                          restore a snapshot onto this embark.
                                          --force allows a same-world snapshot
                                          or a fort that already has buildings
    fort/planeswalkers delete <name> --yes  delete a snapshot
    fort/planeswalkers status             job progress / restored-from marker
    fort/planeswalkers cancel             abort the running job
    fort/planeswalkers step               pump the job once by hand (debug)
    fort/planeswalkers spike <n>          dev: run de-risk spike n
]====]

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

-- in-game notification (the console scrolls away while the job runs)
local function notify(msg, color, popup)
    print('planeswalkers: ' .. msg)
    color = color or COLOR_LIGHTCYAN
    pcall(dfhack.gui.showAnnouncement, 'planeswalkers: ' .. msg, color, true)
    if popup then pcall(dfhack.gui.showPopupAnnouncement, msg, color, true) end
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
    for _, p in ipairs(req('buildings').save_phases(ctx)) do table.insert(phases, p) end
    for _, p in ipairs(req('items').save_phases(ctx)) do table.insert(phases, p) end
    for _, p in ipairs(req('units').save_phases(ctx)) do table.insert(phases, p) end
    common.start_job('save ' .. name, phases, ctx, function()
        common.write_json(ctx.dir .. '/legend.json',
            {v = 1, tiletypes = ctx.legend_tt.list, mats = ctx.legend_mat.list})
        ctx.manifest.skips = {}
        for cat, c in pairs(ctx.skips or {}) do
            ctx.manifest.skips[cat] = {n = c.n, examples = c.examples}
        end
        common.write_json(ctx.dir .. '/manifest.json', ctx.manifest)
        common.print_skips(ctx)
        notify(('snapshot "%s" saved (%s). Load it on a fresh embark in another ' ..
                'world with: fort/planeswalkers load %s'):format(name, ctx.dir, name),
               COLOR_LIGHTGREEN, true)
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
        print('\nload with: fort/planeswalkers load <name>   (or its list number)')
        print('make a manual DF save first -- there is NO rollback')
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

    notify(('restoring "%s" (%dx%d blocks) anchored at block %d,%d, surface z %d -> %d; ' ..
            'the game stays paused until it finishes')
           :format(name, mf.dims.bx, mf.dims.by, anchor.off_bx, anchor.off_by,
                   mf.dims.surface, anchor.dest_surface))

    local phases = terrain.load_phases(ctx)
    local cleanup = table.remove(phases)  -- map cleanup runs last of all
    -- the embark's own buildings (the wagon!) go first, before terrain repaint
    table.insert(phases, 1, req('buildings').clear_phase(ctx))
    if dfhack.filesystem.exists(dir .. '/buildings.json') then
        for _, p in ipairs(req('buildings').load_phases(ctx)) do table.insert(phases, p) end
    end
    if dfhack.filesystem.exists(dir .. '/units.json') then
        -- units before items so unit-held items can be re-attached
        for _, p in ipairs(req('units').load_phases(ctx)) do table.insert(phases, p) end
    end
    if dfhack.filesystem.exists(dir .. '/items.json') then
        for _, p in ipairs(req('items').load_phases(ctx)) do table.insert(phases, p) end
    end
    table.insert(phases, cleanup)
    common.start_job('load ' .. name, phases, ctx, function()
        dfhack.persistent.saveSiteData(GLOBAL_KEY,
            {state = 'done', from = name, world = mf.world, when = os.date('%Y-%m-%d %H:%M:%S')})
        common.print_skips(ctx)
        local cx = anchor.off_x + mf.dims.bx * 8
        local cy = anchor.off_y + mf.dims.by * 8
        dfhack.gui.revealInDwarfmodeMap(xyz2pos(cx, cy, anchor.dest_surface), true)
        notify(('fort "%s" restored from world "%s". SAVE NOW and reload the fort to ' ..
                'verify -- units and jobs settle on the next load.')
               :format(name, mf.world or '?'), COLOR_LIGHTGREEN, true)
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

local HELP = [[
fort/planeswalkers -- carry a whole fort to another world.

  It snapshots this fort to disk (terrain, buildings, stockpiles, zones, items,
  artifacts, and every unit with its skills, personality and family), then
  rebuilds it on a fresh embark in ANY other world. Everything is stored as raw
  tokens, so anything the destination world also has comes back as itself;
  what it lacks is substituted or skipped, and reported at the end.

Doing it, start to finish:

  1. In the fort you want to carry:
         fort/planeswalkers save               (or: save <name>)
     The game pauses and works through the fort in chunks; progress prints to
     the console. You get a notification when the snapshot is written.

  2. Start or load ANOTHER world and embark somewhere. The new embark must be
     at least as large as the old one, and should be untouched -- loading wipes
     the footprint the old fort occupied.

  3. Save the game manually (there is NO rollback), then:
         fort/planeswalkers list               see your snapshots
         fort/planeswalkers load <name>        rebuild the fort here
     <name> may also be the number shown by `list`. You get a notification when
     the fort is restored; SAVE and reload it right away to let DF settle.

Removing a snapshot:

     fort/planeswalkers delete <name> --yes
  That erases the snapshot folder under
  dfhack-config/scripts/data/planeswalkers/<name>/ and nothing else -- it never
  touches a fort you already restored. There is no undo; --yes is required.

All commands:

  fort/planeswalkers                     this help
  fort/planeswalkers save [name]         snapshot the current fort
  fort/planeswalkers list                list snapshots
  fort/planeswalkers load                list snapshots
  fort/planeswalkers load <name|number> [--force]
                                         restore a snapshot onto this embark
                                         (--force: allow a same-world snapshot
                                         or a non-empty fort)
  fort/planeswalkers delete <name> --yes  delete a snapshot
  fort/planeswalkers status              job progress / restored-from marker
  fort/planeswalkers cancel              abort the running save or load
  fort/planeswalkers step                pump the job once by hand (debug)

Run `help fort/planeswalkers` for the full description.
]]

local function do_help() print(HELP) end

local ACTIONS = {
    save = do_save, load = do_load, list = print_list, delete = do_delete,
    status = do_status, cancel = do_cancel, step = do_step, spike = do_spike,
    help = do_help, ['--help'] = do_help, ['-h'] = do_help,
}

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local action = args[1]
if not action then do_help() return end
local fn = ACTIONS[action]
if not fn then
    qerror(('planeswalkers: unknown action "%s" (save|load|list|delete|status|' ..
            'cancel); run `fort/planeswalkers` for help'):format(action))
end
fn(table.unpack(args, 2))
