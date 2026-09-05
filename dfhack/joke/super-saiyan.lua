-- A dwarf enters a martial trance: pause the game, centre on them, play the theme.
--@module = true
--@enable = true
--[[
super-saiyan

A martial trance is the best thing a dwarf can do and DF tells you about it in a line of grey
text you will miss. This gives the moment its due: the instant a citizen enters a martial
trance the game PAUSES, the CAMERA FOLLOWS THEM, and the Ultra Instinct theme plays in full.
The camera is held for as long as the theme runs and handed back when it stops -- to whoever
it was following before, if anyone.

There WAS a cursor blinking on the dwarf's tile for three seconds. It drew in the wrong
place: it assumed the map viewport's top-left cell is screen (0,0), so `pos - window` is the
screen cell, and that is not where DF puts the map. Rather than leave a marker pointing at
the wrong dwarf, it is gone -- the view is centred on them anyway, which is the thing that
actually finds them.

  enable joke/super-saiyan    watch for martial trances
  disable joke/super-saiyan   stop watching
  super-saiyan                status
  super-saiyan test           do the whole thing on a citizen right now, trance or not
  super-saiyan stop           cut the theme short

`enable` needs the FOLDER in the name -- `enable super-saiyan` answers "No such plugin or
Lua script", because DFHack resolves an enableable script by its full script path.

`stop` ends the current celebration without disabling the watcher: the theme runs 167
seconds and a trance in the middle of a siege is not always a moment to sit through. The
next trance fires as normal.

ONE AT A TIME. While the theme is playing, a further trance is skipped entirely -- no sound,
no pause, no camera jump. Sieges produce trances in clusters and each one restarting the
track from the top would be a stutter, not a celebration. The test is "is the plugin playing
right now", not a stopwatch, so replacing the track with one of a different length needs no
change here and `stop` frees the next trance to fire immediately.

`test` is exempt: asking for it explicitly restarts the theme whatever is playing.

WHAT COUNTS. `unit.counters.soldier_mood == MartialTrance`, on the RISING edge per unit: a
trance lasts a while, so the flag is remembered until it clears and one trance fires once.
Only citizens -- a goblin lieutenant's trance is not a moment to celebrate. The scan is over
units.active and runs every few frames, which is cheap enough to leave on forever.

THE SOUND needs the `ssaudio` plugin, which is in this repo under plugins/ and plays an mp3
through its own SDL audio device (`make build-ssaudio`). DFHack's Lua sandbox has no audio
call and no way out to a shell -- os.execute and io.popen are both nil -- so a plugin is the
only way to play an arbitrary file. Without it everything else still happens and the theme is
simply silent; the status line says so.

The track is read from `dfhack-config/music/` -- the folder joke/dwarfify scans -- falling
back to `dfhack-config/scripts/data/` where it used to live.

PAUSING IS THE FIRST THING IT DOES, so anything that has to happen afterwards cannot be
driven by frame timers or game ticks -- a paused fort advances neither. The theme is handed
to the ssaudio plugin, which plays on its own thread and is unaffected.
]]

local GLOBAL_KEY = 'super-saiyan'
local CHECK_FRAMES = 5             -- trances are rare; no need to look every frame

-- ONE PLACE FOR MUSIC. joke/dwarfify made dfhack-config/music/ the folder every tool's tracks
-- live in, so this looks there first and keeps its old home as a fallback for installs that
-- have not moved the file.
local MUSIC_DIR = dfhack.getDFPath() .. '/dfhack-config/music/'
local OLD_HOME = dfhack.getDFPath() .. '/dfhack-config/scripts/data/'
local THEME = (dfhack.filesystem.exists(MUSIC_DIR .. 'ultra_instinct_theme.mp3')
    and MUSIC_DIR or OLD_HOME) .. 'ultra_instinct_theme.mp3'

-- ---- the sound ---------------------------------------------------------------

-- the plugin is optional: without it the pause and the camera snap still happen
local function audio()
    local ok, plug = pcall(require, 'plugins.ssaudio')
    if ok and plug and plug.play then return plug end
end

-- Is the theme still going from an earlier trance? Asked of the plugin rather than measured
-- against a 167-second stopwatch: the file can be replaced with one of any length, and a
-- `super-saiyan stop` (or an ssaudio stop) ends it early, which a timer would not know about.
-- The plugin counts its decode as playing too, so two dwarves entering a trance in the same
-- scan cannot both get through.
local function theme_playing()
    local plug = audio()
    if not plug or not plug.is_playing then return false end
    local ok, playing = pcall(plug.is_playing)
    return ok and playing or false
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

local function is_trancing(unit)
    return unit.counters.soldier_mood == df.soldier_mood_type.MartialTrance
end

-- Whoever the camera was following before we grabbed it, so `stop` can hand it back rather
-- than leaving it wherever the trance left it.
followed_before = followed_before or nil

local function celebrate(unit)
    df.global.pause_state = true
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if pos and pos.x >= 0 then
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
    end
    -- AND FOLLOW THEM. Centring once puts the camera where they were; a trance is a fight,
    -- and the whole point is watching it. DF's own follow does the work from here.
    if followed_before == nil then
        followed_before = df.global.plotinfo.follow_unit
    end
    df.global.plotinfo.follow_unit = unit.id
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

-- The camera is held for as long as the theme runs and handed back when it stops -- which is
-- the same test everything else here uses, so it works whether the theme ended on its own,
-- was cut short, or the file was swapped for one of a different length.
local function release_when_quiet()
    if followed_before ~= nil and not theme_playing() then release_camera() end
end

local function scan()
    if not dfhack.world.isFortressMode() then return end
    local now = {}
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and dfhack.units.isAlive(unit) and is_trancing(unit) then
            now[unit.id] = true
            -- ONE CELEBRATION AT A TIME. A trance that arrives while the theme is still
            -- playing passes without a sound, a pause or a camera jump: interrupting the
            -- last one to restart at bar zero is worse than letting it finish. The dwarf is
            -- still marked seen, so this is a skip rather than a celebration held in a queue
            -- to ambush you when the music stops.
            if not seen[unit.id] and not theme_playing() then celebrate(unit) end
        end
    end
    seen = now
    release_when_quiet()
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

-- Give the camera back, but only if it is still on the dwarf we put it on: if you have taken
-- the view somewhere else in the meantime, that is where you want it.
function release_camera()
    if followed_before == nil then return end
    local was = followed_before
    followed_before = nil
    df.global.plotinfo.follow_unit = was
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, seen = nil, {}
        load_state()
        if state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, seen = nil, {}
    end
end

function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

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

if cmd == 'stop' then
    local plug = audio()
    if not plug then
        print('super-saiyan: nothing to stop -- no ssaudio plugin loaded')
        return
    end
    plug.stop()
    release_camera()
    print('super-saiyan: stopped')
    return
end

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

print(('super-saiyan: %s'):format(enabled and 'ENABLED -- watching for martial trances'
    or 'disabled  (`enable super-saiyan` to watch)'))
print(('  theme: %s'):format(dfhack.filesystem.exists(THEME) and THEME or (THEME .. '  [MISSING]')))
print(('  audio: %s'):format(audio() and 'ssaudio plugin loaded'
    or 'no ssaudio plugin -- everything but the sound'))
print(('  trances celebrated here: %d'):format(state.trances))
