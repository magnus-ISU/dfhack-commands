-- A dwarf enters a martial trance: pause, centre on them, blink a cursor, play the theme.
--@module = true
--@enable = true
--[[
super-saiyan

A martial trance is the best thing a dwarf can do and DF tells you about it in a line of grey
text you will miss. This gives the moment its due: the instant a citizen enters a martial
trance the game PAUSES, the view snaps to them, a cursor blinks on their tile for three
seconds, and the Ultra Instinct theme plays in full.

  enable super-saiyan     watch for martial trances
  disable super-saiyan    stop watching
  super-saiyan            status
  super-saiyan test       do the whole thing on a citizen right now, trance or not

WHAT COUNTS. `unit.counters.soldier_mood == MartialTrance`, on the RISING edge per unit: a
trance lasts a while, so the flag is remembered until it clears and one trance fires once.
Only citizens -- a goblin lieutenant's trance is not a moment to celebrate. The scan is over
units.active and runs every few frames, which is cheap enough to leave on forever.

THE SOUND needs the `ssaudio` plugin, which is in this repo under plugins/ and plays an mp3
through its own SDL audio device (`make build-ssaudio`). DFHack's Lua sandbox has no audio
call and no way out to a shell -- os.execute and io.popen are both nil -- so a plugin is the
only way to play an arbitrary file. Without it everything else still happens and the theme is
simply silent; the status line says so.

The track is read from `dfhack-config/scripts/data/`, beside the other data files.

TIMING IS REAL TIME, not game time, and it has to be: the first thing this does is pause, and
a paused fort advances no frames or ticks at all. The blink is driven from an overlay's
render callback against dfhack.getTickCount(), both of which keep running while paused.
]]

local overlay = require('plugins.overlay')

local GLOBAL_KEY = 'super-saiyan'
local CHECK_FRAMES = 5             -- trances are rare; no need to look every frame
local BLINK_MS = 3000              -- how long the cursor blinks for
local BLINK_PERIOD_MS = 400        -- on for half of this, off for the other half

local THEME = dfhack.getDFPath() .. '/dfhack-config/scripts/data/ultra_instinct_theme.mp3'

-- ---- the sound ---------------------------------------------------------------

-- the plugin is optional: without it the pause/centre/blink still happen
local function audio()
    local ok, plug = pcall(require, 'plugins.ssaudio')
    if ok and plug and plug.play then return plug end
end

local function play_theme()
    local plug = audio()
    if not plug then return false end
    local ok, err = pcall(plug.play, THEME)
    if not ok then
        dfhack.printerr('super-saiyan: ' .. tostring(err))
        return false
    end
    return true
end

-- ---- state -------------------------------------------------------------------

state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, trances = 0})
    end
    if state.enabled == nil then state.enabled = false end
    if state.trances == nil then state.trances = 0 end
    return state
end

local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end

-- ---- the moment --------------------------------------------------------------

-- set by a trance, read by the overlay that draws the cursor
blink = blink or nil               -- {unit_id = <id>, until_ms = <tick>}

local function is_trancing(unit)
    return unit.counters.soldier_mood == df.soldier_mood_type.MartialTrance
end

local function celebrate(unit)
    df.global.pause_state = true
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if pos and pos.x >= 0 then
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
    end
    blink = {unit_id = unit.id, until_ms = dfhack.getTickCount() + BLINK_MS}
    local sound = play_theme()
    load_state()
    state.trances = state.trances + 1
    save_state()
    dfhack.gui.showAnnouncement(
        ('%s has entered a martial trance!'):format(dfhack.units.getReadableName(unit)),
        COLOR_LIGHTCYAN, true)
    return sound
end

-- ---- the watcher -------------------------------------------------------------

-- unit ids seen trancing on the last pass, so one trance fires once rather than every scan
seen = seen or {}

local function scan()
    if not dfhack.world.isFortressMode() then return end
    local now = {}
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) and is_trancing(unit) then
            now[unit.id] = true
            if not seen[unit.id] then celebrate(unit) end
        end
    end
    seen = now
end

-- ---- service loop ------------------------------------------------------------

enabled = enabled or false
function isEnabled() return enabled end

local hb_gen = 0
local last_frame = nil

local function start()
    enabled = true
    last_frame = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local f = df.global.world.frame_counter
        if not last_frame or math.abs(f - last_frame) >= CHECK_FRAMES then
            last_frame = f
            local ok, err = pcall(scan)
            if not ok then dfhack.printerr('super-saiyan: ' .. tostring(err)) end
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, seen, blink = nil, {}, nil
        load_state()
        if state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, seen, blink = nil, {}, nil
    end
end

function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

-- ---- the blinking cursor -----------------------------------------------------

-- Drawn from an overlay because the game is PAUSED by then: frame timers and game ticks are
-- both stopped, and a render callback is the only thing still being called. The clock is
-- dfhack.getTickCount() (real milliseconds) for the same reason.
TranceCursorOverlay = defclass(TranceCursorOverlay, overlay.OverlayWidget)
TranceCursorOverlay.ATTRS{
    desc = 'Blinks a cursor on a dwarf who has just entered a martial trance.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    version = 1,
}

function TranceCursorOverlay:onRenderFrame(dc, rect)
    if not blink then return end
    local now = dfhack.getTickCount()
    if now >= blink.until_ms then blink = nil return end
    if (now % BLINK_PERIOD_MS) * 2 >= BLINK_PERIOD_MS then return end   -- the off half

    local unit = df.unit.find(blink.unit_id)
    if not unit then blink = nil return end
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if not pos or pos.x < 0 or pos.z ~= df.global.window_z then return end

    -- the map viewport's top-left cell is screen (0,0); window_x/y is the map tile drawn there
    local vp = df.global.gps.main_viewport
    local x, y = pos.x - df.global.window_x, pos.y - df.global.window_y
    if x < 0 or y < 0 or x >= vp.dim_x or y >= vp.dim_y then return end

    dfhack.screen.paintTile({ch = 'X', fg = COLOR_LIGHTCYAN, bg = COLOR_BLACK, bold = true}, x, y)
end

OVERLAY_WIDGETS = {cursor = TranceCursorOverlay}

if dfhack_flags.module then
    return
end

-- ---- command line ------------------------------------------------------------

if not dfhack.isMapLoaded() then qerror('super-saiyan needs a loaded fort') end
load_state()

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('super-saiyan: ' .. (enabled and 'enabled -- watching for martial trances' or 'disabled'))
    return
end

local cmd = ({...})[1]

if cmd == 'test' then
    local unit = dfhack.gui.getSelectedUnit(true)
    if not unit then
        for _, u in ipairs(df.global.world.units.active) do
            if dfhack.units.isCitizen(u) and dfhack.units.isAlive(u) then unit = u break end
        end
    end
    if not unit then qerror('no citizen to test on') end
    local sound = celebrate(unit)
    print(('super-saiyan: test on %s%s'):format(dfhack.units.getReadableName(unit),
        sound and '' or '  (no ssaudio plugin -- silent)'))
    return
end

require('plugins.overlay').rescan()
print(('super-saiyan: %s'):format(enabled and 'ENABLED -- watching for martial trances'
    or 'disabled  (`enable super-saiyan` to watch)'))
print(('  theme: %s'):format(dfhack.filesystem.exists(THEME) and THEME or (THEME .. '  [MISSING]')))
print(('  audio: %s'):format(audio() and 'ssaudio plugin loaded'
    or 'no ssaudio plugin -- everything but the sound'))
print(('  trances celebrated here: %d'):format(state.trances))
