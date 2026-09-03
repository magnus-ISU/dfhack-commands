-- Spire CONTENTS for fort/planeswalkers: DF keeps what happens when a spire
-- is dug into as "endgame event" monitors on world.event, not on the map --
-- a deep_vein_hollow per spire (the demon wave, keyed on the hollow's open
-- tiles), and per pocket a divine_treasure or an encased_horror (a walled-in
-- demon, or a magma/water flow), each with its own trigger tiles and a
-- `triggered` byte. Revealing a trigger tile fires the monitor. Two things
-- follow for a transfer:
--   * the destination's monitors under the fort must go BEFORE the terrain is
--     rewritten: the source's open tiles landing on their trigger tiles read
--     as "revealed" and fire every one of them on the first tick (seen live
--     twice: seven announcements and a demon wave straight into the fort);
--   * the source's monitors are what make a carried spire worth digging, so
--     they are saved (tokens, relative coords) and recreated at the anchor.
--@module = true

local common = reqscript('internal/planeswalkers/common')
local match = reqscript('internal/planeswalkers/match')

local FILE = '/spires.json'

-- ---- save ------------------------------------------------------------------

local function tiles_out(ctx, path)
    local o = ctx.origin
    local out, inside = {}, false
    for i = 0, #path.x - 1 do
        local x, y = path.x[i], path.y[i]
        if common.in_footprint(ctx, x, y) then inside = true end
        out[#out + 1] = {x - o.x, y - o.y, path.z[i]}
    end
    return out, inside
end

local function pos_out(ctx, pos, tiles)
    local o = ctx.origin
    if common.in_footprint(ctx, pos.x, pos.y) then
        return {pos.x - o.x, pos.y - o.y, pos.z}
    end
    return tiles[1]  -- untriggered monitors carry a garbage zoom position
end

local function race_out(race, caste)
    -- flow pockets carry garbage in the race field
    if not race or race < 0 or race >= #df.global.world.raws.creatures.all then return nil end
    local craw = df.global.world.raws.creatures.all[race]
    if not craw then return nil end
    local ct = caste and caste >= 0 and craw.caste[caste] and craw.caste[caste].caste_id or nil
    return craw.creature_id, ct, craw.flags.GENERATED and true or false,
           match.adult_size(craw, caste)
end

function save_phases(ctx)
    return {{
        name = 'spire contents',
        step = function(job)
            local ev = df.global.world.event
            local out = {v = 1, hollows = {}, treasures = {}, horrors = {}, barriers = {}}
            for _, h in ipairs(ev.deep_vein_hollows) do
                local tiles, inside = tiles_out(ctx, h.tiles)
                if inside then
                    table.insert(out.hollows, {
                        triggered = h.triggered, age = h.age,
                        tiles = tiles, pos = pos_out(ctx, h.pos, tiles),
                    })
                end
            end
            for _, t in ipairs(ev.divine_treasures) do
                local tiles, inside = tiles_out(ctx, t.tiles)
                if inside then
                    local mi = dfhack.matinfo.decode(t.mat_type, t.mat_index)
                    local st
                    if t.item_type >= 0 and t.item_subtype >= 0 then
                        local ok, def = pcall(dfhack.items.getSubtypeDef, t.item_type, t.item_subtype)
                        st = ok and def and def.id or nil
                    end
                    table.insert(out.treasures, {
                        triggered = t.triggered,
                        item_type = t.item_type >= 0 and df.item_type[t.item_type] or nil,
                        item_subtype = st,
                        mat = mi and mi:getToken() or nil,
                        tiles = tiles, pos = pos_out(ctx, t.pos, tiles),
                    })
                end
            end
            for _, h in ipairs(ev.encased_horrors) do
                local tiles, inside = tiles_out(ctx, h.tiles)
                if inside then
                    local rtok, ctok, generated, gsize
                    if h.type == df.tube_hazard_type.ENEMY then
                        rtok, ctok, generated, gsize = race_out(h.race, h.caste)
                    end
                    table.insert(out.horrors, {
                        type = df.tube_hazard_type[h.type],
                        race = rtok, caste = ctok, generated = generated or nil, gsize = gsize,
                        flow = h.flow, flow_st = h.flow_st, flow_sst = h.flow_sst,
                        triggered = h.triggered,
                        tiles = tiles, pos = pos_out(ctx, h.pos, tiles),
                    })
                end
            end
            for _, g in ipairs(ev.glowing_barriers) do
                if common.in_footprint(ctx, g.pos.x, g.pos.y) then
                    local o = ctx.origin
                    table.insert(out.barriers, {
                        triggered = g.triggered, age = g.age,
                        pos = {g.pos.x - o.x, g.pos.y - o.y, g.pos.z},
                    })
                end
            end
            common.write_json(ctx.dir .. FILE, out)
            ctx.manifest.counts.spire_hollows = #out.hollows
            ctx.manifest.counts.spire_treasures = #out.treasures
            ctx.manifest.counts.spire_horrors = #out.horrors
            ctx.manifest.complete.spires = true
            print(('planeswalkers: spire contents saved: %d hollow(s), %d treasure(s), ' ..
                   '%d horror(s), %d glowing barrier(s)'):format(#out.hollows, #out.treasures,
                   #out.horrors, #out.barriers))
            return true
        end,
    }}
end

-- ---- load ------------------------------------------------------------------

-- the footprint the restore covers, in destination tiles
local function dest_rect(ctx)
    local a, s = ctx.anchor, ctx.src or ctx.manifest.dims
    return a.off_x, a.off_y, a.off_x + s.bx * 16, a.off_y + s.by * 16
end

local function path_touches(path, x0, y0, x1, y1)
    for i = 0, #path.x - 1 do
        local x, y = path.x[i], path.y[i]
        if x >= x0 and x < x1 and y >= y0 and y < y1 then return true end
    end
    return false
end

-- phase: remove every destination monitor with a trigger tile under the fort
function clear_phase(ctx)
    return {
        name = 'disarm native spire contents',
        step = function(job)
            local ev = df.global.world.event
            local x0, y0, x1, y1 = dest_rect(ctx)
            local n = 0
            -- mark only: no vector surgery at all. A monitor with `triggered`
            -- set is one DF considers already gone off, so it never fires again;
            -- the record itself stays where DF put it. Erasing entries from these
            -- vectors (with or without freeing them) reproducibly ended the load
            -- in a double-free abort minutes later, so it is not done.
            local function purge(vec, touches)
                for i = 0, #vec - 1 do
                    local m = vec[i]
                    if m.triggered == 0 and touches(m) then
                        m.triggered = 1
                        n = n + 1
                    end
                end
            end
            local by_tiles = function(m) return path_touches(m.tiles, x0, y0, x1, y1) end
            purge(ev.deep_vein_hollows, by_tiles)
            purge(ev.divine_treasures, by_tiles)
            purge(ev.encased_horrors, by_tiles)
            purge(ev.glowing_barriers, function(g)
                return g.pos.x >= x0 and g.pos.x < x1 and g.pos.y >= y0 and g.pos.y < y1
            end)
            ctx.native_contents_cleared = n
            print(('planeswalkers: %d native spire-content monitor(s) under the fort disarmed'):format(n))
            return true
        end,
    }
end

local function tiles_in(ctx, rec, path)
    local a = ctx.anchor
    local zmax = df.global.world.map.z_count - 2
    local n = 0
    for _, t in ipairs(rec.tiles or {}) do
        local z = t[3] + a.off_z
        if z >= 1 and z <= zmax then
            path.x:insert('#', t[1] + a.off_x)
            path.y:insert('#', t[2] + a.off_y)
            path.z:insert('#', z)
            n = n + 1
        end
    end
    return n
end

local function pos_in(ctx, rec, pos, path)
    local a = ctx.anchor
    local p = rec.pos or rec.tiles[1]
    if p then
        pos.x, pos.y, pos.z = p[1] + a.off_x, p[2] + a.off_y, p[3] + a.off_z
    elseif #path.x > 0 then
        pos.x, pos.y, pos.z = path.x[0], path.y[0], path.z[0]
    end
end

local function resolve_divine_mat(ctx, tok)
    if not tok then return nil end
    local mi = dfhack.matinfo.find(tok)
    if mi and mi.type == 0 then return mi.type, mi.index end
    -- divine metals are numbered per world; any local divine metal will do
    ctx.divine_fallback = ctx.divine_fallback or (function()
        for i, raw in ipairs(df.global.world.raws.inorganics.all) do
            if raw.id:match('^DIVINE_') then return i end
        end
        return false
    end)()
    if ctx.divine_fallback then
        common.add_skip(ctx, 'divine-metal-substituted', tok)
        return 0, ctx.divine_fallback
    end
    return nil
end

local function resolve_horror_race(ctx, rec)
    if not rec.race then return -1, -1 end
    local units = reqscript('internal/planeswalkers/units')
    local r, c = units.resolve_race(ctx, rec.race, rec.caste)
    if r then return r, c end
    if rec.generated then
        local gi = match.match_generated(ctx, rec.race, rec.gsize)
        if gi then return gi, 0 end
    end
    return nil
end

-- phase: recreate the source's monitors at the anchor
function restore_phase(ctx)
    return {
        name = 'spire contents',
        step = function(job)
            local data = common.read_json(ctx.dir .. FILE)
            if not data then
                ctx.spire_contents_report = 'snapshot predates spire contents: carried spires ' ..
                    'are empty (re-save the source fort to carry them)'
                return true
            end
            local ev = df.global.world.event
            local nh, nt, nx, nb = 0, 0, 0, 0
            for _, rec in ipairs(data.hollows or {}) do
                local h = df.deep_vein_hollow:new()
                h.triggered = rec.triggered or 0
                h.age = rec.age or 0
                if tiles_in(ctx, rec, h.tiles) > 0 then
                    pos_in(ctx, rec, h.pos, h.tiles)
                    ev.deep_vein_hollows:insert('#', h)
                    nh = nh + 1
                end
            end
            for _, rec in ipairs(data.treasures or {}) do
                local mt, mx = resolve_divine_mat(ctx, rec.mat)
                if not mt then
                    common.add_skip(ctx, 'spire-treasure-material-missing', rec.mat)
                else
                    local t = df.divine_treasure:new()
                    t.histfig_id = -1
                    t.item_type = rec.item_type and df.item_type[rec.item_type] or -1
                    t.item_subtype = -1
                    if rec.item_type and rec.item_subtype then
                        local ok, st = pcall(dfhack.items.findSubtype,
                                             rec.item_type .. ':' .. rec.item_subtype)
                        if ok and st and st >= 0 then t.item_subtype = st end
                    end
                    t.mat_type, t.mat_index = mt, mx
                    t.triggered = rec.triggered or 0
                    if tiles_in(ctx, rec, t.tiles) > 0 then
                        pos_in(ctx, rec, t.pos, t.tiles)
                        ev.divine_treasures:insert('#', t)
                        nt = nt + 1
                    end
                end
            end
            for _, rec in ipairs(data.horrors or {}) do
                local race, caste = resolve_horror_race(ctx, rec)
                if not race then
                    common.add_skip(ctx, 'spire-horror-race-missing', rec.race)
                else
                    local h = df.encased_horror:new()
                    h.type = df.tube_hazard_type[rec.type or 'NONE'] or -1
                    h.race, h.caste = race, caste
                    h.source_hf = -1
                    h.flow, h.flow_st, h.flow_sst = rec.flow or -1, rec.flow_st or -1, rec.flow_sst or -1
                    h.triggered = rec.triggered or 0
                    if tiles_in(ctx, rec, h.tiles) > 0 then
                        pos_in(ctx, rec, h.pos, h.tiles)
                        ev.encased_horrors:insert('#', h)
                        nx = nx + 1
                    end
                end
            end
            for _, rec in ipairs(data.barriers or {}) do
                local a = ctx.anchor
                local z = rec.pos[3] + a.off_z
                if z >= 1 and z < df.global.world.map.z_count - 1 then
                    local g = df.glowing_barrier:new()
                    g.triggered = rec.triggered or 0
                    g.age = rec.age or 0
                    g.pos.x, g.pos.y, g.pos.z = rec.pos[1] + a.off_x, rec.pos[2] + a.off_y, z
                    ev.glowing_barriers:insert('#', g)
                    nb = nb + 1
                end
            end
            ctx.spire_contents_report = ('spire contents carried: %d demon hollow(s), %d divine ' ..
                'treasure(s), %d encased horror(s)/pocket(s), %d glowing barrier(s)')
                :format(nh, nt, nx, nb)
            print('planeswalkers: ' .. ctx.spire_contents_report)
            return true
        end,
    }
end

if dfhack_flags and dfhack_flags.module then return end
qerror('internal module; use fort/planeswalkers')
