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
`gps.main_map_port` in square cells of window_px_width/dim_x pixels, and the
player is always drawn at the center cell `(screen_x, screen_y)`.

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

-- mouse position -> map-port cell, or nil off the map / in the edge guard
local function mouse_cell(guard)
    local gps = df.global.gps
    local mp = gps.main_map_port
    if mp.dim_x <= 0 or mp.dim_y <= 0 then return end
    local cellpx = math.max(1, (gps.dimx * gps.tile_pixel_x) // mp.dim_x)
    local cx = gps.precise_mouse_x // cellpx
    local cy = gps.precise_mouse_y // cellpx
    if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end
    if guard and (cx < EDGE_GUARD or cx >= mp.dim_x - EDGE_GUARD
            or cy < EDGE_GUARD or cy >= mp.dim_y - EDGE_GUARD) then
        return
    end
    return cx, cy
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
    local mx, my = ax // s, ay // s
    local tx, ty = dest.ax // s, dest.ay // s
    if mx == tx and my == ty then
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
    local dx = tx > mx and 1 or tx < mx and -1 or 0
    local dy = ty > my and 1 or ty < my and -1 or 0
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
        local s = cell_scale()
        dest = {
            ax = ax + (cx - mp.screen_x) * s,
            ay = ay + (cy - mp.screen_y) * s,
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
        local mp = gps.main_map_port
        local s = cell_scale()
        local cellpx = math.max(1, (gps.dimx * gps.tile_pixel_x) // mp.dim_x)
        local cx = mp.screen_x + (dest.ax // s - ax // s)
        local cy = mp.screen_y + (dest.ay // s - ay // s)
        if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end
        -- map cells span cellpx/tile_pixel text cells; mark the cell's middle
        local tx = (cx * cellpx + cellpx // 2) // gps.tile_pixel_x
        local ty = (cy * cellpx + cellpx // 2) // gps.tile_pixel_y
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
