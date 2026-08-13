-- Squad details screen: click a member's portrait to open their sheet instead of the
-- position-assignment list.
--@module = true
--[[
clickable-squad-members

On a squad's details screen (Squads > pick a squad -- focus dwarfmode/Squads/Default), each
filled position shows a portrait beside the member's name. Clicking either one does the same
thing: it opens the position-assignment list, offering to replace the dwarf standing there.
Sensible for an EMPTY slot, wrong for a filled one -- the portrait is the most face-like
thing on the screen and the last thing that should mean "swap this soldier out".

So a click anywhere on a FILLED position's row -- portrait or name, the whole width of DF's
button, out to a couple of columns short of the screen edge -- opens that dwarf's own sheet
and follows them, the pair of actions `fort/clickable-noble-names` gives a noble row.

REPLACING A SOLDIER IS STILL ONE CLICK AWAY, because the row falls through to DF whenever
that dwarf's sheet is ALREADY the one on screen. So the sequence reads: click to see who
this is, click again to replace them. Nothing is taken away, and the assignment list is
never reached by accident -- you have to be looking at the dwarf you are about to replace.

  * an empty slot draws no portrait and holds no unit, so "Assign position 4" is untouched;
  * the squad name, Back to squads and the order buttons never reach this.

WHICH POSITION A LINE IS is read off the screen rather than counted, because the list
scrolls. DF labels every empty slot with its own number -- "Assign position 6" -- so any one
of those lines is an exact anchor: it fixes both the row pitch and which position index the
line holds, and every other row follows from it. When a squad is full and no such label is
on screen, the member is identified instead by testing the drawn text as a PREFIX of each
member's name, which is necessary anyway because this panel truncates ("Ineth Deler...").
If neither method resolves the line, the click is handed to DF unchanged.

The portrait is located by shape, not column: it is drawn from four consecutive
texture-atlas tiles, so it is found wherever DF has put it at whatever width the panel has
been squeezed to.

BOTH MOUSE EDGES ARE CONSUMED on a portrait -- the press and the click. Consuming only the
click leaves DF free to act on the press, which opens the assignment list anyway and makes
the overlay look dead even though it ran.

    clickable-squad-members            what the overlay decided about recent clicks
    clickable-squad-members debug      the same, with every click it saw and rejected

Registered automatically as overlay `fort/clickable-squad-members.click`.
]]

local overlay = require('plugins.overlay')

local ROW_PITCH = 3          -- a member row is three lines tall, name in the middle

local function squads_panel()
    return df.global.game.main_interface.squads
end

local function viewing_squad()
    local sq = squads_panel()
    if not sq.open then return nil end
    local idx = sq.viewing_squad_index
    if idx < 0 or idx >= #sq.squad_id then return nil end
    return df.squad.find(sq.squad_id[idx])
end

local function position_unit(pos)
    if not pos or pos.occupant < 0 then return nil end
    local hf = df.historical_figure.find(pos.occupant)
    return hf and df.unit.find(hf.unit_id) or nil
end

-- ---- what got drawn ----------------------------------------------------------

local function line_text(y)
    local w, h = dfhack.screen.getWindowSize()
    if y < 0 or y >= h then return '' end
    local out = {}
    for x = 0, w - 1 do
        local p = dfhack.screen.readTile(x, y)
        out[#out + 1] = string.char((p and p.ch and p.ch ~= 0) and p.ch or 32)
    end
    return table.concat(out)
end

-- The LAST run of text on this line, as start_x, text -- which on this screen is the squad
-- panel's, because the panel is anchored to the right edge.
--
-- Reading the FIRST run instead is a real bug that was live: with a unit sheet open, the
-- sheet's own prose fills the left of every line, so the row's geometry was measured from
-- "long." somewhere in a thought description and every click on a member missed. That is why
-- having one dwarf's sheet open made the others unclickable.
-- A name has spaces in it ("Hermias Ădrovod"), so the walk left tolerates a small gap and
-- stops only at a wide one -- the empty stretch between the panel and whatever is drawn to
-- its left, which is tens of columns.
local MAX_NAME_GAP = 4

local function panel_run(y)
    local w, h = dfhack.screen.getWindowSize()
    if y < 0 or y >= h then return nil, '' end
    local last, first, gap = nil, nil, 0
    for x = w - 1, 0, -1 do
        local p = dfhack.screen.readTile(x, y)
        if p and p.ch and p.ch > 32 then
            last = last or x
            first = x
            gap = 0
        elseif last then
            gap = gap + 1
            if gap > MAX_NAME_GAP then break end
        end
    end
    if not last then return nil, '' end
    local out = {}
    for x = first, last do
        local p = dfhack.screen.readTile(x, y)
        out[#out + 1] = string.char((p and p.ch and p.ch ~= 0) and p.ch or 32)
    end
    return first, table.concat(out)
end

-- ---- which position a line holds ---------------------------------------------

-- DF numbers its empty slots on screen ("Assign position 6"), and those numbers are the
-- position's own 1-based index -- an exact anchor that survives any scroll. Returns the
-- first one found as {y = <line>, index = <1-based position>}.
local function empty_slot_anchor()
    local _, h = dfhack.screen.getWindowSize()
    for y = 0, h - 1 do
        local n = line_text(y):match('Assign position (%d+)')
        if n then return {y = y, index = tonumber(n)} end
    end
end

-- the member whose name is drawn on this line, by prefix -- the panel truncates
local function member_by_name(squad, y)
    local _, text = panel_run(y)
    text = text:gsub('%s+$', ''):gsub('^%s+', '')
    local prefix = text:gsub('%.+$', '')
    if #prefix < 3 then return nil end
    for _, pos in ipairs(squad.positions) do
        local unit = position_unit(pos)
        if unit then
            local name = dfhack.translation.translateName(dfhack.units.getVisibleName(unit))
            if #name > 0 and name:sub(1, #prefix) == prefix then return unit end
        end
    end
end

-- the member on this line: by anchor where DF has given us one, by name otherwise. Returns
-- unit, how ('anchor' | 'name') -- `how` is only carried for the debug listing.
local function member_on_line(squad, y)
    local anchor = empty_slot_anchor()
    if anchor then
        local delta = y - anchor.y
        if delta % ROW_PITCH == 0 then
            local idx = anchor.index + math.floor(delta / ROW_PITCH)
            local pos = idx >= 1 and idx <= #squad.positions and squad.positions[idx - 1]
            local unit = position_unit(pos)
            if unit then return unit, 'anchor' end
        end
        return nil
    end
    local unit = member_by_name(squad, y)
    if unit then return unit, 'name' end
end

-- the row under the cursor: the name sits on the clicked line or one either side
local function row_at(squad, y)
    for _, name_y in ipairs({y, y - 1, y + 1}) do
        local unit, how = member_on_line(squad, name_y)
        if unit then return unit, name_y, how end
    end
end

-- THE PORTRAIT IS NOT IN THE BUFFER dfhack.screen.readTile reads. Every cell it reports
-- under the art is plain panel background, so hunting for the portrait's own tiles finds
-- nothing -- that is what made the first two attempts pass a fed click and do nothing to a
-- real one. (The one sprite-shaped block readTile does show on the row sits at the far right
-- of the panel, past the name; that is some other widget and is left alone.)
--
-- So the row is located by what IS readable: the member's name. The art is drawn in the
-- columns immediately to its left, and DF's own button -- the one that opens the assignment
-- list -- runs from there out to a couple of columns short of the screen edge. That whole
-- span is claimed: portrait and name alike open the dwarf's sheet.
local ART_WIDTH = 5
local RIGHT_MARGIN = 2       -- DF's button stops this far short of the screen edge

local function on_member_button(x, name_y)
    local start = panel_run(name_y)
    if not start then return false end
    local w = dfhack.screen.getWindowSize()
    return x >= start - ART_WIDTH and x <= w - 1 - RIGHT_MARGIN
end

-- ---- what the overlay saw, for diagnosing a click that did nothing -----------

log = log or {}
local LOG_MAX = 12

local function note(fmt, ...)
    log[#log + 1] = ('%s'):format(fmt:format(...))
    while #log > LOG_MAX do table.remove(log, 1) end
end

-- ---- the action --------------------------------------------------------------

-- Opened on a later frame: revealing the map tears a unit sheet down, and that runs after
-- this handler. The wait is an overlay update rather than dfhack.timeout, whose 'frames'
-- timers stop while a panel is up -- which is exactly the situation here.
pending_sheet_id = pending_sheet_id or nil

local SHEET_TAB_OVERVIEW = 0

-- is this dwarf's sheet the one already on screen?
local function sheet_showing(unit)
    local vs = df.global.game.main_interface.view_sheets
    return vs.open and vs.active_sheet == df.view_sheet_type.UNIT and vs.active_id == unit.id
end

local function goto_member(unit)
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if pos and pos.x >= 0 then
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
        df.global.plotinfo.follow_item = -1
        df.global.plotinfo.follow_unit = unit.id
    end
    pending_sheet_id = unit.id             -- off-map (raiding, say): sheet only
end

-- ---- overlays ----------------------------------------------------------------

SquadMemberClickOverlay = defclass(SquadMemberClickOverlay, overlay.OverlayWidget)
SquadMemberClickOverlay.ATTRS{
    desc = 'Squad details: click a member\'s portrait to open their sheet instead of the assignment list.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode/Squads/Default',
    frame = {w = 1, h = 1},        -- draws nothing; onInput sees the whole screen anyway
    version = 2,
}

function SquadMemberClickOverlay:onInput(keys)
    -- the press as well as the click: DF acts on the press, so consuming only the click
    -- lets the assignment list open regardless
    if not (keys._MOUSE_L or keys._MOUSE_L_DOWN) then return false end
    local x, y = dfhack.screen.getMousePos()
    if not x or not y then return false end

    local squad = viewing_squad()
    if not squad then note('(%s,%s) no squad being viewed', x, y) return false end

    local unit, name_y, how = row_at(squad, y)
    if not unit then note('(%s,%s) no member on lines %d-%d', x, y, y - 1, y + 1) return false end
    if not on_member_button(x, name_y) then
        note('(%s,%s) %s row (by %s) but x is off the button', x, y,
            dfhack.units.getReadableName(unit), how)
        return false
    end
    -- Already looking at this dwarf? Then the click means the other thing. Hand it to DF and
    -- the assignment list opens as it always did -- so replacing a soldier is click-to-see,
    -- click-again-to-replace rather than something this overlay has taken away.
    if sheet_showing(unit) then
        note('(%s,%s) %s sheet already open -- passing to DF', x, y,
            dfhack.units.getReadableName(unit))
        return false
    end

    note('(%s,%s) OPEN %s (by %s)', x, y, dfhack.units.getReadableName(unit), how)
    goto_member(unit)
    return true
end

-- the deferred half, on plain `dwarfmode` so it still runs after the click is over
PendingSheetOverlay = defclass(PendingSheetOverlay, overlay.OverlayWidget)
PendingSheetOverlay.ATTRS{
    desc = 'Opens the unit sheet a click on a squad member\'s portrait asked for.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
    version = 2,
}

function PendingSheetOverlay:overlay_onupdate()
    local id = pending_sheet_id
    if not id then return end
    pending_sheet_id = nil
    local unit = df.unit.find(id)
    if not unit then return end
    local vs = df.global.game.main_interface.view_sheets
    vs.active_sheet = df.view_sheet_type.UNIT
    vs.active_id = unit.id
    -- Overview, always: the sheet remembers the last tab looked at, so a click that means
    -- "who is this soldier" would otherwise land on Rooms or Labor
    vs.active_sub_tab = SHEET_TAB_OVERVIEW
    vs.open = true
end

OVERLAY_WIDGETS = {click = SquadMemberClickOverlay, sheet = PendingSheetOverlay}

if dfhack_flags.module then
    return
end

-- ---- command line ------------------------------------------------------------

local cmd = ({...})[1]

if cmd == 'debug' or cmd == 'log' then
    print(('clickable-squad-members: %d click%s seen'):format(#log, #log == 1 and '' or 's'))
    for _, entry in ipairs(log) do print('  ' .. entry) end
    if #log == 0 then
        print('  Nothing -- the overlay never saw a click. Either it is disabled')
        print('  (`overlay list | grep clickable-squad`) or the screen is not')
        print('  dwarfmode/Squads/Default.')
    end
    return
end

require('plugins.overlay').rescan()
print('clickable-squad-members: registered overlay fort/clickable-squad-members.click')
print('  on a squad\'s details screen, click a member\'s portrait to open their sheet;')
print('  the name still opens DF\'s position-assignment list.')
print('  `clickable-squad-members debug` lists what it decided about recent clicks.')
