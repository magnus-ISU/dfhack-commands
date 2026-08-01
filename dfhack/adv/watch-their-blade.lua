-- Adventure mode: combat summary for each target on the "Who will you attack?" screen.
--@module = true
--[[
adv/watch-their-blade

The attack screens tell you what an enemy is DOING ("IMMINENT: Attacking you with scratch")
but nothing about what shape they are in or what they are holding -- you pick a target and
an attack blind. This overlay paints a three-line summary under each name, starting three
rows below the name line, on BOTH attack screens: the "Who will you attack?" chooser (every
candidate) and the post-pick attack screens ("Lethal: The ..." header -- the one target):

    wounds   -- "Faint, Heavy Bleeding" (or "Unharmed")
    armor    -- "iron high boots, iron greaves, iron breastplate, iron helm" (or "no armor")
    weapons  -- "Left hand silver carving knife, right hand copper whip" (or "Unarmed";
                sheathed gear shows as "iron war hammer strapped to upper body")

    adv/watch-their-blade          print status (the overlay is on by default)

Purely a display -- it feeds no input. Manage it with gui/control-panel (Overlays).

Driven by onRenderFrame painting (the read-the-map pattern): DF redraws the panel every
frame, the overlay paints after, so the text sits stably on top.

PERFORMANCE -- same discipline as adv/right-click-move. Locating the entry rows needs the
rendered text (~10k dfhack.screen.readTile calls), so:

  1. NOTHING scans unless main_interface.adventure.attack.open is true (cheap bool gate).
  2. While open, the scan is throttled to one per SCAN_MS; frames in between paint from
     cache. The game is paused with the chooser up, so wounds cannot change under us.
  3. attack.open flips before the panel is DRAWN (same as option_list in right-click-move),
     and the scan reads the last rendered frame -- so "header not found" is retried, never
     latched, while the panel is open.

Row model, measured live (2026-08). Chooser: header "Who will you attack?", then per entry
a name line "a Lethal: The broad-nose orc champion farmer" (hotkey letter at a fixed column,
8-row pitch) with current-action prose on up to TWO rows below it. Post-pick screens: a name
line "<conflict level>: The broad-nose orc fisherorc" -- the level is one of five fixed
words (see INTENTS), target = attack.attack_unit, blank rows below. The summary starts at name row +3. Painting
only overwrites rows that scanned blank, so if DF ever needs a row there, DF wins. Some
post-pick sub-pages (the body-part list) may not show the name line at all -- then nothing
paints. Sub-pages swap without any struct field changing, so even a settled verdict is
rescanned every SCAN_MS; a stale layout can thus survive at most one SCAN_MS.

unit_choice maps to entries in visual order; with a scrolled list the first visible entry is
unit_choice[scroll_position_unit_choice]. NOTE ipairs over a df vector yields index 0 first.
]]

local overlay = require('plugins.overlay')

local SCAN_MS = 500          -- min gap between screen scans while the chooser is open
local RETRY_MS = 100         -- retry gap while the panel is open but not yet drawn
local MAX_W = 90             -- hard cap on a painted line

local HEADER = 'Who will you attack?'

-- worn-item mode values (unit_inventory_item.mode); enum table is absent on this build
local MODE_WEAPON, MODE_WORN, MODE_STRAPPED = 1, 2, 10

running = running or true
painted = painted or 0       -- menus summarized (for status)

-- ---- unit summary -----------------------------------------------------------

-- Combat-relevant condition, DF-flavored wording. Thresholds are approximations:
-- blood tiers and the bleeding split are not exposed anywhere in df-structures.
local function wound_words(u)
    local w = {}
    local c, c2 = u.counters, u.counters2
    if c.unconscious > 0 then w[#w+1] = 'Unconscious' end
    if c.stunned > 0 then w[#w+1] = 'Stunned' end
    if c.winded > 0 then w[#w+1] = 'Winded' end
    if c.pain >= 50 then w[#w+1] = 'In Pain' end
    if c.nausea > 0 then w[#w+1] = 'Nauseous' end
    if c.dizziness > 0 then w[#w+1] = 'Dizzy' end
    if c2.paralysis > 0 then w[#w+1] = 'Paralyzed' end
    if c2.fever > 0 then w[#w+1] = 'Fevered' end
    if c2.exhaustion >= 3000 then w[#w+1] = 'Exhausted'
    elseif c2.exhaustion >= 1000 then w[#w+1] = 'Tired' end
    local bc, bm = u.body.blood_count, u.body.blood_max
    if bm > 0 and bc < bm then
        local r = bc / bm
        if r <= 0.4 then w[#w+1] = 'Faint'
        elseif r <= 0.75 then w[#w+1] = 'Pale' end
    end
    local bleed = 0
    for _, wound in ipairs(u.body.wounds) do
        for _, p in ipairs(wound.parts) do bleed = bleed + p.bleeding end
    end
    if bleed >= 20 then w[#w+1] = 'Heavy Bleeding'
    elseif bleed > 0 then w[#w+1] = 'Bleeding' end
    pcall(function()
        if u.flags1.on_ground then w[#w+1] = 'Prone' end
    end)
    if #w == 0 then return 'Unharmed' end
    return table.concat(w, ', ')
end

local function mat_of(item)
    local mi = dfhack.matinfo.decode(item)
    return mi and mi:toString() or ''
end

-- worn pieces with armorlevel > 0 -- armor, not clothing. Pairs collapse to the
-- plural ("iron high boots"), odd counts keep the multiplier ("x3").
local function armor_line(u)
    local counts, order = {}, {}
    for _, it in ipairs(u.inventory) do
        if it.mode == MODE_WORN then
            local ok, alvl = pcall(function() return it.item.subtype.armorlevel end)
            if ok and alvl and alvl > 0 then
                local key = mat_of(it.item) .. '|' .. it.item.subtype.name
                if not counts[key] then order[#order+1] = {key = key, item = it.item} end
                counts[key] = (counts[key] or 0) + 1
            end
        end
    end
    if #order == 0 then return 'no armor' end
    local out = {}
    for _, e in ipairs(order) do
        local st, n = e.item.subtype, counts[e.key]
        local name = n > 1 and st.name_plural or st.name
        local mat = mat_of(e.item)
        local piece = (mat ~= '' and mat .. ' ' or '') .. name
        if n > 2 then piece = piece .. (' x%d'):format(n) end
        out[#out+1] = piece
    end
    return table.concat(out, ', ')
end

-- wielded gear by holding part, then sheathed gear. A wielded shield lists here
-- too ("left hand iron shield") -- that is on purpose, you want to know.
local function weapon_line(u)
    local bparts
    pcall(function() bparts = dfhack.units.getCasteRaw(u).body_info.body_parts end)
    local function bp_name(id)
        local name
        if bparts and id >= 0 and id < #bparts then
            pcall(function() name = bparts[id].name_singular[0].value end)
        end
        return name or 'body'
    end
    local held, strapped = {}, {}
    for _, it in ipairs(u.inventory) do
        if it.mode == MODE_WEAPON or it.mode == MODE_STRAPPED then
            local mat = mat_of(it.item)
            local iname = it.item.subtype and it.item.subtype.name
                or df.item_type[it.item:getType()]:lower()
            local desc = (mat ~= '' and mat .. ' ' or '') .. iname
            if it.mode == MODE_WEAPON then
                held[#held+1] = bp_name(it.body_part_id) .. ' ' .. desc
            else
                strapped[#strapped+1] = desc .. ' strapped to ' .. bp_name(it.body_part_id)
            end
        end
    end
    if #held == 0 then held[1] = 'unarmed' end
    for _, s in ipairs(strapped) do held[#held+1] = s end
    local line = table.concat(held, ', ')
    return line:sub(1, 1):upper() .. line:sub(2)
end

-- ---- screen scan ------------------------------------------------------------

-- one full read of the text grid into an array of strings; ~10k readTile calls,
-- every caller sits behind the attack.open gate and the SCAN_MS throttle
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

-- entry name rows: below the header, the k-th entry starts with its hotkey letter
-- ('a', 'b', ...) followed by a space, every letter at the SAME column. The action
-- prose below each name is indented past that column, so it can never match.
local function find_entries(lines, header_y, count)
    local rows, col = {}, nil
    local want = 1
    for y = header_y + 1, #lines do
        local letter = string.char(96 + want)   -- 'a', 'b', ...
        if col == nil then
            local s, e = lines[y]:find('^%s*' .. letter .. ' %S')
            if s then
                col = lines[y]:find(letter, 1, true) - 1
                rows[want] = y - 1              -- back to 0-based screen rows
                want = want + 1
            end
        elseif lines[y]:sub(col + 1, col + 2) == letter .. ' ' then
            rows[want] = y - 1
            want = want + 1
        end
        if want > count then break end
    end
    return rows, col
end

-- ---- overlay ----------------------------------------------------------------

WatchTheirBlade = defclass(WatchTheirBlade, overlay.OverlayWidget)
WatchTheirBlade.ATTRS{
    desc = 'Wounds, armor and weapons under each entry of the attack target chooser.',
    default_enabled = true,
    viewscreens = 'dungeonmode',
    frame = {w = 1, h = 1},
}

local PEN_WOUNDS = dfhack.pen.parse{fg = COLOR_LIGHTRED, bg = COLOR_BLACK}
local PEN_ARMOR = dfhack.pen.parse{fg = COLOR_GREY, bg = COLOR_BLACK}
local PEN_WEAPON = dfhack.pen.parse{fg = COLOR_YELLOW, bg = COLOR_BLACK}

local function summary_lines(u)
    return {
        {wound_words(u), PEN_WOUNDS},
        {armor_line(u), PEN_ARMOR},
        {weapon_line(u), PEN_WEAPON},
    }
end

-- scanned-blank rows of [first, last] as a set keyed by 0-based screen row
local function blank_rows(lines, first, last)
    local blank = {}
    for y = first, math.min(last, #lines - 1) do
        if lines[y + 1]:match('^%s*$') then blank[y] = true end
    end
    return blank
end

-- mode 0: the "Who will you attack?" chooser -- one summary per candidate
local function rebuild_chooser(a, lines)
    local header_y
    for y = 1, #lines do
        if lines[y]:find(HEADER, 1, true) then header_y = y break end
    end
    if not header_y then return nil end          -- open but not drawn yet: retry
    local count = #a.unit_choice
    local rows, col = find_entries(lines, header_y, count)
    if not col then return nil end
    local scroll = a.scroll_position_unit_choice
    local entries = {}
    for k = 1, count do
        local row = rows[k]
        local u = a.unit_choice[scroll + k - 1]   -- df vector: 0-based
        if not row or not u then break end
        local limit = rows[k + 1] and (rows[k + 1] - 1) or (row + 7)
        entries[#entries+1] = {
            row = row, limit = limit,
            blank = blank_rows(lines, row + 3, limit),
            lines = summary_lines(u),
        }
    end
    if #entries == 0 then return nil end
    return {col = col + 2, entries = entries}
end

-- The post-pick name line is "<conflict level>: <name>". The five levels, verbatim
-- from the dwarfort binary's string table (they sit right after "Conflict Level"):
local INTENTS = {'Horseplay: ', 'Brawl: ', 'Non-lethal: ', 'Lethal: ', 'No Quarter: '}

-- any other mode: the post-pick attack screens -- one target, named in the
-- "<intent>: The ..." header (attack_unit). Sub-pages without that line paint
-- nothing (the body-part list has no name row). Anchoring on the intent word set,
-- not a loose pattern: a "capital word, colon" pattern would false-positive on
-- rows like "FPS: 100" and put the summary in the corner of the screen.
local function rebuild_target(a, lines)
    local u = a.attack_unit
    if not u then return nil end
    local header_y, header_x
    for y = 1, #lines do
        for _, needle in ipairs(INTENTS) do
            local s = lines[y]:find(needle, 1, true)
            if s then header_y, header_x = y, s break end
        end
        if header_y then break end
    end
    if not header_y then return nil end
    local row = header_y - 1                     -- back to 0-based screen rows
    local col = header_x - 1
    return {col = col, entries = {{
        row = row, limit = row + 9,
        blank = blank_rows(lines, row + 3, row + 9),
        lines = summary_lines(u),
    }}}
end

-- cache: repainted every frame, rebuilt on a key change or every SCAN_MS (post-pick
-- sub-pages swap with no struct change, so even a good verdict must be re-scanned).
-- entries = { {row, limit, blank=<set of scanned-blank rows>, lines={w,a,we}}, ... }
local cache = nil
local scan_at, tries = 0, 0

local function rebuild()
    local a = df.global.game.main_interface.adventure.attack
    local lines = read_screen()
    if not lines then return nil end
    if a.mode == 0 then return rebuild_chooser(a, lines) end
    return rebuild_target(a, lines)
end

local function paint()
    if not running then return end
    local a = df.global.game.main_interface.adventure.attack
    if not a.open then cache, scan_at, tries = nil, 0, 0 return end
    local now = dfhack.getTickCount()
    local key = ('%d:%d:%d:%d:%d'):format(a.mode, a.scroll_position_unit_choice,
        #a.unit_choice, a.attack_unit and a.attack_unit.id or -1, df.global.gps.dimx)
    if now >= scan_at or (cache and cache.key ~= key) then
        local had = cache ~= nil
        cache = rebuild()
        if cache then
            cache.key = key
            tries = 0
            if not had then painted = painted + 1 end
            scan_at = now + SCAN_MS
        else
            -- not drawn yet (attack.open flips before the panel renders): retry fast,
            -- briefly. After that: an anchor-less sub-page -- fall back to the slow
            -- cadence so browsing the body-part list never costs a scan per frame.
            tries = tries + 1
            scan_at = now + (tries <= 10 and RETRY_MS or SCAN_MS)
        end
    end
    if not cache then return end
    local dimx = df.global.gps.dimx
    for _, e in ipairs(cache.entries) do
        local y = e.row + 3
        for _, l in ipairs(e.lines) do
            while y <= e.limit and not e.blank[y] do y = y + 1 end
            if not e.blank[y] then break end
            local text = l[1]:sub(1, math.min(MAX_W, dimx - cache.col - 1))
            dfhack.screen.paintString(l[2], cache.col, y, text)
            y = y + 1
        end
    end
end

function WatchTheirBlade:onRenderFrame(dc, rect)
    pcall(paint)
end

OVERLAY_WIDGETS = {summary = WatchTheirBlade}

function stop()
    running = false
end

if dfhack_flags.module then return end

local arg = ({...})[1]
if arg == 'stop' then
    stop()
    print('adv/watch-their-blade: stopped.')
elseif arg == 'status' then
    print(('adv/watch-their-blade: %s | menus summarized x%d')
        :format(running and 'ON' or 'stopped', painted))
else
    running = true
    overlay.rescan()
    print('adv/watch-their-blade: attack a crowd -- each target shows wounds, armor, weapons.')
end
