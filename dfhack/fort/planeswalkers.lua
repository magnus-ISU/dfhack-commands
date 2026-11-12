-- Save a whole fort to disk and restore it in a different world.
--@module = true
--[====[
fort/planeswalkers
==================

Tags: fort | armok | map | units | buildings
Command: "fort/planeswalkers"

Move a fortress between generated worlds. ``save`` creates a portable
snapshot; ``load`` replaces the corresponding area of a destination embark.
The destination embark must be at least as large as the saved footprint.

TRANSFERRED DATA
----------------

- Terrain, geology, veins, soils, constructions, grass, trees and temperatures.
- Origin magma pools/channels and complete global magma-sea blocks. The global
  sea is restored at its recorded depth as a static basin inside the footprint;
  the destination magma feature remains native outside the imported area.
- Destination global magma and underworld registrations remain native outside
  the imported footprint; destination world-specific inhabitants remain native.
- Adamantine spires and their event contents when their trigger tiles are
  inside the transferable footprint.
- Buildings, workshops, stockpiles, zones, rooms, furniture and settings.
- Items, containers, artifacts, decorations, ownership and corpses.
- Units, equipment, skills, attributes, wounds and supported historical links.
- Squads, work details, burrows, manager orders and fortress plants.
- Selective party snapshots, with a GUI for choosing units and carried items.
- A snapshot browser, placement preview, metadata comparison and restore report.

Destination-world history, diplomacy, caravans and civilization identity are
not transplanted. The origin population is integrated into the destination
fortress civilization. Missing raws/materials are substituted or skipped when
possible; the restore report lists unresolved records.

TERRAIN AND LIQUID SAFETY
------------------------

The origin fortress keeps its internal Z-level spacing. Placement aligns the
surface where possible, then shifts the complete volume only as needed to fit
above the destination's local underworld ceiling. The destination magma sea is
not used as a vertical limit: imported magma is static and is not part of its
refill system. If the source roof exceeds the available map height, load with
``--add-z`` to request extra sky levels through DFHack's ``infinite-sky`` plugin.
That operation stops before transplanting; save and reload the destination,
then run the load command again.

The destination's global magma sea and underworld registrations remain native
outside and below the imported footprint. The origin's complete magma sea is
restored at its recorded depth as a static, full basin inside the footprint;
its feature Z-bound grid is not merged with the destination's. Local origin
magma pools/channels are also restored as contained liquid. Flow updates are
forbidden for imported magma. Surface smoothing only builds up lower exterior
terrain; it never excavates destination ground, avoiding unsupported cuts and
surface cave-ins. Natural soil/stone caps
mark nearby surface liquids flow-forbidden without replacing them with
unsupported wall tiles, and a two-tile bulkhead seals the remaining surface
and underground boundary. Its base is placed above each column's local
underworld ceiling. Replaced tiles lose destination feature and mineral-event
assignments, and missing source map blocks are allocated before restoration.
The final integrity phase checks the bulkhead and static magma; a failed check
marks the restore as failed, not complete.

The fresh embark wagon is deconstructed. Its supplies are distributed over
nearby supported ground. Fresh embark units are relocated independently to
supported, unoccupied tiles; individual failures are reported.

HOW TO USE
----------

1. In the origin fortress, run ``fort/planeswalkers save [name]``.
2. Generate/load another world and embark on a site at least as large as the
   origin footprint.
3. Run ``fort/planeswalkers preview <name>`` to inspect the proposed placement.
4. Save the destination game manually before loading. A full automatic
   destination backup and rollback are not yet implemented.
5. Run ``fort/planeswalkers list`` and then ``fort/planeswalkers load <name>``.
6. After a successful restore, save and reload the destination fortress.

Jobs run in chunks while the game is paused. The framed progress panel shows
the active operation, phase and progress. If it is hidden, run
``overlay rescan`` and ``overlay enable pump``. Use ``status`` for the current
phase and last restore state. ``cancel`` stops the active job. Cancelled saves
delete their temporary data; failed saves retain diagnostics for
``save <name> --overwrite`` or ``delete-list``.

Snapshots are stored in
``$DF/dfhack-config/scripts/data/planeswalkers/<name>/``.
Format v5 includes terrain, magma and temperature grids. Format v4 is
loadable without source heat data; v2 is loadable without source magma or
heat data. Format v3 must be saved again because it omitted lower terrain.

COMMANDS
--------

    fort/planeswalkers save [name]          save the current fortress
    fort/planeswalkers save <name> --overwrite
                                            replace a complete or partial snapshot
    fort/planeswalkers info                 show this help
    fort/planeswalkers gui                  choose a fort/party save
    fort/planeswalkers party [name] <ids>   save selected travellers and items
    fort/planeswalkers list                 open the snapshot browser
    fort/planeswalkers load                 open the snapshot browser
    fort/planeswalkers load <name|number>    restore a fortress
    fort/planeswalkers load ... --force     allow same-world/non-empty restore
    fort/planeswalkers load <name> --add-z  add required sky levels; save/reload, then retry
    fort/planeswalkers preview <name>        inspect placement without changing it
    fort/planeswalkers compare <a> <b>       compare snapshot metadata
    fort/planeswalkers delete <name> --yes   delete snapshot and partial data
    fort/planeswalkers delete-list          delete all snapshots and partials
    fort/planeswalkers delete-list --preserve <name> [name ...]
                                            delete all except named snapshots
    fort/planeswalkers spires               re-arm restored spires
    fort/planeswalkers repair               restore static origin magma from snapshot
    fort/planeswalkers status               show job and restore status
    fort/planeswalkers report               open the latest save/load operation report
    fort/planeswalkers compact-report       shrink the saved JSON report for sharing
                                            (keeps counts and concise examples)
    fort/planeswalkers cancel               cancel the active job
    fort/planeswalkers step                 pump one chunk manually
]====]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local function req(mod) return reqscript('internal/planeswalkers/' .. mod) end
local common = req('common')

local GLOBAL_KEY = 'planeswalkers'

-- ---- overlay pump: runs the current job even while the game is paused -------

PumpOverlay = defclass(PumpOverlay, overlay.OverlayWidget)
PumpOverlay.ATTRS{
    desc = 'Runs and displays fort/planeswalkers save/load progress.',
    default_enabled = true,
    version = '6', -- reset saved size/position for the framed progress panel
    viewscreens = 'dwarfmode',
    frame_style = gui.FRAME_MEDIUM,
    frame_title = 'Planeswalkers - Operation',
    frame_background = dfhack.pen.parse{ch = ' ', fg = COLOR_WHITE, bg = COLOR_BLACK},
    overlay_onupdate_max_freq_seconds = 0,
    -- Negative y anchors from the bottom edge. Keep the live progress panel
    -- in the lower-right corner by default; players can still reposition it
    -- with gui/overlay or `overlay position pump`.
    default_pos = {x = -2, y = -2},
    frame = {w = 1, h = 1},
}

local function held_count()
    local n = 0
    for _, u in ipairs(df.global.world.units.active) do n = n + #u.inventory end
    return n
end

local PHASE_LABELS = {
    ['terrain shapes'] = 'Updating terrain',
    ['magma sea'] = 'Restoring magma',
    ['replace destination magma with source magma'] = 'Restoring magma',
    ['magma separation buffer'] = 'Separating magma layers',
    ['surface buffer smoothing'] = 'Smoothing exterior border',
    ['surface and underground boundary bulkhead'] = 'Sealing world boundary',
    ['terrain integrity validation'] = 'Validating restored terrain',
    ['plants'] = 'Restoring plants',
    ['buildings'] = 'Restoring buildings',
    ['units'] = 'Restoring units',
    ['items'] = 'Restoring items',
    ['map cleanup'] = 'Finalizing map',
    ['relocate embark party and wagon supplies'] = 'Relocating embark party',
    ['record fresh embark party'] = 'Recording embark party',
}

function PumpOverlay:init()
    -- Overlay widgets should contain ordinary child widgets directly. A nested
    -- Window was not reliably rendered by the overlay host and could disappear
    -- entirely after a rescan.
    self.visible = true
    self.frame.w, self.frame.h = 1, 1
    self:addviews{
        widgets.Label{view_id = 'operation', frame = {t = 0, l = 1, w = 62}, text = ''},
        widgets.Label{view_id = 'bar', frame = {t = 1, l = 1, w = 62}, text = ''},
        widgets.Label{view_id = 'phase', frame = {t = 2, l = 1, w = 62}, text = ''},
        widgets.HotkeyLabel{view_id = 'cancel', frame = {t = 3, l = 1}, key = 'CUSTOM_SHIFT_C',
            label = 'Cancel operation', on_activate = function() common.cancel_job() end},
    }
end

function PumpOverlay:overlay_onupdate()
    -- Keep the widget itself active so it continues pumping jobs while DF is
    -- paused. Shrink it to one tile when idle instead of hiding it; hidden
    -- overlays are not guaranteed to receive update callbacks on all screens.
    self.visible = true
    local job = common.current_job()
    if not job then
        self.frame.w, self.frame.h = 1, 1
        self.subviews.operation:setText('')
        self.subviews.bar:setText('')
        self.subviews.phase:setText('')
        return
    end

    -- Snapshot before pumping as well as after: a short phase can finish inside
    -- this frame's time budget, but the final stage should still be visible.
    local before = common.job_progress()
    common.pump()
    local progress = common.job_progress() or before
    if not progress then return end

    self.frame.w, self.frame.h = 66, 6
    local name = progress.phase_name or 'working'
    local label = PHASE_LABELS[name] or name:gsub('^%l', string.upper)
    self.subviews.operation:setText(label .. ':')

    local bar
    if progress.position ~= nil and progress.total and progress.total > 0 then
        local width = 30
        local pct = math.max(0, math.min(100, progress.percent or 0))
        local filled = math.floor(width * pct / 100)
        bar = ('[%s%s] stage %d/%d (%d%%)')
            :format(string.rep('#', filled), string.rep('-', width - filled),
                    progress.position, progress.total, pct)
    else
        bar = '[working...] stage --/--'
    end
    self.subviews.bar:setText(bar)
    self.subviews.phase:setText(('Phase %d/%d  |  %.1fs elapsed')
        :format(progress.phase_idx, progress.phase_count, progress.elapsed / 1000))
end

OVERLAY_WIDGETS = {pump = PumpOverlay}

-- A job lives in dfhack.internal so a script reload cannot orphan it, which also
-- means nothing about unloading a world clears it on its own. Without this hook a
-- job abandoned in one fort is still there when the next one embarks, and the pump
-- above -- default_enabled, dwarfmode, no frequency cap -- resumes it every frame
-- against the old world's data. Retire the job on the way out and hand the new
-- world a fresh token so any straggler is recognised as stale.
dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        if common.cancel_job() then
            print('planeswalkers: job cancelled -- the world it was running against '
                  .. 'is being unloaded')
        end
        common.new_world_token()
    elseif sc == SC_MAP_LOADED then
        common.new_world_token()
    end
end

-- ---- actions ---------------------------------------------------------------

local function fort_display_name()
    local site = df.global.world.world_data.active_site[0]
    return site and dfhack.translation.translateName(site.name) or 'fort'
end

local function fort_name()
    -- Snapshot directory names stay portable ASCII. The original translated
    -- UTF-8 site name is stored separately in the manifest for display.
    local n = fort_display_name():lower():gsub('[^%w]+', '-')
        :gsub('^%-+', ''):gsub('%-+$', '')
    return n ~= '' and n or 'fort'
end

-- in-game notification (the console scrolls away while the job runs)
local function notify(msg, color, popup)
    print('planeswalkers: ' .. msg)
    color = color or COLOR_LIGHTCYAN
    pcall(dfhack.gui.showAnnouncement, 'planeswalkers: ' .. msg, color, true)
    if popup then pcall(dfhack.gui.showPopupAnnouncement, msg, color, true) end
end


-- Build a short player-facing summary and a separate diagnostic view.
local function issue_label(category)
    local key = category:lower()
    if key:find('error') or key:find('failed') or key:find('unresolved') then
        return '[ERROR] '
    elseif key:find('missing') or key:find('not%-placed') or key:find('no%-safe')
        or key:find('skipped') or key:find('clipped') then
        return '[SKIPPED] '
    elseif key:find('substitut') or key:find('approximat') or key:find('literalized') then
        return '[SUBSTITUTED] '
    end
    return '[DEGRADED] '
end

local function build_restore_report(ctx, name, world, elapsed)
    local civ = ctx.source_civ_name or 'Unknown civilization'
    local function ratio(done, total)
        if total == nil then return 'not processed' end
        return ('%d/%d'):format(done or 0, total)
    end
    local summary = {
        'FORTRESS RESTORE QUICK REPORT',
        ('Snapshot: %s'):format(name or '?'),
        ('Origin fortress: %s'):format(ctx.manifest.fort_display or ctx.manifest.fort or name or '?'),
        ('Origin civilization: %s'):format(civ),
        ('Origin world: %s'):format(world or '?'),
        ('Elapsed: %.1f seconds'):format((elapsed or 0) / 1000),
        '', 'RESTORED',
        ('Terrain blocks: %s'):format(ratio(ctx.terrain_blocks_processed,
            ctx.terrain_blocks_expected)),
        ('Magma blocks: %s'):format(ratio(ctx.magma_blocks_restored,
            ctx.manifest.counts and ctx.manifest.counts.magma_blocks)),
        ('Trees restored: %s'):format(ratio(ctx.trees_restored, ctx.trees_expected)),
        ('Buildings: %s'):format(ratio(ctx.buildings_restored, ctx.manifest.counts and ctx.manifest.counts.buildings)),
        ('Items: %s'):format(ratio(ctx.items_restored, ctx.manifest.counts and ctx.manifest.counts.items)),
        ('Corpses approximated as remains: %s'):format(ratio(ctx.corpses_approximated, ctx.manifest.counts and ctx.manifest.counts.corpses)),
        ('Constructions: %s'):format(ratio(ctx.constructions_restored, ctx.manifest.counts and ctx.manifest.counts.constructions)),
        ('Artifacts: %s'):format(ratio(ctx.artifacts_restored, ctx.manifest.counts and ctx.manifest.counts.artifacts)),
        ('Squads: %s'):format(ratio(ctx.squads_restored, ctx.manifest.counts and ctx.manifest.counts.squads)),
        ('Burrows: %s'):format(ratio(ctx.burrows_restored, ctx.manifest.counts and ctx.manifest.counts.burrows)),
        ('Manager orders: %s'):format(ratio(ctx.orders_restored, ctx.manifest.counts and ctx.manifest.counts.orders)),
        ('Plants restored: %s'):format(ratio(ctx.plants_restored, ctx.plants_expected)),
        ('Units: %s'):format(ratio(ctx.units_restored, ctx.manifest.counts and ctx.manifest.counts.units)),

        ('Embark units safely relocated: %s'):format(ratio(ctx.embark_units_moved,
            ctx.embark_units_expected)),
        ('Wagon supplies relocated: %s'):format(ratio(ctx.embark_items_moved,
            ctx.embark_items_expected)),
    }
    if ctx.magma_tiles_restored or ctx.magma_blocks_restored then
        summary[#summary + 1] = ('Magma tiles restored: %d'):format(ctx.magma_tiles_restored or 0)
    end

    local advanced = {'ADVANCED RESTORE DETAILS'}
    local function add(v) if v and v ~= '' then advanced[#advanced + 1] = v end end
    add(ctx.plants_report)
    add(ctx.liquid_safety_report)
    add(ctx.magma_restore_report)
    add(ctx.liquid_cap_report)
    add(ctx.magma_report)
    add(ctx.spire_report)
    add(ctx.spire_contents_report)
    add(ctx.geo_report)
    add(ctx.surface_buffer_report)
    add(ctx.boundary_seal_report)
    add(ctx.terrain_integrity_report)
    add(ctx.embark_relocation_report)
    if ctx.native_contents_cleared then
        add(('Destination spire-content monitors disarmed: %d'):format(ctx.native_contents_cleared))
    end
    if ctx.components_reminted then
        add(('Building components reinserted: %d building(s)'):format(ctx.components_reminted))
    end
    if ctx.preserve_depths then
        local sk = ctx.preserve_depths_skipped or {}
        add(('Preserve-depths cutoff: destination levels 0-%d retained')
            :format(ctx.preserve_depths_cutoff or 0))
        add(('Filtered records: %d buildings, %d items, %d units, %d plants, %d burrow records, %d manager orders')
            :format(sk.buildings or 0, sk.items or 0, sk.units or 0,
                    sk.plants or 0, sk.burrows or 0, sk.orders or 0))
    end
    add(('Items attached to travellers: %d'):format(ctx.held_attached or 0))
    add(('Items still held at completion: %d'):format(ctx.held_at_end or 0))

    local skips, cats = ctx.skips or {}, {}
    for category in pairs(skips) do cats[#cats + 1] = category end
    table.sort(cats)
    advanced[#advanced + 1] = ''
    advanced[#advanced + 1] = 'RESTORE NOTES GROUPED BY CAUSE'
    if #cats == 0 then
        advanced[#advanced + 1] = 'No restore issues or intentional exclusions were reported.'
        summary[#summary + 1] = ''
        summary[#summary + 1] = 'Issues: none reported'
    else
        local issue_records, review_groups, informational_groups = 0, 0, 0
        local guidance = {
            ['item-outside-footprint'] = {'Items outside the transferred area', 'These items were outside the origin fort footprint and were intentionally left in the destination world.'},
            ['blocks-clipped-at-z-edge'] = {'Terrain beyond the destination map height', 'The destination map does not contain these Z-levels. Use a destination with sufficient vertical space.'},
            ['blocks-below-hell-ceiling-untouched'] = {'Protected underworld terrain', 'These blocks were deliberately left untouched to protect the destination underworld.'},
            ['blocks-at-or-below-magma-sea-boundary-not-transferred'] = {'Protected magma boundary', 'These blocks belong to the magma feature boundary and are handled separately.'},
            ['origin-underworld-preserved-at-destination'] = {'Origin underworld intentionally not imported', 'The origin underworld has world-specific feature registrations and inhabitants. The destination underworld is retained to avoid transplanting invalid demon, spire, and underworld references. This is an intentional compatibility choice, not a restore failure.'},
            ['tiles-at-hell-ceiling-guarded'] = {'Protected underworld ceiling', 'These tiles were left unchanged to avoid opening the destination underworld.'},
            ['plant-tiles-degraded (regrow naturally)'] = {'Plant terrain approximation', 'Some plant tile details could not be copied exactly; the destination can regrow them.'},
        }
        for _, category in ipairs(cats) do
            local entry = skips[category]
            local count = entry.n or 0
            issue_records = issue_records + count
            local info = guidance[category]
            if info then informational_groups = informational_groups + 1
            else review_groups = review_groups + 1 end
            local label = info and '[INFO]' or issue_label(category)
            local title = info and info[1] or category:gsub('%-', ' '):gsub('^%l', string.upper)
            advanced[#advanced + 1] = ('%s %s - %d record(s)'):format(label, title, count)
            if info then
                advanced[#advanced + 1] = '  Meaning: ' .. info[2]
            else
                local action
                if category:find('material') or category:find('subtype') or category:find('race') then
                    action = 'The destination world is missing a compatible raw/material. Use a world with the required raws, or accept the listed substitution/omission.'
                elseif category:find('item') then
                    action = 'Some items could not be recreated or placed. Review the examples below; affected item types/materials may not be supported by the destination raws.'
                elseif category:find('unit') then
                    action = 'A unit could not be safely restored or relocated. Check the listed unit and its destination terrain.'
                elseif category:find('building') or category:find('construction') then
                    action = 'A building or construction could not be recreated at its original coordinates. Check space, terrain, and required raws.'
                elseif category:find('tree') or category:find('plant') then
                    action = 'A plant or tree could not be recreated exactly. Check destination plant raws and available terrain.'
                else
                    action = 'Review the examples below. This group identifies one repeated cause; it is not a separate error window for every affected record.'
                end
                advanced[#advanced + 1] = '  Meaning/action: ' .. action
            end
            if entry.examples and #entry.examples > 0 then
                advanced[#advanced + 1] = '  Examples: ' .. table.concat(entry.examples, '; ')
            end
        end
        summary[#summary + 1] = ('Restore notes: %d cause group(s), %d informational group(s), %d requiring review; %d affected record(s). See Advanced tab.')
            :format(#cats, issue_records, informational_groups, review_groups)
    end

    advanced[#advanced + 1] = ''
    advanced[#advanced + 1] = 'PHASE TIMINGS'
    for _, p in ipairs(ctx.phase_times or {}) do
        advanced[#advanced + 1] = ('%s: %.2fs'):format(p.name, (p.ms or 0) / 1000)
    end
    return table.concat(summary, '\n'), table.concat(advanced, '\n')
end

local ReportWindow = defclass(ReportWindow, widgets.Window)
ReportWindow.ATTRS{
    frame_title = 'Planeswalkers Operation Report',
    frame = {w = 76, h = 38},
    resizable = true,
    resize_min = {w = 54, h = 18},
    summary_text = DEFAULT_NIL,
    advanced_text = DEFAULT_NIL,
}
local function report_choices(value)
    local out = {}
    local width = 68
    local function char_count(s)
        local _, n = s:gsub('[^\128-\191]', '')
        return n
    end
    local function byte_at_char(s, n)
        if utf8 and utf8.offset then return utf8.offset(s, n) end
        local pos, count = 1, 0
        while pos <= #s do
            count = count + 1
            if count == n then return pos end
            local b = s:byte(pos)
            pos = pos + (b < 0x80 and 1 or (b < 0xE0 and 2 or (b < 0xF0 and 3 or 4)))
        end
        return #s + 1
    end
    for line in ((value or '') .. '\n'):gmatch('(.-)\n') do
        if line == '' then
            out[#out + 1] = {text = ' '}
        else
            while char_count(line) > width do
                local byte_limit = byte_at_char(line, width + 1) or (#line + 1)
                local prefix = line:sub(1, byte_limit - 1)
                local cut = prefix:match('^.*() ')
                if not cut or char_count(line:sub(1, cut - 1)) < 20 then cut = byte_limit end
                out[#out + 1] = {text = line:sub(1, cut - 1)}
                line = '  ' .. line:sub(cut + (cut == byte_limit and 0 or 1))
            end
            out[#out + 1] = {text = line}
        end
    end
    if #out == 0 then out[1] = {text = 'No report available.'} end
    return out
end

function ReportWindow:init()
    self.cur_page = 1
    self.summary_choices = report_choices(self.summary_text)
    self.advanced_choices = report_choices(self.advanced_text)
    self:addviews{
        widgets.TabBar{
            view_id = 'tabs', frame = {t = 0, l = 1, w = 70},
            labels = {'Quick Report', 'Advanced'},
            get_cur_page = function() return self.cur_page end,
            on_select = function(idx)
                self.cur_page = idx
                if self.subviews.lines then
                    self.subviews.lines:setChoices(idx == 1 and self.summary_choices or self.advanced_choices)
                end
            end,
        },
        widgets.List{
            view_id = 'lines', frame = {t = 2, l = 1, r = 1, b = 1},
            choices = self.summary_choices,
            on_submit = function() end,
        },
    }
end

local ReportScreen = defclass(ReportScreen, gui.ZScreenModal)
ReportScreen.ATTRS{focus_path = 'planeswalkers-report', summary_text = DEFAULT_NIL, advanced_text = DEFAULT_NIL}
function ReportScreen:init()
    self:addviews{ReportWindow{
        summary_text = self.summary_text,
        advanced_text = self.advanced_text,
    }}
end

local active_report_screen
local function show_restore_report(summary, advanced)
    summary = (summary and summary ~= '') and summary
        or 'No completed restore report is saved for this fortress.'
    advanced = (advanced and advanced ~= '') and advanced or summary

    local function open_report()
        local ok, err = pcall(function()
            if active_report_screen and active_report_screen:isActive() then
                active_report_screen:dismiss()
            end
            active_report_screen = ReportScreen{
                summary_text = summary,
                advanced_text = advanced,
            }:show()
        end)
        if not ok then
            dfhack.printerr('planeswalkers: could not open report window: ' .. tostring(err))
            print(summary)
            print(advanced)
        end
    end

    -- The restore callback runs from the overlay's update loop. Opening a modal
    -- screen inside that callback can race the active viewscreen update. Defer
    -- it one raw frame (which still advances while the game is paused).
    local ok, timer = pcall(dfhack.timeout, 1, 'frames', open_report)
    if not ok or not timer then open_report() end
end

local function require_fort()
    if not dfhack.world.isFortressMode() or not dfhack.isMapLoaded() then
        qerror('planeswalkers: needs a loaded fortress')
    end
end

-- ---- taking a party rather than a fort ------------------------------------
--
-- A PARTY SNAPSHOT is the same machinery pointed at a handful of rows: chosen units, their
-- gear, and nothing else -- no terrain, no buildings, no stockpiles, no plants. It exists
-- because "walk into the next world with these seven dwarves and what they carry" is a
-- different wish from "move my fortress", and rebuilding a map you did not ask for is both
-- slow and destructive to the fort you arrive in.
--
-- The gear is not a separate choice. Whatever a chosen unit is wearing, wielding or carrying
-- comes with them, containers and contents included -- a backpack arrives with what is in it.
-- Extra items can be named on top of that.
local function party_selection(unit_ids, item_ids)
    local sel = {units = {}, items = {}}
    for _, id in ipairs(unit_ids or {}) do sel.units[tonumber(id)] = true end
    for _, id in ipairs(item_ids or {}) do sel.items[tonumber(id)] = true end

    -- everything the chosen units have on them, following containers down
    local function take(item)
        if not item or sel.items[item.id] then return end
        sel.items[item.id] = true
        local ok, contents = pcall(dfhack.items.getContainedItems, item)
        if ok then for _, c in ipairs(contents) do take(c) end end
    end
    for id in pairs(sel.units) do
        local u = df.unit.find(id)
        if u then
            for _, inv in ipairs(u.inventory) do take(inv.item) end
        end
    end
    return sel
end

local function do_save_impl(name, selection_or_flag, ...)
    local select = selection_or_flag
    local overwrite = false
    if type(selection_or_flag) == 'string' then
        overwrite = selection_or_flag == '--overwrite'
        select = nil
    end
    for _, flag in ipairs({...}) do
        if flag == '--overwrite' then overwrite = true end
    end
    require_fort()
    name = name or (fort_name() .. '-' .. os.date('%Y%m%d-%H%M'))
    if not common.valid_name(name) then
        qerror('planeswalkers: bad name (use letters/digits/-_.): ' .. tostring(name))
    end
    if common.current_job() then
        qerror('planeswalkers: a save/load job is already running; cancel it or wait for it to finish')
    end
    local operation_report = common.begin_operation_report('save', name, {
        mode = select and 'party' or 'fort',
        world = common.u(dfhack.translation.translateName(df.global.world.world_data.name)),
        fortress = fort_name(), df_version = dfhack.getDFVersion(),
        format_version = common.FORMAT_VERSION,
    })
    local final_dir = common.snap_dir(name)
    local pending_dir = final_dir .. '.pending'
    local exists_final = dfhack.filesystem.isdir(final_dir)
    local exists_pending = dfhack.filesystem.isdir(pending_dir)
    local failed_publish_dir = final_dir .. '.publish_failed'
    local exists_failed_publish = dfhack.filesystem.isdir(failed_publish_dir)
    if (exists_final or exists_pending or exists_failed_publish) and not overwrite then
        qerror('planeswalkers: snapshot or incomplete save already exists: ' .. name ..
               '; use `save ' .. name .. ' --overwrite` to replace it')
    end
    if overwrite then
        for _, stale_dir in ipairs({pending_dir, failed_publish_dir}) do
            if dfhack.filesystem.exists(stale_dir) then
                local removed, remove_err = common.remove_tree(stale_dir)
                if not removed or dfhack.filesystem.exists(stale_dir) then
                    qerror(('planeswalkers: cannot replace incomplete snapshot "%s"; could not remove %s (%s). ' ..
                            'Close any open files/game sessions using this snapshot, then run delete "%s" --yes.')
                        :format(name, stale_dir, tostring(remove_err or 'directory still exists'), name))
                end
            end
        end
    end
    local made, make_err = pcall(dfhack.filesystem.mkdir_recursive, pending_dir)
    if not made or not dfhack.filesystem.isdir(pending_dir) then
        qerror(('planeswalkers: could not create snapshot directory %s: %s')
            :format(pending_dir, tostring(make_err or 'directory was not created')))
    end

    local terrain = req('terrain')
    local map = df.global.world.map
    -- a fort that was restored here into a larger embark is saved at the size
    -- and area it arrived with, not at the size of this embark
    local marker = dfhack.persistent.getSiteData(GLOBAL_KEY)
    local origin = marker and marker.state == 'done' and marker.anchor
        and common.footprint_origin(marker.anchor) or nil
    local footprint
    if origin then
        footprint = {
            bx = origin.bx, by = origin.by, wb = origin.wb, hb = origin.hb,
            from = marker.from, world = marker.world,
        }
        notify(('saving the %dx%d-block footprint this fort was restored into (from ' ..
                '"%s" of world "%s"), not the whole %dx%d embark')
               :format(origin.wb, origin.hb, marker.from or '?', marker.world or '?',
                       map.x_count_block, map.y_count_block))
    else
        origin = common.whole_map_origin()
    end
    local source_civ_id = df.global.plotinfo.civ_id
    local source_civ = source_civ_id and df.historical_entity.find(source_civ_id) or nil
    local source_civ_name = source_civ and dfhack.translation.translateName(source_civ.name)
        or 'Unknown civilization'
    local ctx = {
        name = name,
        operation_report = operation_report,
        source_civ_id = source_civ_id,
        source_civ_name = common.u(source_civ_name),
        dir = pending_dir,
        final_dir = final_dir,
        origin = origin,
        legend_tt = common.Legend.new(),
        legend_mat = common.Legend.new(),
        legend_plant = common.Legend.new(),
        skips = {},
        select = select,
        party = select and true or nil,
        manifest = {
            v = 1,
            format_version = common.FORMAT_VERSION,
            mode = select and 'party' or 'fort',
            name = name,
            world = common.u(dfhack.translation.translateName(df.global.world.world_data.name)),
            fort = fort_name(),
            fort_display = common.u(fort_display_name()),
            civilization = {id = source_civ_id, name = common.u(source_civ_name)},
            created = os.date('%Y-%m-%d %H:%M:%S'),
            df_version = dfhack.getDFVersion(),
            dims = {
                bx = origin.wb, by = origin.hb, bz = map.z_count_block,
                surface = terrain.find_surface_z(origin),
                top_z = terrain.find_highest_nonempty_z(origin),
            },
            footprint = footprint,
            counts = {},
            complete = {},
        },
        close_all = function(self)
            if self.tiles_f then pcall(self.tiles_f.close, self.tiles_f); self.tiles_f = nil end
            if self.grass_f then pcall(self.grass_f.close, self.grass_f); self.grass_f = nil end
            if self.magma_f then pcall(self.magma_f.close, self.magma_f); self.magma_f = nil end
            if self.heat_f then pcall(self.heat_f.close, self.heat_f); self.heat_f = nil end
            if self.plants_f then pcall(self.plants_f.close, self.plants_f); self.plants_f = nil end
        end,
        on_abort = function(self, reason)
            if reason == 'cancelled' then
                -- Explicit cancellation is a request to discard this snapshot.
                -- Failures retain their pending directory and diagnostics so
                -- `save <name> --overwrite` or delete-list can clean it later.
                pcall(common.remove_tree, self.dir)
                notify(('snapshot "%s" cancelled; partial data deleted'):format(self.name),
                       COLOR_YELLOW, true)
                return
            end
            local diagnostic = {
                name = self.name, state = 'incomplete', reason = tostring(reason),
                failed_phase = self.last_failed_phase or 'initialization',
                created = self.manifest.created, format_version = self.manifest.format_version,
            }
            local wrote, write_err = pcall(common.write_json, self.dir .. '/pending.json', diagnostic)
            dfhack.printerr(('planeswalkers: snapshot "%s" failed in phase "%s": %s')
                :format(self.name, diagnostic.failed_phase, tostring(reason)))
            if not wrote then
                dfhack.printerr(('planeswalkers: could not write failure details: %s')
                    :format(tostring(write_err)))
            end
            notify(('snapshot "%s" failed in phase "%s"; incomplete data retained. ' ..
                    'See the console for the exact error. Retry with: fort/planeswalkers save %s --overwrite')
                :format(self.name, diagnostic.failed_phase, self.name), COLOR_YELLOW, true)
        end,
    }

    local phases_ok, phases = pcall(function()
        local result = {}
        if select then
            -- units first so the histfig pass sees them; items carry the gear
            for _, phase in ipairs(req('items').save_phases(ctx)) do table.insert(result, phase) end
            for _, phase in ipairs(req('units').save_phases(ctx)) do table.insert(result, phase) end
        else
            for _, phase in ipairs(terrain.save_phases(ctx)) do table.insert(result, phase) end
            for _, module_name in ipairs({'spires', 'plants', 'buildings', 'orders', 'items',
                                           'units', 'squads', 'burrows'}) do
                for _, phase in ipairs(req(module_name).save_phases(ctx)) do
                    table.insert(result, phase)
                end
            end
        end
        return result
    end)
    if not phases_ok then
        ctx.last_failed_phase = 'initialization'
        ctx:close_all()
        common.finish_operation_report(ctx, 'failed', tostring(phases), 'initialization', nil)
        ctx:on_abort(phases)
        qerror(('planeswalkers: could not initialize snapshot "%s": %s')
            :format(name, tostring(phases)))
    end
    common.start_job('save ' .. name, phases, ctx, function()
        common.write_json(ctx.dir .. '/legend.json',
            {v = 1, tiletypes = ctx.legend_tt.list, mats = ctx.legend_mat.list,
             plants = ctx.legend_plant.list})
        ctx.manifest.skips = {}
        for cat, c in pairs(ctx.skips or {}) do
            ctx.manifest.skips[cat] = {n = c.n, examples = c.examples}
        end
        -- The manifest is the completion marker. Publish the directory only
        -- after every phase and every metadata file has been written.
        common.write_json(ctx.dir .. '/manifest.json', ctx.manifest)
        -- Verify the completion marker from disk before publishing. A successful
        -- encode call alone is not enough: load resolves snapshots by this exact file.
        local pending_manifest = common.read_json(ctx.dir .. '/manifest.json')
        local pending_complete = pending_manifest and pending_manifest.complete
        local pending_valid = pending_manifest and pending_manifest.name == ctx.name
            and (ctx.party and pending_complete and pending_complete.units and pending_complete.items
                or not ctx.party and pending_complete and pending_complete.terrain
                    and pending_complete.constructions)
        if not pending_valid then
            qerror(('planeswalkers: manifest verification failed for pending snapshot at %s; refusing to report a successful save')
                :format(ctx.dir))
        end
        local backup_dir = ctx.final_dir .. '.replaced'
        if dfhack.filesystem.exists(backup_dir) then
            local removed, remove_err = common.remove_tree(backup_dir)
            if not removed then
                qerror(('planeswalkers: cannot publish snapshot; stale replacement backup could not be removed (%s)')
                    :format(tostring(remove_err)))
            end
        end
        local had_old = dfhack.filesystem.isdir(ctx.final_dir)
        if had_old then
            local backed_up, backup_err = os.rename(ctx.final_dir, backup_dir)
            if not backed_up then
                qerror(('planeswalkers: could not stage the previous snapshot for replacement (%s); pending data remains at %s')
                    :format(tostring(backup_err), ctx.dir))
            end
        end
        local renamed, rename_err = os.rename(ctx.dir, ctx.final_dir)
        if not renamed then
            if had_old then os.rename(backup_dir, ctx.final_dir) end
            qerror(('planeswalkers: snapshot data is complete but could not be published (%s); pending data remains at %s')
                :format(tostring(rename_err), ctx.dir))
        end
        ctx.dir = ctx.final_dir
        -- Verify the published directory at the same path used by `load <name>`.
        -- If it is not readable, restore the previous snapshot when possible.
        local published_manifest = common.read_json(ctx.final_dir .. '/manifest.json')
        if not dfhack.filesystem.isdir(ctx.final_dir) or not published_manifest
            or published_manifest.name ~= ctx.name then
            local failed_dir = ctx.final_dir .. '.publish_failed'
            if dfhack.filesystem.isdir(ctx.final_dir) then os.rename(ctx.final_dir, failed_dir) end
            if had_old and dfhack.filesystem.isdir(backup_dir) then
                os.rename(backup_dir, ctx.final_dir)
            end
            ctx.dir = failed_dir
            qerror(('planeswalkers: publish verification failed; snapshot is not loadable at %s. Previous snapshot restoration was attempted.')
                :format(ctx.final_dir))
        end
        ctx.published = true
        if had_old then
            local removed, remove_err = common.remove_tree(backup_dir)
            if not removed then
                dfhack.printerr(('planeswalkers: snapshot was saved, but the previous backup remains at %s: %s')
                    :format(backup_dir, tostring(remove_err)))
            end
        end
        common.print_skips(ctx)
        notify(('snapshot "%s" saved and verified at %s. Load it on a fresh embark in another ' ..
                'world with: fort/planeswalkers load %s'):format(name, ctx.dir, name),
               COLOR_LIGHTGREEN, true)
    end)
end

local function do_save(...)
    local previous = common.current_operation_report()
    local result = table.pack(pcall(do_save_impl, ...))
    if not result[1] then
        local current = common.current_operation_report()
        if current and current ~= previous and current.state == 'running' then
            common.finish_operation_report(nil, 'failed', tostring(result[2]), 'preflight', nil)
        end
        qerror(result[2])
    end
    return table.unpack(result, 2, result.n)
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

-- ---- legacy filtered-restore helpers ---------------------------------------
-- Retained internally for compatibility with old development code; the public
-- restore path now always replaces the complete source footprint. These wrappers
-- in-memory snapshot after its normal initializer has built its job tables.
local function preserve_depth_filter(phases, job_key, ctx, category, block_records)
    for _, phase in ipairs(phases) do
        local old_init = phase.init
        if old_init then
            phase.init = function(job, ...)
                local result = old_init(job, ...)
                local data = job[job_key]
                if data and data.list then
                    local kept = {}
                    local removed = 0
                    if block_records then
                        for _, rec in ipairs(data.list) do
                            local blocks = {}
                            for _, blk in ipairs(rec.blocks or {}) do
                                if (blk[3] + ctx.anchor.off_z) > ctx.preserve_depths_cutoff then
                                    blocks[#blocks + 1] = blk
                                else
                                    removed = removed + 1
                                end
                            end
                            rec.blocks = blocks
                            if #blocks > 0 then
                                kept[#kept + 1] = rec
                            else
                                removed = removed + 1
                            end
                        end
                    else
                        for _, rec in ipairs(data.list) do
                            -- Rebuilt tree roots extend below the plant's base
                            -- tile. Keep a small vertical margin so a tree
                            -- cannot stamp root tiles into protected geology.
                            local margin = (category == 'plants' and rec.tree) and 16 or 0
                            if rec.z == nil or (rec.z + ctx.anchor.off_z) > (ctx.preserve_depths_cutoff + margin) then
                                kept[#kept + 1] = rec
                            else
                                removed = removed + 1
                            end
                        end
                    end
                    data.list = kept
                    -- Items build an ordered dependency list during init. Filter
                    -- that too, or deep containers could still be minted.
                    if job.ordered then
                        local ordered = {}
                        for _, rec in ipairs(job.ordered) do
                            if rec.z == nil or (rec.z + ctx.anchor.off_z) > ctx.preserve_depths_cutoff then
                                ordered[#ordered + 1] = rec
                            end
                        end
                        job.ordered = ordered
                    end
                    if removed > 0 then
                        ctx.preserve_depths_skipped = ctx.preserve_depths_skipped or {}
                        ctx.preserve_depths_skipped[category] =
                            (ctx.preserve_depths_skipped[category] or 0) + removed
                    end
                end
                -- The unit loader falls back to spawn_anchor when a saved
                -- coordinate is blocked. Never let that fallback place an
                -- imported unit inside the protected destination depth band.
                if category == 'units' and ctx.spawn_anchor
                    and not common.above_transfer_cutoff(ctx, ctx.spawn_anchor.z) then
                    ctx.spawn_anchor = nil
                    for _, citizen in ipairs(dfhack.units.getCitizens(true)) do
                        if common.above_transfer_cutoff(ctx, citizen.pos.z) then
                            ctx.spawn_anchor = xyz2pos(citizen.pos.x, citizen.pos.y, citizen.pos.z)
                            break
                        end
                    end
                end
                return result
            end
        end
    end
    return phases
end

local function preserve_building_clear_phase(ctx)
    local phase = req('buildings').clear_phase(ctx)
    local old_init = phase.init
    phase.init = function(job, ...)
        local result = old_init(job, ...)
        local x0, y0 = ctx.anchor.off_x, ctx.anchor.off_y
        local x1 = x0 + ctx.manifest.dims.bx * 16
        local y1 = y0 + ctx.manifest.dims.by * 16
        local kept = {}
        for _, bld in ipairs(job.old or {}) do
            local overlaps = bld.x2 >= x0 and bld.x1 < x1
                and bld.y2 >= y0 and bld.y1 < y1
            -- Leave destination buildings outside the imported footprint and
            -- every building below the actual transfer boundary untouched.
            if not (overlaps and common.above_transfer_cutoff(ctx, bld.z)) then
                kept[#kept + 1] = bld
            end
        end
        job.old = kept
        job.cursor = 1
        return result
    end
    return phase
end

local function preserve_orders_phases(ctx)
    local phases = req('orders').load_phases(ctx)
    for _, phase in ipairs(phases) do
        local old_step = phase.step
        phase.step = function(job, deadline)
            -- orders.lua reads orders.json inside step(), not init(). Filter
            -- workshop-restricted orders after buildings have been restored,
            -- so an order for a deliberately omitted deep workshop cannot
            -- become an unrestricted manager order in the destination.
            local old_read = common.read_json
            common.read_json = function(path)
                local data = old_read(path)
                if path == ctx.dir .. '/orders.json' and type(data) == 'table' then
                    local legacy = data.list ~= nil
                    local list = legacy and data.list or data
                    local kept, removed = {}, 0
                    for _, order in ipairs(list or {}) do
                        local workshop = order.workshop_id or order.workshop
                        if not workshop or (ctx.bld_map and ctx.bld_map[workshop]) then
                            kept[#kept + 1] = order
                        else
                            removed = removed + 1
                        end
                    end
                    if legacy then data.list = kept else data = kept end
                    if removed > 0 then
                        ctx.preserve_depths_skipped = ctx.preserve_depths_skipped or {}
                        ctx.preserve_depths_skipped.orders =
                            (ctx.preserve_depths_skipped.orders or 0) + removed
                    end
                end
                return data
            end
            local ok, result = pcall(old_step, job, deadline)
            common.read_json = old_read
            if not ok then error(result) end
            return result
        end
    end
    return phases
end

-- Native spire monitors are normally disarmed across the whole imported
-- rectangle. Here, only monitors with trigger tiles in the overwritten band
-- are disarmed; monitors entirely below the cutoff remain native and intact.
local function preserve_spire_clear_phase(ctx)
    return {
        name = 'disarm native spire contents above preserved depths',
        step = function(job)
            local ev = df.global.world.event
            local x0, y0 = ctx.anchor.off_x, ctx.anchor.off_y
            local x1 = x0 + ctx.manifest.dims.bx * 16
            local y1 = y0 + ctx.manifest.dims.by * 16
            local n = 0
            local function path_touches(path)
                for i = 0, #path.x - 1 do
                    local x, y, z = path.x[i], path.y[i], path.z[i]
                    if common.above_transfer_cutoff(ctx, z)
                        and x >= x0 and x < x1 and y >= y0 and y < y1 then
                        return true
                    end
                end
                return false
            end
            local function purge(vec, touches)
                for i = 0, #vec - 1 do
                    local monitor = vec[i]
                    if monitor.triggered == 0 and touches(monitor) then
                        monitor.triggered = 1
                        n = n + 1
                    end
                end
            end
            purge(ev.deep_vein_hollows, function(m) return path_touches(m.tiles) end)
            purge(ev.divine_treasures, function(m) return path_touches(m.tiles) end)
            purge(ev.encased_horrors, function(m) return path_touches(m.tiles) end)
            purge(ev.glowing_barriers, function(m)
                return common.above_transfer_cutoff(ctx, m.pos.z)
                    and m.pos.x >= x0 and m.pos.x < x1
                    and m.pos.y >= y0 and m.pos.y < y1
            end)
            ctx.native_contents_cleared = n
            print(('planeswalkers: %d native spire-content monitor(s) overlapping imported depths disarmed')
                :format(n))
            return true
        end,
    }
end

-- Record the fresh embark party before its wagon and terrain are removed.
-- Only own-civilization citizens/pets standing near the wagon are treated as
-- the embark party; unrelated wildlife and visitors are left alone.
-- Do not move units before terrain replacement: a whole-map snapshot has no
-- exterior holding area. The game remains paused, and the party is relocated
-- onto verified support after terrain restoration but before the job completes.
local function prepare_embark_phase(ctx)
    return {
        name = 'record fresh embark party',
        step = function(job)
            ctx.embark_units, ctx.embark_unit_ids = {}, {}
            ctx.embark_wagon_pos = nil
            local wagon
            for _, bld in ipairs(df.global.world.buildings.all) do
                if bld:getType() == df.building_type.Wagon then
                    wagon = bld
                    break
                end
            end
            local map = df.global.world.map
            local cx = wagon and wagon.centerx or (map.x_count // 2)
            local cy = wagon and wagon.centery or (map.y_count // 2)
            local cz = wagon and wagon.z or (ctx.anchor.dest_surface or 1)
            ctx.embark_party_detected = wagon ~= nil
            if wagon then ctx.embark_wagon_pos = xyz2pos(wagon.centerx, wagon.centery, wagon.z) end
            -- Do not make the wagon's presence a prerequisite for protecting
            -- the starting party. Some embark variants/mods omit or replace it.
            for _, u in ipairs(df.global.world.units.active) do
                local citizen, pet = u.civ_id == df.global.plotinfo.civ_id, false
                local okc, value = pcall(dfhack.units.isCitizen, u, true)
                if okc and value then citizen = true end
                local okp, valuep = pcall(dfhack.units.isPet, u)
                if okp and valuep then pet = true end
                local okt, tam = pcall(dfhack.units.isTame, u)
                if okt and tam then pet = true end
                local ux, uy, uz = dfhack.units.getPosition(u)
                if (citizen or pet) and ux
                    and math.abs(ux - cx) <= 64
                    and math.abs(uy - cy) <= 64
                    and math.abs(uz - cz) <= 12 then
                    ctx.embark_units[#ctx.embark_units + 1] = {
                        unit = u, x = ux, y = uy, z = uz,
                    }
                    ctx.embark_unit_ids[u.id] = true
                end
            end
            ctx.embark_party_detected = ctx.embark_party_detected or #ctx.embark_units > 0
            print(('planeswalkers: recorded %d fresh embark unit(s) for post-restore relocation')
                :format(#ctx.embark_units))
            return true
        end,
    }
end


local function relocate_embark_phase(ctx)
    return {
        name = 'relocate embark party and wagon supplies',
        init = function(job)
            job.units = ctx.embark_units or {}
            job.items = ctx.embark_supplies or {}
            job.unit_cursor, job.item_cursor = 1, 1
            job.moved_units, job.moved_items = 0, 0
            ctx.embark_units_expected = #job.units
            ctx.embark_items_expected = #job.items
            job.occupied = {}
            job.safe_cache = {}
            local map = df.global.world.map
            -- A numeric linear index avoids allocating/formating a string for
            -- every candidate tile in the Manhattan search.
            local function tile_key(x, y, z)
                return (z * map.y_count + y) * map.x_count + x
            end
            job.tile_key = tile_key
            -- Reserve every current unit position, including the destination
            -- embark party. A unit's own tile is released only while finding
            -- its replacement, so an earlier unit cannot claim a later unit's
            -- still-occupied starting tile. Counts also handle stacked units.
            for _, u in ipairs(df.global.world.units.active) do
                local k = tile_key(u.pos.x, u.pos.y, u.pos.z)
                job.occupied[k] = (job.occupied[k] or 0) + 1
            end
        end,
        total = function(job) return #job.units + #job.items end,
        pos = function(job) return job.unit_cursor - 1 + job.item_cursor - 1 end,
        step = function(job, deadline)
            local map = df.global.world.map
            local x0, y0 = ctx.anchor.off_x, ctx.anchor.off_y
            local x1 = x0 + ctx.manifest.dims.bx * 16 - 1
            local y1 = y0 + ctx.manifest.dims.by * 16 - 1
            local function key(x, y, z) return job.tile_key(x, y, z) end
            local function safe_tile(x, y, z)
                if x < 0 or y < 0 or x >= map.x_count or y >= map.y_count
                    or z < 1 or z >= map.z_count - 1 then return false end
                local k = key(x, y, z)
                local cached = job.safe_cache[k]
                if cached ~= nil then return cached end
                -- Destination embark units belong at the destination surface,
                -- not at the source fortress's surface Z. Accept any DF tile
                -- shape that the game marks walkable (floors, ramps, stairs).
                local tt = dfhack.maps.getTileType(x, y, z)
                if not tt then
                    job.safe_cache[k] = false
                    return false
                end
                local attrs = df.tiletype.attrs[tt]
                local shape, material = attrs.shape, attrs.material
                -- A tree trunk/branch/root can report a walkable shape, but it
                -- is never a valid embark relocation tile. Also avoid shrubs,
                -- mushrooms, and other plant geometry that can trap a unit.
                if material == df.tiletype_material.TREE
                    or material == df.tiletype_material.ROOT
                    or material == df.tiletype_material.PLANT
                    or material == df.tiletype_material.MUSHROOM
                    or material == df.tiletype_material.CONSTRUCTION
                    or not df.tiletype_shape.attrs[shape].walkable then
                    job.safe_cache[k] = false
                    return false
                end
                -- A walkable tile can still be an unsupported floor. Require
                -- some real tile directly below it before placing a unit.
                local below = dfhack.maps.getTileType(x, y, z - 1)
                if not below or df.tiletype.attrs[below].shape == df.tiletype_shape.EMPTY then
                    job.safe_cache[k] = false
                    return false
                end
                local bd = select(1, dfhack.maps.getTileFlags(xyz2pos(x, y, z - 1)))
                if bd and bd.flow_size > 0 then
                    job.safe_cache[k] = false
                    return false
                end
                local d = select(1, dfhack.maps.getTileFlags(xyz2pos(x, y, z)))
                if d and d.flow_size > 0 then
                    job.safe_cache[k] = false
                    return false
                end
                job.safe_cache[k] = true
                return true
            end
            local function find_free(origin)
                if not origin then return nil end
                local zlist = {origin.z}
                for dz = 1, 12 do
                    zlist[#zlist + 1] = origin.z + dz
                    zlist[#zlist + 1] = origin.z - dz
                end
                -- Search one 1x1 world-tile neighborhood (48x48 map tiles)
                -- around the original embark position. This deliberately
                -- includes the exterior ring outside the imported footprint;
                -- that is usually the only untouched ground after a transplant.
                local sx0, sy0 = math.max(0, origin.x - 24), math.max(0, origin.y - 24)
                local sx1, sy1 = math.min(map.x_count - 1, origin.x + 23),
                                  math.min(map.y_count - 1, origin.y + 23)
                for _, z in ipairs(zlist) do
                    for r = 0, 48 do
                        for dx = -r, r do
                            local dy = r - math.abs(dx)
                            for _, sy in ipairs(dy == 0 and {1} or {1, -1}) do
                                local x, y = origin.x + dx, origin.y + dy * sy
                                if x >= sx0 and x <= sx1 and y >= sy0 and y <= sy1
                                    and not job.occupied[key(x, y, z)] and safe_tile(x, y, z) then
                                    return xyz2pos(x, y, z)
                                end
                            end
                        end
                    end
                end
                return nil
            end

            while job.unit_cursor <= #job.units do
                local rec = job.units[job.unit_cursor]
                job.unit_cursor = job.unit_cursor + 1
                local u = rec.unit
                if u and df.unit.find(u.id) then
                    -- These are destination-world units. Preserve their own
                    -- embark elevation, applying only the global correction used
                    -- when the source fortress had to be shifted down at the map top.
                    local old_key = key(u.pos.x, u.pos.y, u.pos.z)
                    local old_count = job.occupied[old_key] or 0
                    if old_count <= 1 then
                        job.occupied[old_key] = nil
                    else
                        job.occupied[old_key] = old_count - 1
                    end
                    local moved = false
                    local z = rec.z
                    local origin = xyz2pos(rec.x, rec.y, z)
                    local pos = find_free(origin)
                    if not pos then
                        -- Last chance: find the actual highest non-empty tile in
                        -- this unit's own column. The embark-wide median surface
                        -- can be many Z-levels away on steep terrain, so it is
                        -- not a safe substitute for a local surface measurement.
                        local surface
                        for zz = map.z_count - 2, 1, -1 do
                            local tt = dfhack.maps.getTileType(rec.x, rec.y, zz)
                            if tt then
                                local a = df.tiletype.attrs[tt]
                                local m = a.material
                                if a.shape ~= df.tiletype_shape.EMPTY
                                    and m ~= df.tiletype_material.TREE
                                    and m ~= df.tiletype_material.ROOT
                                    and m ~= df.tiletype_material.PLANT
                                    and m ~= df.tiletype_material.MUSHROOM
                                    and m ~= df.tiletype_material.CONSTRUCTION then
                                    surface = zz + 1
                                    break
                                end
                            end
                        end
                        surface = surface or ctx.anchor.dest_surface or 1
                        pos = find_free(xyz2pos(rec.x, rec.y, surface))
                    end
                    if pos then
                        local ok, result = pcall(dfhack.units.teleport, u, pos)
                        local ax, ay, az = dfhack.units.getPosition(u)
                        if not ax then ax, ay, az = u.pos.x, u.pos.y, u.pos.z end
                        local actual = xyz2pos(ax, ay, az)
                        if ok and result ~= false and ax == pos.x and ay == pos.y and az == pos.z
                            and safe_tile(actual.x, actual.y, actual.z) then
                            local new_key = key(actual.x, actual.y, actual.z)
                            job.occupied[new_key] = (job.occupied[new_key] or 0) + 1
                            job.moved_units = job.moved_units + 1
                            moved = true
                        else
                            common.add_skip(ctx, 'embark-unit-relocation-failed', u.id)
                        end
                    else
                        common.add_skip(ctx, 'embark-unit-no-safe-tile', u.id)
                    end
                    if not moved and old_count > 0 then
                        job.occupied[old_key] = (job.occupied[old_key] or 0) + 1
                    end
                end
                if job.unit_cursor % 8 == 0 and dfhack.getTickCount() >= deadline then return false end
            end
            -- Best effort: individual failures are recorded, but never abort
            -- the fortress transplant.

            while job.item_cursor <= #job.items do
                local item = job.items[job.item_cursor]
                job.item_cursor = job.item_cursor + 1
                if item and df.item.find(item.id) then
                    local base = ctx.embark_wagon_pos
                        or xyz2pos(x0 + 8, y0 + 8, ctx.anchor.dest_surface or 1)
                    -- Spread the wagon contents across a 48x48-tile local area
                    -- rather than stacking every item on one tile. Items are
                    -- only moved onto supported ground; no mid-air placement.
                    local ox = math.max(0, math.min(map.x_count - 1,
                        base.x - 24 + ((job.item_cursor - 1) % 48)))
                    local oy = math.max(0, math.min(map.y_count - 1,
                        base.y - 24 + ((job.item_cursor - 1) // 48)))
                    local origin = xyz2pos(ox, oy, base.z)
                    local pos = find_free(origin)
                    if pos then
                        local ok, result = pcall(dfhack.items.moveToGround, item, pos)
                        if ok and result ~= false then job.moved_items = job.moved_items + 1
                        else common.add_skip(ctx, 'wagon-supply-relocation-failed', item.id) end
                    else
                        common.add_skip(ctx, 'wagon-supply-no-safe-tile', item.id)
                    end
                end
                if job.item_cursor % 16 == 0 and dfhack.getTickCount() >= deadline then return false end
            end
            ctx.embark_units_moved = job.moved_units
            ctx.embark_items_moved = job.moved_items
            ctx.embark_relocation_report = ('destination embark: relocated %d/%d unit(s) and %d/%d wagon item(s) to supported ground')
                :format(job.moved_units, #job.units, job.moved_items, #job.items)
            print('planeswalkers: ' .. ctx.embark_relocation_report)
            return true
        end,
    }
end

local function get_snapshot_manifest(name)
    if not name or not common.valid_name(name) then qerror('planeswalkers: specify a valid snapshot name') end
    local dir = common.snap_dir(name)
    local mf, err = common.read_json(dir .. '/manifest.json')
    if not mf then
        qerror(('planeswalkers: could not read snapshot "%s": %s'):format(name, tostring(err)))
    end
    if mf.name and mf.name ~= name then
        qerror(('planeswalkers: snapshot folder "%s" contains a manifest for "%s"')
            :format(name, tostring(mf.name)))
    end
    return dir, mf
end

local function do_preview(name)
    require_fort()
    local dir, mf = get_snapshot_manifest(name)
    if mf.mode == 'party' then
        qerror('planeswalkers: party snapshots do not replace terrain and do not need placement preview')
    end
    if not (mf.complete and mf.complete.terrain and mf.complete.constructions) then
        qerror('planeswalkers: snapshot is incomplete; placement cannot be previewed')
    end
    local terrain = req('terrain')
    if mf.format_version >= 4 then
        local valid, err = terrain.validate_magma_snapshot(dir, mf)
        if not valid then qerror('planeswalkers: ' .. err) end
    end
    if mf.format_version >= 5 then
        local valid, err = terrain.validate_heat_snapshot(dir, mf)
        if not valid then qerror('planeswalkers: ' .. err) end
    end
    local legends = common.read_json(dir .. '/legend.json') or {}
    local anchor, err = terrain.compute_anchor(mf.dims, dir,
        common.Legend.new(legends.tiletypes), false)
    if not anchor then qerror('planeswalkers: ' .. err) end
    local rect = {x=anchor.off_x, y=anchor.off_y,
        w=mf.dims.bx * 16, h=mf.dims.by * 16}
    local magma_top = terrain.find_magma_top_z(rect)
    local deep_top, deep_min = terrain.find_deep_top_z(rect)
    local ideal_off_z = (anchor.off_z or 0) - (anchor.surface_shift or 0)
    local source_min = mf.dims.magma_min or 1
    local source_bottom = source_min + ideal_off_z
    local required_bottom = math.max(1, deep_top >= 0 and (deep_top + 2) or 1)
    local shift_up = math.max(0, required_bottom - source_bottom)
    local final_off_z = ideal_off_z + shift_up
    local final_top = (anchor.source_top_z or mf.dims.top_z or 0) + final_off_z
    local max_z = df.global.world.map.z_count - 2
    local add_z = math.max(0, final_top - max_z)
    local safe = add_z == 0
    local separation = source_bottom + shift_up - required_bottom
    print('PLANESWALKERS PLACEMENT PREVIEW')
    print(('Snapshot: %s | origin: %s | world: %s'):format(name,
        tostring(mf.fort_display or mf.fort or 'unknown fortress'), tostring(mf.world or 'unknown world')))
    print(('Footprint: %dx%d blocks (%dx%d tiles)'):format(mf.dims.bx, mf.dims.by,
        mf.dims.bx * 16, mf.dims.by * 16))
    print(('Destination offset: block %d,%d; surface Z %d; origin surface Z %d')
        :format(anchor.off_bx, anchor.off_by, anchor.dest_surface or 0, mf.dims.surface or 0))
    print(('Vertical adjustment: %d Z-level(s); clearance above sampled underworld ceiling: %d Z-level(s)')
        :format(final_off_z, separation))
    print(('Destination global magma top: %s (not merged); highest sampled underworld ceiling: %d; lowest sampled ceiling: %d')
        :format(magma_top >= 0 and tostring(magma_top) or 'not found', deep_top, deep_min))
    print(('Highest origin terrain after adjustment: %d; destination legal maximum: %d; additional sky needed: %d')
        :format(final_top, max_z, add_z))
    print(('Destination buildings: %d; restore with --force is %s')
        :format(#df.global.world.buildings.all, #df.global.world.buildings.all > 1 and 'required' or 'not currently required'))
    if safe then
        print('PREVIEW RESULT: vertical placement fits the loaded embark. This is not a guarantee that every geological feature is compatible.')
    else
        print('PREVIEW RESULT: UNSAFE. The required vertical adjustment would clip the origin fortress; choose another destination.')
    end
    if add_z > 0 then
        print('NOTE: load with --add-z to request the additional sky levels, then save/reload and retry.')
    end
end

local function do_compare(name_a, name_b)
    local _, a = get_snapshot_manifest(name_a)
    local _, b = get_snapshot_manifest(name_b)
    local function val(m, path)
        local v = m
        for key in path:gmatch('[^.]+') do v = type(v) == 'table' and v[key] or nil end
        return v == nil and '—' or tostring(v)
    end
    local fields = {
        {'Origin world', 'world'}, {'Origin fortress', 'fort_display'},
        {'Civilization', 'civilization.name'}, {'Created', 'created'},
        {'Format', 'format_version'}, {'Blocks X', 'dims.bx'},
        {'Blocks Y', 'dims.by'}, {'Z levels', 'dims.bz'},
        {'Surface Z', 'dims.surface'}, {'Magma top Z', 'dims.magma_top'},
        {'Magma bottom Z', 'dims.magma_min'}, {'Terrain blocks', 'counts.terrain_blocks'},
        {'Magma blocks', 'counts.magma_blocks'}, {'Buildings', 'counts.buildings'},
        {'Units', 'counts.units'}, {'Items', 'counts.items'},
        {'Plants', 'counts.plants'}, {'Corpses', 'counts.corpses'},
    }
    print(('PLANESWALKERS SNAPSHOT COMPARISON: %s vs %s'):format(name_a, name_b))
    for _, field in ipairs(fields) do
        print(('%-20s | %-28s | %s'):format(field[1], val(a, field[2]), val(b, field[2])))
    end
end

local do_browser
local do_load

local function do_load_impl(name, ...)
    local flags = {}
    for _, a in ipairs({name, ...}) do flags[a] = true end
    if not name or name:match('^%-%-') then
        do_browser()
        return
    end
    require_fort()
    if not common.valid_name(name) then qerror('planeswalkers: invalid snapshot name') end
    -- accept a list index as the name
    if name:match('^%d+$') then
        local snaps = common.list_snapshots()
        local pick = snaps[tonumber(name)]
        if pick then name = pick.name end
    end
    if common.current_job() then
        qerror('planeswalkers: a save/load job is already running; cancel it or wait for it to finish')
    end
    local operation_report = common.begin_operation_report('load', name, {
        destination_world = common.u(dfhack.translation.translateName(df.global.world.world_data.name)),
        df_version = dfhack.getDFVersion(),
    })
    local dir = common.snap_dir(name)
    local mf = common.read_json(dir .. '/manifest.json')
    if not mf then
        qerror(('planeswalkers: no loadable snapshot named "%s". Expected manifest: %s/manifest.json (snapshot root: %s)')
            :format(name, dir, common.SNAP_ROOT))
    end
    common.update_operation_report(operation_report, {metadata = {
        destination_world = operation_report.metadata.destination_world,
        origin_world = mf.world, fort = mf.fort, format_version = mf.format_version,
        mode = mf.mode or 'fort', counts = mf.counts,
    }})
    if mf.name and mf.name ~= name then
        qerror(('planeswalkers: snapshot folder "%s" contains a manifest for "%s"; refusing to load mismatched data')
            :format(name, tostring(mf.name)))
    end
    if mf.format_version ~= common.FORMAT_VERSION and mf.format_version ~= 4 and mf.format_version ~= 2 then
        qerror(('planeswalkers: snapshot format v%s, this build reads v%d, v4, and v2 (older snapshots lack heat data)')
            :format(tostring(mf.format_version), common.FORMAT_VERSION))
    end
    -- A PARTY LOAD IS ITS OWN PATH, and a much shorter one: no terrain, no buildings, no
    -- anchor arithmetic. The travellers arrive in the fort you are already playing, beside a
    -- citizen chosen at random, carrying what they carried. Everything the fort path does to
    -- the map -- clearing buildings, repainting tiles, re-registering features -- would be
    -- destruction nobody asked for here.
    if mf.mode == 'party' then
        if not (mf.complete and mf.complete.units) then
            qerror('planeswalkers: party snapshot is incomplete (the save was aborted); refusing')
        end
        local ctx = {name = name, dir = dir, skips = {}, party = true,
                     operation_report = operation_report,
                     src_year = mf.src_year, manifest = mf,
                     anchor = {off_x = 0, off_y = 0, off_z = 0}}
        local legends = common.read_json(dir .. '/legend.json') or {}
        ctx.legend_tt = common.Legend.new(legends.tiletypes)
        ctx.legend_mat = common.Legend.new(legends.mats)
        local phases = {}
        for _, p in ipairs(req('units').load_phases(ctx)) do table.insert(phases, p) end
        table.insert(phases, req('extras').owners_phase(ctx))
        for _, p in ipairs(req('items').load_phases(ctx)) do table.insert(phases, p) end
        notify(('%d traveller(s) arriving from "%s" of world "%s"')
               :format((mf.counts and mf.counts.units) or 0, name, mf.world or '?'))
        common.start_job('load ' .. name, phases, ctx, function(job)
            common.print_skips(ctx)
            local who = {}
            for _, u in pairs(ctx.unit_map or {}) do
                who[#who + 1] = dfhack.units.getReadableName(u)
                if #who >= 6 then break end
            end
            ctx.report_summary = ('PARTY LOAD %s\nSnapshot: %s\nTravellers restored: %d\nItems restored: %d')
                :format('completed', name, ctx.units_restored or ((mf.counts and mf.counts.units) or 0),
                        ctx.items_restored or 0)
            ctx.report_advanced = 'Origin world: ' .. tostring(mf.world or '?')
                .. '\nDestination world: ' .. tostring(operation_report.metadata.destination_world or '?')
            notify(('%d traveller(s) have arrived%s'):format(
                       #who > 0 and #who or ((mf.counts and mf.counts.units) or 0),
                       #who > 0 and (': ' .. table.concat(who, ', ')) or ''),
                   COLOR_LIGHTGREEN, true)
        end)
        return
    end

    if not (mf.complete and mf.complete.terrain and mf.complete.constructions) then
        qerror('planeswalkers: snapshot is incomplete (the save was aborted); refusing')
    end
    if mf.format_version >= 4 and not (mf.complete.magma
        and dfhack.filesystem.exists(dir .. '/magma.bin')) then
        qerror('planeswalkers: format v4+ snapshot is missing its completed magma.bin; refusing an incomplete restore')
    end
    if mf.world == common.u(dfhack.translation.translateName(df.global.world.world_data.name))
        and not flags['--force'] then
        qerror('planeswalkers: this snapshot came from THIS world; --force to restore anyway')
    end
    if #df.global.world.buildings.all > 1 and not flags['--force'] then
        qerror(('planeswalkers: this fort already has %d buildings; load onto a FRESH ' ..
                'embark, or --force to overwrite anyway'):format(#df.global.world.buildings.all))
    end

    -- Fortress transplantation always replaces the complete source footprint.
    local preserve_depths = false
    local legends = common.read_json(dir .. '/legend.json') or {}
    local legend_tt = common.Legend.new(legends.tiletypes)
    local terrain = req('terrain')
    if mf.format_version >= 4 then
        local valid, magma_err = terrain.validate_magma_snapshot(dir, mf)
        if not valid then qerror('planeswalkers: ' .. magma_err .. '; refusing to modify the destination') end
    end
    if mf.format_version >= 5 then
        local valid, heat_err = terrain.validate_heat_snapshot(dir, mf)
        if not valid then qerror('planeswalkers: ' .. heat_err .. '; refusing to modify the destination') end
    end
    local anchor, err = terrain.compute_anchor(mf.dims, dir, legend_tt, preserve_depths)
    if not anchor then qerror('planeswalkers: ' .. err) end

    local source_magma_top = mf.dims.magma_top
    if mf.format_version >= 4 and (type(source_magma_top) ~= 'number' or source_magma_top < 0) then
        qerror('planeswalkers: snapshot has no valid source magma-sea boundary; save it again with this version')
    end
    source_magma_top = source_magma_top or -1
    local dest_rect = {
        x = anchor.off_x, y = anchor.off_y,
        w = mf.dims.bx * 16, h = mf.dims.by * 16,
    }
    -- Destination magma and underworld remain separate native world systems.
    -- Imported source magma is static, so only the destination underworld
    -- ceiling constrains the source's lower Z bound.
    local dest_magma_top = terrain.find_magma_top_z(dest_rect) -- diagnostic only
    local dest_deep_top, dest_deep_min = terrain.find_deep_top_z()
    local footprint_deep_top, footprint_deep_min = terrain.find_deep_top_z(dest_rect)
    local ideal_off_z = (anchor.off_z or 0) - (anchor.surface_shift or 0)
    local source_magma_min = tonumber(mf.dims.magma_min) or 1
    local required_source_bottom = math.max(1,
        footprint_deep_top >= 0 and (footprint_deep_top + 2) or 1)
    local required_off_z = math.max(ideal_off_z, required_source_bottom - source_magma_min)
    local source_top_z = anchor.source_top_z or mf.dims.top_z or 1
    local required_top_z = source_top_z + required_off_z
    local max_top_z = df.global.world.map.z_count - 2

    if not preserve_depths then
        if required_top_z > max_top_z then
            local add_needed = required_top_z - max_top_z
            if not flags['--add-z'] then
                qerror(('planeswalkers: this destination needs %d additional sky Z-level(s) to fit the origin fortress. Retry with `fort/planeswalkers load %s --add-z`, or choose a destination with more vertical room.')
                    :format(add_needed + 2, name))
            end
            local old_z_count = df.global.world.map.z_count
            local request_levels = add_needed + 2
            local ok, run_err = pcall(dfhack.run_command, 'infinite-sky', tostring(request_levels))
            local new_z_count = df.global.world.map.z_count
            if not ok or new_z_count < old_z_count + add_needed then
                qerror(('planeswalkers: could not add the required sky levels with infinite-sky (%s). Enable the DFHack infinite-sky plugin and retry; destination terrain has not been modified by Planeswalkers.')
                    :format(tostring(run_err or 'map height did not increase enough')))
            end
            qerror(('planeswalkers: added %d sky Z-level(s). Save and reload the destination world before retrying `fort/planeswalkers load %s`; no fortress terrain has been transplanted yet.')
                :format(new_z_count - old_z_count, name))
        end
        anchor.off_z = required_off_z
        anchor.surface_shift = required_off_z - ideal_off_z
        anchor.source_top_z = required_top_z
        if anchor.surface_shift > 0 then
            notify(('adjusting the complete origin fort upward by %d Z-level(s) to clear the destination underworld; internal Z spacing is preserved')
                :format(anchor.surface_shift), COLOR_YELLOW)
        end
    end
    if anchor.surface_shift and anchor.surface_shift < 0 then
        dfhack.printerr(('planeswalkers: exact Z alignment would exceed the destination map ceiling; shifted the fortress down %d level(s) to preserve its upper levels')
            :format(-anchor.surface_shift))
    end
    local preserve_depths_cutoff = -1
    if preserve_depths then
        if dest_deep_top < 0 then
            qerror('planeswalkers: --preserve-depths could not find the destination semi-molten-rock ceiling; refusing an unsafe partial restore')
        end
        preserve_depths_cutoff = math.min(df.global.world.map.z_count - 2,
                                          math.max(dest_deep_top + 20, 40))
        if preserve_depths_cutoff >= df.global.world.map.z_count - 3 then
            qerror(('planeswalkers: --preserve-depths cutoff (%d) leaves too little vertical map space to restore the fort safely')
                :format(preserve_depths_cutoff))
        end
    end

    -- Content objects below the bottom of the source magma feature are not
    -- portable. Terrain itself is restored at every Z-level; magma blocks are
    -- replaced independently from magma.bin.
    local transfer_min_z = math.max(1, (mf.dims.magma_min or 1) + anchor.off_z)
    if preserve_depths then
        transfer_min_z = math.max(transfer_min_z, preserve_depths_cutoff + 1)
    end
    if transfer_min_z >= df.global.world.map.z_count - 2 then
        qerror(('planeswalkers: the origin magma lower boundary leaves no room for portable non-magma fortress contents above z %d in this destination embark')
            :format(transfer_min_z - 1))
    end

    local ctx = {
        name = name,
        dir = dir,
        manifest = mf,
        source_civ_id = mf.civilization and mf.civilization.id or nil,
        source_civ_name = mf.civilization and mf.civilization.name or 'Unknown civilization',
        anchor = anchor,
        -- bisect switches: --no-spires paints carried spires as plain veins and
        -- skips the tube-feature work; --no-contents leaves this world's spire
        -- monitors alone and carries none of the source's
        preserve_depths = preserve_depths,
        preserve_depths_cutoff = preserve_depths_cutoff,
        source_magma_top = source_magma_top,
        source_magma_min = mf.dims.magma_min,
        dest_magma_top = dest_magma_top,
        transfer_min_z = transfer_min_z,
        dest_deep_top = dest_deep_top,
        dest_deep_min = dest_deep_min,
        dest_deep_top_global = dest_deep_top,
        dest_footprint_deep_top = footprint_deep_top,
        -- Source spires and their world-local event monitors are intentionally
        -- not transplanted in this mode; the destination's protected deep
        -- spires remain its own.
        no_spires = flags['--no-spires'] or preserve_depths,
        no_contents = flags['--no-contents'] or preserve_depths,
        operation_report = operation_report,
        legend_tt = legend_tt,
        legend_mat = common.Legend.new(legends.mats),
        legend_plant = common.Legend.new(legends.plants),
        skips = {},
        close_all = function(self)
            if self.tiles_f then pcall(self.tiles_f.close, self.tiles_f); self.tiles_f = nil end
            if self.grass_f then pcall(self.grass_f.close, self.grass_f); self.grass_f = nil end
            if self.magma_f then pcall(self.magma_f.close, self.magma_f); self.magma_f = nil end
            if self.heat_f then pcall(self.heat_f.close, self.heat_f); self.heat_f = nil end
            if self.plants_f then pcall(self.plants_f.close, self.plants_f); self.plants_f = nil end
        end,
    }

    -- the anchor is what a later save needs to keep this fort's own footprint
    local marker_anchor = {
        off_bx = anchor.off_bx, off_by = anchor.off_by, off_z = anchor.off_z,
        bx = mf.dims.bx, by = mf.dims.by, full = anchor.full or false,
    }
    dfhack.persistent.saveSiteData(GLOBAL_KEY,
        {state = 'loading', from = name, world = mf.world, when = os.date('%Y-%m-%d %H:%M:%S'),
         anchor = marker_anchor, current_phase = 'preparing restore', last_completed_phase = nil})
    ctx.on_phase_complete = function(self, phase_name)
        local marker = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        marker.state = 'loading'
        marker.from = name
        marker.world = mf.world
        marker.anchor = marker_anchor
        marker.last_completed_phase = phase_name
        marker.current_phase = nil
        pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, marker)
    end
    ctx.on_phase_start = function(self, phase_name)
        local marker = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        marker.state = 'loading'
        marker.from = name
        marker.world = mf.world
        marker.anchor = marker_anchor
        marker.current_phase = phase_name
        pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, marker)
    end
    ctx.on_abort = function(self, reason)
        local marker = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        marker.state = 'failed'
        marker.from = name
        marker.world = mf.world
        marker.anchor = marker_anchor
        marker.failed_when = os.date('%Y-%m-%d %H:%M:%S')
        marker.failed_phase = self.last_failed_phase or marker.current_phase
        marker.last_completed_phase = self.last_completed_phase or marker.last_completed_phase
        marker.error = tostring(reason):sub(1, 500)
        pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, marker)
        notify(('restore of "%s" stopped after %s; destination may be partially modified. Failure: %s')
            :format(name, marker.last_completed_phase or 'no completed phase', marker.error),
            COLOR_LIGHTRED, true)
    end

    notify(('restoring "%s" (%dx%d blocks) at block %d,%d with source Z alignment%s ' ..
            '(portable non-magma contents start at z %d; origin magma is restored as a static basin, destination magma remains native outside the footprint); ' ..
            'the game stays paused until it finishes')
           :format(name, mf.dims.bx, mf.dims.by, anchor.off_bx, anchor.off_by,
                   anchor.off_z == 0 and ' (unchanged)' or
                       (anchor.off_z > 0 and (' (shifted up ' .. anchor.off_z .. ')')
                           or (' (shifted down ' .. -anchor.off_z .. ')')),
                   transfer_min_z))

    local phases = terrain.load_phases(ctx)
    local cleanup = table.remove(phases)  -- map cleanup runs last of all
    -- The embark's own buildings (the wagon!) go first, before terrain repaint.
    -- The imported footprint is cleared completely before the source fortress is restored.
    if preserve_depths then
        table.insert(phases, 1, preserve_building_clear_phase(ctx))
        table.insert(phases, 1, preserve_spire_clear_phase(ctx))
    else
        table.insert(phases, 1, req('buildings').clear_phase(ctx))
    end
    -- Disarm destination monitors and recreate source monitors.
    if not ctx.no_contents then
        table.insert(phases, 1, req('spires').clear_phase(ctx))
        table.insert(phases, req('spires').restore_phase(ctx))
    end
    -- Capture the fresh embark party before the wagon/terrain are removed.
    -- Relocation itself is delayed until after the incoming buildings exist.
    table.insert(phases, 1, prepare_embark_phase(ctx))
    if ctx.no_spires or ctx.no_contents then
        notify(('bisect flags: %s%s'):format(ctx.no_spires and '--no-spires ' or '',
                                             ctx.no_contents and '--no-contents' or ''))
    end
    if dfhack.filesystem.exists(dir .. '/plants.json') then
        local plant_phases = req('plants').load_phases(ctx)
        if preserve_depths then preserve_depth_filter(plant_phases, 'data', ctx, 'plants') end
        for _, p in ipairs(plant_phases) do table.insert(phases, p) end
    end
    if dfhack.filesystem.exists(dir .. '/buildings.json') then
        local building_phases = req('buildings').load_phases(ctx)
        if preserve_depths then preserve_depth_filter(building_phases, 'blds', ctx, 'buildings') end
        for _, p in ipairs(building_phases) do table.insert(phases, p) end
        local order_phases = preserve_depths and preserve_orders_phases(ctx)
            or req('orders').load_phases(ctx)
        for _, p in ipairs(order_phases) do table.insert(phases, p) end
    end
    if dfhack.filesystem.exists(dir .. '/units.json') then
        -- units before items so unit-held items can be re-attached
        local unit_phases = req('units').load_phases(ctx)
        if preserve_depths then preserve_depth_filter(unit_phases, 'units', ctx, 'units') end
        for _, p in ipairs(unit_phases) do table.insert(phases, p) end
        -- needs both the unit and the building maps. Civilian positions are
        -- deliberately NOT reassigned (the destination's own appointments
        -- stand); the military ones come with their squads.
        table.insert(phases, req('extras').owners_phase(ctx))
        table.insert(phases, req('extras').workdetails_phase(ctx))
        for _, p in ipairs(req('squads').load_phases(ctx)) do table.insert(phases, p) end
        local burrow_phases = req('burrows').load_phases(ctx)
        if preserve_depths then preserve_depth_filter(burrow_phases, 'data', ctx, 'burrows', true) end
        for _, p in ipairs(burrow_phases) do table.insert(phases, p) end
    end
    if dfhack.filesystem.exists(dir .. '/items.json') then
        local item_phases = req('items').load_phases(ctx)
        if preserve_depths then preserve_depth_filter(item_phases, 'items', ctx, 'items') end
        for _, p in ipairs(item_phases) do table.insert(phases, p) end
    end
    table.insert(phases, terrain.integrity_phase(ctx))
    table.insert(phases, cleanup)
    -- This MUST be the final map-mutating phase. Terrain cleanup and all
    -- imported unit/item creation can otherwise invalidate a destination tile
    -- selected for the original embark party.
    table.insert(phases, relocate_embark_phase(ctx))
    ctx.job_started = dfhack.getTickCount()
    common.start_job('load ' .. name, phases, ctx, function(job)
        common.print_skips(ctx)
        local held = held_count()
        print(('planeswalkers: units hold %d item(s) at the end of the load (%d were attached)')
            :format(held, ctx.held_attached or 0))
        if ctx.components_reminted then
            print(('planeswalkers: %d building(s) needed their components put in a second time')
                :format(ctx.components_reminted))
        end
        local elapsed = ctx.job_started and (dfhack.getTickCount() - ctx.job_started) or 0
        ctx.held_at_end = held
        ctx.phase_times = (job and job.phase_times) or {}
        local report_summary, report_advanced
        local report_ok, report_err = pcall(function()
            report_summary, report_advanced = build_restore_report(ctx, name, mf.world, elapsed)
        end)
        if not report_ok then
            report_summary = ('FORTRESS RESTORE SUMMARY\nFortress: %s\nRestore completed, but report generation failed: %s')
                :format(name, tostring(report_err))
            report_advanced = report_summary
            dfhack.printerr('planeswalkers: report generation failed: ' .. tostring(report_err))
        end
        ctx.report_summary = report_summary
        ctx.report_advanced = report_advanced
        local report_legacy = report_summary .. '\n\n' .. report_advanced
        -- Save the complete marker exactly once. Repeated saveSiteData calls can
        -- replace the previous value instead of reliably merging nested fields.
        dfhack.persistent.saveSiteData(GLOBAL_KEY,
            {state = 'done', from = name, world = mf.world, when = os.date('%Y-%m-%d %H:%M:%S'),
             anchor = marker_anchor, report = report_legacy,
             report_summary = report_summary, report_advanced = report_advanced,
             items = {attached = ctx.held_attached or 0, held_at_end = held,
                      grounded = ctx.skips['unit-held-item-grounded'] and ctx.skips['unit-held-item-grounded'].n or 0}})
        local cx = anchor.off_x + mf.dims.bx * 8
        local cy = anchor.off_y + mf.dims.by * 8
        -- F1 returns to the current embark's surface view. Reposition the
        -- initial camera to the nearest real surface at the embark center,
        -- ignoring tree canopies, roots, shrubs, and constructions.
        local view_z
        for z = df.global.world.map.z_count - 2, 1, -1 do
            local tt = dfhack.maps.getTileType(cx, cy, z)
            if tt then
                local a = df.tiletype.attrs[tt]
                local m = a.material
                if a.shape ~= df.tiletype_shape.EMPTY
                    and m ~= df.tiletype_material.TREE
                    and m ~= df.tiletype_material.ROOT
                    and m ~= df.tiletype_material.PLANT
                    and m ~= df.tiletype_material.MUSHROOM
                    and m ~= df.tiletype_material.CONSTRUCTION then
                    view_z = z
                    break
                end
            end
        end
        view_z = view_z or anchor.dest_surface or 1
        df.global.window_x, df.global.window_y, df.global.window_z = cx, cy, view_z
        dfhack.gui.revealInDwarfmodeMap(xyz2pos(cx, cy, view_z), true)
        notify(('fort "%s" restored from world "%s". SAVE NOW, then reload the fort.')
               :format(name, mf.world or '?'), COLOR_LIGHTGREEN)
        show_restore_report(report_summary, report_advanced)
    end)
end

do_load = function(...)
    local previous = common.current_operation_report()
    local result = table.pack(pcall(do_load_impl, ...))
    if not result[1] then
        local current = common.current_operation_report()
        if current and current ~= previous and current.state == 'running' then
            common.finish_operation_report(nil, 'failed', tostring(result[2]), 'preflight', nil)
        end
        qerror(result[2])
    end
    return table.unpack(result, 2, result.n)
end

-- re-run the spire pass on a fort restored here: disarm whatever is left of
-- this world's own adamantine tubes and register the carried spires as live
-- tube features again (forts restored before that pass existed, above all)
local function do_spires()
    require_fort()
    local marker = dfhack.persistent.getSiteData(GLOBAL_KEY)
    if not marker or marker.state ~= 'done' or not marker.from then
        qerror('planeswalkers: this fort was not restored from a snapshot')
    end
    local dir = common.snap_dir(marker.from)
    local mf = common.read_json(dir .. '/manifest.json')
    if not mf then
        qerror(('planeswalkers: snapshot "%s" this fort came from is gone'):format(marker.from))
    end
    local legends = common.read_json(dir .. '/legend.json') or {}
    local terrain = req('terrain')
    local legend_tt = common.Legend.new(legends.tiletypes)
    local anchor = marker.anchor
    if not anchor or not anchor.bx then
        -- restored before the anchor was recorded: recompute the same
        -- Z-preserving anchor used by the loader
        local a, err = terrain.compute_anchor(mf.dims, dir, legend_tt)
        if not a then qerror('planeswalkers: ' .. err) end
        anchor = a
        if not a.full then
            dfhack.printerr('planeswalkers: no anchor recorded for this fort; using a ' ..
                'recomputed Z-preserving anchor')
        end
    end
    anchor.off_x = (anchor.off_bx or 0) * 16
    anchor.off_y = (anchor.off_by or 0) * 16
    local ctx = {
        name = marker.from, dir = dir, manifest = mf, anchor = anchor,
        legend_tt = legend_tt,
        legend_mat = common.Legend.new(legends.mats),
        skips = {},
        close_all = function(self)
            if self.tiles_f then self.tiles_f:close(); self.tiles_f = nil end
            if self.magma_f then self.magma_f:close(); self.magma_f = nil end
        end,
    }
    notify(('re-arming the spires of "%s" on this fort; the game stays paused until ' ..
            'it finishes'):format(marker.from))
    local phases = terrain.spire_repair_phases(ctx)
    table.insert(phases, 1, req('spires').clear_phase(ctx))
    table.insert(phases, req('spires').restore_phase(ctx))
    common.start_job('spires ' .. marker.from, phases, ctx, function()
        common.print_skips(ctx)
        notify(ctx.spire_report or 'no spires found in the snapshot', COLOR_LIGHTGREEN, true)
        if ctx.spire_contents_report then notify(ctx.spire_contents_report) end
    end)
end

-- fix up a restored fort in place: furniture missing its component item,
-- and the spire pass (see do_spires)
do_browser = function()
    req('gui').show_browser(function(name) do_load(name) end)
end

local function do_repair()
    require_fort()
    local marker = dfhack.persistent.getSiteData(GLOBAL_KEY)
    if not marker or marker.state ~= 'done' or not marker.from then
        qerror('repair: this fort was not restored from a planeswalkers snapshot')
    end
    local dir = common.snap_dir(marker.from)
    local mf = common.read_json(dir .. '/manifest.json')
    if not mf then qerror(('repair: source snapshot "%s" is missing'):format(marker.from)) end
    if not dfhack.filesystem.exists(dir .. '/magma.bin') then
        qerror('repair: this snapshot has no source magma data; save it again with format v5')
    end
    local terrain = req('terrain')
    local valid, magma_err = terrain.validate_magma_snapshot(dir, mf)
    if not valid then qerror('repair: ' .. magma_err) end
    local anchor = marker.anchor
    if not anchor or not anchor.bx then qerror('repair: restored fortress anchor is missing') end
    anchor.off_x, anchor.off_y = (anchor.off_bx or 0) * 16, (anchor.off_by or 0) * 16
    local dest_deep_top, dest_deep_min = terrain.find_deep_top_z()
    local repair_rect = {x = anchor.off_x, y = anchor.off_y,
        w = mf.dims.bx * 16, h = mf.dims.by * 16}
    local dest_footprint_deep_top = terrain.find_deep_top_z(repair_rect)
    local ctx = {
        name = marker.from, dir = dir, manifest = mf, anchor = anchor,
        skips = {}, no_spires = true, no_contents = true,
        dest_deep_top = dest_deep_top,
        dest_deep_min = dest_deep_min,
        dest_deep_top_global = dest_deep_top,
        dest_footprint_deep_top = dest_footprint_deep_top,
        source_magma_top = mf.dims and mf.dims.magma_top or -1,
        source_magma_min = mf.dims and mf.dims.magma_min,
        transfer_min_z = math.max(1, ((mf.dims and mf.dims.magma_min) or 1)
            + (anchor.off_z or 0)),
        close_all = function(self)
            if self.magma_f then self.magma_f:close(); self.magma_f = nil end
        end,
    }
    notify(('restoring static origin magma for "%s"; the game stays paused until it finishes')
        :format(marker.from))
    common.start_job('magma repair ' .. marker.from,
        {terrain.magma_refill_phase(ctx), terrain.magma_sea_phase(ctx, false)},
        ctx, function()
            if ctx.magma_refill_report then notify(ctx.magma_refill_report, COLOR_LIGHTCYAN) end
            notify(ctx.magma_report or 'magma refill complete', COLOR_LIGHTGREEN, true)
        end)
end

local function do_delete(name, confirm)
    if not name or not common.valid_name(name) then qerror('delete: need a snapshot name') end
    if confirm ~= '--yes' then qerror('delete: add --yes to really delete ' .. name) end
    local paths = {common.snap_dir(name), common.snap_dir(name) .. '.pending',
                   common.snap_dir(name) .. '.replaced', common.snap_dir(name) .. '.publish_failed'}
    local removed = 0
    for _, path in ipairs(paths) do
        if dfhack.filesystem.exists(path) then
            local ok, err = common.remove_tree(path)
            if not ok then qerror(('planeswalkers: failed to delete %s: %s'):format(path, tostring(err))) end
            if dfhack.filesystem.exists(path) then
                qerror('planeswalkers: deletion was not verified for ' .. path)
            end
            removed = removed + 1
        end
    end
    if removed == 0 then qerror('no snapshot data named ' .. name) end
    print(('planeswalkers: deleted %s (%d directory/file entries, including partial data)')
        :format(name, removed))
end

local function do_delete_list(...)
    local args = {...}
    local preserve = {}
    if args[1] == '--preserve' then
        if #args < 2 then qerror('delete-list --preserve: specify at least one snapshot name') end
        for i = 2, #args do
            if not common.valid_name(args[i]) then qerror('delete-list: invalid preserved name: ' .. tostring(args[i])) end
            preserve[args[i]] = true
        end
    elseif #args > 0 then
        qerror('delete-list accepts either no arguments or --preserve <name> [name ...]')
    end
    local removed, kept = 0, 0
    for _, entry in ipairs(common.list_snapshot_dirs()) do
        if preserve[entry.base] then
            kept = kept + 1
        else
            local ok, err = common.remove_tree(entry.path)
            if not ok then
                qerror(('planeswalkers: delete-list stopped; could not remove %s: %s')
                    :format(entry.path, tostring(err)))
            end
            if dfhack.filesystem.exists(entry.path) then
                qerror('planeswalkers: delete-list could not verify removal of ' .. entry.path)
            end
            removed = removed + 1
        end
    end
    print(('planeswalkers: delete-list removed %d snapshot directory/directories; preserved %d')
        :format(removed, kept))
end

local function sorted_keys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function format_operation_report(report)
    local summary, advanced = {}, {}
    local meta = report.metadata or {}
    local status = tostring(report.state or 'unknown'):upper()
    summary[#summary + 1] = 'PLANESWALKERS OPERATION REPORT'
    summary[#summary + 1] = ('Operation: %s'):format(tostring(report.kind or '?'):upper())
    summary[#summary + 1] = 'Snapshot: ' .. tostring(report.name or '?')
    summary[#summary + 1] = 'Result: ' .. status
    summary[#summary + 1] = 'Started: ' .. tostring(report.started_at or '?')
    summary[#summary + 1] = 'Finished/updated: ' .. tostring(report.finished_at or report.updated_at or '?')
    if report.elapsed_seconds then summary[#summary + 1] = ('Elapsed: %.1f seconds'):format(report.elapsed_seconds) end
    if meta.origin_world or meta.world then summary[#summary + 1] = 'Origin world: ' .. tostring(meta.origin_world or meta.world) end
    if meta.destination_world then summary[#summary + 1] = 'Destination world: ' .. tostring(meta.destination_world) end
    if meta.fort or meta.fortress then summary[#summary + 1] = 'Fortress: ' .. tostring(meta.fort or meta.fortress) end
    if report.last_completed_phase then summary[#summary + 1] = 'Last completed phase: ' .. tostring(report.last_completed_phase) end
    if report.current_phase then summary[#summary + 1] = 'Last active phase: ' .. tostring(report.current_phase) end
    if report.failed_phase then summary[#summary + 1] = 'Failed phase: ' .. tostring(report.failed_phase) end
    if report.ended_phase then summary[#summary + 1] = 'Ended during phase: ' .. tostring(report.ended_phase) end
    if report.failure then summary[#summary + 1] = 'Failure: ' .. tostring(report.failure) end
    if report.summary then
        summary[#summary + 1] = ''
        summary[#summary + 1] = tostring(report.summary)
    elseif report.counts then
        summary[#summary + 1] = ''
        summary[#summary + 1] = 'Snapshot counts:'
        for _, key in ipairs(sorted_keys(report.counts)) do
            summary[#summary + 1] = ('  %s: %s'):format(tostring(key), tostring(report.counts[key]))
        end
    end
    local audit = report.item_audit
    if audit then
        summary[#summary + 1] = ''
        summary[#summary + 1] = ('Item material audit: %d checked, %d unresolved')
            :format(tonumber(audit.final_checked) or 0, tonumber(audit.final_unresolved) or 0)
        local final_stage = audit.stages and audit.stages.after_registry_update_before_final_check
        if final_stage then
            summary[#summary + 1] = ('Pre-final state: %d/%d mismatched'):format(
                tonumber(final_stage.mismatched) or 0, tonumber(final_stage.checked) or 0)
        end
    end
    summary[#summary + 1] = ''
    summary[#summary + 1] = 'Full details: fort/planeswalkers report (Advanced tab)'

    advanced[#advanced + 1] = 'OPERATION DETAILS'
    advanced[#advanced + 1] = ('Report file: %s'):format(common.LAST_OPERATION_REPORT)
    advanced[#advanced + 1] = ('DFHack/DF version: %s'):format(tostring(meta.df_version or '?'))
    advanced[#advanced + 1] = ('Snapshot format: %s'):format(tostring(meta.format_version or '?'))
    advanced[#advanced + 1] = ('Phase count: %s'):format(tostring(report.phase_count or '?'))
    advanced[#advanced + 1] = ('Last completed: %s'):format(tostring(report.last_completed_phase or 'none'))
    if report.current_phase then advanced[#advanced + 1] = 'Current/last active: ' .. tostring(report.current_phase) end
    if report.failed_phase then advanced[#advanced + 1] = 'Failed phase: ' .. tostring(report.failed_phase) end
    if report.ended_phase then advanced[#advanced + 1] = 'Ended during phase: ' .. tostring(report.ended_phase) end
    if report.failure then advanced[#advanced + 1] = 'Failure: ' .. tostring(report.failure) end

    advanced[#advanced + 1] = ''
    advanced[#advanced + 1] = 'PHASE TIMINGS'
    local timings = report.phase_times or {}
    if #timings == 0 then
        advanced[#advanced + 1] = 'No completed phase timings recorded.'
    else
        for _, phase in ipairs(timings) do
            advanced[#advanced + 1] = ('%s: %.2fs'):format(tostring(phase.name or '?'),
                (tonumber(phase.ms) or 0) / 1000)
        end
    end

    local skips = report.skips or {}
    advanced[#advanced + 1] = ''
    advanced[#advanced + 1] = 'SKIPPED / DEGRADED RECORDS'
    if not next(skips) then
        advanced[#advanced + 1] = 'None recorded.'
    else
        for _, category in ipairs(sorted_keys(skips)) do
            local entry = skips[category]
            advanced[#advanced + 1] = ('%s: %d'):format(tostring(category), tonumber(entry.n) or 0)
            for _, example in ipairs(entry.examples or {}) do
                advanced[#advanced + 1] = '  Example: ' .. tostring(example)
            end
        end
    end

    if audit then
        advanced[#advanced + 1] = ''
        advanced[#advanced + 1] = 'ITEM MATERIAL AUDIT BY STAGE'
        if audit.capture_errors and audit.capture_errors > 0 then
            advanced[#advanced + 1] = ('Diagnostic capture errors: %d (%s)')
                :format(audit.capture_errors, tostring(audit.capture_error or '?'))
        end
        local stage_names = {'after_creation', 'after_placement_before_repin',
            'after_placement_repin', 'after_registry_update_before_final_check', 'after_final_check'}
        for _, stage_name in ipairs(stage_names) do
            local stage = audit.stages and audit.stages[stage_name]
            if stage then
                advanced[#advanced + 1] = ('%s: %d checked, %d mismatched')
                    :format(stage_name, tonumber(stage.checked) or 0, tonumber(stage.mismatched) or 0)
                for _, type_name in ipairs(sorted_keys(stage.by_type)) do
                    local group = stage.by_type[type_name]
                    if (tonumber(group.mismatched) or 0) > 0 then
                        advanced[#advanced + 1] = ('  %s: %d/%d mismatched'):format(
                            tostring(type_name), tonumber(group.mismatched) or 0, tonumber(group.checked) or 0)
                    end
                end
                for _, reason in ipairs(sorted_keys(stage.by_reason)) do
                    local bucket = stage.by_reason[reason]
                    advanced[#advanced + 1] = ('  Reason %s: %d'):format(tostring(reason), tonumber(bucket.n) or 0)
                end
                for _, info_name in ipairs(sorted_keys(stage.info)) do
                    advanced[#advanced + 1] = ('  Info %s: %d'):format(tostring(info_name), tonumber(stage.info[info_name]) or 0)
                end
            end
        end
        advanced[#advanced + 1] = ''
        advanced[#advanced + 1] = 'ITEM MATERIAL AUDIT EXAMPLES'
        local printed = 0
        for _, stage_name in ipairs(stage_names) do
            local stage = audit.stages and audit.stages[stage_name]
            local stage_printed = 0
            for _, sample in ipairs(stage and stage.examples or {}) do
                if printed >= 40 or stage_printed >= 10 then break end
                printed = printed + 1
                stage_printed = stage_printed + 1
                local exp, act = sample.expected or {}, sample.actual or {}
                advanced[#advanced + 1] = ('%d. item %s (%s), snapshot id %s, stage %s')
                    :format(printed, tostring(sample.id), tostring(sample.item_type),
                            tostring(sample.source_record_id), tostring(sample.stage))
                if sample.description then advanced[#advanced + 1] = '  Description: ' .. tostring(sample.description) end
                advanced[#advanced + 1] = ('  Snapshot item: type=%s subtype=%s'):format(
                    tostring(exp.snapshot_type), tostring(exp.snapshot_subtype))
                advanced[#advanced + 1] = '  Origin material token: ' .. tostring(exp.source_material or '?')
                advanced[#advanced + 1] = '  Resolved destination material: ' .. tostring(exp.token or '?')
                advanced[#advanced + 1] = ('  Expected: %s [%s:%s], caste-material=%s, race/caste=%s/%s')
                    :format(tostring(exp.token or exp.source_material or '?'), tostring(exp.type),
                        tostring(exp.index), tostring(exp.caste_material), tostring(exp.race), tostring(exp.caste))
                advanced[#advanced + 1] = ('  Actual fields: available=%s [%s:%s]; decoded=%s [%s:%s]')
                    :format(tostring(act.fields_available), tostring(act.mat_type), tostring(act.mat_index),
                        tostring(act.decoded_token), tostring(act.decoded_type), tostring(act.decoded_index))
                advanced[#advanced + 1] = ('  Actual race/caste=%s/%s; position=%s,%s,%s; stack=%s')
                    :format(tostring(act.race), tostring(act.caste), tostring(act.x), tostring(act.y),
                        tostring(act.z), tostring(act.stack))
                if act.fields_error then advanced[#advanced + 1] = '  Material field read error: ' .. tostring(act.fields_error) end
                if act.decode_error then advanced[#advanced + 1] = '  Material decode error: ' .. tostring(act.decode_error) end
                advanced[#advanced + 1] = '  Reason(s): ' .. table.concat(sample.reasons or {}, ', ')
            end
            if printed >= 40 then break end
        end
        if printed == 0 then advanced[#advanced + 1] = 'No material mismatches were captured at the sampled stages.' end
    end
    if report.advanced and report.advanced ~= '' then
        advanced[#advanced + 1] = ''
        advanced[#advanced + 1] = 'RESTORE SUMMARY DETAILS'
        for line in (tostring(report.advanced) .. '\n'):gmatch('(.-)\n') do
            advanced[#advanced + 1] = line
        end
    end
    return table.concat(summary, '\n'), table.concat(advanced, '\n')
end

local function do_compact_report()
    local ok, err = common.compact_last_operation_report()
    if not ok then qerror('planeswalkers: could not compact operation report: ' .. tostring(err)) end
    print('planeswalkers: last-operation.json compacted; item audit totals and concise examples were retained')
end

local function do_report()
    local report, read_err = common.read_last_operation_report()
    if report then
        local summary, advanced = format_operation_report(report)
        show_restore_report(summary, advanced)
        return
    end
    if dfhack.filesystem.exists(common.LAST_OPERATION_REPORT) then
        qerror('planeswalkers: the last-operation report exists but could not be read: ' .. tostring(read_err))
    end
    local marker = dfhack.persistent.getSiteData(GLOBAL_KEY)
    if not marker or marker.state ~= 'done' or not marker.report then
        qerror('planeswalkers: no save/load operation report exists yet')
    end
    show_restore_report(marker.report_summary or marker.report,
                         marker.report_advanced or marker.report)
end

local function do_status()
    local js = common.job_status()
    if js then print('planeswalkers: RUNNING ' .. js) return end
    print('planeswalkers: no job running')
    local last_operation = common.read_last_operation_report()
    if last_operation then
        print(('  last operation: %s "%s" -- %s (%s)')
            :format(tostring(last_operation.kind or '?'), tostring(last_operation.name or '?'),
                    tostring(last_operation.state or '?'), tostring(last_operation.updated_at or last_operation.started_at or '?')))
        if last_operation.failed_phase then print('  operation failed phase: ' .. tostring(last_operation.failed_phase)) end
        if last_operation.failure then print('  operation failure: ' .. tostring(last_operation.failure)) end
    end
    if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then
        local marker = dfhack.persistent.getSiteData(GLOBAL_KEY)
        if marker and marker.state then
            print(('  this fort: restore "%s" from world "%s" -- %s (%s)')
                :format(marker.from or '?', marker.world or '?', marker.state,
                        marker.when or marker.failed_when or '?'))
            if marker.last_completed_phase then print('  last completed phase: ' .. marker.last_completed_phase) end
            if marker.failed_phase then print('  failed phase: ' .. marker.failed_phase) end
            if marker.current_phase then print('  current phase: ' .. marker.current_phase) end
            if marker.error then print('  last restore error: ' .. marker.error) end
            if marker.items then
                print(('  items: %d attached to units at load, %d held at the end of it, %d grounded')
                    :format(marker.items.attached, marker.items.held_at_end, marker.items.grounded))
            end
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
fort/planeswalkers -- move a fortress to another world.

SAVE AND RESTORE

  1. In the origin fortress:
         fort/planeswalkers save [name]
     Replace an existing or incomplete snapshot with:
         fort/planeswalkers save <name> --overwrite

  2. Generate or load another world and embark on a site at least as large
     as the saved footprint. The destination must also have enough vertical
     room above its underworld ceiling; --add-z can add top sky levels if needed.

  3. Inspect the proposed location without changing the map:
         fort/planeswalkers preview <name>
     Save the destination game manually before loading. Full automatic
     destination backup and rollback are not yet implemented.

  4. Restore the fortress:
         fort/planeswalkers list
         fort/planeswalkers load <name|number>
     If --add-z is used, save and reload immediately after the command adds
     sky levels, then rerun the load command. Save again after a successful restore.

TRANSFER DETAILS

  The origin footprint replaces the corresponding destination terrain.
  Internal Z spacing is preserved; the complete volume is shifted only as
  needed to clear the destination underworld ceiling and fit the map. Use
  --add-z when the origin roof needs more top sky levels than the destination has.
  This can add only sky levels at the top of the map, not levels between existing
  geology layers or below the underworld. DFHack recommends saving and reloading
  after adding sky levels before retrying the restore.
  Origin magma is restored as static liquid; it is not merged into the
  destination's global magma feature. The destination magma sea and underworld
  remain independently registered. Surface terrain is blended over a wider
  transition, crossing surface-water channels receive rock/soil bank caps at
  the seam (they are contained, not hydraulically connected between worlds),
  and a two-tile bulkhead seals the underground boundary above the local
  underworld ceiling. Replaced
  tiles lose stale destination mineral/feature assignments.

  The fresh embark wagon is deconstructed and its supplies are relocated.
  Embark units are moved individually to supported, unoccupied tiles.
  Unresolved raws, item references and placement failures appear in the report.

  Format v5 snapshots contain terrain, magma and temperature grids. Format v4
  loads without source heat data; v2 loads without source magma or heat data.
  Format v3 snapshots must be saved again because they omitted lower terrain.

COMMANDS

  fort/planeswalkers save [name]          save the current fortress
  fort/planeswalkers save <name> --overwrite
                                          replace an existing/partial snapshot
  fort/planeswalkers info                 show this help
  fort/planeswalkers gui                  choose a fort/party save
  fort/planeswalkers party [name] <ids>   save selected travellers and items
  fort/planeswalkers list                 open the snapshot browser
  fort/planeswalkers load                 open the snapshot browser
  fort/planeswalkers load <name|number>    restore a fortress
  fort/planeswalkers load ... --force     allow same-world/non-empty restore
  fort/planeswalkers preview <name>        preview placement without changes
  fort/planeswalkers compare <a> <b>       compare snapshot metadata
  fort/planeswalkers delete <name> --yes   delete snapshot and partial data
  fort/planeswalkers delete-list          delete all snapshots and partials
  fort/planeswalkers delete-list --preserve <name> [name ...]
                                          delete all except named snapshots
  fort/planeswalkers spires               re-arm restored spires
  fort/planeswalkers repair               restore static origin magma from snapshot
  fort/planeswalkers status               show progress and restore state
  fort/planeswalkers report               open the latest save/load operation report
  fort/planeswalkers cancel               cancel the active job
  fort/planeswalkers step                 pump one chunk manually
]]

local function do_help() print(HELP) end

-- `gui`: ask what comes along, then save it. The screen is the only place the choice is
-- made; `party` below is the same thing for a keyboard, and `save` with no selection is the
-- whole fort exactly as before.
local function do_gui()
    require_fort()
    req('gui').show(function(sel)
        if sel then
            do_save(nil, party_selection(sel.units, sel.items))
        else
            do_save(nil)
        end
    end)
end

-- fort/planeswalkers party [name] <unit id> [unit id...]
local function do_party(name, ...)
    require_fort()
    local ids = {...}
    if name and name:match('^%d+$') then           -- no name given, straight into ids
        table.insert(ids, 1, name)
        name = nil
    end
    if #ids == 0 then
        local u = dfhack.gui.getSelectedUnit(true)
        if not u then
            qerror('party: name the unit ids to take, or select a dwarf first')
        end
        ids = {u.id}
    end
    local sel = party_selection(ids, nil)
    local n = 0
    for _ in pairs(sel.items) do n = n + 1 end
    print(('planeswalkers: taking %d traveller(s) and %d carried item(s)'):format(#ids, n))
    do_save(name, sel)
end

local ACTIONS = {
    save = do_save, load = do_load, list = do_browser, delete = do_delete,
    preview = do_preview, compare = do_compare,
    ['delete-list'] = do_delete_list,
    gui = do_gui, party = do_party,
    status = do_status, report = do_report, ['compact-report'] = do_compact_report,
    cancel = do_cancel, step = do_step, spike = do_spike,
    spires = do_spires, repair = do_repair,
    info = do_help, help = do_help, ['--help'] = do_help, ['-h'] = do_help,
}

if dfhack_flags and dfhack_flags.module then return end

local args = {...}
local action = args[1]
if not action then do_help() return end
local fn = ACTIONS[action]
if not fn then
    qerror(('planeswalkers: unknown action "%s" (save|load|list|delete|delete-list|preview|compare|info|gui|' ..
            'party|spires|repair|status|report|compact-report|cancel); run `fort/planeswalkers info` for help')
        :format(action))
end
fn(table.unpack(args, 2))
