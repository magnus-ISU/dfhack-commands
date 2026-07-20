-- Replace DFHack's stock "N agitated animals" AND "N hostiles" notify lines with one
-- typed line covering both.
--@module = false
--[[
agitated-animals-notification

DFHack's built-in notify panel shows a bland "N agitated animals" and a separate
"N hostiles". This hides both stock lines (`agitated_count`, `hostile_count`) and
registers one replacement (`agitated_typed`) that names what you're actually dealing
with, in up to four segments (each omitted when empty):

    N agitated animals with A giant elephants; B megabeasts with C forgotten beasts;
    D beasts with E cyclopes; F hostiles with G weres

    * agitated: the named species is that of the LARGEST agitated animal by body size
      (giant elephants are the biggest in the game); A = how many of that species are
      agitated. All one species collapses to "N agitated ravens".
    * the stock "N hostiles" set (non-invader dangers: megabeasts, forgotten beasts,
      semi-megabeasts, night creatures, ...) is broken out by class:
        - MEGABEASTS (incl. forgotten beasts and titans): the named kind is the most
          numerous, but forgotten beasts are DEPRIORITIZED whenever any other
          megabeast kind is present (one dragon outranks three FBs in the name).
        - BEASTS (semi-megabeasts: cyclops, minotaur, ettin, giant): most numerous
          kind named.
        - anything else hostile: most numerous kind named.
      Each segment collapses to just "N <kind>" when it is all one kind.

Clicking is PER SEGMENT: a click on a segment's text cycle-zooms through only that
segment's units (each segment keeps its own cycle position), and SHIFT-clicking (with
squads selected via the dwarf-rts overlay) orders those squads to attack only that
segment's units -- click the megabeast text to hunt megabeasts, the agitated text to
cull wildlife. A click that can't be placed on a segment falls back to the whole
line's units. Shift falls through to the zoom if the overlay isn't loaded or no
squads are selected.

Run `agitated-animals-notification` to register (idempotent); magnus-scripts loads it.
]]

local NAME = 'agitated_typed'
local STOCK = 'agitated_count'          -- built-in lines we hide and replace
local STOCK_HOSTILE = 'hostile_count'

-- living, on-map, agitated wildlife that isn't caged/chained (mirrors the stock iterator)
local function is_agitated(u)
    return not dfhack.units.isDead(u) and dfhack.units.isActive(u)
        and not u.flags1.caged and not u.flags1.chained and dfhack.units.isAgitated(u)
end

-- the stock "N hostiles" set (mirrors notify's for_hostile): non-invader, non-fort,
-- visible dangers -- megabeasts, FBs, semi-megabeasts, night creatures, etc.
local function is_hostile(u)
    return not dfhack.units.isDead(u) and dfhack.units.isActive(u)
        and not u.flags1.caged and not u.flags1.chained
        and not dfhack.units.isInvader(u)
        and not dfhack.units.isFortControlled(u)
        and not dfhack.units.isHidden(u)
        and not dfhack.units.isAgitated(u)
        and dfhack.units.isDanger(u)
end

-- one pass over active units -> the agitated list + the hostiles list
local function list_targets()
    local agitated, hostile = {}, {}
    for _, u in ipairs(df.global.world.units.active) do
        if is_agitated(u) then agitated[#agitated + 1] = u
        elseif is_hostile(u) then hostile[#hostile + 1] = u end
    end
    return agitated, hostile
end

-- creature name: index 0 singular, 1 plural (df creature_raw.name = {sing, plural, adj})
local function creature_name(race, plural)
    local cr = df.global.world.raws.creatures.all[race]
    local n = cr and cr.name[plural and 1 or 0]
    if not n or n == '' then return plural and 'creatures' or 'creature' end
    return n
end

-- ---- hostile classification -------------------------------------------------

local function race_flags(race)
    local cr = df.global.world.raws.creatures.all[race]
    return cr and cr.flags
end

-- 'mega' (megabeasts + forgotten beasts + titans) / 'semi' (cyclops etc.) / 'other'
local function hostile_class(u)
    local f = race_flags(u.race)
    if f and (f.HAS_ANY_MEGABEAST or f.HAS_ANY_FEATURE_BEAST or f.HAS_ANY_TITAN) then
        return 'mega'
    end
    if f and f.HAS_ANY_SEMIMEGABEAST then return 'semi' end
    return 'other'
end

-- the "kind" a unit is counted under for naming. Forgotten beasts and titans are each
-- a unique generated race, so they're pooled under one kind apiece; everything else
-- is its actual race.
local FB_KIND, TITAN_KIND = 'FB', 'TITAN'
local function kind_of(u)
    local f = race_flags(u.race)
    if f and f.HAS_ANY_FEATURE_BEAST then return FB_KIND end
    if f and f.HAS_ANY_TITAN then return TITAN_KIND end
    return u.race
end

local function kind_name(kind, plural)
    if kind == FB_KIND then return plural and 'forgotten beasts' or 'forgotten beast' end
    if kind == TITAN_KIND then return plural and 'titans' or 'titan' end
    return creature_name(kind, plural)
end

-- "B megabeasts with C forgotten beasts" for one hostile class; collapses to
-- "B <kind>" when the class is all one kind. When `deprioritize_fb` is set, the
-- named kind is the most numerous NON-FB kind whenever any non-FB kind exists.
local function class_segment(list, label_sing, label_plur, deprioritize_fb)
    local n = #list
    if n == 0 then return nil end
    local counts, kinds = {}, 0
    for _, u in ipairs(list) do
        local k = kind_of(u)
        if not counts[k] then kinds = kinds + 1 end
        counts[k] = (counts[k] or 0) + 1
    end
    local pick, pickn
    for k, c in pairs(counts) do
        local better
        if not pick then
            better = true
        elseif deprioritize_fb and (k == FB_KIND) ~= (pick == FB_KIND) then
            better = pick == FB_KIND       -- a non-FB kind always beats the FB pool
        else
            better = c > pickn
        end
        if better then pick, pickn = k, c end
    end
    if kinds == 1 then
        return ('%d %s'):format(n, kind_name(pick, n > 1))
    end
    return ('%d %s with %d %s'):format(n, n == 1 and label_sing or label_plur,
        pickn, kind_name(pick, pickn > 1))
end

-- ---- the notify line --------------------------------------------------------

-- the char-column range of each segment in the rendered line, refreshed every
-- render, so a click can be mapped to the segment under the cursor:
-- {s=<1-based col>, e=<col>, kind='agitated'|'mega'|'semi'|'other'}
local segments = {}

local function message()
    if not dfhack.world.isFortressMode() then return end
    local agitated, hostile = list_targets()
    local tokens = {}
    segments = {}
    local col = 0
    local function add(text, pen, kind)
        tokens[#tokens + 1] = {text = text, pen = pen}
        segments[#segments + 1] = {s = col + 1, e = col + #text, kind = kind}
        col = col + #text
    end

    -- agitated segment: named species = that of the largest individual by body size
    if #agitated > 0 then
        local n = #agitated
        local first_race = agitated[1].race
        local same = true
        local big = agitated[1]
        for _, u in ipairs(agitated) do
            if u.race ~= first_race then same = false end
            if u.body.size_info.size_cur > big.body.size_info.size_cur then big = u end
        end
        local text
        if same then
            text = ('%d agitated %s'):format(n, creature_name(first_race, n > 1))
        else
            local a = 0
            for _, u in ipairs(agitated) do if u.race == big.race then a = a + 1 end end
            text = ('%d agitated animals with %d %s')
                :format(n, a, creature_name(big.race, a > 1))
        end
        add(text, COLOR_YELLOW, 'agitated')
    end

    -- hostile segments: megabeasts (FB-deprioritized name), beasts, everything else
    if #hostile > 0 then
        local by_class = {mega = {}, semi = {}, other = {}}
        for _, u in ipairs(hostile) do
            local c = by_class[hostile_class(u)]
            c[#c + 1] = u
        end
        for _, class in ipairs({
            {kind = 'mega', seg = class_segment(by_class.mega, 'megabeast', 'megabeasts', true)},
            {kind = 'semi', seg = class_segment(by_class.semi, 'beast', 'beasts')},
            {kind = 'other', seg = class_segment(by_class.other, 'hostile', 'hostiles')},
        }) do
            if class.seg then
                add((#tokens > 0 and '; ' or '') .. class.seg, COLOR_LIGHTRED, class.kind)
            end
        end
    end

    if #tokens == 0 then return end
    return tokens
end

-- which segment is under the mouse? The notify panel's list text starts one tile in
-- from the overlay frame (MEDIUM_FRAME border), so the clicked character column is
-- mouse_x relative to that; match it against the ranges recorded by message().
local function segment_at_mouse()
    local ok, ov = pcall(require, 'plugins.overlay')
    local e = ok and ov.get_state().db['gui/notify.panel']
    local r = e and e.widget and e.widget.frame_rect
    if not r then return nil end
    local colx = df.global.gps.mouse_x - (r.x1 + 1) + 1   -- 1-based char col in the line
    for _, seg in ipairs(segments) do
        if colx >= seg.s and colx <= seg.e then return seg.kind end
    end
    return nil
end

-- the units behind one segment (or ALL listed units for kind=nil)
local function units_for(kind)
    local agitated, hostile = list_targets()
    if kind == 'agitated' then return agitated end
    if not kind then
        for _, u in ipairs(hostile) do agitated[#agitated + 1] = u end
        return agitated
    end
    local out = {}
    for _, u in ipairs(hostile) do
        if hostile_class(u) == kind then out[#out + 1] = u end
    end
    return out
end

-- click: cycle-zoom through the units of the segment under the cursor (the whole
-- line if the click can't be placed); SHIFT-click with squads selected: order them
-- to attack that segment's units only
local cycles = {}
local function on_click(state, shift)
    local kind = segment_at_mouse()
    local list = units_for(kind)
    if #list == 0 then kind, list = nil, units_for(nil) end   -- stale segment -> whole line
    if #list == 0 then return state end
    if shift then
        local gk = dfhack.internal.dwarf_rts_group_kill
        if gk then
            local ids = {}
            for _, u in ipairs(list) do ids[#ids + 1] = u.id end
            if gk(ids) then return state end   -- squads were selected -> commanded them
        end
    end
    local key = kind or 'all'
    cycles[key] = ((cycles[key] or 0) % #list) + 1
    local u = list[cycles[key]]
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(u.pos.x, u.pos.y, u.pos.z), true, true)
    df.global.plotinfo.follow_unit = u.id
    return state
end

-- ---- registration (mirrors the pack's other notify scripts) -----------------

local function register()
    local n = reqscript('internal/notify/notifications')
    -- hide the stock "N agitated animals" and "N hostiles" lines (their overlays gate
    -- on config.data[name].enabled)
    if n.config and n.config.data then
        for _, stock in ipairs({STOCK, STOCK_HOSTILE}) do
            n.config.data[stock] = n.config.data[stock] or {version = 1}
            n.config.data[stock].enabled = false
        end
    end
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Agitated wildlife + non-invader hostiles (megabeasts/beasts/others), named by kind. Shift-click with squads selected to attack them all.'
    entry.dwarf_fn = message
    entry.on_click = on_click
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
end

register()
dfhack.onStateChange[NAME] = function(ev)
    if ev == SC_WORLD_LOADED or ev == SC_MAP_LOADED then register() end
end

print('agitated-animals-notification: "' .. NAME .. '" registered; stock "'
    .. STOCK .. '" and "' .. STOCK_HOSTILE .. '" hidden.')
print('Shows agitated + megabeasts/beasts/hostiles by kind; click a segment to cycle')
print('through just its units, shift-click a segment to attack just its units.')
