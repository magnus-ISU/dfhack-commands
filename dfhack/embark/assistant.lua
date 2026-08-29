-- Find embark sites matching what you actually want, the way embark-assistant did.
--@module = true
--[[
embark/assistant

A site finder for the fortress embark screen: give it the things you refuse to
embark without, and it sweeps the whole world map and tells you where they are.
This is a reimplementation of the old DFHack `embark-assistant` plugin, which no
longer ships.

    embark/assistant flux coal river fresh
    embark/assistant biome=Forest soil3 calm near=DWARF
    embark/assistant goto 2          -- centre the map on result 2
    embark/assistant                 -- no filters: just the best all-round tiles

Filters (all AND-ed, all optional)
----------------------------------
    flux            a flux-class stone in the column (steel)
    coal            lignite or bituminous coal (fuel with no magma sea)
    casts           a GYPSUM-class stone (plaster, so casts for broken bones)
    ore             an economic metal ore in the veins
    river / brook   running water on the tile
    fresh           salinity under 33 and not an ocean tile
    soilN           at least N soil layers, e.g. soil3
    biome=<Name>    Swamp Desert Forest Mountains Ocean Lake Glacier Tundra
                    Grassland Hills
    aquifer / lightaq / noaquifer
    volcano / volcanoN      a volcano on the tile, or within N tiles
    magma / magmaN          magma pool (needs `survey`); magma1 = cavern 1
    adamantine / noadamantine   (needs `survey`)
    calm / savage   savagery under 33 / 66 and over
    good / evil     evilness under 33 / 66 and over
    near=<RACE>     a civilization of that creature id with a site within 30
                    world tiles, on the same landmass -- near=DWARF is the one
                    you want, since it is your caravan
    notower         no necromancer tower within its own 10-tile reach
    n=<count>       how many results to print (default 10)

Everything is scored as well as filtered, so a run with no filters at all still
ranks the world: elbow room first (how many of the surrounding 5x5 world tiles
can be embarked on at all), then rivers, soil, flux, coal, a calm neighbourhood
and distance from the nearest dwarven hall.

What it cannot see, and why
---------------------------
**Volcanoes and aquifers are world-wide and free.**  Every named peak is in
`world_data.mountain_peaks` with an `is_volcano` flag -- that is what draws the
volcano on the world map -- and aquifers fall out of the geology column, a layer
bottoming at -3 or deeper whose stone carries the `AQUIFER` flag (a non-soil one
being the heavy kind).  Both are the original plugin's own rules.

**Magma pools and adamantine are not.**  Those live in `region_details.features`,
which DF loads per world tile, so they need `embark/assistant survey` once.  The
original embark-assistant solved this by driving DF's own cursor across all 4,225
tiles with `feed_key(CURSOR_*)`, surveying each as DF loaded it; this does the
same thing more cheaply, because pointing the camera somewhere makes DF load a
whole ~10x6 block of region details AND keep them.  Roughly a hundred camera
stops cover the world.  Magma levels are the original's: 3 volcano, 2 a pool
reaching cavern 1, 1 cavern 2, 0 cavern 3.

Speed comes from the same observation: geology is per `geo_index`, not per tile,
and a world has a few dozen of those against thousands of tiles.  Every column is
classified once up front and each tile is then a table lookup, which keeps a
full-world sweep off the "never scan the map from Lua" list -- 4,225 tiles in
~1.3 s on a 65x65 world.  That is still 1.3 s of frozen main thread, so this is a
command you run, never something an overlay calls.

Checked against an independently written ground-truth walk -- per tile, no
`geo_index` cache, no helper shared with this file -- over twenty-odd filter
combinations across two rounds, covering every filter here.  Match counts were
identical in every case and no returned tile fell outside the truth set.  The
run found two real bugs, which is the point of doing it: `magmaN` had its cavern
numbering inverted, and the first survey left sixteen tiles unvisited (hence the
gap pass).  `goto` was confirmed to land on the tile it names; three results'
flux / coal / plaster claims were confirmed against `embark/extra-info`, which
reads the geology by a different path; and `magma3` on the feature data returns
exactly the same single tile as `volcano` on `mountain_peaks`, two unrelated
sources agreeing on the world's one volcano.
]]

local RANGE_CIV = 30
local RANGE_TOWER = 10
local WINDOW = 2                -- 5x5 elbow-room window
local UNEMBARKABLE = {Ocean = true, Lake = true, Mountains = true}
local COAL_IDS = {LIGNITE = true, BITUMINOUS_COAL = true}

local function wd() return df.global.world.world_data end

-- results of the last sweep, kept so `goto` can act on them
last_results = last_results or nil

-- ---- world data --------------------------------------------------------------

local function region_entry(wx, wy)
    local w = wd()
    if wx < 0 or wy < 0 or wx >= w.world_width or wy >= w.world_height then return end
    local ok, rme = pcall(function() return w.region_map[wx]:_displace(wy) end)
    return ok and rme or nil
end

local function region_type(rme)
    local ok, t = pcall(function()
        return df.world_region_type[wd().regions[rme.region_id].type]
    end)
    return ok and t or nil
end

local function has_class(m, class)
    for i = 0, #m.material.reaction_class - 1 do
        if m.material.reaction_class[i].value == class then return true end
    end
    return false
end

-- One pass over every geology column in the world, classified into the handful
-- of yes/no answers the filters ask about.  A world has a few dozen columns and
-- thousands of tiles pointing at them, so this is the whole performance story.
local function classify_geology()
    local inor = df.global.world.raws.inorganics.all
    local out = {}
    local biomes = wd().geo_biomes
    for gi = 0, #biomes - 1 do
        local g = {flux = false, coal = false, casts = false, ore = false, soil = 0,
                   aquifer = false, aq_heavy = false}
        pcall(function()
            local gb = biomes[gi]
            for i = 0, #gb.layers - 1 do
                local L = gb.layers[i]
                local is_soil = df.geo_layer_type[L.type] == 'SOIL'
                if is_soil then g.soil = g.soil + 1 end
                -- the old plugin's rule: a layer bottoming at -3 or deeper whose
                -- stone carries the AQUIFER flag.  A non-soil one is the heavy
                -- kind you cannot just dig past.
                local lm = L.mat_index >= 0 and inor[L.mat_index]
                if lm and lm.flags and lm.flags.AQUIFER and L.bottom_height <= -3 then
                    g.aquifer = true
                    if not is_soil then g.aq_heavy = true end
                end
                local mats = {L.mat_index}
                for j = 0, #L.vein_mat - 1 do mats[#mats + 1] = L.vein_mat[j] end
                for _, idx in ipairs(mats) do
                    local m = idx >= 0 and inor[idx]
                    if m then
                        if has_class(m, 'FLUX') then g.flux = true end
                        if has_class(m, 'GYPSUM') then g.casts = true end
                        if COAL_IDS[m.id] then g.coal = true end
                        if m.flags and m.flags.METAL_ORE then g.ore = true end
                    end
                end
            end
        end)
        out[gi] = g
    end
    return out
end

local function landmass_at(wx, wy)
    local rme = region_entry(wx, wy)
    return rme and rme.landmass_id or nil
end

-- Volcanoes are world-wide data and cost nothing: DF keeps every named peak in
-- `world_data.mountain_peaks` with an `is_volcano` flag, which is what draws the
-- volcano icon on the world map.  No survey needed for these.
local function volcano_peaks()
    local out = {}
    pcall(function()
        for _, p in ipairs(wd().mountain_peaks) do
            if p.flags and p.flags.is_volcano then
                out[#out + 1] = {x = p.pos.x, y = p.pos.y,
                                 land = landmass_at(p.pos.x, p.pos.y)}
            end
        end
    end)
    return out
end

-- Every civilization's site positions, once, so the near= filter is a distance
-- check rather than another sweep.  Towers are collected separately: DF leaves
-- them out of its own neighbour list and they reach only 10 tiles.
local function survey_sites()
    local civs, towers = {}, {}
    for _, s in ipairs(wd().sites) do
        local tower = false
        pcall(function()
            tower = df.world_site_type[s.type] == 'Fortress'
                and s.subtype_info ~= nil
                and df.fortress_type[s.subtype_info.fortress_type] == 'TOWER'
        end)
        if tower then
            towers[#towers + 1] = {x = s.pos.x, y = s.pos.y, land = landmass_at(s.pos.x, s.pos.y)}
        elseif s.civ_id >= 0 then
            local e = df.historical_entity.find(s.civ_id)
            if e and df.historical_entity_type[e.type] == 'Civilization' then
                local c = df.creature_raw.find(e.race)
                local id = c and c.creature_id
                if id then
                    civs[id] = civs[id] or {}
                    table.insert(civs[id],
                        {x = s.pos.x, y = s.pos.y, land = landmass_at(s.pos.x, s.pos.y)})
                end
            end
        end
    end
    return civs, towers
end

-- Nearest of `list` to (wx, wy).  With `land` given, only sites on that landmass
-- count: world-map travel does not cross ocean, so a civ across the water is not
-- a neighbour however close it looks on the map.
local function nearest(list, wx, wy, land)
    local best
    for _, p in ipairs(list or {}) do
        if land == nil or p.land == land then
            local d = math.max(math.abs(p.x - wx), math.abs(p.y - wy))
            if not best or d < best then best = d end
        end
    end
    return best
end


-- ---- the deep survey: magma pools and adamantine ------------------------------
--
-- These two are NOT world-wide data.  They live in `region_details.features`,
-- which DF loads per world tile -- and that is exactly why the original
-- embark-assistant walked DF's own cursor across the entire map with
-- `feed_key(CURSOR_*)`, surveying one tile at a time.  This does the same thing
-- by the same principle and a cheaper route: DF loads region details for a whole
-- block around wherever the camera is pointed and then KEEPS them (292 were
-- resident after ordinary play here), so pointing the camera at a grid of
-- positions and harvesting what appears covers the world in ~100 steps instead
-- of 4,225.
--
-- Magma levels are the original's: 3 volcano, 2 pool reaching cavern 1, 1 cavern
-- 2, 0 cavern 3 -- higher is shallower.  `2 - start_depth` on a magma pool,
-- since layer_type is Cavern1=0, Cavern2=1, Cavern3=2.

deep = deep or {}            -- [wx*4096+wy] = {magma = n|nil, adam = bool}
deep_world = deep_world or nil
deep_count = deep_count or 0

local HARVEST_PER_FRAME = 40

local function world_key()
    local ok, k = pcall(function()
        return dfhack.translation.translateName(wd().name, true) ..
               '/' .. tostring(wd().world_width) .. 'x' .. tostring(wd().world_height)
    end)
    return ok and k or '?'
end

local function reset_deep()
    deep, deep_count, deep_world = {}, 0, world_key()
end

-- Read one world tile's features out of a loaded region_details record.
local function absorb(d)
    local wx, wy = d.pos.x, d.pos.y
    local key = wx * 4096 + wy
    if deep[key] then return false end
    local rec = {magma = nil, adam = false}
    pcall(function()
        local sx, sy = wx // 16, wy // 16
        local shell = wd().feature_map[sx]:_displace(sy)
        if not shell or not shell.features or shell.x ~= sx or shell.y ~= sy then return end
        local inits = shell.features.feature_init[wx % 16][wy % 16]
        local n = #inits
        for ex = 0, 15 do
            for ey = 0, 15 do
                local list = d.features[ex][ey]
                for i = 0, #list - 1 do
                    local idx = list[i].feature_idx
                    if idx >= 0 and idx < n then
                        local f = inits[idx]
                        if df.feature_init_deep_special_tubest:is_instance(f) then
                            rec.adam = true
                        elseif df.feature_init_volcanost:is_instance(f) then
                            rec.magma = 3
                        elseif df.feature_init_magma_poolst:is_instance(f) then
                            local lv = 2 - f.start_depth
                            if not rec.magma or lv > rec.magma then rec.magma = lv end
                        end
                    end
                end
            end
        end
    end)
    deep[key] = rec
    deep_count = deep_count + 1
    return true
end

-- Pull in whatever DF has loaded since last time, bounded so no single frame
-- stalls: each record is a 16x16 walk and there can be hundreds waiting.
local function harvest(budget)
    local done = 0
    for _, d in ipairs(wd().midmap_data.region_details) do
        if done >= (budget or HARVEST_PER_FRAME) then break end
        if absorb(d) then done = done + 1 end
    end
    return done
end

local function every_frame(fn)
    local n = 0
    local function step()
        n = n + 1
        if fn(n) or n >= 4000 then return end
        dfhack.timeout(2, 'frames', step)
    end
    step()
end

-- Walk the camera over the world on a grid, harvesting as we go.  Restores the
-- view when it finishes.
function deep_survey(cont)
    local scr = dfhack.gui.getDFViewscreen(true)
    if not df.viewscreen_choose_start_sitest:is_instance(scr) then
        qerror('embark/assistant: the deep survey needs the fortress embark screen.')
    end
    if deep_world ~= world_key() then reset_deep() end
    local W, H = wd().world_width, wd().world_height
    local STRIDE_X, STRIDE_Y = 8, 4      -- one camera stop loaded a 10x6 block
    local stops = {}
    for x = STRIDE_X // 2, W - 1, STRIDE_X do
        for y = STRIDE_Y // 2, H - 1, STRIDE_Y do
            stops[#stops + 1] = {x = x, y = y}
        end
    end
    local saved = {cx = scr.region_cent_x, cy = scr.region_cent_y,
                   zx = scr.zoom_cent_x, zy = scr.zoom_cent_y,
                   zoom = scr.zoomed_in, embark = scr.choosing_embark}
    local i = 0
    local gap_pass = false
    print(('embark/assistant: deep survey, %d camera stops...'):format(#stops))
    every_frame(function()
        harvest()
        i = i + 1
        if i > #stops then
            -- drain anything still queued, then put the view back
            for _ = 1, 40 do if harvest(200) == 0 then break end end
            -- the grid leaves a handful of edge tiles unvisited; go get them
            if not gap_pass then
                gap_pass = true
                local gaps = {}
                for x = 0, W - 1 do
                    for y = 0, H - 1 do
                        if not deep[x * 4096 + y] then gaps[#gaps + 1] = {x = x, y = y} end
                    end
                end
                if #gaps > 0 then
                    print(('embark/assistant: %d tiles the grid missed; sweeping those.')
                        :format(#gaps))
                    stops = gaps
                    i = 0
                    return false
                end
            end
            scr.region_cent_x, scr.region_cent_y = saved.cx, saved.cy
            scr.zoom_cent_x, scr.zoom_cent_y = saved.zx, saved.zy
            scr.zoomed_in, scr.choosing_embark = saved.zoom, saved.embark
            print(('embark/assistant: deep survey done -- %d of %d world tiles ' ..
                   'now carry magma and adamantine data.')
                :format(deep_count, W * H))
            if cont then cont() end
            return true
        end
        local st = stops[i]
        scr.choosing_embark = false
        scr.region_cent_x, scr.region_cent_y = st.x, st.y
        scr.zoom_cent_x, scr.zoom_cent_y = st.x * 16 + 8, st.y * 16 + 8
        scr.zoomed_in = true
        return false
    end)
end

-- ---- filters -----------------------------------------------------------------

local USAGE = [=[
embark/assistant -- find embark sites matching what you want.

  embark/assistant [filter ...]     sweep the world, print the best matches
  embark/assistant goto <n>         centre the map on result <n>
  embark/assistant survey           deep pass: magma pools and adamantine
  embark/assistant help             this text

Filters are AND-ed; with none at all it simply ranks the whole world.

  Underground        flux      a flux stone in the column (steel)
                     coal      lignite or bituminous coal (fuel, no magma needed)
                     casts     a GYPSUM stone (plaster, so casts for broken bones)
                     ore       an economic metal ore in the veins
                     soilN     at least N soil layers, e.g. soil3
  Water              river     a river on the tile
                     brook     a brook on the tile
                     fresh     salinity under 33 and not ocean
                     aquifer   an aquifer in the column
                     lightaq   an aquifer, but only in the soil (diggable past)
                     noaquifer no aquifer at all
  Magma              volcano   a volcano ON the tile
                     volcanoN  a volcano within N world tiles, e.g. volcano3
                     magma     any magma pool           }  these two need
                     magmaN    a pool reaching cavern N  }  "survey" first
                               magma1 = up in cavern 1 (best), magma3 = anywhere
                     adamantine / noadamantine          }  needs "survey" too
  Surroundings       biome=X   Swamp Desert Forest Mountains Ocean Lake
                               Glacier Tundra Steppe Grassland Hills
                     calm      savagery under 33
                     savage    savagery 66 and over
                     good      evilness under 33
                     evil      evilness 66 and over
  Neighbours         near=RACE a civ of that creature id with a site within 30
                               world tiles -- near=DWARF is your caravan
                     notower   no necromancer tower within its 10-tile reach
  Output             n=<count> how many to print (default 10)

Examples:
  embark/assistant flux coal river fresh noaquifer
  embark/assistant biome=Forest soil3 calm near=DWARF notower
  embark/assistant volcano                 -- embark on the volcano itself
  embark/assistant survey                  -- then:
  embark/assistant magma1 flux             -- magma in cavern 1, and flux
  embark/assistant goto 3

Volcanoes and aquifers are world-wide and always available. Magma pools and
adamantine are not: they live in `region_details`, which DF loads per world tile,
so "survey" walks the camera over the map once to collect them. That is the same
thing the original embark-assistant did by driving DF's cursor, just in ~100
camera stops instead of one per tile.]=]

local function usage() print(USAGE) end

function parse(args)
    local f = {n = 10}
    for _, a in ipairs(args) do
        local k, v = a:match('^(%w+)=(.+)$')
        if k == 'biome' then f.biome = v
        elseif k == 'near' then f.near = v:upper()
        elseif k == 'n' then f.n = tonumber(v) or 10
        elseif a:match('^soil%d+$') then f.soil = tonumber(a:match('%d+'))
        elseif a:match('^magma%d$') then
            -- the argument is a CAVERN number (1 shallowest), the internal
            -- level is 2 - start_depth (cavern 1 -> 2), so they invert
            local cav = tonumber(a:match('%d'))
            if cav < 1 or cav > 3 then
                qerror('embark/assistant: magmaN takes a cavern 1-3.')
            end
            f.magma = 3 - cav
        elseif a:match('^volcano%d+$') then f.volcano = tonumber(a:match('%d+'))
        elseif a == 'volcano' then f.volcano = 0
        elseif a == 'magma' then f.magma = 0   -- any pool at all
        elseif a == 'flux' or a == 'coal' or a == 'casts' or a == 'ore'
            or a == 'river' or a == 'brook' or a == 'fresh' or a == 'calm'
            or a == 'savage' or a == 'good' or a == 'evil' or a == 'notower'
            or a == 'aquifer' or a == 'noaquifer' or a == 'lightaq'
            or a == 'adamantine' or a == 'noadamantine'
        then f[a] = true
        else
            usage()
            qerror(('embark/assistant: unknown filter "%s".'):format(a))
        end
    end
    return f
end

-- ---- the sweep ---------------------------------------------------------------

function sweep(f)
    local w = wd()
    local geo = classify_geology()
    local civs, towers = survey_sites()
    local volcanoes = volcano_peaks()
    local needs_deep = f.magma ~= nil or f.adamantine or f.noadamantine
    local W, H = w.world_width, w.world_height

    -- embarkability of every tile, computed once: the elbow-room term reads it
    -- 25 times per candidate and the naive version was the slow part
    local ok_tile = {}
    for wx = 0, W - 1 do
        ok_tile[wx] = {}
        for wy = 0, H - 1 do
            local rme = region_entry(wx, wy)
            local t = rme and region_type(rme)
            ok_tile[wx][wy] = (t ~= nil) and not UNEMBARKABLE[t] and (#rme.sites == 0)
        end
    end

    local results = {}
    for wx = 0, W - 1 do
        for wy = 0, H - 1 do
            local rme = region_entry(wx, wy)
            local t = rme and region_type(rme)
            if rme and t and ok_tile[wx][wy] then
                local g = geo[rme.geo_index] or {}
                local river, brook, lake = false, false, false
                pcall(function()
                    river = rme.flags.has_river
                    brook = rme.flags.is_brook
                    lake  = rme.flags.is_lake
                end)
                local keep = true
                if f.flux and not g.flux then keep = false end
                if f.coal and not g.coal then keep = false end
                if f.casts and not g.casts then keep = false end
                if f.ore and not g.ore then keep = false end
                if f.soil and (g.soil or 0) < f.soil then keep = false end
                if f.river and not river then keep = false end
                if f.brook and not brook then keep = false end
                if f.fresh and (rme.salinity >= 33 or t == 'Ocean') then keep = false end
                if f.biome and t ~= f.biome then keep = false end
                if f.aquifer and not g.aquifer then keep = false end
                if f.noaquifer and g.aquifer then keep = false end
                if f.lightaq and (not g.aquifer or g.aq_heavy) then keep = false end
                if f.calm and rme.savagery >= 33 then keep = false end
                if f.savage and rme.savagery < 66 then keep = false end
                if f.good and rme.evilness >= 33 then keep = false end
                if f.evil and rme.evilness < 66 then keep = false end

                local land = rme.landmass_id
                local volc_d = keep and nearest(volcanoes, wx, wy) or nil
                if f.volcano and not (volc_d and volc_d <= f.volcano) then keep = false end

                local dp = keep and deep[wx * 4096 + wy] or nil
                if keep and needs_deep then
                    if not dp then keep = false          -- unsurveyed: cannot say
                    else
                        if f.magma and not (dp.magma and dp.magma >= f.magma) then
                            keep = false
                        end
                        if f.adamantine and not dp.adam then keep = false end
                        if f.noadamantine and dp.adam then keep = false end
                    end
                end

                local tower_d = keep and nearest(towers, wx, wy, land) or nil
                if f.notower and tower_d and tower_d <= RANGE_TOWER then keep = false end

                local near_d
                if keep and f.near then
                    near_d = nearest(civs[f.near], wx, wy, land)
                    if not near_d or near_d > RANGE_CIV then keep = false end
                end

                if keep then
                    local room = 0
                    for dx = -WINDOW, WINDOW do
                        for dy = -WINDOW, WINDOW do
                            local col = ok_tile[wx + dx]
                            if col and col[wy + dy] then room = room + 1 end
                        end
                    end
                    local dwarf_d = nearest(civs.DWARF, wx, wy, land)
                    local score = room * 4
                    if river then score = score + 10 end
                    if brook then score = score + 4 end
                    score = score + math.min(g.soil or 0, 4) * 3
                    if g.flux then score = score + 8 end
                    if g.coal then score = score + 6 end
                    if g.casts then score = score + 2 end
                    if g.ore then score = score + 4 end
                    if g.aquifer then score = score - (g.aq_heavy and 8 or 2) end
                    if volc_d == 0 then score = score + 12 end
                    if dp and dp.magma then score = score + 2 * dp.magma end
                    if dp and dp.adam then score = score + 4 end
                    score = score - (rme.savagery // 20)
                    score = score - (rme.evilness // 20)
                    if dwarf_d then score = score - math.min(dwarf_d, RANGE_CIV) end
                    if tower_d and tower_d <= RANGE_TOWER then score = score - 15 end
                    results[#results + 1] = {
                        x = wx, y = wy, score = score, room = room, biome = t,
                        river = river, brook = brook, lake = lake,
                        soil = g.soil or 0, flux = g.flux, coal = g.coal,
                        casts = g.casts, ore = g.ore, tower = tower_d,
                        dwarf = dwarf_d, salinity = rme.salinity,
                        savagery = rme.savagery, evilness = rme.evilness,
                        aquifer = g.aquifer, aq_heavy = g.aq_heavy,
                        volcano = volc_d, magma = dp and dp.magma,
                        adam = dp and dp.adam, surveyed = dp ~= nil,
                    }
                end
            end
        end
    end
    table.sort(results, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    return results
end

function describe(r)
    local bits = {}
    if r.river then bits[#bits + 1] = 'river' end
    if r.brook then bits[#bits + 1] = 'brook' end
    if r.flux then bits[#bits + 1] = 'flux' end
    if r.coal then bits[#bits + 1] = 'coal' end
    if r.casts then bits[#bits + 1] = 'casts' end
    if r.ore then bits[#bits + 1] = 'ore' end
    if r.volcano == 0 then bits[#bits + 1] = 'VOLCANO'
    elseif r.volcano and r.volcano <= 5 then
        bits[#bits + 1] = ('volcano %d'):format(r.volcano)
    end
    if r.magma == 3 then bits[#bits + 1] = 'magma: volcano'
    elseif r.magma then bits[#bits + 1] = ('magma: cavern %d'):format(3 - r.magma) end
    if r.adam then bits[#bits + 1] = 'adamantine' end
    if r.aquifer then bits[#bits + 1] = r.aq_heavy and 'heavy aquifer' or 'light aquifer' end
    bits[#bits + 1] = r.soil .. ' soil'
    if r.salinity < 33 then bits[#bits + 1] = 'fresh' end
    if r.savagery >= 66 then bits[#bits + 1] = 'savage' end
    if r.evilness >= 66 then bits[#bits + 1] = 'evil' end
    if r.tower and r.tower <= RANGE_TOWER then
        bits[#bits + 1] = ('tower %d!'):format(r.tower)
    end
    if r.dwarf then bits[#bits + 1] = ('hall %d'):format(r.dwarf) end
    return table.concat(bits, ', ')
end

-- ---- commands ----------------------------------------------------------------

local function get_screen()
    local scr = dfhack.gui.getDFViewscreen(true)
    if df.viewscreen_choose_start_sitest:is_instance(scr) then return scr end
end

function goto_result(n)
    if not last_results or not last_results[n] then
        qerror('embark/assistant: no result ' .. tostring(n) ..
               ' -- run the search first.')
    end
    local scr = get_screen()
    if not scr then
        qerror('embark/assistant: not on the fortress embark screen.')
    end
    local r = last_results[n]
    scr.choosing_civilization = false
    scr.choosing_reclaim = false
    scr.choosing_embark = false
    scr.doing_site_finder = false
    scr.region_cent_x, scr.region_cent_y = r.x, r.y
    scr.zoom_cent_x, scr.zoom_cent_y = r.x * 16 + 8, r.y * 16 + 8
    scr.zoomed_in = true
    print(('embark/assistant: centred on (%d, %d) -- %s, %s.')
        :format(r.x, r.y, r.biome, describe(r)))
end

function run(args)
    if args[1] == 'help' or args[1] == '-h' or args[1] == '--help' then
        return usage()
    end
    if args[1] == 'goto' then return goto_result(tonumber(args[2]) or 0) end
    if args[1] == 'survey' then return deep_survey() end
    if not df.global.world.world_data or wd().world_width == 0 then
        qerror('embark/assistant: no world is loaded.')
    end
    local f = parse(args)
    local needs_deep = f.magma ~= nil or f.adamantine or f.noadamantine
    if needs_deep and deep_count == 0 then
        print('embark/assistant: magma and adamantine are not world-wide data -- ' ..
              'run "embark/assistant survey" once first.')
        return
    end
    if needs_deep then
        local total = wd().world_width * wd().world_height
        if deep_count < total then
            print(('embark/assistant: deep data covers %d of %d tiles; the rest ' ..
                   'cannot match. Re-run "survey" to close the gap.')
                :format(deep_count, total))
        end
    end
    local t0 = dfhack.getTickCount()
    local results = sweep(f)
    local ms = dfhack.getTickCount() - t0
    last_results = results
    if #results == 0 then
        print('embark/assistant: nothing in the world matches those filters.')
        return
    end
    print(('embark/assistant: %d matching tiles (%d ms). Best %d:')
        :format(#results, ms, math.min(#results, f.n)))
    for i = 1, math.min(#results, f.n) do
        local r = results[i]
        print(('  %2d. (%3d,%3d) %-12s %s'):format(i, r.x, r.y, r.biome, describe(r)))
    end
    print('  embark/assistant goto <n>   centre the map on one of these')
    print('  embark/assistant help       every filter')
end

-- ---- the GUI -----------------------------------------------------------------
--
-- Bare `embark/assistant` opens this rather than printing to a console nobody is
-- looking at.  Type filters, press Enter, and the matches land in a list; Enter
-- on a row jumps the map to that tile and closes, which is the whole point of
-- the tool.

local gui = require('gui')
local widgets = require('gui.widgets')

local HINT = 'flux coal casts ore soilN river brook fresh aquifer lightaq ' ..
             'noaquifer volcano volcanoN magma magmaN adamantine ' ..
             'noadamantine biome=X calm savage good evil near=RACE notower'

AssistantWindow = defclass(AssistantWindow, widgets.Window)
AssistantWindow.ATTRS{
    frame_title = 'Embark assistant',
    frame = {w = 84, h = 30},
    resizable = true,
    resize_min = {w = 60, h = 18},
}

function AssistantWindow:init()
    self:addviews{
        widgets.EditField{
            view_id = 'filters',
            frame = {t = 0, l = 0},
            label_text = 'Filters: ',
            on_submit = function(text) self:search(text) end,
        },
        widgets.WrappedLabel{
            frame = {t = 2, l = 0},
            text_to_wrap = HINT,
            text_pen = COLOR_GREY,
        },
        widgets.Label{
            view_id = 'status',
            frame = {t = 6, l = 0},
            text = 'Type filters and press Enter. Empty = rank the whole world.',
        },
        widgets.List{
            view_id = 'list',
            frame = {t = 8, l = 0, b = 3},
            on_submit = function(idx) self:jump(idx) end,
        },
        widgets.HotkeyLabel{
            frame = {b = 1, l = 0},
            key = 'CUSTOM_S',
            label = 'deep survey (magma + adamantine)',
            on_activate = function() self:survey() end,
        },
        widgets.Label{
            frame = {b = 0, l = 0},
            text = 'Enter on a row jumps there and closes. Esc closes.',
            text_pen = COLOR_GREY,
        },
    }
end

function AssistantWindow:set_status(text, pen)
    local w = self.subviews.status
    w:setText(text)
    w.text_pen = pen or COLOR_WHITE
end

function AssistantWindow:search(text)
    local args = {}
    for word in (text or ''):gmatch('%S+') do args[#args + 1] = word end
    local ok, err = pcall(parse, args)
    if not ok then
        self:set_status(tostring(err):gsub('^.*embark/assistant: ', ''), COLOR_LIGHTRED)
        return
    end
    local f = err
    if (f.magma ~= nil or f.adamantine or f.noadamantine) and deep_count == 0 then
        self:set_status('magma and adamantine need the deep survey first -- press s.',
                        COLOR_YELLOW)
        return
    end
    local t0 = dfhack.getTickCount()
    local results = sweep(f)
    last_results = results
    local choices = {}
    for i, r in ipairs(results) do
        if i > 200 then break end
        choices[#choices + 1] = {
            text = ('%3d,%-3d %-10s %s'):format(r.x, r.y, r.biome, describe(r)),
            idx = i,
        }
    end
    self.subviews.list:setChoices(choices, 1)
    self:set_status(('%d matches (%d ms)%s'):format(
        #results, dfhack.getTickCount() - t0,
        #results > 200 and ' -- best 200 listed' or ''),
        #results > 0 and COLOR_LIGHTGREEN or COLOR_YELLOW)
end

function AssistantWindow:jump(idx)
    local choice = self.subviews.list:getChoices()[idx]
    if not choice then return end
    local ok, err = pcall(goto_result, choice.idx)
    if not ok then
        self:set_status(tostring(err), COLOR_LIGHTRED)
        return
    end
    if self.parent_view then self.parent_view:dismiss() end
end

function AssistantWindow:survey()
    self:set_status('surveying -- the map will jump about; watch this line.',
                    COLOR_YELLOW)
    local win = self
    deep_survey(function()
        win:set_status(('deep survey done: %d tiles carry magma and adamantine data.')
            :format(deep_count), COLOR_LIGHTGREEN)
    end)
end

AssistantScreen = defclass(AssistantScreen, gui.ZScreen)
AssistantScreen.ATTRS{focus_path = 'embark-assistant'}

function AssistantScreen:init()
    self:addviews{AssistantWindow{}}
end

function AssistantScreen:onDismiss()
    view = nil
end

if dfhack_flags.module then return end

local args = {...}
if #args == 0 then
    if not dfhack.gui.getDFViewscreen(true)
        or not df.viewscreen_choose_start_sitest:is_instance(
            dfhack.gui.getDFViewscreen(true))
    then
        qerror('embark/assistant: not on the fortress embark screen.')
    end
    view = view and view:raise() or AssistantScreen{}:show()
    return
end
run(args)
