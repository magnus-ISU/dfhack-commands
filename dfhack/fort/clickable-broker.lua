-- Trade Depot sheet: click the broker's row to open their sheet and follow them.
--@module = true
--[[
clickable-broker

The Trade Depot's info sheet tells you who your broker is, what they are doing right now and
whether they can even reach the depot -- and then does nothing with it. The three lines are
inert: the one dwarf the screen is about is the one dwarf you cannot get to from it.

  * CLICK THE BROKER BLOCK -- the icon, the "Broker: <name>" line, the job line under it, or
    the "Broker can/cannot access depot" line -- and the broker's detail sheet opens and the
    camera starts following them. The same pair of actions clickable-noble-names does for a
    noble row and clickable-squad-members does for a squad member.

    The depot sheet closes on the way out, because a camera following a dwarf behind a
    full-screen sheet is not much of a view. A broker who is off the map (away with a raid)
    gets the sheet alone, with nothing to follow.

HOW THE BLOCK IS FOUND, and why not by counting lines. The sheet's contents move: the
merchant notice above it comes and goes with the caravan, and the tab strip and item list
below it change height with the window. So the block is READ rather than measured. The
broker is resolved from the fort's own noble positions (the assignment carrying the TRADE
responsibility), and the "Broker:" line is whichever line actually has that dwarf's name on
it, in the CP437 bytes DF drew -- the same match clickable-noble-names uses, which is exact
rather than approximate on an accented name. No name on screen, no action: the click goes
back to DF untouched.

The two lines under it are claimed only while they carry text, and never when that text is
one of DF's own captions ("...requested at depot" / "No trader needed at depot"). Those three
buttons sit directly above the broker block and are drawn as the same kind of highlighted
strip, so they are named here explicitly rather than trusted to be out of reach.

Horizontally the block is one span for all three lines, measured from the render: from the
panel's own left edge -- which is where the icon is drawn -- to the end of the widest line in
the block. Dead panel to the right of that is left to DF.

Registered automatically as overlay `fort/clickable-broker.click`.
Reposition with `gui/overlay` (the widget itself draws nothing -- it is a click handler).
]]

local overlay = require('plugins.overlay')

-- ---- who the broker is -------------------------------------------------------

-- the unit assigned to a fort noble position carrying the TRADE responsibility. Same lookup
-- fort/broker-ready uses: the responsibility is the definition of "broker", not the position
-- name, which a mod is free to rename.
local function broker_unit()
    local ent
    for _, e in ipairs(df.global.world.entities.all) do
        if e.id == df.global.plotinfo.group_id then ent = e; break end
    end
    if not ent then return nil end
    local posbyid = {}
    for _, p in ipairs(ent.positions.own) do posbyid[p.id] = p end
    for _, a in ipairs(ent.positions.assignments) do
        local p = posbyid[a.position_id]
        if p and p.responsibilities.TRADE and a.histfig >= 0 then
            local hf = df.historical_figure.find(a.histfig)
            local u = hf and df.unit.find(hf.unit_id)
            if u then return u end
        end
    end
    return nil
end

-- ---- reading the rendered block ----------------------------------------------

-- the line's text as the bytes DF drew, blanks as spaces. DF renders names in CP437 and
-- translateName hands back CP437, so a name found here is an exact byte match.
-- THE PANEL ONLY. The sheet lives in the right part of the screen; the map, the alert strip and
-- the notification panel on the left are not it. Reading a whole row used to let a name drawn
-- on the left half -- a notification line, an announcement -- make that ROW look like the
-- broker's, and a click on whatever DF drew at the right end of the same row (the Trade
-- button, say) then opened the broker's sheet. The band is padded with spaces on the left so
-- column numbers stay screen columns.
local function panel_x1()
    local w = dfhack.screen.getWindowSize()
    return math.floor(w * 0.45)
end

local function line_text(y)
    local w = dfhack.screen.getWindowSize()
    local x1 = panel_x1()
    local out = {(' '):rep(x1)}
    for x = x1, w - 1 do
        local p = dfhack.screen.readTile(x, y)
        out[#out + 1] = string.char((p and p.ch and p.ch ~= 0) and p.ch or 32)
    end
    return table.concat(out)
end

-- DF's own buttons sit directly above the broker block on this sheet and are drawn as the
-- same kind of highlighted strip. They are never ours, whatever else matches.
local DF_CAPTIONS = {'requested at depot', 'trader needed at depot'}

local function is_df_button_line(text)
    for _, cap in ipairs(DF_CAPTIONS) do
        if text:find(cap, 1, true) then return true end
    end
    return false
end

-- The horizontal extent of the broker block: ONE span for all three of its lines, because
-- that is what it looks like -- a block, not three lines of differing width. Clicking the
-- dead space to the right of the short job line is still clicking the broker.
--
-- Left edge = where the PANEL's content starts, which is where the icon is drawn. It is
-- measured rather than guessed, and measured on a BLANK ROW of the panel: that row is one
-- background tile repeating, so walking left along it stops exactly at the panel's border.
-- Walking left along the block's own rows instead does not stop there -- the map beyond the
-- panel draws tiles of its own, and the walk wanders off into it, which is how a click out
-- on the map first came back as a hit.
--
-- Right edge = the last character of the widest line in the block. Panel to the right of
-- that is DF's.
local function block_span(name_y)
    local w, h = dfhack.screen.getWindowSize()
    local text = line_text(name_y)
    local first = text:find('%S')
    if not first then return nil end
    local probe = first - 1

    local ref                          -- a row of untouched panel: above the block, else below
    for _, y in ipairs({name_y - 1, name_y + 3, name_y - 2}) do
        if y >= 0 and y < h and not line_text(y):find('%S') then ref = y; break end
    end
    local x1 = probe
    local floor = panel_x1()
    if ref then
        local p = dfhack.screen.readTile(probe, ref)
        local panel = p and p.tile
        if panel and panel ~= 0 then
            while x1 > floor do
                local q = dfhack.screen.readTile(x1 - 1, ref)
                if not q or q.tile ~= panel then break end
                x1 = x1 - 1
            end
        end
    end

    local x2 = probe
    for y = name_y, name_y + 2 do
        local t = line_text(y)
        if t:find('%S') and not is_df_button_line(t) then
            local last = #(t:gsub('%s+$', '')) - 1
            if last > x2 then x2 = last end
        end
    end
    if x2 >= w then x2 = w - 1 end
    return x1, x2
end

-- The line DF drew the broker's name on, or nil. Scroll- and layout-proof: it asks what is
-- on the screen rather than where it ought to be.
function broker_name_line(unit)
    local h = select(2, dfhack.screen.getWindowSize())
    local name = dfhack.translation.translateName(dfhack.units.getVisibleName(unit))
    if #name == 0 then return nil end
    for y = 0, h - 1 do
        local text = line_text(y)
        if not is_df_button_line(text) and text:find(name, 1, true) and text:find('Broker', 1, true) then
            return y
        end
    end
end

-- is (x, y) inside the broker block? The name line, plus the two lines under it while they
-- carry text of their own -- the job and the depot-access verdict.
function hit_broker(x, y, name_y)
    if y < name_y or y > name_y + 2 then return false end
    local text = line_text(y)
    if not text:find('%S') or is_df_button_line(text) then return false end
    local x1, x2 = block_span(name_y)
    if not x1 then return false end
    return x >= x1 and x <= x2
end

-- ---- breadcrumbs ---------------------------------------------------------------

hit_log = hit_log or {}
local HIT_LOG_MAX = 8

local function record_hit(text)
    local stamp = ('%d/%d'):format(df.global.cur_year, df.global.cur_year_tick)
    table.insert(hit_log, stamp .. ' ' .. text)
    while #hit_log > HIT_LOG_MAX do table.remove(hit_log, 1) end
end

-- ---- the action --------------------------------------------------------------

local SHEET_TAB_OVERVIEW = 0

local function close_sheet()
    df.global.game.main_interface.view_sheets.open = false
end

-- CLEAR THE POSITION CACHES BEFORE OPENING. DF's Overview tab draws a dwarf's noble
-- positions by taking its COUNT from `ent_vect` and its pointers from `ep_vect`, with no
-- bounds check on the second -- so the two have to agree. DF fills them in its own sheet
-- update, which has not run yet on the frame a sheet is opened by writing these fields, and
-- the pair left behind by an earlier sheet can disagree: a non-empty `ent_vect` over an
-- emptied `ep_vect` reads a freed entity_position, and DF aborts building a std::string
-- from its null name -- SIGABRT inside render, no lua error at all
-- (crashlog/crash_2026-09-15-22-46-37.txt). Emptied together they agree at zero, and
-- `last_tick_update` tells DF the caches are stale so it refills them on its next update.
local function clear_sheet_caches(vs)
    pcall(function()
        vs.ent_vect:resize(0)
        vs.ep_vect:resize(0)
        vs.ep_vect_spouse:resize(0)
        vs.last_tick_update = 0
    end)
end

local function open_sheet(unit)
    local vs = df.global.game.main_interface.view_sheets
    clear_sheet_caches(vs)
    vs.active_sheet = df.view_sheet_type.UNIT
    vs.active_id = unit.id
    vs.active_sub_tab = SHEET_TAB_OVERVIEW   -- written only as the sheet is opened
    vs.open = true                           -- ...and `open` last
end

local function unit_pos(unit)
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if not pos or pos.x < 0 then return nil end
    return pos
end

-- THE SHEET IS OPENED ON A LATER FRAME, and it has to be: this click arrives while the depot
-- sheet is up, and closing that sheet tears down whatever view_sheets is showing -- including
-- a unit sheet opened here. So the follow happens now and the sheet is handed to an overlay
-- update, which keeps ticking when frame timers do not (a panel stops them, which is why
-- dfhack.timeout('frames') is the wrong tool on exactly this screen).
pending_sheet_id = pending_sheet_id or nil
local sheet_camera = reqscript('fort/sheet-camera')

local function goto_broker(unit)
    local pos = unit_pos(unit)
    close_sheet()
    if pos then
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
    end
    pending_sheet_id = unit.id               -- off-map (away on a raid): sheet only
end

-- ---- overlay -----------------------------------------------------------------

BrokerClickOverlay = defclass(BrokerClickOverlay, overlay.OverlayWidget)
BrokerClickOverlay.ATTRS{
    desc = "Trade Depot sheet: click the broker's row to open their sheet and follow them.",
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    -- every sub-tab of the depot sheet: the broker block is drawn beside the tab strip, and
    -- the match is by content anyway, so a tab that does not show it simply never hits
    viewscreens = 'dwarfmode/ViewSheets/BUILDING/TradeDepot',
    frame = {w = 1, h = 1},          -- draws nothing; onInput sees the whole screen anyway
    version = 1,
}

function BrokerClickOverlay:onInput(keys)
    if not keys._MOUSE_L then return false end
    local x, y = dfhack.screen.getMousePos()
    if not x or not y then return false end

    if x < panel_x1() then return false end        -- the map side of the screen is DF's
    local unit = broker_unit()
    if not unit then return false end
    local name_y = broker_name_line(unit)
    if not name_y then return false end
    if not hit_broker(x, y, name_y) then return false end

    -- A BREADCRUMB PER HIT. A click that opened the broker's sheet when it was meant for
    -- something else is the kind of thing that happens once a week and cannot be reproduced
    -- on demand, so every hit records the geometry it was decided on: `clickable-broker
    -- log` prints the last few.
    local x1, x2 = block_span(name_y)
    record_hit(('click %d,%d name_y=%d span=%s-%s row=%q'):format(
        x, y, name_y, tostring(x1), tostring(x2), (line_text(y):gsub('^%s+', ''):gsub('%s+$', ''))))

    goto_broker(unit)
    return true
end

-- The deferred half of the click. Lives on plain `dwarfmode` because by the time it runs the
-- depot sheet is shut and this overlay's own screen is gone. It does nothing at all until a
-- click asks for a sheet, which is one nil test per frame.
PendingSheetOverlay = defclass(PendingSheetOverlay, overlay.OverlayWidget)
PendingSheetOverlay.ATTRS{
    desc = 'Opens the unit sheet a click on the Trade Depot sheet asked for, once it has closed.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function PendingSheetOverlay:overlay_onupdate()
    sheet_camera.tick()
    local id = pending_sheet_id
    if not id then return end
    pending_sheet_id = nil
    local unit = df.unit.find(id)
    if unit then
        open_sheet(unit)
        -- the camera is DF's own sheet button, pressed now the sheet is up (fort/sheet-camera):
        -- it centres the unit in the map the sheet leaves visible and follows it
        local x = dfhack.units.getPosition(unit)
        if x and x >= 0 then sheet_camera.request(unit) end
    end
end

OVERLAY_WIDGETS = {click = BrokerClickOverlay, sheet = PendingSheetOverlay}

-- module-level so a running game can test the detection without firing the action
BROKER_UNIT = broker_unit

if dfhack_flags.module then
    return
end

if ({...})[1] == 'log' then
    print(('clickable-broker: %d hit%s recorded (newest last)'):format(#hit_log, #hit_log == 1 and '' or 's'))
    for _, line in ipairs(hit_log) do print('  ' .. line) end
    if #hit_log == 0 then print('  nothing yet -- the overlay has not taken a click this session') end
    return
end

require('plugins.overlay').rescan()
print('clickable-broker: registered overlay fort/clickable-broker.click')
print("  click the broker's icon, name, job or depot-access line on the Trade Depot sheet")
print('  to open their sheet and follow them. `clickable-broker log` shows recent hits.')
