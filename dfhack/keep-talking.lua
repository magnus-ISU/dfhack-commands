-- Adventure mode: when a conversation menu closes, auto-reopen it with the same person.
--@module = true
--@enable = true
--[[
A conversation in adventure mode ends every time you pick a topic (the menu closes back to
the map, the NPC's reply shows, and you must re-initiate to ask the next thing). With
keep-talking ENABLED, the moment the conversation menu closes it is automatically reopened
with the same NPC -- so a conversation never "ends" until you turn keep-talking off (or walk
out of range). You keep asking questions in a flowing back-and-forth instead of re-clicking
the person for every line.

    enable keep-talking       auto-reopen conversations (this session)
    disable keep-talking      stop  (also: how you LEAVE a conversation -- disable, then
                              close the menu once more and it stays closed)
    keep-talking              toggle

Default is OFF, so nothing happens until you enable it.

HOW IT REOPENS (all through DF's own input path -- never by writing viewscreen state, which
segfaults; see the crash lesson in memory): it remembers who you're talking to (the unit
whose interaction option was open just before the conversation), and on close it re-clicks
that unit's map tile to bring up the interaction OptionList, then clicks the option that
resumes the conversation. Attacking is a SEPARATE mode in adv mode, so the default-mode
OptionList holds only talk/look/move options -- a mis-match can at worst open "look", never
an attack. If it can't clearly find the talk option it does nothing (fail-safe).

Reopen tuning lives in TALK_HINTS below -- the labels/keywords the reopen click looks for in
the OptionList. Adjust these to match your game's wording if reopen ever opens the wrong thing.

Registered as overlay `keep-talking.watcher`.

NOTE: written against the observed conversation/option-list structures but NOT yet verified
end-to-end against a live NPC -- test with a real conversation and tune TALK_HINTS if needed.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

local GLOBAL_KEY = 'keep-talking'

enabled = enabled or false
function isEnabled() return enabled end

local function mi() return df.global.game.main_interface end

-- Labels the reopen click looks for in the interaction OptionList, best first. The interlocutor's
-- own name is tried before these (it appears in the option row). Purely a screen-text match, and the
-- default-mode OptionList has no attack option, so a wrong guess is harmless (never an attack).
local TALK_HINTS = {'Talk', 'talk', 'Speak', 'Converse', 'Chat', 'Greet', 'Have a'}

-- ---- synthesized-input primitives (shared with adv/fight's approach) --------

local function feed(name)
    -- feed the real GAME viewscreen; getDFViewscreen skips dfhack overlays, and dfhack.gui
    -- .simulateInput doesn't exist. This is the only safe way to drive adv mode.
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), name)
end

-- visible map-tile count = screen pixels / S (S = map tile px = viewport_zoom_factor/4)
local function visible_tiles()
    local gps = df.global.gps
    local S = math.max(1, gps.viewport_zoom_factor // 4)
    return math.max(4, (gps.dimx * gps.tile_pixel_x) // S),
           math.max(4, (gps.dimy * gps.tile_pixel_y) // S)
end

-- center the camera on a map position, fixing z, so a click on the tile resolves there
local function center_camera(x, y, z)
    local map = df.global.world.map
    local vw, vh = visible_tiles()
    df.global.window_z = math.max(0, math.min(map.z_count - 1, z))
    df.global.window_x = math.max(0, math.min(map.x_count - vw, x - vw // 2))
    df.global.window_y = math.max(0, math.min(map.y_count - vh, y - vh // 2))
end

-- left-click map tile (tx,ty) at the current view z (clicking a UNIT's tile opens the
-- interaction OptionList; clicking empty ground would travel -- so only used on a unit tile)
local function click_tile(tx, ty)
    local gps = df.global.gps
    local S = math.max(1, gps.viewport_zoom_factor // 4)
    local px = (tx - df.global.window_x) * S + S // 2
    local py = (ty - df.global.window_y) * S + S // 2
    gps.precise_mouse_x, gps.precise_mouse_y = px, py
    gps.mouse_x = px // gps.tile_pixel_x
    gps.mouse_y = py // gps.tile_pixel_y
    feed('_MOUSE_L')
end

-- click the middle of the first on-screen text run containing `needle` (exact, case-sensitive).
-- Left-clicks on rendered text drive menus reliably. Returns true if something was clicked.
local function click_text(needle)
    local gps = df.global.gps
    for y = 0, gps.dimy - 1 do
        local chars = {}
        for x = 0, gps.dimx - 1 do
            local ok, t = pcall(dfhack.screen.readTile, x, y)
            local ch = ok and t and t.ch or 0
            chars[x] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local line = table.concat(chars, '', 0, gps.dimx - 1)
        local i = line:find(needle, 1, true)
        if i then
            local cx = (i - 1) + #needle // 2
            gps.mouse_x, gps.mouse_y = cx, y
            gps.precise_mouse_x = cx * gps.tile_pixel_x + gps.tile_pixel_x // 2
            gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
            feed('_MOUSE_L')
            return true
        end
    end
    return false
end

-- ---- interlocutor tracking --------------------------------------------------

-- the unit whose interaction option is currently offered in the OptionList (the target you'd
-- talk to). This is what precedes a conversation opening, so it identifies the interlocutor.
local function option_list_unit()
    local ol = mi().adventure.option_list
    if not ol.open then return nil end
    for i = 0, #ol.option - 1 do
        local ok, uid = pcall(function() return ol.option[i].unit_id end)
        if ok and uid and uid >= 0 then return uid end
    end
    return nil
end

-- first word of a unit's visible name, to match its row in the OptionList text
local function unit_name_token(u)
    local ok, nm = pcall(dfhack.units.getReadableName, u)
    if not ok or not nm then return nil end
    local w = nm:match('%a+')          -- first alphabetic run (e.g. "Nako")
    return (w and #w >= 3) and w or nil
end

-- ---- overlay ----------------------------------------------------------------

KeepTalking = defclass(KeepTalking, overlay.OverlayWidget)
KeepTalking.ATTRS{
    desc = 'Adventure mode: auto-reopen the conversation menu with the same person.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dungeonmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
}

function KeepTalking:reset()
    self.interlocutor = nil
    self.was_open = false
    self.job = nil
end

-- drive a pending reopen across frames. Stages:
--   'click'  -> the conversation just closed: click the interlocutor's tile to raise the OptionList
--   'select' -> the OptionList is up: click the option that resumes the conversation
-- Aborts (self.job=nil, no action) on anything unexpected -- never spams input.
function KeepTalking:drive_reopen()
    local job = self.job
    local adv = mi().adventure
    local u = df.unit.find(job.unit)
    if not u or dfhack.units.isDead(u) then self.job = nil; return end   -- gone: give up cleanly

    if job.stage == 'click' then
        -- only from the plain map view; if any menu is up, wait a few frames then give up
        local focus = dfhack.gui.getCurFocus(true)[1] or ''
        if focus ~= 'dungeonmode/Default' then
            job.tries = job.tries + 1
            if job.tries > 8 then self.job = nil end
            return
        end
        center_camera(u.pos.x, u.pos.y, u.pos.z)
        click_tile(u.pos.x, u.pos.y)
        job.stage, job.tries = 'select', 0
    elseif job.stage == 'select' then
        if adv.conversation.open then self.job = nil; return end   -- already back in conversation: done
        if adv.option_list.open then
            -- click the option that resumes talking: the interlocutor's name row first (the option
            -- shows the NPC's name), then generic talk labels. All harmless in the default OptionList.
            local token = unit_name_token(u)
            local clicked = (token and click_text(token)) or false
            if not clicked then
                for _, hint in ipairs(TALK_HINTS) do if click_text(hint) then clicked = true; break end end
            end
            self.job = nil                       -- one attempt; if it opened "look" instead, no harm
        else
            job.tries = job.tries + 1            -- OptionList hasn't rendered yet; wait, then give up
            if job.tries > 8 then self.job = nil end
        end
    end
end

function KeepTalking:overlay_onupdate()
    if not enabled then self:reset(); return end
    if not dfhack.world.isAdventureMode() then return end
    local conv = mi().adventure.conversation

    -- remember who we're talking to (the unit offered in the OptionList that precedes a conversation)
    local ou = option_list_unit()
    if ou then self.last_unit = ou end

    if conv.open then
        if self.last_unit then self.interlocutor = self.last_unit end
        self.was_open = true
        self.job = nil                           -- in a conversation: cancel any pending reopen
        return
    end

    -- conversation just closed -> queue a reopen with the same person
    if self.was_open then
        self.was_open = false
        if self.interlocutor then
            self.job = {unit = self.interlocutor, stage = 'click', tries = 0}
        end
    end

    if self.job then self:drive_reopen() end
end

OVERLAY_WIDGETS = {watcher = KeepTalking}

-- ---- enable / disable -------------------------------------------------------

local function start() enabled = true end
local function stop() enabled = false end

if dfhack_flags.module then return end

if dfhack_flags.enable ~= nil then
    if dfhack_flags.enable_state then start() else stop() end
else
    if enabled then stop() else start() end
end
require('plugins.overlay').rescan()
print('keep-talking: ' .. (enabled and 'ON -- conversations will auto-reopen with the same person.'
    or 'OFF.'))
