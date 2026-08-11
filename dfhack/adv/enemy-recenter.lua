-- Adventure mode: a "Recenter on enemy" button while you're in combat.
--@module = true
--[[
adv/enemy-recenter

While the adventurer is in combat -- by the SAME judgement adv/reveal hides the
map with (a shared Conflict activity with a foe that matters; see
reveal.combat_foes) -- this adds a "Recenter on enemy" button directly above
DF's own "Recenter on yourself" button in the bottom-right corner, wearing the
same graphic. Click it and the camera jumps to the foe that put you in combat,
and a selection box (fort/dwarf-rts's art) flashes on that unit for a couple of
seconds. More than one foe? Each click cycles to the next. DF's own button --
right below -- takes you home, so the pair reads as one recenter rocker:
enemy above, yourself below. When combat ends the button disappears.

    adv/enemy-recenter           start watching (idempotent)
    adv/enemy-recenter stop      stop
    adv/enemy-recenter status    running? how many recenters?

Internals, measured live on 0.53.x:

  - "In combat" and "which unit" both come from reqscript('adv/reveal')
    .combat_foes(), so combat means one thing across the suite. Rescanned at
    most every COMBAT_SCAN_MS via overlay onupdate (activities are tens of
    entries; cheap).
  - The native button is the 4x3 cell block at (dimx-4..dimx-1,
    dimy-7..dimy-5): hovering it reads main_hover_instruction
    ADVENTURE_RECENTER, and gps.screentexpos there carries its art. "Same
    graphic" is literal: each render copies those 12 live texpos values and
    stamps them at this widget's position, so theme, scale and hover state
    always match.
  - DF HIDES its button while the view is centered on the player (measured:
    the 12 cells all read texpos 0 then) -- and ours must NOT vanish with it,
    that's exactly when you want to find your enemy. So the last-seen art is
    cached and drawn whenever the native cells are blank. Texpos values are
    dynamic atlas indices, stable within a session but not across restarts, so
    the cache can't be persisted -- if combat starts before the native button
    was ever drawn (fresh session, never scrolled), the widget samples it: it
    nudges window_x one tile for a frame or two, which makes DF draw its
    button, caches the art, and puts the camera back. One retry per
    NUDGE_RETRY_MS if a menu blocks the sample; the nudge always restores.
  - A window_x/y write STICKS in adventure mode while the player is idle
    (measured: +10 survived >2s); DF recenters when the player next acts,
    which is exactly the native-button flow in reverse. So recentering is one
    write, not a per-frame fight.
  - The flash is dwarf-rts's selection art -- CURSORS(4,23), painted map-aware
    through guidm.Viewport + paintTile(map=true) -- blinking FLASH_ON_MS on /
    off for FLASH_MS, red ASCII fallback glyph for "enemy".
]]

local overlay = require('plugins.overlay')
local guidm = require('gui.dwarfmode')
local reveal = reqscript('adv/reveal')

-- always-on: nil (never touched this session) counts as running, so the
-- overlay works from the first frame of a fresh DF session; `stop` still
-- pauses it. The overlay's enabled flag is the persistent switch.
if running == nil then running = true end
recenters = recenters or 0     -- button clicks that moved the camera
foes_now = foes_now or 0       -- last scan's foe count -- a GLOBAL because the CLI
                               -- re-executes this env per invocation, resetting locals;
                               -- status must read state the widget's closures update

local COMBAT_SCAN_MS = 250     -- how often to re-ask reveal who we're fighting
local FLASH_MS = 2500          -- how long the selection box flashes
local FLASH_ON_MS = 250        -- blink cadence (on/off phase length)

-- native "Recenter on yourself" button: 4x3 text cells flush to the
-- bottom-right corner, two rows above the bottom toolbar
local BTN_W, BTN_H = 4, 3
local function native_button_origin()
    local gps = df.global.gps
    return gps.dimx - BTN_W, gps.dimy - 7
end

-- the flash marker: fort/dwarf-rts's selection box art (its SELECT_PEN), red
-- ASCII-fallback glyph because this one marks an enemy
local FLASH_PEN = dfhack.pen.parse{ch = 250, fg = COLOR_LIGHTRED, keep_lower = true,
                                   tile = dfhack.screen.findGraphicsTile('CURSORS', 4, 23)}
local TIP_PEN = {fg = COLOR_WHITE, bg = COLOR_BLACK}
local TIP_TEXT = 'Recenter on enemy'

-- pens that stamp a copied interface texpos; cached, they're reused every frame
local copy_pens = {}
local function copy_pen(texpos)
    local pen = copy_pens[texpos]
    if not pen then
        pen = dfhack.pen.parse{ch = 219, fg = COLOR_GREY, tile = texpos}
        copy_pens[texpos] = pen
    end
    return pen
end

-- watcher state (locals, reset on reload -- counters above persist)
local foe_ids = {}             -- ids of the foes that make this fight real
local next_scan = 0
local target_i = 0             -- cycling click target (index into foe_ids)
local flash_id, flash_until = nil, 0

-- the native button's art, cached because DF hides its button (all cells
-- texpos 0) while the view is centered on the player. Refreshed from every
-- live sighting; sampled via a one-tile window nudge when there's never been
-- one (see header). art_cache[dy * BTN_W + dx + 1] = texpos.
local NUDGE_RETRY_MS = 5000    -- how long to wait before re-attempting a failed sample
local NUDGE_GIVE_UP_MS = 1000  -- how long one sample attempt may hold the nudge
local art_cache = nil
local nudge_saved_x = nil      -- window_x to restore, non-nil while nudged
local nudge_wrote_x = nil      -- what we set window_x to (restore only if untouched)
local nudge_deadline, nudge_next_try = 0, 0

local function end_nudge()
    if nudge_saved_x and df.global.window_x == nudge_wrote_x then
        df.global.window_x = nudge_saved_x   -- untouched: put the camera back
    end
    nudge_saved_x, nudge_wrote_x = nil, nil
end

-- read the native button's 12 cells; returns the flat art table, or nil if
-- the native button isn't currently drawn
local function read_native_art()
    local gps = df.global.gps
    local bx, by = native_button_origin()
    local dimy = gps.dimy
    local art, any = {}, false
    for dy = 0, BTN_H - 1 do
        for dx = 0, BTN_W - 1 do
            local texpos = gps.screentexpos[(bx + dx) * dimy + (by + dy)]
            art[dy * BTN_W + dx + 1] = texpos
            if texpos ~= 0 then any = true end
        end
    end
    return any and art or nil
end

local function rescan(now)
    next_scan = now + COMBAT_SCAN_MS
    foe_ids = {}
    for _, u in ipairs(reveal.combat_foes()) do
        if u then foe_ids[#foe_ids + 1] = u.id end
    end
    foes_now = #foe_ids
end

local function visible()
    return running and #foe_ids > 0 and dfhack.world.isAdventureMode()
end

-- one-shot: center the map window on pos (the write sticks until the player acts)
local function center_window(pos)
    local vp = guidm.Viewport.get()
    local w, h = vp.x2 - vp.x1 + 1, vp.y2 - vp.y1 + 1
    local map = df.global.world.map
    df.global.window_x = math.max(0, math.min(pos.x - w // 2, map.x_count - w))
    df.global.window_y = math.max(0, math.min(pos.y - h // 2, map.y_count - h))
    df.global.window_z = pos.z
end

local function on_click()
    if #foe_ids == 0 then return end
    target_i = target_i % #foe_ids + 1
    local u = df.unit.find(foe_ids[target_i])
    if not u then return end
    center_window(u.pos)
    flash_id = u.id
    flash_until = dfhack.getTickCount() + FLASH_MS
    recenters = recenters + 1
end

-- ---- overlay widget ---------------------------------------------------------

EnemyRecenter = defclass(EnemyRecenter, overlay.OverlayWidget)
EnemyRecenter.ATTRS{
    desc = 'Drives adv/enemy-recenter: adds a "Recenter on enemy" button while in combat.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    -- one blank row above the native recenter button, same right edge
    default_pos = {x = -1, y = -9},
    frame = {w = BTN_W, h = BTN_H},
    overlay_onupdate_max_freq_seconds = 0,
}

function EnemyRecenter:overlay_onupdate()
    pcall(function()
        if not running or not dfhack.world.isAdventureMode() then return end
        local now = dfhack.getTickCount()
        if now >= next_scan then rescan(now) end
    end)
end

function EnemyRecenter:onRenderBody(dc)
    pcall(function()
        if not visible() then
            end_nudge()
            return
        end
        -- wear the native button's current art, cell for cell; a live sighting
        -- always refreshes the cache (it carries the current theme and scale)
        local now = dfhack.getTickCount()
        local live = read_native_art()
        if live then
            art_cache = live
            end_nudge()
        elseif not art_cache then
            -- never seen it: nudge the window one tile so DF draws its button
            -- next frame, then read_native_art() above catches it and restores
            if nudge_saved_x then
                if now > nudge_deadline then    -- something blocked the sample
                    end_nudge()
                    nudge_next_try = now + NUDGE_RETRY_MS
                end
            elseif now >= nudge_next_try then
                nudge_saved_x = df.global.window_x
                nudge_wrote_x = nudge_saved_x + (nudge_saved_x > 0 and -1 or 1)
                df.global.window_x = nudge_wrote_x
                nudge_deadline = now + NUDGE_GIVE_UP_MS
            end
        end
        local art = live or art_cache
        if art then
            for dy = 0, BTN_H - 1 do
                for dx = 0, BTN_W - 1 do
                    local texpos = art[dy * BTN_W + dx + 1]
                    if texpos ~= 0 then
                        dc:seek(dx, dy):char(219, copy_pen(texpos))
                    end
                end
            end
        end
        -- hover tip, drawn to the left of the button (outside our frame, so absolute)
        local rect = self.frame_rect
        if rect and self:getMousePos() then
            local tx = math.max(0, rect.x1 - #TIP_TEXT - 1)
            dfhack.screen.paintString(TIP_PEN, tx, rect.y1 + BTN_H // 2, TIP_TEXT)
        end
        -- the flashing selection box on the targeted foe
        if flash_id and now < flash_until then
            if (now // FLASH_ON_MS) % 2 == 0 then
                local u = df.unit.find(flash_id)
                if u and not u.flags2.killed and not u.flags1.inactive then
                    local vp = guidm.Viewport.get()
                    local pos = xyz2pos(u.pos.x, u.pos.y, u.pos.z)
                    if vp:isVisible(pos) then
                        local s = vp:tileToScreen(pos)
                        dfhack.screen.paintTile(FLASH_PEN, s.x, s.y, nil, nil, true)
                    end
                else
                    flash_id = nil
                end
            end
        end
    end)
end

function EnemyRecenter:onInput(keys)
    if not keys._MOUSE_L or not visible() then return false end
    if not self:getMousePos() then return false end
    pcall(on_click)
    return true
end

OVERLAY_WIDGETS = {button = EnemyRecenter}

function stop()
    running = false
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/enemy-recenter: stopped.')
elseif arg == 'status' then
    print(('adv/enemy-recenter: %s | %d foe(s) in sight | recenters x%d')
        :format(running and 'WATCHING' or 'stopped', foes_now, recenters))
else
    if not dfhack.world.isAdventureMode() then
        qerror('adv/enemy-recenter only works in adventure mode')
    end
    running = true
    overlay.rescan()
    print('adv/enemy-recenter: watching -- in combat, a "Recenter on enemy" button'
        .. ' appears above "Recenter on yourself".')
end
