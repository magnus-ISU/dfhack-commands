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
**Aquifers and adamantine are not world-wide data.**  Both live in
`region_details`, which DF loads only for the 16x16 world-tile shell the embark
cursor is standing in -- reading another shell is documented as crash-prone, and
did in fact kill the game once during this tool's development.  So the sweep is
built entirely from `region_map` (elevation, salinity, savagery, evilness,
rivers, sites, landmass) and `world_data.geo_biomes` (the layer and vein
columns), which are complete for the whole world and cheap.  Move the cursor to
a result and `embark/extra-info` will tell you about its adamantine.

Speed comes from the same observation: geology is per `geo_index`, not per tile,
and a world has a few dozen of those against thousands of tiles.  Every column is
classified once up front and each tile is then a table lookup, which keeps a
full-world sweep off the "never scan the map from Lua" list.
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
        local g = {flux = false, coal = false, casts = false, ore = false, soil = 0}
        pcall(function()
            local gb = biomes[gi]
            for i = 0, #gb.layers - 1 do
                local L = gb.layers[i]
                if df.geo_layer_type[L.type] == 'SOIL' then g.soil = g.soil + 1 end
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
            towers[#towers + 1] = {x = s.pos.x, y = s.pos.y}
        elseif s.civ_id >= 0 then
            local e = df.historical_entity.find(s.civ_id)
            if e and df.historical_entity_type[e.type] == 'Civilization' then
                local c = df.creature_raw.find(e.race)
                local id = c and c.creature_id
                if id then
                    civs[id] = civs[id] or {}
                    table.insert(civs[id], {x = s.pos.x, y = s.pos.y})
                end
            end
        end
    end
    return civs, towers
end

local function nearest(list, wx, wy)
    local best
    for _, p in ipairs(list or {}) do
        local d = math.max(math.abs(p.x - wx), math.abs(p.y - wy))
        if not best or d < best then best = d end
    end
    return best
end

-- ---- filters -----------------------------------------------------------------

local function parse(args)
    local f = {n = 10}
    for _, a in ipairs(args) do
        local k, v = a:match('^(%w+)=(.+)$')
        if k == 'biome' then f.biome = v
        elseif k == 'near' then f.near = v:upper()
        elseif k == 'n' then f.n = tonumber(v) or 10
        elseif a:match('^soil%d+$') then f.soil = tonumber(a:match('%d+'))
        elseif a == 'flux' or a == 'coal' or a == 'casts' or a == 'ore'
            or a == 'river' or a == 'brook' or a == 'fresh' or a == 'calm'
            or a == 'savage' or a == 'good' or a == 'evil' or a == 'notower'
        then f[a] = true
        else
            qerror(('embark/assistant: unknown filter "%s" -- see the help text.')
                :format(a))
        end
    end
    return f
end

-- ---- the sweep ---------------------------------------------------------------

local function sweep(f)
    local w = wd()
    local geo = classify_geology()
    local civs, towers = survey_sites()
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
                if f.calm and rme.savagery >= 33 then keep = false end
                if f.savage and rme.savagery < 66 then keep = false end
                if f.good and rme.evilness >= 33 then keep = false end
                if f.evil and rme.evilness < 66 then keep = false end

                local tower_d = keep and nearest(towers, wx, wy) or nil
                if f.notower and tower_d and tower_d <= RANGE_TOWER then keep = false end

                local near_d
                if keep and f.near then
                    near_d = nearest(civs[f.near], wx, wy)
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
                    local dwarf_d = nearest(civs.DWARF, wx, wy)
                    local score = room * 4
                    if river then score = score + 10 end
                    if brook then score = score + 4 end
                    score = score + math.min(g.soil or 0, 4) * 3
                    if g.flux then score = score + 8 end
                    if g.coal then score = score + 6 end
                    if g.casts then score = score + 2 end
                    if g.ore then score = score + 4 end
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

local function describe(r)
    local bits = {}
    if r.river then bits[#bits + 1] = 'river' end
    if r.brook then bits[#bits + 1] = 'brook' end
    if r.flux then bits[#bits + 1] = 'flux' end
    if r.coal then bits[#bits + 1] = 'coal' end
    if r.casts then bits[#bits + 1] = 'casts' end
    if r.ore then bits[#bits + 1] = 'ore' end
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
    if args[1] == 'goto' then return goto_result(tonumber(args[2]) or 0) end
    if not df.global.world.world_data or wd().world_width == 0 then
        qerror('embark/assistant: no world is loaded.')
    end
    local f = parse(args)
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
end

if dfhack_flags.module then return end

run({...})
