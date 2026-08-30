-- Quickfort, sequenced: one blueprint, applied a tile at a time as work finishes.
--@module = true
--[[
fort/quickfort

Stock quickfort applies a blueprint in one shot, which is why a blueprint that
digs a room and furnishes it cannot exist: the beds are placed on undug rock and
DF refuses them. The usual workaround is to split the design into `#dig`,
`#build`, `#place` and `#zone` files and run each by hand when the previous one
finishes -- which is also why the stock blueprint list shows the same design
four times.

This is a replacement front end that shows each blueprint ONCE, with every
section it contains, and then applies those sections itself, per tile, in
dependency order:

    dig  ->  smooth  ->  engrave / carve track  ->  build furniture

Each tile advances on its own. The mason smooths the first stretch of corridor
while miners are still cutting the far end; a bed goes down the moment its own
square is floor, not when the last tile of the blueprint is done.

    fort/quickfort           open the picker
    fort/quickfort status    running jobs, in the console
    fort/quickfort cancel    cancel every running job

BUILDINGS GO DOWN AS BUILDINGS
  A blueprint writes a 3x3 workshop as its code repeated across nine tiles, so
  applying build cells one at a time would ask DF for nine 1x1 workshops. Build
  cells that touch and carry the same code are therefore grouped, and each group
  is placed once, when every tile under it is ready. A bed is a group of one and
  behaves exactly like a single tile, which is the common case.

ZONES AND STOCKPILES ARE ALL-OR-NOTHING
  A zone or a stockpile is one object covering many tiles, so it cannot be laid
  down a tile at a time. Each is held until EVERY tile it covers has finished
  its own dig/smooth/build steps, then placed in one go.

  A zone is never placed over an existing zone. DF allows overlapping zones and
  the result is a mess that is tedious to unpick, so an overlap is refused, and
  reported once as a fortress announcement naming the blueprint.

WHEN IT CANNOT FINISH
  It waits, and shows you that it is waiting. A job that stops advancing usually
  has an ordinary reason -- the beds are not built yet, the miners are busy on
  something else, the stone for a door has not arrived -- and none of those mean
  the plan is wrong. There is no give-up timer, because on a real fort a timer
  fires mostly on jobs that were about to continue.

  Instead every running job is listed in the window with what it has done and
  what is left, and any of them can be cancelled there. A job that is genuinely
  stuck sits at the same count, which is the signal to look at it; cancelling
  removes it and its persisted state and leaves the map as it stands.

HOW PROGRESS IS TRACKED
  Nothing about the plan is stored beyond the blueprint name, the section list
  and the cursor it started at: the tile plan is rebuilt from the blueprint on
  every load, and progress is read back off the MAP -- a dig step is done when
  its designation is gone, a smooth step when `designation.smooth` clears, a
  build step when the building exists. That means a save/load, a script reload
  or a mid-job cancel-and-restart all pick up exactly where the fort actually
  is, and it is impossible for the stored state to disagree with the world.

  Applying a step early is harmless: quickfort's own designation actions refuse
  a tile that is not ready (you cannot smooth un-dug rock), so a premature step
  is a no-op that gets retried, never a corruption.
]]

local gui = require('gui')
local guidm = require('gui.dwarfmode')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local quickfort = reqscript('quickfort')
local quickfort_list = reqscript('internal/quickfort/list')
local quickfort_parse = reqscript('internal/quickfort/parse')

local GLOBAL_KEY = 'quickfort-seq'

local PUMP_INTERVAL_MS = 1500     -- how often a job is looked at

-- ---------------------------------------------------------------------------
-- stages
-- ---------------------------------------------------------------------------

STAGE = {dig = 1, smooth = 2, engrave = 3, carve = 4, build = 5, region = 6}

-- Which stage a `#dig` cell belongs to, by its code. Marker prefixes and the
-- priority suffix are stripped first: "ms3" is a smooth.
local function dig_stage(text)
    local code = text:gsub('^m?b?', ''):gsub('%d+$', '')
    if code == 's' then return STAGE.smooth end
    if code == 'e' then return STAGE.engrave end
    if code == 'F' then return STAGE.carve end
    if code:find('^track') or code == 'T' then return STAGE.carve end
    return STAGE.dig
end

local function stage_of(mode, text)
    if mode == 'dig' then return dig_stage(text) end
    if mode == 'build' then return STAGE.build end
    return STAGE.region      -- place, zone, query, config
end

-- Group same-code build cells that touch into one building each.
--
-- A blueprint writes a 3x3 workshop as its code repeated over all nine tiles,
-- so applying build cells one at a time would ask DF for nine 1x1 workshops
-- instead of one workshop. Furniture is a 1x1 group and behaves exactly as a
-- single tile would, so nothing is lost for the common case.
local function group_build_cells(cells)
    local by_key, groups = {}, {}
    for _, c in ipairs(cells) do
        by_key[('%d,%d,%d'):format(c.pos.x, c.pos.y, c.pos.z)] = c
    end
    local seen = {}
    for k, c in pairs(by_key) do
        if not seen[k] then
            local group, queue = {}, {k}
            seen[k] = true
            while #queue > 0 do
                local ck = table.remove(queue)
                local cell = by_key[ck]
                group[#group + 1] = cell
                for _, d in ipairs({{x=1,y=0}, {x=-1,y=0}, {x=0,y=1}, {x=0,y=-1}}) do
                    local nk = ('%d,%d,%d'):format(cell.pos.x + d.x, cell.pos.y + d.y,
                                                   cell.pos.z)
                    local n = by_key[nk]
                    if n and not seen[nk] and n.text == cell.text then
                        seen[nk] = true
                        queue[#queue + 1] = nk
                    end
                end
            end
            groups[#groups + 1] = group
        end
    end
    return groups
end

-- ---------------------------------------------------------------------------
-- map readers: "did this step take" and "is this step finished"
-- ---------------------------------------------------------------------------

local function tile_parts(pos)
    local block = dfhack.maps.getTileBlock(pos)
    if not block then return end
    return block, pos.x % 16, pos.y % 16
end

local function designation(pos)
    local block, bx, by = tile_parts(pos)
    return block and block.designation[bx][by] or nil
end

local function occupancy(pos)
    local block, bx, by = tile_parts(pos)
    return block and block.occupancy[bx][by] or nil
end

local function has_dig_designation(pos)
    local d = designation(pos)
    return d and d.dig ~= df.tile_dig_designation.No
end

local function has_smooth_designation(pos)
    local d = designation(pos)
    return d and d.smooth ~= 0
end

local function has_track_designation(pos)
    local o = occupancy(pos)
    if not o then return false end
    return o.carve_track_north or o.carve_track_south
        or o.carve_track_east or o.carve_track_west
end

local function is_wall(pos)
    local tt = dfhack.maps.getTileType(pos)
    if not tt then return false end
    local shape = df.tiletype.attrs[tt].shape
    return df.tiletype_shape.attrs[shape].basic_shape == df.tiletype_shape_basic.Wall
end

local function building_at(pos)
    local ok, b = pcall(dfhack.buildings.findAtTile, pos)
    return ok and b or nil
end

-- Has the designation this step asks for been placed on the tile?
local function step_pending_on_map(step, pos)
    if step.stage == STAGE.dig then return has_dig_designation(pos) end
    if step.stage == STAGE.smooth or step.stage == STAGE.engrave then
        return has_smooth_designation(pos)
    end
    if step.stage == STAGE.carve then
        return has_smooth_designation(pos) or has_track_designation(pos)
    end
    if step.stage == STAGE.build then return building_at(pos) ~= nil end
    return false
end

-- Is the work this step asks for finished?
local function step_done_on_map(step, pos)
    if step.stage == STAGE.dig then
        return not has_dig_designation(pos) and not is_wall(pos)
    end
    if step.stage == STAGE.smooth or step.stage == STAGE.engrave then
        return not has_smooth_designation(pos)
    end
    if step.stage == STAGE.carve then
        return not has_smooth_designation(pos) and not has_track_designation(pos)
    end
    if step.stage == STAGE.build then return building_at(pos) ~= nil end
    return true
end

-- ---------------------------------------------------------------------------
-- blueprint listing, one row per file
-- ---------------------------------------------------------------------------

-- do_list_internal returns one entry per SECTION; a blueprint that digs, builds
-- and zones shows up three times. Fold them back into the file they came from.
function list_blueprints()
    local by_path, order = {}, {}
    -- Hidden sections must be included: a library blueprint like house.csv keeps
    -- its real dig/build/place/zone content in hidden() sections and exposes only
    -- a #meta that runs them, so listing without hidden ones plans an empty job.
    -- The visible listing is still read, to mark which sections are which.
    local ok, list = pcall(quickfort_list.do_list_internal, true, true)
    if not ok then return {} end
    local visible = {}
    local ok2, vis = pcall(quickfort_list.do_list_internal, true, false)
    if ok2 then
        for _, v in ipairs(vis) do
            visible[('%s/%s'):format(v.path, tostring(v.section_name))] = true
        end
    end
    for _, v in ipairs(list) do
        local entry = by_path[v.path]
        if not entry then
            entry = {path = v.path, sections = {}, modes = {}}
            by_path[v.path] = entry
            order[#order + 1] = entry
        end
        entry.sections[#entry.sections + 1] = {
            name = v.section_name, mode = v.mode, comment = v.comment,
            hidden = not visible[('%s/%s'):format(v.path, tostring(v.section_name))]}
        entry.modes[v.mode] = (entry.modes[v.mode] or 0) + 1
    end
    for _, e in ipairs(order) do
        local modes = {}
        for _, m in ipairs({'dig', 'build', 'place', 'zone', 'query', 'config', 'meta'}) do
            if e.modes[m] then modes[#modes + 1] = m end
        end
        e.mode_summary = table.concat(modes, '+')
        e.label = e.path:gsub('^.*/', '')
    end
    return order
end

-- ---------------------------------------------------------------------------
-- planning
-- ---------------------------------------------------------------------------

local function key(pos) return ('%d,%d,%d'):format(pos.x, pos.y, pos.z) end

-- Rebuild the whole tile plan for a job from its blueprint. Deterministic, so
-- it is safe to throw away and redo at any time -- which is what makes the
-- persisted state a single line rather than a map of every tile.
function build_plan(job)
    local plan = {tiles = {}, regions = {}, total = 0}
    local filepath = quickfort_list.get_blueprint_filepath(job.name)
    for _, section in ipairs(job.sections) do
        -- `#meta` sections just run other sections of the same file, and every
        -- one of those is already in job.sections -- expanding a meta here
        -- would apply all of them twice
        if section.mode ~= 'meta' then
        local sheet_name, label = quickfort_parse.parse_section_name(section.name)
        local ok, section_data_list = pcall(quickfort_parse.process_section,
            filepath, sheet_name, label, copyall(job.pos), nil)
        if ok then
            for _, sd in ipairs(section_data_list) do
                local mode = sd.modeline.mode
                local region = {mode = mode, cells = {}, section = section.name,
                                stage = STAGE.region}
                local build_cells = {}
                for y, row in pairs(sd.grid) do
                    for x, cell in pairs(row) do
                        local pos = {x = x, y = y, z = sd.zlevel}
                        local stage = stage_of(mode, cell.text)
                        if stage == STAGE.region then
                            region.cells[#region.cells + 1] = {pos = pos, text = cell.text}
                        elseif stage == STAGE.build then
                            build_cells[#build_cells + 1] = {pos = pos, text = cell.text}
                        else
                            local t = plan.tiles[key(pos)]
                            if not t then
                                t = {pos = pos, steps = {}, at = 1}
                                plan.tiles[key(pos)] = t
                            end
                            t.steps[#t.steps + 1] = {stage = stage, mode = mode,
                                                     text = cell.text}
                            plan.total = plan.total + 1
                        end
                    end
                end
                for _, group in ipairs(group_build_cells(build_cells)) do
                    plan.regions[#plan.regions + 1] = {mode = mode, cells = group,
                                                      section = section.name,
                                                      stage = STAGE.build}
                    plan.total = plan.total + 1
                end
                if #region.cells > 0 then
                    plan.regions[#plan.regions + 1] = region
                    plan.total = plan.total + 1
                end
            end
        end
        end
    end
    -- each tile's steps run in stage order, so a tile that is dug, smoothed and
    -- then built on does those three things in that order no matter what order
    -- the sections appeared in the file
    for _, t in pairs(plan.tiles) do
        table.sort(t.steps, function(a, b) return a.stage < b.stage end)
    end
    table.sort(plan.regions, function(a, b) return a.stage < b.stage end)
    return plan
end

-- ---------------------------------------------------------------------------
-- job state
-- ---------------------------------------------------------------------------

-- jobs live in dfhack.internal so a script reload cannot orphan them
local function jobs_table()
    dfhack.internal.quickfort_seq_jobs = dfhack.internal.quickfort_seq_jobs or {}
    return dfhack.internal.quickfort_seq_jobs
end

local function persist()
    local out = {}
    for _, job in ipairs(jobs_table()) do
        out[#out + 1] = {name = job.name, pos = job.pos, sections = job.sections}
    end
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {jobs = out})
end

local function warn(msg)
    pcall(dfhack.gui.showAnnouncement, 'fort/quickfort: ' .. msg, COLOR_YELLOW, true)
    print('fort/quickfort: ' .. msg)
end

function start_job(entry, pos)
    local job = {
        name = entry.path,
        pos = {x = pos.x, y = pos.y, z = pos.z},
        sections = {},
        last_progress = dfhack.getTickCount(),
        done_count = 0,
    }
    for _, s in ipairs(entry.sections) do
        job.sections[#job.sections + 1] = {name = s.name, mode = s.mode}
    end
    job.plan = build_plan(job)
    table.insert(jobs_table(), job)
    persist()
    return job
end

function cancel_job(job)
    local jobs = jobs_table()
    for i, j in ipairs(jobs) do
        if j == job then table.remove(jobs, i) break end
    end
    persist()
end

function cancel_all()
    local n = #jobs_table()
    dfhack.internal.quickfort_seq_jobs = {}
    persist()
    return n
end

local function restore_jobs()
    local data = dfhack.persistent.getSiteData(GLOBAL_KEY, {jobs = {}})
    local jobs = {}
    for _, saved in ipairs(data.jobs or {}) do
        local job = {name = saved.name, pos = saved.pos, sections = saved.sections,
                     last_progress = dfhack.getTickCount(), done_count = 0}
        local ok = pcall(function() job.plan = build_plan(job) end)
        if ok and job.plan then jobs[#jobs + 1] = job end
    end
    dfhack.internal.quickfort_seq_jobs = jobs
end

-- ---------------------------------------------------------------------------
-- applying
-- ---------------------------------------------------------------------------

local function apply_cell(mode, text, pos)
    local ok = pcall(quickfort.apply_blueprint,
        {mode = mode, data = text, pos = {x = pos.x, y = pos.y, z = pos.z}})
    return ok
end

local function apply_region(region)
    -- rebuild the region as a grid relative to its top-left cell so it goes
    -- down as ONE stockpile / zone rather than a scatter of 1x1 ones
    local minx, miny, z = math.huge, math.huge, region.cells[1].pos.z
    for _, c in ipairs(region.cells) do
        minx, miny = math.min(minx, c.pos.x), math.min(miny, c.pos.y)
    end
    local data = {[0] = {}}
    for _, c in ipairs(region.cells) do
        local dy, dx = c.pos.y - miny, c.pos.x - minx
        data[0][dy] = data[0][dy] or {}
        data[0][dy][dx] = c.text
    end
    return pcall(quickfort.apply_blueprint,
        {mode = region.mode, data = data, pos = {x = minx, y = miny, z = z}})
end

local function region_tiles_ready(job, region)
    local needs_building = region.mode == 'query' or region.mode == 'config'
    for _, c in ipairs(region.cells) do
        local t = job.plan.tiles[key(c.pos)]
        if t and t.at <= #t.steps then return false end
        if has_dig_designation(c.pos) or is_wall(c.pos) then return false end
        -- query/config drive a building's own screen, so the building has to be
        -- standing before the keys mean anything
        if needs_building and not building_at(c.pos) then return false end
    end
    return true
end

local function zone_would_overlap(region)
    if region.mode ~= 'zone' then return false end
    for _, c in ipairs(region.cells) do
        local ok, zones = pcall(dfhack.buildings.findCivzonesAt, c.pos)
        if ok and zones and #zones > 0 then return true end
    end
    return false
end

-- one pass over a job; returns true if anything advanced
local function pump_job(job)
    local advanced = false
    local pending = 0

    for _, t in pairs(job.plan.tiles) do
        local step = t.steps[t.at]
        if step then
            pending = pending + 1
            if step.applied then
                if step_done_on_map(step, t.pos) then
                    t.at = t.at + 1
                    job.done_count = job.done_count + 1
                    advanced = true
                end
            else
                -- a step whose designation is already on the tile (the player
                -- did it, or we did before a reload) counts as applied
                if step_pending_on_map(step, t.pos) then
                    step.applied = true
                    advanced = true
                elseif step_done_on_map(step, t.pos) then
                    t.at = t.at + 1
                    job.done_count = job.done_count + 1
                    advanced = true
                elseif apply_cell(step.mode, step.text, t.pos)
                        and step_pending_on_map(step, t.pos) then
                    step.applied = true
                    advanced = true
                end
            end
        end
    end

    for _, region in ipairs(job.plan.regions) do
        if not region.applied then
            pending = pending + 1
            if region_tiles_ready(job, region) then
                if zone_would_overlap(region) then
                    region.applied = true      -- refused, not retried
                    if not job.warned_overlap then
                        job.warned_overlap = true
                        warn(('%s: a zone overlaps one that already exists -- skipped')
                            :format(job.name))
                    end
                elseif region.stage == STAGE.build
                        and building_at(region.cells[1].pos) then
                    region.applied = true       -- something is already built here
                    job.done_count = job.done_count + 1
                    advanced = true
                elseif apply_region(region) then
                    region.applied = true
                    job.done_count = job.done_count + 1
                    advanced = true
                end
            end
        end
    end

    job.pending = pending
    if advanced then job.last_progress = dfhack.getTickCount() end
    return advanced, pending
end

function pump()
    local jobs = jobs_table()
    for i = #jobs, 1, -1 do
        local job = jobs[i]
        local _, pending = pump_job(job)
        if pending == 0 then
            table.remove(jobs, i)
            persist()
            warn(('%s: finished'):format(job.name))
        end
    end
end

-- ---------------------------------------------------------------------------
-- pump overlay
-- ---------------------------------------------------------------------------

QuickfortPump = defclass(QuickfortPump, overlay.OverlayWidget)
QuickfortPump.ATTRS{
    desc = 'Drives fort/quickfort blueprint sequencing.',
    default_enabled = true,
    viewscreens = 'dwarfmode',
    overlay_onupdate_max_freq_seconds = 0,
    default_pos = {x = -1, y = -1},
    frame = {w = 1, h = 1},
}

next_pump_at = next_pump_at or 0

function QuickfortPump:overlay_onupdate()
    if #jobs_table() == 0 then return end
    local now = dfhack.getTickCount()
    if now < next_pump_at then return end
    next_pump_at = now + PUMP_INTERVAL_MS
    pcall(pump)
end

OVERLAY_WIDGETS = {pump = QuickfortPump}

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        dfhack.internal.quickfort_seq_jobs = {}
    elseif sc == SC_MAP_LOADED then
        pcall(restore_jobs)
    end
end

-- ---------------------------------------------------------------------------
-- GUI
-- ---------------------------------------------------------------------------

QuickfortWindow = defclass(QuickfortWindow, widgets.Window)
QuickfortWindow.ATTRS{
    frame_title = 'Quickfort (sequenced)',
    frame = {w = 80, h = 32},
    resizable = true,
}

function QuickfortWindow:init()
    self.blueprints = list_blueprints()
    self:addviews{
        widgets.FilteredList{
            view_id = 'list',
            frame = {l = 0, t = 0, w = 44, b = 8},
            edit_key = 'CUSTOM_ALT_S',
            on_select = function() self:show_detail() end,
            choices = self:make_choices(),
        },
        widgets.Label{
            view_id = 'detail',
            frame = {l = 46, t = 0, b = 8},
            text = '',
        },
        widgets.HotkeyLabel{
            frame = {l = 0, b = 6},
            key = 'CUSTOM_CTRL_S',
            label = 'Start at cursor',
            on_activate = function() self:start_here() end,
        },
        widgets.HotkeyLabel{
            frame = {l = 30, b = 6},
            key = 'CUSTOM_CTRL_X',
            label = 'Cancel selected job',
            on_activate = function() self:cancel_selected() end,
        },
        widgets.Label{
            frame = {l = 0, b = 5},
            text = 'Running jobs:',
        },
        widgets.List{
            view_id = 'jobs',
            frame = {l = 0, b = 1, h = 4},
            choices = {},
        },
        widgets.Label{
            view_id = 'status',
            frame = {l = 0, b = 0},
            text = '',
        },
    }
    self:show_detail()
end

function QuickfortWindow:make_choices()
    local choices = {}
    for _, e in ipairs(self.blueprints) do
        choices[#choices + 1] = {
            text = ('%-30s %s'):format(e.label:sub(1, 30), e.mode_summary),
            search_key = e.path .. ' ' .. e.mode_summary,
            entry = e,
        }
    end
    return choices
end

function QuickfortWindow:selected()
    local _, choice = self.subviews.list:getSelected()
    return choice and choice.entry
end

function QuickfortWindow:set_status(msg)
    self.subviews.status:setText(msg)
end

function QuickfortWindow:show_detail()
    local e = self:selected()
    if not e then
        self.subviews.detail:setText('no blueprints found')
        return
    end
    local lines = {e.path, ''}
    for _, s in ipairs(e.sections) do
        lines[#lines + 1] = ('  %-8s %s%s'):format(s.mode, s.name or '(first sheet)',
            s.hidden and '  (hidden)' or '')
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Applied in order: dig, smooth, engrave,'
    lines[#lines + 1] = 'carve, build; zones and stockpiles last.'
    self.subviews.detail:setText(table.concat(lines, NEWLINE))
end

function QuickfortWindow:start_here()
    local e = self:selected()
    if not e then return end
    local pos = guidm.getCursorPos() or dfhack.gui.getMousePos()
    if not pos then
        self:set_status('put the keyboard cursor (or the mouse) on the map first')
        return
    end
    local job = start_job(e, pos)
    self:set_status(('started %s at %d,%d,%d -- %d steps')
        :format(e.label, pos.x, pos.y, pos.z, job.plan.total))
end

function QuickfortWindow:cancel_selected()
    local _, choice = self.subviews.jobs:getSelected()
    if not choice or not choice.job then
        self:set_status('no job selected')
        return
    end
    cancel_job(choice.job)
    self:set_status(('cancelled %s'):format(choice.job.name:gsub('^.*/', '')))
    self:refresh_jobs()
end

-- The counts move as dwarves work, so the rows are rebuilt each frame; the
-- cursor is carried over so a job cannot slide out from under a cancel.
function QuickfortWindow:refresh_jobs()
    local list = self.subviews.jobs
    local sel = list:getSelected() or 1
    local choices = {}
    for _, job in ipairs(jobs_table()) do
        choices[#choices + 1] = {
            text = ('%-24s %4d done, %4d left'):format(
                job.name:gsub('^.*/', ''):sub(1, 24), job.done_count or 0,
                job.pending or 0),
            job = job,
        }
    end
    if #choices == 0 then
        choices[1] = {text = 'no running jobs'}
    end
    list:setChoices(choices, math.min(sel, #choices))
end

function QuickfortWindow:onRenderFrame(dc, rect)
    QuickfortWindow.super.onRenderFrame(self, dc, rect)
    self:refresh_jobs()
end

QuickfortScreen = defclass(QuickfortScreen, gui.ZScreen)
QuickfortScreen.ATTRS{focus_path = 'quickfort-seq'}
function QuickfortScreen:init() self:addviews{QuickfortWindow{}} end
function QuickfortScreen:onDismiss() view = nil end

-- ---------------------------------------------------------------------------
-- command
-- ---------------------------------------------------------------------------

function status()
    local jobs = jobs_table()
    if #jobs == 0 then
        print('fort/quickfort: no running jobs')
        return
    end
    for _, job in ipairs(jobs) do
        print(('fort/quickfort: %s at %d,%d,%d -- %d done, %d to go')
            :format(job.name, job.pos.x, job.pos.y, job.pos.z,
                job.done_count or 0, job.pending or 0))
    end
end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('fort/quickfort only works in fortress mode')
end

local arg = ({...})[1]
if arg == 'status' then
    status()
elseif arg == 'cancel' then
    local n = cancel_all()
    print(('fort/quickfort: cancelled %d job%s'):format(n, n == 1 and '' or 's'))
else
    view = view and view:raise() or QuickfortScreen{}:show()
end
