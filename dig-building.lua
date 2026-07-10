-- Left-hand building picker: while the Dig tool is active, click a building to place it.
--@module = true
--[[
Companion to dig-shapes. While NORMAL MINING MODE is active (the Dig tool selected,
main_designation_selected == DIG_DIG) on dwarfmode/Default, a picker window docks on the LEFT
listing every buildable thing -- workshops, furnaces, constructions, doors/hatches, machines,
traps, cages/restraints, military buildings, trade depot, and all furniture.

Clicking an entry drives DF's OWN build menu straight to that building's native placement action:
it drops the Dig tool, opens the build menu (the D_BUILDING toolbar key), then clicks through the
category (and subcategory) to the building by matching the on-screen button text and injecting a
real mouse click at it. So you land in the exact native placement/buildingplan flow -- including,
for a SLAB, DF's own "which slab" chooser with no buildingplan interference (nothing special is
done for slabs; the native flow already does the right thing).

  (Why drive the native menu instead of jumping straight in? In v50 the build menu is entirely
  mouse/button-driven -- the HOTKEY_BUILDING_* interface keys are NOT wired to fed input, and
  setting the build mode by hand opens an empty menu with no buttons. Clicking the rendered
  buttons is the only path that works, so we replicate the clicks.)

Layout: two columns, vertically SCROLLABLE when the list overflows. The window leaves 10 rows of
negative space at the TOP and 4 rows at the BOTTOM uncovered.

Registered automatically as overlay `dig-building.picker`. Reposition with `gui/overlay`.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local function mi() return df.global.game.main_interface end
local function scr() return dfhack.gui.getDFViewscreen(true) end
local TOP_MARGIN, BOT_MARGIN = 14, 4      -- rows of negative space kept clear, top / bottom
local LEFT_MARGIN = 8                      -- columns of negative space kept clear on the left
local WIN_W = 34                          -- window width; border + two columns inside
local COL_W = 16                          -- each column's cell width (inside the border)

-- Every buildable thing, in display order: {disp, path}. `path` is the sequence of on-screen
-- button labels to click (category -> [subcategory] -> building), matched EXACTLY against the
-- rendered menu text. `disp` is the (possibly shortened) label shown in the picker.
local ENTRIES = {
    -- Workshops (direct)
    {'Carpenter',    {'Workshops', 'Carpenter'}},
    {'Mason',        {'Workshops', 'Stoneworker'}},
    {'Craftsdwarf',  {'Workshops', 'Crafts'}},
    {'Jeweler',      {'Workshops', 'Jeweler'}},
    {'Metalsmith',   {'Workshops', 'Metalsmith'}},
    {'Magma forge',  {'Workshops', 'Magma forge'}},
    {'Mechanic',     {'Workshops', 'Mechanic'}},
    {'Siege wksp',   {'Workshops', 'Siege'}},
    {'Bowyer',       {'Workshops', 'Bowyer'}},
    {'Ashery',       {'Workshops', 'Ashery'}},
    {'Soap maker',   {'Workshops', "Soap Maker's Workshop"}},
    {'Screw press',  {'Workshops', 'Screw Press'}},
    -- Workshops / Clothing and leather (subcategory -- pick the shop natively)
    {'Cloth/leather',{'Workshops', 'Clothing and leather'}},
    -- Workshops / Farming
    {'Farm plot',    {'Workshops', 'Farming', 'Farm plot'}},
    {'Still',        {'Workshops', 'Farming', 'Still'}},
    {'Butcher',      {'Workshops', 'Farming', 'Butcher'}},
    {'Tanner',       {'Workshops', 'Farming', 'Tanner'}},
    {'Fishery',      {'Workshops', 'Farming', 'Fishery'}},
    {'Kitchen',      {'Workshops', 'Farming', 'Kitchen'}},
    {'Farmer',       {'Workshops', 'Farming', 'Farmer'}},
    -- Workshops / Furnaces
    {'Wood furnace', {'Workshops', 'Furnaces', 'Wood furnace'}},
    {'Smelter',      {'Workshops', 'Furnaces', 'Smelter'}},
    {'Glass furnace',{'Workshops', 'Furnaces', 'Glass furnace'}},
    {'Kiln',         {'Workshops', 'Furnaces', 'Kiln'}},
    {'Magma smelter',{'Workshops', 'Furnaces', 'Magma smelter'}},
    {'Magma glass',  {'Workshops', 'Furnaces', 'Magma glass'}},
    {'Magma kiln',   {'Workshops', 'Furnaces', 'Magma kiln'}},
    -- Furniture
    {'Bed',          {'Furniture', 'Bed'}},
    {'Chair',        {'Furniture', 'Chair'}},
    {'Table',        {'Furniture', 'Table'}},
    {'Chest',        {'Furniture', 'Chest'}},
    {'Cabinet',      {'Furniture', 'Cabinet'}},
    {'Coffin',       {'Furniture', 'Burial'}},
    {'Statue',       {'Furniture', 'Statue'}},
    {'Slab',         {'Furniture', 'Slab'}, {noplan = true}},   -- native slab chooser (keep-building auto-toggle disabled: can't read its state yet)
    {'Traction bed', {'Furniture', 'Traction bench'}},
    {'Bookcase',     {'Furniture', 'Bookcase'}},
    {'Display case', {'Furniture', 'Display'}},
    {'Offering',     {'Furniture', 'Offering place'}},
    {'Instrument',   {'Furniture', 'Instrument'}},
    -- Doors / hatches
    {'Door',         {'Doors/hatches', 'Door'}},
    {'Hatch',        {'Doors/hatches', 'Hatch'}},
    -- Constructions (sorted alphabetically by label -- easier to find a known name)
    {'Bridge',       {'Constructions', 'Bridge'}},
    {'Dirt road',    {'Constructions', 'Dirt road'}},
    {'Floor',        {'Constructions', 'Floor'}},
    {'Floor bars',   {'Constructions', 'Floor bars'}},
    {'Floor grate',  {'Constructions', 'Floor grate'}},
    {'Fortificatn',  {'Constructions', 'Fortification'}},
    {'Gem window',   {'Constructions', 'Gem window'}},
    {'Glass window', {'Constructions', 'Glass window'}},
    {'Paved road',   {'Constructions', 'Paved road'}},
    {'Ramp',         {'Constructions', 'Ramp'}},
    {'Reinf. wall',  {'Constructions', 'Reinforced Wall'}},
    {'Stairs',       {'Constructions', 'Stairs'}},
    {'Support',      {'Constructions', 'Support'}},
    {'Track',        {'Constructions', 'Track'}},
    {'Track stop',   {'Constructions', 'Track stop'}},
    {'Vert bars',    {'Constructions', 'Vertical bars'}},
    {'Wall',         {'Constructions', 'Wall'}},
    {'Wall grate',   {'Constructions', 'Wall grate'}},
    -- Machines / fluids
    {'Lever',        {'Machines/fluids', 'Lever'}},
    {'Well',         {'Machines/fluids', 'Well'}},
    {'Floodgate',    {'Machines/fluids', 'Floodgate'}},
    {'Screw pump',   {'Machines/fluids', 'Screw pump'}},
    {'Water wheel',  {'Machines/fluids', 'Water wheel'}},
    {'Windmill',     {'Machines/fluids', 'Windmill'}},
    {'Gear assembly',{'Machines/fluids', 'Gear assembly'}},
    {'Horiz axle',   {'Machines/fluids', 'Horizontal axle'}},
    {'Vert axle',    {'Machines/fluids', 'Vertical axle'}},
    {'Millstone',    {'Machines/fluids', 'Millstone'}},
    {'Rollers',      {'Machines/fluids', 'Rollers'}},
    -- Cages / restraints
    {'Cage',         {'Cages/restraints', 'Cage'}},
    {'Restraint',    {'Cages/restraints', 'Rope/chain'}},
    {'Animal trap',  {'Cages/restraints', 'Animal trap'}},
    -- Traps
    {'Pressure plt', {'Traps', 'Pressure plate'}},
    {'Cage trap',    {'Traps', 'Cage'}},
    {'Stonefall',    {'Traps', 'Stone-fall'}},
    {'Weapon trap',  {'Traps', 'Weapon'}},
    {'Spike trap',   {'Traps', 'Upright weapon/spike'}},
    -- Military
    {'Archery targ', {'Military', 'Archery target'}},
    {'Weapon rack',  {'Military', 'Weapon rack'}},
    {'Armor stand',  {'Military', 'Armor stand'}},
    {'Ballista',     {'Military', 'Ballista'}},
    {'Catapult',     {'Military', 'Catapult'}},
    {'Bolt thrower', {'Military', 'Bolt thrower'}},
    -- direct (no submenu)
    {'Trade depot',  {'Trade depot'}},
}

-- ---- native-menu driver ------------------------------------------------------

-- read one screen row as a string
local function readrow(y, W)
    local row = {}
    for x = 0, W - 1 do
        local ok, t = pcall(dfhack.screen.readTile, x, y)
        local c = (ok and t and t.ch) or 32
        if c < 32 or c > 126 then c = 32 end
        row[x + 1] = string.char(c)
    end
    return table.concat(row)
end

-- split a row into button segments (labels are separated by 2+ spaces; a label's own internal
-- single spaces stay intact). Returns {text, start_x(0-indexed)} for each segment.
local function segments(s)
    local out, x = {}, 1
    while x <= #s do
        local a = s:find('%S', x); if not a then break end
        local b = s:find('%s%s', a)
        local e = b and (b - 1) or #s
        out[#out + 1] = {text = (s:sub(a, e):gsub('%s+$', '')), sx = a - 1}
        x = e + 1
    end
    return out
end

-- find the button whose text is EXACTLY `label` (in the menu region, x>=40) and inject a click on
-- its center. Returns true if clicked. Exact-segment match so "Wall" != "Reinforced Wall".
local function click_exact(label)
    local gps = df.global.gps
    local W, H = gps.dimx, gps.dimy
    for y = 0, H - 1 do
        local s = readrow(y, W)
        for _, seg in ipairs(segments(s)) do
            if seg.text == label and seg.sx >= 40 then
                gps.mouse_x = seg.sx + math.floor(#label / 2)
                gps.mouse_y = y
                gui.simulateInput(scr(), '_MOUSE_L')
                return true
            end
        end
    end
    return false
end

-- buildingplan's placement overlay has a persistent "show Planner / hide Planner" toggle. When
-- it reads "show Planner" the planner is HIDDEN (regular placement); "hide Planner" means it's
-- SHOWN (the buildingplan filter panel). Ensure it matches `want`: click the toggle only when the
-- current state differs. The state persists across placements, so this usually no-ops after the
-- first building. Slabs pass want=false so DF's own "which slab" chooser is used instead.
local function planner_toggle(want)
    local gps = df.global.gps
    local W, H = gps.dimx, gps.dimy
    for y = 0, H - 1 do
        local s = readrow(y, W)
        local hide = s:find('hide Planner', 1, true)
        local show = s:find('show Planner', 1, true)
        if hide or show then
            local is_shown = hide ~= nil
            if is_shown ~= want then
                local br = s:find('%[', (hide or show))   -- the [ ] toggle after the label
                if br then gps.mouse_x = br; gps.mouse_y = y; gui.simulateInput(scr(), '_MOUSE_L') end
            end
            return
        end
    end
end

-- "Keep building after placement" is a NATIVE placement checkbox whose box sits 5 columns LEFT of
-- its label. We can click it but can't read its on/off state (it's a graphic sprite that reads as
-- blank), so we click it once. Anchored to the label's LIVE position (found by text) so it survives
-- screen resizes. Returns true once the label was found + clicked.
local function keep_building_toggle()
    local gps = df.global.gps
    local W, H = gps.dimx, gps.dimy
    for y = 0, H - 1 do
        local i = readrow(y, W):find('Keep building after placement', 1, true)
        if i then
            gps.mouse_x = (i - 1) - 5   -- checkbox is 5 cols left of the label start
            gps.mouse_y = y
            gui.simulateInput(scr(), '_MOUSE_L')
            return true
        end
    end
    return false
end

-- tracks a picker-initiated build flow so we can return to the Dig screen when it closes:
-- 'pending' (nav started) -> 'armed' (build menu seen open) -> back to Default => re-enter dig.
local return_state = 'idle'

-- open the build menu and click through `path` (category -> [subcategory] -> building). Each step
-- is deferred a few frames so DF re-renders the next level before we read/click it. Fed keys and
-- injected clicks must run inside DF's frame loop, hence the timeouts. Once in placement, force the
-- buildingplan planner on (off for `noplan` items, e.g. slabs), and for `buildmore` items also turn
-- on "keep building after placement". Two attempts absorb render lag.
local function navigate(path, noplan, buildmore)
    mi().main_designation_selected = df.main_designation_type.NONE   -- drop the Dig tool
    return_state = 'pending'
    dfhack.timeout(1, 'frames', function() gui.simulateInput(scr(), 'D_BUILDING') end)
    local d = 4
    for _, label in ipairs(path) do
        local L = label
        dfhack.timeout(d, 'frames', function() click_exact(L) end)
        d = d + 3
    end
    local want = not noplan
    local bm_done = false
    local function settle()
        planner_toggle(want)   -- idempotent (reads state), safe to run twice
        -- keep-building can't be read, so click it exactly once (the first settle where the label
        -- has rendered); the flag stops the second attempt from toggling it back off
        if buildmore and not bm_done and keep_building_toggle() then bm_done = true end
    end
    dfhack.timeout(d + 4, 'frames', settle)
    dfhack.timeout(d + 9, 'frames', settle)
end

-- ---- overlay -----------------------------------------------------------------

DigBuilding = defclass(DigBuilding, overlay.OverlayWidget)
DigBuilding.ATTRS{
    desc = 'While the Dig tool is active, a left-hand picker to place any building.',
    default_pos = {x = LEFT_MARGIN + 1, y = TOP_MARGIN + 1},   -- 5 cols in, 14 rows down
    default_enabled = true,
    -- broad 'dwarfmode' match: selecting the Dig tool switches focus to dwarfmode/Designate/DIG_DIG,
    -- so a narrow 'dwarfmode/Default' overlay would never render on the dig screen. Visibility is
    -- gated to dig_active() below, so it only actually shows while the Dig tool is selected.
    viewscreens = 'dwarfmode',
    frame = {w = WIN_W, h = 10},                  -- h recomputed each update (full height - margins)
    version = 3,                                   -- bumped: moved right / panel border (resets saved pos)
    overlay_onupdate_max_freq_seconds = 0,
}

local function dig_active()
    return mi().main_designation_selected == df.main_designation_type.DIG_DIG
end

function DigBuilding:init()
    self.scroll = 0
    self.cols = 2
end

-- rows available for entries = window height minus the top and bottom border rows
function DigBuilding:list_rows()
    return math.max(1, self.frame.h - 2)
end

function DigBuilding:max_scroll()
    local lines = math.ceil(#ENTRIES / self.cols)
    return math.max(0, lines - self:list_rows())
end

function DigBuilding:overlay_onupdate()
    self.visible = dig_active()
    -- Size the panel to EXACTLY fit the list, and adapt to the screen. Start at 2 columns; if the
    -- list is taller than the space between the top/bottom margins, add columns until it fits (up to
    -- what the screen width allows). If it still can't fit, cap the height and let it scroll.
    local gps = df.global.gps
    local avail_rows = math.max(1, gps.dimy - TOP_MARGIN - BOT_MARGIN - 2)   -- entry rows (excl. borders)
    local max_cols = math.max(1, math.floor((gps.dimx - LEFT_MARGIN - 2) / COL_W))
    local cols = math.min(max_cols, math.max(2, math.ceil(#ENTRIES / avail_rows)))
    self.cols = cols
    local rows = math.min(math.ceil(#ENTRIES / cols), avail_rows)
    self.frame.w = cols * COL_W + 2
    self.frame.h = rows + 2
    if self.scroll > self:max_scroll() then self.scroll = self:max_scroll() end
    -- return to the Dig screen once a picker-initiated build flow has fully closed
    if return_state ~= 'idle' then
        local foc = dfhack.gui.getCurFocus(true)[1] or ''
        if return_state == 'pending' then
            if foc:find('dwarfmode/Building', 1, true) then return_state = 'armed'
            elseif dig_active() then return_state = 'idle' end   -- nav never opened the menu; reset
        elseif return_state == 'armed' then
            if foc == 'dwarfmode/Default'
                    and mi().bottom_mode_selected == df.main_bottom_mode_type.NONE then
                mi().main_designation_selected = df.main_designation_type.DIG_DIG
                return_state = 'idle'
            end
        end
    end
end

-- draw the picker as a bordered, opaque panel (so it doesn't blend into the map)
function DigBuilding:onRenderBody(dc)
    if not self.visible then return end
    local w, h, cols = self.frame.w, self.frame.h, self.cols
    local BG = {fg = COLOR_GREY, bg = COLOR_BLACK}
    for r = 0, h - 1 do dc:seek(0, r):pen(BG):string(string.rep(' ', w)) end   -- opaque background
    local hbar = string.rep(string.char(196), w - 2)                           -- box-drawing border
    dc:seek(0, 0):pen(BG):string(string.char(218) .. hbar .. string.char(191))
    dc:seek(0, h - 1):pen(BG):string(string.char(192) .. hbar .. string.char(217))
    for r = 1, h - 2 do
        dc:seek(0, r):pen(BG):string(string.char(179))
        dc:seek(w - 1, r):pen(BG):string(string.char(179))
    end
    dc:seek(2, 0):pen(COLOR_WHITE):string(' Build ')                           -- title on the top border
    local ms = self:max_scroll()
    if ms > 0 then                                                             -- scroll controls on top border
        dc:seek(w - 10, 0):pen(self.scroll > 0 and COLOR_LIGHTCYAN or COLOR_DARKGREY):string(' [-] ')
        dc:seek(w - 5, 0):pen(self.scroll < ms and COLOR_LIGHTCYAN or COLOR_DARKGREY):string('[+] ')
    end
    for r = 0, self:list_rows() - 1 do                                         -- entries inside the border
        local line = self.scroll + r
        for c = 0, cols - 1 do
            local e = ENTRIES[line * cols + c + 1]
            if e then dc:seek(1 + c * COL_W, r + 1):pen(COLOR_WHITE):string(e[1]:sub(1, COL_W - 1)) end
        end
    end
end

-- body-local (x,y): row 0 & h-1 are borders; entries live in rows 1..h-2, cols 1..cols*COL_W
function DigBuilding:entry_at(x, y)
    if y < 1 or y >= self.frame.h - 1 then return nil end
    local r = y - 1
    if r >= self:list_rows() or x < 1 or x > self.cols * COL_W then return nil end
    local c = math.floor((x - 1) / COL_W)
    return ENTRIES[(self.scroll + r) * self.cols + c + 1]
end

function DigBuilding:onInput(keys)
    if not self.visible then return false end
    if keys.CONTEXT_SCROLL_UP then self.scroll = math.max(0, self.scroll - 1); return true end
    if keys.CONTEXT_SCROLL_DOWN then self.scroll = math.min(self:max_scroll(), self.scroll + 1); return true end
    if keys._MOUSE_L then
        local x, y = self:getMousePos()
        if not x then return false end        -- click outside the window: pass through to the map
        local w = self.frame.w
        if y == 0 then                        -- scroll controls on the title/top border
            if x >= w - 10 and x <= w - 6 then self.scroll = math.max(0, self.scroll - 1)
            elseif x >= w - 5 and x <= w - 2 then self.scroll = math.min(self:max_scroll(), self.scroll + 1) end
            return true
        end
        local e = self:entry_at(x, y)
        if e then navigate(e[2], e[3] and e[3].noplan, e[3] and e[3].buildmore) end
        return true                           -- consume any click within the window
    end
    return false
end

OVERLAY_WIDGETS = {picker = DigBuilding}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dig-building: left-hand building picker (active while the Dig tool is selected).')
