-- Forces the game to never pause -- including on event announcements and GUIs.
--@module = true
--@enable = true
--[[
    no-pausing            toggle on/off
    enable no-pausing     force the game to keep running
    disable no-pausing    allow normal pausing again

While active it clears the pause flag every graphical frame. Because frame
timeouts fire even while the game is paused (and while menus/announcement popups
are open), this overrides pauses from any source -- events, the GUI, or a manual
pause. Turn it off to pause again.

The setting persists with the fort.
]]

local GLOBAL_KEY = 'no-pausing'

enabled = enabled or false
generation = generation or 0

function isEnabled()
    return enabled
end

-- runs once per graphical frame; the generation guard prevents stacking loops
-- if the feature is toggled off and on again quickly
local function frame(gen)
    if not enabled or gen ~= generation then return end
    df.global.pause_state = false
    dfhack.timeout(1, 'frames', function() frame(gen) end)
end

local function start()
    if enabled then return end
    enabled = true
    generation = generation + 1
    frame(generation)
end

local function stop()
    enabled = false
    generation = generation + 1   -- invalidate any pending frame callback
end

local function persist()
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {enabled = enabled})
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        local data = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false})
        if data and data.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if dfhack_flags.enable_state then start() else stop() end
else
    -- no arguments: toggle
    if enabled then stop() else start() end
end
persist()
print('no-pausing: ' .. (enabled and 'ON  (the game will not pause)' or 'OFF'))
