-- Extra embark-screen readout: adamantine, water, wildlife, every neighbour.
--@module = true
--[[
embark/extra-info

An overlay for the fortress embark screen (`choose_start_site`) that adds the
things the vanilla panel either truncates or never says.  It never covers DF's
own panel: the widget measures where that panel is actually drawn and puts
itself in the gap underneath, falling back to the top-left corner when there is
no room.  It is drawn with `gui.paint_frame` in DFHack's own
`FRAME_INTERIOR_MEDIUM` style -- the same call and art every DFHack window uses,
so it matches the game instead of being a hand-drawn box.  (Scraping the border
texpos off a panel already on screen, the way `adv/read-the-map` does it, does
NOT work here: this screen draws the world map into the same lower layer the
frames live in, and a field of identical terrain tiles reads as a border run.)

What it adds
------------
**Adamantine and water**, on one line.  Adamantine is reported by its *absence*:
having a spire is the ordinary case and tells you nothing, so a tile with one
says only `fresh water`, and a tile without one says `NO ADAMANTIUM, fresh
water`.  A spire made of something that is not adamantine -- a modded world
doing something unusual -- is still named outright.

Getting the adamantine right is the whole trick.  A world tile's
`feature_map` entry lists **sixty-four deep-special-tube candidates whatever the
tile is** -- a full 8x8 grid of 2x2 footprints, every one of them a realized
`feature_deep_special_tubest` pointing at raw adamantine.  Testing "is there a
tube in this tile's feature list" therefore answers YES everywhere, which is
exactly the bug this file used to have.  The realized layout lives elsewhere:
`world_data.midmap_data.region_details` holds the loaded regions, and
`details.features[x][y]` is the per-**embark-tile** feature list, each entry a
`feature_idx` into that world tile's candidate vector.  Only tiles whose list
actually resolves to a tube have adamantine, and on a sampled tile that was
about a quarter of them -- so a 1x1 embark genuinely is a coin flip.  (This is
the same path DFHack's own `prospect` takes pre-embark.)

**Stone and wood.**  The seven commonest stones of the geology column under the
embark, ranked by how many z-levels each layer occupies, with three entries
pulled up regardless of thickness because they decide what you can build rather
than how much rock there is: the biggest **flux** layer (steel), **lignite or
bituminous coal** (fuel without a magma sea), and anything with the **GYPSUM**
reaction class (plaster, so casts for broken bones).  Those three are tagged in
the list, and the count of everything else in the column follows it as
`(+N more)`.  Veins and clusters are read as well as layers, since coal and
gypsum usually arrive as seams.

Then the trees, with **featherwood** named outright when the region has it.  DF
gives no honest "commonest tree" pre-embark -- every tree population is recorded
as unlimited and vanilla sets `FREQUENCY:50` on all of them -- so the pick is by
`plant_raw.frequency` (the right field, but one that only discriminates where a
mod varies it) and then by how many `BIOME_*` tokens the species carries.  That
second key is what does the work: a tree declared for twenty biomes is the one
you will actually be cutting, a tree declared for three is a curiosity that
happens to tolerate this one.

**The wildlife.**  Up to fourteen animal populations, biggest first, exactly as
`adv/read-the-map` reads them: a `world_region` keeps its fauna as
`world_population` records in the same vector as its grasses, bushes and vermin,
so only the `Animal` entries count, and a population hunted to zero
(`count_max == 0`) is dropped.  Sorted by `adult_size`, which is the useful
order: the top of the list is what hunts you.

**Every neighbour that can actually reach you, one line per civilization.**
Vanilla shows four entries, one per *race*, which hides the case that matters --
two human civilizations, one at war and one at peace, are one line reading
"Humans".  Here each civilization is its own entry:

    The Spiteful Evils, 12 NE          842 goblins, at war
    The Crested Confederacies, 21 W    932 humans, peace

The order is round-robin by race, not a flat distance sort: every race's nearest
civilization is listed before any race gets a second, and each of those rounds is
ordered by distance.  A flat sort buries the world's one elf civilization behind
six succubus ones, and "who is out there at all" is what the list exists to
answer -- which also means that when it has to be trimmed to fit, the cut lands on
repeats instead of removing whole races.  An embark nothing can reach says so
("none in range") rather than dropping the panel.

The range is DF's, from the wiki: **armies are allowed a 30 world-tile radius of
interaction, and necromancer towers 10**; past that a siege cannot happen.  Both
are also required to be on the same landmass (`region_map_entry.landmass_id`),
since world-map travel does not cross ocean -- an island embark really is
unreachable.  Necromancer towers get their own entries because DF leaves them out
of the neighbour list entirely; a tower is a `Fortress` site whose
`subtype_info.fortress_type` is `TOWER` (there is no Tower site type).

The diplomatic word is per civilization, not per race: it comes from the chosen
origin civ's own `relations.diplomacy.state` entry for that group --
`TotalWar` -> at war, the `allies` flag -> allied, `Peace` -> peace, and no entry
at all -> no contact.  Population is the sum of the civ's `entity_population`
records.

It shows **only on the final placement step** -- the one that says "Click on the
map to embark!" and offers Abort instead of Embark.  Everything here describes a
specific rectangle, and before that step the rectangle is just wherever the mouse
is skimming over the world map; announcing NO ADAMANTIUM for a tile nobody has
chosen is noise.

Overlay `embark/extra-info.panel`, enabled by default; reposition or disable it
with gui/control-panel (Overlays).

Caveat: `feature_map` shells that are not the one in DF's focus are documented as
crash-prone to read.  Every lookup here is anchored to a world tile that has a
loaded `region_details` record, checks the shell's own `x`/`y` before
dereferencing it, and runs inside `pcall` -- the line goes missing rather than
the game.
]]

local gui = require('gui')
local overlay = require('plugins.overlay')

local MAX_ANIMALS = 14
local MAX_WIDTH = 72          -- text cells inside the frame
local NAME_COL = 34           -- "<civ name>, <dist> <dir>" column
local SALT_AT = 66            -- DF's own salinity bands, 0-100
local BRACKISH_AT = 33
local RANGE_CIV = 30          -- world tiles an army will cross (DF wiki)
local RANGE_TOWER = 10        -- ...and a necromancer tower

local function wd() return df.global.world.world_data end

local function scr_if_embark()
    local scr = dfhack.gui.getDFViewscreen(true)
    if df.viewscreen_choose_start_sitest:is_instance(scr) then return scr end
end

-- ---- the tiles under the embark ---------------------------------------------

-- Every EMBARK tile the rectangle covers (16 to a world tile), and every world
-- tile it touches.
local function covered(scr)
    local etiles, wtiles, seen = {}, {}, {}
    pcall(function()
        local lo, hi = scr.location.embark_pos_min, scr.location.embark_pos_max
        for ex = lo.x, hi.x do
            for ey = lo.y, hi.y do
                etiles[#etiles + 1] = {x = ex, y = ey}
                local wx, wy = ex // 16, ey // 16
                local key = wx * 4096 + wy
                if not seen[key] then
                    seen[key] = true
                    wtiles[#wtiles + 1] = {x = wx, y = wy}
                end
            end
        end
    end)
    if #wtiles == 0 then
        wtiles = {{x = scr.location.region_pos.x, y = scr.location.region_pos.y}}
    end
    return etiles, wtiles
end

local function region_entry(wx, wy)
    local w = wd()
    if wx < 0 or wy < 0 or wx >= w.world_width or wy >= w.world_height then return end
    local ok, rme = pcall(function() return w.region_map[wx]:_displace(wy) end)
    return ok and rme or nil
end

local function region_of(rme)
    local ok, r = pcall(function() return wd().regions[rme.region_id] end)
    return ok and r or nil
end

local function landmass_at(wx, wy)
    local rme = region_entry(wx, wy)
    return rme and rme.landmass_id or nil
end

local function spaced(s) return (s:gsub('(%l)(%u)', '%1 %2')) end

-- ---- adamantine --------------------------------------------------------------

local function region_details_at(wx, wy)
    for _, d in ipairs(wd().midmap_data.region_details) do
        if d.pos.x == wx and d.pos.y == wy then return d end
    end
end

-- The candidate list for one world tile: sixty-four tubes plus the caves, pits
-- and layer features.  `region_details.features` indexes into this.
local function feature_inits(wx, wy)
    local sx, sy = wx // 16, wy // 16
    local shell = wd().feature_map[sx]:_displace(sy)
    -- the shell knows its own coordinates; if they disagree we are looking at
    -- memory DF has not loaded and must not touch
    if not shell or not shell.features or shell.x ~= sx or shell.y ~= sy then return end
    return shell.features.feature_init[wx % 16][wy % 16]
end

-- The featstone of a deep special tube that REALLY sits under one of the embark
-- tiles, or nil.  See the header for why the candidate list cannot be used.
local function adamantine(etiles)
    local found
    pcall(function()
        local details, inits = {}, {}
        for _, t in ipairs(etiles) do
            local wx, wy = t.x // 16, t.y // 16
            local key = wx * 4096 + wy
            if details[key] == nil then
                details[key] = region_details_at(wx, wy) or false
                inits[key] = details[key] and feature_inits(wx, wy) or false
            end
            local d, init = details[key], inits[key]
            if d and init then
                local list = d.features[t.x % 16][t.y % 16]
                for i = 0, #list - 1 do
                    local idx = list[i].feature_idx
                    if idx >= 0 and idx < #init then
                        local f = init[idx]
                        if df.feature_init_deep_special_tubest:is_instance(f) then
                            local mi = dfhack.matinfo.decode(f.mat_type, f.mat_index)
                            found = mi and mi:toString() or 'unknown deep stone'
                            return
                        end
                    end
                end
            end
        end
    end)
    return found
end

-- ---- stone and wood ----------------------------------------------------------

local MAX_STONE = 7

local function inorganics() return df.global.world.raws.inorganics.all end

local function has_class(m, class)
    for i = 0, #m.material.reaction_class - 1 do
        if m.material.reaction_class[i].value == class then return true end
    end
    return false
end

local COAL_IDS = {LIGNITE = true, BITUMINOUS_COAL = true}

-- What the embark is made of, from the geology column its world tiles point at.
-- Layer stones are ranked by how many z-levels they occupy (that is what "most
-- common" means when you are digging); veins and clusters are collected too, but
-- only surface in the guaranteed slots below, because a vein is a seam and not a
-- stone you cut a fortress out of.
--
-- Three things are pulled up into the list whatever their thickness, because
-- they decide what you can build rather than how much rock there is: the biggest
-- FLUX layer (steel), lignite or bituminous coal (fuel without a magma sea), and
-- anything with the GYPSUM reaction class (plaster, so casts for broken bones).
local function stone_summary(wtiles)
    local inor = inorganics()
    local layer_weight, order = {}, {}
    local present = {}                      -- everything, layer or vein
    local seen_geo = {}
    pcall(function()
        for _, t in ipairs(wtiles) do
            local rme = region_entry(t.x, t.y)
            if rme and not seen_geo[rme.geo_index] then
                seen_geo[rme.geo_index] = true
                local gb = wd().geo_biomes[rme.geo_index]
                for i = 0, #gb.layers - 1 do
                    local L = gb.layers[i]
                    local idx = L.mat_index
                    if idx >= 0 then
                        local thick = math.max(1, L.top_height - L.bottom_height + 1)
                        if not layer_weight[idx] then order[#order + 1] = idx end
                        layer_weight[idx] = (layer_weight[idx] or 0) + thick
                        present[idx] = true
                    end
                    -- veins carry the gem clusters too, and a gem is not a
                    -- stone type: counting them turned "38 other stones" into
                    -- "114 more", which is just noise
                    for j = 0, #L.vein_mat - 1 do
                        local v = L.vein_mat[j]
                        local vm = v >= 0 and inor[v]
                        if vm and vm.material.flags.IS_STONE then present[v] = true end
                    end
                end
            end
        end
    end)
    if #order == 0 then return end

    local function name_of(idx)
        local m = inor[idx]
        if not m then return nil end
        local nm = m.material.state_name.Solid
        return (nm ~= '' and nm) or m.id:lower():gsub('_', ' ')
    end

    table.sort(order, function(a, b)
        if layer_weight[a] ~= layer_weight[b] then return layer_weight[a] > layer_weight[b] end
        return (name_of(a) or '') < (name_of(b) or '')
    end)

    -- the guaranteed entries, tagged so they are recognisable in the list
    local tag, forced = {}, {}
    local function force(idx, label)
        if not idx or tag[idx] then return end
        tag[idx] = label
        forced[#forced + 1] = idx
    end
    -- one representative per category, not all of them: a column with gypsum,
    -- alabaster, selenite and satinspar would otherwise spend four of the seven
    -- slots saying the same thing
    local best = {}
    local function nominate(key, idx)
        local w = layer_weight[idx] or 0
        if not best[key] or w > best[key].w then best[key] = {idx = idx, w = w} end
    end
    for idx in pairs(present) do
        local m = inor[idx]
        if m then
            if has_class(m, 'FLUX') then nominate('flux', idx) end
            if has_class(m, 'GYPSUM') then nominate('casts', idx) end
            if COAL_IDS[m.id] then nominate('coal', idx) end
        end
    end
    for _, key in ipairs{'flux', 'coal', 'casts'} do
        if best[key] then force(best[key].idx, key) end
    end

    local total = 0
    for _ in pairs(present) do total = total + 1 end

    local out, used = {}, {}
    local function push(idx)
        if used[idx] or #out >= MAX_STONE then return end
        used[idx] = true
        local nm = name_of(idx)
        if nm then out[#out + 1] = tag[idx] and (nm .. ' (' .. tag[idx] .. ')') or nm end
    end
    for _, idx in ipairs(forced) do push(idx) end
    for _, idx in ipairs(order) do push(idx) end
    return out, total
end

-- The trees the region can grow.  DF gives no honest "most common" here: every
-- tree population is recorded as unlimited and vanilla sets FREQUENCY:50 on all
-- of them, so the pick is by `plant_raw.frequency` (the right field) and is only
-- meaningful where a mod varies it.  Featherwood is called out by name because
-- it is worth going out of your way for.
local function wood_summary(wtiles)
    local plants = df.global.world.raws.plants.all
    local seen_region, trees, seen_id = {}, {}, {}
    local feather
    for _, t in ipairs(wtiles) do
        local rme = region_entry(t.x, t.y)
        local r = rme and region_of(rme)
        if r and not seen_region[r.index] then
            seen_region[r.index] = true
            pcall(function()
                for i = 0, #r.population - 1 do
                    local p = r.population[i]
                    if df.world_population_type[p.type] == 'Tree' then
                        local pl = plants[p.plant]
                        if pl and not seen_id[pl.id] then
                            seen_id[pl.id] = true
                            local nm = (pl.name ~= '' and pl.name) or pl.id:lower()
                            -- how many biomes the species is declared for: a
                            -- generalist is what you will actually be cutting
                            local spread = 0
                            for k, v in pairs(pl.flags) do
                                if v == true and tostring(k):sub(1, 6) == 'BIOME_' then
                                    spread = spread + 1
                                end
                            end
                            trees[#trees + 1] =
                                {name = nm, freq = pl.frequency or 0, spread = spread}
                            if pl.id:find('FEATHER') or nm:find('feather') then feather = nm end
                        end
                    end
                end
            end)
        end
    end
    if #trees == 0 then return end
    table.sort(trees, function(a, b)
        if a.freq ~= b.freq then return a.freq > b.freq end
        if a.spread ~= b.spread then return a.spread > b.spread end
        return a.name < b.name
    end)
    local line = ('Wood: %s (%d species)'):format(trees[1].name, #trees)
    if feather and feather ~= trees[1].name then line = line .. ' + ' .. feather end
    return line
end

-- ---- water -------------------------------------------------------------------

local function water_word(wtiles)
    local worst, ocean = -1, false
    for _, t in ipairs(wtiles) do
        local rme = region_entry(t.x, t.y)
        if rme then
            if rme.salinity > worst then worst = rme.salinity end
            local r = region_of(rme)
            if r and df.world_region_type[r.type] == 'Ocean' then ocean = true end
        end
    end
    if worst < 0 then return nil end
    if ocean or worst >= SALT_AT then return 'salt water' end
    if worst >= BRACKISH_AT then return 'brackish water' end
    return 'fresh water'
end

-- ---- wildlife ----------------------------------------------------------------

local function adult_size(race)
    local ok, sz = pcall(function()
        return df.global.world.raws.creatures.all[race].caste[0].misc.adult_size
    end)
    return ok and sz or 0
end

local function race_plural(race)
    local c = df.creature_raw.find(race)
    if not c then return nil end
    local n = c.name[1]
    return (n ~= '' and n) or c.name[0]
end

local function wildlife(wtiles)
    local seen_region, fauna, seen_name = {}, {}, {}
    for _, t in ipairs(wtiles) do
        local rme = region_entry(t.x, t.y)
        local r = rme and region_of(rme)
        if r and not seen_region[r.index] then
            seen_region[r.index] = true
            pcall(function()
                for i = 0, #r.population - 1 do
                    local p = r.population[i]
                    if df.world_population_type[p.type] == 'Animal' and p.count_max > 0 then
                        local nm = race_plural(p.race)
                        if nm and not seen_name[nm] then
                            seen_name[nm] = true
                            fauna[#fauna + 1] = {name = nm, size = adult_size(p.race)}
                        end
                    end
                end
            end)
        end
    end
    table.sort(fauna, function(a, b)
        if a.size ~= b.size then return a.size > b.size end
        return a.name < b.name
    end)
    local names = {}
    for i = 1, math.min(#fauna, MAX_ANIMALS) do names[i] = fauna[i].name end
    return names
end

-- ---- neighbours --------------------------------------------------------------

local COMPASS = {'E', 'NE', 'N', 'NW', 'W', 'SW', 'S', 'SE'}

local function direction(dx, dy)
    if dx == 0 and dy == 0 then return 'here' end
    -- world y grows southward, so the angle is taken against -dy
    local i = math.floor((math.atan(-dy, dx) % (2 * math.pi)) / (math.pi / 4) + 0.5) % 8
    return COMPASS[i + 1]
end

local function is_tower(s)
    local yes = false
    pcall(function()
        yes = df.world_site_type[s.type] == 'Fortress'
            and s.subtype_info ~= nil
            and df.fortress_type[s.subtype_info.fortress_type] == 'TOWER'
    end)
    return yes
end

local function civ_population(e)
    local tot = 0
    pcall(function()
        for _, pid in ipairs(e.populations) do
            local p = df.entity_population.find(pid)
            if p then
                for i = 0, #p.races - 1 do tot = tot + p.counts[i] end
            end
        end
    end)
    return tot
end

-- How the chosen origin civ stands with `other`, in its own diplomacy record.
-- `state` is sorted by group_id and holds only groups this civ has met, so a
-- missing entry is genuinely "never heard of them".
local function diplomacy_word(mine, other_id)
    if not mine or mine.id == other_id then return 'YOU' end
    local word = 'no contact'
    pcall(function()
        for _, st in ipairs(mine.relations.diplomacy.state) do
            if st.group_id == other_id then
                local rel = df.diplomacy_state_type[st.relation]
                if rel == 'TotalWar' then word = 'at war'
                elseif st.flags.allies then word = 'allied'
                elseif rel == 'NoContact' then word = 'no contact'
                elseif rel == 'AcceptingTribute' then word = 'taking tribute'
                elseif rel == 'OfferingTribute' then word = 'paying tribute'
                elseif rel == 'Skirmishing' then word = 'skirmishing'
                else word = 'peace' end
                return
            end
        end
    end)
    return word
end

-- One entry per civilization or tower that could actually send something here:
-- inside DF's interaction radius (30 world tiles for armies, 10 for towers) and
-- on the same landmass, since world-map travel does not cross ocean.
local function neighbours(scr, wx, wy)
    local home = landmass_at(wx, wy)
    local mine = scr.selected_civ >= 0 and scr.selected_civ < #scr.start_civ
        and scr.start_civ[scr.selected_civ] or nil

    local best, towers = {}, {}
    for _, s in ipairs(wd().sites) do
        local d = math.max(math.abs(s.pos.x - wx), math.abs(s.pos.y - wy))
        if is_tower(s) then
            if d <= RANGE_TOWER and landmass_at(s.pos.x, s.pos.y) == home then
                towers[#towers + 1] = {site = s, dist = d}
            end
        elseif s.civ_id >= 0 and d <= RANGE_CIV then
            local cur = best[s.civ_id]
            if not cur or d < cur.dist then best[s.civ_id] = {site = s, dist = d} end
        end
    end

    local out = {}
    for civ_id, hit in pairs(best) do
        local e = df.historical_entity.find(civ_id)
        if e and df.historical_entity_type[e.type] == 'Civilization'
            and landmass_at(hit.site.pos.x, hit.site.pos.y) == home
        then
            local race = race_plural(e.race)
            local pop = civ_population(e)
            -- a civ whose population has run out sends nobody; worldgen leaves
            -- some of these behind with a count of zero or even a negative one
            if race and pop > 0 then
                out[#out + 1] = {
                    name = dfhack.translation.translateName(e.name, true),
                    race = race,
                    dist = hit.dist,
                    dir = direction(hit.site.pos.x - wx, hit.site.pos.y - wy),
                    detail = ('%d %s, %s'):format(pop, race,
                                                  diplomacy_word(mine, civ_id)),
                }
            end
        end
    end
    for _, t in ipairs(towers) do
        out[#out + 1] = {
            name = dfhack.translation.translateName(t.site.name, true),
            race = 'necromancer tower',
            dist = t.dist,
            dir = direction(t.site.pos.x - wx, t.site.pos.y - wy),
            detail = 'necromancer tower',
        }
    end

    -- Round-robin by race, not a flat distance sort.  A flat sort buries the
    -- one elf civilization behind six succubus ones, and "who is out there at
    -- all" is the question this list exists to answer -- so every race gets its
    -- nearest civ shown before any race gets a second, and each of those rounds
    -- is itself ordered by distance.  Matters most when the list is trimmed to
    -- fit: the cut then falls on repeats rather than on whole races.
    local function nearer(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end
    table.sort(out, nearer)
    local count = {}
    for _, n in ipairs(out) do
        n.rank = count[n.race] or 0
        count[n.race] = n.rank + 1
    end
    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return nearer(a, b)
    end)
    return out
end

-- ---- the readout -------------------------------------------------------------

local function wrap(lines, text, indent)
    local cur
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

-- `maxrows` is how many text rows the panel may occupy; the neighbour list is
-- the only thing long enough to care, so it absorbs the whole budget.
function build_lines(scr, maxrows)
    maxrows = maxrows or (df.global.gps.dimy - 8)
    local etiles, wtiles = covered(scr)
    local lines = {}

    local rme = region_entry(wtiles[1].x, wtiles[1].y)
    local r = rme and region_of(rme)
    if r then
        local nm = dfhack.translation.translateName(r.name, true)
        local ty = spaced(df.world_region_type[r.type] or 'Region')
        lines[#lines + 1] = ty .. (nm ~= '' and (': ' .. nm) or '')
    end

    -- Adamantine is reported by its ABSENCE.  Having it is the normal case and
    -- says nothing useful; not having it is the thing that changes where you
    -- embark, so that is what gets shouted.  A spire of something other than
    -- adamantine is a modded world doing something unusual and still gets named.
    local parts = {}
    local tube = adamantine(etiles)
    if not tube then
        parts[#parts + 1] = 'NO ADAMANTIUM'
    elseif not tube:find('adamantine', 1, true) then
        parts[#parts + 1] = tube
    end
    local water = water_word(wtiles)
    if water then parts[#parts + 1] = water end
    if #parts > 0 then lines[#lines + 1] = table.concat(parts, ', ') end

    local stones, stone_total = stone_summary(wtiles)
    if stones and #stones > 0 then
        local rest = (stone_total or #stones) - #stones
        wrap(lines, 'Stone: ' .. table.concat(stones, ', ')
            .. (rest > 0 and (' (+%d more)'):format(rest) or ''), '')
    end

    local wood = wood_summary(wtiles)
    if wood then wrap(lines, wood, '') end

    local animals = wildlife(wtiles)
    if #animals > 0 then
        wrap(lines, ('Wildlife (%d): %s'):format(#animals, table.concat(animals, ', ')), '')
    end

    local nb = neighbours(scr, wtiles[1].x, wtiles[1].y)
    -- In a crowded world a 30-tile radius is thirty-odd civilizations, which is
    -- taller than the screen.  Nearest first, trimmed to what will actually fit
    -- with the frame and DF's own panel, and the tail is counted rather than
    -- silently dropped.
    local room = maxrows - #lines - 2      -- the heading and the "...and N more"
    local shown = math.max(0, math.min(#nb, room))
    if #nb == 0 then
        -- an island, or a corner of the world nobody can walk to.  Worth saying
        -- out loud rather than dropping the whole panel, which is what an
        -- unguarded `nb[1]` used to do here.
        lines[#lines + 1] = 'Neighbors: none in range -- nobody can reach you'
        return lines
    end
    -- the heading counts what is out there, not what fits; the trimming says its
    -- own piece on the last line.  Races counted are civilization races, so a
    -- necromancer tower is in the total but is not one of them.
    local races = {}
    local nraces = 0
    for _, n in ipairs(nb) do
        if n.race ~= 'necromancer tower' and not races[n.race] then
            races[n.race] = true
            nraces = nraces + 1
        end
    end
    lines[#lines + 1] = ('Neighbors: %d from %d races'):format(#nb, nraces)
    -- the left column is sized to the longest "name, dist dir" it has to hold,
    -- so the detail column lines up whatever the civ names are
    local left, w = {}, 0
    for i = 1, shown do
        local n = nb[i]
        -- the distance and bearing are the point of the line, so a long civ
        -- name loses its tail rather than pushing them off the end
        local tail = (', %d %s'):format(n.dist, n.dir)
        local name = n.name
        if #name + #tail > NAME_COL then name = name:sub(1, NAME_COL - #tail - 1) .. '.' end
        left[i] = name .. tail
        if #left[i] > w then w = #left[i] end
    end
    for i = 1, shown do
        lines[#lines + 1] = ('  %-' .. w .. 's  %s'):format(left[i], nb[i].detail)
    end
    if shown < #nb then
        -- the list is not in distance order any more, so the tail's reach has
        -- to be measured rather than read off the last entry
        local far = 0
        for i = shown + 1, #nb do far = math.max(far, nb[i].dist) end
        lines[#lines + 1] = ('  ...and %d more, out to %d tiles')
            :format(#nb - shown, far)
    end
    return lines
end

-- ---- painting ---------------------------------------------------------------

local PEN_HEAD = dfhack.pen.parse{fg = COLOR_LIGHTCYAN, bg = COLOR_BLACK}
local PEN_TEXT = dfhack.pen.parse{fg = COLOR_WHITE, bg = COLOR_BLACK}
local PEN_BLANK = dfhack.pen.parse{ch = 32, fg = COLOR_WHITE, bg = COLOR_BLACK}

-- Where DF drew its own panel, as a bounding box of printable cells in the right
-- of the screen.  The bottom button row and the FPS counter are excluded by the
-- scan bounds, so what is left is the info panel and nothing else.
local function vanilla_panel_box()
    local gps = df.global.gps
    local x0 = (gps.dimx * 55) // 100
    local minx, miny, maxx, maxy
    for y = 0, gps.dimy - 6 do
        for x = x0, gps.dimx - 1 do
            local t = dfhack.screen.readTile(x, y)
            local ch = t and t.ch or 0
            if ch > 32 and ch < 127 then
                if not minx or x < minx then minx = x end
                if not maxx or x > maxx then maxx = x end
                if not miny or y < miny then miny = y end
                if not maxy or y > maxy then maxy = y end
            end
        end
    end
    if not minx then return end
    return {minx = minx, miny = miny, maxx = maxx, maxy = maxy}
end

local function paint(lines, box)
    local gps = df.global.gps
    local width = 0
    for _, l in ipairs(lines) do width = math.max(width, #l) end
    width = math.min(width, MAX_WIDTH)
    local inner = width + 2                   -- a space of padding each side
    local bw, bh = inner + 2, #lines + 2      -- plus the border itself

    local tx, ty
    if box and box.maxy + 2 + bh <= gps.dimy - 5 then
        tx = math.max(0, math.min(box.maxx - bw + 1, gps.dimx - bw))
        ty = box.maxy + 2
    elseif box then
        tx, ty = 1, 1                          -- no room below: top-left corner
    else
        tx, ty = math.max(0, gps.dimx - bw - 1), 1
    end

    -- DFHack's own frame art, the same call every DFHack window uses, rather
    -- than a texpos anchor scraped off whatever panel happened to be on screen.
    -- The scraping approach kept mis-firing here: this screen draws the WORLD
    -- MAP into the same lower layer the frames live in, so a field of identical
    -- terrain tiles reads as a border run.  FRAME_INTERIOR_MEDIUM is the plain
    -- one -- no "DFHack" signature stamped into the bottom edge.
    local x2, y2 = tx + bw - 1, ty + bh - 1
    dfhack.screen.fillRect(PEN_BLANK, tx, ty, x2, y2)
    gui.paint_frame({x1 = 0, y1 = 0}, {x1 = tx, y1 = ty, x2 = x2, y2 = y2},
                    gui.FRAME_INTERIOR_MEDIUM)

    for i, line in ipairs(lines) do
        line = line:sub(1, width)
        dfhack.screen.paintString(i == 1 and PEN_HEAD or PEN_TEXT, tx + 1, ty + i,
            ' ' .. line .. string.rep(' ', inner - #line - 1))
    end
end

-- ---- overlay ----------------------------------------------------------------

ExtraInfo = defclass(ExtraInfo, overlay.OverlayWidget)
ExtraInfo.ATTRS{
    desc = 'Adamantine, water, wildlife and every reachable neighbour at embark.',
    default_enabled = true,
    viewscreens = 'choose_start_site',
    frame = {w = 1, h = 1},
    overlay_onupdate_max_freq_seconds = 0.3,
}

-- `self.active` is reserved on overlay widgets -- a falsy value there makes the
-- framework skip overlay_onupdate entirely -- so the "have something to draw"
-- flag is called show.
function ExtraInfo:overlay_onupdate()
    self.show = false
    local scr = scr_if_embark()
    -- ONLY on the final placement step -- the one where the button row reads
    -- Abort rather than Embark.  Before that the "embark" is just wherever the
    -- mouse happens to be over the world map, and reporting NO ADAMANTIUM for a
    -- tile nobody has chosen is noise.
    if not scr or not scr.choosing_embark then return end
    -- how many rows fit in the gap under DF's panel, from the box measured on
    -- the last rendered frame.  A gap too small to be worth using means the
    -- panel is going to the corner instead, where it gets the full screen.
    local gps = df.global.gps
    local rows = self.box and (gps.dimy - 5 - (self.box.maxy + 2)) or (gps.dimy - 6)
    if rows < 10 then rows = gps.dimy - 6 end
    rows = rows - 2                              -- the frame
    local lo = scr.location.embark_pos_min
    local hi = scr.location.embark_pos_max
    local key = ('%d:%d:%d:%d:%d:%d'):format(lo.x, lo.y, hi.x, hi.y, scr.selected_civ, rows)
    if key ~= self.key then
        self.key = key
        local ok, lines = pcall(build_lines, scr, rows)
        self.lines = ok and lines or nil
    end
    self.show = self.lines ~= nil
end

function ExtraInfo:onRenderFrame(dc, rect)
    if not self.show or not self.lines then return end
    pcall(function()
        -- measured HERE, not in onupdate: overlays paint after DF, so this frame
        -- still holds only DF's own panels and the scan cannot pick up the box
        -- this widget drew last time and walk itself down the screen
        self.box = vanilla_panel_box()
        paint(self.lines, self.box)
    end)
end

OVERLAY_WIDGETS = {panel = ExtraInfo}

if dfhack_flags.module then return end

-- run bare: print the same readout to the console, which is also how you check
-- the numbers without squinting at the map
local scr = scr_if_embark()
if not scr then
    qerror('embark/extra-info: not on the fortress embark screen.')
end
for _, l in ipairs(build_lines(scr)) do print(l) end
print('')
print('The overlay is enabled by default; manage it with gui/control-panel (Overlays).')
