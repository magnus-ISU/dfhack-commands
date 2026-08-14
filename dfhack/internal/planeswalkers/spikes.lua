-- De-risk spikes for fort/planeswalkers. Dev-only; each mutates the CURRENT fort,
-- so run them on a throwaway/backed-up save. `spike 0` re-verifies after reload.
--@module = true

local json = require('json')
local tiletypes = require('plugins.tiletypes')
local tilemat = require('tile-material')

local MARKER_DIR = dfhack.getDFPath() .. '/dfhack-config/scripts/data/planeswalkers'
local MARKER = MARKER_DIR .. '/_spike.json'

local function load_marker()
    if dfhack.filesystem.exists(MARKER) then return json.decode_file(MARKER) end
    return {v = 1}
end

local function save_marker(m)
    dfhack.filesystem.mkdir_recursive(MARKER_DIR)
    json.encode_file(m, MARKER)
end

local function mat_index(token)
    local mi = dfhack.matinfo.find(token)
    if not mi or mi.type ~= 0 then qerror('spike: no inorganic ' .. token) end
    return mi.index
end

-- z of the highest non-empty tile in column (x,y)
local function surface_z(x, y)
    for z = df.global.world.map.z_count - 2, 0, -1 do
        local tt = dfhack.maps.getTileType(x, y, z)
        if tt and df.tiletype.attrs[tt].shape ~= df.tiletype_shape.EMPTY then
            return z
        end
    end
end

local function tile_mat_token(x, y, z)
    local ok, mi = pcall(tilemat.GetTileMat, x, y, z)
    if ok and mi then
        local ok2, tok = pcall(function() return mi:getToken() end)
        if ok2 then return tok end
    end
    return nil
end

-- ---- spike 1: dfhack.constructions.insert ----------------------------------

local S1_MAT = 'INORGANIC:MICROCLINE'

local function spike1()
    local m = load_marker()
    local x0, y0 = 4, 4
    local z = surface_z(x0, y0) or qerror('spike1: no surface?')
    local midx = mat_index(S1_MAT)
    m.constructions = {}
    local specs = {
        {x0,     y0, z,     'ConstructedFloor'},
        {x0 + 1, y0, z,     'ConstructedFloor'},
        {x0 + 2, y0, z + 1, 'ConstructedPillar'},  -- wall-form on the open tile above ground
        {x0 + 3, y0, z + 1, 'ConstructedPillar'},
    }
    for _, s in ipairs(specs) do
        local x, y, zz, ttname = s[1], s[2], s[3], s[4]
        local block = dfhack.maps.ensureTileBlock(x, y, zz)
        local orig = block.tiletype[x % 16][y % 16]
        local c = df.construction:new()
        c.pos.x, c.pos.y, c.pos.z = x, y, zz
        c.item_type = df.item_type.BOULDER
        c.item_subtype = -1
        c.mat_type = 0
        c.mat_index = midx
        c.original_tile = orig
        local ok = dfhack.constructions.insert(c)
        if not ok then
            c:delete()
            print(('spike1: insert REFUSED at %d,%d,%d (existing construction?)'):format(x, y, zz))
        else
            block.tiletype[x % 16][y % 16] = df.tiletype[ttname]
            block.designation[x % 16][y % 16].hidden = false
            dfhack.maps.enableBlockUpdates(block)
            table.insert(m.constructions, {x = x, y = y, z = zz, tt = ttname, mat = S1_MAT})
            print(('spike1: inserted %s at %d,%d,%d'):format(ttname, x, y, zz))
        end
    end
    save_marker(m)
end

-- ---- spike 2: bulk tiletypes_setTile incl. vein stone_material -------------

local S2_MAT = 'INORGANIC:CINNABAR'

local function spike2()
    local m = load_marker()
    local x0, y0 = 8, 8
    local zs = surface_z(x0, y0) or qerror('spike2: no surface?')
    local z0 = zs - 8
    local midx = mat_index(S2_MAT)
    local t0 = dfhack.getTickCount()
    local n, fails = 0, 0
    for z = z0, z0 + 1 do
        for x = x0, x0 + 15 do
            for y = y0, y0 + 15 do
                local ok = tiletypes.tiletypes_setTile(xyz2pos(x, y, z), {
                    shape = df.tiletype_shape.WALL,
                    material = df.tiletype_material.STONE,
                    special = df.tiletype_special.NONE,
                    variant = df.tiletype_variant.NONE,
                    hidden = 1, light = 0, subterranean = 1, skyview = 0,
                    aquifer = -1, autocorrect = 0,
                    stone_material = midx,
                    vein_type = df.inclusion_type.CLUSTER,
                })
                if ok then n = n + 1 else fails = fails + 1 end
            end
        end
    end
    -- a few smooth floors on top for the special/shape path
    for x = x0, x0 + 3 do
        tiletypes.tiletypes_setTile(xyz2pos(x, y0, z0 + 2), {
            shape = df.tiletype_shape.FLOOR,
            material = df.tiletype_material.STONE,
            special = df.tiletype_special.SMOOTH,
            variant = df.tiletype_variant.NONE,
            hidden = 1, light = 0, subterranean = 1, skyview = 0,
            aquifer = -1, autocorrect = 0,
            stone_material = midx, vein_type = df.inclusion_type.CLUSTER,
        })
    end
    local ms = dfhack.getTickCount() - t0
    m.paint = {x0 = x0, y0 = y0, z0 = z0, mat = S2_MAT}
    save_marker(m)
    print(('spike2: painted %d tiles (%d failed) in %d ms (%.0f tiles/s)')
        :format(n, fails, ms, n / math.max(ms, 1) * 1000))
end

-- ---- spike 3: artifact record minting --------------------------------------

local function spike3()
    local m = load_marker()
    local citizens = dfhack.units.getCitizens(true)
    local creator = citizens[1] or qerror('spike3: no citizen')
    local items = dfhack.items.createItem(creator, df.item_type.FIGURINE, -1, 0,
                                          mat_index('INORGANIC:MICROCLINE'), false)
    local item = items and items[1] or items
    if type(item) == 'table' then item = item[1] end
    if not item then qerror('spike3: createItem failed') end
    local ar = df.artifact_record:new()
    ar.id = df.global.artifact_next_id
    df.global.artifact_next_id = ar.id + 1
    ar.item = item
    ar.name.has_name = true
    ar.name.first_name = 'spikefact'
    ar.name.language = 0
    -- word-id port test: two arbitrary (valid, in-range) word ids
    local nwords = #df.global.world.raws.language.words
    ar.name.words[0] = math.min(10, nwords - 1)
    ar.name.words[1] = math.min(20, nwords - 1)
    ar.name.parts_of_speech[0] = df.part_of_speech.Noun
    ar.name.parts_of_speech[1] = df.part_of_speech.Noun
    df.global.world.artifacts.all:insert('#', ar)
    local ref = df.general_ref_is_artifactst:new()
    ref.artifact_id = ar.id
    item.general_refs:insert('#', ref)
    item.flags.artifact = true
    -- DF strings are cp437 -- must round-trip through df2utf for JSON storage
    local rendered = dfhack.df2utf(dfhack.translation.translateName(ar.name))
    m.artifact = {id = ar.id, item_id = item.id, rendered = rendered}
    save_marker(m)
    print(('spike3: artifact %d "%s" on item %d'):format(ar.id, rendered, item.id))
end

-- ---- spike 4: batch histfig + citizen spawn --------------------------------

local function spawn_citizen(name_tag, pos)
    local civ = df.historical_entity.find(df.global.plotinfo.civ_id)
    local u = dfhack.units.create(civ.race, math.random(0, 1))
    if not u then return nil end
    u.pos.x, u.pos.y, u.pos.z = pos.x, pos.y, pos.z
    u.flags1.inactive = false
    df.global.world.units.active:insert('#', u)
    dfhack.units.teleport(u, xyz2pos(pos.x, pos.y, pos.z))
    dfhack.units.makeown(u)
    u.name.first_name = name_tag
    u.name.has_name = true
    local hf = df.historical_figure.find(u.hist_figure_id)
    if hf then hf.name.first_name = name_tag; hf.name.has_name = true end
    return u
end

local function link_pair(hf_a, hf_b, class_a, class_b)
    local la = class_a:new(); la.target_hf = hf_b.id; la.link_strength = 100
    hf_a.histfig_links:insert('#', la)
    local lb = class_b:new(); lb.target_hf = hf_a.id; lb.link_strength = 100
    hf_b.histfig_links:insert('#', lb)
end

local function mint_stub_hf(name_tag, race, caste)
    local hf = df.historical_figure:new()
    hf.id = df.global.hist_figure_next_id
    df.global.hist_figure_next_id = hf.id + 1
    hf.race, hf.caste = race, caste
    hf.sex = 1
    hf.appeared_year = df.global.cur_year - 100
    hf.born_year = df.global.cur_year - 100
    hf.born_seconds = 0
    hf.curse_year = -1; hf.curse_seconds = -1
    hf.old_year = df.global.cur_year - 10; hf.old_seconds = 0
    hf.died_year = df.global.cur_year - 20; hf.died_seconds = 0
    hf.civ_id = -1
    hf.population_id = -1
    hf.breed_id = -1
    hf.cultural_identity = -1
    hf.family_head_id = hf.id
    hf.name.first_name = name_tag
    hf.name.has_name = true
    df.global.world.history.figures:insert('#', hf)
    return hf
end

local function spike4()
    local m = load_marker()
    df.global.pause_state = true
    local citizens = dfhack.units.getCitizens(true)
    local anchor = citizens[1] or qerror('spike4: no citizen')
    local pos = anchor.pos
    m.spawned = {}
    local units = {}
    for i = 1, 3 do
        local u = spawn_citizen('spikeling' .. i, pos)
        if u then
            table.insert(units, u)
            table.insert(m.spawned, {unit_id = u.id, hf_id = u.hist_figure_id,
                                     name = 'spikeling' .. i})
            print(('spike4: spawned %s unit=%d hf=%d'):format('spikeling' .. i,
                  u.id, u.hist_figure_id))
        end
    end
    -- spouse-link the first two, stub dead mothers for all three
    m.stubs = {}
    if #units >= 2 then
        local h1 = df.historical_figure.find(units[1].hist_figure_id)
        local h2 = df.historical_figure.find(units[2].hist_figure_id)
        link_pair(h1, h2, df.histfig_hf_link_spousest, df.histfig_hf_link_spousest)
    end
    for i, u in ipairs(units) do
        local hf = df.historical_figure.find(u.hist_figure_id)
        local stub = mint_stub_hf('spikestub' .. i, hf.race, hf.caste)
        link_pair(hf, stub, df.histfig_hf_link_motherst, df.histfig_hf_link_childst)
        table.insert(m.stubs, {hf_id = stub.id, name = 'spikestub' .. i})
    end
    save_marker(m)
    print(('spike4: %d units spawned, %d stub histfigs linked'):format(#units, #m.stubs))
end

-- ---- verify (spike 0): after DF save + reload ------------------------------

local function verify()
    local m = load_marker()
    local pass, fail = 0, 0
    local function check(ok, what)
        if ok then pass = pass + 1 else fail = fail + 1; print('  FAIL: ' .. what) end
    end
    for _, c in ipairs(m.constructions or {}) do
        local found = dfhack.constructions.findAtTile(xyz2pos(c.x, c.y, c.z))
        check(found ~= nil, ('construction record at %d,%d,%d'):format(c.x, c.y, c.z))
        local tt = dfhack.maps.getTileType(c.x, c.y, c.z)
        check(tt == df.tiletype[c.tt],
              ('construction tiletype at %d,%d,%d (got %s)'):format(c.x, c.y, c.z,
               tt and df.tiletype[tt] or '?'))
        check(tile_mat_token(c.x, c.y, c.z) == c.mat,
              ('construction mat at %d,%d,%d (got %s)'):format(c.x, c.y, c.z,
               tostring(tile_mat_token(c.x, c.y, c.z))))
    end
    if m.paint then
        local p = m.paint
        for _, d in ipairs({{0, 0}, {7, 7}, {15, 15}}) do
            local x, y, z = p.x0 + d[1], p.y0 + d[2], p.z0
            local tt = dfhack.maps.getTileType(x, y, z)
            local tmat = tt and df.tiletype.attrs[tt].material
            check(tmat == df.tiletype_material.STONE or tmat == df.tiletype_material.MINERAL,
                  ('painted tile is stone/mineral at %d,%d,%d'):format(x, y, z))
            check(tile_mat_token(x, y, z) == p.mat,
                  ('painted mat at %d,%d,%d (got %s)'):format(x, y, z,
                   tostring(tile_mat_token(x, y, z))))
        end
    end
    if m.artifact then
        local ar = df.artifact_record.find(m.artifact.id)
        check(ar ~= nil, 'artifact record survives')
        if ar then
            check(dfhack.df2utf(dfhack.translation.translateName(ar.name)) == m.artifact.rendered,
                  'artifact name renders identically')
            check(ar.item ~= nil and ar.item.id == m.artifact.item_id, 'artifact item link')
        end
    end
    for _, s in ipairs(m.spawned or {}) do
        local u = nil
        for _, au in ipairs(df.global.world.units.active) do
            if au.name.first_name == s.name then u = au break end
        end
        check(u ~= nil, 'spawned unit present: ' .. s.name)
        if u then
            check(dfhack.units.isCitizen(u), s.name .. ' is citizen')
            check(u.hist_figure_id >= 0 and df.historical_figure.find(u.hist_figure_id) ~= nil,
                  s.name .. ' histfig survives')
        end
    end
    for _, s in ipairs(m.stubs or {}) do
        local hf = df.historical_figure.find(s.hf_id)
        check(hf ~= nil and hf.name.first_name == s.name, 'stub histfig: ' .. s.name)
    end
    print(('spike verify: %d pass, %d fail'):format(pass, fail))
end

local SPIKES = {[0] = verify, [1] = spike1, [2] = spike2, [3] = spike3, [4] = spike4}

function run(n, ...)
    local fn = SPIKES[n] or qerror('unknown spike ' .. tostring(n))
    fn(...)
end

if dfhack_flags and dfhack_flags.module then return end
qerror('use: fort/planeswalkers spike <n>')
