-- Adventurer creation: hover tooltips for the world-map panes.
--@module = true
--[[
embark/adventurer-map
=====================

Tags: adventure | embark | interface

The world maps of adventurer creation name nothing.  With this overlay
loaded, hovering a site pops the same card adv/read-the-map draws on the
travel map: race-led headline, owner and population, nobles, legends, lair
dwellers, camp crews.  It is active on two pages -- everywhere else the map
port holds stale data and a tooltip would mislabel the screen:

- the Create Your Character origin list (mode 4, ENTITY), and
- the Background tab of the character sheet (mode 5, sub_mode 9).

The two pages project DIFFERENTLY, so each calibrates its own way.

The ENTITY page draws the ENTIRE world flush at the pane origin, compressed
2:1 vertically: one pane cell = 1 world tile wide x 2 world tiles tall (a
65x65 world renders as a 65x32 block; the blinking origin-site markers sit
at cell (site.pos.x, site.pos.y // 2), which is how this was verified).  The
drawn base layer's bounding box IS the calibration: when its width equals
world_width and its height half of world_height, the mapping is locked --
no solver, works even though only 2-3 site cells are ever drawn there.

The Background tab exposes NO anchor for the viewport -- no army at a fixed
cell, no scroll field found on the viewscreen, and `screen_x/y` doesn't
track anything recognizable -- so the mapping is SELF-CALIBRATED at
runtime: whenever the pane's site layer changes, the overlay matches the
drawn site cells (`gps.main_map_port.screentexpos_site`, row-major) against
every site's real footprint, solving for the view offset at two candidate
scales (one cell = one world tile, or one mid tile), and keeps whichever
fits better.  On the Background pane the world-scale solve fits PERFECTLY
(1.00): the pane is the whole world map with a decorative border (a 65-tile
world in a 72-cell port sits at offset -7,-7).  A mid-tile solve also
reaches ~0.78 there by aliasing -- region tiles are dense -- which is why
the higher score wins and MIN_SCORE gates acceptance; below it the overlay
stays quiet rather than mislabel.

The solve runs on DF's render thread, so it must be CHEAP: the site tile
sets are cached per world, a map that merely scrolled is tracked by
re-scoring a small window around the previous offset (accepted only at
TRACK_SCORE, high enough that a zoom change can't alias through), and the
full solve never scans the offset grid -- candidate offsets are generated
by anchoring a few drawn cells onto every site tile, so the search space is
the site-tile list instead of (2 x world-span)^2 offsets (~270k grid points
at mid scale, the 16M-lookup freeze this replaced).  The world-scale list
is tiny (~800 tiles, ~3 ms), so it solves first and a definitive fit skips
the mid solve (~56k tiles, ~200 ms) entirely; measured with debug_bench().

Pane pixel geometry: cells are 16px, the pane's top-left pixel is
`main_map_port.top_left_corner_x/y` (the travel map sits at 0,0; the
Background pane at 752,104 on this window).

    embark/adventurer-map          status (the overlay is on by default)
]]

local overlay = require('plugins.overlay')

local MIN_SCORE = 0.40     -- accepted fraction of sampled site cells matched
local TRACK_SCORE = 0.90   -- bar for keeping a scrolled view without a re-solve
local MAX_SAMPLE = 60      -- drawn cells sampled by the solver
local LOCAL_RANGE = 20     -- offset window searched when tracking a scroll
local CELL_PX = 16         -- map-port cell pixel size (square)

-- ---- world data caches (built once per world) -------------------------------

-- {mid_set=, mid_list=, world_set=, world_list=}: site footprint tiles at
-- both scales, as key sets for scoring and flat lists for candidate
-- generation.  Keys pack (x,y) as x*10000+y.
local tiles_cache = nil

local function get_tilesets()
    local wd = df.global.world.world_data
    if tiles_cache and tiles_cache.key == #wd.sites then return tiles_cache end
    local c = {key = #wd.sites, mid_set = {}, mid_list = {},
               world_set = {}, world_list = {}}
    for j = 0, #wd.sites - 1 do
        local s = wd.sites[j]
        for mx = s.global_min_x, s.global_max_x do
            for my = s.global_min_y, s.global_max_y do
                local k = mx * 10000 + my
                if not c.mid_set[k] then
                    c.mid_set[k] = true
                    c.mid_list[#c.mid_list + 1] = k
                end
            end
        end
        for wx = s.global_min_x // 16, s.global_max_x // 16 do
            for wy = s.global_min_y // 16, s.global_max_y // 16 do
                local k = wx * 10000 + wy
                if not c.world_set[k] then
                    c.world_set[k] = true
                    c.world_list[#c.world_list + 1] = k
                end
            end
        end
    end
    tiles_cache = c
    return c
end

local function drawn_site_cells()
    local mp = df.global.gps.main_map_port
    local cells = {}
    local n = mp.dim_x * mp.dim_y - 1
    local ok = pcall(function()
        local buf = mp.screentexpos_site
        for i = 0, n do
            if buf[i] ~= 0 then cells[#cells + 1] = {i % mp.dim_x, i // mp.dim_x} end
        end
    end)
    return ok and cells or {}
end

-- ---- calibration ------------------------------------------------------------

-- {page=, sx=, sy=, ox=, oy=} once solved: pane cell (cx,cy) shows the mid
-- tiles [(cx-ox)*sx, +sx) x [(cy-oy)*sy, +sy).  sig identifies the layer
-- state a Background solve fits; the ENTITY page recalibrates each update.
local view = nil
local view_sig = nil

local function signature(cells)
    local mp = df.global.gps.main_map_port
    local parts = {mp.dim_x, mp.dim_y, #cells}
    for i = 1, math.min(#cells, 8) do
        parts[#parts + 1] = cells[i][1] * 1000 + cells[i][2]
    end
    return table.concat(parts, ':')
end

local function sample_cells(cells)
    local sample = {}
    local stepn = math.max(1, #cells // MAX_SAMPLE)
    for i = 1, #cells, stepn do sample[#sample + 1] = cells[i] end
    return sample
end

-- fraction-hit numerator: predicted tile of drawn cell = cell - offset
local function score_at(sample, tileset, ox, oy)
    local hit = 0
    for i = 1, #sample do
        local d = sample[i]
        if tileset[(d[1] - ox) * 10000 + (d[2] - oy)] then hit = hit + 1 end
    end
    return hit
end

-- cheap tracking solve: the map scrolled, the scale didn't -- search a small
-- window around the previous offset
local function solve_near(cells, tileset, cx, cy)
    local sample = sample_cells(cells)
    local best, bx, by = -1, cx, cy
    for ox = cx - LOCAL_RANGE, cx + LOCAL_RANGE do
        for oy = cy - LOCAL_RANGE, cy + LOCAL_RANGE do
            local h = score_at(sample, tileset, ox, oy)
            if h > best then best, bx, by = h, ox, oy end
        end
    end
    return bx, by, best / #sample
end

-- full solve for one scale, without scanning the offset grid: anchoring one
-- drawn cell onto one site tile fixes the offset, so the candidate set is
-- (a few anchors) x (the site-tile list).  A short prescreen sample filters
-- candidates; survivors get the full score.
local function solve_candidates(cells, tileset, tilelist)
    local sample = sample_cells(cells)
    local pre = {}
    for i = 1, #sample, math.max(1, #sample // 12) do pre[#pre + 1] = sample[i] end
    local anchors = {sample[1], sample[(#sample + 1) // 2], sample[#sample]}
    local seen, cand = {}, {}
    for _, a in ipairs(anchors) do
        for i = 1, #tilelist do
            local k = tilelist[i]
            local ox, oy = a[1] - k // 10000, a[2] - k % 10000
            local okey = ox * 100000 + oy
            if not seen[okey] then
                seen[okey] = true
                if score_at(pre, tileset, ox, oy) * 3 >= #pre then
                    cand[#cand + 1] = {ox, oy}
                end
            end
        end
    end
    local best, bx, by = 0, 0, 0
    for i = 1, #cand do
        local h = score_at(sample, tileset, cand[i][1], cand[i][2])
        if h > best then best, bx, by = h, cand[i][1], cand[i][2] end
    end
    return bx, by, best / #sample
end

local function calibrate()
    local cells = drawn_site_cells()
    local sig = signature(cells)
    if sig == view_sig and (not view or view.page == 'background') then
        return                               -- same layer state: keep the fit
    end
    local prev = (view and view.page == 'background') and view or nil
    view_sig = sig
    view = nil
    if #cells < 6 then return end            -- not enough to solve against
    local ts = get_tilesets()
    -- scrolled, same scale?  a windowed re-score around the old offset keeps
    -- up with scrolling for ~nothing; TRACK_SCORE is strict so a zoomed map
    -- (wrong scale now) falls through to the full solve instead of aliasing
    if prev then
        local set = prev.sx == 1 and ts.mid_set or ts.world_set
        local ox, oy, s = solve_near(cells, set, prev.ox, prev.oy)
        if s >= TRACK_SCORE then
            view = {page = 'background', sx = prev.sx, sy = prev.sy, ox = ox, oy = oy}
            return
        end
    end
    -- world scale first: its tile list is tiny (~800 vs ~56k), and a
    -- definitive fit there makes the expensive mid solve pointless
    local ox2, oy2, s2 = solve_candidates(cells, ts.world_set, ts.world_list)
    local ox1, oy1, s1 = 0, 0, 0
    if s2 < TRACK_SCORE then
        ox1, oy1, s1 = solve_candidates(cells, ts.mid_set, ts.mid_list)
    end
    last_scores = {s1 = s1, s2 = s2, ox1 = ox1, oy1 = oy1, ox2 = ox2, oy2 = oy2}
    if s1 >= s2 and s1 >= MIN_SCORE then
        view = {page = 'background', sx = 1, sy = 1, ox = ox1, oy = oy1}
    elseif s2 > s1 and s2 >= MIN_SCORE then
        view = {page = 'background', sx = 16, sy = 16, ox = ox2, oy = oy2}
    end
end

-- ENTITY page: the whole world map drawn flush in the pane, 1x2 world tiles
-- per cell.  The drawn base layer's bounding box is the anchor; the blink
-- leaves the site layer mostly empty, so no site-solve is possible there.
local function calibrate_entity()
    local mp = df.global.gps.main_map_port
    local minx, maxx, miny, maxy = math.huge, -1, math.huge, -1
    for _, name in ipairs{'screentexpos_base', 'screentexpos_base_old'} do
        local buf = mp[name]
        for i = 0, mp.dim_x * mp.dim_y - 1 do
            if buf[i] ~= 0 then
                local x, y = i % mp.dim_x, i // mp.dim_x
                if x < minx then minx = x end
                if x > maxx then maxx = x end
                if y < miny then miny = y end
                if y > maxy then maxy = y end
            end
        end
        if maxx >= 0 then break end     -- this half of the double buffer drew
    end
    view = nil
    if maxx < 0 then return end
    local wd = df.global.world.world_data
    local w, h = maxx - minx + 1, maxy - miny + 1
    if w ~= wd.world_width or w < 16 then return end
    if h == wd.world_height // 2 or h == (wd.world_height + 1) // 2 then
        view = {page = 'entity', sx = 16, sy = 32, ox = minx, oy = miny}
    elseif h == wd.world_height then     -- in case DF ever draws it square
        view = {page = 'entity', sx = 16, sy = 16, ox = minx, oy = miny}
    end
end

-- ---- hover ------------------------------------------------------------------

-- which map-bearing page is up, or nil; everywhere else the map port holds
-- stale data and a tooltip would mislabel whatever is on screen
local function active_page()
    local vs = dfhack.gui.getCurViewscreen(true)
    while vs and not df.viewscreen_setupadventurest:is_instance(vs) do vs = vs.parent end
    if not vs then return end
    if vs.mode == 4 then return 'entity' end    -- Create Your Character origins
    if vs.mode ~= 5 then return end
    local idx = vs.active_sheet_index
    if idx < 0 or idx >= #vs.csheet then idx = 0 end
    local cs = vs.csheet[idx]
    if cs and cs.sub_mode == 9 then return 'background' end
end

-- the mid-tile rect under the mouse, or nil
local function mouse_rect(page)
    if not view or view.page ~= page then return end
    local gps = df.global.gps
    local mp = gps.main_map_port
    local cx = (gps.precise_mouse_x - mp.top_left_corner_x) // CELL_PX
    local cy = (gps.precise_mouse_y - mp.top_left_corner_y) // CELL_PX
    if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end
    local x0, y0 = (cx - view.ox) * view.sx, (cy - view.oy) * view.sy
    local wd = df.global.world.world_data
    if x0 < 0 or y0 < 0 or x0 >= wd.world_width * 16 or y0 >= wd.world_height * 16 then
        return
    end
    return x0, x0 + view.sx - 1, y0, y0 + view.sy - 1
end

local cache_key, cache_lines = nil, nil

local function hover_lines(page)
    local x0, x1, y0, y1 = mouse_rect(page)
    if not x0 then return end
    local key = ('%d:%d:%d:%d'):format(x0, x1, y0, y1)
    if key == cache_key then return cache_lines end
    cache_key = key
    cache_lines = nil
    local rtm = reqscript('adv/read-the-map')
    local lines = {}
    local wd = df.global.world.world_data
    for i = 0, #wd.sites - 1 do
        local s = wd.sites[i]
        if x1 >= s.global_min_x and x0 <= s.global_max_x
                and y1 >= s.global_min_y and y0 <= s.global_max_y then
            for _, l in ipairs(rtm.lines_for_site(s.id) or {}) do
                lines[#lines + 1] = l
            end
        end
    end
    if #lines > 0 then cache_lines = lines end
    return cache_lines
end

-- ---- overlay ----------------------------------------------------------------

AdventurerMap = defclass(AdventurerMap, overlay.OverlayWidget)
AdventurerMap.ATTRS{
    desc = 'Hover tooltips for the adventurer-creation world maps.',
    default_enabled = true,
    viewscreens = 'setupadventure',
    overlay_onupdate_max_freq_seconds = 1,
    frame = {w = 1, h = 1},
}

local PEN_TEXT = dfhack.pen.parse{fg = COLOR_WHITE, bg = COLOR_BLACK}
local PEN_EDGE = dfhack.pen.parse{fg = COLOR_LIGHTCYAN, bg = COLOR_BLACK}

function AdventurerMap:overlay_onupdate()
    pcall(function()
        local page = active_page()
        if page == 'background' then
            calibrate()
        elseif page == 'entity' then
            calibrate_entity()
        end
    end)
end

function AdventurerMap:onRenderFrame(dc, rect)
    pcall(function()
        local page = active_page()
        if not page then return end
        local lines = hover_lines(page)
        if not lines then return end
        local gps = df.global.gps
        local width = 0
        for _, l in ipairs(lines) do width = math.max(width, #l) end
        width = width + 2
        local tx = gps.mouse_x + 2
        local ty = gps.mouse_y + 1
        if tx + width >= gps.dimx then tx = math.max(0, gps.mouse_x - width - 1) end
        if ty + #lines >= gps.dimy then ty = math.max(0, gps.mouse_y - #lines - 1) end
        for i, line in ipairs(lines) do
            local pen = i == 1 and PEN_EDGE or PEN_TEXT
            dfhack.screen.paintString(pen, tx, ty + i - 1,
                ' ' .. line .. string.rep(' ', width - #line - 1))
        end
    end)
end

OVERLAY_WIDGETS = {map = AdventurerMap}

-- exported for testing
function debug_state()
    local page = active_page()
    print('page: ' .. tostring(page))
    view_sig = nil                          -- force a fresh solve
    if page == 'entity' then
        calibrate_entity()
    else
        calibrate()
        if last_scores then
            print(('  mid fit %.2f at (%d,%d) | world fit %.2f at (%d,%d)'):format(
                last_scores.s1, last_scores.ox1, last_scores.oy1,
                last_scores.s2, last_scores.ox2, last_scores.oy2))
        end
    end
    if view then
        print(('calibrated: page=%s scale=%dx%d offset=(%d,%d)'):format(
            view.page, view.sx, view.sy, view.ox, view.oy))
    else
        print('not calibrated (no map or low confidence)')
    end
end

-- exported for testing: solver cost on synthetic cells (a world-scale pane
-- at offset (-7,-7), like the Background tab draws)
function debug_bench()
    tiles_cache = nil
    local t0 = os.clock()
    local ts = get_tilesets()
    local t1 = os.clock()
    print(('tilesets: %d mid, %d world tiles in %.0f ms'):format(
        #ts.mid_list, #ts.world_list, (t1 - t0) * 1000))
    local cells = {}
    for i = 1, #ts.world_list do
        local k = ts.world_list[i]
        cells[#cells + 1] = {k // 10000 - 7, k % 10000 - 7}
    end
    t0 = os.clock()
    local ox1, oy1, s1 = solve_candidates(cells, ts.mid_set, ts.mid_list)
    t1 = os.clock()
    local ox2, oy2, s2 = solve_candidates(cells, ts.world_set, ts.world_list)
    local t2 = os.clock()
    print(('full solve: mid %.2f at (%d,%d) in %.0f ms | world %.2f at (%d,%d) in %.0f ms'):format(
        s1, ox1, oy1, (t1 - t0) * 1000, s2, ox2, oy2, (t2 - t1) * 1000))
    t0 = os.clock()
    local ox, oy, s = solve_near(cells, ts.world_set, -4, -9)
    t1 = os.clock()
    print(('track solve: %.2f at (%d,%d) in %.0f ms'):format(s, ox, oy, (t1 - t0) * 1000))
end

-- exported for testing: what the tooltip would say for the pane cell (cx,cy)
function debug_cell(cx, cy)
    local page = active_page()
    if not view or not page then print('no view or page') return end
    local x0, y0 = (cx - view.ox) * view.sx, (cy - view.oy) * view.sy
    local x1, y1 = x0 + view.sx - 1, y0 + view.sy - 1
    print(('cell (%d,%d) -> mid rect x %d-%d y %d-%d'):format(cx, cy, x0, x1, y0, y1))
    local rtm = reqscript('adv/read-the-map')
    local wd = df.global.world.world_data
    for i = 0, #wd.sites - 1 do
        local s = wd.sites[i]
        if x1 >= s.global_min_x and x0 <= s.global_max_x
                and y1 >= s.global_min_y and y0 <= s.global_max_y then
            for _, l in ipairs(rtm.lines_for_site(s.id) or {}) do print('  ' .. l) end
        end
    end
end

if dfhack_flags.module then return end

print('embark/adventurer-map: hover the creation world maps to identify sites.')
print('The overlay is enabled by default; it self-calibrates per map view.')
