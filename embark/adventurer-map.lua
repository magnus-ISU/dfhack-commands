-- Adventurer creation: hover tooltips for the world-map panes.
--@module = true
--[[
embark/adventurer-map
=====================

Tags: adventure | embark | interface

The map panes of adventurer creation (the Background "Home" region map, the
final start-location map) show sites but tell you nothing about them.  With
this overlay loaded, hovering a site pops the same card adv/read-the-map
draws on the travel map: race-led headline, owner and population, nobles,
legends, lair dwellers, camp crews.

Unlike the travel map, these panes expose NO anchor for the viewport -- no
army at a fixed cell, no scroll field found on the viewscreen, and
`screen_x/y` doesn't track anything recognizable -- so the mapping is
SELF-CALIBRATED at runtime: whenever the pane's site layer changes, the
overlay matches the drawn site cells (`gps.main_map_port.screentexpos_site`,
row-major) against every site's real footprint, solving for the view offset
at two candidate scales (one cell = one world tile, or one mid tile), and
keeps whichever fits better.  On the Background pane the world-scale solve
fits PERFECTLY (1.00): the pane is the whole world map with a decorative
border (a 65-tile world in a 72-cell port sits at offset -7,-7).  A mid-tile
solve also reaches ~0.78 there by aliasing -- region tiles are dense -- which
is why the higher score wins and MIN_SCORE gates acceptance; below it the
overlay stays quiet rather than mislabel.  The solve is coarse-to-fine over
sampled cells and runs once per layer change, not per frame.

Pane pixel geometry: cells are 16px, the pane's top-left pixel is
`main_map_port.top_left_corner_x/y` (the travel map sits at 0,0; the
Background pane at 752,104 on this window).

    embark/adventurer-map          status (the overlay is on by default)
]]

local overlay = require('plugins.overlay')

local MIN_SCORE = 0.40     -- accepted fraction of sampled site cells matched
local MAX_SAMPLE = 60      -- drawn cells sampled by the solver
local CELL_PX = 16         -- map-port cell pixel size (square)

-- ---- world data caches (rebuilt per calibration) ----------------------------

local function site_mid_set()
    local set = {}
    local wd = df.global.world.world_data
    for j = 0, #wd.sites - 1 do
        local s = wd.sites[j]
        for mx = s.global_min_x, s.global_max_x do
            for my = s.global_min_y, s.global_max_y do set[mx * 10000 + my] = true end
        end
    end
    return set
end

local function site_world_set()
    local set = {}
    local wd = df.global.world.world_data
    for j = 0, #wd.sites - 1 do
        local s = wd.sites[j]
        for wx = s.global_min_x // 16, s.global_max_x // 16 do
            for wy = s.global_min_y // 16, s.global_max_y // 16 do
                set[wx * 10000 + wy] = true
            end
        end
    end
    return set
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

-- {scale=1|16, ox=, oy=} once solved; sig identifies the layer state it fits
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

-- best offset for one scale: predicted tile of drawn cell = cell - offset
local function solve_scale(cells, tileset, range)
    local sample = {}
    local stepn = math.max(1, #cells // MAX_SAMPLE)
    for i = 1, #cells, stepn do sample[#sample + 1] = cells[i] end
    local function score(ox, oy)
        local hit = 0
        for _, d in ipairs(sample) do
            if tileset[(d[1] - ox) * 10000 + (d[2] - oy)] then hit = hit + 1 end
        end
        return hit
    end
    local best, bx, by = -1, 0, 0
    for ox = -range, range, 4 do
        for oy = -range, range, 4 do
            local h = score(ox, oy)
            if h > best then best, bx, by = h, ox, oy end
        end
    end
    for ox = bx - 4, bx + 4 do
        for oy = by - 4, by + 4 do
            local h = score(ox, oy)
            if h > best then best, bx, by = h, ox, oy end
        end
    end
    return bx, by, best / #sample
end

local function calibrate()
    local cells = drawn_site_cells()
    local sig = signature(cells)
    if sig == view_sig then return end       -- same layer state: keep the fit
    view_sig = sig
    view = nil
    if #cells < 6 then return end            -- not enough to solve against
    local wd = df.global.world.world_data
    local mid_range = math.max(wd.world_width, wd.world_height) * 16
    local ox1, oy1, s1 = solve_scale(cells, site_mid_set(), mid_range)
    local ox2, oy2, s2 = solve_scale(cells, site_world_set(),
        math.max(wd.world_width, wd.world_height) + 80)
    last_scores = {s1 = s1, s2 = s2, ox1 = ox1, oy1 = oy1, ox2 = ox2, oy2 = oy2}
    if s1 >= s2 and s1 >= MIN_SCORE then
        view = {scale = 1, ox = ox1, oy = oy1}
    elseif s2 > s1 and s2 >= MIN_SCORE then
        view = {scale = 16, ox = ox2, oy = oy2}
    end
end

-- ---- hover ------------------------------------------------------------------

-- the mid-tile rect under the mouse, or nil
local function mouse_rect()
    if not view then return end
    local gps = df.global.gps
    local mp = gps.main_map_port
    local cx = (gps.precise_mouse_x - mp.top_left_corner_x) // CELL_PX
    local cy = (gps.precise_mouse_y - mp.top_left_corner_y) // CELL_PX
    if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end
    local tx, ty = cx - view.ox, cy - view.oy
    if view.scale == 1 then return tx, tx, ty, ty end
    return tx * 16, tx * 16 + 15, ty * 16, ty * 16 + 15
end

local cache_key, cache_lines = nil, nil

local function hover_lines()
    local x0, x1, y0, y1 = mouse_rect()
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
    pcall(calibrate)
end

function AdventurerMap:onRenderFrame(dc, rect)
    pcall(function()
        local lines = hover_lines()
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
    view_sig = nil                          -- force a fresh solve
    calibrate()
    if last_scores then
        print(('  mid fit %.2f at (%d,%d) | world fit %.2f at (%d,%d)'):format(
            last_scores.s1, last_scores.ox1, last_scores.oy1,
            last_scores.s2, last_scores.ox2, last_scores.oy2))
    end
    if view then
        print(('calibrated: scale=%d offset=(%d,%d)'):format(view.scale, view.ox, view.oy))
    else
        print('not calibrated (no map or low confidence)')
    end
end

if dfhack_flags.module then return end

print('embark/adventurer-map: hover the creation world maps to identify sites.')
print('The overlay is enabled by default; it self-calibrates per map view.')
