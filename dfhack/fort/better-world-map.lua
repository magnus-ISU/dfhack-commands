-- World map screen: "Center on fort" also flashes markers over the fort and everywhere linked to it.
--@module = true
--[[
fort/better-world-map

The World screen's `Center on fort` button scrolls the map so your fort sits in the middle --
and that is all it does. On a big world the middle is a crowd of sites, roads and rumour
icons in which the fort is one tile among hundreds, and the button gives you no hint which.

This overlay watches for that click and, for FIVE SECONDS after it, flashes a `!` on the tile
directly above each site worth finding:

    BLUE    your own fortress
    YELLOW  a site UNDER YOUR CONTROL -- your holding as a land holder, the one whose panel
            offers Request workers and reads "economically linked to you"
    WHITE   a site that merely BELONGS TO YOUR CIVILIZATION -- your civ, somebody else's
            holding. You cannot attack it and cannot negotiate with it, and that is all.

    RED     a FOREIGN site that keeps books, held by somebody we are AT WAR with
    WHITE   a foreign site that keeps books, allied or never met

THE GLYPH SAYS LIBRARY, THE COLOUR SAYS WHOSE. A site with a library is drawn as an infinity
sign (CP437 236, the closest thing the map font has to a scroll) instead of an exclamation
mark, in whatever colour its standing calls for. A tile holds one glyph, and an earlier version
spent it on ownership alone -- which hid the library at Furnacehailed behind a plain white
mark. Furnacehailed draws a white scroll where it used to draw a plain white bang. YOUR OWN FORTRESS
IS THE EXCEPTION and keeps its blue `!` -- you do not need telling that your own library is
there, and the bang is what you clicked the button to find.

Books are worth going out of your way for BECAUSE they are rare -- 7 libraries across this
world's 3664 sites -- so a foreign library is marked whoever owns it, including a civilization
you are at war with. Getting in is your problem; knowing it is there is the point.

THE MIDDLE TIER IS THE POINT. Flattening "under your control" into "belongs to your
civilization" made fifteen sites look like yours when only one was -- see `site_standing` in
`economic-expeditions` for why the link FLAGS cannot tell them apart and the position profile
can.

WHICH SITES COUNT IS NOT DECIDED HERE. `fort/economic-expeditions` already has to answer this
to know where an expedition may go, and having two scripts disagree about what belongs to you
would be worse than a dependency -- so this asks that one, through its exported
`site_standing`. If it is not installed the flash falls back to marking the fort alone rather
than failing.

The list is built ONCE when the flash starts, not per frame: it is a 3664-site scan that takes
~60ms, which is nothing once but would be a stutter sixty times a second.

SHIFT+CLICK pins the display: the markers keep flashing, with no five-second limit, until the
next click on `Center on fort` clears them. `fort/better-world-map pin` and
`... clear` do the same from the console.

The map is still DF's own; nothing else is drawn or changed, and scrolling away mid-flash
simply carries the markers with their sites (each is placed from the map's centre and the
site's world position every frame, not from a screen spot remembered at click time).

Registered automatically as overlay `fort/better-world-map.flash`.
]]

local overlay = require('plugins.overlay')
local gui = require('gui')

local BUTTON = 'Center on fort'
local FLASH_MS = 5000
local BLINK_MS = 250

-- when the flash ends (dfhack.getTickCount() ms); 0 = not flashing
local flash_until = 0
-- SHIFT+CLICK PINS THE MARKERS. Five seconds is right for "where am I", and wrong for reading
-- the map with your holdings in front of you -- so shift+click leaves them up until the next
-- click on the button takes them down again. It still BLINKS: the blink is what makes a marker
-- findable against a crowded map, and losing it was the whole reason for putting it there.
local pinned = false

-- {{x = world x, y = world y, pen = pen}, ...}, built when the flash starts
local marks = nil

local PENS = {
    own        = {ch = '!', fg = COLOR_LIGHTBLUE, bg = COLOR_BLACK, bold = true},
    controlled = {ch = '!', fg = COLOR_YELLOW,    bg = COLOR_BLACK, bold = true},
    civ        = {ch = '!', fg = COLOR_WHITE,     bg = COLOR_BLACK, bold = true},
}

-- CP437 236 is the infinity sign, the closest thing the map font has to a scroll.
local SCROLL = 236
local BANG = '!'
-- A foreign library has no standing to colour it by, so it is coloured by how dangerous
-- fetching from it would be: RED if we are at war with the government that holds it, WHITE if
-- they are allies or we have never met them.
local ENEMY_LIBRARY_PEN   = {ch = SCROLL, fg = COLOR_LIGHTRED, bg = COLOR_BLACK, bold = true}
local FOREIGN_LIBRARY_PEN = {ch = SCROLL, fg = COLOR_WHITE,    bg = COLOR_BLACK, bold = true}

-- Every site to mark, and in what colour. Asks `economic-expeditions` how each site stands to
-- you so the two tools cannot drift apart; without it, just the fort.
local function build_marks()
    local out = {}
    local mine = df.global.plotinfo.site_id
    local ok, ee = pcall(reqscript, 'fort/economic-expeditions')
    if not (ok and ee and ee.site_standing) then
        local site = df.world_site.find(mine)
        if site then out[1] = {x = site.pos.x, y = site.pos.y, pen = PENS.own} end
        return out
    end
    for _, site in ipairs(df.global.world.world_data.sites) do
        local has_books = ee.site_libraries and ee.site_libraries(site) > 0
        local standing = ee.site_standing(site)
        local pen = PENS[standing or '']
        if pen then
            -- keep the standing colour and swap the glyph, so one tile says both whose it is
            -- AND whether it keeps books. YOUR OWN FORTRESS KEEPS ITS BANG: you do not need
            -- telling that your own library exists, and the blue `!` is what you clicked
            -- "Center on fort" to find.
            if has_books and standing ~= 'own' then
                pen = copyall(pen)
                pen.ch = SCROLL
            end
        elseif has_books then
            pen = (ee.site_hostile and ee.site_hostile(site))
                and ENEMY_LIBRARY_PEN or FOREIGN_LIBRARY_PEN
        end
        if pen then out[#out + 1] = {x = site.pos.x, y = site.pos.y, pen = pen} end
    end
    return out
end

-- The fort's WORLD tile, which is what DF centres on: the site's own `pos`, not the middle
-- of the embark rectangle.
local function fort_world_pos()
    local site = df.world_site.find(df.global.plotinfo.site_id)
    if site then return site.pos.x, site.pos.y end
end

-- Where a world tile lands on the interface grid. The world map is drawn through the main
-- map port -- `dim_x` by `dim_y` world tiles centred on the screen's `region_cent_x/y` --
-- in SQUARE map tiles that fill the whole window behind the side panel, not in interface
-- cells: 120 tiles across a 1920px window is 16px a tile, against 10x16px interface cells.
-- So a world tile's pixel position is converted to a cell through both sizes. (The first
-- version assumed one tile per cell and put the marker 36 columns left of the fort.)
local function world_to_screen(vs, wx, wy)
    local gps = df.global.gps
    local port = gps.main_map_port
    if not port or port.dim_x <= 0 or port.dim_y <= 0 then return nil end
    local tile_px = (gps.dimx * gps.tile_pixel_x) / port.dim_x      -- map tile edge, pixels
    local left = vs.region_cent_x - math.floor(port.dim_x / 2)
    local top = vs.region_cent_y - math.floor(port.dim_y / 2)
    local px = (wx - left) * tile_px + tile_px / 2                   -- the tile's centre
    local py = (wy - top) * tile_px + tile_px / 2
    local sx = math.floor(px / gps.tile_pixel_x)
    local sy = math.floor(py / gps.tile_pixel_y)
    if sx < 0 or sx >= gps.dimx or sy < 0 or sy >= gps.dimy then return nil end
    return sx, sy
end

-- Is the mouse on the `Center on fort` button? Read only the row under the cursor, only
-- when a click has happened: the label's own cells, plus one either side for the box.
-- Is the mouse on the `Center on fort` button? The label is found by reading the screen, and
-- the hit box is deliberately BIGGER than the text: one row above and below, and two columns
-- either side. DF's own button is a graphical widget whose clickable area is larger than the
-- glyphs it draws, so matching the text exactly meant clicks that visibly landed on the button
-- did nothing.
local PAD_ROWS, PAD_COLS = 1, 2

local function row_text(y, sw)
    if y < 0 then return nil end
    local row = {}
    for x = 0, sw - 1 do
        local ok, pen = pcall(dfhack.screen.readTile, x, y)
        local ch = (ok and pen and pen.ch) or 0
        row[#row + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    return table.concat(row)
end

local function on_center_button()
    local mx, my = dfhack.screen.getMousePos()
    if not mx then return false end
    local sw, sh = dfhack.screen.getWindowSize()
    -- the label may be on this row or on one the padding reaches, so look for it on each
    for dy = -PAD_ROWS, PAD_ROWS do
        local y = my + dy
        if y >= 0 and y < sh then
            local text = row_text(y, sw)
            local s = text and text:find(BUTTON, 1, true)
            if s then
                local x1 = s - 1 - PAD_COLS               -- to 0-based, then pad
                local x2 = s - 1 + #BUTTON - 1 + PAD_COLS
                if mx >= x1 and mx <= x2 then return true end
            end
        end
    end
    return false
end

FlashOverlay = defclass(FlashOverlay, overlay.OverlayWidget)
FlashOverlay.ATTRS{
    desc = 'Flashes a marker over the fort for five seconds after "Center on fort" on the World screen.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'world',
    frame = {w = 1, h = 1},
    version = 1,
}

function FlashOverlay:onInput(keys)
    if keys._MOUSE_L and on_center_button() then
        if pinned then
            -- "until you click Center on fort again": any click clears a pinned display
            pinned, flash_until, marks = false, 0, nil
        else
            local built, list = pcall(build_marks)
            marks = built and list or nil
            if dfhack.internal.getModifiers().shift then
                pinned, flash_until = true, 0
            else
                flash_until = dfhack.getTickCount() + FLASH_MS
            end
        end
    end
    return false            -- DF gets the click either way; this only watches
end

function FlashOverlay:render(dc)
    local now = dfhack.getTickCount()
    if not pinned then
        if flash_until == 0 then return end
        if now >= flash_until then flash_until = 0; marks = nil; return end
    end
    if math.floor(now / BLINK_MS) % 2 == 1 then return end     -- the off half of the blink
    local vs = dfhack.gui.getDFViewscreen(true)
    if not df.viewscreen_worldst:is_instance(vs) then return end

    local list = marks
    if not list then
        local wx, wy = fort_world_pos()                        -- fallback: the fort alone
        if not wx then return end
        list = {{x = wx, y = wy, pen = OWN_PEN}}
    end
    for _, mark in ipairs(list) do
        local sx, sy = world_to_screen(vs, mark.x, mark.y)
        if sx and sy >= 1 then
            dfhack.screen.paintTile(mark.pen, sx, sy - 1)
        end
    end
end

-- Start the flash without the button, so it can be triggered from the console (and tested
-- without a mouse). Same five seconds, same markers.
function flash(pin)
    local built, list = pcall(build_marks)
    marks = built and list or nil
    pinned = pin and true or false
    flash_until = pinned and 0 or (dfhack.getTickCount() + FLASH_MS)
    return marks and #marks or 0
end

-- take a pinned display down from the console
function unflash()
    pinned, flash_until, marks = false, 0, nil
end

OVERLAY_WIDGETS = {flash = FlashOverlay}

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'flash' or arg == 'pin' then
    local n = flash(arg == 'pin')
    print(('fort/better-world-map: %d marker(s) %s.'):format(
        n, arg == 'pin' and 'pinned until cleared' or 'flashing for five seconds'))
    return
elseif arg == 'clear' then
    unflash()
    print('fort/better-world-map: markers cleared.')
    return
end

print('fort/better-world-map: overlay registered -- "Center on fort" now flashes BLUE over your '
    .. 'fort, YELLOW over sites under your control, WHITE over the rest of your civilization, '
    .. 'and a scroll instead of a bang wherever a site keeps books (cyan if it is foreign). '
    .. 'SHIFT+CLICK pins them until the next click on the button.')
