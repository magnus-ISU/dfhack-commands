-- Lua side of the ssaudio plugin.
--
-- `require('plugins.ssaudio')` does NOT find a plugin on its own: DFHack resolves
-- plugins.<name> to a real file under hack/lua/plugins/, and mkmodule is what binds the
-- plugin's exported C++ functions into it. A plugin that exports Lua functions but ships no
-- such file loads fine, shows up in `plug`, and is still unreachable from Lua -- which is
-- exactly how this looked before this file existed.
--
-- From the C++ side: play(path, volume), stop(), is_playing().
local _ENV = mkmodule('plugins.ssaudio')

-- DEFAULT ARGUMENTS DO NOT SURVIVE THE BINDING. The C++ play() declares volume = 1.0f, and
-- DFHACK_LUA_FUNCTION ignores that: called with one argument it does not play at all, in
-- silence, with no error. So the default is applied here instead, where it works.
--
-- The file check is here for the same reason -- the decode runs on a worker thread, so a bad
-- path fails with nothing to see. Better a Lua error naming the file than mystery silence,
-- which is otherwise indistinguishable from a broken audio device.
local native_play = _ENV.play

function play(path, volume)
    if type(path) ~= 'string' or path == '' then
        error('ssaudio.play: needs a file path')
    end
    if not dfhack.filesystem.exists(path) then
        error('ssaudio.play: no such file: ' .. path)
    end
    return native_play(path, volume or 1.0)
end

return _ENV
