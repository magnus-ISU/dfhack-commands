-- Adventure travel: click the lesser world map to walk there.
--@module = true
--[[
adv/map-travel
==============

Tags: adventure | interface

On the lesser (zoomed-in) travel map, LEFT-CLICK a tile and your traveler
walks there: the overlay feeds one `A_MOVE_*` key per step toward the
destination.  A red X marks the destination while the journey runs.

Works at BOTH lesser-map zooms.  The travel map silently rescales when you
get close to a site (`adventure.site_level_zoom` flips to 1): one map cell is
one mid tile (3 army-units) in the far state but one army-unit up close, and
one fed A_MOVE_* moves one CELL in either state (measured: -3 far, -1 near).
The destination is stored in army-units, so when a journey crosses the
transition the target simply converts and the walk continues.

The pathing is deliberately NAIVE: each step goes straight at the target
(8-directional).  It does not route around rivers, oceans, mountains, farms
or hostile sites -- when the straight line is blocked and the position stops
changing, the journey aborts with a console note rather than wander.

- Left-click on the map: set / replace the destination (the click is
  consumed).  Clicks within 5 cells of any map edge are IGNORED so the
  buttons living around the screen edges -- including the DFHack overlay
  launcher -- still work.
- Right-click: cancel the journey (consumed; right-click again to leave the
  travel screen as usual).  Leaving the travel screen also cancels.
- The greater map (`m`) is left alone.

Screen decoding as in adv/read-the-map: the map renders through
`gps.main_map_port`, a `dim_x x dim_y` grid of cells, and the player is drawn
at the CENTRE of that grid, `(dim_x//2, dim_y//2)`.

Three things here were wrong for anyone whose display is not the one this was
written on, and all of them misplace things rather than failing outright:

- The cell size was taken from the x axis alone and reused for y. That needs
  square pixel cells and a window that is a whole number of tiles wide. An
  ASCII font is usually taller than it is wide, so the vertical decode slipped
  further with every row down the screen; a rescaled window loses the
  remainder. Each axis is now measured on its own from `gps.screen_pixel_x/y`.
- The player's draw cell was read from `mp.screen_x/screen_y`. That pair
  belongs to the LOCAL map and drifts from the grid centre as soon as the local
  camera clamps at a map edge -- inside a site, everything was offset by the
  drift. adv/read-the-map hit this and verified the centre against
  `screentexpos_army`; this now uses the centre too. (Read live in a fort: the
  pair was 70,33 against a grid centre of 60,34.)
- Pixels per cell was rounded to an integer. Cells are not a whole number of
  pixels: measured on the display this was reported from, 120x68 cells over a
  1920x1080 window is 16.000 x 15.882 pixels per cell, and rounding 15.882 down
  to 15 loses most of a pixel per cell. The error grows with distance from the
  top of the screen -- two cells wrong at y=300, four at y=900 -- in the mouse
  decode AND, mirrored, in where the destination X is drawn. That last one is
  what made the X appear to slide toward the traveller as they moved: it was
  always drawn short of where it belonged, by an amount that shrank as the
  target approached the middle of the screen. Both directions are now exact
  integer ratios with no rounding of the cell size.

What sits at that center cell is NOT always the player army.  DF creates the
army only once the journey starts; on a travel map you have just opened,
`player_army_id` resolves to nothing and DF draws you at
`adventure.travel_origin_x/y` (same army-unit scale) for as long as
`adventure.travel_not_moved` is set.  Read the army alone and the overlay is
inert until some click falls through to DF and starts the travel for you --
which is exactly why this used to need one throwaway click to wake up.

    adv/map-travel             status
    adv/map-travel stop        cancel the current journey
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local STEP_MS = 140        -- wall-clock pace between fed steps
local STUCK_LIMIT = 4      -- aborts after this many stepless attempts
local GAP_CANCEL_MS = 1500 -- overlay silent this long (left the screen) = cancel
local EDGE_GUARD = 5       -- map cells near an edge where clicks pass through

journeys = journeys or 0   -- completed journeys (persists across reloads)

-- journey state (reset on reload); dest is in ARMY-UNITS so it survives the
-- near-site zoom transition
local dest = nil           -- {ax=, ay=}
local next_step_at = 0
local last_fire = 0
local stuck, last_pos = 0, nil

local DIR_KEYS = {
    [-1] = {[-1] = 'A_MOVE_NW', [0] = 'A_MOVE_N', [1] = 'A_MOVE_NE'},
    [0]  = {[-1] = 'A_MOVE_W',                    [1] = 'A_MOVE_E'},
    [1]  = {[-1] = 'A_MOVE_SW', [0] = 'A_MOVE_S', [1] = 'A_MOVE_SE'},
}

-- Where the travel map is centred, in army-units.
--
-- DF does not mint the player army until the journey actually starts: on a
-- freshly opened travel map `player_army_id` points at nothing and DF instead
-- draws the player at `travel_origin` for as long as `travel_not_moved`
-- ("still_local") is set.  Reading the army first therefore made the overlay
-- dead until one click had fallen through to DF and kicked off the travel.
local function center_pos()
    local adv = df.global.adventure
    if adv.travel_not_moved ~= 0 then
        return adv.travel_origin_x, adv.travel_origin_y
    end
    local army = df.army.find(adv.player_army_id)
    if army then return army.pos.x, army.pos.y end
end

local function on_lesser_map()
    return df.global.adventure.travel_right_map == 0
end

-- army-units per map cell (and per fed step) at the current zoom
local function cell_scale()
    return df.global.adventure.site_level_zoom ~= 0 and 1 or 3
end

-- Cell geometry. Cells are NOT a whole number of pixels, and that is the whole
-- problem: on the display this bug was reported from, the map port is 120x68
-- cells across a 1920x1080 window, so a cell is 16.000 x 15.882 pixels. Taking
-- pixels-per-cell as an integer (15) loses 0.88px per cell, and the error
-- compounds with distance from the top of the screen -- measured on that
-- display, a mouse at y=300 decodes two cells off and at y=900 four cells off.
--
-- The same error runs the other way when drawing the destination marker, and
-- that is what made the X appear to creep toward the traveller: the marker's
-- cell index shrinks as you approach, so its error shrinks too, and the X slides
-- inward faster than the ground does. It is not the world-coordinate maths
-- drifting -- it is the marker being drawn increasingly less wrong.
--
-- So neither direction rounds the cell size. Both scale by the exact ratio
-- (window pixels : cells) in integer arithmetic, which is exact everywhere on
-- the screen and needs no correction term.
local function port()
    local gps = df.global.gps
    local mp = gps.main_map_port
    if not mp or mp.dim_x <= 0 or mp.dim_y <= 0 then return end
    local w = gps.screen_pixel_x > 0 and gps.screen_pixel_x or gps.dimx * gps.tile_pixel_x
    local h = gps.screen_pixel_y > 0 and gps.screen_pixel_y or gps.dimy * gps.tile_pixel_y
    return mp, w, h
end

-- pixel -> cell, exactly: cell = floor(px * dim / window_px)
local function px_to_cell(px, dim, window_px)
    return (px * dim) // window_px
end

-- cell -> the text cell its middle falls in, exactly:
--   floor(((cell + 0.5) * window_px / dim) / tile_px)
-- kept in integers by doubling through the halves
local function cell_to_text(cell, dim, window_px, tile_px)
    return ((2 * cell + 1) * window_px) // (2 * dim * tile_px)
end

-- mouse position -> map-port cell, or nil off the map / in the edge guard
local function mouse_cell(guard)
    local gps = df.global.gps
    local mp, w, h = port()
    if not mp then return end
    local cx = px_to_cell(gps.precise_mouse_x, mp.dim_x, w)
    local cy = px_to_cell(gps.precise_mouse_y, mp.dim_y, h)
    if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end
    if guard and (cx < EDGE_GUARD or cx >= mp.dim_x - EDGE_GUARD
            or cy < EDGE_GUARD or cy >= mp.dim_y - EDGE_GUARD) then
        return
    end
    return cx, cy
end

-- The cell the player is drawn in: the CENTRE OF THE GRID, not mp.screen_x/y.
-- That pair is the LOCAL map's player-draw cell; it equals the centre only while
-- the local camera is free to recentre, and drifts once the local view clamps at
-- a map edge (read (62,40) against a marker at (60,33) inside a site). Every
-- click and the destination X were offset by that drift. adv/read-the-map hit
-- the same bug and verified the centre against screentexpos_army.
local function center_cell(mp)
    return mp.dim_x // 2, mp.dim_y // 2
end

local function stop_journey(why)
    if dest and why then print('adv/map-travel: ' .. why) end
    dest, stuck, last_pos = nil, 0, nil
end

local function step()
    local now = dfhack.getTickCount()
    -- a long silence means the player left the travel screen mid-journey;
    -- do not resume a stale journey when they come back
    if last_fire > 0 and now - last_fire > GAP_CANCEL_MS then
        stop_journey(nil)
    end
    last_fire = now
    if not dest or now < next_step_at or not on_lesser_map() then return end
    local ax, ay = center_pos()
    if not ax then stop_journey(nil) return end
    local s = cell_scale()
    -- same reasoning as the marker: measure the separation, then divide. These
    -- are cells REMAINING, so arrival is simply zero on both axes.
    local tx, ty = (dest.ax - ax) // s, (dest.ay - ay) // s
    if tx == 0 and ty == 0 then
        journeys = journeys + 1
        stop_journey('arrived.')
        return
    end
    local pos_key = ax .. ':' .. ay
    if pos_key == last_pos then
        stuck = stuck + 1
        if stuck >= STUCK_LIMIT then
            stop_journey('blocked -- no path straight at the target from here.')
            return
        end
    else
        stuck, last_pos = 0, pos_key
    end
    local dx = tx > 0 and 1 or tx < 0 and -1 or 0
    local dy = ty > 0 and 1 or ty < 0 and -1 or 0
    local key = DIR_KEYS[dy] and DIR_KEYS[dy][dx]
    if not key then stop_journey(nil) return end
    gui.simulateInput(dfhack.gui.getCurViewscreen(true), key)
    next_step_at = now + STEP_MS
end

-- ---- overlay ----------------------------------------------------------------

MapTravel = defclass(MapTravel, overlay.OverlayWidget)
MapTravel.ATTRS{
    desc = 'Click the lesser travel map to walk there.',
    default_enabled = true,
    viewscreens = 'dungeonmode/Travel',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

local PEN_MARK = dfhack.pen.parse{fg = COLOR_LIGHTRED, bg = COLOR_BLACK}

function MapTravel:onInput(keys)
    local ok, handled = pcall(function()
        if not on_lesser_map() then return false end
        if keys._MOUSE_R then
            if dest then stop_journey('cancelled.') return true end
            return false
        end
        if not keys._MOUSE_L then return false end
        local ax, ay = center_pos()
        if not ax then return false end
        local cx, cy = mouse_cell(true)     -- guarded: edge clicks fall through
        if not cx then return false end
        local mp = df.global.gps.main_map_port
        local ccx, ccy = center_cell(mp)
        local s = cell_scale()
        dest = {
            ax = ax + (cx - ccx) * s,
            ay = ay + (cy - ccy) * s,
        }
        stuck, last_pos, next_step_at = 0, nil, 0
        return true
    end)
    return ok and handled
end

function MapTravel:overlay_onupdate()
    pcall(step)
end

function MapTravel:onRenderFrame(dc, rect)
    pcall(function()
        if not dest or not on_lesser_map() then return end
        local ax, ay = center_pos()
        if not ax then return end
        local gps = df.global.gps
        local mp, w, h = port()
        if not mp then return end
        local s = cell_scale()
        local ccx, ccy = center_cell(mp)
        -- the difference of the positions, floored once -- not the difference of
        -- two separately floored positions, which shifts by a cell depending on
        -- where the traveller happens to sit inside their own cell
        local cx = ccx + (dest.ax - ax) // s
        local cy = ccy + (dest.ay - ay) // s
        if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end
        local tx = cell_to_text(cx, mp.dim_x, w, gps.tile_pixel_x)
        local ty = cell_to_text(cy, mp.dim_y, h, gps.tile_pixel_y)
        dfhack.screen.paintString(PEN_MARK, tx, ty, 'X')
    end)
end

OVERLAY_WIDGETS = {travel = MapTravel}

function stop()
    stop_journey('cancelled.')
end

-- exported for testing: destination in army-units
function go(ax, ay)
    dest = {ax = ax, ay = ay}
    stuck, last_pos, next_step_at = 0, nil, 0
end

function status()
    local ax, ay = center_pos()
    local where = ax and (ax .. ',' .. ay) or '?'
    print(('adv/map-travel: %s | at %s (zoom %d) | %d journey%s completed')
        :format(dest and ('heading to ' .. dest.ax .. ',' .. dest.ay) or 'idle',
            where, df.global.adventure.site_level_zoom, journeys,
            journeys == 1 and '' or 's'))
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then stop()
else status() end
