-- Bar counts in the forge's "Add new task" material list, in place of "(opens menu)".
--@module = true
--[[
fort/forge-bars

The metalsmith's forge lists every metal it could work as "iron (opens menu)",
"gold (opens menu)", ... whether you own a single bar of it or not, and the only way to
find out is to open the menu or leave for the stocks screen. This overlay paints the
bar count over that "(opens menu)" tail on every row -- "iron (14 bars)", "gold (no
bars)" -- read straight from the bars on the map. Forbidden bars are not counted;
bars already claimed by a job are counted but noted: "steel (6 bars, 2 in use)".

Lives on the forge and magma forge building sheet only (the smelter lists ores and
reactions, not metals). Auto-discovered by `overlay rescan`; toggle as
`forge-bars.counts` in `gui/overlay`.

    forge-bars               print the counts for the open forge menu
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local building = df.global.game.main_interface.building
local MATSEL = df.interface_button_building_material_selectorst

local TAIL = '(opens menu)'
local PANEL_X0 = 40                    -- the building sheet is well right of centre

-- ---------------------------------------------------------------------------
-- which building, which rows
-- ---------------------------------------------------------------------------

local function forge_open()
    local bld = dfhack.gui.getSelectedBuilding(true)
    if not bld or not df.building_workshopst:is_instance(bld) then return end
    if bld.type == df.workshop_type.MetalsmithsForge or bld.type == df.workshop_type.MagmaForge then
        return bld
    end
end

-- Every button in the list is freed the instant the panel closes and DF leaves
-- `filtered_button` holding the dead pointers; `button` is cleared, so it is the
-- one safe "these pointers are live" gate.
local function list_live()
    return #building.button > 0
end

-- material name -> {mat_type, mat_index} for the rows on the open list
local function list_materials()
    local out, n = {}, 0
    if not list_live() then return out, 0 end
    local vec = building.filtered_button
    for i = 0, #vec - 1 do
        local b = vec[i]
        if MATSEL:is_instance(b) then
            local name = b.filter_str:gsub('%s*%(opens menu%)%s*$', '')
            out[name:lower()] = {mat_type = b.material, mat_index = b.matgloss}
            n = n + 1
        end
    end
    return out, n
end

-- ---------------------------------------------------------------------------
-- counting bars
-- ---------------------------------------------------------------------------

-- {['<type>:<index>'] = {n = usable, busy = claimed by a job}}
function count_bars()
    local counts = {}
    for _, it in ipairs(df.global.world.items.other.BAR) do
        local f = it.flags
        if not f.forbid and not f.garbage_collect and not f.dump then
            local k = it.mat_type .. ':' .. it.mat_index
            local c = counts[k]
            if not c then c = {n = 0, busy = 0}; counts[k] = c end
            c.n = c.n + 1
            if f.in_job then c.busy = c.busy + 1 end
        end
    end
    return counts
end

local function label(c)
    if not c or c.n == 0 then return '(no bars)' end
    local s = ('(%d bar%s'):format(c.n, c.n == 1 and '' or 's')
    if c.busy > 0 then s = s .. (', %d in use'):format(c.busy) end
    return s .. ')'
end

-- ---------------------------------------------------------------------------
-- finding the rows on screen
-- ---------------------------------------------------------------------------
-- DF gives no geometry for the list; the rows are read back off the text grid.
-- A full scan is a few thousand readTile calls, so it only runs when the list
-- changes (opened, filtered, scrolled); every other frame re-reads just the first
-- characters of each remembered row to make sure it still says what we think.

local function read_row(y, x0, x1)
    local chars = {}
    for x = x0, x1 do
        local ok, pen = pcall(dfhack.screen.readTile, x, y)
        local ch = (ok and pen and pen.ch) or 0
        chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(chars)
end

-- returns {{y, x, name, mat}, ...}: x is the column of the '(' in "(opens menu)"
local function scan_rows(mats)
    local sw, sh = dfhack.screen.getWindowSize()
    local rows = {}
    for y = 0, sh - 1 do
        local text = read_row(y, PANEL_X0, sw - 1)
        local c = text:find(TAIL, 1, true)
        if c then
            local name = text:sub(1, c - 1):match('^%s*(.-)%s*$'):lower()
            local mat = mats[name]
            if mat then
                rows[#rows + 1] = {y = y, x = PANEL_X0 + c - 1, name = name, mat = mat}
            end
        end
    end
    return rows
end

-- is the remembered row still drawn where we left it? (checks the name's start)
local function row_holds(r)
    local want = r.name:sub(1, 6)
    local x0 = r.x - #r.name - 1
    if x0 < 0 then return false end
    local got = read_row(r.y, x0, x0 + #want - 1):lower()
    return got == want
end

-- ---------------------------------------------------------------------------
-- overlay
-- ---------------------------------------------------------------------------

CountsOverlay = defclass(CountsOverlay, overlay.OverlayWidget)
CountsOverlay.ATTRS{
    desc = 'Shows how many bars of each metal you have in the forge\'s material list.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/BUILDING/Workshop',
    frame = {w = 1, h = 1},                -- painted with absolute coordinates
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function CountsOverlay:init()
    self.rows = nil
    self.counts = nil
    self.counted_at = 0
    self.sig = nil
    self.frames = 0
end

-- something about the list to notice a rebuild by: length, first and selected entry
local function list_signature()
    if not list_live() then return nil end
    local vec = building.filtered_button
    local first = #vec > 0 and vec[0].filter_str or ''
    return #vec .. '|' .. first .. '|' .. building.selected
end

function CountsOverlay:overlay_onupdate()
    if not forge_open() then self.rows = nil; return end
    local sig = list_signature()
    if not sig then self.rows, self.sig = nil, nil; return end
    local now = dfhack.getTickCount()
    -- bars come and go while the menu is up (a job finishing, hauling): recount every second
    if not self.counts or now - self.counted_at > 1000 then
        self.counts = count_bars()
        self.counted_at = now
    end
    local stale = sig ~= self.sig
    if not stale and self.rows then
        for _, r in ipairs(self.rows) do
            if not row_holds(r) then stale = true; break end
        end
    end
    -- a row can be missed on the frame the list appears (not all of it rendered yet,
    -- or a row under the mouse drawn as a tooltip): a periodic full look catches it
    self.frames = (self.frames or 0) + 1
    if stale or not self.rows or self.frames % 30 == 0 then
        self.rows = scan_rows(list_materials())
        self.sig = sig
    end
end

function CountsOverlay:onRenderFrame(dc, rect)
    if not self.rows or not self.counts then return end
    for _, r in ipairs(self.rows) do
        local c = self.counts[r.mat.mat_type .. ':' .. r.mat.mat_index]
        local text = label(c)
        -- cover the whole of "(opens menu)" even when the count is shorter
        if #text < #TAIL then text = text .. (' '):rep(#TAIL - #text) end
        local pen = (c and c.n > 0) and COLOR_WHITE or COLOR_GREY
        dfhack.screen.paintString(pen, r.x, r.y, text)
    end
end

OVERLAY_WIDGETS = {counts = CountsOverlay}

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if dfhack_flags.module then return end

if not forge_open() then
    qerror('forge-bars: open a metalsmith\'s forge or magma forge sheet first')
end
local mats, n = list_materials()
if n == 0 then
    print('forge-bars: the "Add new task" material list is not open')
    return
end
local counts = count_bars()
local names = {}
for name in pairs(mats) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    local m = mats[name]
    print(('  %-16s %s'):format(name, label(counts[m.mat_type .. ':' .. m.mat_index])))
end
