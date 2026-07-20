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

-- does overlay `w` match the current focus? (only yield to overlays actually drawn on this screen)
local function widget_on_screen(w, vs)
    local vss = w.viewscreens
    if type(vss) == 'string' then vss = {vss} end
    if type(vss) ~= 'table' then return false end
    for _, fs in ipairs(vss) do
        if type(fs) == 'string' then
            local ok, m = pcall(dfhack.gui.matchFocusString, fs, vs)
            if ok and m then return true end
        end
    end
    return false
end

-- rects of OTHER overlays currently rendering that overlap `frect`. The picker renders BEHIND these
-- and yields clicks to them, so it never covers or steals input from another panel (notifications).
local function overlapping_overlays(frect)
    local out = {}
    local ok, db = pcall(function() return overlay.get_state().db end)
    if not ok or not db then return out end
    local vs = dfhack.gui.getDFViewscreen(true)
    local fullw, fullh = df.global.gps.dimx - 1, df.global.gps.dimy - 1
    for name, e in pairs(db) do
        if name ~= 'dig-building.picker' and e.widget then
            local w = e.widget
            local r = w.frame_rect
            local vis = w.visible
            if type(vis) == 'function' then local _; _, vis = pcall(vis, w) end
            if r and vis and r.x2 >= r.x1 and r.y2 >= r.y1                            -- valid, non-degenerate
                and not (r.x1 <= 0 and r.y1 <= 0 and r.x2 >= fullw and r.y2 >= fullh) -- not full-screen
                and r.x1 <= frect.x2 and r.x2 >= frect.x1                             -- overlaps frect
                and r.y1 <= frect.y2 and r.y2 >= frect.y1
                and widget_on_screen(w, vs) then                                      -- actually on-screen
                out[#out + 1] = {x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2}
            end
        end
    end
    return out
end

local function in_any(ax, ay, rects)
    for _, r in ipairs(rects) do
        if ax >= r.x1 and ax <= r.x2 and ay >= r.y1 and ay <= r.y2 then return true end
    end
    return false
end

-- is the cursor over another on-screen overlay drawn above us? (yield clicks to it)
local function over_other_overlay(mx, my)
    return #overlapping_overlays({x1 = mx, y1 = my, x2 = mx, y2 = my}) > 0
end
local TOP_MARGIN, BOT_MARGIN = 12, 6      -- rows of negative space kept clear, top / bottom
                                          -- (start 2 higher; keep >=6 clear at the bottom)
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
    {'Metalsmith',   {'Workshops', 'Metalsmith'}, {alias = {'forge', 'smithy'}}},
    {'Magma forge',  {'Workshops', 'Magma forge'}},
    {'Mechanic',     {'Workshops', 'Mechanic'}},
    {'Siege wksp',   {'Workshops', 'Siege'}},
    {'Bowyer',       {'Workshops', 'Bowyer'}},
    {'Ashery',       {'Workshops', 'Ashery'}},
    {'Soap maker',   {'Workshops', "Soap Maker's Workshop"}},
    {'Screw press',  {'Workshops', 'Screw Press'}},
    -- Workshops / Clothing and leather (broken out into individual shops -- the shop appears in the
    -- right-hand column after the "Clothing and leather" subcategory is selected)
    {'Leather works',{'Workshops', 'Clothing and leather', 'Leather'}},
    {'Loom',         {'Workshops', 'Clothing and leather', 'Loom'}},
    {'Clothier',     {'Workshops', 'Clothing and leather', 'Clothes'}},
    {'Dyer',         {'Workshops', 'Clothing and leather', 'Dyer'}},
    -- Workshops / Farming
    {'Farm plot',    {'Workshops', 'Farming', 'Farm plot'}},
    {'Still',        {'Workshops', 'Farming', 'Still'}},
    {'Butcher',      {'Workshops', 'Farming', 'Butcher'}},
    {'Tanner',       {'Workshops', 'Farming', 'Tanner'}},
    {'Fishery',      {'Workshops', 'Farming', 'Fishery'}},
    {'Kitchen',      {'Workshops', 'Farming', 'Kitchen'}},
    {'Farmer',       {'Workshops', 'Farming', 'Farmer'}},
    {'Quern',        {'Workshops', 'Farming', 'Quern'}},
    {'Nest box',     {'Workshops', 'Farming', 'Nest box'}, {alias = 'nestbox'}},
    {'Hive',         {'Workshops', 'Farming', 'Hive'}},
    {'Vermin catcher', {'Workshops', 'Farming', "Vermin Catcher's Shop"}},
    -- Workshops / Furnaces
    {'Wood furnace', {'Workshops', 'Furnaces', 'Wood furnace'}},
    {'Smelter',      {'Workshops', 'Furnaces', 'Smelter'}},
    {'Glass furnace',{'Workshops', 'Furnaces', 'Glass furnace'}},
    {'Kiln',         {'Workshops', 'Furnaces', 'Kiln'}},
    {'Magma smelter',{'Workshops', 'Furnaces', 'Magma smelter'}},
    {'Magma glass furnace', {'Workshops', 'Furnaces', 'Magma glass furnace'}},
    {'Magma kiln',   {'Workshops', 'Furnaces', 'Magma kiln'}},
    -- Furniture
    {'Bed',          {'Furniture', 'Bed'}},
    {'Chair',        {'Furniture', 'Chair'}, {alias = {'throne', 'seat'}}},
    {'Table',        {'Furniture', 'Table'}, {alias = 'desk'}},
    {'Chest',        {'Furniture', 'Chest'}, {alias = {'coffer', 'box'}}},
    {'Cabinet',      {'Furniture', 'Cabinet'}, {alias = {'dresser', 'wardrobe'}}},
    {'Coffin',       {'Furniture', 'Burial'}, {alias = {'sarcophagus', 'casket', 'tomb', 'grave'}}},
    {'Statue',       {'Furniture', 'Statue'}},
    {'Slab',         {'Furniture', 'Slab'}, {noplan = true, alias = 'memorial'}},   -- native slab chooser (keep-building auto-toggle disabled: can't read its state yet)
    {'Traction bed', {'Furniture', 'Traction bench'}},
    {'Bookcase',     {'Furniture', 'Bookcase'}, {alias = 'bookshelf'}},
    {'Display case', {'Furniture', 'Display'}, {alias = 'pedestal'}},
    {'Offering',     {'Furniture', 'Offering place'}, {alias = {'altar', 'shrine'}}},
    {'Instrument',   {'Furniture', 'Instrument'}},
    -- Doors / hatches
    {'Door',         {'Doors/hatches', 'Door'}},
    {'Hatch',        {'Doors/hatches', 'Hatch'}, {alias = {'trapdoor', 'hatch cover'}}},
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
    {'Stairs',       {'Constructions', 'Stairs'}, {alias = 'staircase'}},
    {'Support',      {'Constructions', 'Support'}},
    {'Track',        {'Constructions', 'Track'}},
    {'Track stop',   {'Constructions', 'Track stop'}},
    {'Vert bars',    {'Constructions', 'Vertical bars'}},
    {'Wall',         {'Constructions', 'Wall'}, {alias = {'pillar', 'column'}}},
    {'Wall grate',   {'Constructions', 'Wall grate'}},
    -- Machines / fluids
    {'Lever',        {'Machines/fluids', 'Lever'}},
    {'Well',         {'Machines/fluids', 'Well'}},
    {'Floodgate',    {'Machines/fluids', 'Floodgate'}},
    {'Screw pump',   {'Machines/fluids', 'Screw pump'}},
    {'Water wheel',  {'Machines/fluids', 'Water wheel'}},
    {'Windmill',     {'Machines/fluids', 'Windmill'}},
    {'Gear assembly',{'Machines/fluids', 'Gear assembly'}, {alias = 'cog'}},
    {'Horiz axle',   {'Machines/fluids', 'Horizontal axle'}},
    {'Vert axle',    {'Machines/fluids', 'Vertical axle'}},
    {'Millstone',    {'Machines/fluids', 'Millstone'}},
    {'Rollers',      {'Machines/fluids', 'Rollers'}},
    -- Cages / restraints
    {'Cage',         {'Cages/restraints', 'Cage'}},
    {'Restraint',    {'Cages/restraints', 'Rope/chain'}, {alias = {'rope', 'chain'}}},
    {'Animal trap',  {'Cages/restraints', 'Animal trap'}},
    -- Traps
    {'Pressure plt', {'Traps', 'Pressure plate'}},
    {'Cage trap',    {'Traps', 'Cage'}},
    {'Stonefall',    {'Traps', 'Stone-fall'}},
    {'Weapon trap',  {'Traps', 'Weapon'}},
    {'Spike trap',   {'Traps', 'Upright weapon/spike'}},
    -- Military
    {'Archery targ', {'Military', 'Archery target'}, {alias = {'archery range', 'target'}}},
    {'Weapon rack',  {'Military', 'Weapon rack'}},
    {'Armor stand',  {'Military', 'Armor stand'}, {alias = 'armour stand'}},
    {'Ballista',     {'Military', 'Ballista'}},
    {'Catapult',     {'Military', 'Catapult'}},
    {'Bolt thrower', {'Military', 'Bolt thrower'}},
    -- direct (no submenu)
    {'Trade depot',  {'Trade depot'}},
}

-- one fully alphabetical list (by shown label) so anything is easy to find by name
table.sort(ENTRIES, function(a, b) return a[1] < b[1] end)

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

-- fuzzy subsequence match: every char of `needle` appears in `hay` IN ORDER (case-insensitive).
-- So "tradep" or "trddpt" both match "Trade Depot".
local function fuzzy(needle, hay)
    if needle == '' then return true end
    needle, hay = needle:lower(), hay:lower()
    local j = 1
    for i = 1, #hay do
        if hay:byte(i) == needle:byte(j) then
            j = j + 1
            if j > #needle then return true end
        end
    end
    return false
end

-- how well the search matches an entry -- its shown label, any build-menu path segment, or an
-- explicit search alias (e[3].alias, a string or list; DF's own name for a thing plus any synonym
-- counts). Returns a RANK (lower = better) or nil for no match:
--   0 = exact ("door" == Door -- an exact name always wins outright)
--   1 = prefix ("cof" -> Coffin/Coffer...)
--   2 = substring ("pump" -> Screw pump)
--   3 = fuzzy subsequence ("trddpt" -> Trade Depot)
local function entry_rank(e, needle)
    needle = needle:lower()
    local terms = {e[1]}
    for _, seg in ipairs(e[2]) do terms[#terms + 1] = seg end
    local alias = e[3] and e[3].alias
    if alias then
        if type(alias) == 'string' then alias = {alias} end
        for _, a in ipairs(alias) do terms[#terms + 1] = a end
    end
    local best
    for _, t in ipairs(terms) do
        t = t:lower()
        local r
        if t == needle then r = 0
        elseif t:sub(1, #needle) == needle then r = 1
        elseif t:find(needle, 1, true) then r = 2
        elseif fuzzy(needle, t) then r = 3 end
        if r and (not best or r < best) then best = r end
        if best == 0 then break end
    end
    return best
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
    self.search = ''
end

-- entries matching the current search. Returns a set (by ENTRIES index), a list of matching
-- indices, and the BEST match's index -- lowest rank wins (exact beats prefix beats substring
-- beats fuzzy), ties go to the first alphabetically. Enter always selects the best match.
-- Empty search = no match.
function DigBuilding:compute_matches()
    local set, list, best, best_rank = {}, {}, nil, nil
    if self.search ~= '' then
        for i = 1, #ENTRIES do
            local r = entry_rank(ENTRIES[i], self.search)
            if r then
                set[i] = true; list[#list + 1] = i
                if not best_rank or r < best_rank then best, best_rank = i, r end
            end
        end
    end
    return set, list, best
end

-- scroll so the BEST match is on screen, so you can see what Enter will pick
function DigBuilding:scroll_to_match()
    if self.search == '' then return end
    local _, _, best = self:compute_matches()
    if not best then return end
    local line = math.floor((best - 1) / self.cols)
    if line < self.scroll then self.scroll = line
    elseif line >= self.scroll + self:list_rows() then self.scroll = line - self:list_rows() + 1 end
    self.scroll = math.max(0, math.min(self.scroll, self:max_scroll()))
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
    self.search = self.search or ''
    self.visible = dig_active()
    if not self.visible then                               -- reset when the picker closes:
        self.search = ''                                   -- clear the filter
        self.unfocused = false                             -- and refocus for next open
    end
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

-- Is any cell of our frame covered by native content? Overlays always draw on top of the
-- viewscreen, so to render BEHIND native panels we read the screen buffer (native content is
-- already there when overlays render) and, if the game drew anything visible in ANY of our cells
-- (ch > 32), we step aside entirely. The map is graphic tiles (ch 0), so it never triggers this;
-- native panels/announcements (text + frames) do. Whole-panel (not per-cell) so panel BACKGROUNDS
-- aren't covered either.
function DigBuilding:covered_by_native()
    local fr = self.frame_rect
    if not fr then return false end
    for y = fr.y1, fr.y2 do
        for x = fr.x1, fr.x2 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            if ok and t and t.ch and t.ch > 32 then return true end
        end
    end
    return false
end

-- draw the picker as a bordered, opaque panel -- unless a native panel overlaps it (then hide it)
function DigBuilding:onRenderBody(dc)
    if not self.visible then return end
    self.covered = self:covered_by_native()
    if self.covered then return end   -- a native panel overlaps us: get out of its way entirely
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
    -- fuzzy-search box on the top border, right after " Build " (auto-focused -- just type). Shows
    -- the typed text + a cursor + the live match count; green while Enter has a pick.
    local mset, mlist, mbest = self:compute_matches()
    local fx1, fx2 = 9, (ms > 0) and (w - 11) or (w - 2)
    if fx2 >= fx1 then
        local fw = fx2 - fx1 + 1
        if self.unfocused then
            -- unfocused (after < or >): keys go to DF; click the box to type again. The
            -- filter text (if any) stays visible but greyed, cursorless.
            local txt = self.search == '' and 'click to filter'
                or (self.search .. (' (%d)'):format(#mlist))
            dc:seek(fx1, 0):pen(COLOR_DARKGREY):string(txt:sub(1, fw))
        elseif self.search == '' then
            dc:seek(fx1, 0):pen(COLOR_DARKGREY):string(('type to filter'):sub(1, fw))
        else
            local n = #mlist
            local cnt = (' (%d)'):format(n)
            local body = self.search .. '_'
            if #body + #cnt > fw then body = body:sub(1, math.max(0, fw - #cnt)) end
            local pen = mbest and COLOR_GREEN or COLOR_LIGHTRED
            dc:seek(fx1, 0):pen(pen):string((body .. cnt):sub(1, fw))
        end
    end
    for r = 0, self:list_rows() - 1 do                                         -- entries inside the border
        local line = self.scroll + r
        for c = 0, cols - 1 do
            local idx = line * cols + c + 1
            local e = ENTRIES[idx]
            if e then
                -- empty search: all white. Otherwise the BEST match (what Enter picks) is bright
                -- green, other matches light green, non-matches dimmed.
                local pen
                if self.search == '' then pen = COLOR_WHITE
                elseif idx == mbest then pen = COLOR_GREEN
                elseif mset[idx] then pen = COLOR_LIGHTGREEN
                else pen = COLOR_DARKGREY end
                dc:seek(1 + c * COL_W, r + 1):pen(pen):string(e[1]:sub(1, COL_W - 1))
            end
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
    -- yield everything while hidden or while a native panel overlaps us (covered, set in render)
    if not self.visible or self.covered then return false end
    self.search = self.search or ''

    -- '<' / '>' are DF's z-level keys: NEVER typed into the search. They also UNFOCUS the
    -- search box, so plain keys (wasd panning, hotkeys) pass to DF again -- refocus by
    -- clicking the search box or reopening the picker.
    if keys._STRING == 60 or keys._STRING == 62 then
        self.unfocused = true
        return false                                              -- DF still gets the z change
    end
    if not self.unfocused then
        -- keyboard: the border search box is auto-focused whenever the picker is showing. Backspace
        -- edits, Enter picks the sole match. Space is deliberately NOT captured (it stays DF's pause;
        -- fuzzy subsequence matching means you never need to type the spaces in "Trade Depot" anyway).
        if keys._STRING == 0 then                                 -- backspace
            self.search = self.search:sub(1, -2); self:scroll_to_match(); return true
        elseif keys._STRING and keys._STRING >= 33 then           -- a printable, non-space char
            self.search = self.search .. string.char(keys._STRING); self:scroll_to_match(); return true
        end
        if keys.SELECT then                                       -- Enter: select the BEST match
            local _, _, best = self:compute_matches()
            if best then
                local e = ENTRIES[best]
                self.search = ''
                navigate(e[2], e[3] and e[3].noplan, e[3] and e[3].buildmore)
                return true
            end
            return false                                         -- no match: leave Enter to DF
        end
        if keys.LEAVESCREEN and self.search ~= '' then self.search = ''; return true end   -- Esc clears filter
    end

    -- from here on it's mouse handling: yield when the cursor is over a DF hover element / another
    -- overlay -- never steal their input
    if mi().current_hover ~= -1 or over_other_overlay(df.global.gps.mouse_x, df.global.gps.mouse_y) then
        return false
    end
    -- mouse wheel: only scroll our list when the cursor is actually over the picker AND the list
    -- overflows. Otherwise pass it through so DF still gets the wheel for z-level changes -- stealing
    -- it unconditionally (as before) broke z-scrolling everywhere while the Dig tool was selected.
    if keys.CONTEXT_SCROLL_UP or keys.CONTEXT_SCROLL_DOWN then
        if self:getMousePos() and self:max_scroll() > 0 then
            if keys.CONTEXT_SCROLL_UP then self.scroll = math.max(0, self.scroll - 1)
            else self.scroll = math.min(self:max_scroll(), self.scroll + 1) end
            return true
        end
        return false
    end
    if keys._MOUSE_L then
        local x, y = self:getMousePos()       -- body-local coords, nil if the click is outside us
        if not x then return false end        -- click outside the window: pass through to the map
        local w = self.frame.w
        if y == 0 then                        -- scroll controls on the title/top border
            if x >= w - 10 and x <= w - 6 then self.scroll = math.max(0, self.scroll - 1)
            elseif x >= w - 5 and x <= w - 2 then self.scroll = math.min(self:max_scroll(), self.scroll + 1)
            elseif x >= 9 then self.unfocused = false end   -- click the search box: refocus it
            return true
        end
        local e = self:entry_at(x, y)
        if e then self.search = ''; navigate(e[2], e[3] and e[3].noplan, e[3] and e[3].buildmore) end
        return true                           -- consume any click within the window
    end
    return false
end

OVERLAY_WIDGETS = {picker = DigBuilding}

if dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('dig-building: left-hand building picker (active while the Dig tool is selected).')
