-- [Regain your weapon] button on the adventure "Who will you attack?" screen.
--@module = true
--[[
adv/posession

When you and someone else are struggling over possession of a weapon (yours got
grabbed, or it is stuck in them and they are pulling), the attack target screen
("Who will you attack?") gains a [Regain your weapon] button directly below the
title. Clicking it selects whoever shares the weapon with you and initiates the
Wrestle attack that struggles for possession -- no hunting through the target
list and wrestle submenus.

How it detects a struggle: the attack interface keeps the contested items in
`adventure.attack.shared_it`; the button shows only when one of those items is
in YOUR inventory AND in an attackable unit's inventory at the same time (the
tug-of-war state). The click then drives DF's own UI -- selects the holder's
row, then picks the possession-struggle wrestle move -- so the resulting attack
is 100% native.

Registered automatically as overlay `adv/posession.regain` (enabled by
default). Nothing to run; it is dormant except on the attack screen during a
possession struggle.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local function attack_iface() return df.global.game.main_interface.adventure.attack end

-- the contested item + the OTHER unit gripping it, if a struggle is live
local function find_struggle()
    local a = attack_iface()
    local me = dfhack.world.getAdventurer()
    if not me or not a.open then return end
    local mine = {}
    for _, iv in ipairs(me.inventory) do mine[iv.item.id] = true end
    for _, it in ipairs(a.shared_it) do
        if mine[it.id] then
            for idx, u in ipairs(a.unit_choice) do
                if u.id ~= me.id then
                    for _, iv in ipairs(u.inventory) do
                        if iv.item.id == it.id then return it, idx, u end
                    end
                end
            end
        end
    end
end

-- ---- screen-text helpers (the list rows are plain grid text) -----------------
local function readrow(y)
    local gps = df.global.gps
    local row = {}
    for x = 0, gps.dimx - 1 do
        local ok, t = pcall(dfhack.screen.readTile, x, y)
        local c = (ok and t and t.ch) or 32
        row[x + 1] = (c >= 32 and c < 127) and string.char(c) or ' '
    end
    return table.concat(row)
end

local function find_text(needle, from_y)
    local gps = df.global.gps
    for y = from_y or 0, gps.dimy - 1 do
        local i = readrow(y):find(needle, 1, true)
        if i then return i - 1, y end
    end
end

local function click_at(x, y)
    local gps = df.global.gps
    gps.mouse_x, gps.mouse_y = x, y
    gps.precise_mouse_x = x * gps.tile_pixel_x + gps.tile_pixel_x // 2
    gps.precise_mouse_y = y * gps.tile_pixel_y + gps.tile_pixel_y // 2
    gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
end

-- the target list rows: lines below the title whose first non-space char is a
-- single letter hotkey followed by a space ("a No Quarter: The ...")
local function option_rows(title_y)
    local gps = df.global.gps
    local rows = {}
    for y = title_y + 1, gps.dimy - 1 do
        local s = readrow(y)
        local ws, letter = s:match('^(%s*)(%l) %S')
        if letter then rows[#rows + 1] = {x = #ws, y = y, letter = letter} end
    end
    return rows
end

-- ---- the driver: select holder -> pick the possession wrestle move -----------
-- Runs a small state machine from overlay_onupdate (which fires even while the
-- game is paused on a menu). Every native step needs a rendered frame between
-- click and verify, hence the time gates.
driver = driver or nil

local function announce(msg, good)
    dfhack.gui.showAnnouncement(msg, good and COLOR_LIGHTGREEN or COLOR_LIGHTRED, true)
end

local function start_driver(item, holder_idx, holder)
    driver = {
        stage = 'select',
        item_id = item.id,
        holder_id = holder.id,
        holder_idx = holder_idx,          -- 0-based index in unit_choice
        tried = {},
        deadline = dfhack.getTickCount() + 6000,
        next_at = 0,
    }
end

local function drive()
    local d = driver
    if not d then return end
    local now = dfhack.getTickCount()
    if now < d.next_at then return end
    if now > d.deadline then
        driver = nil
        announce('Regain weapon: gave up (screen did not cooperate).')
        return
    end
    local a = attack_iface()
    if not a.open then
        driver = nil
        return
    end
    if d.stage == 'select' then
        -- click the row we believe is the holder's; verified next step, wrong
        -- picks back out (mode=0) and try the remaining rows one by one
        if a.mode ~= 0 then a.mode = 0 d.next_at = now + 200 return end
        local _, ty = find_text('Who will you attack?')
        if not ty then d.next_at = now + 200 return end
        local rows = option_rows(ty)
        local pick
        -- best guess first: the holder's position in the visible list
        local guess = d.holder_idx - a.scroll_position_unit_choice
        if rows[guess + 1] and not d.tried[guess + 1] then pick = guess + 1 end
        if not pick then
            for i in ipairs(rows) do
                if not d.tried[i] then pick = i break end
            end
        end
        if not pick then
            driver = nil
            announce('Regain weapon: could not find their row on screen.')
            return
        end
        d.tried[pick] = true
        click_at(rows[pick].x + 3, rows[pick].y)
        d.stage = 'verify'
        d.next_at = now + 400
    elseif d.stage == 'verify' then
        if a.mode == 0 then d.stage = 'select' d.next_at = now + 100 return end
        local target = a.attack_unit
        if not target or target.id ~= d.holder_id then
            a.mode = 0                    -- wrong unit: back out, try the next row
            d.stage = 'select'
            d.next_at = now + 300
            return
        end
        if a.mode == 1 then
            -- the "Really attack the ...?" confirm (they are not hostile to you).
            -- Leave the decision to the player rather than auto-confirming.
            driver = nil
            announce('Confirm the attack, then pick the possession move.', true)
            return
        end
        d.stage = 'wrestle'
        d.next_at = now + 200
    elseif d.stage == 'wrestle' then
        -- the move menu is up for the holder: pick the possession struggle.
        -- Try the most specific label first, then open the wrestle submenu.
        for _, needle in ipairs({'possession', 'Possession', 'Struggle', 'Wrestle'}) do
            local x, y = find_text(needle)
            if x then
                click_at(x + 2, y)
                d.clicked = needle
                d.stage = 'confirm_move'
                d.next_at = now + 400
                return
            end
        end
        d.next_at = now + 300             -- menu may still be rendering
    elseif d.stage == 'confirm_move' then
        -- if picking "Wrestle" opened a submenu, click the possession entry there
        local x, y = find_text('possession')
        if not x then x, y = find_text('Possession') end
        if x and d.clicked == 'Wrestle' then
            click_at(x + 2, y)
            d.next_at = now + 400
            d.clicked = 'possession'
            return
        end
        -- success check: the attack screen closed or our unit queued an attack
        local me = dfhack.world.getAdventurer()
        local queued = false
        if me then
            for _, act in ipairs(me.actions) do
                if act.type == df.unit_action_type.Attack then queued = true end
            end
        end
        if queued or not a.open then
            driver = nil
            announce('You struggle for your weapon!', true)
        else
            d.next_at = now + 300         -- keep watching until the deadline
        end
    end
end

-- ---- overlay -----------------------------------------------------------------
local LABEL = '[Regain your weapon]'

PosessionButton = defclass(PosessionButton, overlay.OverlayWidget)
PosessionButton.ATTRS{
    desc = 'Adds a Regain-your-weapon button to the adventure attack screen.',
    default_pos = {x = 40, y = 20},
    default_enabled = true,
    viewscreens = 'dungeonmode/Attack',
    frame = {w = #LABEL, h = 1},
    -- full-grid text scans are ~12k readTile calls; 4 Hz keeps the screen
    -- responsive without lagging the game (driver steps are 100-400ms anyway)
    overlay_onupdate_max_freq_seconds = 0.25,
}

function PosessionButton:overlay_onupdate()
    pcall(drive)
    -- park the frame right below the "Who will you attack?" title
    local ok, tx, ty = pcall(function()
        local x, y = find_text('Who will you attack?')
        return x, y
    end)
    self.active = false
    if not ok or not ty then return end
    if not find_struggle() then return end
    self.active = true
    local ir = gui.get_interface_rect()
    local t, l = ty + 1 - ir.y1, tx - ir.x1
    if self.frame.t ~= t or self.frame.l ~= l then
        self.frame = {w = #LABEL, h = 1, t = t, l = l}
        self:updateLayout(gui.ViewRect{rect = ir})
    end
end

function PosessionButton:onRenderBody(dc)
    if not self.active then return end
    dc:seek(0, 0):pen{fg = driver and COLOR_YELLOW or COLOR_LIGHTGREEN, bg = COLOR_BLACK}
        :string(LABEL)
end

function PosessionButton:onInput(keys)
    if not self.active then return false end
    if keys._MOUSE_L and self:getMousePos() then
        if not driver then
            local item, idx, holder = find_struggle()
            if item then
                -- unit_choice iteration was 1-based via ipairs on a df vector? No:
                -- ipairs on df vectors is 0-based in DFHack -- idx is already 0-based.
                start_driver(item, idx, holder)
                announce('Regaining your ' .. dfhack.items.getDescription(item, 0) .. '...', true)
            end
        end
        return true
    end
    return false
end

OVERLAY_WIDGETS = {regain = PosessionButton}

if dfhack_flags and dfhack_flags.module then return end

require('plugins.overlay').rescan()
print('adv/posession: [Regain your weapon] appears on the attack screen during a')
print('possession struggle (overlay adv/posession.regain, enabled by default).')
