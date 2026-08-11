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

How it detects a struggle -- measured live (2026-08, an orc gripping the
player's artifact short sword): the contested item sits in YOUR inventory with
TWO `UNIT_HOLDER` general refs, yours and the other gripper's. That second
holder ref IS the tug-of-war state. (`adventure.attack.shared_it`, the
original gate, is EMPTY on the "Who will you attack?" chooser -- DF only
fills it after a target is picked -- so a button gated on it never appeared.)

The click walks DF's own WRESTLE path, replayed from the flow that actually
works in play (the attack menu is a dead end: with both grasps full the move
list is STRIKE/BLOCK only, allow_wrestle=false, and no strike screen offers a
possession move):

    1. LEAVESCREEN until the attack UI is closed
    2. feed A_WRESTLE -- the same interface reopens as "Who will you
       wrestle?" with allow_wrestle=true (that bool is the wrestle-flavor
       marker; the strike-flavored chooser has it false)
    3. select the holder's row (letter key, computed from their index in
       unit_choice minus scroll; click fallback on the row text)
    4. mode WRESTLE_GRASP lists the moves; the possession row is cl_type
       StruggleForItem with cl_index = the ITEM ID -- click its rendered
       "Gain possession of ..." text (combat_list rows only act on native
       clicks)

Verified end to end live: the full chain closed the attack UI and printed
"You struggle for / You gain possession of the Astodshasar Udistam."

Registered automatically as overlay `adv/posession.regain` (enabled by
default). Nothing to run; it is dormant except on the attack screen during a
possession struggle.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local function attack_iface() return df.global.game.main_interface.adventure.attack end

-- the contested item + the OTHER unit gripping it, if a struggle is live:
-- an item of MINE with a second UNIT_HOLDER ref naming an attackable unit
local function find_struggle()
    local a = attack_iface()
    local me = dfhack.world.getAdventurer()
    if not me or not a.open then return end
    for _, iv in ipairs(me.inventory) do
        local it = iv.item
        for _, r in ipairs(it.general_refs) do
            if r:getType() == df.general_ref_type.UNIT_HOLDER then
                local ok, uid = pcall(function() return r.unit_id end)
                if ok and uid and uid ~= me.id then
                    for idx, u in ipairs(a.unit_choice) do
                        if u.id == uid then return it, idx, u end
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
        stage = 'close',
        item_id = item.id,
        holder_id = holder.id,
        tries = 0,
        deadline = dfhack.getTickCount() + 8000,
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
    local vs = dfhack.gui.getDFViewscreen(true)
    if d.stage == 'close' then
        -- step 1: whatever attack screen is up, back all the way out
        if a.open then
            gui.simulateInput(vs, 'LEAVESCREEN')
            d.next_at = now + 250
        else
            d.stage = 'wrestle_cmd'
            d.next_at = now + 150
        end
    elseif d.stage == 'wrestle_cmd' then
        -- step 2: open the wrestle-flavored chooser ("Who will you wrestle?")
        if not a.open then
            gui.simulateInput(vs, 'A_WRESTLE')
            d.next_at = now + 350
        elseif a.allow_wrestle then
            d.stage = 'select'
            d.next_at = now + 150
        else
            -- an attack-flavored screen opened instead; close and retry
            d.stage = 'close'
            d.next_at = now + 250
        end
    elseif d.stage == 'select' then
        -- step 3: pick the holder. Their letter = position in unit_choice
        -- (visual order; first visible row = unit_choice[scroll]).
        if a.mode ~= 0 then d.stage = 'verify' return end
        local holder_pos
        for idx, u in ipairs(a.unit_choice) do   -- 0-based over df vectors
            if u.id == d.holder_id then holder_pos = idx end
        end
        if not holder_pos then
            driver = nil
            announce('Regain weapon: they are no longer on the wrestle list.')
            return
        end
        local vis = holder_pos - a.scroll_position_unit_choice
        d.tries = d.tries + 1
        if d.tries > 8 then
            driver = nil
            announce('Regain weapon: could not select their row.')
            return
        end
        if vis >= 0 and vis < 26 and d.tries % 2 == 1 then
            -- letter keys select chooser rows (the right-click-move pattern);
            -- fall back to clicking the row text on even tries
            gui.simulateInput(vs, 'CUSTOM_' .. string.char(65 + vis))
        else
            local _, ty = find_text('Who will you wrestle?')
            if ty then
                local x, y = find_text(string.char(97 + math.max(vis, 0)) .. ' Lethal', ty)
                if x then click_at(x + 2, y) end
            end
        end
        d.stage = 'verify'
        d.next_at = now + 400
    elseif d.stage == 'verify' then
        if a.mode == 0 then d.stage = 'select' d.next_at = now + 100 return end
        if a.mode == 1 then
            -- the "Really attack?" confirm (they are not hostile to you).
            -- Leave the decision to the player rather than auto-confirming.
            driver = nil
            announce('Confirm the wrestle, then click "Gain possession of".', true)
            return
        end
        local target = a.attack_unit
        if not target or target.id ~= d.holder_id then
            -- wrong unit: back out to the chooser and try again
            gui.simulateInput(vs, 'LEAVESCREEN')
            d.stage = 'select'
            d.next_at = now + 350
            return
        end
        d.stage = 'grasp'
        d.next_at = now + 200
    elseif d.stage == 'grasp' then
        -- step 4: the WRESTLE_GRASP move list; click the possession row
        if not a.open then
            driver = nil
            announce('You struggle for your weapon!', true)
            return
        end
        local x, y = find_text('Gain possession of')
        if x then
            click_at(x + 5, y)
            d.stage = 'done'
            d.next_at = now + 400
        else
            d.next_at = now + 250         -- list may still be rendering
        end
    elseif d.stage == 'done' then
        if not a.open then
            driver = nil
            announce('You struggle for your weapon!', true)
        else
            d.next_at = now + 250         -- keep watching until the deadline
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
    -- plain 'dungeonmode', NOT 'dungeonmode/Attack': on a subfocus spec the
    -- overlay framework RENDERS the widget but never calls overlay_onupdate
    -- (measured live -- manual onupdate worked, framework never fired it), so
    -- the button could never activate. Every working overlay in this suite
    -- matches the whole viewscreen and gates on its own cheap bool instead.
    viewscreens = 'dungeonmode',
    frame = {w = #LABEL, h = 1},
    -- full-grid text scans are ~12k readTile calls; 4 Hz keeps the screen
    -- responsive without lagging the game (driver steps are 100-400ms anyway)
    overlay_onupdate_max_freq_seconds = 0.25,
}

function PosessionButton:overlay_onupdate()
    -- NOT self.active: `active` is a RESERVED gui.View field, and the overlay
    -- framework's do_update skips overlay_onupdate entirely while it is falsy
    -- (measured live: active=false -> 0 framework calls ever, a self-deadlock
    -- since only onupdate could set it true). self.show is ours alone.
    self.show = false
    -- cheap authoritative gate: this overlay updates on EVERY dungeonmode
    -- frame, and the ~12k-readTile title scan must never run outside the
    -- attack screen (the watch-their-blade performance lesson)
    if not attack_iface().open then return end
    pcall(drive)
    -- park the frame right below the chooser title (attack- or wrestle-flavored)
    local ok, tx, ty = pcall(function()
        local x, y = find_text('Who will you attack?')
        if not x then x, y = find_text('Who will you wrestle?') end
        return x, y
    end)
    if not ok or not ty then return end
    if not find_struggle() then return end
    self.show = true
    local ir = gui.get_interface_rect()
    local t, l = ty + 1 - ir.y1, tx - ir.x1
    if self.frame.t ~= t or self.frame.l ~= l then
        self.frame = {w = #LABEL, h = 1, t = t, l = l}
        self:updateLayout(gui.ViewRect{rect = ir})
    end
end

function PosessionButton:onRenderBody(dc)
    if not self.show then return end
    dc:seek(0, 0):pen{fg = driver and COLOR_YELLOW or COLOR_LIGHTGREEN, bg = COLOR_BLACK}
        :string(LABEL)
end

function PosessionButton:onInput(keys)
    if not self.show then return false end
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
