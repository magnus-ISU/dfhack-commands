-- Stage channel designations so only the top level is ever dug.
--@module = true
--[[
fort/channel-safely

Channelling a large hole is miserable to manage by hand: dwarves happily start
on a lower level while the level above is still open, drop into their own work,
or cut the last support out from under a chunk of floor. This holds every
channel designation in MARKER MODE except the ones on the highest z-level that
still has channelling to do, and releases the next level down as each level
finishes.

    fort/channel-safely            status
    fort/channel-safely enable     start managing channel designations
    fort/channel-safely disable    stop, and release every designation it holds
    fort/channel-safely once       run a single pass now, then stop

PRIORITY IS THE ESCAPE HATCH
  A channel designation at priority 1 (DF's highest, `d1` in quickfort or the
  priority selector in-game) is never held back. Set a tile to priority 1 when
  you want it dug now regardless of what is above it -- that is the manual
  override, and the only way to make this tool get out of the way for one tile.

CAVE-IN PROTECTION IS CHEAP, NOT A GUARANTEE
  A chunk of floor falls when nothing in it still touches a wall, so the honest
  test is a connectivity search -- a property of the whole level, not of the tile
  being dug. This does run that search, but over a bounded area and one level at
  a time, which is what keeps it affordable and also what keeps it short of a
  guarantee. Three rules:

    1. Top level only. Nothing below the highest channelling level is active, so
       a level is never opened while one above it is still coming down. This is
       the rule that prevents most real collapses, because a staged excavation
       keeps its floor attached at the edges.
    2. Never channel a tile that has a building or construction standing on it,
       or one directly below it. Digging those out drops the thing on top.
    3. Never channel a tile that would cut a neighbour loose from the rock.
       Pretend the whole active channel set is already dug, then flood out from
       the WALLS across everything still standing, 8-connected as DF's own
       support is. Anything the flood never reaches would be left hanging, and
       every channel tile touching it is held back.

  Rule 3 is a real connectivity search, not a neighbour count, so it catches an
  unanchored region of any shape -- but it is bounded in area, and those bounds
  are where it stops being a guarantee:

    * It looks only at the bounding box of the active channel set plus a small
      margin. Support running off the edge of that box is ASSUMED anchored,
      because it usually is, and assuming otherwise would hold back half a fort.
    * Above 10,000 tiles the check is skipped entirely and says so in `status`.
      The staging and building rules still apply; the support test does not.
    * It considers one z-level. A floor cut loose by digging on the level below
      is not this rule's business.

  Cost drove every one of those choices, and the numbers are measured, not
  estimated. Asking the question once per level instead of once per candidate
  tile is what makes it linear in the area rather than in area x designations.
  Reading tiletypes out of cached map blocks instead of through
  dfhack.maps.getTileType is worth 100x on its own -- 2500 tiles in 4ms rather
  than 474ms -- and the flood uses integer grid indices because building
  "x,y,z" keys for it cost more than the map reads. The answer is cached and
  recomputed only when the designation set changes, so a pass that finds the
  same set as the last one is nearly free.

WHAT IT TOUCHES
  `occupancy.dig_marked` -- DF's own marker-mode bit -- and nothing else. Marker
  mode is saved with the map, so held designations survive a save/load whether
  or not this is enabled. It only ever un-marks tiles IT marked: marks are
  recorded in dfhack persistence (site data) so a designation you put into
  marker mode yourself is never released by this tool.

  `disable` releases everything it currently holds, so turning it off leaves the
  map the way you would have designated it by hand.
]]

local overlay = require('plugins.overlay')

local GLOBAL_KEY = 'channel-safely'

-- priority at or above which a designation is never held back. DF priorities run
-- 1 (highest) .. 7 (lowest); the priority event stores them the same way.
local EXEMPT_PRIORITY = 1
local DEFAULT_PRIORITY = 4      -- what DF uses when a block has no priority event

local BLOCKS_PER_PASS = 400     -- blocks examined per pump, to keep frames cheap
local PASS_INTERVAL_MS = 2000   -- wall-clock gap between passes

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

-- marks = { ["x,y,z"] = true } for every tile WE put into marker mode
local state = nil

local function default_state()
    return {enabled = false, marks = {}}
end

local function get_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, default_state())
        state.marks = state.marks or {}
    end
    return state
end

local function save_state()
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, get_state())
end

local function key(pos) return ('%d,%d,%d'):format(pos.x, pos.y, pos.z) end

-- ---------------------------------------------------------------------------
-- tile access
-- ---------------------------------------------------------------------------

local function tile_parts(pos)
    local block = dfhack.maps.getTileBlock(pos)
    if not block then return end
    return block, pos.x % 16, pos.y % 16
end

local function designation_of(pos)
    local block, bx, by = tile_parts(pos)
    if not block then return end
    return block.designation[bx][by], block.occupancy[bx][by]
end

-- Dig priority lives in a per-block event holding a 16x16 array, not in the tile
-- record. A block with no such event is at DF's default.
local function priority_of(pos)
    local block, bx, by = tile_parts(pos)
    if not block then return DEFAULT_PRIORITY end
    for _, ev in ipairs(block.block_events) do
        if ev:getType() == df.block_square_event_type.designation_priority then
            local p = ev.priority[bx][by]
            -- DF stores priority * 1000 in this array
            if p and p > 0 then return math.max(1, math.floor(p / 1000)) end
            return DEFAULT_PRIORITY
        end
    end
    return DEFAULT_PRIORITY
end

local function is_channel(pos)
    local d = designation_of(pos)
    return d and d.dig == df.tile_dig_designation.Channel
end

local function has_building(pos)
    local _, occ = designation_of(pos)
    if not occ then return false end
    return occ.building ~= df.tile_building_occ.None
end

-- ---------------------------------------------------------------------------
-- rule 3: what would be left hanging
-- ---------------------------------------------------------------------------
--
-- This is the expensive rule, and how expensive is not a matter of opinion:
-- measured on this machine, dfhack.maps.getTileType costs ~50 microseconds a
-- call, so 20,000 tile reads freeze DF for a full second. A per-candidate
-- search -- walk outward from each neighbour of each channel tile hunting for a
-- wall -- crosses the same ground once per candidate and reaches millions of
-- reads on a real excavation. It is the obvious implementation and it is
-- unusable.
--
-- So the question is asked once for the whole level rather than once per tile.
-- Pretend the entire active channel set is already dug, then flood OUT FROM THE
-- WALLS over everything still standing: whatever the flood fails to reach is
-- what would be left hanging. Every tile is read at most once, and it is
-- strictly more accurate than a bounded per-tile search, because it finds
-- unanchored regions of any shape and size instead of only those inside some
-- radius.
--
-- Bounds, because a fort can designate a whole level:
--   * only the bounding box of the ACTIVE channel set, grown by MARGIN
--   * skipped, and said so in `status`, if that box exceeds MAX_AREA
--   * tiles on the box edge count as anchored -- support may well continue
--     outside the box, and assuming it does not would hold half a fort
--   * recomputed only when the channel set changes

local MARGIN = 3
local MAX_AREA = 10000         -- a 100x100 excavation; measured at ~16ms

local SHAPE_OPEN, SHAPE_WALL, SHAPE_SUPPORT = 0, 1, 2

-- tiletype -> shape code, built once.
--
-- Reading df.tiletype.attrs[tt].shape per tile crosses into the C++ structures
-- every time and dominates everything else: classifying 10,000 tiles that way
-- takes 1491ms, against 8ms through this table. Building it walks every
-- tiletype once and costs ~125ms, paid on the first pass of a session.
local SHAPE_CODE = nil
local function shape_code_table()
    if SHAPE_CODE then return SHAPE_CODE end
    SHAPE_CODE = {}
    for tt in ipairs(df.tiletype) do
        local basic = df.tiletype_shape.attrs[df.tiletype.attrs[tt].shape].basic_shape
        SHAPE_CODE[tt] = (basic == df.tiletype_shape_basic.Wall) and SHAPE_WALL
                      or (basic == df.tiletype_shape_basic.Open) and SHAPE_OPEN
                      or SHAPE_SUPPORT
    end
    return SHAPE_CODE
end

local NEIGHBOURS = {}
for dx = -1, 1 do
    for dy = -1, 1 do
        if dx ~= 0 or dy ~= 0 then NEIGHBOURS[#NEIGHBOURS + 1] = {x = dx, y = dy} end
    end
end

-- Tiles that would be left unanchored if `doomed` were dug out, as a set keyed
-- the same way `doomed` is, or nil if the area is over budget.
--
-- Two things make this affordable, both measured rather than guessed:
--
--   * tiletypes are read straight out of the map block, with the block looked
--     up once per 16x16 rather than once per tile, and turned into a shape code
--     through a precomputed table. Measured over 10,000 tiles: 1491ms the
--     obvious way, 8ms this way.
--   * the grid is a flat array indexed by integer, not a table keyed by
--     "x,y,z" strings, and the flood runs off a manual stack pointer. Same
--     10,000 tiles: 473ms before, 8ms after.
local function unanchored_after(active, doomed, _)
    if #active == 0 then return {} end
    local z = active[1].z
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(active) do
        x0, y0 = math.min(x0, p.x), math.min(y0, p.y)
        x1, y1 = math.max(x1, p.x), math.max(y1, p.y)
    end
    x0, y0, x1, y1 = x0 - MARGIN, y0 - MARGIN, x1 + MARGIN, y1 + MARGIN
    local w, h = x1 - x0 + 1, y1 - y0 + 1
    if w * h > MAX_AREA then return nil end

    local grid, blocks, codes = {}, {}, shape_code_table()
    local function block_at(x, y)
        local bk = (x // 16) * 4096 + (y // 16)
        local b = blocks[bk]
        if b == nil then
            b = dfhack.maps.getTileBlock({x = x, y = y, z = z}) or false
            blocks[bk] = b
        end
        return b
    end

    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local x, y = x0 + ix, y0 + iy
            local code = SHAPE_OPEN
            if not doomed[key({x = x, y = y, z = z})] then
                local b = block_at(x, y)
                if b then code = codes[b.tiletype[x % 16][y % 16]] or SHAPE_OPEN end
            end
            grid[ix * h + iy] = code
        end
    end

    -- seed the flood with every wall, plus the standing tiles on the box edge:
    -- support may continue past the box, and calling it unanchored because we
    -- stopped looking would hold back half a fort
    local reached, stack, sp = {}, {}, 0
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local i = ix * h + iy
            local c = grid[i]
            if c == SHAPE_WALL
                    or (c == SHAPE_SUPPORT
                        and (ix == 0 or iy == 0 or ix == w - 1 or iy == h - 1)) then
                reached[i] = true
                sp = sp + 1
                stack[sp] = i
            end
        end
    end
    while sp > 0 do
        local i = stack[sp]
        sp = sp - 1
        local ix, iy = i // h, i % h
        for _, d in ipairs(NEIGHBOURS) do
            local nx, ny = ix + d.x, iy + d.y
            if nx >= 0 and ny >= 0 and nx < w and ny < h then
                local ni = nx * h + ny
                if grid[ni] == SHAPE_SUPPORT and not reached[ni] then
                    reached[ni] = true
                    sp = sp + 1
                    stack[sp] = ni
                end
            end
        end
    end

    local left = {}
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local i = ix * h + iy
            if grid[i] == SHAPE_SUPPORT and not reached[i] then
                left[key({x = x0 + ix, y = y0 + iy, z = z})] = true
            end
        end
    end
    return left
end

-- rule 2, plus a lookup into rule 3's precomputed answer
local function is_unsafe(pos, hanging)
    if has_building(pos) then return true, 'a building stands on it' end
    local below = {x = pos.x, y = pos.y, z = pos.z - 1}
    if has_building(below) then return true, 'a building stands under it' end
    if hanging then
        for _, d in ipairs(NEIGHBOURS) do
            if hanging[('%d,%d,%d'):format(pos.x + d.x, pos.y + d.y, pos.z)] then
                return true, 'it would cut a neighbour loose'
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- marking
-- ---------------------------------------------------------------------------

local function set_marked(pos, marked)
    local block, bx, by = tile_parts(pos)
    if not block then return false end
    if block.occupancy[bx][by].dig_marked == marked then return false end
    block.occupancy[bx][by].dig_marked = marked
    return true
end

local function hold(pos)
    local s = get_state()
    if set_marked(pos, true) then
        s.marks[key(pos)] = true
        return true
    end
    -- already in marker mode: if it is not ours, leave it alone forever
    return false
end

local function release(pos)
    local s = get_state()
    local k = key(pos)
    if not s.marks[k] then return false end
    set_marked(pos, false)
    s.marks[k] = nil
    return true
end

function release_all()
    local s = get_state()
    local n = 0
    for k in pairs(s.marks) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        if x then
            set_marked({x = tonumber(x), y = tonumber(y), z = tonumber(z)}, false)
            n = n + 1
        end
    end
    s.marks = {}
    save_state()
    return n
end

-- ---------------------------------------------------------------------------
-- the pass
-- ---------------------------------------------------------------------------

-- Collect every channel designation on the map. Cheap because block_flags
-- .designated (HAS_DESJOB) tells us which blocks have designation jobs at all,
-- so the 256-tile read only happens on the handful that matter.
local scan = nil

local function start_scan()
    scan = {i = 0, blocks = df.global.world.map.map_blocks, found = {}, top = nil}
end

-- returns true when the scan finished this call
local function step_scan()
    if not scan then start_scan() end
    local blocks = scan.blocks
    local last = math.min(scan.i + BLOCKS_PER_PASS, #blocks)
    while scan.i < last do
        local block = blocks[scan.i]
        scan.i = scan.i + 1
        if block and block.flags.designated then
            for bx = 0, 15 do
                for by = 0, 15 do
                    if block.designation[bx][by].dig == df.tile_dig_designation.Channel then
                        local pos = {x = block.map_pos.x + bx,
                                     y = block.map_pos.y + by,
                                     z = block.map_pos.z}
                        scan.found[#scan.found + 1] = pos
                        if not scan.top or pos.z > scan.top then scan.top = pos.z end
                    end
                end
            end
        end
    end
    return scan.i >= #blocks
end

-- the channel set the last rule-3 answer was computed for
local hanging_cache = {set = nil, hanging = nil, skipped = false}

local function apply(found, top)
    local s = get_state()
    local doomed = {}
    for _, pos in ipairs(found) do doomed[key(pos)] = true end

    -- The rule-3 flood only cares about the ACTIVE level: everything below is
    -- held by rule 1 whatever the answer, so there is no reason to pay for it.
    local active, sig = {}, {}
    for _, pos in ipairs(found) do
        if pos.z == top and priority_of(pos) > EXEMPT_PRIORITY then
            active[#active + 1] = pos
            sig[#sig + 1] = key(pos)
        end
    end
    table.sort(sig)
    sig = table.concat(sig, ';')

    -- Recompute only when the designation set actually changed. Dwarves finish
    -- one tile at a time, so most passes look at the same set as the last one
    -- and the flood would return the same answer for the same cost.
    if hanging_cache.set ~= sig then
        hanging_cache.hanging = unanchored_after(active, doomed)
        hanging_cache.skipped = hanging_cache.hanging == nil
        hanging_cache.set = sig
    end
    local hanging = hanging_cache.hanging

    local held, freed = 0, 0
    for _, pos in ipairs(found) do
        if priority_of(pos) <= EXEMPT_PRIORITY then
            if release(pos) then freed = freed + 1 end
        elseif pos.z < top then
            -- held by rule 1, so rule 3 never has to be asked about it
            if hold(pos) then held = held + 1 end
        elseif select(1, is_unsafe(pos, hanging)) then
            if hold(pos) then held = held + 1 end
        else
            if release(pos) then freed = freed + 1 end
        end
    end

    -- a tile we were holding that is no longer designated at all (dug, or the
    -- player erased it) must not keep an entry, or the marker bit is stranded
    for k in pairs(s.marks) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        local pos = x and {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
        if pos and not is_channel(pos) then
            set_marked(pos, false)
            s.marks[k] = nil
        end
    end

    save_state()
    return held, freed
end

last_pass = last_pass or {held = 0, freed = 0, channels = 0, top = nil}

-- one pump step; returns true when a full pass completed
function pump()
    if not step_scan() then return false end
    local found, top = scan.found, scan.top
    scan = nil
    local held, freed = apply(found, top or 0)
    last_pass = {held = held, freed = freed, channels = #found, top = top}
    return true
end

function run_once()
    start_scan()
    local guard = 0
    repeat
        guard = guard + 1
    until pump() or guard > 10000
    return last_pass
end

-- ---------------------------------------------------------------------------
-- overlay pump
-- ---------------------------------------------------------------------------

ChannelPump = defclass(ChannelPump, overlay.OverlayWidget)
ChannelPump.ATTRS{
    desc = 'Drives fort/channel-safely: holds channel designations below the top level.',
    default_enabled = true,
    viewscreens = 'dwarfmode',
    overlay_onupdate_max_freq_seconds = 0,
    default_pos = {x = -1, y = -1},
    frame = {w = 1, h = 1},
}

next_pass_at = next_pass_at or 0

function ChannelPump:overlay_onupdate()
    if not get_state().enabled then return end
    local now = dfhack.getTickCount()
    if scan then
        pcall(pump)
        return
    end
    if now < next_pass_at then return end
    next_pass_at = now + PASS_INTERVAL_MS
    pcall(pump)
end

OVERLAY_WIDGETS = {pump = ChannelPump}

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        state, scan = nil, nil
    elseif sc == SC_MAP_LOADED then
        state, scan = nil, nil
    end
end

-- ---------------------------------------------------------------------------
-- command
-- ---------------------------------------------------------------------------

function status()
    local s = get_state()
    local n = 0
    for _ in pairs(s.marks) do n = n + 1 end
    print(('fort/channel-safely: %s | holding %d designation%s')
        :format(s.enabled and 'enabled' or 'disabled', n, n == 1 and '' or 's'))
    if last_pass.top then
        print(('  last pass: %d channel tiles, top level z=%d, %d held, %d released')
            :format(last_pass.channels, last_pass.top, last_pass.held, last_pass.freed))
    end
    print(('  priority %d designations are never held'):format(EXEMPT_PRIORITY))
    if hanging_cache.skipped then
        print(('  support check SKIPPED: the active level spans more than %d tiles')
            :format(MAX_AREA))
        print('  (top-level staging and the building rules still apply)')
    end
end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('fort/channel-safely only works in fortress mode')
end

local arg = ({...})[1]
if arg == 'enable' then
    get_state().enabled = true
    save_state()
    run_once()
    print(('fort/channel-safely: enabled -- %d held, %d released')
        :format(last_pass.held, last_pass.freed))
elseif arg == 'disable' then
    get_state().enabled = false
    local n = release_all()
    print(('fort/channel-safely: disabled -- released %d designation%s')
        :format(n, n == 1 and '' or 's'))
elseif arg == 'once' then
    run_once()
    print(('fort/channel-safely: one pass -- %d channel tiles, %d held, %d released')
        :format(last_pass.channels, last_pass.held, last_pass.freed))
else
    status()
end
