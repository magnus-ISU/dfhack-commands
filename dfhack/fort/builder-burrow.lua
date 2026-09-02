-- Turn a burrow into a district: pick a burrow and a preset, roads and rooms
-- are planned inside it and every blueprint is started at once.
--@module = true
--[[
fort/builder-burrow

Opens a picker: a burrow, a preset (hovels, housing, luxury housing, noble
quarters, tombs, temples, guildhalls, ...) and when to build. Confirming plans
the burrow on the z-level being looked at (or the level where the burrow has the
most tiles): roads grow from wherever the burrow touches the fort's dug floor,
one segment at a time; each segment is dressed with hallway pieces and lined
with districts as it is laid; a road with nothing along it is refused; a second
pass fills leftover frontage. Then every room, road and hallway piece is started
as a `fort/quickfort` job, so digging, smoothing, engraving and furniture
sequence themselves per tile as the miners get to them.

    fort/builder-burrow            open the picker
    fort/builder-burrow status     the plans stored for this fort

BUILD WHEN
  Only "apply now" exists yet: every blueprint of the plan is started the moment
  you confirm. Gating on a need (a noble without rooms, a house short) is the next
  step and the dropdown is already there for it.

WHAT IT NEEDS FROM THE BURROW
  The burrow marks rock the tool may dig. Its outermost ring is never dug, so it
  becomes wall, and the tool only starts where the burrow touches dug floor: a
  corridor of yours running up to the burrow, or a burrow painted around an
  existing road. Existing floor inside the burrow counts as road that new roads
  may join. Nothing outside the burrow is ever dug.

  One z-level per plan. Multi-floor blueprints (the town presets) are not
  applied yet; the shipped presets are all rock-cut, single level.

CODES
  Stamps use quickfort's build codes. Two DF pieces have no quickfort code, so
  an altar is placed as a statue and a bookcase as a cabinet; pedestals are
  display furniture. Change them in internal/builder-burrow/presets.lua.

The design is burrow-stamper-plan.md; the packer is a port of
prototypes/burrow-stamper/sandbox.html and lives in internal/builder-burrow/.
]]

local gui = require('gui')
local widgets = require('gui.widgets')

local packer = reqscript('internal/builder-burrow/packer')
local presets = reqscript('internal/builder-burrow/presets')
local qf = reqscript('fort/quickfort')

local GLOBAL_KEY = 'builder-burrow'

-- ---------------------------------------------------------------------------
-- map reading
-- ---------------------------------------------------------------------------

local function tile_shape(pos)
    local tt = dfhack.maps.getTileType(pos)
    if not tt then return nil end
    return df.tiletype.attrs[tt].shape
end

-- rock that may be dug into a room or a road
local function is_rock(pos)
    local shape = tile_shape(pos)
    if not shape then return false end
    local basic = df.tiletype_shape.attrs[shape].basic_shape
    if basic ~= df.tiletype_shape_basic.Wall then return false end
    local tt = dfhack.maps.getTileType(pos)
    local mat = df.tiletype.attrs[tt].material
    -- constructed walls and trees are not rock to carve
    if mat == df.tiletype_material.CONSTRUCTION or mat == df.tiletype_material.TREE then return false end
    local ok, b = pcall(dfhack.buildings.findAtTile, pos)
    if ok and b then return false end
    return true
end

-- dug floor a dwarf could walk: where roads start and what they may join
local function is_floor(pos)
    local shape = tile_shape(pos)
    if not shape then return false end
    local basic = df.tiletype_shape.attrs[shape].basic_shape
    return basic == df.tiletype_shape_basic.Floor or basic == df.tiletype_shape_basic.Ramp
        or basic == df.tiletype_shape_basic.Stair
end

-- ---------------------------------------------------------------------------
-- scanning the burrow, a few blocks per frame
-- ---------------------------------------------------------------------------

-- Which z holds this burrow: the level being looked at if the burrow has tiles
-- there, else the level with the most of its tiles.
function choose_z(burrow)
    local per_z = {}
    for _, block in ipairs(dfhack.burrows.listBlocks(burrow)) do
        per_z[block.map_pos.z] = (per_z[block.map_pos.z] or 0) + 1
    end
    local wz = df.global.window_z
    if per_z[wz] then return wz end
    local best, bestn = nil, -1
    for z, n in pairs(per_z) do if n > bestn then best, bestn = z, n end end
    return best
end

-- Collect the burrow's tiles on one z. Runs as a coroutine: yields after every
-- few blocks so the game keeps rendering.
function scan_burrow(burrow, z, yield)
    local tiles = {}          -- key -> {x, y, rock, floor}
    local x0, y0, x1, y1 = math.huge, math.huge, -1, -1
    local n = 0
    for _, block in ipairs(dfhack.burrows.listBlocks(burrow)) do
        if block.map_pos.z == z then
            local bx, by = block.map_pos.x, block.map_pos.y
            for dy = 0, 15 do
                for dx = 0, 15 do
                    local pos = xyz2pos(bx + dx, by + dy, z)
                    if dfhack.burrows.isAssignedTile(burrow, pos) then
                        local t = {x = pos.x, y = pos.y, rock = is_rock(pos), floor = is_floor(pos)}
                        tiles[pos.x .. ',' .. pos.y] = t
                        x0, y0 = math.min(x0, pos.x), math.min(y0, pos.y)
                        x1, y1 = math.max(x1, pos.x), math.max(y1, pos.y)
                        n = n + 1
                    end
                end
            end
            yield()
        end
    end
    if n == 0 then return nil end
    return {tiles = tiles, x0 = x0, y0 = y0, x1 = x1, y1 = y1, n = n, z = z}
end

-- ---------------------------------------------------------------------------
-- turning a plan into fort/quickfort jobs
-- ---------------------------------------------------------------------------

-- stamp code -> quickfort #build code (nil: nothing to build)
local BUILD = {
    d = 'd', b = 'b', t = 't', c = 'c', f = 'f', h = 'h', r = 'r', a = 'a', s = 's',
    x = 'n',    -- coffin
    P = 'F',    -- pedestal: display furniture
    A = 's',    -- altar: no quickfort code, a statue stands in
    B = 'f',    -- bookcase: no quickfort code, a cabinet stands in
}
local DIG = {i = 'i'}   -- everything else in a footprint is a plain dig

local function job_name(preset_name, what, n)
    return ('builder-burrow %s: %s #%d'):format(preset_name, what, n)
end

-- Start one in-memory quickfort job. `cells` are {x, y, code} in slab coords;
-- the job is anchored at the slab origin so cells are relative to it.
local function start_data_job(name, origin, dig, smooth, build)
    local data = {}
    if #dig > 0 then data[#data + 1] = {mode = 'dig', name = 'dig', cells = dig} end
    if #smooth > 0 then data[#data + 1] = {mode = 'dig', name = 'smooth', cells = smooth} end
    if #build > 0 then data[#data + 1] = {mode = 'build', name = 'build', cells = build} end
    if #data == 0 then return nil end
    return qf.start_job({path = name, data = data}, origin)
end

local function emit_jobs(result, slab, preset_name)
    local W, H = result.W, result.H
    local claim, wallKind = result.claim, result.wallKind
    local origin = {x = slab.ox, y = slab.oy, z = slab.z}
    local started = 0
    local function at(x, y)
        if x < 0 or y < 0 or x >= W or y >= H then return 9 end
        return claim[y][x]
    end
    -- rooms: dig + smooth floor + engrave the walls the room owns + furniture
    for i, room in ipairs(result.rooms) do
        local dig, smooth, build = {}, {}, {}
        local cellSet = {}
        for _, c in ipairs(room.cells) do
            if c.ch ~= '#' and c.ch ~= 'F' then
                cellSet[c.x .. ',' .. c.y] = true
                dig[#dig + 1] = {c.x, c.y, DIG[c.ch] or 'd'}
                smooth[#smooth + 1] = {c.x, c.y, 's'}
                local b = BUILD[c.ch]
                if b then build[#build + 1] = {c.x, c.y, b} end
            end
        end
        local walls = {}
        for _, c in ipairs(room.cells) do
            for dy = -1, 1 do
                for dx = -1, 1 do
                    local x, y = c.x + dx, c.y + dy
                    local k = x .. ',' .. y
                    if not cellSet[k] and not walls[k] and at(x, y) == 3 and result.owner[y][x] == i then
                        walls[k] = true
                        smooth[#smooth + 1] = {x, y, 'e'}
                    end
                end
            end
        end
        if start_data_job(job_name(preset_name, room.stamp, i), origin, dig, smooth, build) then
            started = started + 1
        end
    end
    -- roads: dig + smooth floor + smooth the rock beside them that no room owns
    for i, seg in ipairs(result.segments) do
        local dig, smooth = {}, {}
        local seen = {}
        for _, t in ipairs(seg.tiles) do
            local x, y = t[1], t[2]
            local k = at(x, y)
            if (k == 1 or k == 6) and not seen[x .. ',' .. y] then
                seen[x .. ',' .. y] = true
                dig[#dig + 1] = {x, y, 'd'}
                smooth[#smooth + 1] = {x, y, 's'}
            end
        end
        for _, t in ipairs(seg.tiles) do
            for dy = -1, 1 do
                for dx = -1, 1 do
                    local x, y = t[1] + dx, t[2] + dy
                    local kk = x .. ',' .. y
                    if not seen[kk] and x >= 0 and y >= 0 and x < W and y < H and wallKind[y][x] == 2 then
                        seen[kk] = true
                        smooth[#smooth + 1] = {x, y, 's'}
                    end
                end
            end
        end
        if start_data_job(job_name(preset_name, ('road %dx%d'):format(seg.w, seg.n), i), origin, dig, smooth, {}) then
            started = started + 1
        end
    end
    -- hallway pieces: any of their tiles outside a road get dug too; statues and coffins are built
    for i, st in ipairs(result.stamps) do
        local dig, smooth, build = {}, {}, {}
        for _, c in ipairs(st.cells) do
            dig[#dig + 1] = {c.x, c.y, 'd'}
            smooth[#smooth + 1] = {c.x, c.y, 's'}
            local b = BUILD[c.ch]
            if b and c.ch ~= 'd' then build[#build + 1] = {c.x, c.y, b} end
        end
        if start_data_job(job_name(preset_name, st.stamp, i), origin, dig, smooth, build) then
            started = started + 1
        end
    end
    return started
end

-- ---------------------------------------------------------------------------
-- the pipeline: scan, pack, emit -- pumped a step per frame
-- ---------------------------------------------------------------------------

local function persist_plan(record)
    local data = dfhack.persistent.getSiteData(GLOBAL_KEY, {plans = {}})
    data.plans = data.plans or {}
    data.plans[#data.plans + 1] = record
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, data)
end

-- Plan `burrow` with `preset_name`, then start every blueprint. `on_status(text)`
-- is called with progress, `on_done(summary or nil, err)` at the end.
function plan_and_apply(burrow, preset_name, on_status, on_done)
    local preset = presets.PRESETS[preset_name]
    if not preset then on_done(nil, 'unknown preset ' .. tostring(preset_name)) return end
    if preset.surface then on_done(nil, 'surface presets are not applied yet') return end
    local z = choose_z(burrow)
    if not z then on_done(nil, 'the burrow has no tiles') return end
    local co = coroutine.create(function(yield)
        on_status('scanning the burrow on z ' .. z)
        local scan = scan_burrow(burrow, z, yield)
        if not scan then error('the burrow has no tiles on z ' .. z) end
        -- the slab: the burrow's bounding box with a two-tile pad, so existing
        -- floor just outside the burrow can be seen and joined
        local pad = 2
        local ox, oy = scan.x0 - pad, scan.y0 - pad
        local W, H = scan.x1 - scan.x0 + 1 + 2 * pad, scan.y1 - scan.y0 + 1 + 2 * pad
        local tiles = scan.tiles
        local function inBurrow(x, y) return tiles[(ox + x) .. ',' .. (oy + y)] ~= nil end
        local function free(x, y)
            local t = tiles[(ox + x) .. ',' .. (oy + y)]
            if not t or not t.rock then return false end
            for ey = -1, 1 do
                for ex = -1, 1 do
                    if not inBurrow(x + ex, y + ey) then return false end -- the border ring stays rock
                end
            end
            return true
        end
        local floorCache = {}
        local function existing(x, y)
            if x < 0 or y < 0 or x >= W or y >= H then return false end
            local k = x .. ',' .. y
            local v = floorCache[k]
            if v == nil then
                local t = tiles[(ox + x) .. ',' .. (oy + y)]
                if t then v = t.floor
                else v = is_floor(xyz2pos(ox + x, oy + y, z)) end
                floorCache[k] = v
            end
            return v
        end
        on_status(('packing %dx%d slab, %d burrow tiles'):format(W, H, scan.n))
        local seed = math.random(1, 1e6)
        local result = packer.pack({W = W, H = H, free = free, existing = existing, inBurrow = inBurrow,
                                    preset = preset, districts = presets.DISTRICTS, seed = seed, yield = yield})
        if not result then error('nowhere to start: the burrow touches no dug floor, or nothing fits') end
        on_status(('starting %d rooms, %d roads, %d hallway pieces')
            :format(#result.rooms, result.stats.segN, result.stats.stampsN))
        yield()
        local started = emit_jobs(result, {ox = ox, oy = oy, z = z}, preset_name)
        local per = {}
        for name, n in pairs(result.stats.per) do per[#per + 1] = ('%d %s'):format(n, name) end
        table.sort(per)
        persist_plan({burrow = burrow.id, burrow_name = burrow.name, preset = preset_name, z = z,
                      seed = seed, rooms = #result.rooms, roads = result.stats.segN, jobs = started,
                      when = 'now', year = df.global.cur_year, tick = df.global.cur_year_tick})
        return {rooms = #result.rooms, roads = result.stats.segN, stamps = result.stats.stampsN,
                jobs = started, per = table.concat(per, ', '), z = z,
                used = (result.stats.roomTiles + result.stats.roadTiles) / math.max(1, result.stats.burrow)}
    end)
    local function step()
        local ok, res = coroutine.resume(co, function() coroutine.yield() end)
        if not ok then on_done(nil, tostring(res)) return end
        if coroutine.status(co) == 'dead' then on_done(res) return end
        dfhack.timeout(1, 'frames', step)
    end
    step()
end

-- ---------------------------------------------------------------------------
-- the picker
-- ---------------------------------------------------------------------------

local WHEN = {{label = 'apply now', value = 'now'}}

BuilderWindow = defclass(BuilderWindow, widgets.Window)
BuilderWindow.ATTRS{
    frame_title = 'Builder burrow',
    frame = {w = 64, h = 22},
    resizable = true,
}

function BuilderWindow:init()
    local burrows = {}
    for _, b in ipairs(df.global.plotinfo.burrows.list) do
        local name = b.name ~= '' and b.name or ('burrow #' .. b.id)
        burrows[#burrows + 1] = {text = name, burrow = b}
    end
    local plist = {}
    for _, name in ipairs(presets.PRESET_ORDER) do plist[#plist + 1] = {text = name, preset = name} end
    self.busy = false
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = 'Burrow'},
        widgets.List{view_id = 'burrows', frame = {t = 1, l = 0, w = 28, h = 12}, choices = burrows},
        widgets.Label{frame = {t = 0, l = 31}, text = 'Preset'},
        widgets.List{view_id = 'presets', frame = {t = 1, l = 31, w = 28, h = 12}, choices = plist},
        widgets.CycleHotkeyLabel{view_id = 'when', frame = {t = 14, l = 0}, key = 'CUSTOM_W',
            label = 'Build when', options = WHEN, initial_option = 'now'},
        widgets.HotkeyLabel{frame = {t = 16, l = 0}, key = 'SELECT', label = 'Plan and apply',
            on_activate = self:callback('apply')},
        widgets.Label{view_id = 'status', frame = {t = 18, l = 0}, text = ''},
    }
    if #burrows == 0 then self:status('this fort has no burrows: paint one over the rock to build in') end
end

function BuilderWindow:status(text)
    self.subviews.status:setText(text)
end

function BuilderWindow:apply()
    if self.busy then return end
    local _, bsel = self.subviews.burrows:getSelected()
    local _, psel = self.subviews.presets:getSelected()
    if not bsel or not psel then self:status('pick a burrow and a preset') return end
    self.busy = true
    plan_and_apply(bsel.burrow, psel.preset,
        function(text) self:status(text) end,
        function(summary, err)
            self.busy = false
            if not summary then
                self:status('failed: ' .. tostring(err))
                return
            end
            local msg = ('%s in "%s": %d rooms (%s), %d roads, %d hallway pieces; %d quickfort jobs started, %d%% of the burrow used')
                :format(psel.preset, bsel.text, summary.rooms, summary.per, summary.roads, summary.stamps,
                        summary.jobs, math.floor(summary.used * 100 + 0.5))
            self:status(msg)
            pcall(dfhack.gui.showAnnouncement, 'fort/builder-burrow: ' .. msg, COLOR_LIGHTGREEN, true)
            print('fort/builder-burrow: ' .. msg)
        end)
end

BuilderScreen = defclass(BuilderScreen, gui.ZScreen)
BuilderScreen.ATTRS{focus_path = 'builder-burrow'}
function BuilderScreen:init() self:addviews{BuilderWindow{}} end
function BuilderScreen:onDismiss() view = nil end

-- ---------------------------------------------------------------------------
-- command line
-- ---------------------------------------------------------------------------

local function status()
    local data = dfhack.persistent.getSiteData(GLOBAL_KEY, {plans = {}})
    if not data.plans or #data.plans == 0 then print('fort/builder-burrow: no plans stored for this fort') return end
    for _, p in ipairs(data.plans) do
        print(('  %s in %s (z %d): %d rooms, %d roads, %d jobs, seed %d, %s')
            :format(p.preset, p.burrow_name ~= '' and p.burrow_name or ('burrow #' .. p.burrow), p.z,
                    p.rooms, p.roads, p.jobs, p.seed, p.when))
    end
end

if dfhack_flags.module then return end

if not dfhack.isMapLoaded() then qerror('fort/builder-burrow needs a loaded fortress') end
local args = {...}
if args[1] == 'status' then
    status()
else
    view = view and view:raise() or BuilderScreen{}:show()
end
