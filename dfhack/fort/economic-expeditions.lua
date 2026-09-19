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
                -- The artifact's name is the usual source, but one book in ninety-seven at
                -- Furnacehailed has a name that translates to nothing at all. The item carries
                -- its own `title`, so fall back to that before giving up and dropping it --
                -- a blank line in a list of sixty titles just looks like a rendering bug.
                local title = dfhack.translation.translateName(art.name, true)
                if title == '' then title = item.title or '' end
                if title ~= '' then out[#out + 1] = title end
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

-- THREE ANSWERS, not two. `site_hostile` collapses "at war" and "never heard of them" into
-- "not hostile", which is right for deciding whether to colour a marker red and wrong for
-- deciding whether scribes may visit: you cannot copy books from a library you have had no
-- contact with, and you cannot copy them from one whose owners are trying to kill you either,
-- but those are different problems with different fixes.
--
--   'war'      at war with the site government -- make peace first
--   'contact'  a diplomatic state exists and it is not war
--   nil        no state at all: never contacted
function site_contact(site)
    if not site then return nil end
    local me = df.historical_entity.find(df.global.plotinfo.civ_id)
    if not me then return nil end
    -- your own holdings and your own forts are always "contacted" -- they are yours, and no
    -- diplomacy state is ever recorded between you and yourself
    local standing = site_standing(site)
    if standing == 'own' or standing == 'controlled' or standing == 'civ' then return 'contact' end
    local gov
    for _, link in ipairs(site.entity_links) do
        local e = df.historical_entity.find(link.entity_id)
        if e and e.type == df.historical_entity_type.SiteGovernment then gov = e break end
    end
    if not gov then return nil end
    for _, st in ipairs(me.relations.diplomacy.state) do
        if st.group_id == gov.id then
            return st.relation == 1 and 'war' or 'contact'
        end
    end
    return nil
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
        contact = site_contact(site),
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
-- THE EDGE IS PICKED ONCE. It used to be re-chosen on every check as the squad moved -- a
-- dwarf who starts deep in the fort may surface nearer a different side than the one picked
-- at the door -- with a margin so they would not dither between two edges. In practice even
-- a single rewrite of the order mid-walk confused the squad: members already moving under the
-- old order stopped, milled, and re-formed on the new point, and a second rewrite did it
-- again. Nearest-reachable from where they stand when the order is given is good enough, and
-- an order that never changes is one a squad can actually follow.

-- defined further down, once the map-edge and haul machinery they need exists
local depart_arrivals, come_home

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

-- Tear the Expedition route back down. Without this every march leaves a route behind in the
-- player's Routes list -- three had piled up before I noticed -- and its points with it.
local function destroy_route(route_id)
    if not route_id then return end
    local wp = df.global.plotinfo.waypoints
    if wp.in_edit_waypts_mode or wp.in_edit_name_mode then return end
    for i = #wp.routes - 1, 0, -1 do
        local rt = wp.routes[i]
        if rt.id == route_id then
            local doomed = {}
            for _, pid in ipairs(rt.points) do doomed[pid] = true end
            for j = #wp.points - 1, 0, -1 do
                if doomed[wp.points[j].id] then
                    local pt = wp.points[j]
                    wp.points:erase(j)
                    pt:delete()
                end
            end
            wp.routes:erase(i)
            rt:delete()
            return
        end
    end
end

-- WHY THE FIRST MARCH LOOKED LIKE A MARCH INTO THE CAVERNS. The patrol order was live and DF
-- had even copied its destination onto the soldier's `idle_area` -- but her path goal was
-- `IndividualSkillDrill` and her destination the barracks, twenty-six z-levels DOWN. She was
-- going to drill, not to the caverns; every route point was on the surface the whole time.
--
-- I tried clearing the `train` bit on the squad's barracks to remove the competing errand, and
-- it is NOT a lever: DF put the bit back by itself, with nothing here restoring it, and the
-- squad reached the edge regardless. The drill is chosen upstream as an activity, so neither
-- the barracks flag nor a direct write to `path.goal`/`path.dest` -- both outputs, rewritten on
-- the unit's next decision -- suppresses it. The standing patrol order is the durable lever and
-- it wins on its own; a drill is only ever an interlude on the way.

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
local TICKS_PER_YEAR = TICKS_PER_DAY * 28 * 12   -- 403200

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

-- DF's calendar is twelve 28-day months, so a date that many days out is pure arithmetic.
-- DISPLAY ONLY -- the expedition's own clock is accumulated ticks, never this, because
-- `cur_year_tick` is not monotonic under timestream.
local MONTHS = {'Granite', 'Slate', 'Felsite', 'Hematite', 'Malachite', 'Galena',
                'Limestone', 'Sandstone', 'Timber', 'Moonstone', 'Opal', 'Obsidian'}
local DAYS_PER_MONTH, MONTHS_PER_YEAR = 28, 12

local function ordinal(n)
    local ones, teens = n % 10, n % 100
    if teens >= 11 and teens <= 13 then return n .. 'th' end
    return n .. (({'st', 'nd', 'rd'})[ones] or 'th')
end

function date_in(days)
    local day = math.floor(df.global.cur_year_tick / TICKS_PER_DAY) + days
    local per_year = DAYS_PER_MONTH * MONTHS_PER_YEAR
    local year = df.global.cur_year + math.floor(day / per_year)
    day = day % per_year
    local out = ('the %s of %s'):format(
        ordinal(day % DAYS_PER_MONTH + 1), MONTHS[math.floor(day / DAYS_PER_MONTH) + 1])
    if year ~= df.global.cur_year then out = out .. ', ' .. year end
    return out
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
        tile = st.tile,
        away = st.away and #st.away or 0,
        still_marching = sq and #squad_members(sq) or 0,
        days_left = st.phase == 'away'
            and math.max(0, (st.days or 0) - (st.ticks_away or 0) / TICKS_PER_DAY) or nil,
    }
end

-- standing at (or near) the edge tile, close enough to walk off it
local function at_edge(u, tile)
    return math.abs(u.pos.x - tile.x) <= ARRIVE_RADIUS
        and math.abs(u.pos.y - tile.y) <= ARRIVE_RADIUS
        and u.pos.z == tile.z
end

local function stop_march_driver()
    require('repeat-util').cancel(MARCH_KEY)
end

local function march_tick()
    local st = march_state()
    if not st or not st.squad_id then stop_march_driver() return end
    local sq = df.squad.find(st.squad_id)
    if not sq then cancel_march('the squad is gone') return end

    -- CANCELLING THE ORDER IS HOW YOU CANCEL THE EXPEDITION, but only while nobody has gone
    -- yet. If the squad is no longer carrying its patrol order the player took it off them --
    -- by standing the squad down, by giving them something else to do, or by deleting the
    -- order outright -- and that is a perfectly good way to say "never mind". Once somebody is
    -- off the map there is no recalling them by deleting an order.
    if st.phase == 'marching' and not carrying_order(sq, st.tile, st.route_id) then
        cancel_march('the squad was given other orders')
        return
    end

    -- NOBODY WAITS FOR THE SLOW ONES. Seven dwarves fetching their kit from across the fort
    -- arrive at the edge minutes apart, and holding the first six there until the seventh
    -- turns up is how an expedition sits looking broken for a week. Each one walks off the map
    -- the moment they reach it; the stragglers keep their order and join later.
    local left = depart_arrivals(st, sq)
    local site = df.world_site.find(st.site_id)
    local where = site and dfhack.translation.translateName(site.name, true) or 'the expedition'

    if #left > 0 and st.phase == 'marching' then
        -- THE CLOCK STARTS WITH THE FIRST ONE OUT, not with the last.
        st.phase, st.ticks_away = 'away', 0
        dfhack.gui.showAnnouncement(
            ('%s has set out for %s, expected back in %d days on %s%s.'):format(
                dfhack.military.getSquadName(sq.id), where, st.days or 0, date_in(st.days or 0),
                #squad_members(sq) > 0 and (', %d still making their way'):format(
                    #squad_members(sq)) or ''), COLOR_LIGHTCYAN)
    elseif #left > 0 then
        dfhack.gui.showAnnouncement(('%d more %s caught up with the expedition.'):format(
            #left, #left == 1 and 'has' or 'have'), COLOR_WHITE)
    end

    if st.phase == 'away' then
        -- once the last of them is gone the patrol has nothing left to walk
        if #squad_members(sq) == 0 and st.route_id then
            clear_squad_orders(sq)
            destroy_route(st.route_id)
            st.route_id = nil
        end
        -- DAYS ABROAD ARE CALENDAR DAYS. The announcement names a calendar date, and with
        -- `timestream` running the calendar moves several ticks per simulated tick on a slow
        -- fort -- so counting the driver's own interval (100 simulated ticks a check, as this
        -- first did) brought a "7 day" trip home a fortnight late by the calendar. So the
        -- calendar is read, with its two known faults handled rather than avoided: it wraps at
        -- the year end (a large negative step is the new year), and timestream can nudge it
        -- BACKWARDS by a little (a small negative step is jitter). The driver's interval stays
        -- as the floor, since the simulation did run that long whatever the calendar says, and
        -- one check never credits more than a generous cap, so a save reloaded from a week ago
        -- does not bring them home on the spot.
        local now = df.global.cur_year_tick
        local elapsed = MARCH_CHECK_TICKS
        if st.last_tick then
            local d = now - st.last_tick
            if d < -TICKS_PER_YEAR / 2 then d = d + TICKS_PER_YEAR end
            elapsed = math.max(MARCH_CHECK_TICKS, math.min(d, MARCH_CHECK_TICKS * 50))
        end
        st.last_tick = now
        st.ticks_away = (st.ticks_away or 0) + elapsed
        if st.ticks_away >= (st.days or 0) * TICKS_PER_DAY then
            come_home(st)
            return
        end
    end
    save_march(st)
end

local function start_march_driver()
    require('repeat-util').scheduleEvery(MARCH_KEY, MARCH_CHECK_TICKS, 'ticks', march_tick)
end

-- HOT-RELOAD HELPER. `repeat-util` holds the callback that registered it, so redeploying this
-- file leaves the PREVIOUS copy's `march_tick` driving the expedition -- new code on disk,
-- old code running, and no sign of it. Re-register so the driver is the one you just wrote.
function restart_march_driver()
    stop_march_driver()
    if march_state() then start_march_driver() return true end
    return false
end

-- Send a squad to the map edge. Nothing leaves yet -- this is the walk, and the notification
-- when they get there.
function begin_march(squad, site, kind, choice)
    if not (squad and site) then return false, 'need a squad and a site' end
    if march_state() then return false, 'an expedition is already under way' end
    local members = squad_members(squad)
    if #members == 0 then return false, 'that squad has no living members' end
    local no_tool = missing_tool(kind)
    if no_tool then return false, no_tool end
    -- WHERE THIS TRADE MAY GO. The four work trades strip a place, so they are confined to your
    -- own holdings; scribes only copy, so they may visit any library you are on speaking terms
    -- with -- but speaking terms is the condition, and war and never-met both fail it.
    if kind == 'scholarly' then
        local contact = site_contact(site)
        if contact == nil then
            return false, 'you have had no contact with that site'
        elseif contact == 'war' then
            return false, 'you are at war with that site -- make peace first'
        end
        if #site_books(site) == 0 then return false, 'that library holds no known books' end
    elseif not is_ours(site) then
        return false, 'that site is not yours to send a work party to'
    end
    -- Rolled now only to VALIDATE the picks and to record what a full turnout would fetch. The
    -- haul that lands is rolled on return, from whoever actually made it off the map.
    local haul, bad = resolve_expedition(kind, choice, members, survey(site))
    if not haul then return false, bad end

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
        manifest = haul,
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
    destroy_route(st.route_id)
    save_march(nil)
    stop_march_driver()
    dfhack.gui.showAnnouncement(('The expedition is called off%s.'):format(
        why and (' -- ' .. why) or ''), COLOR_YELLOW)
    return true
end

-- ---------------------------------------------------------------------------
-- off the map, and back again
-- ---------------------------------------------------------------------------
-- THE MANUAL ROUND TRIP, rather than a real DF mission. A mission would hand the squad to an
-- `army_controller` and hope DF gives them back; this takes them off the map by hand, counts
-- the days here, and puts them down again on the tile they left from. Fewer moving parts, and
-- the expedition cannot be lost to DF deciding the army should do something else.
--
-- A unit is "off the map" the way DF itself parks one: `flags1.inactive` set and dropped from
-- `world.units.active`. Both halves matter -- leaving them in the active list keeps the engine
-- ticking a unit that is nowhere, and leaving the tile's occupancy set leaves an invisible
-- body blocking the square they walked off.

-- With a position it goes out as a ZOOM announcement, so clicking the notification (or
-- pressing the recentre key on it) puts the map on the tile it is about -- which for an
-- expedition is the corner of the map where the goods were just dropped, a hundred tiles from
-- anywhere you were looking. `MIGRANT_ARRIVAL` is the carrier because it is display-only in
-- `announcements.txt` (`A_D:D_D`): no popup box, no forced pause, just a recentrable line.
local function announce_at(pos, text, color)
    local ok = false
    if pos then
        ok = pcall(dfhack.gui.showZoomAnnouncement, df.announcement_type.MIGRANT_ARRIVAL,
                   pos, text, color, true)
    end
    if not ok then pcall(dfhack.gui.showAnnouncement, text, color, true) end
end

local function offload(u)
    -- Detach them from any job FIRST -- never `removeJob` a unit's `current_job`, that
    -- segfaults; `removeWorker` unhooks the worker and leaves the job to be picked up again.
    if u.job.current_job then pcall(dfhack.job.removeWorker, u.job.current_job, 0) end
    local blk = dfhack.maps.ensureTileBlock(u.pos)
    if blk then blk.occupancy[u.pos.x % 16][u.pos.y % 16].unit = false end
    u.flags1.inactive = true
    local act = df.global.world.units.active
    for i = #act - 1, 0, -1 do
        if act[i].id == u.id then act:erase(i) break end
    end
end

local function reload_unit(u, pos)
    u.flags1.inactive = false
    local act, found = df.global.world.units.active, false
    for _, a in ipairs(act) do if a.id == u.id then found = true break end end
    if not found then act:insert('#', u) end
    pcall(dfhack.units.teleport, u, xyz2pos(pos.x, pos.y, pos.z))
end

-- name -> raws index. The survey speaks in display names because that is what the panel shows;
-- creating the goods needs the index back, so each lookup walks the raws once on return.
-- EVERY ONE OF THESE GUARDS AGAINST A NIL NAME, and the guard is not paranoia. `plant_name`
-- returns nil for the grasses it deliberately filters out, so a row with no name compared
-- nil == nil and matched meadow-grass -- the expedition delivered the one plant the survey
-- exists to exclude. A nameless row is a bug upstream; it must never resolve to something.
local function find_inorganic(name)
    if not name or name == '' then return nil end
    for i = 0, #df.global.world.raws.inorganics.all - 1 do
        if inorganic_name(i) == name then return i end
    end
end

local function find_plant(name, namer)
    if not name or name == '' then return nil end
    for i = 0, #df.global.world.raws.plants.all - 1 do
        if namer(i) == name then return i, df.global.world.raws.plants.all[i] end
    end
end

local function find_creature(name)
    if not name or name == '' then return nil end
    for i = 0, #df.global.world.raws.creatures.all - 1 do
        if creature_name(i) == name then return i, df.global.world.raws.creatures.all[i] end
    end
end

-- Put a live animal of `race` on the map at `pos`, wild and belonging to nobody. Shared by the
-- cage branch (which then locks it in) and the corpse branch (which then bleeds it out).
--
-- ORDER MATTERS: a freshly created unit comes out at -30000 with `inactive` set, so seed `pos`
-- to a real tile BEFORE clearing the flag, and insert into `units.active` last or DF never
-- ticks it. See [[df-unit-spawn-solved]].
local function spawn_animal(race, raw, pos)
    local u = dfhack.units.create(race, math.random(0, #raw.caste - 1))
    if not u then return nil end
    u.pos:assign(pos)
    u.flags1.inactive = false
    df.global.world.units.active:insert('#', u)
    u.flags1.tame = false
    u.civ_id, u.population_id = -1, -1
    u.training_level = df.animal_training_level.WildUntamed
    -- what a genuinely wild animal carries, and a created one does not
    u.flags2.roaming_wilderness_population_source = true
    return u
end

-- The wood an expedition's cages are knocked together from. Any plant with a WOOD material
-- will do -- the cage is a container, not a trophy -- so this takes the first and remembers it.
local cage_wood_cache
local function cage_wood()
    if cage_wood_cache ~= nil then return cage_wood_cache or nil end
    for i = 0, #df.global.world.raws.plants.all - 1 do
        local pr = df.global.world.raws.plants.all[i]
        local mi = dfhack.matinfo.find('PLANT_MAT:' .. pr.id .. ':WOOD')
        if mi then cage_wood_cache = mi return mi end
    end
    cage_wood_cache = false
    return nil
end

local function make(creator, item_type, mat_type, mat_index, count)
    local made = {}
    for _ = 1, count do
        local ok, items = pcall(dfhack.items.createItem, creator, item_type, -1, mat_type, mat_index)
        if not ok or not items or #items == 0 then break end
        for _, it in ipairs(items) do made[#made + 1] = it end
    end
    return made
end

-- Turn one haul row into real items at the returning squad's feet. Returns how many landed and,
-- when nothing could be made, why -- the caller reports shortfalls rather than silently losing
-- a week's work.
--
-- EXPORTED so it can be exercised without waiting a fortnight for a squad to come home. Three
-- of these branches shipped untested because proving them meant a real round trip, and two of
-- the three were wrong; `unload` runs one row on the spot.
function unload_row(creator, row)
    if not row.name or row.name == '' then return 0, 'that row has no name' end
    if row.kind == 'stone' then
        local idx = find_inorganic(row.name)
        if not idx then return 0, 'no such stone in the raws' end
        return #make(creator, df.item_type.BOULDER, 0, idx, row.count)

    elseif row.kind == 'log' then
        local _, raw = find_plant(row.name, tree_name)
        if not raw then return 0, 'no such tree in the raws' end
        local mi = dfhack.matinfo.find('PLANT_MAT:' .. raw.id .. ':WOOD')
            or dfhack.matinfo.find('PLANT_MAT:' .. raw.id .. ':STRUCTURAL')
        if not mi then return 0, 'that tree has no wood material' end
        return #make(creator, df.item_type.WOOD, mi.type, mi.index, row.count)

    elseif row.kind == 'plant' then
        local _, raw = find_plant(row.name, plant_name)
        if not raw then return 0, 'no such plant in the raws' end
        local mi = dfhack.matinfo.find('PLANT_MAT:' .. raw.id .. ':STRUCTURAL')
        if not mi then return 0, 'that plant has no structural material' end
        return #make(creator, df.item_type.PLANT, mi.type, mi.index, row.count)

    elseif row.kind == 'corpse' then
        -- DF MUST BUILD THE CORPSE, NOT US. An `item_corpsest` from `createItem` carries a race
        -- and a material and nothing else -- none of the body-component data DF dereferences --
        -- and `Items::getDescription` SEGFAULTS on it. That is not a cosmetic problem: DF calls
        -- getDescription whenever it draws the item, so such a corpse crashes the fort the
        -- moment a hunting party's pile is rendered. It killed this one at 23:59.
        --
        -- So the animal comes home and dies HERE. Spawn it live the same way the cage branch
        -- does, knock it senseless so it cannot act in the tick or two it is breathing, and
        -- empty its blood; DF's own death handling then produces a real corpse with everything
        -- in it. Note `exterminate`'s `destroyUnit` pairs blood_count with a vanish_countdown --
        -- that is what removes the body, and it must NOT be copied here.
        local race, raw = find_creature(row.name)
        if not raw then return 0, 'no such creature in the raws' end
        local made = 0
        for _ = 1, row.count do
            local u = spawn_animal(race, raw, creator.pos)
            if not u then break end
            u.counters.unconscious = 1000
            u.body.blood_count = 0
            made = made + 1
        end
        if made == 0 then return 0, 'could not bring the quarry home' end
        return made

    elseif row.kind == 'book' then
        -- A COPY IS THREE PARTS: the bound item, its title, and a pages improvement carrying
        -- the page material, the page count and the `written_content` ids. Sharing the content
        -- id with the original is not a shortcut -- that is precisely what a scribe's copy is,
        -- and DF expects many items to point at one written work.
        local src = find_book_source(row.name)
        if not src then return 0, 'no copy of that book exists to work from' end
        local pages = src.improvements and #src.improvements > 0 and src.improvements[0]
        local made = make(creator, df.item_type.BOOK, src.mat_type, src.mat_index, row.count)
        for _, it in ipairs(made) do
            it.title = (src.title ~= '' and src.title) or row.name
            if pages then
                local imp = df.itemimprovement_pagesst:new()
                imp.mat_type, imp.mat_index = pages.mat_type, pages.mat_index
                imp.maker, imp.masterpiece_event = -1, -1
                imp.quality, imp.skill_rating, imp.age_counter = 0, 0, 0
                imp.count = pages.count
                for _, c in ipairs(pages.contents) do imp.contents:insert('#', c) end
                it.improvements:insert('#', imp)
            end
        end
        return #made

    elseif row.kind == 'cage' then
        -- A CAGED BEAST IS TWO OBJECTS, wired to each other. The cage is an ordinary item; the
        -- occupant is a real live unit sitting in `units.active` with `flags1.caged` set, and
        -- the two are joined BOTH WAYS -- `contains_unitst` on the cage, `contained_in_itemst`
        -- on the unit. Wire only one side and DF renders an empty cage with a loose animal in
        -- it. Get it right and the description builds itself: "crundle () cage (cherry wood)".
        local race, raw = find_creature(row.name)
        if not raw then return 0, 'no such creature in the raws' end
        local wood = cage_wood()
        if not wood then return 0, 'no wood to build a cage from' end

        local made = 0
        for _ = 1, row.count do
            local cages = make(creator, df.item_type.CAGE, wood.type, wood.index, 1)
            local cage = cages[1]
            if not cage then break end
            -- A RANDOM CASTE, which is to say a random sex: you caught what you caught. Two
            -- captures may well be the same sex and thus no breeding pair, which is exactly
            -- the shortage that sent you hunting in the first place.
            local u = spawn_animal(race, raw, cage.pos)
            if not u then break end
            u.flags1.caged = true

            -- THE FLAG IS NOT OPTIONAL. DF treats an item as HOLDING something only when
            -- `flags.container` is set; without it the refs are all correctly wired, the
            -- description still reads "wild boar () cage" -- and the cage shows up EMPTY in
            -- the UI, which is exactly how this was caught.
            cage.flags.container = true
            local holds = df.general_ref_contains_unitst:new()
            holds.unit_id = u.id
            cage.general_refs:insert('#', holds)
            local held = df.general_ref_contained_in_itemst:new()
            held.item_id = cage.id
            u.general_refs:insert('#', held)
            made = made + 1
        end
        return made
    end
    return 0, ('nothing knows how to unload a %s'):format(tostring(row.kind))
end

-- WHO WENT IS WHO PAID. The haul is priced on the units that actually made it off the map,
-- not on the squad roster -- a dwarf who never finished fetching their kit contributes nothing,
-- which is why this is resolved on return rather than reused from the send-time manifest.
local function deliver(st, sq, members)
    if #members == 0 then return end
    local site = df.world_site.find(st.site_id)
    if not site then return end
    local haul, why = resolve_expedition(st.kind, st.choice, members, survey(site))
    if not haul then
        dfhack.printerr('economic-expeditions: nothing to unload -- ' .. tostring(why))
        return
    end
    local creator, lines, missed = members[1], {}, {}
    for _, row in ipairs(haul) do
        local n, err = unload_row(creator, row)
        if n > 0 then lines[#lines + 1] = ('%d %s'):format(n, row.name) end
        if n < row.count then
            missed[#missed + 1] = ('%d %s (%s)'):format(row.count - n, row.name,
                err or 'could not be unloaded')
        end
    end
    if #lines > 0 then
        announce_at(copyall(creator.pos), ('The expedition unloads %s.'):format(
            table.concat(lines, ', ')), COLOR_LIGHTGREEN)
    end
    for _, m in ipairs(missed) do
        dfhack.printerr('economic-expeditions: lost ' .. m)
    end
end

-- Walk off the map anyone who has reached the edge since the last check. Returns the units
-- that left this time, so the caller can tell the first departure (which starts the clock) from
-- a straggler catching up. `squad_members` skips `inactive` units, so somebody who has already
-- gone simply stops appearing.
function depart_arrivals(st, sq)
    local left = {}
    for _, u in ipairs(squad_members(sq)) do
        if at_edge(u, st.tile) then
            offload(u)
            left[#left + 1] = u
        end
    end
    if #left > 0 then
        st.away = st.away or {}
        for _, u in ipairs(left) do st.away[#st.away + 1] = u.id end
    end
    return left
end

-- The days are up: put them back on the tile they left from, with what they went for.
function come_home(st)
    local sq = df.squad.find(st.squad_id)
    local back, lost = {}, 0
    for _, id in ipairs(st.away or {}) do
        local u = df.unit.find(id)
        if u then reload_unit(u, st.tile); back[#back + 1] = u else lost = lost + 1 end
    end
    if #back > 0 then
        announce_at(copyall(back[1].pos),
            ('%s has returned from the expedition -- %d of them.'):format(
                sq and dfhack.military.getSquadName(sq.id) or 'The expedition', #back),
            COLOR_LIGHTGREEN)
        if sq then deliver(st, sq, back) end
    end
    -- anyone who never reached the edge is still walking to it; take the order back
    if sq then clear_squad_orders(sq) end
    destroy_route(st.route_id)
    if lost > 0 then
        dfhack.printerr(('economic-expeditions: %d expedition member(s) could not be found'):format(lost))
    end
    save_march(nil)
    stop_march_driver()
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
-- WHICH TITLES THE FORTRESS ALREADY HOLDS, by title, keyed the same way the survey names
-- them. Every book in the fort is an item in play whatever shelf it is on, so this is one pass
-- over the book vector rather than a walk of every bookcase. Cached per frame alongside the
-- rest of the holdings, because the survey asks it once per title.
local books_cache, books_frame
function fort_books()
    local frame = df.global.world.frame_counter
    if books_cache and books_frame == frame then return books_cache end
    local out = {}
    for _, it in ipairs(df.global.world.items.other.BOOK) do
        if it.title and it.title ~= '' then out[it.title] = true end
    end
    books_cache, books_frame = out, frame
    return out
end

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

-- WHAT THE TRADE NEEDS TO HAND. A mining party needs a pick in the fortress and a logging
-- party an axe. The expedition never touches them -- nobody carries one out and none comes
-- back worn -- they are proof the fortress is equipped for the work, the same way you cannot
-- put a dwarf on Mining with no pick in the stockpile.
local TOOL_OF = {mining = 'pick', logging = 'axe'}

-- The CIV'S OWN DIGGER is the yardstick for what counts. `entity.resources.digger_type` is
-- authoritative for picks, and because that pick is by construction a weapon your race wields
-- in one hand, its two-handed threshold is exactly the line a chopping axe has to stay under.
-- That keeps great axes and halberds -- same AXE skill, twice the size, useless for felling --
-- out of the count without hard-coding a race or a subtype name.
local function tool_subtypes(which)
    local defs = df.global.world.raws.itemdefs.weapons
    local ent = df.historical_entity.find(df.global.plotinfo.civ_id)
    local diggers, limit = {}, 0
    for _, st in ipairs(ent and ent.resources.digger_type or {}) do
        diggers[st] = true
        local d = defs[st]
        if d and d.two_handed > limit then limit = d.two_handed end
    end
    if which == 'pick' then return diggers end

    local axes = {}
    for i = 0, #defs - 1 do
        local d = defs[i]
        if d.skill_melee == df.job_skill.AXE and (limit == 0 or d.two_handed <= limit) then
            axes[i] = true
        end
    end
    return axes
end

-- How many of the tool this trade needs the fortress holds. `nil` means the trade needs none.
-- A merchant's pick is not yours, and neither is one already packed for trade.
function fort_tool_count(kind)
    local which = TOOL_OF[kind]
    if not which then return nil end
    local want, n = tool_subtypes(which), 0
    for _, it in ipairs(df.global.world.items.other.WEAPON) do
        if it.subtype and want[it.subtype.subtype]
            and not it.flags.garbage_collect and not it.flags.foreign
            and not it.flags.trader then
            n = n + 1
        end
    end
    return n
end

-- nil when the fortress is equipped; otherwise why it is not
function missing_tool(kind)
    local which = TOOL_OF[kind]
    if not which then return nil end
    if (fort_tool_count(kind) or 0) > 0 then return nil end
    return ('there is no %s in the fortress -- a %s expedition needs one to hand'):format(
        which, EXPEDITIONS[kind] and EXPEDITIONS[kind].label or kind)
end

-- EVERY BOOK THAT EXISTS, by title. Ordinary copies do not exist off-map -- an off-site
-- library instantiates no book items at all -- so the world's books are its ARTIFACT books,
-- the same 1162 records the site panel lists under Artifacts. Scanned on demand, never per
-- frame.
function world_books()
    local out = {}
    for _, art in ipairs(df.global.world.artifacts.all) do
        local item = art.item
        if item and item:getType() == df.item_type.BOOK then
            local title = dfhack.translation.translateName(art.name, true)
            if title == '' then title = item.title or '' end
            if title ~= '' then out[title] = item end
        end
    end
    return out
end

-- The item to copy a title FROM. A copy needs the original's page material, page count and
-- written content, none of which can be invented, so a title with no findable source is a
-- title we cannot bring back.
function find_book_source(title)
    for _, art in ipairs(df.global.world.artifacts.all) do
        local item = art.item
        if item and item:getType() == df.item_type.BOOK then
            local name = dfhack.translation.translateName(art.name, true)
            if name == '' then name = item.title or '' end
            if name == title then return item end
        end
    end
    for _, item in ipairs(df.global.world.items.other.BOOK) do
        if item.title == title then return item end
    end
end

-- Which trades come home with something no matter how unskilled the squad is. A week at a
-- quarry or in the woods yields at least one rock or one log; a week of foraging or hunting can
-- genuinely turn up nothing.
local MIN_ONE = {mining = true, logging = true}

EXPEDITIONS = {
    mining  = {label = 'mining',  skill = df.job_skill.MINING,      picks = 'stone'},
    logging = {label = 'logging', skill = df.job_skill.WOODCUTTING, picks = 'trees'},
    botany  = {label = 'botany',  skill = df.job_skill.HERBALISM,   picks = 'plants'},
    hunting = {label = 'hunting', skill = df.job_skill.SNEAK,       picks = 'game'},
    -- SCRIBES, not a work party. There is nothing to choose: the library is the target, and
    -- what they come back with is whatever they managed to copy.
    scholarly = {label = 'scholarly', skill = df.job_skill.READING, picks = 'books'},
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
    -- `keep` holds a row that came out at zero. Mining and logging need one to exist so the
    -- per-mission floor below has something to raise; every other kind drops it.
    local function add(name, k, n, keep)
        if not name then return end
        if n <= 0 and not keep then return end
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
        -- NOT an `and/or` ternary: with `{target = 'amethyst'}` the `and` yields nil, the `or`
        -- falls through, and `layer` becomes the CHOICE TABLE itself -- which then fails as
        -- "table: 0x... is not a layer stone". Picking only a vein is perfectly legal.
        local layer, target
        if type(choice) == 'table' then
            layer, target = choice.layer, choice.target
        else
            layer = choice
        end
        if layer then
            if stone_tier(d, layer) ~= 'layer' then
                return nil, ('%s is not a layer stone at this site'):format(tostring(layer))
            end
            add(layer, 'stone', rate_to_count(MINING_YIELD.layer * 100 * attempts, roll), true)
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
            add(target, 'stone', rate_to_count((MINING_YIELD[tier] or 0) * 100 * attempts, roll), true)
        end
        if not layer and not target then return nil, 'pick a layer stone, a target, or both' end

    elseif kind == 'logging' then
        add(choice, 'log', rate_to_count(LOG_YIELD * 100 * attempts, roll), true)

    elseif kind == 'botany' then
        for _, u in ipairs(units) do
            local lvl = squad_skill({u}, spec.skill)
            add(choice, 'plant', rate_to_count(10 * lvl, roll))
        end

    elseif kind == 'scholarly' then
        -- ONE ROLL PER SCRIBE: a flat tenth for turning up at all, plus a tenth for every level
        -- of Reading. Summed as a percentage and converted once, so ten unskilled scribes make
        -- 100% -- a squad of ten always comes home with at least one book, exactly as specified.
        local have = fort_books()
        local all, wanted = {}, {}
        for _, t in ipairs(d.books or {}) do
            all[#all + 1] = t
            if not have[t] then wanted[#wanted + 1] = t end
        end

        local percent, levels = 0, 0
        for _, u in ipairs(units) do
            local lvl = squad_skill({u}, spec.skill)
            levels = levels + lvl
            percent = percent + 10 + 10 * lvl
        end

        -- NO DUPLICATES WHILE ANYTHING NEW IS LEFT. Copying the same book twice in one trip is
        -- a wasted trip; once the fort holds every title this library has, a second copy is the
        -- only thing left to bring, so the rule relaxes rather than coming home empty.
        local function take(pool, exclusive)
            if #pool == 0 then return nil end
            local i = math.min(#pool, math.max(1, math.floor(roll() * #pool) + 1))
            local pick = pool[i]
            if exclusive then table.remove(pool, i) end
            return pick
        end
        for _ = 1, rate_to_count(percent, roll) do
            local pick = #wanted > 0 and take(wanted, true) or take(all, false)
            if not pick then break end
            add(pick, 'book', 1)
        end

        -- A RARER FIND, and not from this library at all: a hundredth per level of Reading that
        -- somebody turns up a book the fortress has never held, from anywhere in the world. If
        -- you already own a copy of everything that exists, this finds nothing.
        local elsewhere = {}
        for title in pairs(world_books()) do
            if not have[title] then elsewhere[#elsewhere + 1] = title end
        end
        table.sort(elsewhere)
        for _ = 1, rate_to_count(levels, roll) do
            local pick = take(elsewhere, true)
            if not pick then break end
            add(pick, 'book', 1)
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
    -- MINING AND LOGGING NEVER COME HOME EMPTY. A squad with no Mining between them still
    -- spends a week at a quarry and can carry one rock out of it; the same for a week in the
    -- woods and one log. The floor is per MISSION, not per pick, so choosing a small cluster
    -- alongside a layer stone does not turn a 1-in-500 vein into a guaranteed one -- the
    -- guaranteed item goes on the FIRST row, which is the quarry stone or the tree they went
    -- for. Botany and hunting keep no floor: a week's foraging really can find nothing.
    if MIN_ONE[kind] then
        local total = 0
        for _, row in ipairs(haul) do total = total + row.count end
        if total == 0 and haul[1] then haul[1].count = 1 end
    end
    -- drop the placeholders that stayed at zero, so nothing reads "0 bituminous coal"
    for i = #haul, 1, -1 do
        if haul[i].count <= 0 then table.remove(haul, i) end
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

-- THE LIBRARY BLOCK. Unlike every other group this one is a LIST, one title per line, because
-- a library runs to dozens of books -- Bannertongue holds 67 -- and wrapped prose at that
-- length is unreadable. For the same reason the button goes on the HEADER row rather than
-- after the names: you should not have to scroll past sixty titles to find it.
--
-- Three states, and the difference is the whole point of showing the line at all:
--   contacted      the titles, a count, and a button
--   never met      no titles -- you do not know what they have until you have spoken to them
--   at war         the titles, but no button; make peace first
local function library_rows(rows, d)
    -- No library, no line. A site with no library has nothing to say here and a row saying so
    -- on every one of them is noise.
    if d.libraries <= 0 then return end
    rows[#rows + 1] = {}

    if d.contact == nil then
        rows[#rows + 1] = {{text = 'Library: ', pen = LABEL_PEN}}
        rows[#rows + 1] = {{text = INDENT, pen = VALUE_PEN},
            {text = 'Contact the site to learn about their books and send scribes to copy them.',
             pen = COLOR_BROWN}}
        return
    end

    if d.contact == 'war' then
        rows[#rows + 1] = {{text = 'Library: ', pen = LABEL_PEN}}
        rows[#rows + 1] = {{text = INDENT, pen = VALUE_PEN},
            {text = 'Make peace in order to send scribes to copy these books.',
             pen = COLOR_BROWN}}
    else
        local head = {{text = 'Library: ', pen = LABEL_PEN},
                      {text = ('%d book%s'):format(#d.books, #d.books == 1 and '' or 's'),
                       pen = VALUE_PEN}}
        -- nothing to copy, nothing to send anybody for
        if #d.books > 0 then
            head[#head + 1] = {text = '   ', pen = VALUE_PEN}
            head[#head + 1] = {text = '[Send Expedition]', pen = BUTTON_PEN}
            head.button = 'scholarly'
        end
        rows[#rows + 1] = head
    end

    local have = fort_books()
    for _, title in ipairs(d.books) do
        rows[#rows + 1] = {{text = INDENT, pen = VALUE_PEN},
                           {text = title, pen = have[title] and VALUE_PEN or MISSING_PEN}}
    end
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
    library_rows(rows, d)
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
    elseif kind == 'scholarly' then
        -- Nothing to pick: the library IS the target. The titles are listed so you can see what
        -- you are sending scribes for, on a slot nothing reads.
        return {{'Books in the library', d.books, 'browse'}}
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
    local no_tool = missing_tool(self.kind)
    if no_tool then
        dfhack.printerr('economic-expeditions: ' .. no_tool)
        return
    end
    local haul, err, attempts = resolve_expedition(self.kind, choice, sq.members, self.d)
    if err then
        dfhack.printerr('economic-expeditions: ' .. err)
        return
    end
    -- THE MANIFEST, to the console, and then they go. `begin_march` rolls its own haul; this
    -- one is only what the player is shown, so the two can differ by a rock. Print before
    -- sending so a refusal is not buried under a list.
    print(('%s expedition to %s -- %s, %d dwarves, %d attempts'):format(
        EXPEDITIONS[self.kind].label, self.d.name,
        dfhack.military.getSquadName(sq.squad.id), #sq.members, attempts))
    if #haul == 0 then print('  comes home with nothing') end
    for _, row in ipairs(haul) do
        print(('  %-6s %-26s x%d'):format(row.kind, row.name, row.count))
    end

    local ok, why = begin_march(sq.squad, self.site, self.kind, choice)
    if not ok then
        dfhack.printerr('economic-expeditions: ' .. tostring(why))
        return
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
