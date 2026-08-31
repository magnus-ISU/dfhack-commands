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
    3. Never channel a tile that is the LAST place a dwarf can stand to dig
       another channel tile that is still waiting. Channelling away a standing
       spot leaves the tile it served undiggable forever, and the hole is
       abandoned half finished with no error reported anywhere. Holding those
       back produces the order you would use by hand: start at the far end and
       retreat toward the way in. Reachability is DF's own walkability group
       (`block.walkable`), compared against the group the citizens are standing
       in, so it costs an integer comparison rather than a path search.
    4. Never channel a tile whose removal would drop the floor it is holding
       up. Against the map AS IT STANDS, find the tiles that hold a piece of
       rock onto the rest of it -- articulation points, 8-connected as DF's own
       support is, anchored at the walls -- and hold those back. A ring is then
       dug from both ends and the tile that would close it waits until the floor
       inside has gone.

  The first version of rule 4 asked the wrong question, and a fort caved in on
  the first attempt because of it. It simulated the entire active channel set as
  already dug and looked for what was left hanging -- but at the end of a
  full-level channel job almost nothing is left standing, so almost nothing was
  ever flagged. The danger is not the final state, it is every state on the way
  there: dwarves take the released designations in whatever order suits them,
  and the instant one completes a ring the floor inside drops. Asking instead
  which single tile removals would strand something answers that.

  Rule 4 is a real connectivity search, not a neighbour count, so it catches an
  unanchored region of any shape -- but it is bounded, and those bounds are
  where it stops being a guarantee:

    * Only SINGLE removals are checked. Dwarves dig concurrently, so two
      released tiles can go at the same moment and strand something neither
      would have alone.

    * It looks only at the bounding box of the active channel set plus a small
      margin. Support running off the edge of that box is ASSUMED anchored,
      because it usually is, and assuming otherwise would hold back half a fort.
    * Above 10,000 tiles the check is skipped entirely and says so.
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

A TRAP WORTH KNOWING ABOUT, IF YOU EVER TOUCH THIS CODE
  `block_flags.designated` means "this block has designation JOBS", and a
  designation in marker mode has no job. So the flag goes FALSE on a block as
  soon as the last of its designations is one this tool is holding -- and a scan
  filtered on that flag loses sight of precisely the tiles it suspended. They
  can never be re-examined, never released, and sit as "planned" forever, which
  is what a stuck job looks like from the player's side. Confirmed on a live
  fort: a block with three marker-mode channel designations reported
  `designated = false`. The scan therefore always examines the blocks holding
  its own marks as well, which persistence knows.

WHEN IT GETS IN ITS OWN WAY
  "Never strand a tile" and "always finish the job" can contradict each other: a
  shaft designated from the inside has no safe first tile, and in a ring every
  tile is the last way to the next. Held to the rule the whole level would sit
  suspended forever, which is indistinguishable from the tool being broken. So
  when nothing on the active level is workable, exactly one tile is let through
  -- whichever is the last foothold for the fewest others -- and you get told.
  That release is sticky: a pass runs every couple of seconds and a dwarf takes
  far longer to walk over, so re-deciding the tile each pass would re-hold it
  before anyone could dig it and it would flicker between planned and active
  instead of getting done.

ANNOUNCEMENTS
  Three situations raise a fortress announcement, once each, cleared when the
  situation goes away:

    * designations that cannot be reached at all (nothing walkable and
      fort-connected beside them), which no ordering can fix
    * the escape valve above firing
    * the channelled area being too large for the cave-in check

  `fort/channel-safely` on its own prints the same state to the DFHack console
  -- what it is holding, the last pass's numbers, and any of the above that is
  currently true. That console readout is what "status" means here; there is no
  separate status screen.

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

-- WHAT WOULD FALL IF ONE MORE TILE WENT
--
-- The first version of this asked the wrong question. It simulated the ENTIRE
-- active channel set as already dug and looked for what was left hanging -- and
-- at the end of a full-level channel job almost nothing is left standing, so
-- almost nothing was ever flagged. It sailed through a real excavation and the
-- fort caved in on the first attempt.
--
-- The danger is not the final state, it is every state on the way to it.
-- Dwarves take the released designations in whatever order suits them, and the
-- instant one of them completes a ring, the floor inside the ring drops. So the
-- question has to be asked against the map AS IT IS NOW: would removing this
-- one tile leave a piece of floor with nothing holding it up?
--
-- That is exactly an articulation point -- a tile whose removal splits the
-- standing rock into a piece containing no wall. One depth-first pass finds all
-- of them at once, for the same cost as the old flood, and answers the question
-- that matters. A ring then gets dug from both ends, and the tile that would
-- close it is held until the floor inside has been taken out.
--
-- Reading the map is cheap for the reasons measured earlier: tiletypes come
-- from cached blocks through a precomputed shape table (8ms per 10,000 tiles
-- against 1491ms the obvious way) and the grid is a flat integer-indexed array.
--
-- What this still does not cover: dwarves dig concurrently, so two released
-- tiles can go at the same moment and strand something neither would have alone.
-- Single-tile removal is what is checked, and that is the honest limit of
-- "cheap, not a guarantee".
function analyse(active, removed)
    if #active == 0 then return {}, {} end
    local z = active[1].z
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(active) do
        x0, y0 = math.min(x0, p.x), math.min(y0, p.y)
        x1, y1 = math.max(x1, p.x), math.max(y1, p.y)
    end
    x0, y0, x1, y1 = x0 - MARGIN, y0 - MARGIN, x1 + MARGIN, y1 + MARGIN
    local w, h = x1 - x0 + 1, y1 - y0 + 1
    if w * h > MAX_AREA then return nil, nil end

    local codes, grid, blocks = shape_code_table(), {}, {}
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
            local b = block_at(x, y)
            local code = b and (codes[b.tiletype[x % 16][y % 16]] or SHAPE_OPEN) or SHAPE_OPEN
            -- `removed` lets a caller ask "what if these were already dug"; it
            -- is what the ring test uses, and is nil in normal operation
            if removed and removed[key({x = x, y = y, z = z})] then code = SHAPE_OPEN end
            grid[ix * h + iy] = code
        end
    end

    -- Anchored tiles are those touching a wall, plus standing tiles on the edge
    -- of the examined box (support may well continue outside it). Treat them all
    -- as hanging off one virtual root: "still attached to the rock" then means
    -- "still reachable from that root".
    local adj_root = {}
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local i = ix * h + iy
            if grid[i] == SHAPE_SUPPORT then
                if ix == 0 or iy == 0 or ix == w - 1 or iy == h - 1 then
                    adj_root[i] = true
                else
                    for _, d in ipairs(NEIGHBOURS) do
                        local nx, ny = ix + d.x, iy + d.y
                        if nx >= 0 and ny >= 0 and nx < w and ny < h
                                and grid[nx * h + ny] == SHAPE_WALL then
                            adj_root[i] = true
                            break
                        end
                    end
                end
            end
        end
    end

    local disc, low, parent, cut = {}, {}, {}, {}
    local timer = 0

    -- Iterative depth-first search: 10,000 tiles would blow the lua stack if
    -- this recursed.
    local function dfs(root)
        timer = timer + 1
        disc[root], low[root], parent[root] = timer, timer, -1
        local stack = {{node = root, ni = 0}}
        while #stack > 0 do
            local top = stack[#stack]
            local u = top.node
            top.ni = top.ni + 1
            if top.ni <= #NEIGHBOURS then
                local d = NEIGHBOURS[top.ni]
                local nx, ny = (u // h) + d.x, (u % h) + d.y
                if nx >= 0 and ny >= 0 and nx < w and ny < h then
                    local v = nx * h + ny
                    if grid[v] == SHAPE_SUPPORT then
                        if not disc[v] then
                            parent[v] = u
                            timer = timer + 1
                            disc[v], low[v] = timer, timer
                            stack[#stack + 1] = {node = v, ni = 0}
                        elseif v ~= parent[u] and disc[v] < low[u] then
                            low[u] = disc[v]
                        end
                    end
                end
            else
                stack[#stack] = nil
                local p = parent[u]
                if p and p >= 0 then
                    if low[u] < low[p] then low[p] = low[u] end
                    -- p holds u's subtree on, and that subtree has no wall of
                    -- its own to hang from
                    if low[u] >= disc[p] and not adj_root[u] then cut[p] = true end
                end
            end
        end
    end

    -- Search outward from the anchored tiles, so anything still undiscovered at
    -- the end is genuinely hanging rather than merely unvisited.
    for i in pairs(adj_root) do
        if not disc[i] then dfs(i) end
    end

    local cut_set, hanging = {}, {}
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local i = ix * h + iy
            if grid[i] == SHAPE_SUPPORT then
                local k = key({x = x0 + ix, y = y0 + iy, z = z})
                if not disc[i] then
                    hanging[k] = true
                elseif cut[i] then
                    cut_set[k] = true
                end
            end
        end
    end
    return cut_set, hanging
end

-- rule 2, plus the answers computed above
local function is_unsafe(pos, cut_set, hanging)
    if has_building(pos) then return true, 'a building stands on it' end
    local below = {x = pos.x, y = pos.y, z = pos.z - 1}
    if has_building(below) then return true, 'a building stands under it' end
    if cut_set and cut_set[key(pos)] then
        return true, 'digging it would drop the floor it holds up'
    end
    if hanging then
        for _, d in ipairs(NEIGHBOURS) do
            if hanging[('%d,%d,%d'):format(pos.x + d.x, pos.y + d.y, pos.z)] then
                return true, 'the floor beside it is already unsupported'
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- rule 4: keep the rest of the job reachable
-- ---------------------------------------------------------------------------
--
-- A dwarf channels a tile while standing on a walkable tile beside it. Dig the
-- tiles in a careless order and the standing spot for a later tile is the first
-- thing to go: the designation survives, nothing can ever be done about it, and
-- the hole is left half finished with no error anywhere.
--
-- So a channel tile is held back when it is the LAST standing spot of another
-- channel tile that still has to be dug. What falls out of that is the order
-- you would dig by hand -- start at the far end, retreat toward the way in,
-- and the last tile channelled is the one nearest the exit.
--
-- Reachability is free here. DF keeps a walkability group per tile
-- (block.walkable, 0 meaning non-walkable, equal non-zero values meaning
-- mutually reachable), so "could a dwarf stand there and get to it" is an
-- integer comparison against the group the fort's citizens are standing in --
-- no flood fill, unlike the cave-in rule.
--
-- Access from BELOW is not counted. Channelling drops a ramp into the tile
-- underneath, and a dwarf on that ramp can sometimes reach the level above;
-- ignoring that holds back a few more tiles than strictly necessary, which is
-- the safe direction to be wrong in.

-- the walkability group the fort itself lives in, by majority of its citizens
function fort_group()
    local counts, best, bestn = {}, nil, 0
    local citizens = dfhack.units.getCitizens(true)
    for i, u in ipairs(citizens) do
        if i > 10 then break end
        local g = dfhack.maps.getWalkableGroup(u.pos)
        if g and g ~= 0 then
            counts[g] = (counts[g] or 0) + 1
            if counts[g] > bestn then best, bestn = g, counts[g] end
        end
    end
    return best
end

-- walkable, fort-connected neighbours of pos on its own z level
function standing_spots(pos, group)
    local spots = {}
    for _, d in ipairs(NEIGHBOURS) do
        local n = {x = pos.x + d.x, y = pos.y + d.y, z = pos.z}
        if dfhack.maps.getWalkableGroup(n) == group then
            spots[#spots + 1] = n
        end
    end
    return spots
end

-- Returns two sets keyed like `doomed`: tiles that must be held because they
-- are some other pending tile's last standing spot, and tiles that already have
-- nowhere to stand at all (nothing can be done for those -- they are reported).
function access_holds(active)
    local group = fort_group()
    if not group then return {}, {} end
    local pending = {}
    for _, pos in ipairs(active) do pending[key(pos)] = true end

    local critical, stranded = {}, {}
    for _, pos in ipairs(active) do
        local spots = standing_spots(pos, group)
        if #spots == 0 then
            stranded[key(pos)] = true
        elseif #spots == 1 then
            -- its only standing spot: if that spot is itself waiting to be
            -- channelled, digging it strands this tile
            local k = key(spots[1])
            if pending[k] then critical[k] = true end
        end
    end
    return critical, stranded
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


-- Announcements. Each situation is reported once, when it starts, and the latch
-- clears when it goes away -- the same shape as auto-elf-chop's "no burrow"
-- warning. These are all cases where the tool is not doing the obvious thing
-- and the player would otherwise be left wondering why digging stopped.
local warned = {}

local function announce(id, msg)
    if warned[id] then return end
    warned[id] = true
    pcall(dfhack.gui.showAnnouncement, 'channel-safely: ' .. msg, COLOR_YELLOW, true)
    print('fort/channel-safely: ' .. msg)
end

local function clear_warning(id) warned[id] = nil end

-- ---------------------------------------------------------------------------
-- the pass
-- ---------------------------------------------------------------------------

-- Collect every channel designation on the map. Cheap because block_flags
-- .designated (HAS_DESJOB) tells us which blocks have designation jobs at all,
-- so the 256-tile read only happens on the handful that matter.
local scan = nil

-- Blocks holding a designation WE put into marker mode. This set is the whole
-- reason the scan below is not a straight flags.designated filter: see there.
local function marked_blocks()
    local set = {}
    for k in pairs(get_state().marks) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        if x then
            set[(tonumber(x) // 16) .. ',' .. (tonumber(y) // 16) .. ',' .. z] = true
        end
    end
    return set
end

local function start_scan()
    scan = {i = 0, blocks = df.global.world.map.map_blocks, found = {}, top = nil,
            marked = marked_blocks()}
end

-- returns true when the scan finished this call
local function step_scan()
    if not scan then start_scan() end
    local blocks = scan.blocks
    local last = math.min(scan.i + BLOCKS_PER_PASS, #blocks)
    while scan.i < last do
        local block = blocks[scan.i]
        scan.i = scan.i + 1
        -- flags.designated means "has designation JOBS", and a designation in
        -- marker mode has no job -- so the flag goes FALSE on a block once the
        -- last of its designations is one we are holding. Filtering on the flag
        -- alone therefore loses sight of exactly the tiles this tool is
        -- suspending: they can never be re-examined, never released, and sit in
        -- "planned" forever. Measured on a live fort: a block with three
        -- marker-mode channel designations reported designated = false. So the
        -- blocks holding our own marks are always examined too.
        local wanted = block and block.flags.designated
        if block and not wanted then
            wanted = scan.marked[(block.map_pos.x // 16) .. ',' ..
                                 (block.map_pos.y // 16) .. ',' .. block.map_pos.z]
        end
        if wanted then
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
    local active, active_all, sig = {}, {}, {}
    for _, pos in ipairs(found) do
        if pos.z == top then
            active_all[#active_all + 1] = pos
            if priority_of(pos) > EXEMPT_PRIORITY then
                active[#active + 1] = pos
                sig[#sig + 1] = key(pos)
            end
        end
    end
    table.sort(sig)
    sig = table.concat(sig, ';')

    -- Recompute only when the designation set actually changed. Dwarves finish
    -- one tile at a time, so most passes look at the same set as the last one
    -- and the flood would return the same answer for the same cost.
    if hanging_cache.set ~= sig then
        local cut_set, hanging = analyse(active)
        hanging_cache.cut, hanging_cache.hanging = cut_set, hanging
        hanging_cache.skipped = cut_set == nil
        hanging_cache.set = sig
    end
    local cut_set, hanging = hanging_cache.cut, hanging_cache.hanging

    -- rule 4 looks at the whole active level, priority 1 tiles included: those
    -- are never held, but they still have to be reachable, so they count when
    -- deciding whether some other tile is about to remove their last foothold
    local critical, stranded = access_holds(active_all)

    local n_stranded = 0
    for _ in pairs(stranded) do n_stranded = n_stranded + 1 end
    if n_stranded > 0 then
        announce('stranded', ('%d channel designation%s cannot be reached -- no tile '
            .. 'beside %s is both walkable and connected to the fort')
            :format(n_stranded, n_stranded == 1 and '' or 's',
                    n_stranded == 1 and 'it' or 'them'))
    else
        clear_warning('stranded')
    end

    -- Counted as TOTALS, not as changes made this pass: a pass that alters
    -- nothing was reporting "0 held" while two designations sat suspended.
    local held, freed, released_here = 0, 0, 0
    local function decide(pos)
        local k = key(pos)
        if priority_of(pos) <= EXEMPT_PRIORITY then return 'release' end
        if s.valve == k then return 'release' end   -- let through by the valve
        if pos.z < top then return 'hold' end          -- rule 1
        if select(1, is_unsafe(pos, cut_set, hanging)) then return 'hold' end
        if critical[k] then return 'hold' end          -- rule 4
        return 'release'
    end

    local all_held = {}
    for _, pos in ipairs(found) do
        local what = decide(pos)
        if what == 'hold' then
            hold(pos)
            held = held + 1
            if pos.z == top then all_held[#all_held + 1] = pos end
        else
            release(pos)
            freed = freed + 1
            if pos.z == top then released_here = released_here + 1 end
        end
    end

    -- The escape valve. "Never strand anything" and "always finish the job" can
    -- contradict each other -- a shaft designated from inside it has no safe
    -- first tile, and every tile in a ring is the last way to the next. Left
    -- alone the whole level would sit held forever, which looks exactly like
    -- the tool being broken. So when nothing on the active level is workable,
    -- one tile is let through: the one that is the last foothold for the fewest
    -- others, breaking ties by priority.
    if released_here == 0 and #all_held > 0 then
        local best, best_cost
        for _, pos in ipairs(all_held) do
            if critical[key(pos)] then
                local cost = 0
                for _, other in ipairs(active_all) do
                    local spots = standing_spots(other, fort_group() or -1)
                    if #spots == 1 and key(spots[1]) == key(pos) then cost = cost + 1 end
                end
                cost = cost * 10 + priority_of(pos)
                if not best_cost or cost < best_cost then best, best_cost = pos, cost end
            end
        end
        best = best or all_held[1]
        release(best)
        released_here = released_here + 1
        -- Sticky. A pass runs every couple of seconds and a dwarf takes far
        -- longer than that to walk over, so re-deciding this tile on the next
        -- pass would re-hold it before anyone could dig it, and it would
        -- flicker between planned and active forever instead of getting done.
        s.valve = key(best)
        freed = freed + 1
        held = math.max(0, held - 1)
        announce('deadlock', ('every channel designation on this level would strand '
            .. 'another; released the one at %d,%d,%d so the work can proceed -- '
            .. 'check that stretch by eye'):format(best.x, best.y, best.z))
    else
        clear_warning('deadlock')
    end

    if hanging_cache.skipped then
        announce('too_big', ('the channelled area is larger than %d tiles, so the '
            .. 'cave-in check is skipped -- staging and the building rules still apply')
            :format(MAX_AREA))
    else
        clear_warning('too_big')
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
    if s.valve and not is_channel({
            x = tonumber(s.valve:match('^(-?%d+)')),
            y = tonumber(s.valve:match('^-?%d+,(-?%d+)')),
            z = tonumber(s.valve:match('(-?%d+)$'))}) then
        s.valve = nil          -- the tile it let through has been dug
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
