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

WHAT THIS CANNOT DO. DF's scheduler still owns the playlist. It fades and replaces songs on
its own timetable, so a track started here plays until the game decides otherwise -- enabling
the rotation below just starts another of yours whenever it notices the game has moved on.
Fighting the scheduler outright would mean replacing DF's music system, which is a different
and much larger job.

    joke/dwarfify                 what is registered, and what is playing
    joke/dwarfify add <file>...   register audio files (ogg, mp3 -- whatever FMOD reads)
    joke/dwarfify scan <dir>      register every audio file in a folder
    joke/dwarfify play [n]        play track n now (or the next one)
    joke/dwarfify forget          drop the list
    enable joke/dwarfify          keep your tracks coming round in rotation
    disable joke/dwarfify         hand the music back to the game

Tracks are remembered per install, not per fort: what you want to listen to is not a property
of a fortress. Registering a file with DF's engine lasts until DF exits, so the list is
re-registered on load.
]]

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

local function plugin()
    local ok, p = pcall(require, 'plugins.ssaudio')
    if not ok or not p or not p.play_native then return nil end
    return p
end

-- Registering a file costs an id out of DF's song table (MAXSONGNUM is 1000, the game's own
-- tracks sit below SONGNUM), so each file is registered ONCE per session and replayed by id
-- afterwards. Re-registering the same file every time would eat the table.
local function song_id(path)
    load_state()
    if ids[path] then return ids[path] end
    local p = plugin()
    if not p then return nil, 'the ssaudio plugin is not loaded' end
    if not dfhack.filesystem.exists(path) then return nil, 'no such file: ' .. path end
    local id = p.play_native(path, false)
    if not id or id < 0 then return nil, 'DF\'s engine would not load ' .. path end
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
    local p = plugin()
    -- song_id() has already started it the first time round; afterwards, ask for it by id
    if p and p.play_native_id then p.play_native_id(id) end
    playing = id
    return path
end

function stop()
    local p = plugin()
    if p and p.stop_native then p.stop_native() end
    playing = nil
end

-- ---------------------------------------------------------------------------
-- the list
-- ---------------------------------------------------------------------------

local function known(path)
    for _, p in ipairs(state.paths) do
        if p == path then return true end
    end
    return false
end

function add(path)
    load_state()
    if not dfhack.filesystem.exists(path) then return false, 'no such file: ' .. path end
    if known(path) then return false, 'already listed' end
    state.paths[#state.paths + 1] = path
    save_state()
    return true
end

function scan(dir)
    load_state()
    if not dfhack.filesystem.isdir(dir) then return 0, 'not a folder: ' .. dir end
    local n = 0
    for _, entry in ipairs(dfhack.filesystem.listdir(dir) or {}) do
        local ext = entry:match('%.(%w+)$')
        if ext and AUDIO_EXT[ext:lower()] then
            local full = dir .. '/' .. entry
            if add(full) then n = n + 1 end
        end
    end
    return n
end

function forget()
    load_state()
    local n = #state.paths
    state.paths = {}
    save_state()
    return n
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

if cmd == 'add' then
    local n = 0
    for i = 2, #args do
        local ok, err = add(args[i])
        if ok then n = n + 1 else print('  ' .. (err or 'skipped') .. ': ' .. args[i]) end
    end
    print(('joke/dwarfify: added %d track%s'):format(n, n == 1 and '' or 's'))
elseif cmd == 'scan' then
    local n, err = scan(args[2] or '')
    if err then qerror(err) end
    print(('joke/dwarfify: added %d track%s from %s'):format(n, n == 1 and '' or 's', args[2]))
elseif cmd == 'play' then
    local n = tonumber(args[2]) or 1
    local path, err = play_index(n)
    if not path then qerror(err) end
    print(('joke/dwarfify: playing %s'):format(path))
elseif cmd == 'stop' then
    stop()
    print('joke/dwarfify: stopped')
elseif cmd == 'forget' then
    print(('joke/dwarfify: forgot %d track%s'):format(forget(), '' ))
else
    local p = plugin()
    print(('joke/dwarfify: %d track%s, rotation %s, engine %s'):format(
        #state.paths, #state.paths == 1 and '' or 's',
        enabled and 'on' or 'off',
        p and (p.native_available and p.native_available() and 'reachable' or 'unreachable')
          or 'no ssaudio plugin'))
    for i, path in ipairs(state.paths) do
        print(('  %2d. %s%s'):format(i, path, ids[path] and (' [song %d]'):format(ids[path]) or ''))
    end
    if #state.paths == 0 then
        print('  add some: joke/dwarfify scan ~/Music/dwarf')
    end
end
