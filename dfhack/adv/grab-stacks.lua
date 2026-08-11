-- Adventure mode: grab whole stacks without the "how many?" screen.
--@module = true
--[[
adv/grab-stacks

Clicking a stack row in the "What do you want to do?" pickup menu ("Get ...
copper coins [512]") opens a "Pick up how many? (0-N)" screen: a slider, a
number, and an Okay button that ONLY responds to a mouse click (measured: fed
SELECT and typed digits both do nothing -- the screen is mouse-only). Almost
always you want the whole stack, so that screen is a pointless extra click.

With this running:

  - Click a stack row anywhere EXCEPT its [N] count and the amount screen is
    accepted for you instantly at its default -- the full stack. One click
    grabs all 512 coins.
  - Click ON the [N] count and the amount screen stays up for you to pick a
    number, exactly as before.
  - On the amount screen (however you got there), Enter or any LETTER key now
    accepts the shown number -- no more hunting for the Okay button.

    adv/grab-stacks           start watching (idempotent)
    adv/grab-stacks stop      stop
    adv/grab-stacks status    running? how many handled?

Internals, measured live on 0.53.x:

  - The amount screen is `main_interface.adventure.option_list`: clicking a
    stack row sets `doing_pickup_amount` with `pickup_amount_index` = the row,
    `pickup_amount_max` = stack size, and `number_amount` DEFAULTING TO MAX --
    so accepting immediately means "take all". Accepting = clicking the
    rendered "Okay" text (im-sure pattern); the struct's `entering_number` /
    `number_str` typed-entry state never activates on this build.
  - "Did the click land on the number?" is decided by watching the hovered
    text row while the list is open: one 192-cell row read per frame, gated on
    `option_list.open` and only while NOT on the amount screen. The [N] span
    is found with a `%[%d+%]` match against the mouse column. When
    `doing_pickup_amount` flips true, the last hover verdict decides.
  - Keyboard accept is an overlay onInput hook (sortoverlay pattern): while
    the amount screen is up, SELECT or any letter (STRING_A065-090/097-122)
    sets the accept flag and is consumed. The click itself happens in
    onupdate, never inside onInput (no reentrant simulateInput).

Driven by an OVERLAY: menus freeze frame timers, onupdate keeps firing.
]]

local overlay = require('plugins.overlay')

-- always-on: nil (never touched this session) counts as running, so the
-- overlay works from the first frame of a fresh DF session; `stop` still
-- pauses it. The overlay's enabled flag is the persistent switch.
if running == nil then running = true end
skipped = skipped or 0        -- amount screens auto-accepted after a row click
key_accepts = key_accepts or 0 -- amount screens accepted via Enter/letter

local ACCEPT_RETRY_MS = 100   -- gap between Okay-click attempts
local ACCEPT_GIVE_UP_MS = 2000 -- stop trying if the screen won't accept
local HOVER_FRESH_MS = 1500   -- hover verdict older than this doesn't auto-skip

local function option_list()
    return df.global.game.main_interface.adventure.option_list
end

-- Find a string on the rendered screen; returns its top-left text cell + length.
-- ~10k readTile calls -- only ever called while the amount screen is up and an
-- accept is pending (transient, never steady-state).
local function find_text(needle)
    local gps = df.global.gps
    local readTile, char = dfhack.screen.readTile, string.char
    local dimx, dimy = gps.dimx, gps.dimy
    local fx, fy, flen
    pcall(function()
        local row = {}
        for y = 0, dimy - 1 do
            for x = 0, dimx - 1 do
                local t = readTile(x, y)
                local ch = t and t.ch or 0
                row[x + 1] = (ch >= 32 and ch < 127) and char(ch) or ' '
            end
            local i = table.concat(row, '', 1, dimx):find(needle, 1, true)
            if i then fx, fy, flen = i - 1, y, #needle return end
        end
    end)
    return fx, fy, flen
end

-- click the middle of a text-cell run
local function click_text(x, y, len)
    local gps = df.global.gps
    local cx = x + len // 2
    gps.mouse_x, gps.mouse_y = cx, y
    gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
    gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
    require('gui').simulateInput(dfhack.gui.getCurViewscreen(true), '_MOUSE_L')
end

-- Is the mouse over a "[N]" stack count on its own screen row? One row read
-- (<=192 cells); every frame's verdict overwrites the last, so scrolling the
-- list under a stationary mouse stays correct.
local function mouse_on_stack_count()
    local gps = df.global.gps
    local mx, my = gps.mouse_x, gps.mouse_y
    if mx < 0 or my < 0 or my >= gps.dimy or mx >= gps.dimx then return false end
    local row = {}
    local ok = pcall(function()
        for x = 0, gps.dimx - 1 do
            local t = dfhack.screen.readTile(x, my)
            local ch = t and t.ch or 0
            row[x + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
    end)
    if not ok then return false end
    local line, init = table.concat(row), 1
    while true do
        local s, e = line:find('%[%d+%]', init)
        if not s then return false end
        if mx >= s - 1 and mx <= e - 1 then return true end
        init = e + 1
    end
end

-- watcher state (locals, reset on reload -- counters above persist)
local was_doing = false
local hover_on_count, hover_at = false, 0
local accept_pending, accept_from_key = false, false
local accept_until, retry_at = 0, 0

local function request_accept(from_key)
    accept_pending, accept_from_key = true, from_key
    accept_until = dfhack.getTickCount() + ACCEPT_GIVE_UP_MS
    retry_at = 0
end

local function step()
    if not running or not dfhack.world.isAdventureMode() then return end
    local ol = option_list()
    local now = dfhack.getTickCount()

    if not ol.open then
        was_doing, accept_pending = false, false
        return
    end

    if not ol.doing_pickup_amount then
        -- list view: track whether the mouse sits on a row's [N] count, so the
        -- click that opens the amount screen carries a verdict with it
        hover_on_count, hover_at = mouse_on_stack_count(), now
        if was_doing then was_doing = false end
        accept_pending = false
        return
    end

    -- amount screen is up
    if not was_doing then
        was_doing = true
        -- opened by a row click: auto-accept unless that click was ON the count
        -- (a stale hover verdict -- e.g. screen opened some other way -- skips nothing)
        if not hover_on_count and now - hover_at < HOVER_FRESH_MS then
            request_accept(false)
        end
    end

    if accept_pending then
        if now > accept_until then
            accept_pending = false
        elseif now >= retry_at then
            retry_at = now + ACCEPT_RETRY_MS
            local x, y, len = find_text('Okay')
            if x then
                click_text(x, y, len)
                if accept_from_key then key_accepts = key_accepts + 1
                else skipped = skipped + 1 end
                accept_pending = false
            end
        end
    end
end

-- true if the pressed keys include Enter or a letter
local function is_accept_key(keys)
    if keys.SELECT then return true end
    for k in pairs(keys) do
        local code = tonumber(type(k) == 'string' and k:match('^STRING_A(%d+)$') or nil)
        if code and ((code >= 65 and code <= 90) or (code >= 97 and code <= 122)) then
            return true
        end
    end
    return false
end

-- ---- overlay driver ---------------------------------------------------------

GrabStacks = defclass(GrabStacks, overlay.OverlayWidget)
GrabStacks.ATTRS{
    desc = 'Drives adv/grab-stacks: one click takes a whole stack; Enter/letters accept the amount screen.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = 1, h = 1},
}

function GrabStacks:overlay_onupdate()
    pcall(step)
end

function GrabStacks:onInput(keys)
    if not running or not dfhack.world.isAdventureMode() then return false end
    local ok, handled = pcall(function()
        local ol = option_list()
        if ol.open and ol.doing_pickup_amount and is_accept_key(keys) then
            request_accept(true)   -- the Okay click happens in onupdate
            return true
        end
        return false
    end)
    return ok and handled or false
end

OVERLAY_WIDGETS = {watch = GrabStacks}

function stop()
    running = false
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/grab-stacks: stopped.')
elseif arg == 'status' then
    print(('adv/grab-stacks: %s | stacks grabbed in one click x%d | key-accepts x%d')
        :format(running and 'WATCHING' or 'stopped', skipped, key_accepts))
else
    if not dfhack.world.isAdventureMode() then
        qerror('adv/grab-stacks only works in adventure mode')
    end
    running = true
    overlay.rescan()
    print('adv/grab-stacks: watching -- click a stack (not its [N]) to grab it all;'
        .. ' Enter or any letter accepts the amount screen.')
end
