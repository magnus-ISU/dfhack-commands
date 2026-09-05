-- Your own music, played by Dwarf Fortress itself.
--@module = true
--@enable = true
--[[
joke/dwarfify

Adds your own tracks to the game's music, played through DF'S OWN ENGINE rather than beside
it. That is the whole point of this over `joke/super-saiyan`, which opens an audio device of
its own: a track added here goes through FMOD the way the game's own songs do, so the music
slider in Settings moves it, muting the game mutes it, and it does not play on top of whatever
DF had already started.

HOW IT REACHES THE ENGINE. `dwarfort` is stripped, but its sound code is not in dwarfort --
it lives in `libg_src_lib.so`, linked dynamically, so the whole `musicsoundst` API is exported
under its mangled names. DF also ships `g_src/music_and_sound.cpp`, which shows how the game
adds custom music itself: take an id from `next_song_id++`, call `set_song(file, id, loops)`
to hand the file to FMOD, and from then on it is an ordinary song that
`startbackgroundmusic(id)` plays. The `ssaudio` plugin resolves those three symbols and does
exactly that -- see `ssaudio.play_native`. Nothing here is a simulation of the game's music;
it IS the game's music, with your file in it.

ASKING FOR A SONG DOES NOT INTERRUPT ONE. DF's `startbackgroundmusic` plays immediately only
when nothing is playing; otherwise it puts your request in `queued_song` and the scheduler gets
to it when it likes. That is what "dwarfify plays no sound" was -- the call worked, the music
did not change. The plugin stops the current song first, so a play is a play.

WHAT THIS CANNOT DO. DF's scheduler still owns the playlist. It fades and replaces songs on
its own timetable, so a track started here plays until the game decides otherwise -- enabling
the rotation below just starts another of yours whenever it notices the game has moved on.
Fighting the scheduler outright would mean replacing DF's music system, which is a different
and much larger job.

YOUR TRACKS GO IN ONE FOLDER: `dfhack-config/music/`. Anything readable in there is a track --
that is the whole configuration, and deleting a file is how you remove one. joke/super-saiyan's
theme is installed there too, so the joke's music is available as ordinary music.

THE GAME'S OWN SONGS are pickable as well, by the names DF calls them internally: `play strange
moods`, `play mountainhome`, `play koganusan`. The list comes from `enum Song` in the
`g_src/music_and_sound_g.h` the game ships -- 121 songs, ids 0..120, which is exactly the
SONGNUM that `next_song_id` starts at in a running game, so the count is right for this build.
Treat the NAMES as a good guess rather than gospel: that header is shipped source and may sit a
version behind the binary, in which case a name could be off by an entry or two. The ids are
real either way, so `play 0` style numbers cannot drift.

    joke/dwarfify                 what is here, and what is playing
    joke/dwarfify scan            re-read dfhack-config/music/
    joke/dwarfify play <what>     a number, a filename, or one of the game's song names
    joke/dwarfify stop            stop the music
    enable joke/dwarfify          keep your tracks coming round in rotation
    disable joke/dwarfify         hand the music back to the game

Registering a file with DF's engine lasts until DF exits, so a track costs one song id the
first time it is played and is replayed by id after that.
]]

-- THE GAME'S OWN SONGS, by name. DF ships g_src/music_and_sound_g.h, and `enum Song` in it
-- is the list -- 121 of them, ids 0..120, which is exactly the SONGNUM that `next_song_id`
-- starts at in a running game. So the built-in tracks are pickable here too, by the names the
-- game calls them: `joke/dwarfify play strange moods`. Cards are the short stingers DF plays
-- between things; they are in the list because the game has them, not because you want them.
local DF_SONGS = {
    [0] = 'dwarf fortress',
    [1] = 'koganusan',
    [2] = 'expansive cavern',
    [3] = 'expansive cavern card 1',
    [4] = 'expansive cavern card 2',
    [5] = 'expansive cavern card 3',
    [6] = 'expansive cavern card 4',
    [7] = 'death spiral',
    [8] = 'hill dwarf',
    [9] = 'hill dwarf card 1',
    [10] = 'hill dwarf card 2',
    [11] = 'hill dwarf card 3',
    [12] = 'hill dwarf card 4',
    [13] = 'hill dwarf card 5',
    [14] = 'forgotten beast',
    [15] = 'forgotten beast card 1',
    [16] = 'forgotten beast card 2',
    [17] = 'forgotten beast card 3',
    [18] = 'forgotten beast card 4',
    [19] = 'forgotten beast card 5',
    [20] = 'drink and industry',
    [21] = 'vile force of darkness',
    [22] = 'vile force of darkness card 1',
    [23] = 'vile force of darkness card 2',
    [24] = 'vile force of darkness card 3',
    [25] = 'vile force of darkness card 4',
    [26] = 'vile force of darkness card 5',
    [27] = 'first year',
    [28] = 'first year card 1',
    [29] = 'first year card 2',
    [30] = 'first year card 3',
    [31] = 'first year card 4',
    [32] = 'another year',
    [33] = 'another year card 1',
    [34] = 'another year card 2',
    [35] = 'another year card 3',
    [36] = 'another year card 4',
    [37] = 'another year card 5',
    [38] = 'strike the earth',
    [39] = 'strike the earth card 1',
    [40] = 'strike the earth card 2',
    [41] = 'strike the earth card 3',
    [42] = 'strike the earth card 4',
    [43] = 'strange moods',
    [44] = 'winter entombs you',
    [45] = 'winter entombs you card 1',
    [46] = 'winter entombs you card 2',
    [47] = 'winter entombs you card 3',
    [48] = 'winter entombs you card 4',
    [49] = 'craftsdwarfship',
    [50] = 'craftsdwarfship card 1',
    [51] = 'craftsdwarfship card 2',
    [52] = 'craftsdwarfship card 3',
    [53] = 'craftsdwarfship card 4',
    [54] = 'craftsdwarfship card 5',
    [55] = 'mountainhome',
    [56] = 'mountainhome card 1',
    [57] = 'mountainhome card 2',
    [58] = 'mountainhome card 3',
    [59] = 'mountainhome card 4',
    [60] = 'mountainhome card 5',
    [61] = 'neutral card 1',
    [62] = 'neutral card 2',
    [63] = 'neutral card 3',
    [64] = 'neutral card 4',
    [65] = 'neutral card 5',
    [66] = 'neutral card 6',
    [67] = 'neutral card 7',
    [68] = 'neutral card 8',
    [69] = 'neutral card 9',
    [70] = 'neutral card 10',
    [71] = 'neutral card 11',
    [72] = 'neutral card 12',
    [73] = 'neutral card 13',
    [74] = 'neutral card 14',
    [75] = 'neutral card 15',
    [76] = 'neutral card 16',
    [77] = 'ambience blizzard',
    [78] = 'ambience cavern',
    [79] = 'ambience combat',
    [80] = 'ambience desert',
    [81] = 'ambience evil',
    [82] = 'ambience forest',
    [83] = 'ambience glacier',
    [84] = 'ambience good',
    [85] = 'ambience grasslands',
    [86] = 'ambience magma close',
    [87] = 'ambience magma far',
    [88] = 'ambience magma low',
    [89] = 'ambience rainforest',
    [90] = 'ambience river high',
    [91] = 'ambience river low',
    [92] = 'ambience river medium',
    [93] = 'ambience siege',
    [94] = 'ambience swamp',
    [95] = 'ambience tavern',
    [96] = 'ambience thunderstorm',
    [97] = 'ambience trade depot',
    [98] = 'ambience workshop',
    [99] = 'ambience outside',
    [100] = 'ambience terrifying',
    [101] = 'classic title theme',
    [102] = 'classic main theme',
    [103] = 'ambience neutral winds',
    [104] = 'ambience neutral winds 2',
    [105] = 'ambience neutral cavern',
    [106] = 'strike it again',
    [107] = 'the capital',
    [108] = 'bruising the fat',
    [109] = 'life of adventure',
    [110] = 'beyond the gates',
    [111] = 'hamlet memoirs',
    [112] = 'night creature',
    [113] = 'into the pits',
    [114] = 'sisters of war',
    [115] = 'cannibal',
    [116] = 'pony rider',
    [117] = 'two coins',
    [118] = 'losing is fun',
    [119] = 'danger room',
    [120] = 'nabidas',
}

-- ONE FOLDER, always the same one. Anything readable dropped in here is a track; that is the
-- whole configuration. joke/super-saiyan's theme is installed here too, so `play ultra` works
-- and the joke's music is available as ordinary music.
local MUSIC_DIR = dfhack.getDFPath() .. '/dfhack-config/music'

-- A PLAIN FILE, not persistent site data. What you want to listen to is not a property of a
-- fortress or even of a world, and DFHack's persistence has nothing wider than a world to
-- keep it in. A list of paths in dfhack-config is also the kind of thing you can edit in a
-- text editor, which for a playlist is a feature.
local LIST_FILE = dfhack.getDFPath() .. '/dfhack-config/dwarfify-tracks.txt'
local AUDIO_EXT = {ogg = true, mp3 = true, wav = true, flac = true}

-- {paths = {'/abs/path.ogg', ...}}, and the ids DF gave them this session
state = state or nil
ids = ids or nil          -- path -> song id, valid until DF exits
enabled = enabled or false
playing = playing or nil  -- the id we last started, to notice when DF moves on

local function load_state()
    if not state then
        state = {paths = {}}
        local f = io.open(LIST_FILE, 'r')
        if f then
            for raw in f:lines() do
                local line = raw:gsub('^%s+', ''):gsub('%s+$', '')
                -- '#' starts a comment, so the file can be annotated by hand
                if line ~= '' and line:sub(1, 1) ~= '#' then
                    state.paths[#state.paths + 1] = line
                end
            end
            f:close()
        end
    end
    if not ids then ids = {} end
    return state
end

local function save_state()
    local f = io.open(LIST_FILE, 'w')
    if not f then
        dfhack.printerr('joke/dwarfify: cannot write ' .. LIST_FILE)
        return
    end
    f:write('# joke/dwarfify -- one audio file per line, played through DF\'s own engine.\n')
    for _, path in ipairs(state.paths) do f:write(path, '\n') end
    f:close()
end

-- ---------------------------------------------------------------------------
-- the engine
-- ---------------------------------------------------------------------------

-- TWO WAYS IN, because a hot-loaded plugin has only one of them. DFHack registers a plugin's
-- Lua module when it starts, not when a plugin is loaded later, so `require` finds the module
-- file but none of its C++ functions until DF is restarted -- while the plugin's COMMAND works
-- immediately. So the command is the fallback, and everything below goes through these two
-- wrappers rather than caring which is in use.
local function lua_plugin()
    local ok, p = pcall(require, 'plugins.ssaudio')
    if ok and p and p.play_native then return p end
    return nil
end

local function have_engine()
    if lua_plugin() then return true end
    -- the command answers whether or not the Lua side is bound
    return (pcall(dfhack.run_command, 'ssaudio', 'status'))
end

-- Returns the song id DF gave the file, which is readable afterwards as musicsound.song --
-- the command cannot hand a value back, and this is the same number.
local function engine_play_file(path)
    local p = lua_plugin()
    if p then
        local id = p.play_native(path, false)
        return (id and id >= 0) and id or nil
    end
    -- The id is the one just allocated, NOT musicsound.song: `song` is what the engine is
    -- playing and it lags a frame or two behind, which had a second copy of the same file
    -- registered under a second id every time.
    local before = df.global.musicsound.next_song_id
    local ok = pcall(dfhack.run_command, 'ssaudio', 'native', path)
    local after = df.global.musicsound.next_song_id
    if not ok or after == before then return nil end
    return after - 1
end

local function engine_play_id(id)
    local p = lua_plugin()
    if p then p.play_native_id(id) return true end
    return pcall(dfhack.run_command, 'ssaudio', 'native-id', tostring(id))
end

local function engine_stop()
    local p = lua_plugin()
    if p then p.stop_native() return true end
    return pcall(dfhack.run_command, 'ssaudio', 'native-stop')
end

-- Registering a file costs an id out of DF's song table (MAXSONGNUM is 1000, the game's own
-- tracks sit below SONGNUM), so each file is registered ONCE per session and replayed by id
-- afterwards. Re-registering the same file every time would eat the table.
local function song_id(path)
    load_state()
    if ids[path] then return ids[path] end
    if not dfhack.filesystem.exists(path) then return nil, 'no such file: ' .. path end
    local id = engine_play_file(path)
    if not id then return nil, 'DF\'s engine would not load ' .. path end
    ids[path] = id
    playing = id
    return id
end

function play_index(n)
    load_state()
    local path = state.paths[n]
    if not path then return nil, ('no track %d'):format(n or -1) end
    local id, err = song_id(path)
    if not id then return nil, err end
    -- song_id() has already started it the first time round; afterwards, ask for it by id
    engine_play_id(id)
    playing = id
    return path
end

-- one of the game's own, by id
function play_builtin(id)
    if not DF_SONGS[id] then return nil, ('no built-in song %d'):format(id) end
    if not engine_play_id(id) then return nil, 'the ssaudio plugin is not loaded' end
    playing = id
    return DF_SONGS[id]
end

-- "3", "strange moods", "ultra" -- a number is a track in the folder, a word is matched
-- against the game's songs first and then against your filenames, so the obvious thing works
-- without having to know which list something is in.
function play_named(what)
    load_state()
    local n = tonumber(what)
    if n then return play_index(n) end
    local needle = tostring(what):lower()
    for id, name in pairs(DF_SONGS) do
        if name == needle then return play_builtin(id) end
    end
    for id, name in pairs(DF_SONGS) do
        if name:find(needle, 1, true) then return play_builtin(id) end
    end
    for i, path in ipairs(state.paths) do
        if path:lower():find(needle, 1, true) then return play_index(i) end
    end
    return nil, ('nothing here called "%s"'):format(tostring(what))
end

function stop()
    engine_stop()
    playing = nil
end

-- ---------------------------------------------------------------------------
-- the list
-- ---------------------------------------------------------------------------

-- Rebuilt from the folder every time rather than remembered: a playlist that is just "what is
-- in this folder" cannot go stale, and deleting a file is how you remove a track.
function scan()
    load_state()
    state.paths = {}
    if not dfhack.filesystem.isdir(MUSIC_DIR) then
        dfhack.filesystem.mkdir_recursive(MUSIC_DIR)
        return 0
    end
    local found = {}
    for _, entry in ipairs(dfhack.filesystem.listdir(MUSIC_DIR) or {}) do
        local ext = entry:match('%.(%w+)$')
        if ext and AUDIO_EXT[ext:lower()] then found[#found + 1] = entry end
    end
    table.sort(found)
    for _, entry in ipairs(found) do
        state.paths[#state.paths + 1] = MUSIC_DIR .. '/' .. entry
    end
    save_state()
    return #state.paths
end

-- ---------------------------------------------------------------------------
-- the rotation
-- ---------------------------------------------------------------------------
--
-- Not a timer over track lengths: we do not know how long a file is, and DF may fade a song
-- out early anyway. The test is what the GAME says it is playing -- when that stops being the
-- track we started, the game has moved on and it is our turn again.

hb_gen = hb_gen or 0
local next_idx = 1

local function tick()
    if not enabled then return end
    load_state()
    if #state.paths > 0 then
        local ms = df.global.musicsound
        if not playing or ms.song ~= playing then
            next_idx = next_idx % #state.paths + 1
            play_index(next_idx)
        end
    end
    dfhack.timeout(100, 'frames', tick)
end

function set_enabled(on)
    enabled = on and true or false
    hb_gen = hb_gen + 1
    if enabled then tick() end
end

function isEnabled() return enabled end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print(('joke/dwarfify: rotation %s'):format(enabled and 'on' or 'off'))
    return
end

load_state()
local args = {...}
local cmd = args[1]

if cmd == 'scan' then
    local n = scan()
    print(('joke/dwarfify: %d track%s in %s'):format(n, n == 1 and '' or 's', MUSIC_DIR))
elseif cmd == 'play' then
    local what = table.concat(args, ' ', 2)
    if what == '' then what = '1' end
    local name, err = play_named(what)
    if not name then qerror(err) end
    print(('joke/dwarfify: playing %s'):format(name))
elseif cmd == 'stop' then
    stop()
    print('joke/dwarfify: stopped')
else
    print(('joke/dwarfify: %d track%s, rotation %s, engine %s'):format(
        #state.paths, #state.paths == 1 and '' or 's',
        enabled and 'on' or 'off',
        have_engine() and (lua_plugin() and 'reachable' or 'reachable (through the command)')
          or 'no ssaudio plugin'))
    for i, path in ipairs(state.paths) do
        print(('  %2d. %s%s'):format(i, path:match('[^/]+$') or path,
            ids[path] and (' [song %d]'):format(ids[path]) or ''))
    end
    if #state.paths == 0 then
        print(('  drop audio files in %s and run `joke/dwarfify scan`'):format(MUSIC_DIR))
    end
    print(('  ...and %d of the game\'s own songs, by name: `joke/dwarfify play strange moods`')
        :format(#DF_SONGS + 1))
end
