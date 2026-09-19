-- Workshop Tasks list: click a job's worker icon to open that dwarf's sheet and follow them.
--@module = true
--[[
clickable-job-worker

A workshop's Tasks list tells you that somebody is on a job -- the row of the job being worked
carries its own icon, the green check DF draws for a claimed task -- and then refuses to say
who. The one question that icon raises is the one the screen will not answer: WHICH dwarf is
doing this, and where are they?

  * CLICK THE JOB'S NAME, OR ITS GREEN CHECK, and that dwarf's sheet opens with the camera
    following them. The same pair of actions `clickable-noble-names`,
    `clickable-squad-members` and `clickable-broker` do for their rows.

    Those two spans and nothing else: DF's own row buttons sit between them, and
    `fort/workshop-tools` puts a `+` near the panel's right edge. Taking the whole row --
    which this did at first -- swallowed clicks meant for both.

    The building's sheet closes on the way out, because a camera following a dwarf behind a
    full-screen sheet is not much of a view. A worker who has left the map (a hauler on a
    raid, a corpse already carted off) gets the sheet alone.

THE "ADD NEW TASK" MENU IS LEFT ALONE. It draws over the same rows with job names, so a
click on "Make pair of silk gloves" there looked like a click on a queued job with the same
words; while that menu is open (`main_interface.building.button` is non-empty) nothing here
takes a click.

ONLY A ROW WITH A WORKER ON IT IS TAKEN. A job nobody has picked up has no dwarf to show, so
its row is left to DF entirely -- which is every row on a quiet workshop. The rows that do get
taken are the ones carrying the check, and what the check means is exactly what this answers.

WHERE DF'S ROW TEXT AND THE JOB'S NAME DISAGREE, the longest run of whole words they share
decides the row. A butcher's shop draws "Slaughter Stray Yak Bull (Tame)" for a job named
"Slaughter animal" -- DF names the beast, the job name does not -- so matching on the name
alone left every row on a butcher's shop unclickable.

HOW A ROW IS IDENTIFIED, and why not by counting rows. The list scrolls and the rows are three
lines tall, so arithmetic on the click's y hands back the wrong job as soon as anything is
scrolled -- on a screen whose buttons cancel work, that is not a mistake worth risking.
Instead the clicked line is READ: `dfhack.job.getName` returns exactly the string DF drew on
the row ("Make gabbro door", "Brynjolf Ánulvathez (engrave memorial)"), so the row is whichever
job's name is actually on that line. Where two jobs share a name -- two "Make rock pedestal"
rows -- the rows carrying that name are matched to those jobs in order, top to bottom.

Registered automatically as overlay `fort/clickable-job-worker.click`.
Reposition with `gui/overlay` (the widget itself draws nothing -- it is a click handler).
]]

local overlay = require('plugins.overlay')

-- the sheet's own panel: roughly the right third of the screen. Everything this reads lives
-- inside it, and bounding the scan is what keeps a click cheap -- readTile is not free, and a
-- whole-screen sweep per click is a visible pause.
local function panel_band()
    local w, h = dfhack.screen.getWindowSize()
    return math.floor(w * 0.45), w - 1, h
end

-- the line's text as the bytes DF drew, blanks as spaces, inside the panel only
local function line_text(y)
    local x1, x2 = panel_band()
    local out = {}
    for x = x1, x2 do
        local p = dfhack.screen.readTile(x, y)
        out[#out + 1] = string.char((p and p.ch and p.ch ~= 0) and p.ch or 32)
    end
    return table.concat(out)
end

-- The building whose sheet is open. `viewing_bldid` is the field DF builds its own focus
-- string from, so it is also the honest answer to "what am I looking at".
-- NOT THE TRADE DEPOT. A depot has jobs -- "Trade at depot", held by the broker, "Bring item
-- to depot" held by whoever is hauling -- but no Tasks list: nobody queued them and the sheet
-- draws no worker check beside them. What the depot sheet DOES draw is the broker's name with
-- her current job under it, and when that job is "Trade at depot" it reads exactly like a
-- Tasks row for a job whose worker is the broker. So a click landing there -- or on DF's own
-- Trade button, which shares the word -- opened the broker's sheet and closed the depot, with
-- the trade never started. The depot is fort/clickable-broker's, and it is skipped here.
local function sheet_building()
    local vs = df.global.game.main_interface.view_sheets
    if not vs.open or vs.active_sheet ~= df.view_sheet_type.BUILDING then return nil end
    local bld = df.building.find(vs.viewing_bldid)
    if bld and df.building_tradedepotst:is_instance(bld) then return nil end
    return bld
end

local function job_worker(job)
    for _, r in ipairs(job.general_refs) do
        if r:getType() == df.general_ref_type.UNIT_WORKER then
            return df.unit.find(r.unit_id)
        end
    end
end

-- DF truncates a long row with an ellipsis, so match on a prefix rather than the whole name.
-- Short enough to survive the truncation, long enough that two different jobs do not collide.
local PROBE = 16

local function probe_of(job)
    local ok, name = pcall(dfhack.job.getName, job)
    if not ok or not name or name == '' then return nil end
    return name:sub(1, PROBE)
end

-- DF'S ROW TEXT IS NOT ALWAYS THE JOB'S NAME. A butcher's shop draws "Slaughter Stray Yak
-- Bull (Tame)" for a job `dfhack.job.getName` calls "Slaughter animal": DF names the beast
-- and the job name does not, so the probe appeared on no line and NO row on a butcher's shop
-- could be clicked at all. The same split turns up wherever DF names the target rather than
-- the work.
--
-- So where no job's name is on the line, the row is matched by the longest run of WHOLE WORDS
-- it shares with one. "Slaughter" is nine characters of agreement and nothing else in a
-- butcher's list comes near it. A short agreement is not agreement -- "Make" opens every
-- other row on a craftsdwarf's shop -- so the run must reach MIN_PREFIX characters, and a run
-- that stops mid-word does not count as sharing that word. Jobs that tie fall to the same
-- in-order rule as jobs that read identically.
local MIN_PREFIX = 6

local function shared_head(line, name)
    local n = 0
    local a, b = line:lower(), name:lower()
    while n < #a and n < #b and a:sub(n + 1, n + 1) == b:sub(n + 1, n + 1) do n = n + 1 end
    local pre = line:sub(1, n)
    -- diverged inside a word: back off to the last whole one
    if n < #line and n < #name and not line:sub(n + 1, n + 1):match('%s') then
        pre = pre:match('^(.*)%s%S*$') or ''
    end
    return (pre:gsub('%s+$', ''))
end

-- the jobs whose name shares the longest leading words with this line, kept in the original
-- case so the shared run is still a literal substring of what DF drew
local function prefix_matches(bld, text)
    local head = text:match('^%s*(.-)%s*$')
    if head == '' then return {} end
    local best, out = MIN_PREFIX - 1, {}
    for _, j in ipairs(bld.jobs) do
        local ok, name = pcall(dfhack.job.getName, j)
        if ok and name and name ~= '' then
            local pre = shared_head(head, name)
            if #pre > best then best, out = #pre, {{job = j, probe = pre}}
            elseif #pre == best then out[#out + 1] = {job = j, probe = pre} end
        end
    end
    return out
end

-- Which job DF drew on this line. Jobs that share a name are matched to the lines carrying it
-- IN ORDER -- the first such line is the first such job -- which is the only thing that can be
-- said about two rows that read identically.
function job_on_line(bld, y)
    local text = line_text(y)
    local matches = {}
    for _, j in ipairs(bld.jobs) do
        local probe = probe_of(j)
        if probe and text:find(probe, 1, true) then matches[#matches + 1] = {job = j, probe = probe} end
    end
    if #matches == 0 then matches = prefix_matches(bld, text) end
    if #matches == 0 then return nil end
    if #matches == 1 then return matches[1].job end

    -- ambiguous: find where this line sits among the lines showing the same name
    local probe = matches[1].probe
    local _, _, h = panel_band()
    local nth, seen = nil, 0
    for yy = 0, h - 1 do
        if line_text(yy):find(probe, 1, true) then
            seen = seen + 1
            if yy == y then nth = seen end
        end
    end
    return nth and matches[math.min(nth, #matches)].job or matches[1].job
end

-- ---- what part of the row is OURS ---------------------------------------------
--
-- THE NAME AND THE CHECK, and nothing else. Taking the whole row was greedy and wrong: DF's
-- own per-row buttons sit in the middle of it, and `fort/workshop-tools` puts a `+` (queue
-- another one of these) near the right edge -- a click this tool swallowed before its owner
-- ever saw it. Measured on a Stoneworker's list: the name runs from column 96, DF's row
-- buttons are at 131-151, the `+` is at 153 just inside the panel border at 154, and the
-- green check is at 163-166, outside the panel entirely.
--
-- So the region is two spans, read off the render: the run of text that is the job's name,
-- and the icon beyond the panel's edge. Everything between them belongs to somebody else.

-- the name: printable characters from the first one, ending at the first gap of two or more
-- blanks, so a `+` parked further along the line is not swallowed with it
local function name_span(y)
    local x1, x2 = panel_band()
    local first, last, gap = nil, nil, 0
    for x = x1, x2 do
        local p = dfhack.screen.readTile(x, y)
        local ch = p and p.ch or 0
        if ch > 32 and ch < 127 then
            if not first then first = x end
            last, gap = x, 0
        elseif first then
            gap = gap + 1
            if gap >= 2 then break end
        end
    end
    return first, last
end

-- the worker icon: the first run of drawn tiles PAST the panel's right border. The border is
-- where the sheet stops and the map begins (tile 0), and the check is drawn out there on its
-- own -- which is also why it only appears on rows that have a worker.
local function check_span(y, from_x)
    local w = dfhack.screen.getWindowSize()
    local x, seen_gap = from_x or 0, false
    while x < w do
        local p = dfhack.screen.readTile(x, y)
        local t = p and p.tile or 0
        if t == 0 then
            seen_gap = true
        elseif seen_gap then
            local x1 = x
            while x + 1 < w do
                local q = dfhack.screen.readTile(x + 1, y)
                if not q or (q.tile or 0) == 0 then break end
                x = x + 1
            end
            return x1, x
        end
        x = x + 1
    end
end

-- is this click on the job's own name, or on its worker icon?
local function on_row_content(x, y, name_y)
    local n1, n2 = name_span(name_y)
    if n1 and x >= n1 and x <= n2 then return true end
    local c1, c2 = check_span(y, n2 or 0)
    if c1 and x >= c1 and x <= c2 then return true end
    return false
end

-- ---- the action --------------------------------------------------------------

local SHEET_TAB_OVERVIEW = 0

local function close_sheet()
    df.global.game.main_interface.view_sheets.open = false
end

-- CLEAR THE POSITION CACHES BEFORE OPENING. DF's Overview tab draws a dwarf's noble
-- positions by taking its COUNT from `ent_vect` and its pointers from `ep_vect`, with no
-- bounds check on the second -- so the two have to agree. DF fills them in its own sheet
-- update, which has not run yet on the frame a sheet is opened by writing these fields, and
-- the pair left behind by an earlier sheet can disagree: a non-empty `ent_vect` over an
-- emptied `ep_vect` reads a freed entity_position, and DF aborts building a std::string
-- from its null name -- SIGABRT inside render, no lua error at all
-- (crashlog/crash_2026-09-15-22-46-37.txt). Emptied together they agree at zero, and
-- `last_tick_update` tells DF the caches are stale so it refills them on its next update.
local function clear_sheet_caches(vs)
    pcall(function()
        vs.ent_vect:resize(0)
        vs.ep_vect:resize(0)
        vs.ep_vect_spouse:resize(0)
        vs.last_tick_update = 0
    end)
end

local function open_sheet(unit)
    local vs = df.global.game.main_interface.view_sheets
    clear_sheet_caches(vs)
    vs.active_sheet = df.view_sheet_type.UNIT
    vs.active_id = unit.id
    vs.active_sub_tab = SHEET_TAB_OVERVIEW   -- written only as the sheet is opened
    vs.open = true                           -- ...and `open` last
end

-- THE SHEET IS OPENED ON A LATER FRAME. Closing the building sheet tears down whatever
-- view_sheets is showing, including a unit sheet opened in the same breath, so the follow
-- happens now and the sheet is handed to an overlay update -- which keeps ticking when frame
-- timers do not.
pending_sheet_id = pending_sheet_id or nil
local sheet_camera = reqscript('fort/sheet-camera')

hit_log = hit_log or {}
local HIT_LOG_MAX = 8
local function record_hit(text)
    table.insert(hit_log, ('%d/%d %s'):format(df.global.cur_year, df.global.cur_year_tick, text))
    while #hit_log > HIT_LOG_MAX do table.remove(hit_log, 1) end
end

local function goto_worker(unit)
    local x, y, z = dfhack.units.getPosition(unit)
    close_sheet()
    if x and x >= 0 then
        dfhack.gui.revealInDwarfmodeMap(xyz2pos(x, y, z), true, true)
    end
    pending_sheet_id = unit.id                -- off the map: sheet only
end

-- ---- overlay -----------------------------------------------------------------

JobWorkerClickOverlay = defclass(JobWorkerClickOverlay, overlay.OverlayWidget)
JobWorkerClickOverlay.ATTRS{
    desc = "Workshop Tasks list: click a job's row to open its worker's sheet.",
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    -- every building sheet: the Tasks list is the same list on a workshop, a furnace or a
    -- lever, and the match is by content anyway, so a sheet without one never hits
    viewscreens = 'dwarfmode/ViewSheets/BUILDING',
    frame = {w = 1, h = 1},          -- draws nothing; onInput sees the whole screen anyway
    version = 1,
}

-- THE "ADD NEW TASK" MENU IS NOT THE TASKS LIST. It draws in the same panel, on the same
-- rows, and its entries are job NAMES -- "Make pair of silk gloves" -- so a click on one of
-- them looks exactly like a click on a queued job that shares those words, and this opened
-- the worker's sheet instead of adding the task. DF fills `main_interface.building.button`
-- only while that menu is up (it is emptied the instant it closes), which is the one safe
-- test for it; see fort/workshop-tools, which sorts the same list.
local function add_task_menu_open()
    local ok, n = pcall(function() return #df.global.game.main_interface.building.button end)
    return ok and n > 0
end

function JobWorkerClickOverlay:onInput(keys)
    if not keys._MOUSE_L then return false end
    if add_task_menu_open() then return false end
    local x, y = dfhack.screen.getMousePos()
    if not x or not y then return false end
    local bld = sheet_building()
    if not bld or #bld.jobs == 0 then return false end

    -- the icon is drawn down all three lines of a row; the name is on the middle one
    local job, name_y
    for _, try_y in ipairs({y, y - 1, y + 1}) do
        job = job_on_line(bld, try_y)
        if job then name_y = try_y; break end
    end
    if not job then return false end

    local unit = job_worker(job)
    if not unit then return false end          -- nobody on it: the row is DF's business
    if not on_row_content(x, y, name_y) then return false end   -- somebody else's column

    record_hit(('click %d,%d bld=%d job=%q line=%q -> %s'):format(x, y, bld.id,
        dfhack.job.getName(job), (line_text(name_y):gsub('^%s+', ''):gsub('%s+$', '')),
        dfhack.units.getReadableName(unit)))
    goto_worker(unit)
    return true
end

-- The deferred half of the click, on plain `dwarfmode` because by the time it runs the
-- building sheet is shut and this overlay's own screen is gone.
PendingSheetOverlay = defclass(PendingSheetOverlay, overlay.OverlayWidget)
PendingSheetOverlay.ATTRS{
    desc = 'Opens the unit sheet a click on a job worker icon asked for, once the sheet closed.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function PendingSheetOverlay:overlay_onupdate()
    sheet_camera.tick()
    local id = pending_sheet_id
    if not id then return end
    pending_sheet_id = nil
    local unit = df.unit.find(id)
    if unit then
        open_sheet(unit)
        -- the camera is DF's own sheet button, pressed now the sheet is up (fort/sheet-camera):
        -- it centres the unit in the map the sheet leaves visible and follows it
        local x = dfhack.units.getPosition(unit)
        if x and x >= 0 then sheet_camera.request(unit) end
    end
end

OVERLAY_WIDGETS = {click = JobWorkerClickOverlay, sheet = PendingSheetOverlay}

if dfhack_flags.module then
    return
end

if ({...})[1] == 'log' then
    print(('clickable-job-worker: %d hit%s recorded (newest last)'):format(#hit_log, #hit_log == 1 and '' or 's'))
    for _, line in ipairs(hit_log) do print('  ' .. dfhack.df2console(line)) end
    if #hit_log == 0 then print('  nothing yet') end
    return
end

require('plugins.overlay').rescan()
print('clickable-job-worker: registered overlay fort/clickable-job-worker.click')
print("  click a job's row in a building's Tasks list to open the worker's sheet and")
print('  follow them -- the rows with a green check are the ones that have a worker.')
