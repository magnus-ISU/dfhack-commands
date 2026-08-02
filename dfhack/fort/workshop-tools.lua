-- Two fixes for the workshop/furnace task panel: a [+] that re-queues a task, and
-- doable jobs sorted above impossible ones in the "Add new task" list.
--@module = true
--[[
fort/workshop-tools

Two overlays, both live on any workshop or furnace building panel
(dwarfmode/ViewSheets/BUILDING/Workshop, .../Furnace). Auto-discovered by
`overlay rescan` (magnus-scripts runs it); no enable needed.

**A `+` on every queued task.** Each task in the shop's list gets a `+` at the
right edge of the panel; clicking it queues another identical task without
reopening the menu. Pick "make bed" once, then click `+` six times for seven beds
-- the task you just added gets its own `+` straight away, so you can keep
clicking down the column. The copy carries the original's material, subtype and
reaction, plus its repeat/suspend flags -- it is DFHack's own deep job clone,
minus the worker assignment -- so it is exactly the task you already set up, not a
fresh one you have to re-specify. DF caps a shop at ten tasks; at ten the buttons
grey out.

**Doable jobs first in "Add new task".** DF lists every job the shop can ever do
and quietly greys out the ones you have no materials for, scattered through the
list -- worst at the smelter, where the ores you actually mined sit among two
dozen you never will. This re-orders that list so every job you can do right now
comes first, keeping DF's own alphabetical order within each group; the
impossible ones follow, still there, still greyed, just out of the way.

    workshop-tools           report what the overlays would do on the open panel

Both overlays can be toggled individually in `gui/overlay`
(`workshop-tools.dupe`, `workshop-tools.sort`).
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local building = df.global.game.main_interface.building
local NEWJOB = df.interface_button_building_new_jobst

local MAX_JOBS = 10           -- DF's own per-workshop task cap

-- ---------------------------------------------------------------------------
-- the panel's building
-- ---------------------------------------------------------------------------

-- the workshop/furnace whose sheet is open, or nil. Furnaces (smelter, kiln,
-- glass furnace) are a separate building class from workshops but carry the same
-- `jobs` vector and the same task panel, so both are in scope.
local function panel_building()
    local bld = dfhack.gui.getSelectedBuilding(true)
    if not bld then return end
    if df.building_workshopst:is_instance(bld) or df.building_furnacest:is_instance(bld) then
        return bld
    end
end

-- ---------------------------------------------------------------------------
-- duplicating a queued task
-- ---------------------------------------------------------------------------

-- Queue another copy of `job` at `bld`. cloneJobStruct deep-copies the job spec
-- (job_items, material, subtype, reaction) and keeps the repeat/suspend flags and
-- the BUILDING_HOLDER general ref, while dropping the worker, the attached items
-- and the posting -- i.e. exactly a fresh, unstarted copy of the same order.
function duplicate_job(bld, job)
    if not bld or not job then return nil, 'no task' end
    if #bld.jobs >= MAX_JOBS then
        return nil, ('this shop already holds DF\'s maximum of %d tasks'):format(MAX_JOBS)
    end
    local nj = dfhack.job.cloneJobStruct(job)
    if not nj then return nil, 'could not copy the task' end
    dfhack.job.linkIntoWorld(nj, true)     -- assigns a fresh id and links it into the world job list
    bld.jobs:insert('#', nj)
    dfhack.job.checkBuildingsNow()
    return nj
end

-- ---------------------------------------------------------------------------
-- sorting the "Add new task" list
-- ---------------------------------------------------------------------------

-- Every button in the list is freed the instant the panel closes, and DF leaves
-- `filtered_button` holding those dead pointers. `button` (the master vector) IS
-- cleared, so a non-empty `button` is the one safe "these pointers are live"
-- test -- reading a stale one segfaults DF. (Same guard DFHack's own slab
-- overlay uses on this vector.)
local function list_live()
    return #building.button > 0
end

-- a job DF has an objection to ("[Requires bituminous coal]", "[Requires Window]")
-- is one you cannot do right now. Non-job buttons (category selectors) carry no
-- objection field and count as doable, so they keep their place at the top.
local function objected(b)
    return NEWJOB:is_instance(b) and b.objection ~= ''
end

-- Is the displayed list already doable-first? Cheap enough to run every frame;
-- the actual re-order then only happens right after DF has rebuilt the vector
-- (opening the panel, typing in its filter box).
local function needs_sort(vec)
    local seen_bad = false
    for i = 0, #vec - 1 do
        if objected(vec[i]) then seen_bad = true
        elseif seen_bad then return true end
    end
    return false
end

-- Stable partition of the DISPLAY vector: doable first, impossible after, DF's
-- own order preserved inside each group. Only ever called on a freshly rebuilt
-- vector, so the current index is a faithful stand-in for DF's intended order.
function sort_job_list()
    if not list_live() then return 0 end
    local vec = building.filtered_button
    local n = #vec
    if n < 2 or not needs_sort(vec) then return 0 end

    local sel = (building.selected >= 0 and building.selected < n) and vec[building.selected] or nil
    local arr = {}
    for i = 0, n - 1 do
        arr[i + 1] = {b = vec[i], rank = i, bad = objected(vec[i]) and 1 or 0}
    end
    table.sort(arr, function(x, y)
        if x.bad ~= y.bad then return x.bad < y.bad end
        return x.rank < y.rank
    end)

    local out, newsel, moved = {}, nil, 0
    for i, e in ipairs(arr) do
        out[i] = e.b
        if e.rank ~= i - 1 then moved = moved + 1 end
        if sel and e.b == sel then newsel = i - 1 end
    end
    vec:assign(out)
    vec:resize(n)
    -- keep the highlight on whatever row it was on, rather than letting it jump
    -- to an unrelated job that happens to have landed at the old index
    if newsel then building.selected = newsel end
    return moved
end

-- ---------------------------------------------------------------------------
-- finding the queued-task rows on screen
-- ---------------------------------------------------------------------------
-- DF exposes no geometry for the rows it draws in the task panel, so we read
-- them back off the text grid: every queued task is drawn under the name we can
-- already compute for it, and the rows come out in `bld.jobs` order, so even two
-- identical tasks pair up with the right entries. The scan is bounded to the
-- panel's half of the screen and only re-runs when the task list changes.

local ADD_TASK = 'Add new task'
local PANEL_X0 = 40                    -- the building sheet is well right of centre

local function read_row(y, x0, x1)
    local chars = {}
    for x = x0, x1 do
        local ok, pen = pcall(dfhack.screen.readTile, x, y)
        local ch = (ok and pen and pen.ch) or 0
        chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(chars)
end

-- DF truncates a long task name to fit the panel, so match on a prefix rather
-- than the whole string; 14 characters is enough to tell tasks apart without
-- being long enough to fall off the end of a narrow panel.
local PREFIX = 14

-- returns {rows = {{job, y, dy, x_end}, ...}, anchor_x, anchor_y, complete} or nil.
-- `dy` is the row's offset from the first one -- the panel draws tasks three lines
-- apart, so nothing here may assume a one-row pitch. `complete` is false when we
-- found fewer rows than the shop has tasks, which is the normal state for a frame
-- or two after a task is added: readTile hands back the LAST RENDERED frame, so the
-- new row is not on screen yet even though it already exists in `bld.jobs`.
local function locate_task_rows(bld)
    -- while the "Add new task" list is up it covers the queued tasks, and its own
    -- entries would match the names we are looking for
    if #building.button > 0 then return end

    local sw, sh = dfhack.screen.getWindowSize()
    local x1 = sw - 1
    local grid, ax, ay = {}, nil, nil
    for y = 0, sh - 1 do
        local text = read_row(y, PANEL_X0, x1)
        grid[y] = text:lower()         -- DF's row capitalisation need not match getName's
        if not ay then
            local c = text:find(ADD_TASK, 1, true)
            if c then ax, ay = PANEL_X0 + c - 1, y end
        end
    end
    if not ay then return end          -- panel not drawn yet (wrong tab, or mid-transition)

    local rows, ji = {}, 0
    for y = 0, sh - 1 do
        if ji >= #bld.jobs then break end
        local job = bld.jobs[ji]
        local name = dfhack.job.getName(job) or ''
        local want = name:sub(1, PREFIX):lower()
        local c = (#want > 0) and grid[y]:find(want, 1, true) or nil
        if c then
            local col = PANEL_X0 + c - 1
            rows[#rows + 1] = {job = job, y = y, x_end = col + #name}
            ji = ji + 1
        end
    end
    if #rows == 0 then return end
    for _, r in ipairs(rows) do r.dy = r.y - rows[1].y end
    return {rows = rows, anchor_x = ax, anchor_y = ay, complete = #rows == #bld.jobs}
end

-- ---------------------------------------------------------------------------
-- overlay: a [+] on every queued task
-- ---------------------------------------------------------------------------

local PLUS = '+'
local PLUS_W = #PLUS

-- how many frames to keep re-reading the screen for a task row that has not been
-- drawn yet before settling for the rows we did find. A newly added task appears
-- within a frame or two; this is only a backstop against scanning forever if a
-- name never matches (a scrolled-off row, say).
local MAX_TRIES = 30

DupeOverlay = defclass(DupeOverlay, overlay.OverlayWidget)
DupeOverlay.ATTRS{
    desc = 'Adds a [+] to each queued workshop task that queues another one just like it.',
    default_pos = {x = 2, y = 6},      -- fallback until it snaps onto the task rows
    default_enabled = true,
    viewscreens = {
        'dwarfmode/ViewSheets/BUILDING/Workshop',
        'dwarfmode/ViewSheets/BUILDING/Furnace',
    },
    frame = {w = PLUS_W, h = 1},
    overlay_onupdate_max_freq_seconds = 0,   -- checked per frame, re-scraped only on change
    version = 1,
}

-- Where the sheet panel stops. DF paints a background tile clear across the panel
-- and nothing at all beyond it, so walking right from the task text until a column
-- comes back blank finds the edge -- no hard-coded width, whatever the window size.
-- The tile test covers the graphical tilesets; the printable-char and background
-- colour tests cover ASCII mode, where there is no tile to find.
local function panel_right_edge(y, from_x)
    local sw = dfhack.screen.getWindowSize()
    local last = from_x
    for x = from_x, sw - 1 do
        local ok, pen = pcall(dfhack.screen.readTile, x, y)
        local drawn = false
        if ok and pen then
            local ch, tile = pen.ch or 0, pen.tile or 0
            drawn = tile ~= 0 or (ch > 32 and ch < 127) or (pen.bg or 0) ~= 0
        end
        if not drawn then break end
        last = x
    end
    return last
end

-- The column the [+] buttons share: right-aligned against the panel edge, inset by
-- the same two columns DF leaves to the left of the task names. If a task name were
-- ever long enough to reach that far, the buttons give way and sit just past the
-- longest name instead of overprinting it.
local RIGHT_INSET = 1

local function plus_column(loc)
    local x = 0
    for _, r in ipairs(loc.rows) do if r.x_end > x then x = r.x_end end end
    local edge = panel_right_edge(loc.rows[1].y, x)
    local col = edge - RIGHT_INSET - PLUS_W + 1
    if col < x + 2 then col = x + 2 end
    local sw = dfhack.screen.getWindowSize()
    return math.min(col, sw - PLUS_W)
end

-- draws the buttons for whatever rows we could find; returns whether every task
-- got one, so the caller knows if it is worth looking again next frame
function DupeOverlay:reposition(bld)
    local loc = locate_task_rows(bld)
    if not loc then
        self.rows, self.by_dy = nil, nil   -- never keep drawing the previous list's rows
        return false
    end
    local col = plus_column(loc)
    local ir = gui.get_interface_rect()
    self.rows = loc.rows
    -- one entry per drawn line, so a click maps straight back to its task
    -- whatever pitch the panel happens to use
    self.by_dy = {}
    for _, r in ipairs(loc.rows) do self.by_dy[r.dy] = r.job end
    self.frame = {w = PLUS_W, h = loc.rows[#loc.rows].dy + 1,
                  l = col - ir.x1, t = loc.rows[1].y - ir.y1}
    self:updateLayout(gui.ViewRect{rect = ir})
    return loc.complete
end

-- re-scrape only when the shop, its task list or the window changes; the cheap
-- signature check itself is what runs every frame
function DupeOverlay:overlay_onupdate()
    local bld = panel_building()
    if not bld or #bld.jobs == 0 or #building.button > 0 then
        self.sig, self.trying, self.tries = nil, nil, nil
        self.rows, self.by_dy = nil, nil
        return
    end
    self.full = #bld.jobs >= MAX_JOBS
    local ids = {}
    for _, j in ipairs(bld.jobs) do ids[#ids + 1] = j.id end
    local sw, sh = dfhack.screen.getWindowSize()
    local sig = ('%d:%s:%dx%d'):format(bld.id, table.concat(ids, ','), sw, sh)
    if sig == self.sig then return end                 -- nothing changed; nothing to re-read

    -- Keep looking until every task has a button. A task queued by our own [+] (or
    -- by DF) exists in `bld.jobs` before its row is painted, so the first scan after
    -- one is added finds a row short -- retrying next frame is what makes the new
    -- task's button appear right away instead of waiting for the next panel change.
    if sig ~= self.trying then self.trying, self.tries = sig, 0 end
    self.tries = self.tries + 1
    if self:reposition(bld) or self.tries >= MAX_TRIES then
        self.sig, self.trying, self.tries = sig, nil, nil
    end
end

function DupeOverlay:onRenderBody(dc)
    if not self.rows then return end
    -- greyed out at DF's ten-task cap: the button stays put, it just can't do
    -- anything until a task finishes or is cancelled
    local pen = self.full and COLOR_DARKGREY or COLOR_LIGHTGREEN
    for _, r in ipairs(self.rows) do
        dc:seek(0, r.dy):string(PLUS, pen)
    end
end

function DupeOverlay:onInput(keys)
    if not keys._MOUSE_L or not self.by_dy then return false end
    local _, y = self:getMousePos()
    if not y then return false end
    local job = self.by_dy[y]
    if not job then return false end   -- a gap between rows: let the click through
    local bld = panel_building()
    if not bld then return false end
    local _, err = duplicate_job(bld, job)
    if err then
        dfhack.printerr('workshop-tools: ' .. err)
    else
        self.sig = nil                 -- the list grew: re-scrape on the next frame
    end
    return true
end

-- ---------------------------------------------------------------------------
-- overlay: sort the job list (no UI of its own)
-- ---------------------------------------------------------------------------

SortOverlay = defclass(SortOverlay, overlay.OverlayWidget)
SortOverlay.ATTRS{
    desc = 'Sorts a workshop\'s "Add new task" list so jobs you can do come before ones you can\'t.',
    default_pos = {x = -1, y = -1},
    default_enabled = true,
    viewscreens = {
        'dwarfmode/ViewSheets/BUILDING/Workshop',
        'dwarfmode/ViewSheets/BUILDING/Furnace',
    },
    frame = {w = 1, h = 1},                -- logic only; nothing is drawn
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function SortOverlay:overlay_onupdate()
    sort_job_list()
end

OVERLAY_WIDGETS = {dupe = DupeOverlay, sort = SortOverlay}

if dfhack_flags and dfhack_flags.module then return end

-- ---------------------------------------------------------------------------
-- command line: report on the open panel
-- ---------------------------------------------------------------------------

local bld = panel_building()
if not bld then
    print('workshop-tools: no workshop or furnace panel is open.')
    print('Open one to see its tasks; the overlays work on their own.')
else
    print(('%s -- %d/%d tasks'):format(dfhack.buildings.getName(bld), #bld.jobs, MAX_JOBS))
    -- ipairs over a df vector starts at 0, so the human-facing number is i+1
    for i, j in ipairs(bld.jobs) do
        print(('  %d. %s'):format(i + 1, dfhack.job.getName(j)))
    end
    local loc = locate_task_rows(bld)
    if not loc then
        print('  (could not find the task rows on screen -- the [+] buttons stay hidden)')
    else
        print(('  "%s" anchor at col %d row %d; [+] column %d')
            :format(ADD_TASK, loc.anchor_x, loc.anchor_y, plus_column(loc)))
        for i, r in ipairs(loc.rows) do
            print(('    row %d -> screen y=%d, name ends at col %d'):format(i, r.y, r.x_end))
        end
        if #loc.rows < #bld.jobs then
            print(('    WARNING: matched %d of %d tasks'):format(#loc.rows, #bld.jobs))
        end
    end
end

if list_live() then
    local vec = building.filtered_button
    local bad = 0
    for i = 0, #vec - 1 do if objected(vec[i]) then bad = bad + 1 end end
    print(('"Add new task" list: %d jobs, %d of them unavailable%s'):format(
        #vec, bad, needs_sort(vec) and ' (unsorted)' or ' (sorted)'))
end
