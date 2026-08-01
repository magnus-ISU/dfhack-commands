-- Adventure mode: show each inventory item's weight next to its row.
--@module = true
-- helpdb reads the [====[ ]====] block: `help adv/inventory-display-weight`
-- and `adv/inventory-display-weight help` both serve it.
--[====[
adv/inventory-display-weight
============================

Tags: adventure | interface

The adventure inventory tells you your total burden ("112{weight}/112{weight}")
but not what any single item weighs -- you dig through View-item sheets to find
the 20{weight} mail shirt you should drop. This overlay paints every item's
weight on its row: right-aligned, on the TOP half of the item's two-row entry,
just left of the button icons (the magnifying-glass "View this item" column).
Weights under 1{weight} show as "<1{weight}".

    adv/inventory-display-weight           print status (overlay is on by default)
    adv/inventory-display-weight help      print this help

Purely a display -- it feeds no input. Manage it with gui/control-panel
(Overlays).

Implementation notes, all measured live (2026-08):

* Weight lives on the item itself: `item.weight` is a massst {whole, fraction},
  in the same {weight}-units the Burden header uses (fraction is millionths).
  The weight glyph is CP437 char 226.
* Rows: the list renders at a 3-row pitch under the "Your inventory" header --
  name row ("a +steel long sword+", hotkey letter at a fixed column), body-part
  row, blank row. Visible row k maps to option_current[scroll_position + k - 1]
  (0-based df vector). The mapping is VERIFIED per row by comparing the rendered
  name against the item description (first 10 alphanumerics); a mismatched row
  paints nothing rather than a wrong number.
* The button icons are pure graphics -- absent from the text layer. They ARE in
  gps.screentexpos (column-major: [x*dimy + y]); every item block's icons start
  at one fixed column (x=116 at this window size), so the paint anchor is the
  GLOBAL leftmost icon column across the visible name rows, minus 2. Icons found
  per name row, never assumed from resolution.
* A row whose own name text runs into the weight column is SKIPPED (the cells
  must scan blank), so long names are never painted over.

PERFORMANCE -- same discipline as adv/watch-their-blade: nothing scans unless
main_interface.adventure.inventory.open is true; while open, one full text-grid
read per SCAN_MS (plus a fast bounded retry while the panel is mid-draw, since
`open` flips before the first frame renders); frames in between paint from
cache.
]====]

local overlay = require('plugins.overlay')

local SCAN_MS = 500          -- min gap between screen scans while open
local RETRY_MS = 100         -- retry gap while open but not yet drawn
local HEADER = 'Your inventory'
local WEIGHT_CH = string.char(226)   -- CP437 gamma, DF's weight symbol

running = running or true

local function fmt_weight(w)
    if w.whole >= 1 then return tostring(w.whole) .. WEIGHT_CH end
    if w.fraction > 0 then return '<1' .. WEIGHT_CH end
    return '0' .. WEIGHT_CH
end

-- ---- screen scan ------------------------------------------------------------

-- one full read of the text grid into an array of strings; every caller sits
-- behind the inventory.open gate and the SCAN_MS throttle
local function read_screen()
    local gps = df.global.gps
    local readTile, char = dfhack.screen.readTile, string.char
    local dimx, dimy = gps.dimx, gps.dimy
    local lines = {}
    local ok = pcall(function()
        local row = {}
        for y = 0, dimy - 1 do
            for x = 0, dimx - 1 do
                local t = readTile(x, y)
                local ch = t and t.ch or 0
                row[x + 1] = (ch >= 32 and ch < 127) and char(ch) or ' '
            end
            lines[y + 1] = table.concat(row, '', 1, dimx)
        end
    end)
    return ok and lines or nil
end

-- name rows below the header: the k-th entry starts with its hotkey letter
-- ('a', 'b', ...) at one fixed column. Item names can BEGIN with a decoration
-- glyph (the ascii filter blanks it), so unlike watch-their-blade nothing is
-- required after the "letter space" -- the letter+column+sequence is the match.
local function find_entries(lines, header_y)
    local rows, col = {}, nil
    local want = 1
    for y = header_y + 1, #lines do
        local letter = string.char(96 + want)
        if col == nil then
            if lines[y]:find('^%s*' .. letter .. ' ') then
                col = lines[y]:find(letter, 1, true) - 1
                rows[want] = y - 1               -- back to 0-based screen rows
                want = want + 1
            end
        elseif lines[y]:sub(col + 1, col + 2) == letter .. ' ' then
            rows[want] = y - 1
            want = want + 1
        end
        if want > 26 then break end
    end
    return rows, col
end

-- first 10 alphanumerics, lowercased -- enough to tell items apart and immune
-- to decoration glyphs, quality wrappers and the ascii filter
local function name_key(s)
    return (s:gsub('%W', ''):lower():sub(1, 10))
end

-- leftmost button-icon column on a name row: icons are graphics, present in
-- gps.screentexpos (column-major). Scan right of the hotkey column only --
-- everything left of the panel is map tiles, which also carry texpos.
local function button_left(row, from_x)
    local gps = df.global.gps
    local dimx, dimy = gps.dimx, gps.dimy
    for x = from_x, dimx - 1 do
        if gps.screentexpos[x * dimy + row] ~= 0 then return x end
    end
end

-- ---- overlay ----------------------------------------------------------------

InventoryWeight = defclass(InventoryWeight, overlay.OverlayWidget)
InventoryWeight.ATTRS{
    desc = 'Shows each item\'s weight in the adventure inventory list.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    frame = {w = 1, h = 1},
}

local PEN = dfhack.pen.parse{fg = COLOR_WHITE, bg = COLOR_BLACK}

-- cache = {key, entries={{row=<0-based y>, x=<paint col>, text}, ...}}
local cache = nil
local scan_at, tries = 0, 0

local function rebuild()
    local inv = df.global.game.main_interface.adventure.inventory
    local lines = read_screen()
    if not lines then return nil end
    local header_y
    for y = 1, #lines do
        if lines[y]:find(HEADER, 1, true) then header_y = y break end
    end
    if not header_y then return nil end          -- open but not drawn yet: retry
    local rows, col = find_entries(lines, header_y)
    if not col then return nil end
    -- one shared right-align anchor: the leftmost icon column of any visible row
    local left
    for _, row in pairs(rows) do
        local b = button_left(row, col + 2)
        if b and (not left or b < left) then left = b end
    end
    if not left then return nil end
    local anchor = left - 2                      -- text ends here, one blank gap
    local scroll = inv.scroll_position
    local entries = {}
    for k, row in pairs(rows) do
        local ok, item = pcall(function()
            return inv.option_current[scroll + k - 1]:getItem()
        end)
        if ok and item then
            local shown = name_key(lines[row + 1]:sub(col + 3))
            local want = name_key(dfhack.items.getReadableDescription(item))
            if shown == want then
                local text = fmt_weight(item.weight)
                local x = anchor - #text + 1
                -- never overwrite the name: the target cells must have scanned blank
                if lines[row + 1]:sub(x, anchor + 1):match('^%s*$') then
                    entries[#entries+1] = {row = row, x = x, text = text}
                end
            end
        end
    end
    if #entries == 0 then return nil end
    return {entries = entries}
end

local function paint()
    if not running then return end
    local inv = df.global.game.main_interface.adventure.inventory
    if not inv.open then cache, scan_at, tries = nil, 0, 0 return end
    local now = dfhack.getTickCount()
    local key = ('%d:%d:%d'):format(inv.scroll_position, #inv.option_current,
        df.global.gps.dimx)
    if now >= scan_at or (cache and cache.key ~= key) then
        cache = rebuild()
        if cache then
            cache.key = key
            tries = 0
            scan_at = now + SCAN_MS
        else
            tries = tries + 1
            scan_at = now + (tries <= 10 and RETRY_MS or SCAN_MS)
        end
    end
    if not cache then return end
    for _, e in ipairs(cache.entries) do
        dfhack.screen.paintString(PEN, e.x, e.row, e.text)
    end
end

function InventoryWeight:onRenderFrame(dc, rect)
    pcall(paint)
end

OVERLAY_WIDGETS = {weights = InventoryWeight}

function stop()
    running = false
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/inventory-display-weight: stopped.')
elseif arg == 'help' or arg == '-h' or arg == '--help' then
    if not pcall(function() require('helpdb').help('adv/inventory-display-weight') end) then
        print('adv/inventory-display-weight [stop | status | help]')
    end
else
    running = true
    print(('adv/inventory-display-weight: %s -- open your inventory and every item shows its weight.')
        :format(running and 'ON' or 'stopped'))
end
