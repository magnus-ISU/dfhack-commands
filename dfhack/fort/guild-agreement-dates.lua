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
count months in your head. This adds both halves of the answer:

    Build temple, 321 days
    The Communion of Coal
    8th Galena (6), 109

The count is the days left of the year you were given. The number in brackets is the month,
counted from Granite, so you can compare it against today's date without knowing the calendar
by heart.

The notice is redrawn where DF drew it, found by reading the screen, so it follows the notice
rather than assuming a position: it moves with the window, and when something covers the
notice -- the squads panel takes that corner -- there is nothing to find and nothing is drawn.

What it costs per frame: a cached check for an outstanding agreement, and, only while one is
outstanding, a re-read of the two lines it already found (about fifty tiles). The whole-screen
sweep that locates the notice runs at most twice a second, and only when the lines it knew
about stop reading as a notice.

Long names are shortened to fit the corner rather than running off the edge: a guildhall
agreement reads `Guildhall, 321 days` and a grand guildhall `Grand hall, 321 days`.
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

-- Names too long for the corner. DF's own wording is kept where it fits; these are the two that
-- do not, cut to the shortest thing that still reads as the building it is.
local SHORT_NAME = {
    ['Build grand guildhall'] = 'Grand hall',
    ['Build guildhall'] = 'Guildhall',
    ['Grand guildhall'] = 'Grand hall',
    ['Guildhall'] = 'Guildhall',
}

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

-- Find the notice: the date line, and the job line two rows above it. Returns the screen column
-- the notice starts at, the job row, and the parsed date. The search is right of centre, where
-- DF puts it, and stops at the first date line that has two lines above it.
local function find_notice()
    local sw, sh = dfhack.screen.getWindowSize()
    local x1 = math.floor(sw / 2)
    for y = 2, sh - 1 do
        local text = line_at(y, x1, sw - 1)
        local day, month, year, month_name = parse_date(text)
        if day then
            local job = line_at(y - 2, x1, sw - 1):gsub('%s+$', '')
            local col = job:find('%S')
            if col and #job > 0 then
                return x1 + col - 1, y - 2, {day = day, month = month, year = year,
                                             month_name = month_name,
                                             job = strip_annotation(job:gsub('^%s+', ''))}
            end
        end
    end
end

-- ---- the arithmetic -----------------------------------------------------------

-- days left of the year the fort was given, from the date the agreement was struck
function days_left(date)
    local made = (date.year * DAYS_PER_YEAR + (date.month - 1) * DAYS_PER_MONTH + (date.day - 1))
    local now_days = df.global.cur_year * DAYS_PER_YEAR
        + math.floor((df.global.cur_year_tick or 0) / TICKS_PER_DAY)
    return made + GRACE_DAYS - now_days
end

-- "Build temple, 321 days", shortened if it would run off the edge
function job_line(date, width)
    local name = SHORT_NAME[date.job] or date.job
    local left = days_left(date)
    local suffix = left >= 0 and (', %d day%s'):format(left, left == 1 and '' or 's')
                              or (', %d day%s over'):format(-left, left == -1 and '' or 's')
    if #name + #suffix > width then
        name = SHORT_NAME[date.job:gsub('^Build ', '')] or name
    end
    if #name + #suffix > width then
        name = name:sub(1, math.max(1, width - #suffix))
    end
    return name .. suffix
end

-- "8th Galena (6), 109"
function date_line(date)
    local suffix = 'th'
    local d = date.day
    if d % 10 == 1 and d ~= 11 then suffix = 'st'
    elseif d % 10 == 2 and d ~= 12 then suffix = 'nd'
    elseif d % 10 == 3 and d ~= 13 then suffix = 'rd' end
    return ('%d%s %s (%d), %d'):format(d, suffix, date.month_name, date.month, date.year)
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
    frame = {w = 26, h = 3},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function GuildAgreementOverlay:init()
    self:addviews{
        widgets.Label{view_id = 'job', frame = {t = 0, l = 0},
                      text = '', text_pen = COLOR_LIGHTCYAN},
        widgets.Label{view_id = 'date', frame = {t = 2, l = 0},
                      text = '', text_pen = COLOR_GREY},
    }
end

-- Re-find the notice on a slow tick: it appears and disappears with the agreement and moves with
-- the window, and a full screen read is not something to do every frame. A cheap probe of the
-- date line we already found keeps the common case to a dozen tile reads.
function GuildAgreementOverlay:overlay_onupdate()
    -- the cheap gate first: no agreement, no notice, nothing to read
    if not agreement_outstanding() then
        self.col, self.date_row, self.visible = nil, nil, false
        return
    end
    local sw = dfhack.screen.getWindowSize()
    -- Cheap path: the notice is where it was last time. Re-read its two lines rather than trust
    -- a cached copy -- the day rolls over, and the agreement itself can be replaced by another.
    if self.col and self.date_row then
        local date = self:read_notice(self.col, self.date_row, sw)
        if date then self:show_notice(date, sw); return end
    end
    -- Otherwise look for it again, at most twice a second: a whole-screen read is not something
    -- to do every frame, and most frames have no agreement outstanding at all.
    local now = dfhack.getTickCount()
    if self.scan_ms and now >= self.scan_ms and now - self.scan_ms < 500 then
        self.visible = false
        return
    end
    self.scan_ms = now
    local col, row, date = find_notice()
    if not col then
        self.col, self.date_row, self.visible = nil, nil, false
        return
    end
    self.col, self.date_row = col, row + 2
    -- laid out against the interface rect, like every other snapping overlay here; the widget
    -- renders into the FULL painter (see fullscreen above), and on this build the two rects are
    -- the same screen, so the offsets line up
    local ir = gui.get_interface_rect()
    self.frame = {w = self.frame.w, h = self.frame.h, l = col - ir.x1, t = row - ir.y1}
    self:updateLayout(gui.ViewRect{rect = ir})
    self:show_notice(date, sw)
end

-- the notice as it reads on screen right now at this position, or nil if it is gone
function GuildAgreementOverlay:read_notice(col, date_row, sw)
    local day, month, year, month_name = parse_date(line_at(date_row, col, sw - 1))
    if not day then return nil end
    local job = line_at(date_row - 2, col, sw - 1):gsub('%s+$', ''):gsub('^%s+', '')
    if #job == 0 then return nil end
    return {day = day, month = month, year = year, month_name = month_name,
            job = strip_annotation(job)}
end

function GuildAgreementOverlay:show_notice(date, sw)
    self.visible = true
    local width = math.max(10, sw - self.col)
    self.subviews.job:setText(job_line(date, width))
    self.subviews.date:setText(date_line(date))
end

OVERLAY_WIDGETS = {notice = GuildAgreementOverlay}

if dfhack_flags and dfhack_flags.module then return end

local col, row, date = find_notice()
if not date then
    print('guild-agreement-dates: no agreement notice on screen right now.')
    print('  It shows on the map view while a temple or guildhall agreement is outstanding.')
    return
end
print(('guild-agreement-dates: %s'):format(job_line(date, 26)))
print(('  %s'):format(date_line(date)))
print(('  (notice found at column %d, row %d)'):format(col, row))
