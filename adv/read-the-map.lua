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
standing there.  For a site it shows:

- type and name ("Town: Conjurewebs")
- owning entity, its race and the head count -- the race is the OCCUPIER's,
  so a goblin pit taken over by humans reads "human"
- the population by race when the site is mixed ("dwarf 57, goblin 66, ...")
- the top nobles (by position precedence -- lord, law-giver, militia
  commander...), who are also the quest-giving residents
- Legendary-skilled residents
- worldgen quest postings, when the site has any

How the lesser map is decoded (all verified live against drawn markers):

- The map renders through `gps.main_map_port`, a `dim_x x dim_y` grid of
  square cells, cell size = window_pixel_width / dim_x (16px here).  Its
  layer buffers are ROW-major (`idx = y*dim_x + x`).
- One lesser-map cell = one MID TILE (1/16 world tile, 3 army-steps).  The
  player army is always drawn at the center cell `(screen_x, screen_y)`, so
  `mid = army.pos//3 + (cell - center)`.  (On the greater map one cell = one
  world tile, same centering -- that map keeps DF's own hover text.)
- Site footprints are `world_site.global_min/max_x/y`, in mid tiles, so a
  town lights up only while the cursor is over its actual span; camps, lairs
  and vaults are single-tile.  `hover_text_ax/ay` in
  `main_interface.adventure.travel` is greater-map-only and stays stale on
  the lesser map, which is why this reimplements the lookup instead.

Site data sources (this build): population = `site.populace.inhabitants`
count sum (the abstract population; falls back to `site.resident_count` for
the currently-loaded site, whose counts have been materialized into units);
notable residents = `site.populace.nemesis` -> nemesis_record -> histfig,
whose worldgen skill points are level x 1000, so >= 15000 = Legendary;
nobles = the owning entity's `positions.assignments` matched to residents.

Sites are looked up fresh only when the hovered cell or the army moves; the
per-frame cost is one cached paint.

    adv/read-the-map           status (the overlay is on by default)
]]

local overlay = require('plugins.overlay')

local MAX_NOBLES = 3       -- top-precedence position holders shown
local MAX_LEGENDS = 3      -- legendary residents shown
local LEGEND_PTS = 15000   -- worldgen skill points = level x 1000; 15 = Legendary
local MAX_WIDTH = 60       -- tooltip line clamp, in text cells

-- world_site_type -> what a player calls it ("LairShrine" is the lair marker,
-- vaults and the mysterious structures are ImportantLocation on this build)
local TYPE_NAMES = {
    PlayerFortress = 'Abandoned fortress',
    DarkFortress = 'Dark fortress',
    Cave = 'Cave',
    MountainHalls = 'Mountain halls',
    ForestRetreat = 'Forest retreat',
    Town = 'Town',
    ImportantLocation = 'Vault',
    LairShrine = 'Lair',
    Fortress = 'Fortress',
    Camp = 'Camp',
    Monument = 'Monument',
}

local function type_name(t)
    local raw = df.world_site_type[t] or tostring(t)
    return TYPE_NAMES[raw] or raw:gsub('(%l)(%u)', '%1 %2')
end

local function race_name(race)
    local ok, name = pcall(function()
        return df.global.world.raws.creatures.all[race].name[0]
    end)
    return ok and name or nil
end

local function hf_name(hf)
    local n = dfhack.translation.translateName(hf.name, true)
    return n ~= '' and n or 'someone'
end

local function skill_noun(skill)
    local ok, cap = pcall(function() return df.job_skill.attrs[skill].caption_noun end)
    return ok and cap or (df.job_skill[skill] or '?')
end

-- ---- site details -----------------------------------------------------------

local function population_lines(s, owner, lines)
    local total, races, distinct, first_race = 0, {}, 0, nil
    pcall(function()
        for i = 0, #s.populace.inhabitants - 1 do
            local inh = s.populace.inhabitants[i]
            local rn = race_name(inh.pop_spec.race)
            if rn then
                distinct = distinct + 1
                if not first_race then first_race = inh.pop_spec.race end
                total = total + inh.count
                races[#races + 1] = inh.count > 0 and (rn .. ' ' .. inh.count) or rn
            end
        end
    end)
    -- the loaded site's abstract counts are zeroed (they became live units);
    -- resident_count still has the head count
    if total == 0 then total = s.resident_count end
    local bits = {}
    if owner then bits[#bits + 1] = race_name(owner.race) end
    if total > 0 then bits[#bits + 1] = ('pop %d'):format(total) end
    local ownername = owner and dfhack.translation.translateName(owner.name, true) or ''
    if ownername ~= '' then bits[#bits + 1] = 'of ' .. ownername end
    if #bits > 0 then lines[#lines + 1] = '  ' .. table.concat(bits, ', ') end
    -- the breakdown matters when the population is mixed OR when the whole
    -- population is a different race than the occupying entity
    if distinct > 1 or (distinct == 1 and owner and first_race ~= owner.race) then
        lines[#lines + 1] = '  ' .. table.concat(races, ', ')
    end
end

-- residents of the site, as {hf=, nemesis-order} -- the nemesis vector holds
-- the site's named (historical) residents
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

local function noble_lines(s, owner, resident_hfs, lines)
    if not owner then return end
    local by_id = {}
    for _, hf in ipairs(resident_hfs) do by_id[hf.id] = true end
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
                        resident = by_id[hf_id] or false,
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
        lines[#lines + 1] = ('  %s: %s'):format(n.title:gsub('^%l', string.upper), hf_name(n.hf))
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
local MAX_DWELLERS = 3

local function dweller_lines(s, resident_hfs, lines)
    local alive = {}
    for _, hf in ipairs(resident_hfs) do
        if hf.died_year < 0 then alive[#alive + 1] = hf end
    end
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

local function site_lines(s, lines)
    local name = dfhack.translation.translateName(s.name, true)
    lines[#lines + 1] = type_name(s.type) .. (name ~= '' and (': ' .. name) or '')
    local owner
    pcall(function() owner = df.historical_entity.find(s.cur_owner_id) end)
    population_lines(s, owner, lines)
    local resident_hfs = residents(s)
    if DWELLING[df.world_site_type[s.type]] then
        dweller_lines(s, resident_hfs, lines)
    end
    noble_lines(s, owner, resident_hfs, lines)
    legend_lines(resident_hfs, lines)
    pcall(function()
        if #s.wg_quest_posting > 0 then
            lines[#lines + 1] = ('  Quests posted: %d'):format(#s.wg_quest_posting)
        end
    end)
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
    local player_army = df.global.adventure.player_army_id
    local armies = df.global.world.armies.all
    for i = 0, #armies - 1 do
        local a = armies[i]
        if a.id ~= player_army and a.pos.x // 3 == mx and a.pos.y // 3 == my then
            local n = 0
            pcall(function() n = #a.members end)
            lines[#lines + 1] = n > 0 and ('An army (%d)'):format(n) or 'An army'
        end
    end
    for i, l in ipairs(lines) do
        if #l > MAX_WIDTH then lines[i] = l:sub(1, MAX_WIDTH - 1) .. '~' end
    end
    if #lines > 0 then return lines end
end

-- exported for testing: the tooltip lines for a site id
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
    local army = df.army.find(adv.player_army_id)
    if not army then return end
    local gps = df.global.gps
    local mp = gps.main_map_port
    if mp.dim_x <= 0 or mp.dim_y <= 0 then return end
    -- map cells are square: window pixel width / dim_x (16px at this window size)
    local cellpx = math.max(1, (gps.dimx * gps.tile_pixel_x) // mp.dim_x)
    local cx = gps.precise_mouse_x // cellpx
    local cy = gps.precise_mouse_y // cellpx
    if cx < 0 or cx >= mp.dim_x or cy < 0 or cy >= mp.dim_y then return end

    local key = ('%d:%d:%d:%d'):format(cx, cy, army.pos.x, army.pos.y)
    if key ~= cache_key then
        cache_key = key
        local mx = army.pos.x // 3 + (cx - mp.screen_x)
        local my = army.pos.y // 3 + (cy - mp.screen_y)
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
