-- What a world-map site is actually made of: its stone, trees, plants and game.
--@module = true
--[[
fort/economic-expeditions

HOUSE RULE (display half). On the fort-mode world map, clicking a site shows you its name,
its population and three buttons. It tells you nothing about what is THERE. This adds a
survey panel under DF's `Diplomacy` button listing what the site's land holds:

    * STONE -- the layer stones (always present) and the vein/cluster materials, grouped by
      how hard they are to find.
    * TREES, PLANTS and GAME -- what actually lives in that region, with population counts.
    * BOOKS -- whether the site has a library at all (see the caveat below).

This is the READ-ONLY half of a larger house rule; sending expeditions comes later. Nothing
here writes to the game.

WHERE THE NUMBERS COME FROM, and why none of it is a scan:

  STONE is the world tile's GEOLOGY, not a survey of the ground. `region_map_entry.geo_index`
  picks a `world_geo_biome`, whose `layers` carry the layer stone (`mat_index`, guaranteed to
  be there) and the vein materials (`vein_mat`) each tagged with an `inclusion_type` --
  VEIN, CLUSTER, CLUSTER_SMALL, CLUSTER_ONE. That tag is the rarity signal, and it is a
  handful of vector reads rather than a prospect sweep, so it is cheap enough to do on a
  panel. It is a MODEL of what the rock would hold, not a count of what is there.

  TREES, PLANTS and GAME come from `world_region.population`, which is DF's own record of
  what lives in that region, with `count_min`/`count_max` per entry. This is much better
  than filtering the creature raws by biome flag: the biome flags say what COULD live in a
  temperate grassland (224 creatures, measured) while the region population says what DOES
  live in this one (130). Vermin and insect colonies are dropped -- they are not game.

  NEVER INDEX `world_data.region_map` BY HAND. It is declared `region_map_entry**` and
  DFHack hands it over with no bounds checking, so a computed offset that is off by a row
  reads unmapped memory and takes the game down with it. `dfhack.maps.getRegionBiome(x, y)`
  is the bounds-checked way in and is what this uses.

THE BOOKS CAVEAT, which is a real limitation and not a TODO. Off-map sites do not
instantiate items, so their libraries hold no book items: measured on this world, 7
libraries across 3664 sites and ZERO book item ids between them. `world.written_contents`
has 11474 texts, but a written content records its author and its references and NOT where
it is kept, so there is no way to say which texts sit at which site. So this panel can tell
you a site HAS a library; it cannot list its books, and a scholarly expedition cannot copy a
named one without inventing the answer.

THE PANEL IS PLACED BY READING THE SCREEN. DF's site panel is a v50 widget_container whose
children sit behind an opaque shared_ptr, so nothing can be inserted into it. Instead the
`Diplomacy` label is located in a bounded band on the right-hand side of the screen and the
survey is drawn below it -- the same trick `fort/butcher-shop` uses for its button. If the
label is not found the panel does not draw, rather than guessing a position.

    fort/economic-expeditions          print the survey for the selected site
    fort/economic-expeditions <id>     print the survey for a site by id
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local gui = require('gui')

local GLOBAL_KEY = 'economic-expeditions'

-- ---------------------------------------------------------------------------
-- reading a site
-- ---------------------------------------------------------------------------

-- How hard the stone is to come by, worst last. The tag is DF's own `inclusion_type` on the
-- geo layer's vein list; the wording is ours. A layer stone has no tag at all -- it IS the
-- layer, so it is always there.
local RARITY_ORDER = {'layer', 'VEIN', 'CLUSTER', 'CLUSTER_SMALL', 'CLUSTER_ONE'}
local RARITY_LABEL = {
    layer           = 'Layer stone',
    VEIN            = 'Veins',
    CLUSTER         = 'Clusters',
    CLUSTER_SMALL   = 'Small clusters',
    CLUSTER_ONE     = 'Single gems',
}

local function inorganic_name(mat_index)
    local ir = df.global.world.raws.inorganics.all[mat_index]
    if not ir then return nil end
    local ok, nm = pcall(function() return ir.material.state_name.Solid end)
    if ok and nm and nm ~= '' then return nm end
    return ir.id:lower():gsub('_', ' ')
end

-- Stone you could actually come back with.
--
-- SOIL LAYERS DROP NO BOULDERS. Clay, silt, silt loam and sandy clay loam are layers like any
-- other in the geology, but digging them yields nothing to carry -- listing them as things a
-- mining expedition might fetch would be a lie. `inorganic.flags.SOIL` is the test (the geo
-- layer's own SOIL/SOIL_OCEAN/SOIL_SAND type agrees), and it is the same test
-- `fort/auto-needs` uses when it picks a stone to carve.
--
-- ADAMANTINE IS NEVER OFFERED, and it never appears here anyway: the spire is a map FEATURE,
-- not part of any geo layer, so it is not in this data to begin with. The name check is
-- belt and braces for a modded raw that puts it in a layer.
local function is_forbidden_stone(mat_index)
    local ir = df.global.world.raws.inorganics.all[mat_index]
    if not ir then return true end
    if ir.id == 'INORGANIC_ADAMANTINE' then return true end
    local ok, soil = pcall(function() return ir.flags.SOIL end)
    if ok and soil then return true end
    return false
end

-- the stone of the world tile a site stands on, bucketed by rarity
local function site_stone(site)
    local ok, rgn = pcall(dfhack.maps.getRegionBiome, site.pos.x, site.pos.y)
    if not ok or not rgn then return {} end
    local gb = df.global.world.world_data.geo_biomes[rgn.geo_index]
    if not gb then return {} end

    local seen, buckets = {}, {}
    local function add(bucket, mat_index)
        if is_forbidden_stone(mat_index) then return end
        local nm = inorganic_name(mat_index)
        if not nm or seen[nm] then return end
        seen[nm] = true
        buckets[bucket] = buckets[bucket] or {}
        table.insert(buckets[bucket], nm)
    end

    for i = 0, #gb.layers - 1 do
        local L = gb.layers[i]
        add('layer', L.mat_index)
        for j = 0, #L.vein_mat - 1 do
            local vt = df.inclusion_type[L.vein_type[j]] or 'CLUSTER'
            add(vt, L.vein_mat[j])
        end
    end
    for _, list in pairs(buckets) do table.sort(list) end
    return buckets
end

-- WHAT LIVES THERE, from DF's per-world-tile LOCAL POPULATIONS -- `world.populations.all`,
-- 9146 `local_population` entries for this world, each tagged with a world tile through its
-- `world_population_ref`. This is the roster DF actually spawns from, and getting to it took
-- two corrections worth writing down because both produced confidently wrong lists:
--
--   1. IT IS PER WORLD TILE, NOT PER REGION. `world_region.population` is the union over every
--      tile the region covers -- "The Prairie of Zeniths" spans 415 of them -- so it credited a
--      site with coconut palms growing four hundred tiles away. A tile's own roster is 13-15
--      surface animals, which is the number you see wandering into a fort.
--
--   2. SURFACE ONLY: `layer_depth`, `cave_id` and `feature_idx` must ALL be -1. Unfiltered, a
--      tile returns 74-126 entries, because the same structure carries the cavern layers
--      (crundle, troll, gorlak), the magma sea (fire imp, magma man), the HFS (demons) and the
--      water (carp, pike, sturgeon). A hunting party is not coming back with a troll.
--
-- A SITE IS NOT ONE TILE, which is why this unions over the tiles the site covers rather than
-- reading `site.pos`. 1441 of this world's 3664 sites span more than one world tile (the
-- largest, a dark fortress, spans four). Burnedroofs covers x 70..71, y 78..79: three of those
-- tiles hold the same 15 grassland animals and the fourth holds a 10-strong desert roster with
-- camels, jaguar and leopard in it. Reading `pos` alone would have dropped the camels.
--
-- SAVAGE TILES ARE NOT A BUG. A savage tile legitimately carries ~51 surface animals -- the
-- giant variants and the animal people both live there. Animal people are filtered as people;
-- the giants stay.
--
-- THE AGREED DIFFICULTY RULE for the hunting half, recorded here so the display collects what
-- it needs. Three tiers, and they do NOT stack:
--
--   normal game            10% per ambusher level for a corpse, 1% for a caged one
--   normal game, savage    5% / 0.5%   -- twice as hard, because of where it lives
--   giant                  2% / 0.2%   -- five times as hard, savage or not
--
-- The savage doubling applies ONLY to ordinary creatures in a savage place. A giant is already
-- the five-times tier and does not get doubled again for standing on a savage tile, which is
-- the only tile it would ever stand on anyway.
--
-- SAVAGERY IS PER TILE, NOT PER SITE, and that matters for a site straddling a boundary: a
-- creature is only "savage game" if EVERY tile it was found on is savage. Found on a calm tile
-- as well and you can go hunt it there, at the ordinary rate. Measured on this embark, the bar
-- is exactly right -- tile 70,80 at savagery 66 carries 26 giants and 15 ordinary animals,
-- while every tile below 66 carries zero giants.
--
-- "Giant" is `creature_raw.flags.SAVAGE`, not a name match, and it is near-exact once animal
-- people are gone: of 165 creatures whose id starts GIANT_, 164 carry SAVAGE, and the SAVAGE
-- creatures that are NOT giants are almost entirely animal men, which this already drops as
-- people. The flag also catches BIRD_PENGUIN_GIANT, which an id-prefix test would miss.
function is_giant(cr)
    if not cr then return false end
    local ok, savage = pcall(function() return cr.flags.SAVAGE end)
    return ok and savage == true
end

-- DF's own savagery is 0-99 per world tile; 66 and up is what the game calls a savage biome.
local SAVAGE_BAR = 66
local POP_GAME   = {Animal = true}
local POP_TREE   = {Tree = true}
local POP_PLANT  = {Bush = true, Grass = true}

function is_game(cr)
    if not cr then return false end
    local caste = cr.caste[0]
    if not caste then return false end
    return not (caste.flags.CAN_LEARN or caste.flags.CAN_SPEAK)
end

local function creature_name(race)
    local cr = df.global.world.raws.creatures.all[race]
    if not cr or not is_game(cr) then return nil end
    local n = cr.name[0]
    return (n ~= '' and n) or cr.creature_id:lower():gsub('_', ' ')
end

-- GRASS IS NOT A CROP. `plant_raw.flags.GRASS` marks the ground cover -- meadow-grass, grama,
-- blue sedge, ryegrass -- which no herbalist can gather and which has no seed to plant. They
-- turned up in the plant list because the region records them as growing there, which is true
-- and useless: you cannot send anybody to pick them. Rope reed and rat weed carry no GRASS
-- flag and stay.
local function is_gatherable_plant(p)
    if not p then return false end
    local ok, grass = pcall(function() return p.flags.GRASS end)
    return not (ok and grass)
end

local function plant_name(idx)
    local p = df.global.world.raws.plants.all[idx]
    if not p or not is_gatherable_plant(p) then return nil end
    local n = p.name
    return (n ~= '' and n) or p.id:lower():gsub('_', ' ')
end

-- trees are named the same way but are never grass, so they keep their own accessor
local function tree_name(idx)
    local p = df.global.world.raws.plants.all[idx]
    if not p then return nil end
    local n = p.name
    return (n ~= '' and n) or p.id:lower():gsub('_', ' ')
end

-- the world tiles a site stands on. `global_min/max` are in mid-level tiles, 16 to a world
-- tile; `pos` is the fallback if that range reads oddly on some site type.
local function site_tiles(site)
    local tiles, seen = {}, {}
    local ok = pcall(function()
        local x0, x1 = math.floor(site.global_min_x / 16), math.floor(site.global_max_x / 16)
        local y0, y1 = math.floor(site.global_min_y / 16), math.floor(site.global_max_y / 16)
        if x1 < x0 or y1 < y0 or (x1 - x0) > 16 or (y1 - y0) > 16 then error('bad extent') end
        for x = x0, x1 do for y = y0, y1 do
            local k = x .. ',' .. y
            if not seen[k] then seen[k] = true; tiles[#tiles + 1] = {x = x, y = y} end
        end end
    end)
    if not ok or #tiles == 0 then tiles = {{x = site.pos.x, y = site.pos.y}} end
    return tiles
end

-- THE EXACT ANSWER IS ONLY AVAILABLE NEAR HOME, which is the limitation that shapes this.
-- `world.populations.all` is generated for the LOADED EMBARK'S NEIGHBOURHOOD and nowhere else:
-- measured on this world, 9146 entries covering 49 world tiles (x 65..71, y 77..83) out of
-- 33153. Ask it about Shinmystery, a forest retreat 116 tiles east with vegetation 90, and it
-- returns nothing at all -- which an earlier version dutifully printed as "Trees: none here"
-- for a site in the middle of a conifer forest.
--
-- So there are two answers and the panel says which one you are getting:
--
--   EXACT  the site's tiles have local populations -- the 13-15 surface animals DF actually
--          spawns there, per tile, with the caverns and the water filtered out.
--   REGION the fallback: the roster of the REGION the site sits in, intersected with the biome
--          of the site's own tile. A region spans hundreds of tiles and several biomes, so the
--          intersection is what keeps it from crediting a temperate site with jungle animals.
--          Broader than the truth -- it lists what could be there rather than what is.
local function life_from_local(site, want)
    local out = {game = {}, savage_game = {}, giant_game = {}, trees = {}, plants = {}}
    local savagery, found = {}, false
    for key in pairs(want) do
        local x, y = key:match('^(%-?%d+),(%-?%d+)$')
        local ok, rgn = pcall(dfhack.maps.getRegionBiome, tonumber(x), tonumber(y))
        savagery[key] = (ok and rgn) and rgn.savagery or 0
    end

    local calmest, giant, seen = {}, {}, {}
    for _, lp in ipairs(df.global.world.populations.all) do
        local r = lp.population
        if r.layer_depth == -1 and r.cave_id == -1 and r.feature_idx == -1 then
            local key = r.region_x .. ',' .. r.region_y
            if want[key] then
                found = true
                local kind = df.world_population_type[lp.type]
                if POP_GAME[kind] then
                    local cr = df.global.world.raws.creatures.all[lp.race]
                    local nm = creature_name(lp.race)
                    if nm then
                        local sv = savagery[key] or 0
                        if calmest[nm] == nil or sv < calmest[nm] then calmest[nm] = sv end
                        giant[nm] = is_giant(cr)
                    end
                else
                    local nm, into
                    if POP_TREE[kind] then nm, into = tree_name(lp.plant), out.trees
                    elseif POP_PLANT[kind] then nm, into = plant_name(lp.plant), out.plants
                    end
                    if nm then
                        local k2 = kind .. ':' .. nm
                        if not seen[k2] then seen[k2] = true; table.insert(into, nm) end
                    end
                end
            end
        end
    end
    if not found then return nil end
    for nm, sv in pairs(calmest) do
        local bucket = giant[nm] and out.giant_game
            or (sv >= SAVAGE_BAR and out.savage_game or out.game)
        table.insert(bucket, nm)
    end
    return out
end

-- The fallback. `world_region.population` is the union over every tile the region covers, so
-- it is intersected with the biome flag of the site's own tile -- without that a temperate
-- site is credited with whatever grows at the far end of a 400-tile region.
local function life_from_region(site)
    local out = {game = {}, savage_game = {}, giant_game = {}, trees = {}, plants = {}}
    local ok, rgn = pcall(dfhack.maps.getRegionBiome, site.pos.x, site.pos.y)
    if not ok or not rgn then return out end
    local wr = df.global.world.world_data.regions[rgn.region_id]
    if not wr then return out end

    local flag
    local okb, bt = pcall(dfhack.maps.getBiomeType, site.pos.x, site.pos.y)
    if okb and bt then flag = 'BIOME_' .. tostring(df.biome_type[bt]) end
    local function in_biome(raw)
        if not flag or not raw then return true end
        local got, on = pcall(function() return raw.flags[flag] end)
        return got and on == true
    end

    local savage = rgn.savagery >= SAVAGE_BAR
    local creatures, plants = df.global.world.raws.creatures.all, df.global.world.raws.plants.all
    local seen = {}
    for i = 0, #wr.population - 1 do
        local p = wr.population[i]
        local kind = df.world_population_type[p.type]
        local nm, into
        if POP_GAME[kind] then
            local cr = creatures[p.race]
            if in_biome(cr) then
                nm = creature_name(p.race)
                into = is_giant(cr) and out.giant_game
                    or (savage and out.savage_game or out.game)
            end
        elseif POP_TREE[kind] then
            if in_biome(plants[p.plant]) then nm, into = tree_name(p.plant), out.trees end
        elseif POP_PLANT[kind] then
            if in_biome(plants[p.plant]) then nm, into = plant_name(p.plant), out.plants end
        end
        if nm and into then
            local key = kind .. ':' .. nm
            if not seen[key] then seen[key] = true; table.insert(into, nm) end
        end
    end
    return out
end

local function site_life(site)
    local want = {}
    for _, t in ipairs(site_tiles(site)) do want[t.x .. ',' .. t.y] = true end
    local out, exact = life_from_local(site, want), true
    if not out then out, exact = life_from_region(site), false end
    out.exact = exact
    table.sort(out.game); table.sort(out.savage_game); table.sort(out.giant_game)
    table.sort(out.trees); table.sort(out.plants)
    return out
end

-- THE BOOKS A SITE HOLDS, by title.
--
-- An earlier version of this said titles were unavailable off-map, and that was wrong. It is
-- true that an off-map library instantiates no ordinary book items -- `library.item_id` is
-- empty on all 7 of this world's libraries -- and true that `written_content` records an
-- author and references but never a location. But ARTIFACT books are a different thing
-- entirely: `world.artifacts.all` carries 1710 records, each with a real `item` and a `site`,
-- and DF shows them on the site panel under Artifacts. Filtering those to `item_type.BOOK`
-- gives exactly the titles the panel lists -- "The Journey into Trickery", "Musings on
-- Surveying" and the rest at Silkendied.
--
-- These are the NAMED books, not every volume on the shelves; ordinary copies still do not
-- exist off-map. It is the difference between "there is a library here" and "here is what is
-- worth sending somebody for", which is the question this panel is trying to answer.
function site_books(site)
    local out = {}
    if not site then return out end
    for _, art in ipairs(df.global.world.artifacts.all) do
        if art.site == site.id then
            local item = art.item
            if item and item:getType() == df.item_type.BOOK then
                out[#out + 1] = dfhack.translation.translateName(art.name, true)
            end
        end
    end
    table.sort(out)
    return out
end

-- A site's libraries -- the BUILDING, which is a different question from whether any books are
-- there: 7 sites in this world have a library and 139 hold book artifacts. Exported because
-- `better-world-map` marks library sites on the world map, and there should be one answer to
-- "does this place keep books", not two.
function site_libraries(site)
    local n = 0
    for _, b in ipairs(site.buildings) do
        if df.abstract_building_libraryst:is_instance(b) then n = n + 1 end
    end
    return n
end

-- HOW A SITE STANDS TO YOU. Three answers, and DF draws a real distinction between them that
-- an earlier version of this flattened into one:
--
--   'own'         your fortress.
--   'controlled'  YOUR holding -- what DF calls "economically linked to you", the site whose
--                 panel offers Request workers.
--   'civ'         merely belongs to your civilization. Your civ, somebody else's holding: you
--                 cannot attack it and cannot negotiate with it, and that is all it means.
--
-- THE DISCRIMINATOR IS `position_profile_id`, not the link flags. Every one of this world's 16
-- `land_for_holding` links points at the same civ entity, so testing the flag alone calls all
-- sixteen yours when fifteen belong to other nobles. Each link carries the POSITION PROFILE it
-- was granted to, and yours is the one on your own fort's link -- profile 11 here, which is
-- also the `land_holder_residence`. Sorting by it gives 1 own / 1 controlled / 14 civ, against
-- the flat test's 1 + 15.
local function our_position_profile()
    local home = df.world_site.find(df.global.plotinfo.site_id)
    if not home then return nil end
    local civ = df.global.plotinfo.civ_id
    for _, link in ipairs(home.entity_links) do
        if link.entity_id == civ and link.position_profile_id >= 0 then
            return link.position_profile_id
        end
    end
end

function site_standing(site)
    if not site then return nil end
    if site.id == df.global.plotinfo.site_id then return 'own' end
    local civ, grp = df.global.plotinfo.civ_id, df.global.plotinfo.group_id
    local profile = our_position_profile()
    local in_civ = false
    for _, link in ipairs(site.entity_links) do
        if link.entity_id == civ or link.entity_id == grp then
            in_civ = true
            if profile and link.entity_id == civ and link.position_profile_id == profile then
                return 'controlled'
            end
        end
    end
    if in_civ then return 'civ' end
    return nil
end

-- Are we at war with whoever holds this site?
--
-- DIPLOMACY IS TRACKED PER SITE GOVERNMENT, not per civilization -- every `group_id` in our
-- civ's `relations.diplomacy.state` resolves to a SiteGovernment entity, so looking the site's
-- CIVILIZATION up there finds nothing and reads every foreign place as "no contact". The site
-- government is the entity on the site's own `residence` link.
--
-- `relation == 1` is war; `flags.allies` is an alliance; anything else, including no state at
-- all, is peace or no contact. This world: at war with 2 governments, allied with 7, 19 other.
function site_hostile(site)
    if not site then return false end
    local me = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not me then return false end
    local gov
    for _, link in ipairs(site.entity_links) do
        local e = df.historical_entity.find(link.entity_id)
        if e and e.type == df.historical_entity_type.SiteGovernment then gov = e break end
    end
    if not gov then return false end
    for _, st in ipairs(me.relations.diplomacy.state) do
        if st.group_id == gov.id then return st.relation == 1 end
    end
    return false                                  -- no state at all: no contact, not hostile
end

-- Is this site somewhere we can send an expedition?
--
-- YOUR HOLDINGS, and other fortresses you have played. Belonging to your civilization is NOT
-- enough -- another noble's hillocks are not yours to strip, which is the distinction
-- `site_standing` draws. A fort you played and retired qualifies whatever the diplomacy graph
-- says; the fort you are sitting in does not, there being nowhere to send anybody.
-- (This world has exactly one player fortress, the current one, so that branch is written from
-- the site type and has not been exercised against a second fort.)
function is_ours(site)
    if site.type == df.world_site_type.PlayerFortress then
        return site.id ~= df.global.plotinfo.site_id
    end
    return site_standing(site) == 'controlled'
end

-- The worst savagery across the tiles the site covers -- the hunting half doubles difficulty
-- above SAVAGE_BAR, and a site straddling a savage tile is a savage place to hunt.
function site_savagery(site)
    local worst = 0
    for _, t in ipairs(site_tiles(site)) do
        local ok, rgn = pcall(dfhack.maps.getRegionBiome, t.x, t.y)
        if ok and rgn and rgn.savagery > worst then worst = rgn.savagery end
    end
    return worst
end

function is_savage_site(site)
    return site_savagery(site) >= SAVAGE_BAR
end

-- everything the panel shows, cached per site: the geology and the region population do not
-- change while you look at them, and this runs behind a render
local cache = {id = nil, data = nil}

function survey(site)
    if not site then return nil end
    if cache.id == site.id then return cache.data end
    local ok, rgn = pcall(dfhack.maps.getRegionBiome, site.pos.x, site.pos.y)
    local wr = (ok and rgn) and df.global.world.world_data.regions[rgn.region_id] or nil
    local life = site_life(site)
    local d = {
        id = site.id,
        name = dfhack.translation.translateName(site.name, true),
        kind = df.world_site_type[site.type],
        region = wr and dfhack.translation.translateName(wr.name, true) or nil,
        region_kind = wr and df.world_region_type[wr.type] or nil,
        biome = (ok and rgn) and df.biome_type[dfhack.maps.getBiomeType(site.pos.x, site.pos.y)] or nil,
        stone = site_stone(site),
        game = life.game, savage_game = life.savage_game, giant_game = life.giant_game,
        trees = life.trees, plants = life.plants, exact = life.exact,
        savagery = site_savagery(site),
        libraries = site_libraries(site),
        books = site_books(site),
        ours = is_ours(site),
    }
    cache.id, cache.data = site.id, d
    return d
end

-- ---------------------------------------------------------------------------
-- the march: getting a squad to the edge of the map
-- ---------------------------------------------------------------------------
--
-- A STATION ORDER, the same one `fort/dwarf-rts` issues when you click the map with a squad
-- selected -- `squad_order_movest` on the squad, `issuer_hf` set to the LEADER, `point_id` -1,
-- with every member's individual orders cleared first so nobody is left following an older one.
--
-- A one-point PATROL was tried first and DF ignored it outright: the squad showed no order at
-- all. Two reasons, both visible in dwarf-rts, which does patrols successfully -- it sets a
-- real `issuer_hf` rather than -1, and it never builds a patrol of fewer than TWO points
-- ("station + clicked tile = a 2-point patrol"). One waypoint is not a route to walk. A
-- station is what "go there and stand" actually is, and the route object bought nothing that
-- the order itself does not.

local MARCH_KEY = 'economic-expeditions/march'
local MARCH_CHECK_TICKS = 100
local ARRIVE_RADIUS = 3      -- how close counts as "at the edge"; they will not all fit on one tile

-- THE NEAREST MAP EDGE THE SQUAD CAN ACTUALLY REACH. A pure straight-line pick sends them at
-- whatever edge is fewest tiles away as the crow flies, which is the wrong edge when terrain
-- or the shape of the fort is in the way. DFHack exposes no path LENGTH -- only
-- `canWalkBetween` (a yes/no, but a REAL DF pathfind) and `getWalkableGroup`.
--
-- A breadth-first search of our own was tried and abandoned. It is correct -- BFS visits in
-- distance order, so the first edge tile found is genuinely the nearest -- but unaffordable:
-- measured on this fort (288x288, 312 z-levels), a citizen standing outdoors near an edge
-- resolved in 23ms, while the DEEPEST citizen burned 272ms and gave up without reaching the
-- surface at all, and the highest exhausted its reachable set in 46ms having found no outdoor
-- edge tile. Most squads are inside the fort, so giving up was the common case, and half a
-- second of held main thread is too much to pay for an answer that then fell back anyway.
--
-- So: rank the edge tiles by distance and ask DF's own pathfinder, nearest first, until one
-- says yes. That is nearest-reachable rather than nearest-by-path -- a nearer edge whose route
-- happens to wind can still be chosen over a further one with a straight road -- but it is
-- honest about reachability, which is what was actually going wrong, and it costs a couple of
-- pathfind calls instead of a hundred thousand tile reads.
--
-- Distance is CHEBYSHEV: DF walks a diagonal in one step, so the eight neighbours cost alike.
local MAX_PATH_TESTS = 40     -- give up rather than pathfind to every tile on the perimeter

-- an edge tile is only a place to leave from if it is open to the sky and unbuilt
local function usable_edge(pos)
    local fl, occ = dfhack.maps.getTileFlags(pos)
    return fl and fl.outside and not fl.hidden
        and occ and occ.building == df.tile_building_occ.None
end

-- Outdoor perimeter tiles in the unit's walkable group, nearest first.
--
-- The columns are RANKED BEFORE they are probed, and probing stops once enough near ones have
-- been found. Finding the surface in a column means walking z downward until the first floor,
-- and this map is 312 levels deep over a 1148-column perimeter -- scanning all of them cost
-- ~200ms, nearly all of it spent on the far side of the map for candidates that were never
-- going to win. Sorting first and stopping early looks at a few dozen columns instead.
local function edge_candidates(unit, want)
    local W = df.global.world.map
    local ok, mygroup = pcall(dfhack.maps.getWalkableGroup, unit.pos)
    if not ok or mygroup == 0 then return {} end
    local xmax, ymax = W.x_count - 1, W.y_count - 1

    local cols = {}
    local function add_col(x, y)
        cols[#cols + 1] = {x = x, y = y,
            d = math.max(math.abs(x - unit.pos.x), math.abs(y - unit.pos.y))}
    end
    for y = 1, ymax - 1 do add_col(0, y); add_col(xmax, y) end
    for x = 1, xmax - 1 do add_col(x, 0); add_col(x, ymax) end
    table.sort(cols, function(a, b) return a.d < b.d end)

    local out = {}
    for _, c in ipairs(cols) do
        for z = W.z_count - 1, 1, -1 do
            local pos = xyz2pos(c.x, c.y, z)
            local tt = dfhack.maps.getTileType(pos)
            if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.FLOOR then
                if usable_edge(pos) then
                    local ok2, wg = pcall(dfhack.maps.getWalkableGroup, pos)
                    if ok2 and wg ~= 0 and wg == mygroup then
                        out[#out + 1] = {pos = pos, d = c.d}
                    end
                end
                break                      -- topmost floor in the column is the surface
            end
        end
        if #out >= (want or MAX_PATH_TESTS) then break end
    end
    return out
end

function edge_tile(unit)
    local t0 = os.clock()
    local cands = edge_candidates(unit, MAX_PATH_TESTS)
    if #cands == 0 then return nil, 'no outdoor map-edge tile in the squad\'s walkable group' end
    local tested = 0
    for _, c in ipairs(cands) do
        tested = tested + 1
        if tested > MAX_PATH_TESTS then break end
        local ok, reachable = pcall(dfhack.maps.canWalkBetween, unit.pos, c.pos)
        if ok and reachable then
            return c.pos, ('%d tiles off, confirmed reachable on try %d, %.0f ms'):format(
                c.d, tested, (os.clock() - t0) * 1000)
        end
    end
    -- nothing confirmed: take the nearest anyway rather than refuse the expedition
    return cands[1].pos, ('no route confirmed in %d tries, taking the nearest (%.0f ms)'):format(
        tested, (os.clock() - t0) * 1000)
end


-- the leader's histfig, which is who DF records as having given the order
local function leader_hf(sq)
    for i = 0, #sq.positions - 1 do
        local occ = sq.positions[i].occupant
        if occ ~= -1 then return occ end
    end
    return -1
end

local function clear_squad_orders(sq)
    for i = #sq.orders - 1, 0, -1 do sq.orders:erase(i) end
    -- a squad-wide order drops any individual member orders, or a member keeps walking an
    -- older one of their own
    for p = 0, #sq.positions - 1 do
        local po = sq.positions[p].orders
        for i = #po - 1, 0, -1 do po:erase(i) end
    end
end

-- A SECOND EDGE TILE beside the first, so the patrol has two points to walk between. DF
-- ignores a one-point route -- `dwarf-rts`, which does patrols successfully, always builds
-- them from a station plus one more tile. Adjacent tiles on the same edge keep the squad
-- pacing on the boundary rather than wandering inland.
local function neighbour_edge_tile(tile)
    local W = df.global.world.map
    local ok, want = pcall(dfhack.maps.getWalkableGroup, xyz2pos(tile.x, tile.y, tile.z))
    if not ok then return nil end
    local on_vertical = (tile.x == 0 or tile.x == W.x_count - 1)
    for _, d in ipairs{1, -1, 2, -2, 3, -3} do
        local nx = on_vertical and tile.x or (tile.x + d)
        local ny = on_vertical and (tile.y + d) or tile.y
        if nx >= 0 and nx < W.x_count and ny >= 0 and ny < W.y_count then
            local pos = xyz2pos(nx, ny, tile.z)
            local tt = dfhack.maps.getTileType(pos)
            if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.FLOOR then
                local ok2, wg = pcall(dfhack.maps.getWalkableGroup, pos)
                if ok2 and wg ~= 0 and wg == want then return pos end
            end
        end
    end
end

-- the two-point route the squad paces, and the patrol order on it
local function order_patrol_edge(sq, tile)
    local second = neighbour_edge_tile(tile)
    if not second then return nil, 'no second walkable tile on that edge to patrol between' end
    local wp = df.global.plotinfo.waypoints
    if wp.in_edit_waypts_mode or wp.in_edit_name_mode then
        return nil, 'close the Routes screen first'
    end

    local function new_point(pos)
        local pt = df.pointst:new()
        pt.id = wp.next_point_id
        wp.next_point_id = wp.next_point_id + 1
        pt.pos.x, pt.pos.y, pt.pos.z = pos.x, pos.y, pos.z
        pt.tile, pt.fg_color, pt.bg_color = 88, COLOR_GREY, COLOR_BLACK
        wp.points:insert('#', pt)
        return pt.id
    end

    local rt = df.routest:new()
    rt.id = wp.next_route_id
    wp.next_route_id = wp.next_route_id + 1
    rt.name = 'Expedition'
    rt.points:insert('#', new_point(tile))
    rt.points:insert('#', new_point(second))
    wp.routes:insert('#', rt)

    local o = df.squad_order_patrol_routest:new()
    o.issuer_hf, o.recipient_hf = leader_hf(sq), -1
    o.year, o.year_tick = df.global.cur_year, df.global.cur_year_tick
    o.route_id = rt.id
    sq.orders:insert('#', o)
    return rt
end

local function order_station(sq, tile)
    local mo = df.squad_order_movest:new()
    mo.issuer_hf = leader_hf(sq)
    mo.recipient_hf = -1
    mo.year, mo.year_tick = df.global.cur_year, df.global.cur_year_tick
    mo.pos.x, mo.pos.y, mo.pos.z = tile.x, tile.y, tile.z
    mo.point_id = -1
    sq.orders:insert('#', mo)
end

-- still carrying the order we gave? Either the patrol on our route, or the station fallback.
local function carrying_order(sq, tile, route_id)
    for _, o in ipairs(sq.orders) do
        if route_id and df.squad_order_patrol_routest:is_instance(o) and o.route_id == route_id then
            return true
        end
        if df.squad_order_movest:is_instance(o)
            and o.pos.x == tile.x and o.pos.y == tile.y and o.pos.z == tile.z then
            return true
        end
    end
    return false
end

-- TRAVEL TIME, fitted to what DF's own world map reports. DF counts a diagonal step as one
-- step, so the distance that matters is CHEBYSHEV -- max(|dx|, |dy|) -- not the straight line.
-- Over 9 that reproduces every figure the game shows, exactly:
--
--     Cloakgales 27 -> 3      Glistenedpolished 37 -> 4
--     Furnacehailed 56 -> 6   Guttersculpt 183 -> 20
--
-- and the verbal bands with it: 2 tiles reads as a short trip (0.22), 4 as half a day (0.44),
-- 7 as nearly a day (0.78), 8 as a day (0.89), 10 as more than a day (1.11), and 18 as
-- exactly two days (2.00). Euclidean over 9.2 fits almost as well but misses the clean
-- integers -- Cloakgales is the tell, 27/9 = 3.00 against 29.5/9.2 = 3.21.
local TILES_PER_DAY = 9
local WORK_DAYS = 7          -- a week on site, whatever the trade
local TICKS_PER_DAY = 1200

function travel_days(site)
    local home = df.world_site.find(df.global.plotinfo.site_id)
    if not (home and site) then return 0 end
    local dx = math.abs(site.pos.x - home.pos.x)
    local dy = math.abs(site.pos.y - home.pos.y)
    return math.floor(math.max(dx, dy) / TILES_PER_DAY + 0.5)
end

-- a week of work plus the road, both ways: 7 days to Burnedroofs, 47 to the far side of the world
function expedition_days(site)
    return WORK_DAYS + 2 * travel_days(site)
end

-- ---------------------------------------------------------------------------
-- the march, driven
-- ---------------------------------------------------------------------------

-- No march is `nil`, not an empty table: saving `{}` reads back TRUTHY, so cancelling used to
-- leave a state object that answered "an expedition is already under way" forever.
local function march_state()
    local st = dfhack.persistent.getSiteData(MARCH_KEY, nil)
    if not st or not st.squad_id then return nil end
    return st
end

local function save_march(st)
    if st then
        dfhack.persistent.saveSiteData(MARCH_KEY, st)
    else
        pcall(dfhack.persistent.deleteSiteData, MARCH_KEY)
        dfhack.persistent.saveSiteData(MARCH_KEY, {})
    end
end

-- is this squad out on an expedition? `fort/dwarf-rts` asks, so that standing every squad down
-- when the squads screen closes does not quietly cancel a march already under way.
function squad_on_expedition(squad_id)
    local st = march_state()
    return st ~= nil and st.squad_id == squad_id
end

-- THE GENERIC GUARD. Any tool that stands squads down en masse -- `fort/dwarf-rts` does it
-- when the squads screen closes -- can ask this table whether a squad is busy with something
-- that its orders ARE, rather than knowing about expeditions specifically. A guard is a
-- function taking a squad id; any one returning true protects that squad's orders.
dfhack.internal.squad_order_guards = dfhack.internal.squad_order_guards or {}
dfhack.internal.squad_order_guards['economic-expeditions'] = function(squad_id)
    return squad_on_expedition(squad_id)
end

function march_status()
    local st = march_state()
    if not st or not st.squad_id then return nil end
    local sq = df.squad.find(st.squad_id)
    local site = df.world_site.find(st.site_id)
    return {
        squad = sq, site = site, phase = st.phase,
        name = sq and dfhack.military.getSquadName(sq.id) or ('squad ' .. st.squad_id),
        site_name = site and dfhack.translation.translateName(site.name, true) or '?',
        kind = st.kind, choice = st.choice, days = st.days,
        tile = st.tile, arrived = st.arrived,
    }
end

-- how many of the squad are standing at (or near) the edge tile
local function at_edge(sq, tile)
    local there, total = 0, 0
    for _, u in ipairs(squad_members(sq)) do
        total = total + 1
        if math.abs(u.pos.x - tile.x) <= ARRIVE_RADIUS
            and math.abs(u.pos.y - tile.y) <= ARRIVE_RADIUS
            and u.pos.z == tile.z then
            there = there + 1
        end
    end
    return there, total
end

local function stop_march_driver()
    require('repeat-util').cancel(MARCH_KEY)
end

local function march_tick()
    local st = march_state()
    if not st or not st.squad_id then stop_march_driver() return end
    local sq = df.squad.find(st.squad_id)
    if not sq then cancel_march('the squad is gone') return end

    -- CANCELLING THE ORDER IS HOW YOU CANCEL THE EXPEDITION. If the squad is no longer
    -- carrying its patrol order, the player took it off them -- by standing the squad down, by
    -- giving them something else to do, or by deleting the order outright -- and that is a
    -- perfectly good way to say "never mind". Re-issuing it would make the march impossible to
    -- call off by hand, which is worse than losing a march to a stray stand-down.
    if not carrying_order(sq, st.tile, st.route_id) then
        cancel_march('the squad was given other orders')
        return
    end

    local there, total = at_edge(sq, st.tile)
    if st.phase == 'marching' and total > 0 and there >= total then
        st.phase, st.arrived = 'ready', true
        save_march(st)
        dfhack.gui.showAnnouncement(
            ('%s has reached the edge of the map, ready to leave for %s (%d days).'):format(
                dfhack.military.getSquadName(sq.id),
                (df.world_site.find(st.site_id) and
                 dfhack.translation.translateName(df.world_site.find(st.site_id).name, true))
                    or 'the expedition', st.days or 0),
            COLOR_LIGHTGREEN)
    end
end

local function start_march_driver()
    require('repeat-util').scheduleEvery(MARCH_KEY, MARCH_CHECK_TICKS, 'ticks', march_tick)
end

-- Send a squad to the map edge. Nothing leaves yet -- this is the walk, and the notification
-- when they get there.
function begin_march(squad, site, kind, choice)
    if not (squad and site) then return false, 'need a squad and a site' end
    if march_state() then return false, 'an expedition is already under way' end
    local members = squad_members(squad)
    if #members == 0 then return false, 'that squad has no living members' end

    local tile, how = edge_tile(members[1])
    if not tile then return false, 'no walkable map-edge tile the squad can reach' end
    clear_squad_orders(squad)
    -- a patrol between two edge tiles, or a plain station if the edge has no second tile
    local route, why = order_patrol_edge(squad, tile)
    if not route then order_station(squad, tile) end

    save_march{
        squad_id = squad.id, site_id = site.id, kind = kind, choice = choice,
        route_id = route and route.id or nil, phase = 'marching',
        tile = {x = tile.x, y = tile.y, z = tile.z},
        days = expedition_days(site),
    }
    start_march_driver()
    if how then print('economic-expeditions: edge tile ' .. how) end
    dfhack.gui.showAnnouncement(
        ('%s is marching to the edge of the map, bound for %s.'):format(
            dfhack.military.getSquadName(squad.id),
            dfhack.translation.translateName(site.name, true)), COLOR_WHITE)
    return true
end

function cancel_march(why)
    local st = march_state()
    if not st or not st.squad_id then return false end
    local sq = df.squad.find(st.squad_id)
    if sq then clear_squad_orders(sq) end
    save_march(nil)
    stop_march_driver()
    dfhack.gui.showAnnouncement(('The expedition is called off%s.'):format(
        why and (' -- ' .. why) or ''), COLOR_YELLOW)
    return true
end

dfhack.onStateChange[MARCH_KEY] = function(sc)
    if sc == SC_MAP_LOADED and dfhack.world.isFortressMode() then
        if march_state() then start_march_driver() end
    end
end

-- ---------------------------------------------------------------------------
-- what the fort already has
-- ---------------------------------------------------------------------------
--
-- Everything the survey lists is drawn RED when the fort has no source of it -- the point of
-- an expedition is to fetch what you cannot get at home, and a list that does not say which is
-- which makes you go and check four screens before deciding.
--
-- "Already have it" means a different thing for each:
--
--   STONE    it is in YOUR OWN geology, so you could mine it out of a wall. Read from the
--            fort's geo layers, not from a map sweep -- scanning tiles for stone types is the
--            kind of whole-map scan that locks the game up.
--   TREES    it grows on your own tiles, from the same local populations the survey uses.
--   PLANTS   you hold SEEDS of it. A plant you cannot plant is one you have to go and pick.
--   ANIMALS  you have a breeding pair: a live tame male who would breed with a female and a
--            live tame female who would breed with a male. DF tracks orientation on animals
--            too (`soul.orientation_flags`), and a pair that will not breed is not a herd --
--            which is exactly the case where you would send a hunting party for another.
local holdings_cache = {frame = -1, data = nil}

local function fort_stone_set()
    local out = {}
    local home = df.world_site.find(df.global.plotinfo.site_id)
    if not home then return out end
    for _, t in ipairs(site_tiles(home)) do
        local ok, rgn = pcall(dfhack.maps.getRegionBiome, t.x, t.y)
        if ok and rgn then
            local gb = df.global.world.world_data.geo_biomes[rgn.geo_index]
            for i = 0, (gb and #gb.layers or 0) - 1 do
                local L = gb.layers[i]
                local nm = inorganic_name(L.mat_index)
                if nm then out[nm] = true end
                for j = 0, #L.vein_mat - 1 do
                    local vn = inorganic_name(L.vein_mat[j])
                    if vn then out[vn] = true end
                end
            end
        end
    end
    return out
end

local function fort_tree_set()
    local out = {}
    local home = df.world_site.find(df.global.plotinfo.site_id)
    if not home then return out end
    local want = {}
    for _, t in ipairs(site_tiles(home)) do want[t.x .. ',' .. t.y] = true end
    for _, lp in ipairs(df.global.world.populations.all) do
        local r = lp.population
        if r.layer_depth == -1 and r.cave_id == -1 and r.feature_idx == -1
            and want[r.region_x .. ',' .. r.region_y]
            and df.world_population_type[lp.type] == 'Tree'
        then
            local nm = plant_name(lp.plant)
            if nm then out[nm] = true end
        end
    end
    return out
end

local function fort_seed_set()
    local out = {}
    for _, it in ipairs(df.global.world.items.other.SEEDS) do
        if not (it.flags.dump or it.flags.garbage_collect or it.flags.removed) then
            local pr = df.global.world.raws.plants.all[it.mat_index]
            if pr then out[(pr.name ~= '' and pr.name) or pr.id] = true end
        end
    end
    return out
end

-- a male who would breed with a female, or the other way round
local function breeds_with_other_sex(u)
    local soul = u.status and u.status.current_soul
    if not soul then return false end
    local ok, f = pcall(function() return soul.orientation_flags end)
    if not ok or not f then return true end        -- no orientation recorded: assume it breeds
    if u.sex == 1 then return f.marry_female or f.romance_female end   -- male
    if u.sex == 0 then return f.marry_male or f.romance_male end       -- female
    return false
end

local function fort_breeding_set()
    local male, female = {}, {}
    for _, u in ipairs(df.global.world.units.active) do
        if not dfhack.units.isDead(u) and dfhack.units.isTame(u) and breeds_with_other_sex(u) then
            local cr = df.global.world.raws.creatures.all[u.race]
            local nm = cr and ((cr.name[0] ~= '' and cr.name[0]) or cr.creature_id)
            if nm then
                if u.sex == 1 then male[nm] = true elseif u.sex == 0 then female[nm] = true end
            end
        end
    end
    local out = {}
    for nm in pairs(male) do if female[nm] then out[nm] = true end end
    return out
end

-- Recomputed at most once a frame: four fort-wide sweeps behind a panel that redraws sixty
-- times a second would be four sweeps a frame.
function fort_holdings()
    local frame = df.global.world.frame_counter
    if holdings_cache.frame == frame and holdings_cache.data then return holdings_cache.data end
    local d = {
        stone = fort_stone_set(),
        trees = fort_tree_set(),
        plants = fort_seed_set(),
        animals = fort_breeding_set(),
    }
    holdings_cache.frame, holdings_cache.data = frame, d
    return d
end

-- ---------------------------------------------------------------------------
-- expeditions: what a squad brings home
-- ---------------------------------------------------------------------------
--
-- ONE CHANCE PER LEVEL OF THE RELEVANT SKILL, per dwarf. A squad's haul is the sum over its
-- members, so a legendary miner is worth twenty attempts and a novice one. Expeditions grant
-- NO experience -- they spend skill rather than build it, which is what keeps them from being
-- the best training in the game.
--
-- The four trades and what a level buys:
--
--   MINING       TWO choices: a layer stone to quarry and a vein/cluster to dig for. A level
--                buys 1/5 of a layer stone, and 1/10, 1/20, 1/100 or 1/500 of the target
--                depending on how the geology buried it.
--   WOODCUTTING  1/5 of a log. Forty logs for a full squad of legendaries, which you would not
--                usually have.
--   HERBALISM    a 10% chance at the chosen plant. 120% is one guaranteed and a 20% chance of
--                a second, which is how every fractional rate here is read.
--   SNEAK        a 10% chance at a corpse and a 1% chance at a live one in a cage.
--
-- A MINER BRINGS HOME BOTH, and there is no failure roll any more: the layer stone is the
-- quarry work that always pays, and the vein or cluster is what they were actually after. At
-- 150 squad levels that is 30 layer stones plus 15 of a vein, or 8 of a cluster, or 1 or 2 of
-- a small cluster.
--
-- SINGLE GEMS (`CLUSTER_ONE`, the diamonds) are an extrapolation at 1/500 and NOT part of the
-- agreed rates -- the ramp had to continue somewhere, and leaving a whole tier unfetchable
-- seemed worse than guessing. No geology reachable from this fort has one to test against.
local MINING_YIELD = {
    layer         = 1/5,
    VEIN          = 1/10,
    CLUSTER       = 1/20,
    CLUSTER_SMALL = 1/100,
    CLUSTER_ONE   = 1/500,
}
local LOG_YIELD = 1/5

-- Hunting rates by tier, {corpse%, caged%} per level of Ambusher. Giants are five times
-- harder; ordinary game in a savage place is twice as hard. The two do NOT stack -- a giant is
-- already the hard tier and is not doubled again for standing where giants stand.
local HUNT_RATE = {
    game        = {10, 1},
    savage_game = {5, 0.5},
    giant_game  = {2, 0.2},
}

EXPEDITIONS = {
    mining  = {label = 'mining',  skill = df.job_skill.MINING,      picks = 'stone'},
    logging = {label = 'logging', skill = df.job_skill.WOODCUTTING, picks = 'trees'},
    botany  = {label = 'botany',  skill = df.job_skill.HERBALISM,   picks = 'plants'},
    hunting = {label = 'hunting', skill = df.job_skill.SNEAK,       picks = 'game'},
}

-- A rate in percent becomes a whole number of results plus one roll for the remainder, so 120%
-- is "one for certain, and a one-in-five chance of another" rather than a coin flip.
local function rate_to_count(percent, roll)
    local whole = math.floor(percent / 100)
    local rest = percent - whole * 100
    if rest > 0 and roll() * 100 < rest then whole = whole + 1 end
    return whole
end

-- every level of `skill` across the squad, which is the number of attempts
function squad_skill(units, skill)
    local total = 0
    for _, u in ipairs(units) do
        local ok, lvl = pcall(dfhack.units.getNominalSkill, u, skill, true)
        if ok and lvl and lvl > 0 then total = total + lvl end
    end
    return total
end

-- which rarity tier a stone name sits in, for this site
local function stone_tier(d, name)
    for tier, list in pairs(d.stone) do
        for _, n in ipairs(list) do if n == name then return tier end end
    end
end

local function hunt_tier(d, name)
    for _, tier in ipairs{'game', 'savage_game', 'giant_game'} do
        for _, n in ipairs(d[tier]) do if n == name then return tier end end
    end
end

-- WHAT THE SQUAD COMES HOME WITH. Pure: it reads the survey and the squad's skills and returns
-- a tally, touching nothing. `roll` is injectable so the odds can be tested without a game.
--
-- Returns a LIST of {name, kind, count}, and the number of attempts, so the caller can say
-- "160 attempts, 38 came back with something".
--
-- KEYED BY NAME **AND** KIND. Keying by name alone silently merged a hunt's corpses and its
-- caged animals into one pile under whichever arrived first -- 3 wild boar corpses and a cage
-- came back as "3.31 corpses", with the cages invisible. Two different things can share a
-- name, and a boar in a cage is not a dead boar.
function resolve_expedition(kind, choice, units, d, roll)
    roll = roll or math.random
    local spec = EXPEDITIONS[kind]
    if not spec then return nil, 'no such expedition: ' .. tostring(kind) end
    local attempts = squad_skill(units, spec.skill)
    local haul, index = {}, {}
    local function add(name, k, n)
        if not name or n <= 0 then return end
        local key = k .. '\0' .. name
        local row = index[key]
        if not row then
            row = {name = name, kind = k, count = 0}
            index[key] = row
            haul[#haul + 1] = row
        end
        row.count = row.count + n
    end

    if kind == 'mining' then
        -- two picks: what to quarry, and what to dig for. Either may be left out.
        local layer = type(choice) == 'table' and choice.layer or choice
        local target = type(choice) == 'table' and choice.target or nil
        if layer then
            if stone_tier(d, layer) ~= 'layer' then
                return nil, ('%s is not a layer stone at this site'):format(tostring(layer))
            end
            add(layer, 'stone', rate_to_count(MINING_YIELD.layer * 100 * attempts, roll))
        end
        if target then
            local tier = stone_tier(d, target)
            if not tier then
                return nil, ('%s is not in this site\'s stone'):format(tostring(target))
            end
            if tier == 'layer' then
                return nil, ('%s is a layer stone -- pick it as the quarry, not the target')
                    :format(tostring(target))
            end
            add(target, 'stone', rate_to_count((MINING_YIELD[tier] or 0) * 100 * attempts, roll))
        end
        if not layer and not target then return nil, 'pick a layer stone, a target, or both' end

    elseif kind == 'logging' then
        add(choice, 'log', rate_to_count(LOG_YIELD * 100 * attempts, roll))

    elseif kind == 'botany' then
        for _, u in ipairs(units) do
            local lvl = squad_skill({u}, spec.skill)
            add(choice, 'plant', rate_to_count(10 * lvl, roll))
        end

    elseif kind == 'hunting' then
        local tier = hunt_tier(d, choice)
        if not tier then return nil, ('%s is not game at this site'):format(tostring(choice)) end
        local corpse_rate, cage_rate = HUNT_RATE[tier][1], HUNT_RATE[tier][2]
        for _, u in ipairs(units) do
            local lvl = squad_skill({u}, spec.skill)
            add(choice, 'corpse', rate_to_count(corpse_rate * lvl, roll))
            add(choice, 'cage', rate_to_count(cage_rate * lvl, roll))
        end
    end
    table.sort(haul, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)
    return haul, nil, attempts
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

-- The survey is drawn full width and is allowed to sit over DF's own right-edge buttons
-- ("Center on fort", "Missions", ...) -- by request: the reading is worth more than the
-- buttons while you are looking at a site, and they come back the moment the panel does not
-- draw. A filled background box is painted first so the text never interleaves with whatever
-- DF drew underneath it, which is what made "anteosaurus ort" out of two overlapping strings.
-- The survey is drawn full width and is allowed to sit over DF's own right-edge buttons
-- ("Center on fort", "Missions", ...) -- by request: the reading is worth more than the
-- buttons while you are looking at a site, and they come back the moment the panel does not
-- draw. A filled background box is painted first so the text never interleaves with whatever
-- DF drew underneath it, which is what made "anteosaurus ort" out of two overlapping strings.
local PANEL_W = 54
local INDENT = '  '
local BORDER_PAD = 4   -- columns of border+padding left of the text, to sit flush with DF's panel
local TEXT_W = PANEL_W

-- EVERY NAME IS SHOWN. There is no "and N more": a list you cannot read to the end is no use
-- for deciding where to send an expedition, and vertical space is what the layout spends
-- instead -- no counts, no section heading over the stone, and one blank row between groups.
-- Burnedroofs fills roughly forty of the fifty-odd rows below the Diplomacy button.
--
-- A row is a list of {text, pen} segments so a blue label and its grey names share one line.
local LABEL_PEN = COLOR_LIGHTBLUE
local VALUE_PEN = COLOR_GREY

-- RED MEANS THE FORT HAS NO SOURCE OF IT. Each name is its own segment so it can carry its own
-- pen, which means wrapping has to happen over the segments rather than over one joined string
-- -- the earlier version built the whole line as text and could only colour it all at once.
local MISSING_PEN = COLOR_LIGHTRED

local function labelled(rows, label, list, empty_text, have)
    local head = label .. ':  '
    if #list == 0 then
        rows[#rows + 1] = {{text = head, pen = LABEL_PEN},
                           {text = empty_text or 'none', pen = VALUE_PEN}}
        return
    end

    local first_width = math.max(8, TEXT_W - #head)
    local rest_width = math.max(8, TEXT_W - #INDENT)
    local wrapped, cur, used, width = {}, {}, 0, first_width
    for i, name in ipairs(list) do
        local piece = name .. (i < #list and ', ' or '')
        if used > 0 and used + #piece > width then
            wrapped[#wrapped + 1] = cur
            cur, used, width = {}, 0, rest_width
        end
        cur[#cur + 1] = {text = piece,
                         pen = (have and not have[name]) and MISSING_PEN or VALUE_PEN}
        used = used + #piece
    end
    if #cur > 0 then wrapped[#wrapped + 1] = cur end

    for i, segs in ipairs(wrapped) do
        local row = {i == 1 and {text = head, pen = LABEL_PEN}
                             or {text = INDENT, pen = VALUE_PEN}}
        for _, seg in ipairs(segs) do row[#row + 1] = seg end
        rows[#rows + 1] = row
    end
end

-- A section's send button, drawn on its own row at the foot of the section. Rows carrying a
-- `button` field are recorded with their screen rect when painted, so a click can be read back
-- to the expedition it belongs to.
local BUTTON_PEN = COLOR_LIGHTGREEN
local function button_row(rows, kind, enabled)
    if not enabled then return end
    rows[#rows + 1] = {
        {text = INDENT, pen = VALUE_PEN},
        {text = '[Send Expedition]', pen = BUTTON_PEN},
        button = kind,
    }
end

local function survey_lines(d)
    local rows = {}
    local have = fort_holdings()
    if d.region then
        rows[#rows + 1] = {{text = ('%s -- %s'):format(d.region, tostring(d.region_kind)),
                            pen = COLOR_WHITE}}
        -- say so when the living things are a regional estimate rather than the site's own
        -- roster: DF only generates local populations near the loaded embark
        if not d.exact then
            rows[#rows + 1] = {{text = 'living things estimated from the region',
                                pen = COLOR_BROWN}}
        end
        rows[#rows + 1] = {}
    end
    -- the stone tiers run together as one block: they are all the same question
    local any_stone = false
    for _, tier in ipairs(RARITY_ORDER) do
        local list = d.stone[tier]
        if list and #list > 0 then
            labelled(rows, RARITY_LABEL[tier], list, nil, have.stone)
            any_stone = true
        end
    end
    if not any_stone then labelled(rows, 'Stone', {}, 'nothing recorded for this tile') end
    button_row(rows, 'mining', d.ours and any_stone)

    rows[#rows + 1] = {}
    labelled(rows, 'Trees', d.trees, 'none here', have.trees)
    button_row(rows, 'logging', d.ours and #d.trees > 0)
    rows[#rows + 1] = {}
    labelled(rows, 'Plants', d.plants, 'none here', have.plants)
    button_row(rows, 'botany', d.ours and #d.plants > 0)
    rows[#rows + 1] = {}
    -- three difficulty tiers, each named, so you can see what a squad is walking into before
    -- you send it. Empty tiers are simply not drawn; a calm site shows one "Game:" line.
    local shown_game = false
    if #d.game > 0 then
        labelled(rows, 'Game', d.game, nil, have.animals); shown_game = true end
    if #d.savage_game > 0 then
        labelled(rows, 'Savage game', d.savage_game, nil, have.animals); shown_game = true end
    if #d.giant_game > 0 then
        labelled(rows, 'Giant game', d.giant_game, nil, have.animals); shown_game = true end
    if not shown_game then labelled(rows, 'Game', {}, 'none here') end
    button_row(rows, 'hunting',
        d.ours and (#d.game + #d.savage_game + #d.giant_game) > 0)
    -- No library, no line: a site with no library has nothing to say here, and a row saying so
    -- on every one of them is noise. With a library, the named books it holds -- or the plain
    -- fact that none are known.
    if d.libraries > 0 then
        rows[#rows + 1] = {}
        labelled(rows, 'Library', d.books, 'No books known')
    end
    return rows
end

-- a row flattened to plain text, for the console
local function row_text(row)
    local t = {}
    for _, seg in ipairs(row) do t[#t + 1] = seg.text end
    return table.concat(t)
end

-- ---------------------------------------------------------------------------
-- the picker
-- ---------------------------------------------------------------------------
--
-- Two panels: the SQUAD on the left with the skill that matters to this trade, and the
-- TARGETS on the right, ONE PER LINE rather than the wrapped prose the survey uses -- a list
-- you are picking from wants to be a list, even though the same names read better wrapped
-- when you are only looking.
--
-- Mining is the one that takes two picks, so its right-hand panel carries two ticks: one in
-- the layer stones and one somewhere below. Everything else takes a single pick.

local TICK = string.char(251)          -- CP437 check mark, the same one butcher-shop uses

local function target_groups(kind, d)
    if kind == 'mining' then
        return {
            {'Layer stone',    d.stone.layer or {},         'layer'},
            {'Veins',          d.stone.VEIN or {},          'target'},
            {'Clusters',       d.stone.CLUSTER or {},       'target'},
            {'Small clusters', d.stone.CLUSTER_SMALL or {}, 'target'},
            {'Single gems',    d.stone.CLUSTER_ONE or {},   'target'},
        }
    elseif kind == 'logging' then return {{'Trees', d.trees, 'target'}}
    elseif kind == 'botany' then return {{'Plants', d.plants, 'target'}}
    elseif kind == 'hunting' then
        return {
            {'Game',        d.game,        'target'},
            {'Savage game', d.savage_game, 'target'},
            {'Giant game',  d.giant_game,  'target'},
        }
    end
    return {}
end

ExpeditionWindow = defclass(ExpeditionWindow, widgets.Window)
ExpeditionWindow.ATTRS{
    frame = {w = 74, h = 32},
    resizable = true,
    kind = DEFAULT_NIL,
    site = DEFAULT_NIL,
}

function ExpeditionWindow:init()
    -- AS TALL AS THE SCREEN ALLOWS. The target list can run to forty names -- every giant on a
    -- savage tile, every plant in a temperate region -- and a fixed height means scrolling
    -- through a list that would have fitted. Two rows of margin top and bottom so the window
    -- still reads as a window.
    local sw, sh = dfhack.screen.getWindowSize()
    self.frame = {w = math.min(80, math.max(60, sw - 8)), h = math.max(20, sh - 4)}

    local spec = EXPEDITIONS[self.kind]
    self.frame_title = ('Send a %s expedition'):format(spec.label)
    self.d = survey(self.site)
    self.groups = target_groups(self.kind, self.d)

    -- DEFAULTS: the first layer stone and the first vein, so a mining expedition is ready to
    -- send without touching anything.
    self.sel = {}
    for _, g in ipairs(self.groups) do
        local slot = g[3]
        if #g[2] > 0 and not self.sel[slot] then self.sel[slot] = g[2][1] end
    end

    self.squads = fort_squads()
    ACTIVE_PICKER = self          -- a handle, so the open picker can be driven from the console
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = 'Squad', text_pen = COLOR_LIGHTCYAN},
        widgets.List{
            view_id = 'squads',
            frame = {t = 1, l = 0, w = 32, b = 3},
            on_select = function() self:refresh_summary() end,
        },
        widgets.Label{frame = {t = 0, l = 34}, text = 'Bring back', text_pen = COLOR_LIGHTCYAN},
        widgets.List{
            view_id = 'targets',
            frame = {t = 1, l = 34, r = 0, b = 3},
            on_submit = function(idx, choice) self:pick(idx, choice) end,
        },
        widgets.Label{view_id = 'summary', frame = {b = 2, l = 0}, text = ''},
        widgets.HotkeyLabel{
            frame = {b = 0, l = 0}, key = 'CUSTOM_SHIFT_S',
            label = 'Send the expedition', on_activate = function() self:send() end,
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 30}, key = 'LEAVESCREEN',
            label = 'Cancel', on_activate = function() self.parent_view:dismiss() end,
        },
    }
    self:refresh()
end

function ExpeditionWindow:refresh()
    local spec = EXPEDITIONS[self.kind]
    local squad_choices = {}
    for _, sq in ipairs(self.squads) do
        local members = squad_members(sq)
        local lvl = squad_skill(members, spec.skill)
        squad_choices[#squad_choices + 1] = {
            text = {
                {text = ('%-22s'):format(
                    dfhack.translation.translateName(sq.name, true):sub(1, 22))},
                {text = (' %3d'):format(lvl),
                 pen = lvl > 0 and COLOR_LIGHTGREEN or COLOR_DARKGREY},
            },
            squad = sq, level = lvl, members = members,
        }
    end
    self.subviews.squads:setChoices(squad_choices, self.subviews.squads:getSelected())

    -- one name per line, with the group headings between them
    local rows = {}
    local holdings = fort_holdings()
    local have = ({mining = holdings.stone, logging = holdings.trees,
                   botany = holdings.plants, hunting = holdings.animals})[self.kind]
    for _, g in ipairs(self.groups) do
        local title, list, slot = g[1], g[2], g[3]
        if #list > 0 then
            if #rows > 0 then rows[#rows + 1] = {text = '', header = true} end
            rows[#rows + 1] = {text = {{text = title .. ':', pen = COLOR_LIGHTCYAN}},
                               header = true}
            for _, name in ipairs(list) do
                local on = self.sel[slot] == name
                -- same red as the survey: a name the fort has no source of
                local missing = have and not have[name]
                local pen = missing and COLOR_LIGHTRED or (on and COLOR_WHITE or COLOR_GREY)
                rows[#rows + 1] = {
                    text = {{text = on and (' ' .. TICK .. ' ') or '   ',
                             pen = COLOR_LIGHTGREEN},
                            {text = name, pen = pen}},
                    name = name, slot = slot,
                }
            end
        end
    end
    self.subviews.targets:setChoices(rows, self.subviews.targets:getSelected())
    self:refresh_summary()
end

function ExpeditionWindow:refresh_summary()
    local _, sq = self.subviews.squads:getSelected()
    local spec = EXPEDITIONS[self.kind]
    local picks = {}
    if self.sel.layer then picks[#picks + 1] = self.sel.layer end
    if self.sel.target then picks[#picks + 1] = self.sel.target end
    self.subviews.summary:setText{
        {text = ('%s, %s %d'):format(
            sq and dfhack.translation.translateName(sq.squad.name, true) or 'no squad',
            df.job_skill.attrs[spec.skill].caption or spec.label,
            sq and sq.level or 0), pen = COLOR_WHITE},
        NEWLINE,
        {text = 'for ' .. (#picks > 0 and table.concat(picks, ' + ') or 'nothing'),
         pen = COLOR_GREY},
    }
end

function ExpeditionWindow:pick(_, choice)
    if not choice or choice.header then return end       -- headings are not choices
    self.sel[choice.slot] = choice.name
    self:refresh()
end

function ExpeditionWindow:send()
    local _, sq = self.subviews.squads:getSelected()
    if not sq then return end
    local choice = self.sel.target
    if self.kind == 'mining' then choice = {layer = self.sel.layer, target = self.sel.target} end
    local haul, err, attempts = resolve_expedition(self.kind, choice, sq.members, self.d)
    if err then
        dfhack.printerr('economic-expeditions: ' .. err)
        return
    end
    -- THE DRY RUN, to the console. Nothing travels and nothing is created yet.
    print(('%s expedition to %s -- %s, %d dwarves, %d attempts'):format(
        EXPEDITIONS[self.kind].label, self.d.name,
        dfhack.translation.translateName(sq.squad.name, true), #sq.members, attempts))
    if #haul == 0 then print('  comes home with nothing') end
    for _, row in ipairs(haul) do
        print(('  %-6s %-26s x%d'):format(row.kind, row.name, row.count))
    end
    self.parent_view:dismiss()
end

ExpeditionScreen = defclass(ExpeditionScreen, gui.ZScreen)
-- kind and site MUST be declared: an ATTR a defclass does not declare arrives nil however it
-- was passed, and the window then builds against a nil expedition spec.
ExpeditionScreen.ATTRS{
    focus_path = 'economic-expeditions/send',
    kind = DEFAULT_NIL,
    site = DEFAULT_NIL,
}
function ExpeditionScreen:init()
    self:addviews{ExpeditionWindow{kind = self.kind, site = self.site}}
end
function ExpeditionScreen:onDismiss() ACTIVE_PICKER = nil end

function open_expedition(kind, site)
    if not (EXPEDITIONS[kind] and site) then return false end
    ExpeditionScreen{kind = kind, site = site}:show()
    return true
end

-- ---------------------------------------------------------------------------
-- overlay
-- ---------------------------------------------------------------------------

-- DF's site panel cannot be added to (a v50 widget_container behind a shared_ptr), so the
-- `Diplomacy` label is found by reading the screen and the survey is drawn under it. The
-- scrape is confined to the right-hand third and the top 30 rows -- the band the panel is
-- drawn in -- so it is a few hundred tile reads, not a whole-screen sweep.
local ANCHOR = 'Diplomacy'

local function anchor_pos()
    local sw, sh = dfhack.screen.getWindowSize()
    local x0 = math.floor(sw * 2 / 3)
    for y = 0, math.min(30, sh - 1) do
        local chars = {}
        for x = x0, sw - 1 do
            local ok, pen = pcall(dfhack.screen.readTile, x, y)
            local ch = (ok and pen and pen.ch) or 0
            chars[#chars + 1] = (ch >= 32 and ch < 127) and string.char(ch) or ' '
        end
        local c = table.concat(chars):find(ANCHOR, 1, true)
        if c then return x0 + c - 1, y end
    end
end

SurveyOverlay = defclass(SurveyOverlay, overlay.OverlayWidget)
SurveyOverlay.ATTRS{
    desc = 'economic-expeditions: what a world-map site is made of.',
    default_pos = {x = -2, y = -2},
    default_enabled = true,
    viewscreens = 'world',
    overlay_onupdate_max_freq_seconds = 0,
    frame = {w = PANEL_W, h = 1},
    version = 1,
}

local function focused_site()
    local scr = dfhack.gui.getCurViewscreen()
    if not df.viewscreen_worldst:is_instance(scr) then return nil end
    return scr.focus_site
end

function SurveyOverlay:overlay_onupdate()
    local site = focused_site()
    -- a new site starts at the top: carrying one site's scroll onto another leaves you looking
    -- at the middle of a list you have not seen the start of
    if site ~= self.site then self.scroll = 0 end
    self.site = site
end

-- How many rows the panel may use. FIVE ARE LEFT AT THE BOTTOM of the screen, so the panel
-- never runs into the very edge and there is somewhere for DF's own bottom row to live.
local BOTTOM_MARGIN = 5

function SurveyOverlay:visible_rows(top)
    local _, sh = dfhack.screen.getWindowSize()
    return math.max(1, (sh - BOTTOM_MARGIN) - top)
end

function SurveyOverlay:clamp_scroll(total, shown)
    local max = math.max(0, total - shown)
    self.scroll = math.max(0, math.min(self.scroll or 0, max))
    return self.scroll, max
end

-- Drawn by hand rather than through child widgets: the panel has to sit wherever DF put the
-- Diplomacy button THIS frame, and an overlay's frame is resolved before we know that.
function SurveyOverlay:onRenderBody(dc)
    local site = self.site or focused_site()
    if not site then return end
    local ax, ay = anchor_pos()
    if not ax then return end          -- label not drawn: say nothing rather than guess

    local d = survey(site)
    if not d then return end
    local all_lines = survey_lines(d)
    local sw, sh = dfhack.screen.getWindowSize()
    local top = ay + 3                 -- clear of the label and its one-line note
    local left = ax

    -- SCROLLING, because a site like Furnacehailed does not fit: the panel shows a window onto
    -- the survey and the wheel moves it, with five rows left free at the bottom of the screen.
    local shown = self:visible_rows(top)
    local scroll, max_scroll = self:clamp_scroll(#all_lines, shown)
    local lines = {}
    for i = scroll + 1, math.min(#all_lines, scroll + shown) do
        lines[#lines + 1] = all_lines[i]
    end
    self.scroll_max = max_scroll

    -- A PLAIN FILLED BOX, not `gui.paint_frame`. The native window frame was tried and its top
    -- border reads as jarring here -- this panel hangs off DF's own site panel rather than
    -- being a window of its own, and a hard rule across the top cuts it away from the
    -- Diplomacy button it belongs to. The box still extends BORDER_PAD columns left of the
    -- text so its edge sits flush with the native panel's.
    --
    -- Blanking is not decoration: DF drew its buttons under us, and two strings sharing a row
    -- read as gibberish ("anteosaurus ort" out of "anteosaurus man" and "Center on fort").
    local x1 = math.max(0, left - BORDER_PAD)
    local x2 = math.min(sw - 1, left + PANEL_W - 1)
    local y1 = math.max(0, top - 1)
    local y2 = math.min(sh - 1, top + #lines)
    local inner_w = math.max(0, x2 - left + 1)

    local blank = (' '):rep(math.max(0, x2 - x1 + 1))
    for y = y1, y2 do
        dfhack.screen.paintString({fg = COLOR_GREY, bg = COLOR_BLACK}, x1, y, blank)
    end

    -- the buttons' screen rects are remembered as they are painted, so a click can be read
    -- back to the section it landed in. They move with DF's panel, so this has to be per
    -- frame rather than worked out once.
    self.buttons = {}
    for i, row in ipairs(lines) do
        local y = top + i - 1
        if y > y2 then break end
        local x = 0
        for _, seg in ipairs(row) do
            if x >= inner_w then break end
            local text = seg.text:sub(1, inner_w - x)
            dfhack.screen.paintString({fg = seg.pen, bg = COLOR_BLACK}, left + x, y, text)
            if row.button and seg.pen == BUTTON_PEN then
                self.buttons[#self.buttons + 1] =
                    {kind = row.button, x1 = left + x, x2 = left + x + #text - 1, y = y}
            end
            x = x + #text
        end
    end

    -- say so when there is more to see, rather than just ending mid-list
    if max_scroll > 0 then
        local note = (scroll < max_scroll) and ' more below -- scroll ' or ' scroll up for more '
        local y = math.min(sh - 1, top + #lines)
        dfhack.screen.paintString({fg = COLOR_BROWN, bg = COLOR_BLACK}, left, y,
            note:sub(1, inner_w))
    end
    self.panel_rect = {x1 = x1, x2 = x2, y1 = y1, y2 = math.min(sh - 1, top + #lines)}
end

-- The panel is painted, not built from widgets, so the click has to be matched against the
-- rects recorded above. Returning true swallows it -- otherwise DF reads the same press as a
-- click on the world map underneath and scrolls somewhere.
function SurveyOverlay:onInput(keys)
    local mx, my = dfhack.screen.getMousePos()

    -- the wheel scrolls the survey, but only while the pointer is actually over it: the world
    -- map behind wants the wheel too, and stealing it everywhere would break zooming
    local step = (keys.CONTEXT_SCROLL_UP and -1) or (keys.CONTEXT_SCROLL_DOWN and 1)
        or (keys.CONTEXT_SCROLL_PAGEUP and -10) or (keys.CONTEXT_SCROLL_PAGEDOWN and 10)
    if step and mx then
        local r = self.panel_rect
        if r and mx >= r.x1 and mx <= r.x2 and my >= r.y1 and my <= r.y2 then
            self.scroll = math.max(0, math.min((self.scroll or 0) + step, self.scroll_max or 0))
            return true
        end
    end

    if not keys._MOUSE_L then return false end
    if not mx then return false end
    for _, b in ipairs(self.buttons or {}) do
        if my == b.y and mx >= b.x1 and mx <= b.x2 then
            local site = self.site or focused_site()
            if site then open_expedition(b.kind, site) end
            return true
        end
    end
    return false
end

OVERLAY_WIDGETS = {survey = SurveyOverlay}

-- The fort's squads, and the living members of one. A squad position holds a HISTFIG id, not
-- a unit id, so it takes two hops to reach the dwarf -- and an empty position or a dead member
-- resolves to nothing rather than a nil that blows up later.
function fort_squads()
    local out = {}
    for _, sq in ipairs(df.global.world.squads.all) do
        if sq.entity_id == df.global.plotinfo.group_id then out[#out + 1] = sq end
    end
    return out
end

function squad_members(squad)
    local out = {}
    for _, pos in ipairs(squad.positions) do
        if pos.occupant >= 0 then
            local hf = df.historical_figure.find(pos.occupant)
            local u = hf and df.unit.find(hf.unit_id)
            if u and not u.flags1.inactive then out[#out + 1] = u end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

local args = {...}

-- `plan <kind> <site id> <squad #> <what>` -- what this squad WOULD bring back, changing
-- nothing. The expedition itself does not exist yet; this is the arithmetic on its own.
if args[1] == 'plan' then
    local kind, sid, sqn = args[2], tonumber(args[3]), tonumber(args[4])
    local what = table.concat({select(5, table.unpack(args))}, ' ')
    -- mining takes two: "<layer stone> + <vein/cluster>", either side may be empty
    if kind == 'mining' then
        local a, b = what:match('^%s*(.-)%s*%+%s*(.-)%s*$')
        if a then what = {layer = a ~= '' and a or nil, target = b ~= '' and b or nil}
        else what = {layer = what} end
    end
    local site = sid and df.world_site.find(sid)
    if not (EXPEDITIONS[kind or ''] and site and sqn) then
        qerror('usage: economic-expeditions plan <mining|logging|botany|hunting> <site id> '
            .. '<squad #> <what>   (mining: "<layer stone> + <vein or cluster>")')
    end
    local squads = fort_squads()
    local squad = squads[sqn]
    if not squad then qerror(('no squad #%d (fort has %d)'):format(sqn, #squads)) end
    local units = squad_members(squad)
    local d = survey(site)
    local haul, err, attempts = resolve_expedition(kind, what, units, d)
    if err then qerror(err) end
    print(('%s expedition to %s -- %s, %d dwarves, %d attempts'):format(
        kind, d.name, dfhack.translation.translateName(squad.name, true), #units, attempts))
    if #haul == 0 then
        print('  comes home with nothing')
    else
        for _, row in ipairs(haul) do
            print(('  %-6s %-26s x%d'):format(row.kind, row.name, row.count))
        end
    end
    return
end

local site
if args[1] then
    site = df.world_site.find(tonumber(args[1]))
    if not site then qerror('economic-expeditions: no site with id ' .. tostring(args[1])) end
else
    site = focused_site()
    if not site then
        qerror('economic-expeditions: open the world map and click a site, or pass a site id')
    end
end

local d = survey(site)
print(('%s -- %s%s'):format(d.name, tostring(d.kind), d.ours and '  [economically linked]' or ''))
for _, row in ipairs(survey_lines(d)) do print(row_text(row)) end
