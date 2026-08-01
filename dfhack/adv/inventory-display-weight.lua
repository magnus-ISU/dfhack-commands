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

The PICK-UP menu (right-click a tile with items: "What do you want to do?" with
"Get ..." options) gets the same treatment: any option that resolves to an item
shows that item's weight, right-aligned two past the longest visible row. That
menu is the generic adventure option_list (context menus share it), so options
without an item -- "View yourself", "Path to here" -- simply show nothing.

    adv/inventory-display-weight           print status (overlay is on by default)
    adv/inventory-display-weight help      print this help

Purely a display -- it feeds no input. Manage it with gui/control-panel
(Overlays).

Implementation notes, all measured live (2026-08):

* Weight lives on the item itself: `item.weight` is a massst {whole, fraction},
  in the same {weight}-units the Burden header uses (fraction is millionths).
  The weight glyph is CP437 char 226.
* Rows: the list renders at a 3-row pitch under the "Your inventory" header --
  name row ("a +steel long sword+"), body-part row (absent for container
  contents), blank row. The hotkey letter is the row's first non-space char and
  its column VARIES: container contents (backpack, quiver) indent one column
  deeper than top-level items. Letters restart at 'a' on every scroll page;
  visible row k maps to option_current[scroll_position + k - 1] (0-based df
  vector). The mapping is VERIFIED per row by comparing the rendered name
  against the item description (first 10 alphanumerics); a mismatched row
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

-- item.weight is a lazy cache: carried items have it, GROUND items read 0/0
-- until DF's own calculateWeight() fills it in (measured: an iron statue read
-- 0 until the call, 471 after)
local function weight_of(item)
    if item.weight.whole == 0 and item.weight.fraction == 0 then
        pcall(function() item:calculateWeight() end)
    end
    return item.weight
end

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
-- ('a', 'b', ...; they restart at 'a' on every scroll page) as the row's first
-- non-space character. The column is NOT fixed: container contents (backpack,
-- quiver) indent their letter one column right of top-level items, which is
-- exactly what broke the first version mid-list. Only the letter sequence
-- anchors a row; body-part rows start uppercase and can never match.
local function find_entries(lines, header_y)
    local rows = {}      -- rows[k] = {row=<0-based y>, col=<0-based letter col>}
    local want = 1
    for y = header_y + 1, #lines do
        local letter = string.char(96 + want)
        if lines[y]:find('^%s*' .. letter .. ' ') then
            rows[want] = {row = y - 1, col = lines[y]:find('%S') - 1}
            want = want + 1
            if want > 26 then break end
        end
    end
    return rows
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

-- cache = {entries={{row=<0-based y>, x=<paint col>, text}, ...}}
local cache = nil
local scan_at, tries, last_key = 0, 0, nil

-- the pick-up / context menu: weight for every option that resolves to an item.
-- Mapping is verified per row: the cleaned rendered row must CONTAIN the item
-- description's first alphanumerics ("Get Urist's right arm  iron gauntlet").
local function rebuild_pickup()
    local ol = df.global.game.main_interface.adventure.option_list
    local lines = read_screen()
    if not lines then return nil end
    local header_y
    for y = 1, #lines do
        if lines[y]:find('What do you want to do?', 1, true) then header_y = y break end
    end
    if not header_y then return nil end
    local rows = find_entries(lines, header_y)
    if not rows[1] then return nil end
    -- shared right-align anchor: all weights end 2 + max-weight-width past the
    -- longest visible row (weights are at most 4 cells wide)
    local maxlen = 0
    for _, e in ipairs(rows) do
        local txt = lines[e.row + 1]:gsub('%s+$', '')
        if #txt > maxlen then maxlen = #txt end
    end
    local end0 = math.min(maxlen + 5, df.global.gps.dimx - 2)   -- 0-based end col
    local scroll = ol.scroll_position
    local entries = {}
    for k, e in ipairs(rows) do
        local ok, item = pcall(function()
            return ol.option[scroll + k - 1]:getItem()
        end)
        if ok and item then
            local rowclean = lines[e.row + 1]:gsub('%W', ''):lower()
            local want = name_key(dfhack.items.getReadableDescription(item)):sub(1, 8)
            if want ~= '' and rowclean:find(want, 1, true) then
                local text = fmt_weight(weight_of(item))
                local x = end0 - #text + 1
                if lines[e.row + 1]:sub(x, end0 + 1):match('^%s*$') then
                    entries[#entries+1] = {row = e.row, x = x, text = text}
                end
            end
        end
    end
    if #entries == 0 then return nil end
    return {entries = entries}
end

local function rebuild()
    local inv = df.global.game.main_interface.adventure.inventory
    local lines = read_screen()
    if not lines then return nil end
    local header_y
    for y = 1, #lines do
        if lines[y]:find(HEADER, 1, true) then header_y = y break end
    end
    if not header_y then return nil end          -- open but not drawn yet: retry
    local rows = find_entries(lines, header_y)
    if not rows[1] then return nil end
    -- one shared right-align anchor: the leftmost icon column of any visible row
    local left
    for _, e in ipairs(rows) do
        local b = button_left(e.row, e.col + 2)
        if b and (not left or b < left) then left = b end
    end
    if not left then return nil end
    local anchor = left - 2                      -- text ends here, one blank gap
    local scroll = inv.scroll_position
    local entries = {}
    for k, e in ipairs(rows) do
        local ok, item = pcall(function()
            return inv.option_current[scroll + k - 1]:getItem()
        end)
        if ok and item then
            local shown = name_key(lines[e.row + 1]:sub(e.col + 3))
            local want = name_key(dfhack.items.getReadableDescription(item))
            if shown == want then
                local text = fmt_weight(weight_of(item))
                local x = anchor - #text + 1
                -- never overwrite the name: the target cells must have scanned blank
                if lines[e.row + 1]:sub(x, anchor + 1):match('^%s*$') then
                    entries[#entries+1] = {row = e.row, x = x, text = text}
                end
            end
        end
    end
    if #entries == 0 then return nil end
    return {entries = entries}
end

local function paint()
    if not running then return end
    local adv = df.global.game.main_interface.adventure
    local inv, ol = adv.inventory, adv.option_list
    local mode = inv.open and 'i' or ol.open and 'p' or nil
    if not mode then cache, scan_at, tries, last_key = nil, 0, 0, nil return end
    local now = dfhack.getTickCount()
    local key = mode == 'i'
        and ('i:%d:%d:%d'):format(inv.scroll_position, #inv.option_current,
            df.global.gps.dimx)
        or ('p:%d:%d:%d'):format(ol.scroll_position, #ol.option,
            df.global.gps.dimx)
    -- any scroll/resize forces a prompt rescan EVEN IF the last scan failed --
    -- resetting `tries` here is what keeps the weights snappy while scrolling
    -- (the old cache is dropped too: it maps the previous page's items)
    if key ~= last_key then last_key, tries, scan_at, cache = key, 0, 0, nil end
    if now >= scan_at then
        cache = mode == 'i' and rebuild() or rebuild_pickup()
        if cache then
            tries = 0
            scan_at = now + SCAN_MS
        else
            -- the scan reads the last RENDERED frame, which lags a fresh scroll
            -- by a frame or two -- retry fast, briefly, then settle to SCAN_MS
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
