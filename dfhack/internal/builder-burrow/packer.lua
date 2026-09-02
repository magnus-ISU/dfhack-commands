-- The builder-burrow packer: roads grow from the entry (or from existing roads)
-- one segment at a time; each segment is dressed with road stamps and lined
-- with districts as it is laid; a road with nothing along it is refused; a
-- second pass fills leftover frontage.
--
-- Pure Lua, no DFHack dependencies, so it can be run under a plain interpreter
-- for tests. Coordinates are 0-based grid coordinates local to the slab being
-- planned; grids are tables indexed [y][x]. This is a port of
-- prototypes/burrow-stamper/sandbox.html; the design is burrow-stamper-plan.md.
--@module = true

local M = {}

-- ---------------------------------------------------------------------------
-- rng (xorshift32, seeded, so a plan is reproducible)
-- ---------------------------------------------------------------------------

local function RNG(seed)
    local s = (seed or 1) & 0xFFFFFFFF
    if s == 0 then s = 1 end
    local r = {}
    function r.next()
        s = s ~ ((s << 13) & 0xFFFFFFFF); s = s & 0xFFFFFFFF
        s = s ~ (s >> 17)
        s = s ~ ((s << 5) & 0xFFFFFFFF); s = s & 0xFFFFFFFF
        return s / 4294967296
    end
    function r.int(n) return math.floor(r.next() * n) end
    function r.shuffle(a)
        for i = #a, 2, -1 do
            local j = r.int(i) + 1
            a[i], a[j] = a[j], a[i]
        end
        return a
    end
    function r.pick(arr, wf)
        local t = 0
        for _, x in ipairs(arr) do t = t + wf(x) end
        local v = r.next() * t
        for _, x in ipairs(arr) do
            v = v - wf(x)
            if v <= 0 then return x end
        end
        return arr[#arr]
    end
    return r
end
M.RNG = RNG

-- ---------------------------------------------------------------------------
-- geometry
-- ---------------------------------------------------------------------------

local DIRS = {[0] = {0, -1}, [1] = {1, 0}, [2] = {0, 1}, [3] = {-1, 0}} -- up right down left
M.DIRS = DIRS
local function key(x, y) return x .. ',' .. y end
M.key = key
local function unkey(k)
    local x, y = k:match('^(-?%d+),(-?%d+)$')
    return tonumber(x), tonumber(y)
end

local function newGrid(W, H, fill)
    local g = {}
    for y = 0, H - 1 do
        local row = {}
        for x = 0, W - 1 do row[x] = fill end
        g[y] = row
    end
    return g
end
M.newGrid = newGrid

local function copyGrid(g, W, H)
    local c = {}
    for y = 0, H - 1 do
        local row, src = {}, g[y]
        for x = 0, W - 1 do row[x] = src[x] end
        c[y] = row
    end
    return c
end

-- ---------------------------------------------------------------------------
-- stamps: a grid of rows of quickfort codes.
--   ' ' blank (not footprint)  '.' floor  d door  b bed  t table  c chair
--   f cabinet  h chest  r weapon rack  a armor stand  s statue  x coffin
--   P pedestal  A altar  B bookcase  i stair  F farm plot  # built wall (surface)
-- ---------------------------------------------------------------------------

local function transforms(grid)
    local out, seen = {}, {}
    local rows = {}
    for i, r in ipairs(grid) do
        local cells = {}
        for j = 1, #r do cells[j] = r:sub(j, j) end
        rows[i] = cells
    end
    for _ = 1, 2 do
        local cur = rows
        for _ = 1, 4 do
            local strs = {}
            for i, cells in ipairs(cur) do strs[i] = table.concat(cells) end
            local k = table.concat(strs, '\n')
            if not seen[k] then
                seen[k] = true
                out[#out + 1] = strs
            end
            local h, w = #cur, #cur[1]
            local n = {}
            for x = 1, w do
                local row = {}
                for y = 1, h do row[h - y + 1] = cur[y][x] end
                n[x] = row
            end
            cur = n
        end
        local flipped = {}
        for i, cells in ipairs(rows) do
            local rev = {}
            for j = #cells, 1, -1 do rev[#rev + 1] = cells[j] end
            flipped[i] = rev
        end
        rows = flipped
    end
    return out
end

local function analyse(grid)
    local h = #grid
    local w = 0
    for _, r in ipairs(grid) do if #r > w then w = #r end end
    local function at(x, y)
        if y < 0 or y >= h or x < 0 or x >= w then return ' ' end
        local r = grid[y + 1]
        if x + 1 > #r then return ' ' end
        return r:sub(x + 1, x + 1)
    end
    local cells = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local ch = at(x, y)
            if ch ~= ' ' then cells[#cells + 1] = {x = x, y = y, ch = ch} end
        end
    end
    local entrances = {}
    for _, c in ipairs(cells) do
        if c.ch == 'd' then
            for d = 0, 3 do
                local dx, dy = DIRS[d][1], DIRS[d][2]
                local inward = at(c.x - dx, c.y - dy)
                if at(c.x + dx, c.y + dy) == ' ' and inward ~= ' ' and inward ~= '#' then
                    entrances[#entrances + 1] = {x = c.x, y = c.y, dir = d}
                end
            end
        end
    end
    if #entrances == 0 then
        for _, c in ipairs(cells) do
            for d = 0, 3 do
                local dx, dy = DIRS[d][1], DIRS[d][2]
                if at(c.x + dx, c.y + dy) == ' ' then
                    entrances[#entrances + 1] = {x = c.x, y = c.y, dir = d, open = true}
                end
            end
        end
    end
    local fp = {}
    for _, c in ipairs(cells) do fp[key(c.x, c.y)] = true end
    local shell, sset = {}, {}
    for _, c in ipairs(cells) do
        for dy = -1, 1 do
            for dx = -1, 1 do
                local k = key(c.x + dx, c.y + dy)
                if not fp[k] and not sset[k] then
                    sset[k] = true
                    shell[#shell + 1] = {x = c.x + dx, y = c.y + dy}
                end
            end
        end
    end
    for _, e in ipairs(entrances) do
        local zone = {}
        for dy = -1, 1 do
            for dx = -1, 1 do
                local sx, sy = e.x + dx, e.y + dy
                if not fp[key(sx, sy)] then
                    local nearOther = false
                    for _, c in ipairs(cells) do
                        if not (c.x == e.x and c.y == e.y)
                            and math.abs(c.x - sx) <= 1 and math.abs(c.y - sy) <= 1 then
                            nearOther = true
                            break
                        end
                    end
                    if not nearOther then zone[key(sx, sy)] = true end
                end
            end
        end
        e.zone = zone
    end
    return {cells = cells, entrances = entrances, shell = shell, w = w, h = h}
end
M.analyse = analyse

-- For each door direction, the variant whose entrance faces that way with the
-- least depth. `s` = {name, grid (rows) or {floors={rows,...}}, weight, max}
local function prepStamp(s)
    local ground = s.grid.floors and s.grid.floors[1] or s.grid
    local floors = s.grid.floors and #s.grid.floors or 1
    local vs = {}
    for _, g in ipairs(transforms(ground)) do vs[#vs + 1] = analyse(g) end
    local byDir = {}
    for d = 0, 3 do
        local best
        for _, v in ipairs(vs) do
            for _, e in ipairs(v.entrances) do
                if e.dir == d then
                    local depth = (d == 0 or d == 2) and v.h or v.w
                    if not best or depth < best.depth then best = {v = v, e = e, depth = depth} end
                end
            end
        end
        byDir[d] = best
    end
    local plain = vs[1]
    local turned
    for _, v in ipairs(vs) do
        if v ~= plain and v.w == plain.h and v.h == plain.w then turned = v break end
    end
    return {name = s.name, weight = s.weight or 1, max = s.max or math.huge,
            byDir = byDir, plain = plain, turned = turned, floors = floors,
            grid = s.grid}
end
M.prepStamp = prepStamp

-- ---------------------------------------------------------------------------
-- the packer
-- claim: 0 free, 1 road, 2 room, 3 wall (room-owned rock), 4 margin (keeps
-- rooms apart; roads may cross), 5 road stub (reserved for a head), 6 statue on
-- road, 7 kept lane (no room body or wall; roads may cross)
-- ---------------------------------------------------------------------------

-- opts:
--   W, H            slab size
--   free(x, y)      true if the tile may be dug (inside the burrow, rock, not
--                   on the burrow's border ring)
--   existing(x, y)  optional: true if the tile is already dug floor (existing
--                   road; new roads may join it, and heads may start beside it)
--   preset          {main, side, surface, districts = {...}, second = {...},
--                   road = {...}}; districts entries are {name, weight, ...} or
--                   inline; see presets.lua
--   districts       table name -> district definition
--   seed            integer
--   prior           optional earlier result on the same slab (its claims,
--                   rooms, segments are the starting point)
--   yield           optional function called at safe points (frame pacing)
function M.pack(opts)
    local W, H, preset, seed = opts.W, opts.H, opts.preset, opts.seed or 1
    local yield = opts.yield or function() end
    local rng = RNG(seed * 7919 + 13)
    local mainW, sideW = preset.main or 1, preset.side or 1
    local surface = preset.surface and true or false
    local DISTRICTS = opts.districts or {}
    local prior = opts.prior
    local freeFn, existingFn = opts.free, opts.existing or function() return false end
    local function free(x, y)
        if x < 0 or y < 0 or x >= W or y >= H then return false end
        return freeFn(x, y)
    end
    local claim = prior and copyGrid(prior.claim, W, H) or newGrid(W, H, 0)
    local owner = prior and copyGrid(prior.owner, W, H) or newGrid(W, H, 0)
    -- existing dug floor inside the slab is road that new roads may join, at any distance
    local existingRoad = newGrid(W, H, false)
    if not prior then
        for y = 0, H - 1 do
            for x = 0, W - 1 do
                if existingFn(x, y) then claim[y][x] = 1; existingRoad[y][x] = true end
            end
        end
    end
    local function at(x, y)
        if x < 0 or y < 0 or x >= W or y >= H then return 9 end
        return claim[y][x]
    end
    local freeList = {}
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            if free(x, y) then freeList[#freeList + 1] = {x, y} end
        end
    end
    if #freeList == 0 then return nil end

    -- districts -----------------------------------------------------------
    local function slot(s)
        local alts = s.alts or {{grid = s.grid, weight = s.weight, max = s.max, setback = s.setback, name = s.name}}
        local out = {name = s.name, max = s.max or 1, weight = s.weight or 1, alts = {}}
        for _, a in ipairs(alts) do
            local p = prepStamp({name = a.name or s.name, grid = a.grid, weight = a.weight, max = a.max})
            out.alts[#out.alts + 1] = {name = a.name or s.name, weight = a.weight or 1,
                                       p = p, setback = a.setback or 0}
        end
        return out
    end
    local function buildTypes(list)
        local out = {}
        for _, d in ipairs(list or {}) do
            local base = d.stamps and d or (DISTRICTS[d.name] or {stamps = {}})
            local D = {name = d.name, weight = d.weight or 1,
                       margin = d.margin ~= nil and d.margin or (base.margin or 0),
                       maxLen = base.maxLen or 14, depth = base.depth or 12,
                       set = base.set and true or false, shared = base.shared and true or false,
                       stamps = {}, optional = {}}
            for _, s in ipairs(base.stamps or {}) do D.stamps[#D.stamps + 1] = slot(s) end
            for _, s in ipairs(base.optional or {}) do D.optional[#D.optional + 1] = slot(s) end
            out[#out + 1] = D
        end
        return out
    end
    local dtypes = buildTypes(preset.districts)
    local dtypes2 = buildTypes(preset.second or preset.districts)
    local roadPool = {}
    for _, s in ipairs(preset.road or {}) do
        roadPool[#roadPool + 1] = {name = s.name, weight = s.weight or 1, p = prepStamp(s)}
    end
    -- segments must be long enough for the widest hub to find clear frontage
    local frontNeed = 0
    for _, D in ipairs(dtypes) do
        local sl = D.stamps[1]
        if sl then
            for _, a in ipairs(sl.alts) do
                local w = math.max(a.p.plain.w, a.p.plain.h)
                frontNeed = math.max(frontNeed, w + 2 + D.margin + 2 * (mainW >> 1) + 1)
            end
        end
    end
    local minMain = math.max(6, frontNeed)
    local maxMain = math.max(22, 2 * frontNeed)
    local segStamps, plazaStamps = {}, {}
    for _, r in ipairs(roadPool) do
        local w, h = r.p.plain.w, r.p.plain.h
        if math.min(w, h) == mainW and math.max(w, h) > mainW then segStamps[#segStamps + 1] = r end
        if w == h and w > mainW then plazaStamps[#plazaStamps + 1] = r end
    end

    -- width geometry (valid for even widths: the extra tile sits on the +x/+y side)
    local function lo(w) return -((w - 1) >> 1) end
    local function hi(w) return w >> 1 end
    local function eo(w, sign) if sign > 0 then return hi(w) else return -lo(w) end end
    local function footprint(x, y, dir, w)
        local p = DIRS[(dir + 1) % 4]
        local qx, qy = math.abs(p[1]), math.abs(p[2])
        local out = {}
        for t = lo(w), hi(w) do out[#out + 1] = {x + qx * t, y + qy * t} end
        return out
    end
    local function haloOf(x, y, dir, w)
        local p = DIRS[(dir + 1) % 4]
        local qx, qy = math.abs(p[1]), math.abs(p[2])
        return {x + qx * (hi(w) + 1), y + qy * (hi(w) + 1)}, {x + qx * (lo(w) - 1), y + qy * (lo(w) - 1)}
    end
    local function sqCentre(seg)
        local dx, dy = DIRS[seg.dir][1], DIRS[seg.dir][2]
        local function back(sg) if sg > 0 then return hi(seg.w) else return -lo(seg.w) end end
        local cx = seg.x + dx * (seg.n - 1) - (dx ~= 0 and dx * back(dx) or 0)
        local cy = seg.y + dy * (seg.n - 1) - (dy ~= 0 and dy * back(dy) or 0)
        return cx, cy
    end

    -- boundary candidates: a diggable tile whose tile two behind is NOT
    -- diggable (the burrow edge, or existing floor), with an open run of
    -- main-road width ahead, scored by the free rock around the run
    local function boundaryHeads()
        local out = {}
        for _, p in ipairs(freeList) do
            local x, y = p[1], p[2]
            for d = 0, 3 do
                local dx, dy = DIRS[d][1], DIRS[d][2]
                -- a head beside the fort's floor must be the tile directly beside it, so the
                -- road actually meets the floor; a bare burrow edge counts two tiles behind
                local touches = existingFn(x - dx, y - dy)
                local behind = not touches and not free(x - dx * 2, y - dy * 2) and not existingFn(x - dx * 2, y - dy * 2)
                if behind or touches then
                    local q = DIRS[(d + 1) % 4]
                    local qx, qy = math.abs(q[1]), math.abs(q[2])
                    local run = 0
                    for i = 0, 39 do
                        local ok = true
                        for t = -((mainW - 1) >> 1), (mainW >> 1) do
                            local a, b = x + dx * i + qx * t, y + dy * i + qy * t
                            if not free(a, b) or claim[b][a] ~= 0 then ok = false break end
                        end
                        if not ok then break end
                        run = run + 1
                    end
                    if run >= 6 then
                        local area = 0
                        for i = 0, run - 1 do
                            for t = -10, 10 do
                                local a, b = x + dx * i + qx * t, y + dy * i + qy * t
                                if free(a, b) and claim[b][a] == 0 then area = area + 1 end
                            end
                        end
                        local score = area - math.abs(y - H / 2) * 0.05 - x * 0.02
                        if touches then score = score + 500 end -- touching the fort beats a bare edge
                        out[#out + 1] = {x = x, y = y, dir = d, run = run, score = score}
                    end
                end
            end
        end
        table.sort(out, function(p, q) return p.score > q.score end)
        return out
    end

    local priorRoads = false
    if prior then
        for _, sg in ipairs(prior.segments) do
            if sg.dir >= 0 and not sg.dead then priorRoads = true break end
        end
    end
    local entry, entryDir
    if not priorRoads then
        local c = boundaryHeads()[1]
        if not c then return nil end
        entry, entryDir = {c.x, c.y}, c.dir
    else
        entry = prior.entry
    end

    local rooms = prior and {table.unpack(prior.rooms)} or {}
    local districts = prior and {table.unpack(prior.districts)} or {}
    local segments = prior and {table.unpack(prior.segments)} or {}
    local stamps = prior and {table.unpack(prior.stamps)} or {}
    local joins, undone = 0, 0
    local count = {}
    for _, D in ipairs(dtypes) do count[D.name] = 0 end
    for _, D in ipairs(dtypes2) do count[D.name] = 0 end
    local placedN = 0
    local function nextDistrict(list, exclude)
        local wsum = 0
        for _, d in ipairs(list) do wsum = wsum + d.weight end
        local order = {}
        for _, d in ipairs(list) do
            if not exclude[d.name] then
                order[#order + 1] = {d = d, s = (d.weight * (placedN + 1) / wsum - count[d.name]) + (rng.next() - 0.5) * 0.6}
            end
        end
        table.sort(order, function(p, q) return p.s > q.s end)
        return order[1] and order[1].d or nil
    end
    local function snapshot()
        local cnt = {}
        for k, v in pairs(count) do cnt[k] = v end
        return {c = copyGrid(claim, W, H), o = copyGrid(owner, W, H), nR = #rooms, nD = #districts,
                nS = #stamps, nSeg = #segments, joins = joins, cnt = cnt, pn = placedN}
    end
    local function restore(sn)
        for y = 0, H - 1 do
            local cr, orow, sc, so = claim[y], owner[y], sn.c[y], sn.o[y]
            for x = 0, W - 1 do cr[x] = sc[x]; orow[x] = so[x] end
        end
        while #rooms > sn.nR do rooms[#rooms] = nil end
        while #districts > sn.nD do districts[#districts] = nil end
        while #stamps > sn.nS do stamps[#stamps] = nil end
        while #segments > sn.nSeg do segments[#segments] = nil end
        joins = sn.joins
        for k, v in pairs(sn.cnt) do count[k] = v end
        placedN = sn.pn
    end

    -- room placement primitives ------------------------------------------
    local function commitRoom(v, e, ax, ay, R, room, dIdx)
        local idx = #rooms + 1
        for _, c in ipairs(v.cells) do
            local x, y = ax + c.x, ay + c.y
            claim[y][x] = 2; owner[y][x] = idx
            room.cells[#room.cells + 1] = {x = x, y = y, ch = c.ch}
            if e and c.x == e.x and c.y == e.y then room.door = {x = x, y = y} end
        end
        for _, s in ipairs(v.shell) do
            if not (e and e.zone[key(s.x, s.y)]) then
                local x, y = ax + s.x, ay + s.y
                if x >= 0 and y >= 0 and x < W and y < H then
                    if claim[y][x] == 0 or claim[y][x] == 4 then claim[y][x] = surface and 4 or 3 end
                end
            end
        end
        for _, c in ipairs(v.cells) do
            for dy = -R, R do
                for dx = -R, R do
                    local x, y = ax + c.x + dx, ay + c.y + dy
                    if x >= 0 and y >= 0 and x < W and y < H and claim[y][x] == 0 then claim[y][x] = 4 end
                end
            end
        end
        room.district = dIdx
        rooms[#rooms + 1] = room
        return room
    end
    -- shareWith: owner id whose '#' walls this stamp's '#' walls may overlap (0 none, -1 any)
    local function fits(v, e, ax, ay, inside, shareWith)
        for _, c in ipairs(v.cells) do
            local x, y = ax + c.x, ay + c.y
            if not free(x, y) or not inside(x, y) then return false end
            local k = claim[y][x]
            local shared = false
            if k == 2 and c.ch == '#' and shareWith ~= 0 and (shareWith == -1 or owner[y][x] == shareWith) then
                local rm = rooms[owner[y][x]]
                if rm then
                    for _, q in ipairs(rm.cells) do
                        if q.x == x and q.y == y and q.ch == '#' then shared = true break end
                    end
                end
            end
            if not shared and k ~= 0 and not (surface and k == 4) then return false end
        end
        for _, s in ipairs(v.shell) do
            local x, y = ax + s.x, ay + s.y
            if x >= 0 and y >= 0 and x < W and y < H then
                local k = claim[y][x]
                local zoneOK = e and e.zone[key(s.x, s.y)]
                if k == 2 then
                    local shareOK = shareWith ~= 0 and (shareWith == -1 or owner[y][x] == shareWith)
                    if not zoneOK and not shareOK then return false end
                end
                if k == 6 or k == 7 then return false end
                if k == 5 and not zoneOK then return false end
                if k == 1 and not surface and not zoneOK then return false end
            end
        end
        return true
    end

    local clusterAt -- forward

    -- districts along one side of a segment ------------------------------
    local function packSide(seg, side, list, gaps, deadEnd)
        local dx, dy = DIRS[seg.dir][1], DIRS[seg.dir][2]
        local pd = side > 0 and (seg.dir + 1) % 4 or (seg.dir + 3) % 4
        local px, py = DIRS[pd][1], DIRS[pd][2]
        local half = eo(seg.w, px + py)
        local doorDir = (pd + 2) % 4
        local i = (seg.parent == nil and seg.n >= minMain + 2 * seg.w) and seg.w or 0
        local D, used, capsLeft, dIdx = nil, 0, nil, -1
        local tried = {}
        local function triedCount() local n = 0 for _ in pairs(tried) do n = n + 1 end return n end
        local iEnd = (seg.joined or deadEnd) and seg.n or seg.n - seg.w
        local function doorAt(ii, setback)
            local cx, cy = seg.x + dx * ii, seg.y + dy * ii
            local fx, fy = cx + px * half, cy + py * half
            local doorX, doorY = cx + px * (half + 1 + setback), cy + py * (half + 1 + setback)
            for t = 1, setback do
                local x, y = cx + px * (half + t), cy + py * (half + t)
                if not free(x, y) or not (claim[y][x] == 0 or claim[y][x] == 4) then return nil end
            end
            if at(fx, fy) ~= 1 or not free(doorX, doorY) then return nil end
            local k = claim[doorY][doorX]
            if not (k == 0 or (surface and k == 4)) then return nil end
            return {cx = cx, cy = cy, fx = fx, fy = fy, doorX = doorX, doorY = doorY}
        end
        while i < iEnd do
            if not D then
                D = nextDistrict(list, tried)
                if not D then break end
                tried[D.name] = true
                used, capsLeft, dIdx = 0, {}, -1
                for _, sl in ipairs(D.stamps) do
                    for _, a in ipairs(sl.alts) do capsLeft[a.name] = a.p.max end
                end
            end
            local advanced = 0
            if D.set then
                local pos = doorAt(i, 0)
                if not pos then
                    i = i + 1
                else
                    local r = clusterAt(D, pos.doorX, pos.doorY, doorDir, seg, dIdx)
                    if r then
                        if dIdx < 0 then
                            dIdx = #districts + 1
                            districts[dIdx] = {type = D, rooms = {}}
                            count[D.name] = count[D.name] + 1
                            placedN = placedN + 1
                        end
                        for _, rm in ipairs(r.rooms) do
                            rm.district = dIdx
                            local dr = districts[dIdx].rooms
                            dr[#dr + 1] = rm
                        end
                        advanced = r.extent + 1 + D.margin
                    else
                        D = nil
                        if triedCount() >= #list then tried = {}; i = i + 1 end
                    end
                end
            else
                local cand = {}
                for _, sl in ipairs(D.stamps) do
                    for _, a in ipairs(sl.alts) do
                        if (capsLeft[a.name] or 0) > 0 then cand[#cand + 1] = a end
                    end
                end
                if #cand == 0 then
                    D = nil
                else
                    local s = rng.pick(cand, function(x) return x.weight end)
                    local setback = surface and (s.setback or 0) or 0
                    local b = s.p.byDir[doorDir]
                    local pos = doorAt(i, setback)
                    if b and pos then
                        local v, e = b.v, b.e
                        local ax, ay = pos.doorX - e.x, pos.doorY - e.y
                        local cx, cy = pos.cx, pos.cy
                        local function inside(x, y)
                            return math.abs((x - cx) * px + (y - cy) * py) <= D.depth + half + setback
                        end
                        if fits(v, e, ax, ay, inside, D.shared and -1 or 0) then
                            local room = {stamp = s.name, cells = {}, door = nil,
                                          front = {x = pos.fx, y = pos.fy}, floors = s.p.floors, grid = s.p.grid}
                            if dIdx < 0 then
                                dIdx = #districts + 1
                                districts[dIdx] = {type = D, rooms = {}}
                                count[D.name] = count[D.name] + 1
                                placedN = placedN + 1
                            end
                            for t = 1, setback do
                                local x, y = cx + px * (half + t), cy + py * (half + t)
                                claim[y][x] = 1
                            end
                            commitRoom(v, e, ax, ay, D.shared and 0 or 1 + D.margin, room, dIdx)
                            local dr = districts[dIdx].rooms
                            dr[#dr + 1] = room
                            capsLeft[s.name] = capsLeft[s.name] - 1
                            local extent = (pd == 1 or pd == 3) and v.h or v.w
                            advanced = extent + (D.shared and -1 or 1) + D.margin
                        end
                    end
                end
            end
            if D and advanced > 0 then
                i = i + advanced
                used = used + advanced
                local capped = true
                for _, sl in ipairs(D.stamps) do
                    for _, a in ipairs(sl.alts) do
                        if a.p.max == math.huge or (capsLeft[a.name] or 0) > 0 then capped = false end
                    end
                end
                if used >= D.maxLen or capped or D.set then
                    D = nil
                    tried = {}
                    if gaps and seg.level < 3 then i = i + sideW + 1 end -- room for a side street between districts
                end
            elseif D and advanced == 0 and not D.set then
                i = i + 1
            end
        end
    end

    -- a suite: hub door at (doorX,doorY) facing doorDir; every other room
    -- shares a wall with a placed room (its door replaces a tile of the
    -- parent's rock wall underground; on the surface its built wall row
    -- coincides with the parent's, door in it)
    clusterAt = function(D, doorX, doorY, doorDir, seg, dIdx)
        local pd = (doorDir + 2) % 4
        local px, py = DIRS[pd][1], DIRS[pd][2]
        local dx, dy = DIRS[seg.dir][1], DIRS[seg.dir][2]
        local function inside(x, y)
            local dep = (x - doorX) * px + (y - doorY) * py
            local al = (x - doorX) * dx + (y - doorY) * dy
            return dep >= 0 and dep <= D.depth and al >= -8 and al <= D.depth + 8
        end
        local function pickAlt(sl) return rng.pick(sl.alts, function(a) return a.weight end) end
        local sn = snapshot()
        local placed = {}
        local hub = pickAlt(D.stamps[1])
        local b = hub.p.byDir[doorDir]
        if not b then return nil end
        local ax, ay = doorX - b.e.x, doorY - b.e.y
        if not fits(b.v, b.e, ax, ay, inside, 0) then return nil end
        local hubRoom = {stamp = hub.name, cells = {}, door = nil, front = {x = doorX - px, y = doorY - py},
                         hub = true, floors = hub.p.floors, grid = hub.p.grid}
        commitRoom(b.v, b.e, ax, ay, 1, hubRoom, dIdx)
        placed[#placed + 1] = hubRoom
        local function bbox()
            local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
            for _, r in ipairs(placed) do
                for _, c in ipairs(r.cells) do
                    x0, y0 = math.min(x0, c.x), math.min(y0, c.y)
                    x1, y1 = math.max(x1, c.x), math.max(y1, c.y)
                end
            end
            return x0, y0, x1, y1
        end
        local function attach(stamp)
            local cands = {}
            local bx0, by0, bx1, by1 = bbox()
            for _, parent in ipairs(placed) do
                local pidx
                for i, r in ipairs(rooms) do if r == parent then pidx = i break end end
                for _, pc in ipairs(parent.cells) do
                    if pc.ch ~= 'd' then
                        for d = 0, 3 do
                            local tx, ty, ok = nil, nil, true
                            if surface then
                                if pc.ch ~= '#' then ok = false
                                else
                                    local bx, by = pc.x - DIRS[d][1], pc.y - DIRS[d][2]
                                    local back
                                    for _, q in ipairs(parent.cells) do
                                        if q.x == bx and q.y == by then back = q break end
                                    end
                                    if not back or back.ch == '#' then ok = false end
                                    tx, ty = pc.x, pc.y
                                end
                            else
                                if pc.ch == '#' then ok = false
                                else
                                    tx, ty = pc.x + DIRS[d][1], pc.y + DIRS[d][2]
                                    if not free(tx, ty) or not inside(tx, ty) or claim[ty][tx] ~= 3 then ok = false end
                                end
                            end
                            if ok then
                                local clean = true
                                for ey = -1, 1 do
                                    for ex = -1, 1 do
                                        local x, y = tx + ex, ty + ey
                                        if at(x, y) == 2 and owner[y][x] ~= pidx then clean = false end
                                    end
                                end
                                local bb2 = clean and stamp.p.byDir[(d + 2) % 4] or nil
                                if bb2 then
                                    local v, e = bb2.v, bb2.e
                                    local ax2, ay2 = tx - e.x, ty - e.y
                                    local saved, savedO = claim[ty][tx], owner[ty][tx]
                                    claim[ty][tx] = 0
                                    local fit = fits(v, e, ax2, ay2, inside, surface and pidx or 0)
                                    claim[ty][tx], owner[ty][tx] = saved, savedO
                                    if fit then
                                        local nx0, ny0, nx1, ny1 = bx0, by0, bx1, by1
                                        for _, c in ipairs(v.cells) do
                                            nx0, ny0 = math.min(nx0, ax2 + c.x), math.min(ny0, ay2 + c.y)
                                            nx1, ny1 = math.max(nx1, ax2 + c.x), math.max(ny1, ay2 + c.y)
                                        end
                                        local w, hh = nx1 - nx0 + 1, ny1 - ny0 + 1
                                        cands[#cands + 1] = {score = math.max(w, hh) * 1000 + w * hh + rng.next() * 0.5,
                                                             v = v, e = e, ax = ax2, ay = ay2, tx = tx, ty = ty, parent = parent}
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if #cands == 0 then return false end
            table.sort(cands, function(p, q) return p.score < q.score end)
            local c = cands[1]
            claim[c.ty][c.tx] = 0
            local room = {stamp = stamp.name, cells = {}, door = nil, front = nil,
                          parent = c.parent.stamp, floors = stamp.p.floors, grid = stamp.p.grid}
            commitRoom(c.v, c.e, c.ax, c.ay, 1, room, dIdx)
            placed[#placed + 1] = room
            return true
        end
        for si = 2, #D.stamps do
            if not attach(pickAlt(D.stamps[si])) then restore(sn) return nil end
        end
        for _, sl in ipairs(D.optional) do
            local n = rng.int(sl.max + 1)
            for _ = 1, n do attach(pickAlt(sl)) end
        end
        local bx0, by0, bx1, by1 = bbox()
        local R = D.margin
        for y = by0 - 1 - R, by1 + 1 + R do
            for x = bx0 - 1 - R, bx1 + 1 + R do
                if x >= 0 and y >= 0 and x < W and y < H and claim[y][x] == 0 then claim[y][x] = 4 end
            end
        end
        local extent = 0
        for _, r in ipairs(placed) do
            for _, c in ipairs(r.cells) do
                extent = math.max(extent, (c.x - doorX) * dx + (c.y - doorY) * dy)
            end
        end
        return {rooms = placed, extent = extent}
    end

    -- road laying ----------------------------------------------------------
    local lastBlock = ''
    local function laySegment(head, want)
        local x, y, dir, w = head.x, head.y, head.dir, head.w
        local half = w >> 1
        local dx, dy = DIRS[dir][1], DIRS[dir][2]
        local own = head.stub or {}
        local n, joined = 0, false
        local limit = head.join and want or want + half
        for i = 0, limit - 1 do
            local cx, cy = x + dx * i, y + dy * i
            local f = footprint(cx, cy, dir, w)
            local bad, road = false, 0
            for _, t in ipairs(f) do
                local a, b = t[1], t[2]
                if not free(a, b) then bad = true break end
                local k = claim[b][a]
                if k == 2 or k == 3 or k == 6 or (k == 5 and not own[key(a, b)]) then bad = true break end
                if k == 1 then road = road + 1 end
            end
            if bad then break end
            if road > 0 then
                if road == #f and i >= head.minLen and not head.noJoin then joined = true end
                break
            end
            local h1, h2 = haloOf(cx, cy, dir, w)
            local hl, hr = at(h1[1], h1[2]), at(h2[1], h2[2])
            if hl == 1 or hr == 1 or hl == 6 or hr == 6 then break end
            n = i + 1
        end
        if head.join and n == want then joined = true end
        if joined then
            if n < head.minLen then return nil end
        else
            if n < head.minLen + half then return nil end
        end
        local seg = {x = x, y = y, dir = dir, w = w, n = n, tiles = {}, joined = joined, level = head.level,
                     children = 0, rooms = 0, connector = head.connector and true or false,
                     parent = head.parent, stamps = {}}
        for i = 0, n - 1 do
            for _, t in ipairs(footprint(x + dx * i, y + dy * i, dir, w)) do
                claim[t[2]][t[1]] = 1
                seg.tiles[#seg.tiles + 1] = {t[1], t[2]}
            end
        end
        for k in pairs(own) do
            local a, b = unkey(k)
            if claim[b][a] == 5 then claim[b][a] = 0 end
        end
        if joined then joins = joins + 1 end
        return seg
    end
    local function layRoadStamp(v, ax, ay, name, onRoadOnly)
        local cells = {}
        for _, c in ipairs(v.cells) do
            local x, y = ax + c.x, ay + c.y
            if not free(x, y) then return nil end
            local k = claim[y][x]
            if k ~= 1 and (onRoadOnly or (k ~= 0 and k ~= 4 and k ~= 7)) then return nil end
            cells[#cells + 1] = {x = x, y = y, ch = c.ch}
        end
        for _, s in ipairs(v.shell) do
            local k = at(ax + s.x, ay + s.y)
            if k == 2 or k == 3 then return nil end
        end
        for _, c in ipairs(cells) do
            claim[c.y][c.x] = (c.ch == 's' or c.ch == 'x') and 6 or 1
        end
        local st = {stamp = name, cells = cells, plaza = true}
        stamps[#stamps + 1] = st
        return st
    end
    -- reserve a straight continuation from (hx,hy) heading nd at width w
    local function reserve(hx, hy, nd, w, level, budget, parent, minLen, keep)
        lastBlock = ''
        if w == mainW then minLen = math.max(minLen, minMain) end
        local ndx, ndy = DIRS[nd][1], DIRS[nd][2]
        local nh = w >> 1
        local upper = (w == mainW) and maxMain or (w > 1 and 22 or 16)
        local want = minLen + rng.int(math.max(1, upper - minLen))
        local stub, got, join = {}, 0, false
        for t = 0, want + nh - 1 do
            local ok, road, rock, existingHit = true, 0, false, false
            local f = footprint(hx + ndx * t, hy + ndy * t, nd, w)
            for _, tt in ipairs(f) do
                local a, b = tt[1], tt[2]
                local k = at(a, b)
                if not free(a, b) then ok = false; rock = true
                elseif k ~= 0 and k ~= 4 and k ~= 7 and k ~= 1 then ok = false end
                if k == 1 then
                    road = road + 1
                    if existingRoad[b] and existingRoad[b][a] then existingHit = true end
                end
            end
            if ok and road > 0 then
                -- a planned road is joined only after a proper run; the fort's own floor at any length
                if road == #f and (t >= minLen or (existingHit and t >= 1)) then join = true end
                break
            end
            local h1, h2 = haloOf(hx + ndx * t, hy + ndy * t, nd, w)
            local hl, hr = at(h1[1], h1[2]), at(h2[1], h2[2])
            if not ok or hl == 1 or hr == 1 or hl == 6 or hr == 6 then
                lastBlock = rock and 'rock' or 'claim'
                break
            end
            for _, tt in ipairs(f) do stub[key(tt[1], tt[2])] = true end
            got = t + 1
        end
        local floor = math.max(3, w + 2)
        local tooShort = join and got < 1 or (not join and got < floor + nh)
        if tooShort then
            -- at a road end keep the first tiles of the lane clear so a later plan can grow through it
            if keep then
                local t = 0
                for k in pairs(stub) do
                    if t >= 3 * w then break end
                    t = t + 1
                    local a, b = unkey(k)
                    if claim[b][a] == 0 or claim[b][a] == 4 then claim[b][a] = 7 end
                end
            end
            return nil
        end
        for k in pairs(stub) do
            local a, b = unkey(k)
            claim[b][a] = 5
        end
        local laid = join and got or math.min(want, got - nh)
        return {x = hx, y = hy, dir = nd, w = w, level = level, minLen = math.min(minLen, laid),
                want = laid, join = join, budget = budget, parent = parent, stub = stub}
    end
    local function release(head)
        if head and head.stub then
            for k in pairs(head.stub) do
                local a, b = unkey(k)
                if claim[b][a] == 5 then claim[b][a] = 0 end
            end
        end
    end

    -- growth ----------------------------------------------------------------
    local heads = {}
    -- seed heads from an existing, connected network: every segment's end
    -- square (and a root's start square) and every gap along it
    local function seedFrom(segList)
        local added = 0
        local ownerOf = {}
        for _, sg in ipairs(segments) do
            if not sg.dead then
                for _, t in ipairs(sg.tiles) do ownerOf[key(t[1], t[2])] = sg end
            end
        end
        local touched
        local function pastRoad(hx, hy, nd, w)
            local px, py = DIRS[nd][1], DIRS[nd][2]
            touched = nil
            for t = 0, 7 do
                local f = footprint(hx + px * t, hy + py * t, nd, w)
                local hit
                for _, tt in ipairs(f) do
                    local k = at(tt[1], tt[2])
                    if k == 1 or k == 6 then hit = tt break end
                end
                if not hit then return hx + px * t, hy + py * t end
                touched = ownerOf[key(hit[1], hit[2])] or touched
            end
            return nil
        end
        local function tryW(hx, hy, nd, w, minLen, parent)
            local h2
            local sx, sy = pastRoad(hx, hy, nd, w)
            if sx then h2 = reserve(sx, sy, nd, w, 0, 40, touched or parent, minLen, false) end
            if not h2 and (not sx or lastBlock == 'rock') then
                for cw = w - 1, 1, -1 do
                    local tx, ty = pastRoad(hx, hy, nd, cw)
                    if tx then
                        h2 = reserve(tx, ty, nd, cw, 0, 40, touched or parent, cw > 1 and 4 or 3, false)
                        if h2 then h2.connector = true; h2.connDepth = 1 break end
                    end
                end
            end
            if h2 then heads[#heads + 1] = h2; added = added + 1 end
        end
        for _, seg in ipairs(segList) do
            if seg.dir >= 0 and not seg.dead then
                local dx, dy = DIRS[seg.dir][1], DIRS[seg.dir][2]
                local ecx, ecy = sqCentre(seg)
                if not seg.joined then
                    for _, nd in ipairs({seg.dir, (seg.dir + 1) % 4, (seg.dir + 3) % 4}) do
                        local px, py = DIRS[nd][1], DIRS[nd][2]
                        local w = (nd == seg.dir) and math.max(seg.w, seg.connector and mainW or 0) or mainW
                        local ed = eo(seg.w, px + py)
                        tryW(ecx + px * (ed + 1), ecy + py * (ed + 1), nd, w, w > 1 and 6 or 4, seg)
                    end
                end
                if seg.parent == nil then
                    local back = (seg.dir + 2) % 4
                    local scx = seg.x - (dx > 0 and lo(seg.w) or dx < 0 and hi(seg.w) or 0)
                    local scy = seg.y - (dy > 0 and lo(seg.w) or dy < 0 and hi(seg.w) or 0)
                    for _, nd in ipairs({back, (seg.dir + 1) % 4, (seg.dir + 3) % 4}) do
                        local px, py = DIRS[nd][1], DIRS[nd][2]
                        local w = (nd == back) and math.max(seg.w, seg.connector and mainW or 0) or mainW
                        local ed = eo(seg.w, px + py)
                        tryW(scx + px * (ed + 1), scy + py * (ed + 1), nd, w, w > 1 and 6 or 4, seg)
                    end
                end
                for _, sd in ipairs({1, -1}) do
                    local pd = sd > 0 and (seg.dir + 1) % 4 or (seg.dir + 3) % 4
                    local px, py = DIRS[pd][1], DIRS[pd][2]
                    local ed = eo(seg.w, px + py)
                    local last = -99
                    for i = 2, seg.n - seg.w - 3 do
                        if i - last >= 6 then
                            local before = #heads
                            tryW(seg.x + dx * i + px * (ed + 1), seg.y + dy * i + py * (ed + 1), pd, sideW, sideW > 1 and 6 or 4, seg)
                            if #heads > before then last = i end
                        end
                    end
                end
            end
        end
        return added
    end
    if not priorRoads then
        heads[1] = {x = entry[1], y = entry[2], dir = entryDir, w = mainW, level = 0, minLen = minMain, budget = 40}
        claim[entry[2]][entry[1]] = 0
    else
        seedFrom(prior.segments)
    end

    local guard, phase = 0, 0
    while (#heads > 0 or phase == 0) and guard < 3000 do
        guard = guard + 1
        if #heads == 0 then
            if phase >= 2 then break end
            phase = phase + 1
            seedFrom(segments)
            if #heads == 0 then break end
        end
        if guard % 8 == 0 then yield() end
        local head = table.remove(heads, 1)
        local sn = snapshot()
        local upper = (head.w == mainW) and maxMain or (head.w > 1 and 22 or 16)
        local want = head.want or (head.minLen + rng.int(math.max(1, upper - head.minLen)))
        local seg = laySegment(head, want)
        if seg then
            segments[#segments + 1] = seg
            local dx, dy = DIRS[seg.dir][1], DIRS[seg.dir][2]
            local ecx, ecy = sqCentre(seg)
            local ends = {}
            if not seg.joined and head.budget > 0 then
                if head.level <= 1 then ends = {'S', 'L', 'R'}
                else ends = {'S', rng.next() < 0.5 and 'L' or 'R'} end
            end
            local plazaR = 0
            if not seg.connector and #ends >= 2 and #plazaStamps > 0 and rng.next() < 0.6 then
                local ps = rng.pick(plazaStamps, function(s) return s.weight end)
                local v = ps.p.plain
                local r = v.w >> 1
                local st = layRoadStamp(v, ecx - r, ecy - r, ps.name, false)
                if st then plazaR = r; seg.stamps[#seg.stamps + 1] = st end
            end
            if not seg.connector and #segStamps > 0 and seg.n >= 15 and rng.next() < 0.5 then
                local ss = rng.pick(segStamps, function(s) return s.weight end)
                local v
                if seg.dir == 1 or seg.dir == 3 then
                    v = ss.p.plain.w >= ss.p.plain.h and ss.p.plain or ss.p.turned
                else
                    v = ss.p.plain.h >= ss.p.plain.w and ss.p.plain or ss.p.turned
                end
                if v then
                    local len = math.max(v.w, v.h)
                    local half = seg.w >> 1
                    local start = (seg.n - half - len) // 2
                    if start >= 1 then
                        local cx, cy = seg.x + dx * start, seg.y + dy * start
                        local ax = math.min(cx, cx + dx * (len - 1)) + (dx == 0 and lo(seg.w) or 0)
                        local ay = math.min(cy, cy + dy * (len - 1)) + (dy == 0 and lo(seg.w) or 0)
                        local st = layRoadStamp(v, ax, ay, ss.name, true)
                        if st then seg.stamps[#seg.stamps + 1] = st end
                    end
                end
            end
            -- continuation heads, reserved for their whole length before rooms go down
            local newHeads = {}
            local function tryEnd(e)
                local nd, hx, hy, w
                if e == 'S' then
                    nd = seg.dir
                    w = seg.connector and mainW or seg.w
                    local R = plazaR > 0 and plazaR or eo(seg.w, dx + dy)
                    hx, hy = ecx + dx * (R + 1), ecy + dy * (R + 1)
                else
                    nd = (e == 'L') and (seg.dir + 3) % 4 or (seg.dir + 1) % 4
                    w = (head.level == 0 and #ends == 1) and mainW or (rng.next() < 0.5 and mainW or sideW)
                    if seg.w == sideW then w = sideW end
                    local px, py = DIRS[nd][1], DIRS[nd][2]
                    local R = plazaR > 0 and plazaR or eo(seg.w, px + py)
                    hx, hy = ecx + px * (R + 1), ecy + py * (R + 1)
                end
                local h2 = reserve(hx, hy, nd, w, head.level + (w < seg.w and 1 or 0), head.budget - 1, seg,
                                   w > 1 and 6 or 4, e == 'S')
                -- a throat too narrow for the road: push a narrower connector through it
                if not h2 and lastBlock == 'rock' and (head.connDepth or 0) < 3 then
                    for cw = w - 1, 1, -1 do
                        h2 = reserve(hx, hy, nd, cw, head.level, head.budget - 1, seg, cw > 1 and 4 or 3, false)
                        if h2 then h2.connector = true; h2.connDepth = (head.connDepth or 0) + 1 break end
                    end
                end
                if h2 then newHeads[#newHeads + 1] = h2 end
                return h2 ~= nil
            end
            for _, e in ipairs(rng.shuffle({table.unpack(ends)})) do tryEnd(e) end
            -- districts along both sides
            if not seg.connector then
                for _, s in ipairs({1, -1}) do packSide(seg, s, dtypes, true, #newHeads == 0) end
            end
            local function roomsOn()
                local n = 0
                local tileSet = {}
                for _, t in ipairs(seg.tiles) do tileSet[key(t[1], t[2])] = true end
                for _, r in ipairs(rooms) do
                    if r.front and tileSet[key(r.front.x, r.front.y)] then n = n + 1 end
                end
                return n
            end
            seg.rooms = roomsOn()
            if seg.rooms == 0 and not seg.connector and preset.second then
                for _, s in ipairs({1, -1}) do packSide(seg, s, dtypes2, true, #newHeads == 0) end
                seg.rooms = roomsOn()
            end
            -- side streets: found in the gaps the districts left
            if head.level < 3 and seg.n >= 8 then
                for _, s in ipairs({1, -1}) do
                    local pd = s > 0 and (seg.dir + 1) % 4 or (seg.dir + 3) % 4
                    local px, py = DIRS[pd][1], DIRS[pd][2]
                    local ed = eo(seg.w, px + py)
                    local last = -99
                    for i = 2, seg.n - seg.w - 3 do
                        if i - last >= 6 then
                            local hx, hy = seg.x + dx * i + px * (ed + 1), seg.y + dy * i + py * (ed + 1)
                            local h2 = reserve(hx, hy, pd, sideW, head.level + 1, head.budget - 1, seg, 4, false)
                            if not h2 and lastBlock == 'rock' and (head.connDepth or 0) < 3 then
                                for cw = sideW - 1, 1, -1 do
                                    h2 = reserve(hx, hy, pd, cw, head.level + 1, head.budget - 1, seg, cw > 1 and 4 or 3, false)
                                    if h2 then h2.connector = true; h2.connDepth = (head.connDepth or 0) + 1 break end
                                end
                            end
                            if h2 then newHeads[#newHeads + 1] = h2; last = i end
                        end
                    end
                end
            end
            local refuse = false
            if seg.rooms == 0 and not seg.connector then
                -- a cave passage (flanks too shallow for any room) may stay as a
                -- connector if it leads somewhere; space that rooms declined may not
                local depthSum, flank, rock = 0, 0, 0
                for i = 0, seg.n - 1 do
                    for _, sd in ipairs({1, -1}) do
                        local pd = sd > 0 and (seg.dir + 1) % 4 or (seg.dir + 3) % 4
                        local px, py = DIRS[pd][1], DIRS[pd][2]
                        local e = eo(seg.w, px + py)
                        local dpt = 0
                        for t = 1, 10 do
                            if not free(seg.x + dx * i + px * (e + t), seg.y + dy * i + py * (e + t)) then break end
                            dpt = dpt + 1
                        end
                        if dpt == 0 then rock = rock + 1 end
                        depthSum = depthSum + dpt
                        flank = flank + 1
                    end
                end
                local passage = depthSum / flank < 5 or rock >= flank * 0.5
                if not passage or #newHeads == 0 then refuse = true else seg.connector = true end
            end
            if refuse then
                restore(sn)
                for _, h2 in ipairs(newHeads) do release(h2) end
                release(head)
                undone = undone + 1
            else
                if head.parent then head.parent.children = head.parent.children + 1 end
                for _, h2 in ipairs(newHeads) do heads[#heads + 1] = h2 end
            end
        else
            release(head)
        end
    end

    -- connectors that led nowhere are removed, with their stamps
    local connectorsCut = 0
    local changed = true
    while changed do
        changed = false
        for _, seg in ipairs(segments) do
            if not seg.dead and seg.connector then
                local hasChild = false
                for _, k in ipairs(segments) do
                    if not k.dead and k.parent == seg then hasChild = true break end
                end
                if not hasChild then
                    seg.dead = true
                    for _, t in ipairs(seg.tiles) do
                        local k = claim[t[2]][t[1]]
                        if k == 1 or k == 6 then claim[t[2]][t[1]] = 0 end
                    end
                    for _, st in ipairs(seg.stamps) do
                        for _, c in ipairs(st.cells) do
                            local k = claim[c.y][c.x]
                            if k == 1 or k == 6 then claim[c.y][c.x] = 0 end
                        end
                        for i, s2 in ipairs(stamps) do if s2 == st then table.remove(stamps, i) break end end
                    end
                    changed = true
                    connectorsCut = connectorsCut + 1
                end
            end
        end
    end
    for i = #segments, 1, -1 do if segments[i].dead then table.remove(segments, i) end end
    yield()

    -- second pass: walk every road edge again with the fill list
    local firstPassRooms = #rooms
    for _, seg in ipairs(segments) do
        if seg.dir >= 0 and not seg.dead then
            local ecx, ecy = sqCentre(seg)
            local dead = not seg.joined
            if dead then
                for d = 0, 3 do
                    local px, py = DIRS[d][1], DIRS[d][2]
                    local e = eo(seg.w, px + py)
                    if at(ecx + px * (e + 1), ecy + py * (e + 1)) == 1 then dead = false end
                end
            end
            for _, s in ipairs({1, -1}) do packSide(seg, s, dtypes2, false, dead) end
        end
    end
    local filled = #rooms - firstPassRooms

    -- designations: room floors smooth, room walls engrave, road floors smooth,
    -- rock beside a road that no room owns smooth
    local wallKind = newGrid(W, H, 0)
    local desig = {smoothFloor = 0, engrave = 0, smoothWall = 0}
    local inB = opts.inBurrow or function(x, y) return free(x, y) end
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local k = claim[y][x]
            if k == 1 or k == 6 or k == 2 then desig.smoothFloor = desig.smoothFloor + 1
            elseif k == 3 then wallKind[y][x] = 1; desig.engrave = desig.engrave + 1
            elseif inB(x, y) then
                local nearRoad = false
                for ey = -1, 1 do
                    for ex = -1, 1 do
                        local kk = at(x + ex, y + ey)
                        if kk == 1 or kk == 6 then nearRoad = true end
                    end
                end
                if nearRoad then wallKind[y][x] = 2; desig.smoothWall = desig.smoothWall + 1 end
            end
        end
    end
    local roadTiles, roomTiles = 0, 0
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local k = claim[y][x]
            if k == 1 or k == 6 then roadTiles = roadTiles + 1 elseif k == 2 then roomTiles = roomTiles + 1 end
        end
    end
    local per = {}
    for _, D in ipairs(districts) do per[D.type.name] = (per[D.type.name] or 0) + 1 end
    local connectors = 0
    for _, s in ipairs(segments) do if s.connector then connectors = connectors + 1 end end
    return {
        rooms = rooms, stamps = stamps, segments = segments, districts = districts,
        claim = claim, owner = owner, wallKind = wallKind, entry = entry, W = W, H = H,
        stats = {burrow = #freeList, roadTiles = roadTiles, roomTiles = roomTiles, per = per,
                 joins = joins, undone = undone, filled = filled, connectors = connectors,
                 connectorsCut = connectorsCut, stampsN = #stamps, segN = #segments, desig = desig},
    }
end

-- DFHack's reqscript hands back a script's globals, a plain `dofile` its return value: serve both
pack, RNG, newGrid, analyse, prepStamp, DIRS, key = M.pack, M.RNG, M.newGrid, M.analyse, M.prepStamp, M.DIRS, M.key
return M
