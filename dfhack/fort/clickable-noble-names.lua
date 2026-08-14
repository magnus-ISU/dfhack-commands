-- Nobles screen: click a noble to open their sheet and follow them; click a room icon to go there.
--@module = true
--[[
clickable-noble-names

On Info > Nobles and administrators (dwarfmode/Info/ADMINISTRATORS/Default) the rows are
almost entirely dead space: DF gives you two buttons per row -- assign and symbols -- and
nothing else on the row does anything at all. The noble's own name is inert. This makes the
rest of the row live:

  * CLICK THE ROW (the position caption, the name, the space around them) and the noble's
    detail sheet opens and the camera starts following them -- the same pair of actions
    dwarf-rts does for a squad member. The Info panel closes on the way out, because a
    camera following a dwarf behind a full-screen panel is not much of a view.

    The whole row counts, and a row is three lines tall with the NAME IN THE MIDDLE: a blank
    line, the name, then the squad line. So the line above a name is that noble's, and the
    line below a name is still theirs rather than the next noble's.
  * CLICK A ROOM ICON -- the office / bedroom / dining room / tomb squares at the right of
    the row -- and the map jumps to that room instead. No sheet, no follow: you asked where
    the room is, so you get the room. A noble with no room of that kind gets a one-line
    announcement saying so and nothing moves.

DF'S OWN BUTTONS ARE NEVER SWALLOWED. The assign button (which opens the candidate list) and
the symbols button (which opens the symbol picker) keep working, with a one-column margin
around each in case DF's hitbox is a shade wider than its graphic. The overlay is also bound
to the /Default subfocus alone, so once either of those lists IS open every click on it
belongs to DF -- the candidate list can pick a candidate, and this cannot reach it.

HOW A ROW IS IDENTIFIED, and why not by counting rows. Rows are laid out at a fixed pitch,
but the list scrolls, and a scrolled list read by arithmetic hands back the wrong dwarf --
which, on a screen whose buttons appoint nobles, is not a mistake worth risking. Instead the
clicked line is READ: each noble's name is rendered in the same CP437 bytes
`translateName` returns, so the row is whichever noble's name is actually on that line. No
match, no action -- the click goes to DF untouched.

The row's zones are read from the render too, not hardcoded. Every 4-wide block in the row
(both buttons and all the room icons) is drawn from four CONSECUTIVE texture-atlas tiles,
which makes the blocks self-identifying: the two that stand alone are DF's buttons, and the
strip of them packed edge to edge after the last button is the room icons, in struct order --
office, bedroom, dining room, tomb.
So the layout is measured on the spot at whatever window size and column offsets DF is
using, and a fifth icon (or any DF adds later) is left alone rather than guessed at.

Registered automatically as overlay `fort/clickable-noble-names.click`.
Reposition with `gui/overlay` (the widget itself draws nothing -- it is a click handler).
]]

local overlay = require('plugins.overlay')

local function administrators()
    return df.global.game.main_interface.info.administrators
end

-- ---- reading the rendered row ------------------------------------------------

-- the row's text as the bytes DF drew, blanks as spaces. DF renders names in CP437 and
-- translateName hands back CP437, so a name found here is an exact byte match -- no
-- transliteration, no case folding, nothing to get subtly wrong on an accented name.
local function line_text(y)
    local w = dfhack.screen.getWindowSize()
    local out = {}
    for x = 0, w - 1 do
        local p = dfhack.screen.readTile(x, y)
        out[#out + 1] = string.char((p and p.ch and p.ch ~= 0) and p.ch or 32)
    end
    return table.concat(out)
end

-- every 4-wide block of consecutive atlas tiles on this line, in x order. DF composes each
-- icon and each button out of four neighbouring atlas tiles, and nothing else on the row does
-- that -- panel background repeats one tile id, and the row's TEXT carries no tile at all (the
-- glyphs ride on the background tile as characters), so prose cannot fake a block.
--
-- THE IDS RUN DOWNWARDS, n, n-1, n-2, n-3, which is the whole reason this was dead: the test
-- used to be `t == prev + 1`, no run ever matched, every row came back with no blocks and so
-- every click was handed straight back to DF.
--
-- A run is also not always one block. Where two icons sit edge to edge and happen to be
-- neighbours in the atlas, their eight columns descend without a break and read as a single
-- run -- so a run is CUT INTO 4-wide blocks rather than accepted or rejected whole. Anything
-- left over past the last whole block is not a block and is dropped.
local BLOCK_W = 4

local function tile_blocks(y)
    local w = dfhack.screen.getWindowSize()
    local blocks, run_start, prev = {}, nil, nil
    local function close(at)
        if not run_start then return end
        for x1 = run_start, at - BLOCK_W, BLOCK_W do
            local p = dfhack.screen.readTile(x1, y)
            blocks[#blocks + 1] = {x1 = x1, x2 = x1 + BLOCK_W - 1, fg = p and p.fg}
        end
    end
    for x = 0, w - 1 do
        local p = dfhack.screen.readTile(x, y)
        local t = p and p.tile
        if t and prev and t == prev - 1 then
            -- still inside a run
        else
            close(x)
            run_start = t and x or nil
        end
        prev = t
    end
    close(w)
    return blocks
end

-- Sort the row's blocks into DF's buttons and the room icons, BY SHAPE rather than by
-- colour. DF's buttons stand alone with clear space either side; the room icons are packed
-- edge to edge into a strip. So an isolated block is a button and a block with a neighbour
-- is an icon, and the icons wanted are the first such strip after the last button.
--
-- Colour is what this used to test -- cyan for a button -- and it was wrong. Cyan means the
-- button is ENABLED: a militia captain can be neither appointed nor given a symbol from this
-- screen, so both of their buttons are drawn greyed, the row came back with no buttons at
-- all, and every military row was written off as unrecognisable and left dead.
--
-- Returns buttons, icons (icons in left-to-right order, and empty if there is no strip).
local function row_blocks(y)
    local blocks = tile_blocks(y)
    local adjacent = {}
    for i, b in ipairs(blocks) do
        local prev, next_ = blocks[i - 1], blocks[i + 1]
        adjacent[i] = (prev and prev.x2 + 1 == b.x1) or (next_ and b.x2 + 1 == next_.x1) or false
    end
    local buttons, last_button_i = {}, 0
    for i, b in ipairs(blocks) do
        if not adjacent[i] then buttons[#buttons + 1] = b; last_button_i = i end
    end
    local icons = {}
    for i = last_button_i + 1, #blocks do
        if adjacent[i] then
            -- the strip ends where the packing does: later strips are DF's own business
            if #icons > 0 and blocks[i].x1 ~= icons[#icons].x2 + 1 then break end
            icons[#icons + 1] = blocks[i]
        end
    end
    return buttons, icons
end

-- ---- rows --------------------------------------------------------------------

-- the noblelist entry whose name DF drew on this line, or nil. Scroll-proof: it asks what
-- is on the line rather than what ought to be, and a vacant row (no unit) never matches.
local function noble_on_line(y)
    local text = line_text(y)
    for _, nl in ipairs(administrators().noblelist) do
        local u = nl.un
        if u then
            local name = dfhack.translation.translateName(dfhack.units.getVisibleName(u))
            if #name > 0 and text:find(name, 1, true) then return nl end
        end
    end
end

-- A row is three lines tall WITH THE NAME IN THE MIDDLE: a blank line, the name, then the
-- squad line. The buttons and room icons are drawn down all three, so the line above a name
-- belongs to that noble and the line below a name does NOT belong to the next one -- getting
-- this backwards hands the next row's room icons to the row above it.
--
-- So the name sits on the clicked line, one above it, or one below it, and since names are
-- three lines apart at most one of those can hold one: no ambiguity to resolve.
--
-- The name line is what gets returned and measured, not the clicked line. On a row's top
-- line DF draws the assign button in the plain colour rather than cyan, which would read as
-- a room icon; on the name line every block is drawn in its true colour.
local function row_at(y)
    for _, name_y in ipairs({y, y - 1, y + 1}) do
        local nl = noble_on_line(name_y)
        if nl then return nl, name_y end
    end
end

-- ---- rooms -------------------------------------------------------------------

-- the room icons in the order DF draws them, which is the order the requirements sit in
-- entity_position: office, bedroom, dining room, tomb. Anything past the fourth icon is
-- some other indicator and is deliberately not claimed.
local ROOM_ICONS = {
    {zone = df.civzone_type.Office,     name = 'office'},
    {zone = df.civzone_type.Bedroom,    name = 'bedroom'},
    {zone = df.civzone_type.DiningHall, name = 'dining room'},
    {zone = df.civzone_type.Tomb,       name = 'tomb'},
}

local function owned_room(unit, zone_type)
    for _, bld in ipairs(unit.owned_buildings) do
        if bld:getType() == df.building_type.Civzone and bld.type == zone_type then
            return bld
        end
    end
end

local function room_center(bld)
    return xyz2pos(math.floor((bld.x1 + bld.x2) / 2), math.floor((bld.y1 + bld.y2) / 2), bld.z)
end

-- ---- what a click at (x, y) means --------------------------------------------

local MARGIN = 1   -- DF's hitboxes can run a shade wider than the graphic; never clip them

-- 'room', <ROOM_ICONS entry>  |  'noble'  |  nil (not ours -- give the click back to DF)
local function classify(x, row_line)
    local buttons, icons = row_blocks(row_line)
    for _, b in ipairs(buttons) do
        if x >= b.x1 - MARGIN and x <= b.x2 + MARGIN then return nil end
    end
    for i, b in ipairs(icons) do
        if x >= b.x1 and x <= b.x2 then
            local room = ROOM_ICONS[i]
            return room and 'room' or nil, room   -- a 5th+ icon is not ours
        end
    end
    -- The row proper: caption, name and the space among them -- everything left of the icon
    -- strip, on any of the row's three lines, since all three are the noble's own block.
    -- Falls back to the last button when a row draws no icons at all.
    local edge = icons[1] and icons[1].x1 or (buttons[#buttons] and buttons[#buttons].x1)
    if edge and x < edge then return 'noble' end
end

-- ---- the actions -------------------------------------------------------------

local function close_info()
    df.global.game.main_interface.info.open = false
end

-- Overview, always. The sheet remembers whichever tab was last looked at, so without this
-- a click that means "who is this dwarf" lands on Rooms or Labor -- whatever the last sheet
-- was left on, which is never what you wanted from the row you just clicked.
local SHEET_TAB_OVERVIEW = 0

local function open_sheet(unit)
    local vs = df.global.game.main_interface.view_sheets
    vs.active_sheet = df.view_sheet_type.UNIT
    vs.active_id = unit.id
    vs.active_sub_tab = SHEET_TAB_OVERVIEW
    vs.open = true
end

local function unit_pos(unit)
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if not pos or pos.x < 0 then return nil end
    return pos
end

-- THE SHEET IS OPENED ON A LATER FRAME, and it has to be: closing the Info panel tears a
-- unit sheet down, and that happens after this handler runs, so a sheet opened here is
-- opened and shut before anything is drawn -- the click reads as "it only followed him".
--
-- The wait is handed to an overlay update rather than to dfhack.timeout. A 'frames' timeout
-- looks like the obvious tool and quietly fails: with a panel up the frame timers stop, so
-- on the very screen this runs from the sheet would never appear. Overlay updates keep
-- ticking. This is the same shape dwarf-rts uses for its own deferred follow.
pending_sheet_id = pending_sheet_id or nil

-- open the sheet and follow, the way dwarf-rts follows a squad member
local function goto_noble(unit)
    local pos = unit_pos(unit)
    close_info()
    if pos then
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
        df.global.plotinfo.follow_item = -1
        df.global.plotinfo.follow_unit = unit.id
    end
    pending_sheet_id = unit.id                    -- off-map (on a raid, say): sheet only
end

-- jump to the room itself: no sheet, and following is dropped -- a camera glued to the
-- noble would drag the view straight back off the room you asked to see.
local function goto_room(unit, room)
    local bld = owned_room(unit, room.zone)
    if not bld then
        dfhack.gui.showAnnouncement(
            ('%s has no %s assigned.'):format(dfhack.units.getReadableName(unit), room.name),
            COLOR_YELLOW, false)
        return
    end
    close_info()
    df.global.plotinfo.follow_unit = -1
    df.global.plotinfo.follow_item = -1
    dfhack.gui.revealInDwarfmodeMap(room_center(bld), true, true)
end

-- ---- overlay -----------------------------------------------------------------

NobleClickOverlay = defclass(NobleClickOverlay, overlay.OverlayWidget)
NobleClickOverlay.ATTRS{
    desc = 'Nobles screen: click a noble to open their sheet and follow them, or a room icon to go there.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    -- /Default only: while the candidate or symbol list is up, every click is DF's
    viewscreens = 'dwarfmode/Info/ADMINISTRATORS/Default',
    frame = {w = 1, h = 1},          -- draws nothing; onInput sees the whole screen anyway
    version = 2,
}

function NobleClickOverlay:onInput(keys)
    if not keys._MOUSE_L then return false end
    local x, y = dfhack.screen.getMousePos()
    if not x or not y then return false end

    local nl, row_line = row_at(y)
    if not nl or not nl.un then return false end

    local what, room = classify(x, row_line)
    if not what then return false end             -- DF's button, or none of our business

    if what == 'room' then goto_room(nl.un, room) else goto_noble(nl.un) end
    return true
end

-- The deferred half of a row click. Lives on plain `dwarfmode` because by the time it runs
-- the Info panel is shut and the click overlay's own screen is gone. It does nothing at all
-- until a click asks for a sheet, which is one nil test per frame.
PendingSheetOverlay = defclass(PendingSheetOverlay, overlay.OverlayWidget)
PendingSheetOverlay.ATTRS{
    desc = 'Opens the unit sheet a click on the Nobles screen asked for, once the panel has closed.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0,
    version = 1,
}

function PendingSheetOverlay:overlay_onupdate()
    local id = pending_sheet_id
    if not id then return end
    pending_sheet_id = nil
    local unit = df.unit.find(id)
    if unit then open_sheet(unit) end
end

OVERLAY_WIDGETS = {click = NobleClickOverlay, sheet = PendingSheetOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('clickable-noble-names: registered overlay fort/clickable-noble-names.click')
print('  click a noble row to open their sheet and follow them;')
print('  click an office/bedroom/dining/tomb icon to jump to that room.')
