-- Adventure mode: auto-click "Continue waiting" on the cannot-act prompt.
--@module = true
--[[
adv/im-sure

During long-running actions (slow walking, waiting, being pinned) the game interrupts
with a "You haven't been able to act for a while" prompt that must be acknowledged by
clicking its **Continue waiting** button. The prompt has NO dialog struct (verified:
nothing in main_interface opens; keyboard feeds don't reach it) -- only the on-screen
button works. This watches for the prompt state
(`adventure.player_control_state == TAKING_TOO_LONG_INPUT`), finds the literal button
text by READING THE SCREEN, and clicks it.

    adv/im-sure           start watching (idempotent)
    adv/im-sure stop      stop
    adv/im-sure status    running? how many clicked?
]]

running = running or false
dismissed = dismissed or 0
local gen = gen or 0

-- find a text string on the rendered screen; returns its top-left text cell + length
local function find_text(needle)
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local row = {}
        for x = 0, gps.dimx - 1 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            local ch = ok and t and t.ch or 0
            row[#row + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local i = table.concat(row):find(needle, 1, true)
        if i then return i - 1, y, #needle end
    end
end

-- click the middle of a text-cell run (text cells are gps.tile_pixel_x/y sized)
local function click_text(x, y, len)
    local gps = df.global.gps
    local cx = x + len // 2
    gps.mouse_x, gps.mouse_y = cx, y
    gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
    gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
end

-- exported: find and click "Continue waiting"; true if the button was found
function dismiss()
    local x, y, len = find_text('Continue waiting')
    if not x then x, y, len = find_text('Continue') end
    if not x then return false end
    click_text(x, y, len)
    return true
end

local function watch_loop()
    gen = gen + 1
    local my_gen = gen
    local stuck = 0
    local cooldown = 0
    local function loop()
        if not running or my_gen ~= gen then return end
        local prompt = dfhack.world.isAdventureMode()
            and df.global.adventure.player_control_state
                == df.adventure_game_loop_type.TAKING_TOO_LONG_INPUT
        if prompt then
            stuck = stuck + 1
            if cooldown > 0 then cooldown = cooldown - 1 end
            -- give the prompt a moment to render, then click; retry at ~1/second
            if stuck > 15 and cooldown <= 0 then
                if dismiss() then dismissed = dismissed + 1 end
                cooldown = 100
            end
        else
            stuck, cooldown = 0, 0
        end
        dfhack.timeout(1, 'frames', loop)
    end
    loop()
end

function stop()
    running = false
    gen = gen + 1
end

if dfhack_flags.module then return end

if not dfhack.world.isAdventureMode() then
    qerror('adv/im-sure only works in adventure mode')
end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/im-sure: stopped.')
elseif arg == 'status' then
    print(('adv/im-sure: %s, "Continue waiting" clicked %d time%s'):format(
        running and 'WATCHING' or 'stopped', dismissed, dismissed == 1 and '' or 's'))
else
    if running then
        print('adv/im-sure: already watching (' .. dismissed .. ' clicked).')
    else
        running = true
        watch_loop()
        print('adv/im-sure: watching -- "Continue waiting" will be clicked for you.')
    end
end
