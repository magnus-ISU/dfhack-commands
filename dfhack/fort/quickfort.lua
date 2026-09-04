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

TWO DESIGNATIONS NEVER SHARE A SQUARE
  DF is happy to smooth the face of a natural wall. So a tile that carries a mine
  designation AND a smooth designation gets SMOOTHED -- and the mining never happens.
  Worse, finishing the smoothing clears the square's designations, so the wall is
  left standing in the middle of a room with nothing on it at all, and every step
  queued behind that square waits forever. Four rules keep that state unreachable:

  1. WITHIN a blueprint, a tile's steps run in stage order -- its dig finishes before
     its smooth is designated, its smooth before its engraving.
  2. BETWEEN blueprints, a step may only act when its stage is the earliest anything
     still has waiting at that square (`earliest_pending_stage`). Several plans can
     want one tile -- a road whose flank is the next room's doorway, a second apply
     over the same burrow -- and this is the queue between them. Stockpiles, zones
     and buildings hold their squares the same way until they are placed.
  3. A smoothing or engraving step also waits while the square carries a live dig
     designation that belongs to no job at all -- one you placed by hand.
  4. Mining wins any tie: a tile sitting at its dig step has any smoothing
     designation stripped straight off it.

  A HIDDEN square cannot be smoothed or engraved -- DF does not keep those
  designations on undiscovered rock -- so those steps WAIT until the rock beside them is
  dug and the wall is revealed. They are never retried-and-given-up in the meantime,
  which would leave a room's walls silently unsmoothed.

  A step is never written off while DF might still take it. Rock is always diggable, so
  a dig designation that went missing was taken away by something else, and mining is
  never given up on at all. For the rest, only an OUTRIGHT refusal counts against a
  square -- DF declining the designation the moment it is placed, which is the permanent
  kind of no (smoothing a soil floor). A designation that was accepted and later vanished
  is a cancelled job -- the wall went out of reach while the room was being dug, the
  dwarf was interrupted -- and it is simply placed again. Anything that did not happen --
  still rock past its dig step, still rough past its smoothing -- is rewound to that step
  and designated again.

    fort/quickfort           open the picker
    fort/quickfort status    running jobs, in the console
    fort/quickfort cancel    cancel every running job

SLABS ARE PLACED ENGRAVED
  A blank slab is a blank stone; an engraved one is the memorial that puts a ghost to
  rest. DF hands the mason whichever slab is nearest, and quickfort does not know the
  difference exists, so the first slab placed here turns on buildingplan's "engraved
  only" setting for slabs. It is a per-building-type setting that lives with the fort,
  so it is set once and left alone if you already have it on.

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
  It waits, and shows you that it is waiting -- unless a designation it placed was
  cancelled and stayed cancelled, which drops that blueprint (see below). A job that stops advancing usually
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
  every load, and progress is read back off the MAP. Every "done" test is
  POSITIVE evidence -- the tile is no longer wall, the tile is smooth, an
  engraving exists there, the track is carved, the building stands -- never the
  absence of a designation, which cannot tell a finished tile from one that was
  never asked. That means a save/load, a script reload or a mid-job
  cancel-and-restart all pick up exactly where the fort actually is, and it is
  impossible for the stored state to disagree with the world.

  A designation DF will not accept -- smoothing a soil floor, say -- is retried a
  few times and then given up on, so the steps queued behind it (the furniture
  waiting for that tile) are not blocked forever.

  Applying a step early is harmless: quickfort's own designation actions refuse
  a tile that is not ready (you cannot smooth un-dug rock), so a premature step
  is a no-op that gets retried, never a corruption.

  One DF mechanic matters here: a designation is CONSUMED when DF turns it into work.
  The tile's `dig` or `smooth` field goes back to 0 and a Dig / DetailWall / DetailFloor
  job appears on that square, waiting for a worker. So an empty designation does not mean
  "not designated yet" -- usually it means "already taken" -- and a step counts as placed
  while either the designation or a job for it is there. Reading it the other way is not
  a small mistake: it cancelled 26 blueprints in a live fort, half of them on mining.

  A step that has been placed is then LEFT ALONE for a minute. If both the designation
  and any job for it are gone by then, DF cancelled that work and did not hand the
  designation back -- which is ordinary: a mason is interrupted, a miner is called away.
  It is placed again, once. Re-placing it any sooner is what turns work into an endless
  pick-up-and-cancel, because a designation put back on a square a worker is already
  walking to makes DF drop that job and take a new one.

  A square that loses its designation more than a few times is not bad luck: something
  about it will not be worked. Only then is the blueprint cancelled, and the
  announcement recentres the map on the square and says which stage it was.

  MINING AND SMOOTHING NEVER SHARE A TILE. DF is happy to smooth the face of a natural
  wall, so a square that is one blueprint's flanking wall and another's doorway can end
  up carrying a mine designation and a smooth designation at once -- and then the
  smoothing is what gets worked, the mining never happens, and everything queued behind
  that square waits forever. Mining wins, both ways round: a smoothing or engraving step
  waits while its tile still carries a dig designation (from any blueprint, or from you)
  or while another running job has yet to dig it, and a tile at its dig step has any
  smoothing designation stripped off it.
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
local MAX_STEP_TRIES = 6          -- a designation DF will not take (smoothing soil, say)
                                  -- is skipped after this many tries, not retried forever
local RETRY_MS = 60000            -- how long a placed designation is left alone before it
                                  -- counts as lost
local MAX_STEP_LOSSES = 3         -- how many times a square may lose its designation before
                                  -- the blueprint is given up on

-- ---------------------------------------------------------------------------
-- stages
-- ---------------------------------------------------------------------------

STAGE = {dig = 1, smooth = 2, engrave = 3, carve = 4, build = 5, region = 6}

-- how a stage is named in an announcement
STAGE_NAME = {[1] = 'mining', [2] = 'smoothing', [3] = 'engraving', [4] = 'carving',
              [5] = 'construction', [6] = 'placement'}


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

-- Undiscovered rock. DF will happily take a MINE designation on a hidden tile (that is how
-- you dig into unexplored stone), but it refuses smoothing, engraving and track carving
-- there -- quickfort's own actions return nothing for them. A hidden square is therefore
-- not "impossible", it is "not yet": it becomes designatable the moment the rock beside it
-- is dug out and the wall is revealed.
local function is_hidden(pos)
    local d = designation(pos)
    return d and d.hidden or false
end

local function has_dig_designation(pos)
    local d = designation(pos)
    return d and d.dig ~= df.tile_dig_designation.No
end

-- DF CONSUMES a designation when it turns it into a job. The tile's `dig` or `smooth`
-- field goes back to 0 and a Dig / DetailWall / DetailFloor job appears on that square,
-- waiting for a worker -- measured in a live fort: every one of 17 active Dig jobs sat on
-- a tile with no dig designation left on it. So an empty designation does not mean "not
-- designated": most often it means "already taken", and reading it the other way had this
-- tool re-designating squares that were already queued and then declaring the work lost.
local DESIGNATION_JOBS = {
    -- SMOOTHING and ENGRAVING are different job types, and missing the smoothing pair here
    -- meant every square DF was busy smoothing looked like a square whose designation had
    -- gone missing -- which cancelled whole blueprints, 34 of 35 of them on smoothing
    [df.job_type.SmoothWall] = 'detail',
    [df.job_type.SmoothFloor] = 'detail',
    [df.job_type.Dig] = 'dig',
    [df.job_type.DigChannel] = 'dig',
    [df.job_type.CarveUpwardStaircase] = 'dig',
    [df.job_type.CarveDownwardStaircase] = 'dig',
    [df.job_type.CarveUpDownStaircase] = 'dig',
    [df.job_type.CarveRamp] = 'dig',
    [df.job_type.RemoveStairs] = 'dig',
    [df.job_type.DetailWall] = 'detail',
    [df.job_type.DetailFloor] = 'detail',
    [df.job_type.CarveTrack] = 'detail',
    [df.job_type.CarveFortification] = 'detail',
}
local function designation_job_tiles()
    local set = {}
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        local kind = job and DESIGNATION_JOBS[job.job_type]
        if kind then set[('%d,%d,%d'):format(job.pos.x, job.pos.y, job.pos.z)] = kind end
        link = link.next
    end
    return set
end
local job_tiles = {}
local function has_job_for(pos, kind)
    return job_tiles[('%d,%d,%d'):format(pos.x, pos.y, pos.z)] == kind
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

-- Positively smoothed, as opposed to "no smoothing designation on the tile": a
-- freshly dug floor has no designation either.
local function is_smoothed(pos)
    local tt = dfhack.maps.getTileType(pos)
    if not tt then return false end
    return df.tiletype.attrs[tt].special == df.tiletype_special.SMOOTH
end

local function is_track(pos)
    local tt = dfhack.maps.getTileType(pos)
    if not tt then return false end
    return df.tiletype.attrs[tt].special == df.tiletype_special.TRACK
end

local function is_fortification(pos)
    local tt = dfhack.maps.getTileType(pos)
    if not tt then return false end
    return df.tiletype.attrs[tt].shape == df.tiletype_shape.FORTIFICATION
end

-- Engravings are a world-level list, not a tile field, so keep a position set and
-- extend it as the list grows (it only shrinks when an engraving is destroyed, which
-- is when the whole set is rebuilt).
local engraved = {n = -1, set = {}}
local function engraving_key(pos) return ('%d,%d,%d'):format(pos.x, pos.y, pos.z) end
local function has_engraving(pos)
    local list = df.global.world.event.engravings
    local n = #list
    if n < engraved.n then
        engraved = {n = 0, set = {}}
    end
    if n > engraved.n then
        for i = math.max(engraved.n, 0), n - 1 do
            local e = list[i]
            if e then engraved.set[engraving_key(e.pos)] = true end
        end
        engraved.n = n
    end
    return engraved.set[engraving_key(pos)] or false
end

-- Take a smoothing designation off a tile. A tile carrying BOTH a mine and a smooth
-- designation is the one state that must never exist: DF works the smoothing and the
-- mining never happens, so the square stays wall forever and everything queued behind
-- it stalls. Mining always wins -- a wall that is going to be removed has no business
-- being polished first.
local function clear_smooth_designation(pos)
    local block, bx, by = tile_parts(pos)
    if not block then return end
    block.designation[bx][by].smooth = 0
    block.flags.designated = true
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
    if step.stage == STAGE.dig then
        return has_dig_designation(pos) or has_job_for(pos, 'dig')
    end
    if step.stage == STAGE.smooth or step.stage == STAGE.engrave then
        return has_smooth_designation(pos) or has_job_for(pos, 'detail')
    end
    if step.stage == STAGE.carve then
        return has_smooth_designation(pos) or has_track_designation(pos)
            or has_job_for(pos, 'detail')
    end
    if step.stage == STAGE.build then return building_at(pos) ~= nil end
    return false
end

-- Is the work this step asks for finished? Every answer here is POSITIVE evidence off
-- the map -- the tile is smooth, the engraving exists, the track is carved -- and not
-- "the designation is gone". The absence of a designation cannot tell a finished tile
-- from one that was never asked: reading it that way marked every smoothing and
-- engraving step done the instant its dig finished, so the furniture went straight onto
-- rough floor and nothing was ever smoothed.
local function step_done_on_map(step, pos)
    if step.stage == STAGE.dig then
        return not has_dig_designation(pos) and not is_wall(pos)
    end
    if step.stage == STAGE.smooth then return is_smoothed(pos) end
    if step.stage == STAGE.engrave then return has_engraving(pos) end
    if step.stage == STAGE.carve then
        local code = (step.text or ''):gsub('^m?b?', ''):gsub('%d+$', '')
        if code == 'F' then return is_fortification(pos) end
        return is_track(pos)
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
    -- one parsed section (a grid of cells with a mode) into the plan
    local function add_section_data(sd, section_name)
        local mode = sd.modeline.mode
        local region = {mode = mode, cells = {}, section = section_name,
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
                                              section = section_name,
                                              stage = STAGE.build}
            plan.total = plan.total + 1
        end
        if #region.cells > 0 then
            plan.regions[#plan.regions + 1] = region
            plan.total = plan.total + 1
        end
    end
    if job.data then
        -- an in-memory blueprint (fort/builder-burrow makes these): sections
        -- of {mode, name, cells = {{dx, dy, text}, ...}} relative to job.pos
        for _, sec in ipairs(job.data) do
            local grid = {}
            for _, c in ipairs(sec.cells) do
                local x, y = job.pos.x + c[1], job.pos.y + c[2]
                grid[y] = grid[y] or {}
                grid[y][x] = {text = c[3]}
            end
            add_section_data({grid = grid, zlevel = job.pos.z, modeline = {mode = sec.mode}},
                             sec.name or sec.mode)
        end
        for _, t in pairs(plan.tiles) do
            table.sort(t.steps, function(a, b) return a.stage < b.stage end)
        end
        table.sort(plan.regions, function(a, b) return a.stage < b.stage end)
        return plan
    end
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
            for _, sd in ipairs(section_data_list) do add_section_data(sd, section.name) end
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
        out[#out + 1] = {name = job.name, pos = job.pos, sections = job.sections, data = job.data}
    end
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {jobs = out})
end

local function warn(msg, pos)
    -- With a position it goes out as a ZOOM announcement, so the notification recentres
    -- the map on the square it is about when you click it (or press the recentre key), and
    -- its text says WHY rather than spending the line on coordinates. The console copy
    -- keeps the coordinates: that is the record you go back to afterwards, and without
    -- them there is no way to tell which square failed.
    local text = 'fort/quickfort: ' .. msg
    local ok = false
    if pos then
        ok = pcall(dfhack.gui.showZoomAnnouncement, df.announcement_type.CANCEL_JOB, pos,
                   text, COLOR_YELLOW, true)
    end
    if not ok then pcall(dfhack.gui.showAnnouncement, text, COLOR_YELLOW, true) end
    print(pos and ('%s [%d,%d,%d]'):format(text, pos.x, pos.y, pos.z) or text)
end

function start_job(entry, pos)
    local job = {
        name = entry.path,
        pos = {x = pos.x, y = pos.y, z = pos.z},
        sections = {},
        last_progress = dfhack.getTickCount(),
        done_count = 0,
    }
    if entry.data then
        -- an in-memory blueprint: the sections are its data blocks
        job.data = entry.data
        for _, sec in ipairs(entry.data) do
            job.sections[#job.sections + 1] = {name = sec.name or sec.mode, mode = sec.mode}
        end
    else
        for _, s in ipairs(entry.sections) do
            job.sections[#job.sections + 1] = {name = s.name, mode = s.mode}
        end
    end
    job.plan = build_plan(job)
    table.insert(jobs_table(), job)
    persist()
    return job
end

-- Is a running job about to put a zone on this tile? Tools that place activity zones of
-- their own (fort/auto-tomb drops a 1x1 Tomb on every coffin) ask this before acting: a
-- coffin whose room zone has not landed yet would otherwise get a 1x1 zone first, and DF
-- would then be holding two overlapping zones -- or, since an overlap is refused, the room
-- would never get the zone the blueprint asked for. A cancelled job stops answering, so
-- nothing is blocked forever.
function pending_zone_at(pos)
    for _, job in ipairs(jobs_table()) do
        if job.plan then
            for _, region in ipairs(job.plan.regions) do
                if region.mode == 'zone' and not region.applied then
                    for _, c in ipairs(region.cells) do
                        if c.pos.x == pos.x and c.pos.y == pos.y and c.pos.z == pos.z then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
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
                     data = saved.data, last_progress = dfhack.getTickCount(), done_count = 0}
        local ok, err = pcall(function() job.plan = build_plan(job) end)
        if ok and job.plan then
            jobs[#jobs + 1] = job
        else
            -- never disappear quietly: a blueprint that cannot be rebuilt is one the fort
            -- will simply stop working on, and that is worth saying out loud
            warn(('%s: dropped on load -- its blueprint could not be rebuilt (%s)')
                :format(job.name, tostring(err)))
        end
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

-- A SLAB is only worth placing if it is an engraved one: a blank slab is a blank stone,
-- while an engraved one is the memorial that puts a ghost to rest. DF picks whichever slab
-- is nearest unless told otherwise, and quickfort has no idea the distinction exists, so
-- every slab this places is put down under buildingplan's "engraved only" setting. That
-- setting is per building type and lives with the fort, so it is set once, when the first
-- slab of a session is placed, and left alone if it is already on.
local slab_special_set = false
local function want_engraved_slabs()
    if slab_special_set then return end
    slab_special_set = true
    local ok, buildingplan = pcall(require, 'plugins.buildingplan')
    if not ok or not buildingplan or not buildingplan.setSpecial then return end
    local got, specials = pcall(buildingplan.getSpecials, df.building_type.Slab, -1, -1)
    if got and specials and specials.engraved then return end
    pcall(buildingplan.setSpecial, df.building_type.Slab, -1, -1, 'engraved', true)
end

local SLAB_CODE = '~s'

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
        if c.text == SLAB_CODE then want_engraved_slabs() end
    end
    return pcall(quickfort.apply_blueprint,
        {mode = region.mode, data = data, pos = {x = minx, y = miny, z = z}})
end

local function region_tiles_ready(job, region, stages)
    local needs_building = region.mode == 'query' or region.mode == 'config'
    -- A ZONE is the loose case. It takes in the room's WALLS as well as its floor, so it
    -- must tolerate squares that are wall and squares still queued for smoothing and
    -- engraving -- a bedroom should be usable as soon as the room is dug, not months later
    -- when the last carving is finished. Everything else (a building, a stockpile) needs
    -- its squares finished and floored.
    local zone = region.mode == 'zone'
    for _, c in ipairs(region.cells) do
        local k = key(c.pos)
        local t = job.plan.tiles[k]
        if t then
            if not zone then
                if t.at <= #t.steps then return false end
            else
                for i = t.at, #t.steps do
                    if t.steps[i].stage == STAGE.dig then return false end
                end
            end
        end
        -- and nothing else may still owe this square earlier work
        local earliest = stages and stages[k]
        if earliest and earliest < (zone and STAGE.smooth or region.stage) then return false end
        if has_dig_designation(c.pos) then return false end
        if not zone and is_wall(c.pos) then return false end
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

-- The EARLIEST stage any running job still has waiting at each tile.
--
-- Within one blueprint a tile's steps are already ordered, but several blueprints can want
-- the same square -- two plans over the same ground, a second apply on the same burrow, a
-- road whose flank is the next room's doorway. This is the queue between them: a step may
-- only act when its stage is the earliest anything still has pending there, so smoothing
-- waits behind another job's digging, engraving waits behind its smoothing, and furniture
-- waits behind both. A job's own step is in this table too, so the earliest stage a tile
-- is waiting on is its own whenever nothing else is ahead of it.
local function earliest_pending_stage()
    local out = {}
    local function want(k, stage)
        local cur = out[k]
        if not cur or stage < cur then out[k] = stage end
    end
    for _, job in ipairs(jobs_table()) do
        if job.plan then
            for k, t in pairs(job.plan.tiles) do
                local step = t.steps[t.at]
                if step then want(k, step.stage) end
            end
            -- a stockpile, zone or building covers its tiles as one object; until it is
            -- placed it is still waiting on them
            for _, region in ipairs(job.plan.regions) do
                if not region.applied then
                    for _, c in ipairs(region.cells) do want(key(c.pos), region.stage) end
                end
            end
        end
    end
    return out
end

-- one pass over a job; returns true if anything advanced
local function pump_job(job, stages)
    local advanced = false
    local pending = 0

    for _, t in pairs(job.plan.tiles) do
        -- REPAIR: an earlier step that plainly never happened -- the square is still rock
        -- past its dig, or still rough past its smoothing -- is rewound and done again. A
        -- step that was deliberately given up on (gave_up) is left alone, so a square DF
        -- really will not take is not retried in a loop.
        local function rewind_to(stage, ok)
            if ok then return end
            for i = 1, t.at - 1 do
                if t.steps[i].stage == stage and not t.steps[i].gave_up then
                    job.done_count = math.max(0, job.done_count - (t.at - i))
                    t.at = i
                    t.steps[i].applied, t.steps[i].tries = false, 0
                    if stage == STAGE.dig then clear_smooth_designation(t.pos) end
                    advanced = true
                    return
                end
            end
        end
        if t.at > 1 then
            -- a dig is only ever finished by the square ceasing to be wall; if it is still
            -- wall, something took the mine designation away (a smoothing job on the same
            -- square used to do exactly that) and it was wrongly written off
            rewind_to(STAGE.dig, not is_wall(t.pos))
            -- likewise a smoothing is only finished by the square becoming smooth. A
            -- hidden square counts as not done and is rewound too -- it then WAITS at its
            -- smooth step until the rock beside it is dug and it can be designated.
            rewind_to(STAGE.smooth, is_smoothed(t.pos))
        end
        local step = t.steps[t.at]
        -- Wait for whatever else still owes this square earlier work: another blueprint's
        -- dig, or its smoothing. A live dig designation counts even when no job owns it,
        -- which is how a square you designated by hand also holds the queue.
        local earliest = step and stages and stages[key(t.pos)]
        local dressing = step and (step.stage == STAGE.smooth or step.stage == STAGE.engrave
            or step.stage == STAGE.carve)
        local held = step and ((earliest and step.stage > earliest)
            or (dressing and is_hidden(t.pos))
            or ((step.stage == STAGE.smooth or step.stage == STAGE.engrave)
                and has_dig_designation(t.pos)))
        if held then
            pending = pending + 1
        elseif step then
            pending = pending + 1
            local function finish()
                t.at = t.at + 1
                job.done_count = job.done_count + 1
                advanced = true
            end
            -- a step DF keeps refusing (you cannot smooth soil, and a room dug through
            -- a soil layer has floors like that) is given up on, so the tiles behind it
            -- -- the furniture waiting on this one -- are not blocked forever.
            -- MINING is never given up on: rock is always diggable, so a dig designation
            -- that went missing was taken away by something else, and abandoning it leaves
            -- a wall standing in the middle of a room with nothing designated on it.
            -- Counted ONLY when DF refuses the designation outright, the moment we place
            -- it: that is the permanent kind of no (smoothing a soil floor, say). A
            -- designation that WAS accepted and later vanished is a cancelled job -- the
            -- wall went out of reach while the room around it was being dug, the dwarf was
            -- interrupted -- and it is simply placed again. Counting those cost 45 walls
            -- their engraving in a live fort: six cancellations inside nine seconds and the
            -- square was written off, though it was perfectly engravable.
            local function refuse()
                if step.stage == STAGE.dig then return end
                step.tries = (step.tries or 0) + 1
                if step.tries >= MAX_STEP_TRIES then
                    step.gave_up = true
                    finish()
                end
            end
            if step.stage == STAGE.dig and has_smooth_designation(t.pos) then
                clear_smooth_designation(t.pos)
            end
            if step.applied then
                if step_done_on_map(step, t.pos) then
                    finish()
                elseif not step_pending_on_map(step, t.pos) then
                    -- Neither the designation nor a job for it is on the square any more:
                    -- DF cancelled the work and did not hand the designation back. That is
                    -- ORDINARY -- a mason gets interrupted, a miner is called away -- so it
                    -- is placed again. What must not happen is placing it again straight
                    -- away: a designation put back on a square a worker is already walking
                    -- to makes DF drop that job and take a new one, and the work is picked
                    -- up and cancelled forever. So it waits a minute (DF is often just
                    -- between consuming a designation and creating the job) and then tries
                    -- once more. A square that loses its designation MAX_STEP_LOSSES times
                    -- is not bad luck any more -- something about it will not be worked --
                    -- and only then is the blueprint given up on.
                    local now = dfhack.getTickCount()
                    if not step.retry_at then
                        step.retry_at = now + RETRY_MS
                    elseif now >= step.retry_at then
                        step.losses = (step.losses or 0) + 1
                        step.applied, step.retry_at = false, nil
                        advanced = true
                        if step.losses > MAX_STEP_LOSSES then
                            job.lost = {
                                what = STAGE_NAME[step.stage] or step.text,
                                losses = step.losses,
                                pos = copyall(t.pos),
                            }
                        end
                    end
                end
            else
                -- a step whose designation is already on the tile (the player
                -- did it, or we did before a reload) counts as applied
                if step_pending_on_map(step, t.pos) then
                    step.applied, step.retry_at = true, nil
                    advanced = true
                elseif step_done_on_map(step, t.pos) then
                    finish()
                elseif apply_cell(step.mode, step.text, t.pos)
                        and step_pending_on_map(step, t.pos) then
                    step.applied, step.retry_at = true, nil
                    advanced = true
                else
                    refuse()
                end
            end
        end
    end

    for _, region in ipairs(job.plan.regions) do
        if not region.applied then
            pending = pending + 1
            if region_tiles_ready(job, region, stages) then
                if zone_would_overlap(region) then
                    region.applied = true      -- refused, not retried
                    if not job.warned_overlap then
                        job.warned_overlap = true
                        warn(('%s: a zone overlaps one that already exists -- skipped')
                            :format(job.name), region.cells[1] and region.cells[1].pos)
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
    job_tiles = designation_job_tiles()
    local stages = earliest_pending_stage()
    for i = #jobs, 1, -1 do
        local job = jobs[i]
        local _, pending = pump_job(job, stages)
        if job.lost then
            table.remove(jobs, i)
            persist()
            warn(('%s: cancelled -- its %s was called off %d times over, so that square is'
                  .. ' not going to be worked (out of reach, or something is standing on it)')
                :format(job.name, job.lost.what, job.lost.losses), job.lost.pos)
        elseif pending == 0 then
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

-- ---------------------------------------------------------------------------
-- placement preview
-- ---------------------------------------------------------------------------
--
-- The preview comes from this tool's own planner, not from quickfort's preview
-- pass, and that is a deliberate difference. Asked to preview `housing.csv` on
-- undug ground, quickfort reports 651 invalid smoothing tiles, 318 invalid
-- carves and 207 invalid buildings -- measured, on a real fort -- because none
-- of that ground is dug YET. Every one of those tiles is perfectly fine by the
-- time its turn comes, so painting them red would be a lie about the only
-- blueprint shape this tool exists to handle.
--
-- Instead the preview shows the footprint coloured by WHEN each tile is due:
-- green for work that starts immediately, blue for work that waits its turn.
--
-- It is also built once, when placement begins, as offsets from the cursor --
-- re-parsing the blueprint on every mouse move would read the file dozens of
-- times a second.
local function build_footprint(entry)
    local job = {name = entry.path, pos = {x = 0, y = 0, z = 0}, sections = {}}
    for _, sec in ipairs(entry.sections) do
        job.sections[#job.sections + 1] = {name = sec.name, mode = sec.mode}
    end
    local ok, plan = pcall(build_plan, job)
    if not ok or not plan then return {offsets = {}, now = 0, later = 0} end

    local offsets, now, later = {}, 0, 0
    local function add(pos, immediate)
        offsets[#offsets + 1] = {dx = pos.x, dy = pos.y, dz = pos.z, now = immediate}
        if immediate then now = now + 1 else later = later + 1 end
    end
    for _, t in pairs(plan.tiles) do
        local first = t.steps[1]
        add(t.pos, first and first.stage == STAGE.dig)
    end
    for _, region in ipairs(plan.regions) do
        for _, c in ipairs(region.cells) do add(c.pos, false) end
    end
    return {offsets = offsets, now = now, later = later, total = plan.total}
end

-- footprint offsets -> the tile lookup and bounds renderMapOverlay wants
local function place_footprint(footprint, cursor)
    local tiles, bounds = {}, {}
    for _, o in ipairs(footprint.offsets) do
        local x, y, z = cursor.x + o.dx, cursor.y + o.dy, cursor.z + o.dz
        local row = ensure_keys(tiles, z, y)
        if row[x] == nil or o.now then row[x] = o.now end
        local b = ensure_key(bounds, z, {x1 = x, x2 = x, y1 = y, y2 = y})
        b.x1, b.x2 = math.min(b.x1, x), math.max(b.x2, x)
        b.y1, b.y2 = math.min(b.y1, y), math.max(b.y2, y)
    end
    return tiles, bounds
end

local function same_pos(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

-- Docked down the LEFT edge, the full height of the screen: the blueprint list and
-- the running-job list are both long, and the map you are about to place on is to the
-- right of them. `t` and `b` with no `h` stretch the window to whatever the screen is.
local LIST_FRAME = {l = 0, t = 0, b = 0, w = 80}

QuickfortWindow = defclass(QuickfortWindow, widgets.Window)
QuickfortWindow.ATTRS{
    frame_title = 'Quickfort (sequenced)',
    frame = copyall(LIST_FRAME),
    resizable = true,
}

function QuickfortWindow:init()
    self.blueprints = list_blueprints()
    self.list_frame = copyall(LIST_FRAME)
    self:addviews{
        widgets.FilteredList{
            view_id = 'list',
            frame = {l = 0, t = 0, w = 44, b = 16},
            edit_key = 'CUSTOM_ALT_S',
            on_select = function() self:show_detail() end,
            on_submit = function() self:enter_placement() end,
        },
        widgets.Label{
            view_id = 'detail',
            frame = {l = 46, t = 0, b = 16},
            text = '',
        },
        widgets.Label{
            view_id = 'place_help',
            frame = {l = 0, t = 0, b = 16},
            visible = false,
            text = '',
        },
        widgets.HotkeyLabel{
            view_id = 'cancel_btn',
            frame = {l = 30, b = 14},
            key = 'CUSTOM_CTRL_X',
            label = 'Cancel selected job',
            on_activate = function() self:cancel_selected() end,
        },
        widgets.Label{
            view_id = 'jobs_label',
            frame = {l = 0, b = 13},
            text = 'Running jobs:',
        },
        widgets.List{
            view_id = 'jobs',
            frame = {l = 0, b = 1, h = 12},
            choices = {},
        },
        widgets.Label{
            view_id = 'status',
            frame = {l = 0, b = 0},
            text = '',
        },
    }
    -- Choices are set AFTER addviews, never as a constructor field: setChoices
    -- selects a row, which fires on_select, which runs self:show_detail() --
    -- and during init self.subviews does not exist yet, so the callback died on
    -- a nil 'list' before the window ever opened.
    self.subviews.list:setChoices(self:make_choices())
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
    local list = self.subviews and self.subviews.list
    if not list then return end
    local _, choice = list:getSelected()
    return choice and choice.entry
end

function QuickfortWindow:set_status(msg)
    self.subviews.status:setText(msg)
end

function QuickfortWindow:show_detail()
    local detail = self.subviews and self.subviews.detail
    if not detail then return end
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

-- ---- placement mode -------------------------------------------------------
--
-- Clicking a blueprint does not start it. It switches the window into placement
-- mode, where the blueprint is drawn on the map under the mouse and a click on
-- the map commits it. That is the same shape as gui/quickfort's placement step,
-- and it exists for the same reason: a blueprint applied at the wrong cursor is
-- tedious to undo, and this one keeps working for hours afterwards.

-- Everything except the help text is hidden while placing, and the window
-- shrinks into the top-left corner. At its list size it covers the middle of
-- the screen, which is exactly where you are trying to look when deciding where
-- the blueprint goes.
local PLACING_FRAME = {w = 34, h = 13, l = 1, t = 1}

function QuickfortWindow:set_chrome(placing)
    for _, id in ipairs({'list', 'detail', 'cancel_btn', 'jobs_label', 'jobs', 'status'}) do
        local v = self.subviews[id]
        if v then v.visible = not placing end
    end
    self.subviews.place_help.visible = placing
    self.frame = placing and copyall(PLACING_FRAME) or copyall(self.list_frame)
    self:updateLayout()
end

function QuickfortWindow:enter_placement()
    local e = self:selected()
    if not e then return end
    -- While placing, a click on the map is the commit, so the screen must not
    -- defocus itself when the mouse goes out there. Restored on the way out, so
    -- in list mode clicking the map hands control straight back to the game.
    local screen = self.parent_view
    if screen then screen.defocusable, screen.defocused = false, false end
    self.placing = e
    self.footprint = build_footprint(e)
    self.preview = nil
    self.preview_at = nil
    self:set_chrome(true)
    self:set_status('')
end

function QuickfortWindow:leave_placement(msg)
    local screen = self.parent_view
    if screen then screen.defocusable = true end
    self.placing = nil
    self.footprint = nil
    self.preview = nil
    self.preview_at = nil
    self:set_chrome(false)
    if msg then self:set_status(msg) end
end

function QuickfortWindow:update_preview(cursor)
    if same_pos(self.preview_at, cursor) then return end
    self.preview_at = copyall(cursor)
    local tiles, bounds = place_footprint(self.footprint, cursor)
    self.preview = {tiles = tiles, bounds = bounds}
    local f = self.footprint
    self.subviews.place_help:setText(table.concat({
        self.placing.label,
        '',
        'Move the mouse to position it.',
        'LEFT CLICK on the map to start it here.',
        'RIGHT CLICK or Esc to go back.',
        '',
        ('at %d, %d, %d'):format(cursor.x, cursor.y, cursor.z),
        ('%d tiles dug first (green)'):format(f.now),
        ('%d follow as those finish (blue)'):format(f.later),
    }, NEWLINE))
end

function QuickfortWindow:commit_placement(cursor)
    local e = self.placing
    local job = start_job(e, cursor)
    self:leave_placement(('started %s at %d,%d,%d -- %d steps')
        :format(e.label, cursor.x, cursor.y, cursor.z, job.plan.total))
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

local to_pen = dfhack.pen.parse
local NOW_PEN = to_pen{ch = 'x', fg = COLOR_GREEN,
                       tile = dfhack.screen.findGraphicsTile('CURSORS', 1, 2)}
local LATER_PEN = to_pen{ch = '+', fg = COLOR_LIGHTBLUE,
                         tile = dfhack.screen.findGraphicsTile('CURSORS', 0, 0)}

function QuickfortWindow:onRenderFrame(dc, rect)
    QuickfortWindow.super.onRenderFrame(self, dc, rect)
    self:refresh_jobs()
    if not self.placing then return end

    local cursor = dfhack.gui.getMousePos()
    if not cursor then return end
    self:update_preview(cursor)

    -- in ASCII the overlay would hide the map under it, so blink it like
    -- gui/quickfort does
    if not dfhack.screen.inGraphicsMode() and not gui.blink_visible(500) then
        return
    end
    local tiles = self.preview and self.preview.tiles
    local bounds = tiles and self.preview.bounds[cursor.z]
    if not bounds then return end
    guidm.renderMapOverlay(function(pos)
        local t = safe_index(tiles, pos.z, pos.y, pos.x)
        if t == nil then return end
        return t and NOW_PEN or LATER_PEN
    end, bounds)
end

function QuickfortWindow:onInput(keys)
    if self.placing then
        if keys.LEAVESCREEN or keys._MOUSE_R then
            self:leave_placement('cancelled')
            return true
        end
        if keys._MOUSE_L and not self:getMouseFramePos() then
            -- getMousePos is nil anywhere that is not the map -- the minimap,
            -- DF's own panels -- so those clicks fall through and keep working
            local cursor = dfhack.gui.getMousePos()
            if cursor then
                self:commit_placement(cursor)
                return true
            end
        end
    end
    return QuickfortWindow.super.onInput(self, keys)
end

QuickfortScreen = defclass(QuickfortScreen, gui.ZScreen)
QuickfortScreen.ATTRS{
    focus_path = 'quickfort-seq',
    -- A ZScreen eats map movement keys unless told not to, which left the map
    -- frozen under the window. Mouse clicks outside the window already fall
    -- through to DF (that is the default), so with these two the map scrolls by
    -- keyboard, by dragging, and by the minimap while this is open.
    pass_movement_keys = true,
    pass_mouse_clicks = true,
}
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
