-- Put the deadline on the map view's agreement notice: how many days are left, and the month
-- as a number.
--@module = true
--[[
guild-agreement-dates

When you agree to build a temple or a guildhall, DF parks a three-line notice at the right of
the map view:

    Build temple
    The Communion of Coal
    8th Galena, 109

That date is when the agreement was MADE, and the petitioner expects the location within a
year of it -- which the notice never says, so the only way to know how long you have is to
count months in your head. This puts the count on the END OF DF'S OWN FIRST LINE:

    Build temple, 321 days
    The Communion of Coal
    8th Galena, 109

ON THE JOB LINE, NOT UNDER THE NOTICE. DF STACKS the notices when more than one agreement is
outstanding -- three rows each, one directly under the last -- so a count on a line of its own
lands in the gap between two notices and belongs visibly to neither. On the job line it can only
be read as the deadline for the thing named beside it, and every notice on screen gets its own.

The annotation is written straight onto DF's line with the pen read off that line, so it looks
like part of the notice rather than something stuck to it, and it is written every frame: DF
paints the notice late -- later than the overlay pass -- which is what the `fullscreen` attribute
below answers.

The notices are found by reading the screen, so the counts follow them: they move with the
window, and when something covers the corner -- the squads panel takes it -- there is nothing to
find and nothing is drawn. The search only ever looks in the right-edge band DF hangs the notice
off, and only at lines that read as `Build ...`, so a window that happens to show a date
somewhere else on screen -- `gui/autochop` did exactly this -- can never be mistaken for it.

What it costs per frame: a cached check for an outstanding agreement, and, only while one is
outstanding, a re-read of the two lines it already found (about fifty tiles). The whole-screen
sweep that locates the notice runs at most twice a second, and only when the lines it knew
about stop reading as a notice.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local DAYS_PER_MONTH = 28
local MONTHS_PER_YEAR = 12
local DAYS_PER_YEAR = DAYS_PER_MONTH * MONTHS_PER_YEAR       -- 336
local TICKS_PER_DAY = 1200
-- how long a petitioner waits for the location they agreed to. DF does not store a deadline --
-- the agreement carries only the date it was struck -- so the year is the rule, not a field.
local GRACE_DAYS = DAYS_PER_YEAR

local MONTHS = {
    'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena',
    'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian',
}
local MONTH_NUM = {}
for i, name in ipairs(MONTHS) do MONTH_NUM[name] = i end

-- ---- when to look at all -------------------------------------------------------
--
-- What runs every frame is the question that matters. The notice only exists while this site has
-- an outstanding Location agreement -- a temple or guildhall someone petitioned for -- so that is
-- the tell, and it is answered from data rather than from the screen. The agreement list is
-- world-wide and long (hundreds of entries on an old world), so the answer is cached for a couple
-- of seconds; agreements are struck a few times a year, not a few times a second.
--
-- With no agreement outstanding the per-frame cost is one clock read and a compare. With one, it
-- is a re-read of the two lines already located, about fifty tiles. The whole-screen sweep only
-- happens when the notice has moved or first appeared, and never more than twice a second.
local AGREEMENT_CACHE_MS = 2000
local agreement_cache = {ms = nil, open = false}

local function agreement_outstanding()
    local now = dfhack.getTickCount()
    if agreement_cache.ms and now >= agreement_cache.ms
        and now - agreement_cache.ms < AGREEMENT_CACHE_MS then
        return agreement_cache.open
    end
    local site_id = df.global.plotinfo.site_id
    local open = false
    for _, a in ipairs(df.global.world.agreements.all) do
        for _, d in ipairs(a.details) do
            if d.type == df.agreement_details_type.Location
                and d.data.Location.site == site_id then
                open = true
                break
            end
        end
        if open then break end
    end
    agreement_cache.ms, agreement_cache.open = now, open
    return open
end

-- ---- reading the notice off the screen ---------------------------------------

local function line_at(y, x1, x2)
    local chars = {}
    for x = x1, x2 do
        local ok, pen = pcall(dfhack.screen.readTile, x, y)
        local ch = (ok and pen and pen.ch) or 0
        chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(chars)
end

-- Parse "8th Galena, 109" -> day, month index (1-12), year. nil when the line is anything else.
--
-- IT MUST ALSO PARSE ITS OWN OUTPUT. Once this overlay draws, the cells it re-reads next frame
-- hold "8th Galena (6), 109", not DF's line -- so a pattern that only matched DF's spelling saw
-- the notice vanish the moment it was annotated, hid itself, let DF redraw, found it again, and
-- flickered at frame rate. The bracketed month is therefore optional here, and the job line is
-- stripped of its own ", N days" suffix below, which makes both reads idempotent.
local function parse_date(text)
    local day, month, year = text:match('(%d+)%a%a%s+(%a+)%s*%(?%d*%)?,%s*(%d+)')
    if not day then return nil end
    local m = MONTH_NUM[month]
    if not m then return nil end
    return tonumber(day), m, tonumber(year), month
end

-- the job name as DF wrote it, with any annotation of ours taken back off
local function strip_annotation(job)
    return (job:gsub(',%s*%d+%s+days?%s*o?v?e?r?%s*$', ''))
end

-- WHERE THE NOTICE CAN BE, and nowhere else.
--
-- DF hangs the notice off the RIGHT EDGE of the interface, a fixed 26 columns wide, in the strip
-- below the map's top-right readouts. The search is confined to that band, with a few columns of
-- slack, because a search that is not confined finds the wrong thing: any window that happens to
-- draw a date with a line two rows above it reads as a notice -- `gui/autochop` was the one that
-- did it -- and the annotation then lands in the middle of that window. Worse, it STICKS: the
-- overlay parses its own output, so once it has drawn two lines somewhere, the thing it finds
-- next frame is itself, and it never comes back on its own.
local NOTICE_WIDTH = 26
local NOTICE_SLACK = 4          -- room for a build where DF hangs it a column or two differently

-- the columns the notice may occupy, inclusive
local function notice_band()
    local ir = gui.get_interface_rect()
    return math.max(ir.x1, ir.x2 - NOTICE_WIDTH - NOTICE_SLACK + 1), ir.x2
end

-- Is this DF's job line? The notice names a building to put up, so it starts with "Build" --
-- and so does our own annotated version of it, which has to keep reading as a notice. Anything
-- else in the band is somebody else's window, not an agreement.
local function is_job_line(job)
    return job:lower():find('^build %a') ~= nil
end

-- Find the notices: a date line, and the job line two rows above it. Returns one entry per
-- notice on screen -- DF stacks them when more than one agreement is outstanding, and each has
-- its own deadline. Only the right-edge band is searched, and only a "Build ..." line counts.
local function find_notices()
    local _, sh = dfhack.screen.getWindowSize()
    local x1, x2 = notice_band()
    local out = {}
    for y = 2, sh - 1 do
        local text = line_at(y, x1, x2)
        local day, month, year, month_name = parse_date(text)
        if day then
            local job = line_at(y - 2, x1, x2):gsub('%s+$', '')
            local col = job:find('%S')
            job = strip_annotation(job:gsub('^%s+', ''))
            if col and is_job_line(job) then
                out[#out + 1] = {col = x1 + col - 1, job_row = y - 2, date_row = y,
                                 date = {day = day, month = month, year = year,
                                         month_name = month_name, job = job}}
            end
        end
    end
    return out
end

-- ---- the arithmetic -----------------------------------------------------------

-- days left of the year the fort was given, from the date the agreement was struck
function days_left(date)
    local made = (date.year * DAYS_PER_YEAR + (date.month - 1) * DAYS_PER_MONTH + (date.day - 1))
    local now_days = df.global.cur_year * DAYS_PER_YEAR
        + math.floor((df.global.cur_year_tick or 0) / TICKS_PER_DAY)
    return made + GRACE_DAYS - now_days
end

-- What gets appended to the job line: ", 321 days", or ", 12 days over" once the year has run
-- out. It reads as part of DF's own line -- "Build temple, 321 days" -- which is the whole point
-- of putting it there: with two agreements outstanding DF stacks the notices, and a number on a
-- line of its own sits between two of them belonging visibly to neither.
function annotation_suffix(date)
    local left = days_left(date)
    return left >= 0
        and (', %d day%s'):format(left, left == 1 and '' or 's')
        or (', %d day%s over'):format(-left, left == -1 and '' or 's')
end

-- the same thing as a sentence, for the command line
function annotation_line(date)
    local left = days_left(date)
    return left >= 0
        and ('%d day%s left (month %d)'):format(left, left == 1 and '' or 's', date.month)
        or ('%d day%s over (month %d)'):format(-left, left == -1 and '' or 's', date.month)
end

-- ---- the overlay --------------------------------------------------------------

GuildAgreementOverlay = defclass(GuildAgreementOverlay, overlay.OverlayWidget)
GuildAgreementOverlay.ATTRS{
    desc = 'Adds days-left and the month number to the map view agreement notice.',
    default_pos = {x = -26, y = 20},
    default_enabled = true,
    -- DF keeps drawing the notice behind the unit sheets, the info screens and the combat log,
    -- so the annotation has to be registered for those too or it vanishes the moment one opens.
    -- A bare 'dwarfmode' does NOT work here -- the overlay only ever rendered this widget for
    -- explicit focus strings -- so they are listed.
    viewscreens = {'dwarfmode/Default', 'dwarfmode/Squads', 'dwarfmode/ViewSheets',
                   'dwarfmode/AnnouncementAlert', 'dwarfmode/Info'},
    -- FULLSCREEN IS NOT COSMETIC HERE. DF paints this notice LATE -- later than the overlay pass
    -- for the map view -- so a normal widget writing those cells is wiped by DF's own redraw of
    -- the whole three-line block, including the columns past the end of its text. Rendering into
    -- the full painter lands on top of it. Everything else about the widget was already right;
    -- this one attribute is the difference between the annotation showing and vanishing.
    fullscreen = true,
    frame = {w = NOTICE_WIDTH, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

-- One label per notice, laid over the end of DF's own job line.
--
-- The annotation is drawn by LABEL SUBVIEWS rather than by painting in `onRenderBody`: measured
-- on this build, a widget with no subviews renders nothing at all from its own body -- the same
-- text through a label appears exactly where it was asked for. So the labels are the mechanism,
-- and everything else here is just keeping their frames on top of lines DF moves around.
local MAX_NOTICES = 8

function GuildAgreementOverlay:init()
    self.notices = {}
    for i = 1, MAX_NOTICES do
        self:addviews{
            widgets.Label{view_id = 'note' .. i, frame = {t = 0, l = 0, h = 1},
                          text = '', visible = false},
        }
    end
end

-- Lay the widget over every notice on screen -- from the first job line to the last -- and put a
-- label at the end of each one. The frame has to cover them all: a label is clipped to it.
function GuildAgreementOverlay:layout_over_notices()
    local ir = gui.get_interface_rect()
    local top, bottom, left
    for _, n in ipairs(self.notices) do
        if not top or n.job_row < top then top = n.job_row end
        if not bottom or n.job_row > bottom then bottom = n.job_row end
        if not left or n.col < left then left = n.col end
    end
    if not top then return false end
    self.frame = {l = left - ir.x1, t = top - ir.y1,
                  w = ir.x2 - left + 1, h = bottom - top + 1}
    for i = 1, MAX_NOTICES do
        local label, n = self.subviews['note' .. i], self.notices[i]
        if not n then
            label.visible = false
        else
            local x = n.col + #n.date.job
            local room = ir.x2 - x + 1
            label.visible = room > 0
            if label.visible then
                -- DF's own pen for that line, so the count reads as part of the notice rather
                -- than as something stuck to it
                local p = dfhack.screen.readTile(n.col, n.job_row)
                label.text_pen = (p and p.fg) and {fg = p.fg, bg = p.bg, bold = p.bold}
                    or COLOR_LIGHTCYAN
                label.frame.t = n.job_row - top
                label.frame.l = x - left
                label:setText(annotation_suffix(n.date):sub(1, room))
            end
        end
    end
    self:updateLayout(gui.ViewRect{rect = ir})
    return true
end

-- the notice as it reads on screen right now at this position, or nil if it is gone
function GuildAgreementOverlay:read_notice(col, date_row)
    local x1, x2 = notice_band()
    -- a window resize moves the band; a column outside it is last frame's answer, not this one's
    if col < x1 or col > x2 then return nil end
    local day, month, year, month_name = parse_date(line_at(date_row, col, x2))
    if not day then return nil end
    local job = strip_annotation(line_at(date_row - 2, col, x2):gsub('%s+$', ''):gsub('^%s+', ''))
    if not is_job_line(job) then return nil end
    return {day = day, month = month, year = year, month_name = month_name, job = job}
end

OVERLAY_WIDGETS = {notice = GuildAgreementOverlay}

if dfhack_flags and dfhack_flags.module then return end

local notices = find_notices()
if #notices == 0 then
    print('guild-agreement-dates: no agreement notice on screen right now.')
    print('  It shows on the map view while a temple or guildhall agreement is outstanding.')
    return
end
for _, n in ipairs(notices) do
    local d = n.date
    print(('guild-agreement-dates: %s -- %s'):format(d.job, annotation_line(d)))
    print(('  agreed %d %s, %d'):format(d.day, d.month_name, d.year))
    print(('  (notice found at column %d, row %d)'):format(n.col, n.job_row))
end
