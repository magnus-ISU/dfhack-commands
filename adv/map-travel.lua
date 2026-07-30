-- Adventure travel: click the lesser world map to walk there.
--@module = true
--[[
adv/map-travel
==============

Tags: adventure | interface

On the lesser (zoomed-in) travel map, LEFT-CLICK a tile and your traveler
walks there: the overlay feeds one `A_MOVE_*` key per step toward the
destination, which DF answers by moving the army one map cell (one mid tile,
3 army-units -- verified live: one fed A_MOVE_W moved the army pos by exactly
-3).  A red X marks the destination while the journey runs.

The pathing is deliberately NAIVE: each step goes straight at the target
(8-directional).  It does not route around rivers, oceans, mountains, farms
or hostile sites -- when the straight line is blocked and the position stops
changing, the journey aborts with a console note rather than wander.

- Left-click: set / replace the destination (the click is consumed).
- Right-click: cancel the journey (consumed; right-click again to leave the
  travel screen as usual).  Leaving the travel screen also cancels.
- The greater map (`m`) is left alone.

Screen-to-tile decoding is the same as adv/read-the-map: the map renders
through `gps.main_map_port` in square cells of window_px_width/dim_x pixels,
the player army is always drawn at the center cell `(screen_x, screen_y)`,
and one lesser-map cell = one mid tile: `mid = army.pos//3 + (cell-center)`.

    adv/map-travel             status
    adv/map-travel stop        cancel the current journey
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local STEP_MS = 140        -- wall-clock pace between fed steps
local STUCK_LIMIT = 4      -- aborts after this many stepless attempts
local GAP_CANCEL_MS = 1500 -- overlay silent this long (left the screen) = cancel

journeys = journeys or 0   -- completed journeys (persists across reloads)

-- journey state (reset on reload)
local dest = nil           -- {mx=, my=} in mid tiles
local next_step_at = 0
local last_fire = 0
local stuck, last_pos = 0, nil

local DIR_KEYS = {
    [-1] = {[-1] = 'A_MOVE_NW', [0] = 'A_MOVE_N', [1] = 'A_MOVE_NE'},
    [0]  = {[-1] = 'A_MOVE_W',                    [1] = 'A_MOVE_E'},
    [1]  = {[-1] = 'A_MOVE_SW', [0] = 'A_MOVE_S', [1] = 'A_MOVE_SE'},
}

local function player_army()
    return df.army.find(df.global.adventure.player_army_id)
end

local function on_lesser_map()
    return df.global.adventure.travel_right_map == 0
end

-- mouse position -> lesser-map mid tile, or nil off the map
local function mouse_mid()
    local army = player_army()
    if not army then return end
    local gps = df.global.gps
    local mp = gps.main_map_port
    if mp.dim_x <= 0 or mp.dim_y <= 0 then return end
    local cellpx = math.max(1, (gps.dimx * gps.tile_pixel_x) // mp.dim_x)
    local cx = gps.precise_mouse_x // cellpx
    local cy = gps.precise_mouse_y // cellpx
    if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end
    return army.pos.x // 3 + (cx - mp.screen_x),
           army.pos.y // 3 + (cy - mp.screen_y)
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
    local army = player_army()
    if not army then stop_journey(nil) return end
    local mx, my = army.pos.x // 3, army.pos.y // 3
    if mx == dest.mx and my == dest.my then
        journeys = journeys + 1
        stop_journey('arrived.')
        return
    end
    local pos_key = army.pos.x .. ':' .. army.pos.y
    if pos_key == last_pos then
        stuck = stuck + 1
        if stuck >= STUCK_LIMIT then
            stop_journey('blocked -- no path straight at the target from here.')
            return
        end
    else
        stuck, last_pos = 0, pos_key
    end
    local dx = dest.mx > mx and 1 or dest.mx < mx and -1 or 0
    local dy = dest.my > my and 1 or dest.my < my and -1 or 0
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
        local mx, my = mouse_mid()
        if not mx then return false end
        dest = {mx = mx, my = my}
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
        local army = player_army()
        if not army then return end
        local gps = df.global.gps
        local mp = gps.main_map_port
        local cellpx = math.max(1, (gps.dimx * gps.tile_pixel_x) // mp.dim_x)
        local cx = mp.screen_x + (dest.mx - army.pos.x // 3)
        local cy = mp.screen_y + (dest.my - army.pos.y // 3)
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

-- exported for testing
function go(mx, my)
    dest = {mx = mx, my = my}
    stuck, last_pos, next_step_at = 0, nil, 0
end

function status()
    local army = player_army()
    local where = army and (army.pos.x // 3) .. ',' .. (army.pos.y // 3) or '?'
    print(('adv/map-travel: %s | at mid %s | %d journey%s completed')
        :format(dest and ('heading to ' .. dest.mx .. ',' .. dest.my) or 'idle',
            where, journeys, journeys == 1 and '' or 's'))
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then stop()
else status() end
