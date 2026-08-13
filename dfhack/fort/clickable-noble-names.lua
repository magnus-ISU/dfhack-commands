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
which makes the blocks self-identifying: cyan ones are DF's buttons, the plain ones after
the last button are the room icons, in struct order -- office, bedroom, dining room, tomb.
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
-- icon and each button out of tiles n, n+1, n+2, n+3, and nothing else on the row does that
-- -- panel background repeats one tile id, and glyphs are scattered around the atlas.
local function tile_blocks(y)
    local w = dfhack.screen.getWindowSize()
    local blocks, run_start, prev = {}, nil, nil
    local function close(at)
        if run_start and at - run_start == 4 then
            local p = dfhack.screen.readTile(run_start, y)
            blocks[#blocks + 1] = {x1 = run_start, x2 = at - 1, fg = p and p.fg}
        end
    end
    for x = 0, w - 1 do
        local p = dfhack.screen.readTile(x, y)
        local t = p and p.tile
        if t and prev and t == prev + 1 then
            -- still inside a run; a run longer than 4 is not a block, and close() drops it
        else
            close(x)
            run_start = t and x or nil
        end
        prev = t
    end
    close(w)
    return blocks
end

-- DF's buttons are the cyan blocks (assign, symbols); the room icons are the plain blocks
-- that come after the last button. Returns buttons, icons.
local function row_blocks(y)
    local buttons, icons = {}, {}
    for _, b in ipairs(tile_blocks(y)) do
        if b.fg == COLOR_CYAN then buttons[#buttons + 1] = b else icons[#icons + 1] = b end
    end
    local last_button = buttons[#buttons]
    if not last_button then return buttons, {} end
    local after = {}
    for _, b in ipairs(icons) do
        if b.x1 > last_button.x2 then after[#after + 1] = b end
    end
    return buttons, after
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

-- a row is three lines tall: the name, the squad line under it, and a separator. The icons
-- are drawn down all three, so a click anywhere in the block belongs to the row above it.
local ROW_HEIGHT = 3

local function row_at(y)
    for dy = 0, ROW_HEIGHT - 1 do
        local nl = noble_on_line(y - dy)
        if nl then return nl, y - dy, dy end
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
local function classify(x, row_line, dy)
    local buttons, icons = row_blocks(row_line)
    if #buttons == 0 then return nil end          -- unrecognisable row; don't guess
    for _, b in ipairs(buttons) do
        if x >= b.x1 - MARGIN and x <= b.x2 + MARGIN then return nil end
    end
    for i, b in ipairs(icons) do
        if x >= b.x1 and x <= b.x2 then
            local room = ROOM_ICONS[i]
            return room and 'room' or nil, room   -- a 5th+ icon is not ours
        end
    end
    -- the row proper: caption, name and the space among them, left of the last button. The
    -- separator line is left out so a click in the gap doesn't fire the row above it.
    if x < buttons[#buttons].x1 and dy < ROW_HEIGHT - 1 then return 'noble' end
end

-- ---- the actions -------------------------------------------------------------

local function close_info()
    df.global.game.main_interface.info.open = false
end

local function open_sheet(unit)
    local vs = df.global.game.main_interface.view_sheets
    vs.active_sheet = df.view_sheet_type.UNIT
    vs.active_id = unit.id
    vs.open = true
end

local function unit_pos(unit)
    local pos = xyz2pos(dfhack.units.getPosition(unit))
    if not pos or pos.x < 0 then return nil end
    return pos
end

-- open the sheet and follow, the way dwarf-rts follows a squad member.
--
-- THE SHEET IS OPENED ONE FRAME LATE, and it has to be. Closing the Info panel and revealing
-- the map both tear the unit sheet down, and they run after this handler in the same frame,
-- so a sheet opened here is opened and shut before anything is drawn -- the click read as
-- "it only followed him". A 'frames' timeout lands after that teardown, and unlike 'ticks'
-- it still fires while the game is paused, which is exactly when this screen is used.
local function goto_noble(unit)
    local pos = unit_pos(unit)
    close_info()
    if pos then
        dfhack.gui.revealInDwarfmodeMap(pos, true, true)
        df.global.plotinfo.follow_item = -1
        df.global.plotinfo.follow_unit = unit.id
    end
    local id = unit.id
    dfhack.timeout(1, 'frames', function()
        local u = df.unit.find(id)                -- off-map (on a raid, say): sheet only
        if u then open_sheet(u) end
    end)
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
    version = 1,
}

function NobleClickOverlay:onInput(keys)
    if not keys._MOUSE_L then return false end
    local x, y = dfhack.screen.getMousePos()
    if not x or not y then return false end

    local nl, row_line, dy = row_at(y)
    if not nl or not nl.un then return false end

    local what, room = classify(x, row_line, dy)
    if not what then return false end             -- DF's button, or none of our business

    if what == 'room' then goto_room(nl.un, room) else goto_noble(nl.un) end
    return true
end

OVERLAY_WIDGETS = {click = NobleClickOverlay}

if dfhack_flags.module then
    return
end

require('plugins.overlay').rescan()
print('clickable-noble-names: registered overlay fort/clickable-noble-names.click')
print('  click a noble row to open their sheet and follow them;')
print('  click an office/bedroom/dining/tomb icon to jump to that room.')
