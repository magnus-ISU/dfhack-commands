-- Adventure travel: hover tooltips for sites on the LESSER (zoomed-in) world map.
--@module = true
--[[
adv/read-the-map
================

Tags: adventure | interface

The greater world map (the `m` toggle) names whatever you hover; the lesser
travel map you actually walk on shows nothing.  With this overlay loaded,
hovering the lesser map pops a tooltip for whatever your cursor is directly
over -- any site whose footprint covers the hovered tile, plus any army
standing there.

Site cards lead with the occupier's race, so a conquered site reads as such
("Human Dark Fortress: ..." for a taken pit):

    Human Town: Conjurewebs
      of The Knowing Fellowship, pop 119
      Lord: Imo Admiredrhymed
      ...
      Legendary Weaver: Athel Oilyboards

    Human Bandit Camp: Passionglades
      of The Lancers of Yore
      7 in all: orc 5, human 2
      Named: Maceman, Lasher x2, Spearman
      Chieftain: Cor Practicedprairie

    Roc Lair: Clodmoth the Large Controller
      Lives here: Ruxava the Earthen Wind (roc)

A camp's population comes from two disjoint stores -- an abstract per-race
head count (`populace.inhabitants`) and the individually named residents
(`populace.nemesis`) -- so the card shows ONE merged total ("7 in all")
whose breakdown always sums to it, and labels the profession list "Named:"
because only named residents have professions.  Camps have no owning entity;
the gang is a NomadicGroup entity on `site.entity_links`, which also
surfaces the gang leader (Boss / Ringleader / Chieftain) through the normal
position path.

Armies get cards too: member count, race breakdown and the leading names
(`army.members` -> nemesis -> histfig); a lone wanderer -- often a roaming
megabeast, sometimes a hidden one -- reads "Roaming: <name> (<species>)".

OPEN WILDERNESS gets a card of its own -- the region and what lives there,
biggest species first:

    Desert: The Noiseless Dune
      Wildlife: ravens, peregrine falcons

A world region stores its fauna as `world_population` records (up to ~14
Animal entries per region) in the same vector as its grasses, bushes and
vermin; only the Animal records are wildlife, and populations hunted to zero
are dropped.  Sorting is by the species' `adult_size`, so the order itself
tells you what is dinner and what considers YOU dinner.  The card shows ONLY
outside of sites: hovering a town keeps the town's card uncluttered.  The
region under a mid tile comes from `region_map` -- world-tile indexed, and a
row is a POINTER, so it is read with `_displace`, never `[y]`.

How the lesser map is decoded (all verified live against drawn markers):

- The map renders through `gps.main_map_port`, a `dim_x x dim_y` grid of
  square cells, cell size = window_pixel_width / dim_x (16px here).  Its
  layer buffers are ROW-major (`idx = y*dim_x + x`).
- One lesser-map cell = one MID TILE (1/16 world tile, 3 army-steps), or one
  army-step when zoomed in near a site (`adventure.site_level_zoom` == 1).
  The player is always drawn at the center cell `(screen_x, screen_y)`, so
  `mid = center//3 + (cell - center_cell)`.  (On the greater map one cell =
  one world tile, same centering -- that map keeps DF's own hover text.)
- That center is the player ARMY only once the journey has started.  DF mints
  the army on the first travel step; before that `player_army_id` resolves to
  nothing and DF draws you at `adventure.travel_origin_x/y` (same army-unit
  scale) for as long as `adventure.travel_not_moved` is set.  Reading the army
  alone left this tooltip dead on every freshly opened travel map, until a
  click started the travel and brought the army into being.
- Site footprints are `world_site.global_min/max_x/y`, in mid tiles, so a
  town lights up only while the cursor is over its actual span; camps, lairs
  and vaults are single-tile.  `hover_text_ax/ay` in
  `main_interface.adventure.travel` is greater-map-only and stays stale on
  the lesser map, which is why this reimplements the lookup instead.

Other data sources (this build): town population = `populace.inhabitants`
count sum, falling back to `site.resident_count` for the currently-loaded
site (whose abstract counts have been materialized into units); notable
residents = `populace.nemesis` -> nemesis_record -> histfig, whose worldgen
skill points are level x 1000, so >= 15000 = Legendary; nobles = the owning
entity's `positions.assignments` ranked by position precedence.

Sites are looked up fresh only when the hovered cell or the army moves; the
per-frame cost is one cached paint.

    adv/read-the-map           status (the overlay is on by default)
]]

local overlay = require('plugins.overlay')

local MAX_NOBLES = 3       -- top-precedence position holders shown
local MAX_LEGENDS = 3      -- legendary residents shown
local MAX_DWELLERS = 3     -- lair dwellers shown
local MAX_ARMY_NAMES = 3   -- named army members shown
local LEGEND_PTS = 15000   -- worldgen skill points = level x 1000; 15 = Legendary
local MAX_WIDTH = 60       -- tooltip line clamp, in text cells

-- world_site_type -> what a player calls it ("LairShrine" is the lair marker,
-- vaults and the mysterious structures are ImportantLocation on this build)
local TYPE_NAMES = {
    PlayerFortress = 'Abandoned Fortress',
    DarkFortress = 'Dark Fortress',
    Cave = 'Cave',
    MountainHalls = 'Mountain Halls',
    ForestRetreat = 'Forest Retreat',
    Town = 'Town',
    ImportantLocation = 'Vault',
    LairShrine = 'Lair',
    Fortress = 'Fortress',
    Camp = 'Camp',
    Monument = 'Monument',
}

-- a non-government occupying entity, as noun ("of the bandits") and as the
-- adjective slotted into the headline ("Human Bandit Camp")
local ENTITY_KIND = {
    NomadicGroup = 'Bandit',
    MigratingGroup = 'Migrant',
    MilitaryUnit = 'Soldier',
    Religion = 'Cult',
    Guild = 'Guild',
    MerchantCompany = 'Merchant',
    PerformanceTroupe = 'Performer',
    Outcast = 'Outcast',
}

local function type_name(t)
    local raw = df.world_site_type[t] or tostring(t)
    return TYPE_NAMES[raw] or raw:gsub('(%l)(%u)', '%1 %2')
end

local function race_name(race, plural)
    local ok, name = pcall(function()
        return df.global.world.raws.creatures.all[race].name[plural and 1 or 0]
    end)
    return ok and name or nil
end

-- "Lasher" -> "Lashers", "Maceman" -> "Macemen"
local function plural_prof(cap)
    if cap:sub(-3) == 'man' then return cap:sub(1, -4) .. 'men' end
    return cap .. 's'
end

local function title_case(s)
    return (s:gsub('(%a)([%w]*)', function(a, b) return a:upper() .. b end))
end

local function hf_name(hf)
    local n = dfhack.translation.translateName(hf.name, true)
    return n ~= '' and n or 'someone'
end

local function skill_noun(skill)
    local ok, cap = pcall(function() return df.job_skill.attrs[skill].caption_noun end)
    return ok and cap or (df.job_skill[skill] or '?')
end

local function prof_name(prof)
    local cap = df.profession[prof] or '?'
    pcall(function() cap = df.profession.attrs[prof].caption end)
    return cap
end

-- ---- site details -----------------------------------------------------------

-- abstract per-race population, MERGED by race -- a site holds several
-- records per race (one per culture/section); returns total and breakdown
local function abstract_pop(s)
    local total, by_race, order, first_race = 0, {}, {}, nil
    pcall(function()
        for i = 0, #s.populace.inhabitants - 1 do
            local inh = s.populace.inhabitants[i]
            local race = inh.pop_spec.race
            if race_name(race) then
                if not first_race then first_race = race end
                if not by_race[race] then order[#order + 1] = race; by_race[race] = 0 end
                by_race[race] = by_race[race] + inh.count
                total = total + inh.count
            end
        end
    end)
    local races = {}
    for _, race in ipairs(order) do
        local n = by_race[race]
        races[#races + 1] = n > 0 and (n .. ' ' .. race_name(race, n > 1)) or race_name(race)
    end
    return total, races, #order, first_race
end

-- residents of the site: the nemesis vector holds its named (historical) figures
local function residents(s)
    local out = {}
    pcall(function()
        for i = 0, #s.populace.nemesis - 1 do
            local nr = df.nemesis_record.find(s.populace.nemesis[i])
            local hf = nr and nr.figure
            if hf then out[#out + 1] = hf end
        end
    end)
    return out
end

-- with_prof prefixes the holder's profession ("Chieftain: Maceman Cor ...")
local function noble_lines(owner, lines, with_prof)
    if not owner then return end
    local nobles = {}
    pcall(function()
        for i = 0, #owner.positions.assignments - 1 do
            local a = owner.positions.assignments[i]
            local hf_id = a.histfig2
            if hf_id and hf_id ~= -1 then
                local pos
                for j = 0, #owner.positions.own - 1 do
                    if owner.positions.own[j].id == a.position_id then
                        pos = owner.positions.own[j] break
                    end
                end
                local hf = df.historical_figure.find(hf_id)
                if pos and hf then
                    nobles[#nobles + 1] = {
                        prec = pos.precedence or 30000,
                        title = pos.name[0] ~= '' and pos.name[0] or pos.code,
                        hf = hf,
                    }
                end
            end
        end
    end)
    table.sort(nobles, function(a, b) return a.prec < b.prec end)
    local shown = 0
    for _, n in ipairs(nobles) do
        if shown >= MAX_NOBLES then
            lines[#lines + 1] = ('  (+%d more officials)'):format(#nobles - shown)
            break
        end
        local who = hf_name(n.hf)
        if with_prof then who = prof_name(n.hf.profession) .. ' ' .. who end
        lines[#lines + 1] = ('  %s: %s'):format(n.title:gsub('^%l', string.upper), who)
        shown = shown + 1
    end
end

local function legend_lines(resident_hfs, lines)
    local legends = {}
    for _, hf in ipairs(resident_hfs) do
        pcall(function()
            local sk = hf.info.skills
            local bs, bp = nil, 0
            for j = 0, #sk.skills - 1 do
                if sk.points[j] > bp then bp = sk.points[j]; bs = sk.skills[j] end
            end
            if bs and bp >= LEGEND_PTS then
                legends[#legends + 1] = {hf = hf, skill = bs, pts = bp}
            end
        end)
    end
    table.sort(legends, function(a, b) return a.pts > b.pts end)
    for i, l in ipairs(legends) do
        if i > MAX_LEGENDS then
            lines[#lines + 1] = ('  (+%d more legends)'):format(#legends - MAX_LEGENDS)
            break
        end
        lines[#lines + 1] = ('  Legendary %s: %s'):format(skill_noun(l.skill), hf_name(l.hf))
    end
end

-- lairs and lair-like dwellings: name the creature(s) living there, or say
-- the place is empty.  The dweller IS the site's nemesis list.
local DWELLING = {LairShrine = true, Cave = true, Monument = true, ImportantLocation = true}

local function living(resident_hfs)
    local alive = {}
    for _, hf in ipairs(resident_hfs) do
        if hf.died_year < 0 then alive[#alive + 1] = hf end
    end
    return alive
end

local function dweller_lines(s, resident_hfs, lines)
    local alive = living(resident_hfs)
    for i, hf in ipairs(alive) do
        if i > MAX_DWELLERS then
            lines[#lines + 1] = ('  (+%d more dwellers)'):format(#alive - MAX_DWELLERS)
            break
        end
        local species = race_name(hf.race)
        lines[#lines + 1] = ('  Lives here: %s%s'):format(hf_name(hf),
            species and (' (' .. species .. ')') or '')
    end
    if #alive == 0 and df.world_site_type[s.type] == 'LairShrine' then
        lines[#lines + 1] = '  Empty'
    end
end

-- camps: one merged head count (abstract population PLUS named residents, two
-- disjoint stores) whose breakdown always sums to the printed total.
-- "7 members: 5 orcs, 2 humans, of The Lancers of Yore"
local function camp_members_line(s, resident_hfs, owner, lines)
    local by_race, order = {}, {}
    local function add(race, n)
        if n <= 0 or not race_name(race) then return end
        if not by_race[race] then order[#order + 1] = race; by_race[race] = 0 end
        by_race[race] = by_race[race] + n
    end
    pcall(function()
        for i = 0, #s.populace.inhabitants - 1 do
            local inh = s.populace.inhabitants[i]
            add(inh.pop_spec.race, inh.count)
        end
    end)
    for _, hf in ipairs(living(resident_hfs)) do add(hf.race, 1) end
    local total, bits = 0, {}
    for _, race in ipairs(order) do
        local n = by_race[race]
        total = total + n
        bits[#bits + 1] = n .. ' ' .. race_name(race, n > 1)
    end
    if total == 0 then return end
    local ownername = owner and dfhack.translation.translateName(owner.name, true) or ''
    if ownername ~= '' then bits[#bits + 1] = 'of ' .. ownername end
    lines[#lines + 1] = ('  %d member%s: %s'):format(total, total == 1 and '' or 's',
        table.concat(bits, ', '))
end

-- "Known members: 1 Maceman, 2 Lashers, 1 Spearman" -- named residents only,
-- since only they have professions
local function camp_known_line(resident_hfs, lines)
    local profs, porder = {}, {}
    for _, hf in ipairs(living(resident_hfs)) do
        local cap = prof_name(hf.profession)
        if not profs[cap] then porder[#porder + 1] = cap; profs[cap] = 0 end
        profs[cap] = profs[cap] + 1
    end
    local pbits = {}
    for _, cap in ipairs(porder) do
        local n = profs[cap]
        pbits[#pbits + 1] = n .. ' ' .. (n > 1 and plural_prof(cap) or cap)
    end
    if #pbits > 0 then
        lines[#lines + 1] = '  Known members: ' .. table.concat(pbits, ', ')
    end
end

local function site_lines(s, lines)
    local stype = df.world_site_type[s.type]
    local name = dfhack.translation.translateName(s.name, true)

    -- occupying entity: cur_owner, or (camps) the band on entity_links
    local owner, kind_adj
    pcall(function() owner = df.historical_entity.find(s.cur_owner_id) end)
    if not owner then
        pcall(function()
            for i = 0, #s.entity_links - 1 do
                local e = df.historical_entity.find(s.entity_links[i].entity_id)
                if e then
                    owner = e
                    kind_adj = ENTITY_KIND[df.historical_entity_type[e.type]]
                    break
                end
            end
        end)
    end

    -- headline: lead with the occupier's race ("Illithid Dark Fortress",
    -- "Human Bandit Camp"); lairs lead with the dweller's species instead
    local resident_hfs = residents(s)
    local head = type_name(s.type)
    if owner then
        local rn = race_name(owner.race)
        if rn then
            head = title_case(rn) .. (kind_adj and (' ' .. kind_adj) or '') .. ' ' .. head
        end
    elseif DWELLING[stype] then
        local alive = living(resident_hfs)
        local species = #alive > 0 and race_name(alive[1].race) or nil
        if species then head = title_case(species) .. ' ' .. head end
    end
    lines[#lines + 1] = head .. (name ~= '' and (': ' .. name) or '')

    if stype == 'Camp' then
        -- "7 members: 5 orcs, 2 humans, of X" / leader / "Known members: ..."
        camp_members_line(s, resident_hfs, owner, lines)
        noble_lines(owner, lines, true)
        camp_known_line(resident_hfs, lines)
    else
        -- occupier line carries the population for towns etc.
        local total, races, distinct, first_race = abstract_pop(s)
        if total == 0 then total = s.resident_count end
        local bits = {}
        local ownername = owner and dfhack.translation.translateName(owner.name, true) or ''
        if ownername ~= '' then bits[#bits + 1] = 'of ' .. ownername end
        if total > 0 then bits[#bits + 1] = ('pop %d'):format(total) end
        if #bits > 0 then lines[#lines + 1] = '  ' .. table.concat(bits, ', ') end
        -- the breakdown matters when the population is mixed OR is a different
        -- race than the occupier (a conquest not yet visible in the headline)
        if distinct > 1 or (distinct == 1 and owner and first_race ~= owner.race) then
            lines[#lines + 1] = '  ' .. table.concat(races, ', ')
        end
        noble_lines(owner, lines)
    end
    if DWELLING[stype] then dweller_lines(s, resident_hfs, lines) end
    legend_lines(resident_hfs, lines)
    pcall(function()
        if #s.wg_quest_posting > 0 then
            lines[#lines + 1] = ('  Quests posted: %d'):format(#s.wg_quest_posting)
        end
    end)
end

-- ---- armies -----------------------------------------------------------------

local function army_lines(a, lines)
    local counts, order, named = {}, {}, {}
    pcall(function()
        for i = 0, #a.members - 1 do
            local nr = df.nemesis_record.find(a.members[i].nemesis_id)
            local hf = nr and nr.figure
            if hf then
                local rn = race_name(hf.race) or '?'
                if not counts[rn] then order[#order + 1] = rn; counts[rn] = 0 end
                counts[rn] = counts[rn] + 1
                named[#named + 1] = ('%s (%s)'):format(hf_name(hf), rn)
            end
        end
    end)
    local n = #named
    if n == 0 then
        lines[#lines + 1] = 'An army'
        return
    end
    if n == 1 then
        lines[#lines + 1] = 'Roaming: ' .. named[1]
        return
    end
    local bits = {}
    for _, rn in ipairs(order) do
        bits[#bits + 1] = counts[rn] > 1 and (rn .. ' ' .. counts[rn]) or rn
    end
    lines[#lines + 1] = ('Army (%d): %s'):format(n, table.concat(bits, ', '))
    for i = 1, math.min(n, MAX_ARMY_NAMES) do
        lines[#lines + 1] = '  ' .. named[i]
    end
    if n > MAX_ARMY_NAMES then
        lines[#lines + 1] = ('  (+%d more)'):format(n - MAX_ARMY_NAMES)
    end
end

-- ---- region wildlife --------------------------------------------------------
-- what lives in the hovered region, biggest first. Shown only when no site
-- covers the tile: wilderness tells you what roams it, towns keep their card.

local function adult_size(race)
    local ok, sz = pcall(function()
        return df.global.world.raws.creatures.all[race].caste[0].misc.adult_size
    end)
    return ok and sz or 0
end

local function region_at(mx, my)
    local wd = df.global.world.world_data
    local wx, wy = mx // 16, my // 16
    if wx < 0 or wy < 0 or wx >= wd.world_width or wy >= wd.world_height then return end
    local ok, region = pcall(function()
        return wd.regions[wd.region_map[wx]:_displace(wy).region_id]
    end)
    return ok and region or nil
end

-- append `text` word-wrapped to MAX_WIDTH; continuation lines get a deeper indent
local function wrap_lines(lines, text, indent)
    local cur = nil
    for word in text:gmatch('%S+') do
        if not cur then
            cur = indent .. word
        elseif #cur + 1 + #word <= MAX_WIDTH then
            cur = cur .. ' ' .. word
        else
            lines[#lines + 1] = cur
            cur = indent .. '  ' .. word
        end
    end
    if cur then lines[#lines + 1] = cur end
end

local function region_lines(region, lines)
    -- Animal records only -- the same vector holds the region's grasses, bushes,
    -- trees and vermin. count_max == 0 is a population hunted to extinction.
    local fauna = {}
    pcall(function()
        for i = 0, #region.population - 1 do
            local p = region.population[i]
            if df.world_population_type[p.type] == 'Animal' and p.count_max > 0 then
                local nm = race_name(p.race, true)
                if nm then fauna[#fauna + 1] = {name = nm, size = adult_size(p.race)} end
            end
        end
    end)
    local rname = dfhack.translation.translateName(region.name, true)
    local rtype = (df.world_region_type[region.type] or 'Region'):gsub('(%l)(%u)', '%1 %2')
    lines[#lines + 1] = rtype .. (rname ~= '' and (': ' .. rname) or '')
    if #fauna == 0 then
        lines[#lines + 1] = '  No wild animals'
        return
    end
    -- biggest first; the order itself is the size information
    table.sort(fauna, function(a, b)
        if a.size ~= b.size then return a.size > b.size end
        return a.name < b.name
    end)
    local names = {}
    for _, f in ipairs(fauna) do names[#names + 1] = f.name end
    wrap_lines(lines, 'Wildlife: ' .. table.concat(names, ', '), '  ')
end

-- ---- hover lookup -----------------------------------------------------------

-- Where the travel map is centred, in army-units.
--
-- DF does not mint the player army until the journey actually starts: on a
-- freshly opened travel map `player_army_id` points at nothing and DF instead
-- draws the player at `travel_origin` for as long as `travel_not_moved`
-- ("still_local") is set.  Reading the army first therefore left the tooltip
-- dead until the player had clicked once and started travelling.
local function center_pos()
    local adv = df.global.adventure
    if adv.travel_not_moved ~= 0 then
        return adv.travel_origin_x, adv.travel_origin_y
    end
    local army = df.army.find(adv.player_army_id)
    if army then return army.pos.x, army.pos.y end
end

-- the lines to show for one hovered mid tile; nil when there is nothing there
local function tile_info(mx, my)
    local lines = {}
    local wd = df.global.world.world_data
    for i = 0, #wd.sites - 1 do
        local s = wd.sites[i]
        if mx >= s.global_min_x and mx <= s.global_max_x
                and my >= s.global_min_y and my <= s.global_max_y then
            site_lines(s, lines)
        end
    end
    local in_site = #lines > 0
    local player_army = df.global.adventure.player_army_id
    local armies = df.global.world.armies.all
    for i = 0, #armies - 1 do
        local a = armies[i]
        if a.id ~= player_army and a.pos.x // 3 == mx and a.pos.y // 3 == my then
            army_lines(a, lines)
        end
    end
    -- wilderness only: a hovered site keeps its card free of the region blurb
    if not in_site then
        local region = region_at(mx, my)
        if region then pcall(region_lines, region, lines) end
    end
    for i, l in ipairs(lines) do
        if #l > MAX_WIDTH then lines[i] = l:sub(1, MAX_WIDTH - 1) .. '~' end
    end
    if #lines > 0 then return lines end
end

-- exported for testing
function lines_for_site(id)
    local wd = df.global.world.world_data
    for i = 0, #wd.sites - 1 do
        if wd.sites[i].id == id then
            local lines = {}
            site_lines(wd.sites[i], lines)
            return lines
        end
    end
end

function lines_for_army(id)
    local a = df.army.find(id)
    if not a then return end
    local lines = {}
    army_lines(a, lines)
    return lines
end

function lines_for_tile(mx, my)
    return tile_info(mx, my)
end

-- ---- overlay ----------------------------------------------------------------

ReadTheMap = defclass(ReadTheMap, overlay.OverlayWidget)
ReadTheMap.ATTRS{
    desc = 'Hover tooltips for sites on the lesser travel map.',
    default_enabled = true,
    viewscreens = 'dungeonmode/Travel',
    frame = {w = 1, h = 1},
}

local PEN_TEXT = dfhack.pen.parse{fg = COLOR_WHITE, bg = COLOR_BLACK}
local PEN_EDGE = dfhack.pen.parse{fg = COLOR_LIGHTCYAN, bg = COLOR_BLACK}

local cache_key, cache_lines = nil, nil

local function paint()
    local adv = df.global.adventure
    if adv.travel_right_map ~= 0 then return end     -- greater map has DF's own hover
    local ax, ay = center_pos()
    if not ax then return end
    local gps = df.global.gps
    local mp = gps.main_map_port
    if mp.dim_x <= 0 or mp.dim_y <= 0 then return end
    -- map cells are square: window pixel width / dim_x (16px at this window size)
    local cellpx = math.max(1, (gps.dimx * gps.tile_pixel_x) // mp.dim_x)
    local cx = gps.precise_mouse_x // cellpx
    local cy = gps.precise_mouse_y // cellpx
    if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end

    local key = ('%d:%d:%d:%d'):format(cx, cy, ax, ay)
    if key ~= cache_key then
        cache_key = key
        -- near a site the lesser map rescales to one army-unit per cell
        local s = adv.site_level_zoom ~= 0 and 1 or 3
        local mx = (ax + (cx - mp.screen_x) * s) // 3
        local my = (ay + (cy - mp.screen_y) * s) // 3
        cache_lines = tile_info(mx, my)
    end
    if not cache_lines then return end

    -- tooltip near the mouse, nudged to stay on screen
    local width = 0
    for _, l in ipairs(cache_lines) do width = math.max(width, #l) end
    width = width + 2
    local tx = gps.mouse_x + 2
    local ty = gps.mouse_y + 1
    if tx + width >= gps.dimx then tx = math.max(0, gps.mouse_x - width - 1) end
    if ty + #cache_lines >= gps.dimy then ty = math.max(0, gps.mouse_y - #cache_lines - 1) end
    for i, line in ipairs(cache_lines) do
        local pen = i == 1 and PEN_EDGE or PEN_TEXT
        dfhack.screen.paintString(pen, tx, ty + i - 1,
            ' ' .. line .. string.rep(' ', width - #line - 1))
    end
end

function ReadTheMap:onRenderFrame(dc, rect)
    pcall(paint)
end

OVERLAY_WIDGETS = {tooltip = ReadTheMap}

if dfhack_flags.module then return end

print('adv/read-the-map: hover the lesser travel map to identify sites under the cursor.')
print('The overlay is enabled by default; manage it with gui/control-panel (Overlays).')
