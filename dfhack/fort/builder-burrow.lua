-- Turn a burrow into a district: pick a burrow and a preset, roads and rooms are
-- planned inside it in the background and every blueprint is started as it lands.
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

PRESETS
  The picker's "New preset" and "Edit preset" open the preset editor: three
  columns. The first holds the actions (create district, add blueprint, remove,
  a different second pass, hallway blueprints, paste and copy JSON, save) and
  the settings of whatever is selected; the second lists the passes with their
  districts and blueprints; the third is the blueprint library, filtered by what
  is being edited (rooms by type, then surface rooms; hallway pieces when the
  hallway section is selected). Enter on a library entry adds it: to the
  selected district, as an alternative of the selected blueprint, or, with only
  a pass selected, in a new district named after it. Presets are saved to
  dfhack-config/scripts/data/builder-burrow/presets.json and override shipped
  ones of the same name. Copy and paste use the system clipboard, in the same
  JSON the browser sandbox (prototypes/burrow-stamper) copies out, so a preset
  designed there pastes straight in.

BUILD WHEN
  Only "apply now" exists yet: every blueprint of the plan is started the moment
  you confirm. Gating on a need (a noble without rooms, a house short) is the next
  step and the dropdown is already there for it.

  Confirming CLOSES the picker at once and plans in the background, a slice of a
  frame at a time, so the game keeps running while rooms appear. Progress goes to
  the console; the summary is also announced in-game. Only one plan runs at a time.

  A plan that lays NOTHING is reported as a failure, in red, saying what the burrow
  gave it: how many tiles were diggable, how many were already floor, and the likely
  reason (all floor already, no dug floor to start from, or no room for a road of
  this preset's width).

WHAT IT NEEDS FROM THE BURROW
  The burrow marks rock the tool may dig. Its outermost ring is never dug, so it
  becomes wall, and the tool only starts where the burrow touches dug floor: a
  corridor of yours running up to the burrow, or a burrow painted around an
  existing road. Existing floor inside the burrow counts as road that new roads
  may join. Nothing outside the burrow is ever dug.

  One z-level per plan. Multi-floor blueprints (the town presets) are not
  applied yet; the shipped presets are all rock-cut, single level.

CODES
  Every tile a plan touches is dug and then smoothed before anything is built on it.
  ENGRAVING is for walls only, so the pictures are at eye level and the floors stay
  plain -- and EVERY wall around what the plan digs is dressed, not just the walls a
  room formally owns, or the margin rock between two rooms would be left bare. Each
  wall belongs to exactly one blueprint (two jobs would fight over the square, and two
  room zones covering it would overlap, which DF refuses). Rock that the plan is going
  to dig out is never smoothed as though it were a wall: a road's flank is often the
  square a room's door gets cut through.

  fort/quickfort sequences a tile's own steps (dig, smooth, engrave, build), so each
  square is dressed as soon as IT is ready rather than waiting for the rest.

ZONES
  A stamp DECLARES the activity zone its room carries, as the quickfort zone code the
  blueprint writes: `zone = 'b'` bedroom, `'o'` office, `'h'` dining hall, `'T'` tomb
  (internal/builder-burrow/presets.lua). The blueprint carries a `#zone` section
  covering the room's floor AND the walls it owns -- a room is worth what its walls are
  worth, and an engraving outside the zone counts towards nothing -- alongside its
  dig, smooth, engrave and build sections, and
  fort/quickfort lays it once the room's own tiles are finished. A stamp with no
  `zone` gets none -- which is what a catacomb or a family tomb wants, since a DF tomb
  belongs to one dwarf and those hold many coffins; `fort/auto-tomb` zones each of
  those coffins separately.

  auto-tomb also stands off any tile a running plan is about to zone (`pending_zone_at`
  in fort/quickfort), so the two never race for the same coffin: a 1x1 tomb dropped on
  the coffin first would make DF refuse the room's zone as an overlap.

  A stamp added in the preset editor starts with the zone its furniture implies, from
  the same classification the library list shows, and it is then part of the preset --
  visible and editable in the preset JSON.

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
local editor = reqscript('internal/builder-burrow/editor')
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

-- Rooms carry their activity zone as a quickfort zone code declared on the stamp
-- (`zone = 'b'` and friends in internal/builder-burrow/presets.lua), so the blueprint
-- says what it is rather than this guessing from furniture. A stamp with no `zone`
-- gets none.

local function job_name(preset_name, what, n)
    return ('builder-burrow %s: %s #%d'):format(preset_name, what, n)
end

-- Start one in-memory quickfort job. `cells` are {x, y, code} in slab coords;
-- the job is anchored at the slab origin so cells are relative to it.
--
-- Smoothing and engraving are SEPARATE sections even though both are `#dig` mode:
-- a section is a grid, so a second cell at the same square would overwrite the first,
-- and every tile here is both smoothed and then engraved. fort/quickfort runs a
-- tile's steps in stage order (dig, smooth, engrave, then anything built on it), so
-- one tile can carry all four.
local function start_data_job(name, origin, dig, smooth, engrave, build, zone)
    local data = {}
    if #dig > 0 then data[#data + 1] = {mode = 'dig', name = 'dig', cells = dig} end
    if #smooth > 0 then data[#data + 1] = {mode = 'dig', name = 'smooth', cells = smooth} end
    if #engrave > 0 then data[#data + 1] = {mode = 'dig', name = 'engrave', cells = engrave} end
    if #build > 0 then data[#data + 1] = {mode = 'build', name = 'build', cells = build} end
    if zone and #zone > 0 then data[#data + 1] = {mode = 'zone', name = 'zone', cells = zone} end
    if #data == 0 then return nil end
    return qf.start_job({path = name, data = data}, origin)
end

-- Starting a blueprint is the expensive half of applying (quickfort walks every cell and
-- registers designations and buildings), so this yields after each one: a plan of a couple
-- of hundred rooms would otherwise stall DF for seconds in a single frame.
local function emit_jobs(result, slab, preset_name, yield, on_status, in_burrow)
    local W, H = result.W, result.H
    local claim = result.claim
    local origin = {x = slab.ox, y = slab.oy, z = slab.z}
    local started = 0
    local n_all = #result.rooms + #result.segments + #result.stamps
    local done = 0
    local function tick()
        done = done + 1
        if on_status and done % 10 == 0 then
            on_status(('starting blueprints: %d/%d'):format(done, n_all))
        end
        yield()
    end
    local function at(x, y)
        if x < 0 or y < 0 or x >= W or y >= H then return 9 end
        return claim[y][x]
    end

    -- Every tile the plan will HOLLOW OUT. Rock that is going to be dug must never be
    -- designated for smoothing as though it were rock that stays: a road's flanking wall
    -- is often the very square a room's door gets cut through, and smoothing it first
    -- leaves a smoothed patch where the doorway should be.
    local dug = {}
    local function mark_dug(x, y) dug[x .. ',' .. y] = true end
    for _, room in ipairs(result.rooms) do
        for _, c in ipairs(room.cells) do
            if c.ch ~= '#' and c.ch ~= 'F' then mark_dug(c.x, c.y) end
        end
    end
    for _, st in ipairs(result.stamps) do
        for _, c in ipairs(st.cells) do mark_dug(c.x, c.y) end
    end
    for _, seg in ipairs(result.segments) do
        for _, t in ipairs(seg.tiles) do
            local k = at(t[1], t[2])
            if k == 1 or k == 6 then mark_dug(t[1], t[2]) end
        end
    end

    -- EVERY wall around what the plan digs is smoothed and engraved -- not only the walls a
    -- room formally owns and the rock flanking a road, which between them leave the margin
    -- rock between rooms bare. A wall belongs to exactly ONE blueprint: two jobs designating
    -- the same square would fight over it, and two room zones covering it would overlap,
    -- which DF refuses outright. Rooms are emitted first, so a room takes the walls around
    -- itself before the roads do.
    local wall_claimed = {}
    local function claim_walls(cells)
        local out = {}
        for _, c in ipairs(cells) do
            for dy = -1, 1 do
                for dx = -1, 1 do
                    local x, y = c[1] + dx, c[2] + dy
                    local k = x .. ',' .. y
                    if not dug[k] and not wall_claimed[k] and in_burrow(x, y)
                        and not is_floor(xyz2pos(origin.x + x, origin.y + y, origin.z)) then
                        wall_claimed[k] = true
                        out[#out + 1] = {x, y}
                    end
                end
            end
        end
        return out
    end

    -- rooms: dig + smooth the floor, dress every wall around it, furniture
    for i, room in ipairs(result.rooms) do
        local dig, smooth, engrave, build = {}, {}, {}, {}
        local zone, zcode = {}, room.zone_code
        for _, c in ipairs(room.cells) do
            if c.ch ~= '#' and c.ch ~= 'F' then
                dig[#dig + 1] = {c.x, c.y, DIG[c.ch] or 'd'}
                smooth[#smooth + 1] = {c.x, c.y, 's'}
                if zcode then zone[#zone + 1] = {c.x, c.y, zcode} end
                local b = BUILD[c.ch]
                if b then build[#build + 1] = {c.x, c.y, b} end
            end
        end
        for _, w in ipairs(claim_walls(dig)) do
            -- a wall has to be smoothed before it can be engraved
            smooth[#smooth + 1] = {w[1], w[2], 's'}
            engrave[#engrave + 1] = {w[1], w[2], 'e'}
            -- the room's zone takes in its walls, not just its floor: a bedroom is worth
            -- what its walls are worth, and an engraving outside the zone counts for nothing
            if zcode then zone[#zone + 1] = {w[1], w[2], zcode} end
        end
        if start_data_job(job_name(preset_name, room.stamp, i), origin, dig, smooth, engrave, build, zone) then
            started = started + 1
        end
        tick()
    end
    -- roads: dig + smooth floor + smooth the rock beside them that no room owns
    for i, seg in ipairs(result.segments) do
        local dig, smooth, engrave = {}, {}, {}
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
        for _, w in ipairs(claim_walls(dig)) do
            smooth[#smooth + 1] = {w[1], w[2], 's'}
            engrave[#engrave + 1] = {w[1], w[2], 'e'}
        end
        if start_data_job(job_name(preset_name, ('road %dx%d'):format(seg.w, seg.n), i), origin, dig, smooth, engrave, {}) then
            started = started + 1
        end
        tick()
    end
    -- hallway pieces: any of their tiles outside a road get dug too; statues and coffins are built
    for i, st in ipairs(result.stamps) do
        local dig, smooth, engrave, build = {}, {}, {}, {}
        for _, c in ipairs(st.cells) do
            dig[#dig + 1] = {c.x, c.y, 'd'}
            smooth[#smooth + 1] = {c.x, c.y, 's'}
            local b = BUILD[c.ch]
            if b and c.ch ~= 'd' then build[#build + 1] = {c.x, c.y, b} end
        end
        for _, w in ipairs(claim_walls(dig)) do
            smooth[#smooth + 1] = {w[1], w[2], 's'}
            engrave[#engrave + 1] = {w[1], w[2], 'e'}
        end
        if start_data_job(job_name(preset_name, st.stamp, i), origin, dig, smooth, engrave, build) then
            started = started + 1
        end
        tick()
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

-- One plan at a time: the run outlives the picker window, so a second one would fight it
-- for the same rock. `nil` when nothing is running.
running = running or nil

-- How long a frame may spend planning. Small enough that DF keeps drawing smoothly,
-- big enough that a plan does not take a thousand frames: the coroutine is resumed over
-- and over inside one frame until the budget is gone, then it waits for the next.
local FRAME_BUDGET_MS = 8

-- Plan `burrow` with `preset_name`, then start every blueprint. `on_status(text)`
-- is called with progress, `on_done(summary or nil, err)` at the end. Both run in the
-- background, a slice per frame -- the caller does not wait, and the picker closes at once.
function plan_and_apply(burrow, preset_name, on_status, on_done)
    local allp = editor.all_presets()
    local preset = allp[preset_name]
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
        local started = emit_jobs(result, {ox = ox, oy = oy, z = z}, preset_name, yield, on_status,
                                  inBurrow)
        -- A plan that laid no road is a FAILURE, not a plan with nothing in it: reporting it
        -- as "0 rooms, 0 roads, 1% of the burrow used" reads like success and says nothing
        -- about why. Say what the burrow gave us to work with instead.
        if started == 0 then
            local floors, diggable = 0, result.stats.burrow
            for _, t in pairs(scan.tiles) do if t.floor then floors = floors + 1 end end
            local why
            if diggable == 0 then
                why = 'nothing in it can be dug -- it is all floor already, or it is so thin that its'
                    .. ' outer ring (never dug, so it stays wall) is the whole burrow'
            elseif floors == 0 then
                why = 'it touches no dug floor, so a road has nowhere to start -- paint the burrow'
                    .. ' to take in a corridor of yours'
            else
                why = "no road of this preset's width would fit; try a preset with narrower roads"
                    .. ' (hovels, housing 2x2) or a wider burrow'
            end
            error(('planned nothing on z %d (%d tiles, %d diggable, %d already floor): %s')
                :format(z, scan.n, diggable, floors, why))
        end
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
    local yield = function() coroutine.yield() end
    local function step()
        local deadline = dfhack.getTickCount() + FRAME_BUDGET_MS
        repeat
            local ok, res = coroutine.resume(co, yield)
            if not ok then running = nil; on_done(nil, tostring(res)) return end
            if coroutine.status(co) == 'dead' then running = nil; on_done(res) return end
        until dfhack.getTickCount() >= deadline
        dfhack.timeout(1, 'frames', step)
    end
    running = {burrow = burrow.id, preset = preset_name}
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
    self:addviews{
        widgets.Label{frame = {t = 0, l = 0}, text = 'Burrow'},
        widgets.List{view_id = 'burrows', frame = {t = 1, l = 0, w = 28, h = 12}, choices = burrows},
        widgets.Label{frame = {t = 0, l = 31}, text = 'Preset'},
        widgets.List{view_id = 'presets', frame = {t = 1, l = 31, w = 28, h = 12}, choices = {}},
        widgets.CycleHotkeyLabel{view_id = 'when', frame = {t = 14, l = 0}, key = 'CUSTOM_W',
            label = 'Build when', options = WHEN, initial_option = 'now'},
        widgets.HotkeyLabel{frame = {t = 16, l = 0}, key = 'SELECT', label = 'Plan and apply',
            on_activate = self:callback('apply')},
        widgets.HotkeyLabel{frame = {t = 14, l = 31}, key = 'CUSTOM_N', label = 'New preset',
            on_activate = self:callback('new_preset')},
        widgets.HotkeyLabel{frame = {t = 15, l = 31}, key = 'CUSTOM_E', label = 'Edit preset',
            on_activate = self:callback('edit_preset')},
        widgets.Label{view_id = 'status', frame = {t = 18, l = 0}, text = ''},
    }
    self:refresh_presets()
    if #burrows == 0 then self:status('this fort has no burrows: paint one over the rock to build in') end
end

function BuilderWindow:status(text)
    self.subviews.status:setText(text)
end

function BuilderWindow:refresh_presets(select_name)
    local allp, order = editor.all_presets()
    local plist, idx = {}, 1
    for i, name in ipairs(order) do
        plist[#plist + 1] = {text = name, preset = name}
        if name == select_name then idx = i end
    end
    self.subviews.presets:setChoices(plist, idx)
end

function BuilderWindow:new_preset()
    editor.open(nil, nil, function(name) self:refresh_presets(name); self:status(('preset "%s" saved'):format(name)) end)
end

function BuilderWindow:edit_preset()
    local _, psel = self.subviews.presets:getSelected()
    if not psel then return end
    local allp = editor.all_presets()
    editor.open(allp[psel.preset], psel.preset,
        function(name) self:refresh_presets(name); self:status(('preset "%s" saved'):format(name)) end)
end

-- Planning happens in the background, so the picker gets out of the way the moment you
-- confirm: progress and the result go to the console, and the summary (or the failure)
-- also lands in DF's announcement log, where it is still there when you look up.
function BuilderWindow:apply()
    local _, bsel = self.subviews.burrows:getSelected()
    local _, psel = self.subviews.presets:getSelected()
    if not bsel or not psel then self:status('pick a burrow and a preset') return end
    if running then
        self:status(('still planning "%s" -- one at a time'):format(running.preset))
        return
    end
    local preset_name, burrow_text = psel.preset, bsel.text
    plan_and_apply(bsel.burrow, preset_name,
        function(text) print('fort/builder-burrow: ' .. text) end,
        function(summary, err)
            if not summary then
                local msg = ('fort/builder-burrow: %s in "%s" failed: %s')
                    :format(preset_name, burrow_text, tostring(err))
                pcall(dfhack.gui.showAnnouncement, msg, COLOR_LIGHTRED, true)
                print(msg)
                return
            end
            local msg = ('%s in "%s": %d rooms (%s), %d roads, %d hallway pieces; %d quickfort jobs started, %d%% of the burrow used')
                :format(preset_name, burrow_text, summary.rooms, summary.per, summary.roads, summary.stamps,
                        summary.jobs, math.floor(summary.used * 100 + 0.5))
            pcall(dfhack.gui.showAnnouncement, 'fort/builder-burrow: ' .. msg, COLOR_LIGHTGREEN, true)
            print('fort/builder-burrow: ' .. msg)
        end)
    pcall(dfhack.gui.showAnnouncement,
        ('fort/builder-burrow: planning %s in "%s" -- building starts as it goes')
            :format(preset_name, burrow_text), COLOR_WHITE, false)
    self.parent_view:dismiss()
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
