-- Stage channel designations so only the top level is ever dug.
--@module = true
--[[
fort/channel-safely

Channelling a large hole by hand is miserable: dwarves cut the floor out from
under each other, drop into their own work, and close a ring around a patch of
floor that then falls on somebody. This takes the designation over and feeds it
back to them one tile at a time, in an order it can prove is safe.

    fort/channel-safely            status
    fort/channel-safely enable     start managing channel designations
    fort/channel-safely disable    stop, and hand every held designation back
    fort/channel-safely once       run a single pass now

HOW IT WORKS

  Suspend on sight. A channel designation is put into marker mode the instant it
  is seen, before anything is known about it. That is not caution, it is the
  only workable order of operations: DF turns a designation into a job promptly,
  and the moment it does the tile's dig field is CLEARED -- the work stops living
  on the map, and marker mode has nothing left to hold. Judging first and
  suspending afterwards loses every tile the scheduler reached first, which is
  what caved three forts in during development. The visible cost is a flicker as
  a freshly drawn area shows planned before anything is let out.

  A few at a time, never side by side. Up to eight tiles are out of the
  blueprint at once and no two of them touch, so two miners can never take
  neighbouring tiles and drop a floor that neither would alone. Each pick is
  chosen with the ones before it imagined as ALREADY CHANNELLED OUT, and the
  whole judgement is recomputed between picks -- that is what stops eight
  individually reasonable choices from adding up to a collapse.

  Everything already let out -- released but not yet dug, or in a dwarf's hands
  as a job -- counts the same way: a HOLE THAT EXISTS, holding nothing up, with
  nobody able to stand on it. Being pessimistic about work in flight is what
  makes a release provable rather than merely plausible.

  Two tests, both against that pretend map. A candidate is released only if
  digging it leaves nothing hanging that was not hanging already, and if every
  other designated tile still has somewhere to stand that connects out of the
  excavation. The first is a connectivity search over the standing rock,
  anchored at the walls; the second floods DF's own walkability groups inward
  from the edge of the area, with the pretend holes knocked out.

  Candidates are tried farthest-from-the-middle first, which is the order a
  dwarf would choose anyway: start at the far end and retreat toward the way in.

  When nothing can be proven safe, everything simply stays planned. A ring drawn
  around floor that is not itself designated has no safe order and will sit
  suspended: designate the floor inside it, or dig those tiles by hand.

PRIORITY 1 IS THE ESCAPE HATCH
  A designation at priority 1 is never touched. That is the way to say "dig this
  now, I know what I am doing".

WHAT IT TOUCHES
  `designation.traffic` on tiles it lets out: a tile about to become a hole is
  set to restricted so nobody walks over it while it is being cut. Whatever the
  tile had before is remembered and put back if it returns to the blueprint or
  the designation is cancelled, so a route deliberately marked low or high is
  not quietly rewritten.

  `occupancy.dig_marked`, DF's marker-mode bit, and `block_flags.designated`,
  which has to be re-raised whenever a marker is cleared or DF never schedules
  the tile. While enabled it OWNS the marker bit for channel designations, so a
  suspension set by hand does not stick; `disable` hands everything back.

  Jobs are READ, never written, with one exception: a job issued for a tile that
  has not been cleared is removed and the tile written straight back as a
  suspended designation, so nothing is lost. That happens a frame later from a
  timeout, never inside the event callback -- removing a job while DFHack's
  event manager still holds it is a SIGSEGV in Core::onUpdate. A job somebody is
  already working is left strictly alone and planned around.

WHERE IT STOPS BEING A GUARANTEE
  The searches cover the bounding box of the designation plus a small margin,
  and skip entirely above 10,000 tiles. Support running off the edge of that box
  is assumed anchored. Everything is reasoned one z-level at a time, so a floor
  cut loose by digging below it is not this tool's business. And it only manages
  channel designations: ordinary mining that undercuts something is not seen.
]]

local overlay = require('plugins.overlay')

local GLOBAL_KEY = 'channel-safely'

-- priority at or above which a designation is never held back. DF priorities run
-- 1 (highest) .. 7 (lowest); the priority event stores them the same way.
local EXEMPT_PRIORITY = 1
local DEFAULT_PRIORITY = 4      -- what DF uses when a block has no priority event

-- Blocks examined per frame. The sweep never idles -- an idle gap is a window
-- in which a fresh designation can become a job before it is seen -- so this is
-- the only thing bounding the per-frame cost. 800 pointer tests a frame sweeps
-- a 25,000 block map about twice a second.
local BLOCKS_PER_PASS = 800

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

-- marks = { ["x,y,z"] = true } for every tile WE put into marker mode
local state = nil

local function default_state()
    return {enabled = false, marks = {}, allowed = {}, watch = {}, traffic = {}}
end

local function get_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, default_state())
        state.marks = state.marks or {}
        state.allowed = state.allowed or {}
        state.watch = state.watch or {}
        state.traffic = state.traffic or {}
    end
    return state
end

local function save_state()
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, get_state())
end

local function key(pos) return ('%d,%d,%d'):format(pos.x, pos.y, pos.z) end

-- Declared up here because both the event hook and the pass queue into it, and
-- the pass is defined long before the hook is.
local pending_reclaim = {}
local process_reclaims          -- forward declaration

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

-- How many tiles may be out of the blueprint at once. Never two of them
-- adjacent, and each one is chosen with the ones before it imagined as already
-- channelled out, so the set as a whole is provable rather than eight
-- individually plausible picks.
local MAX_CONCURRENT = 8

-- How far past the designation the support search looks. Tiles on the EDGE of
-- that box are assumed anchored, because support usually does continue outside
-- it -- so the margin is really "how far away that assumption is made". At 3 it
-- was being made right next to the work, which is exactly where a designation
-- beside an existing pit gets a false anchor and a candidate is cleared on the
-- strength of it.
local MARGIN = 8
local MAX_AREA = 10000         -- a 100x100 excavation; measured at ~16ms

-- A designation bigger than MAX_AREA used to end the story: `analyse` returned
-- nil for the oversized box, `choose_release` saw no base to compare against
-- and gave up, and every tile of a big channel sat held forever -- the tool
-- looked enabled and did nothing. So an oversized set is judged through a
-- WINDOW around the candidate instead of all at once. Support and stranding
-- are local questions: what holds a tile up is its neighbours, and a flood that
-- reaches the window's border has reached the rest of the fort. This is the
-- same computation the small case does, just centred on the tile being weighed
-- rather than on the whole excavation.
local WINDOW = 20              -- a 41x41 box around the candidate

-- Weighing one candidate costs two grid builds and a flood. Trying every tile
-- of a thousand-tile designation, eight times over, every frame, is what took
-- the fort to 8 FPS. A pass looks at this many and stops, resuming where it
-- left off next time, so every tile still gets its turn -- just not all in one
-- frame.
local CANDIDATES_PER_PASS = 24

-- and a pass does not start every frame either
local PASS_INTERVAL_MS = 1000

-- where the last pass stopped weighing candidates. Deliberately NOT in the
-- persisted state: it is progress through one pass, not a decision about the
-- fort, and writing it to the save every second would be noise.
release_cursor = release_cursor or 0

-- set when a pass found channel work but no part of it can be reached yet: a
-- designation drawn across undug rock is waiting on the tunnel to it, not on
-- this tool, and `status` should say which of the two it is
unreachable_pass = unreachable_pass or false

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

-- Support travels along the four sides ONLY. A floor touching another floor at
-- the corner is not held up by it -- which is exactly the mistake that made
-- this clear tiles that then fell, since an 8-connected flood finds support
-- paths through diagonals that do not carry any weight. The 8-way set above is
-- still right for two other things: keeping jobs out of all eight neighbours,
-- and walking, because dwarves do move diagonally.
local ORTHO = {{x = 1, y = 0}, {x = -1, y = 0}, {x = 0, y = 1}, {x = 0, y = -1}}

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

    -- The level BELOW, read the same way. A floor sitting straight on top of
    -- rock is held up by that rock no matter what its own neighbours do, so
    -- without this the search calls solid ground unsupported and refuses work
    -- it should allow.
    local below, bblocks = {}, {}
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local x, y = x0 + ix, y0 + iy
            local bk = (x // 16) * 4096 + (y // 16)
            local b = bblocks[bk]
            if b == nil then
                b = dfhack.maps.getTileBlock({x = x, y = y, z = z - 1}) or false
                bblocks[bk] = b
            end
            below[ix * h + iy] = b and (codes[b.tiletype[x % 16][y % 16]] or SHAPE_OPEN)
                                   or SHAPE_OPEN
        end
    end

    -- What holds a tile up: rock along one of its four SIDES, rock directly
    -- underneath it, or running off the edge of the box (where support usually
    -- does continue). Corners hold up nothing.
    local adj_root = {}
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local i = ix * h + iy
            if grid[i] == SHAPE_SUPPORT then
                if ix == 0 or iy == 0 or ix == w - 1 or iy == h - 1
                        or below[i] == SHAPE_WALL then
                    adj_root[i] = true
                else
                    for _, d in ipairs(ORTHO) do
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
            if top.ni <= #ORTHO then
                local d = ORTHO[top.ni]
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


-- BOTH QUESTIONS, BECAUSE NEITHER IS ENOUGH ON ITS OWN
--
-- "Which single removal strands something" finds nothing on a freshly
-- designated plan: while the rock is still solid there are no articulation
-- points, so a ring is released whole and the miners are free to close it in
-- whatever order they like. Measured on a fresh 5x5 ring: 0 tiles held.
--
-- "If the whole plan were dug, what would be left hanging" answers that one --
-- the same ring reports the 9 tiles inside it as doomed before a single tile
-- is cut -- but it says nothing once digging is under way, because by then the
-- remaining designations no longer enclose anything.
--
-- So both are asked. The second runs to a fixpoint: tiles next to something
-- that would be left hanging are held, which shrinks the set that is going to
-- be dug, which can make other tiles safe, so it is re-asked until it settles.
--
-- In-flight dig jobs count as already gone. Putting a designation into marker
-- mode does not cancel a job a dwarf has already taken, and cancelling one
-- outright risks the crash that removeJob on a live job is known for, so the
-- honest thing is to plan around them: whatever has a job is treated as a hole
-- that already exists.
local MAX_SETTLE = 5

-- world.jobs.list is a LINKED LIST of job_list_link, not a vector. The first
-- version of this iterated it with ipairs, which silently walks nothing at all,
-- so every "count the jobs already under way" check quietly saw zero.
local function each_job(fn)
    local link = df.global.world.jobs.list.next
    while link do
        local job = link.item
        local nxt = link.next
        if job then fn(job) end
        link = nxt
    end
end

local function inflight_channels()
    local set = {}
    each_job(function(job)
        if job.job_type == df.job_type.DigChannel then set[key(job.pos)] = true end
    end)
    return set
end

-- Jobs are READ, never written.
--
-- Once DF turns a designation into a job the tile's dig field is cleared, so
-- there is nothing left to suspend and the work is out of reach. Two ways to
-- reach into it were tried and both are off the table: removeJob destroys the
-- work outright (measured -- the tile came back with no designation and no job,
-- the plan simply gone), and writing flags.suspend on a job a dwarf is actively
-- working is the kind of live-job mutation this repo has crashed on before.
--
-- So a tile that reached a job is accepted as lost to us and planned around --
-- treated as a hole that already exists. The answer to the race is not to
-- reach into jobs, it is to never let an unjudged tile become one: see
-- "default deny" below.

-- returns: support_holds (set), cut set, hanging set, or nil when over budget
function plan_support_holds(active)
    local inflight = inflight_channels()

    -- everything that could be dug, minus what we decide to hold
    local doomed = {}
    for _, p in ipairs(active) do doomed[key(p)] = true end
    for k in pairs(inflight) do doomed[k] = true end

    local holds = {}
    for _ = 1, MAX_SETTLE do
        local cut, hanging = analyse(active, doomed)
        if not cut then return nil end
        local changed = false
        for _, p in ipairs(active) do
            local k = key(p)
            if doomed[k] and not holds[k] and not inflight[k] then
                for _, d in ipairs(NEIGHBOURS) do
                    if hanging[('%d,%d,%d'):format(p.x + d.x, p.y + d.y, p.z)] then
                        holds[k], doomed[k], changed = true, nil, true
                        break
                    end
                end
            end
        end
        if not changed then break end
    end

    -- and the single-removal question, against the map as it stands plus
    -- whatever the miners are already part way through
    local cut_now, hanging_now = analyse(active, inflight)
    return holds, cut_now, hanging_now
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
-- Can a miner get to this tile AT ALL right now? Nothing else in this tool asks
-- that -- everything else asks whether digging it is SAFE -- and safe work that
-- cannot be started is still work that does not happen. Letting one out is worse
-- than useless: a released tile stays out until it is dug, so tiles nobody can
-- reach fill the working set and stop anything reachable from following them.
--
-- Two conditions, both measured on a 502-tile channel drawn across buried stone,
-- where DF had issued not one job in several minutes:
--
--   * NOT HIDDEN. 494 of those tiles were undiscovered rock. DF does not dig
--     what the fort has not seen, and a tile can be under a perfectly good floor
--     one level up and still be invisible.
--   * REACHABLE AT ITS OWN LEVEL -- standable itself, or with somewhere to stand
--     beside it. A floor directly ABOVE a wall does not help: you channel a tile
--     by standing on it, and you cannot stand inside rock. 151 of those tiles had
--     fort floor above them and none of them was ever dug.
--
-- Of 502 tiles that left exactly one workable, which is the honest answer: the
-- excavation opens from the one corner a miner can get to, and each tile dug
-- makes its neighbours reachable in turn.
function workable(pos, group)
    if not group then return true end          -- no fort to judge against: allow
    local d = designation_of(pos)
    if d and d.hidden then return false end
    if dfhack.maps.getWalkableGroup(pos) == group then return true end
    if #standing_spots(pos, group) > 0 then return true end

    -- And the way INTO an excavation that is already under way. A tile that has
    -- been channelled is a ramp top, and DF gives a ramp top no walkability group
    -- of its own -- but the ramp beneath it is fort-walkable, and coming up that
    -- ramp is how the miners have been reaching the next wall all along. Without
    -- this the tool digs until the last tile that touches ordinary floor and then
    -- stops dead with the excavation half cut: measured at 333 designations left,
    -- 49 of them revealed, every one beside a ramp, and none of them "reachable".
    --
    -- The neighbour has to be OPEN **and have a RAMP under it**, both. Open alone
    -- is not a way in and neither is walkable-below: a dwarf standing on a plain
    -- floor cannot climb into the empty tile above it. It is the ramp that carries
    -- them up, which is exactly the shape a channelled tile leaves behind -- ramp
    -- below, ramp top above. A wall with a corridor running underneath it is not a
    -- way in either, and counting either of those would put us back to releasing
    -- tiles nobody can stand near.
    local codes = shape_code_table()
    for _, dir in ipairs(NEIGHBOURS) do
        local n = {x = pos.x + dir.x, y = pos.y + dir.y, z = pos.z}
        local block, bx, by = tile_parts(n)
        if block and codes[block.tiletype[bx][by]] ~= SHAPE_WALL then
            local under = {x = n.x, y = n.y, z = n.z - 1}
            local ublock, ux, uy = tile_parts(under)
            if ublock
                and df.tiletype.attrs[ublock.tiletype[ux][uy]].shape
                    == df.tiletype_shape.RAMP
                and dfhack.maps.getWalkableGroup(under) == group then
                return true
            end
        end
    end
    return false
end

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
    local changed = block.occupancy[bx][by].dig_marked ~= marked
    block.occupancy[bx][by].dig_marked = marked
    -- Un-suspending is not enough on its own. block_flags.designated is how DF
    -- knows a block has designation work to schedule, and it stays FALSE after
    -- this tool clears a marker -- so the tile sits designated, unsuspended and
    -- untouched, with no job ever created for it. Seen live on 70,75,13: dig =
    -- Channel, marker cleared, and no dwarf ever came. Raising the flag is what
    -- quickfort's own dig code does after writing a designation, for the same
    -- reason.
    if not marked then block.flags.designated = true end
    return changed
end

-- A tile that has been let out is about to become a hole, so keep dwarves off
-- it: restrict traffic while it is out, and put the old setting back if it goes
-- back into the blueprint. Whatever the tile had before is remembered, so a
-- route deliberately marked low or high is not quietly rewritten to normal.
local function set_traffic(pos, value)
    local block, bx, by = tile_parts(pos)
    if not block then return end
    block.designation[bx][by].traffic = value
end

local function restrict(pos)
    local s, k = get_state(), key(pos)
    local block, bx, by = tile_parts(pos)
    if not block then return end
    if s.traffic[k] == nil then
        s.traffic[k] = block.designation[bx][by].traffic
    end
    set_traffic(pos, df.tile_traffic.Restricted)
end

local function unrestrict(pos)
    local s, k = get_state(), key(pos)
    if s.traffic[k] == nil then return end
    set_traffic(pos, s.traffic[k])
    s.traffic[k] = nil
end

local function hold(pos)
    local s = get_state()
    set_marked(pos, true)
    s.marks[key(pos)] = true       -- recorded even if the bit was already set
    unrestrict(pos)                -- back in the blueprint: walk on it again
    return true
end

-- Authoritative, and that is a deliberate change from tracking ownership.
--
-- Release used to clear the marker only for tiles recorded as ours, so that a
-- suspension set by hand was never undone. That bookkeeping cannot be kept
-- honest: a tile ended up marked while its record was missing, and from there
-- nothing could free it -- the sweep skipped it as "already suspended, not
-- ours", release skipped it as "not ours", and it sat planned for good while
-- every pass cheerfully reported it released. Watched live on 70,75,13.
--
-- So a decision to release now clears the bit whatever the records say. The
-- cost is real and worth stating: suspending a channel designation by hand no
-- longer sticks while this is enabled, because the tile will be judged and
-- released if it is safe. Priority 1 is how to say hands off, and `disable`
-- hands everything back.
local function release(pos)
    local s = get_state()
    local k = key(pos)
    local changed = set_marked(pos, false)
    s.marks[k] = nil
    restrict(pos)
    return changed
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


-- DEFAULT DENY
--
-- The whole reason this tool kept failing in a live fort: it decided at its own
-- pace, once every couple of seconds, while DF turns designations into jobs
-- promptly -- and the moment a designation becomes a job, the tile's dig field
-- is cleared and the work is beyond reach. Anything not yet judged could be
-- gone before the judging happened.
--
-- So the order is inverted. A channel designation is suspended the instant it
-- is SEEN, before anything is known about it, and released later only if the
-- analysis clears it. DF can then only ever build a job out of a tile that has
-- already been judged safe, and there is no window left to lose.
--
-- The visible cost is a flicker: a freshly drawn area shows as planned for the
-- fraction of a second before the safe parts are released. That is the trade
-- the fort owner asked for, and it beats losing tiles to the scheduler.
--
-- Tiles already released stay released (state.allowed), or the next sweep would
-- re-suspend everything and nothing would ever be dug. Marker mode set by the
-- player is never touched: only marks this tool made are in state.marks.
local function deny_on_sight(pos, block, bx, by)
    local s = get_state()
    local k = key(pos)
    if s.allowed[k] then return end            -- judged safe already
    if block.occupancy[bx][by].dig_marked then
        return                                 -- already suspended, ours or not
    end
    if priority_of(pos) <= EXEMPT_PRIORITY then return end
    block.occupancy[bx][by].dig_marked = true
    s.marks[k] = true
end

-- ---------------------------------------------------------------------------
-- the pass
-- ---------------------------------------------------------------------------

-- Collect every channel designation on the map. Cheap because block_flags
-- .designated (HAS_DESJOB) tells us which blocks have designation jobs at all,
-- so the 256-tile read only happens on the handful that matter.
local scan = nil

-- BLOCKS THAT MUST BE READ IN FULL, whatever their flags say.
--
-- block_flags.designated cannot be trusted as "this block contains
-- designations". DF sets it when a block has designation work to schedule and
-- clears it once it has processed the block -- INCLUDING when some designations
-- in that block did not become jobs. Measured in a live fort: a block holding
-- an active channel designation at 70,75,13 and a claimed job at 70,76,13
-- reported designated = false, so the sweep reported zero channel designations
-- while one sat there in plain view, never judged and free to be dug.
--
-- So every block this tool has ever seen channel work in is remembered, and
-- those are always read in full. The flag is still used as the cheap way to
-- notice work in blocks it has never looked at.
local function watched_blocks()
    local s = get_state()
    local set = {}
    for k in pairs(s.watch) do set[k] = true end
    for k in pairs(s.marks) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        if x then
            set[(tonumber(x) // 16) .. ',' .. (tonumber(y) // 16) .. ',' .. z] = true
        end
    end
    return set
end

local function block_key(pos)
    return (pos.x // 16) .. ',' .. (pos.y // 16) .. ',' .. pos.z
end

local function start_scan()
    scan = {i = 0, blocks = df.global.world.map.map_blocks, found = {}, top = nil,
            marked = watched_blocks(), seen = {}}
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
                        scan.seen[block_key(pos)] = true
                        deny_on_sight(pos, block, bx, by)
                    end
                end
            end
        end
    end
    return scan.i >= #blocks
end

-- the channel set the last rule-3 answer was computed for
local hanging_cache = {set = nil, hanging = nil, skipped = false}

-- ---------------------------------------------------------------------------
-- the pass: release ONE tile at a time, along an order it can prove
-- ---------------------------------------------------------------------------
--
-- Everything before this judged the whole designation every couple of seconds
-- and released whatever looked safe at that moment. Tile by tile each decision
-- was defensible, and the fort still caved in, because "safe now" says nothing
-- about the shape that is left after several of those releases have been dug.
--
-- So it commits to an order instead. At most ONE tile is out of the blueprint
-- at a time, and the next is not chosen until that one is actually gone. When
-- weighing a candidate, everything already let out -- released but not yet dug,
-- or already in a dwarf's hands as a job -- counts as a HOLE THAT EXISTS: it
-- holds nothing up and nobody can stand on it. That pessimism is what makes a
-- release provable rather than merely plausible.
--
-- A candidate has to pass both tests, against that pretend map:
--   * digging it leaves nothing hanging that was not hanging already, and
--   * every other designated tile still has somewhere to stand that connects
--     out of the excavation -- so no part of the job is stranded by getting to
--     this one.
--
-- Candidates are tried farthest-out first, which is the order a dwarf would
-- pick anyway: start at the far end, retreat toward the way in.

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- Tiles let out but not yet dug: still designated, or gone from the map into a
-- job somebody is carrying. Until this is empty, nothing else is released.
function outstanding(s)
    local jobs = inflight_channels()
    local out = {}
    for k in pairs(s.released or {}) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        local pos = x and {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
        if pos and (is_channel(pos) or jobs[k]) then out[k] = true end
    end
    for k in pairs(jobs) do out[k] = true end
    return out
end

-- Would digging `hyp` (a set of holes-to-be) leave any designated tile with
-- nowhere to stand that reaches the outside? Walkability comes from DF's own
-- groups, read straight out of the blocks, with the pretend holes knocked out.
function strands_work(active, hyp, group)
    if not group then return false end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for _, p in ipairs(active) do
        x0, y0 = math.min(x0, p.x), math.min(y0, p.y)
        x1, y1 = math.max(x1, p.x), math.max(y1, p.y)
    end
    x0, y0, x1, y1 = x0 - MARGIN, y0 - MARGIN, x1 + MARGIN, y1 + MARGIN
    local w, h, z = x1 - x0 + 1, y1 - y0 + 1, active[1].z
    if w * h > MAX_AREA then return false end

    local walk, blocks = {}, {}
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            local x, y = x0 + ix, y0 + iy
            local bk = (x // 16) * 4096 + (y // 16)
            local b = blocks[bk]
            if b == nil then
                b = dfhack.maps.getTileBlock({x = x, y = y, z = z}) or false
                blocks[bk] = b
            end
            local ok = b and b.walkable[x % 16][y % 16] == group
            if ok and hyp[key({x = x, y = y, z = z})] then ok = false end
            walk[ix * h + iy] = ok and true or false
        end
    end

    -- flood in from the border: those are the tiles that reach the rest of the
    -- fort, so a standing spot only counts if the flood got to it
    local seen, stack, sp = {}, {}, 0
    for ix = 0, w - 1 do
        for iy = 0, h - 1 do
            if (ix == 0 or iy == 0 or ix == w - 1 or iy == h - 1)
                    and walk[ix * h + iy] then
                local i = ix * h + iy
                seen[i] = true; sp = sp + 1; stack[sp] = i
            end
        end
    end
    while sp > 0 do
        local i = stack[sp]; sp = sp - 1
        local ix, iy = i // h, i % h
        for _, d in ipairs(NEIGHBOURS) do
            local nx, ny = ix + d.x, iy + d.y
            if nx >= 0 and ny >= 0 and nx < w and ny < h then
                local ni = nx * h + ny
                if walk[ni] and not seen[ni] then
                    seen[ni] = true; sp = sp + 1; stack[sp] = ni
                end
            end
        end
    end

    -- A designated tile that is STILL SOLID ROCK cannot be stranded. There is no
    -- floor under it to lose, and it needs no standing spot yet -- the excavation
    -- opens its own way in as it is dug. Asking for one anyway is not a
    -- conservative reading, it is a wrong one: a 504-tile channel drawn across
    -- hidden stone has nothing walkable anywhere near it, so every tile failed
    -- this test, every pass, and the whole designation sat held forever while the
    -- test was re-run against all 504 of them on every frame.
    local codes = shape_code_table()
    local function solid(p)
        local bk = (p.x // 16) * 4096 + (p.y // 16)
        local b = blocks[bk]
        if b == nil then
            b = dfhack.maps.getTileBlock({x = p.x, y = p.y, z = p.z}) or false
            blocks[bk] = b
        end
        return b and codes[b.tiletype[p.x % 16][p.y % 16]] == SHAPE_WALL
    end

    for _, p in ipairs(active) do
        if not hyp[key(p)] and not solid(p) then
            local reachable = false
            for _, d in ipairs(NEIGHBOURS) do
                local ix, iy = p.x + d.x - x0, p.y + d.y - y0
                if ix >= 0 and iy >= 0 and ix < w and iy < h and seen[ix * h + iy] then
                    reachable = true
                    break
                end
            end
            if not reachable then return true end
        end
    end
    return false
end

-- the one tile to let out next, or nil if nothing can be proven safe
-- the active tiles near enough to a candidate to bear on it
local function window_active(active, cand)
    local sub = {}
    for _, p in ipairs(active) do
        if math.abs(p.x - cand.x) <= WINDOW and math.abs(p.y - cand.y) <= WINDOW then
            sub[#sub + 1] = p
        end
    end
    return sub
end

function choose_release(active, phantom, group)
    local _, base = analyse(active, phantom)
    -- nil means the excavation is bigger than one grid can hold: judge each
    -- candidate through its own window instead of abandoning the whole thing
    local windowed = base == nil
    local base_n = base and count(base) or 0

    -- farthest from the middle of the shape first -- but REACHABLE tiles ahead of
    -- unreachable ones.
    --
    -- Farthest-first is the order a dwarf would pick in an open excavation: start
    -- at the far end and retreat toward the way in. It is the wrong order for a
    -- designation drawn across solid rock, where the far end is buried and no
    -- miner can get to it -- the tool let out eight tiles nobody could reach, DF
    -- issued no job for any of them, and since a released tile stays out until it
    -- is dug, the working set filled up with work that could never happen and the
    -- excavation never started. In an open excavation every tile is reachable, so
    -- this sorts on nothing and the old order stands.
    local cx, cy = 0, 0
    for _, p in ipairs(active) do cx, cy = cx + p.x, cy + p.y end
    cx, cy = cx / #active, cy / #active
    local order = {}
    for _, p in ipairs(active) do
        if not phantom[key(p)] then order[#order + 1] = p end
    end
    -- Unreachable tiles are not candidates at all. Letting one out does nothing --
    -- DF issues no job for a tile no miner can get to -- and it is not free
    -- either: a released tile stays out until it is dug, so eight of them fill
    -- the working set and stop anything reachable from being released later.
    local kept = {}
    for _, p in ipairs(order) do
        if workable(p, group) then kept[#kept + 1] = p end
    end
    order = kept
    if #order == 0 then
        unreachable_pass = true
        return nil
    end
    unreachable_pass = false
    table.sort(order, function(a, b)
        local da = (a.x - cx) ^ 2 + (a.y - cy) ^ 2
        local db = (b.x - cx) ^ 2 + (b.y - cy) ^ 2
        if da ~= db then return da > db end
        return key(a) < key(b)
    end)

    -- Resume where the last pass stopped. The order is stable for a given
    -- shape, so walking it a slice at a time still reaches every tile -- and a
    -- tile that could not be released last pass is usually not the one that can
    -- this pass either, so starting from the top every time is wasted work as
    -- well as slow.
    local start = release_cursor % math.max(#order, 1)
    local looked = 0
    for n = 1, #order do
        local cand = order[((start + n - 1) % #order) + 1]
        looked = looked + 1
        if looked > CANDIDATES_PER_PASS then
            release_cursor = start + n - 1
            return nil
        end
        -- Anything standing on the tile, or on the tile above it, comes down
        -- with the floor. This check existed, then was dropped in a rewrite and
        -- nothing called it for several versions -- restored, and now looking
        -- up as well, since a construction one level above loses its floor just
        -- as surely as one standing on the tile itself.
        local above = {x = cand.x, y = cand.y, z = cand.z + 1}
        if has_building(cand) or has_building(above)
                or has_building({x = cand.x, y = cand.y, z = cand.z - 1}) then
            goto continue
        end

        -- never beside work already out: two adjacent tiles dug at the same
        -- moment can drop a floor that neither would alone, and no amount of
        -- per-tile reasoning sees that coming
        local beside_work = false
        for _, d in ipairs(NEIGHBOURS) do
            if phantom[('%d,%d,%d'):format(cand.x + d.x, cand.y + d.y, cand.z)] then
                beside_work = true
                break
            end
        end
        local hyp = {}
        for k in pairs(phantom) do hyp[k] = true end
        hyp[key(cand)] = true
        if beside_work then goto continue end
        local sub, want = active, base_n
        if windowed then
            sub = window_active(active, cand)
            local _, local_base = analyse(sub, phantom)
            if not local_base then goto continue end   -- cannot judge it: leave it held
            want = count(local_base)
        end
        local _, hanging = analyse(sub, hyp)
        if hanging and count(hanging) <= want
                and not strands_work(sub, hyp, group) then
            release_cursor = start + looked
            return cand
        end
        ::continue::
    end
    release_cursor = 0
    return nil
end

-- Jobs that got out while nothing was watching -- created before this was
-- enabled, or while the hook was missing. Same treatment as a fresh one: taken
-- back and written down as a suspended designation, but only while unclaimed,
-- and always through the deferred queue rather than from here.
local function reclaim_stray_jobs()
    local s = get_state()
    each_job(function(job)
        if job.job_type ~= df.job_type.DigChannel then return end
        local pos = {x = job.pos.x, y = job.pos.y, z = job.pos.z}
        local k = key(pos)
        if s.released[k] or s.allowed[k] then return end
        if priority_of(pos) <= EXEMPT_PRIORITY then return end
        if dfhack.job.getWorker(job) then return end
        pending_reclaim[#pending_reclaim + 1] = {id = job.id, pos = pos}
    end)
end

local function apply(found, top)
    local s = get_state()
    s.released = s.released or {}
    s.allowed = s.allowed or {}
    reclaim_stray_jobs()

    local active = {}
    for _, pos in ipairs(found) do
        if pos.z == top and priority_of(pos) > EXEMPT_PRIORITY then
            active[#active + 1] = pos
        end
    end

    -- forget released tiles that are done with
    local out = outstanding(s)

    -- And take back the ones that were let out but can never be worked: no job
    -- came of them and no miner can reach them. Released tiles stay out until
    -- they are dug, so without this the working set silently fills with tiles
    -- nobody can touch and nothing else is ever released.
    do
        local jobs = inflight_channels()
        local group = fort_group()
        for k in pairs(out) do
            if not jobs[k] then
                local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
                local pos = x and {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
                if pos and not workable(pos, group) then
                    out[k] = nil
                    s.released[k] = nil
                end
            end
        end
    end

    -- Restrict everything currently out, from the `out` set rather than from
    -- the designation list: once DF turns a released tile into a job the tile
    -- has no designation any more, so it is not in `found` at all -- which is
    -- exactly the window when a dwarf must not be standing on it.
    for k in pairs(out) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        if x then restrict({x = tonumber(x), y = tonumber(y), z = tonumber(z)}) end
    end
    for k in pairs(s.released) do
        if not out[k] then s.released[k] = nil end
    end

    -- Top the working set up to MAX_CONCURRENT, one pick at a time, each chosen
    -- with the previous picks imagined as already channelled out. Recomputing
    -- between picks is the whole point: it is what stops eight separately
    -- reasonable choices from adding up to a collapse.
    local picks, phantom = {}, {}
    for k in pairs(out) do phantom[k] = true end
    if #active > 0 then
        local group = fort_group()
        while count(phantom) < MAX_CONCURRENT do
            local cand = choose_release(active, phantom, group)
            if not cand then break end
            picks[key(cand)] = true
            phantom[key(cand)] = true
        end
    end

    local held, freed = 0, 0
    for _, pos in ipairs(found) do
        local k = key(pos)
        if priority_of(pos) <= EXEMPT_PRIORITY then
            release(pos); freed = freed + 1
        elseif picks[k] then
            release(pos)
            s.released[k] = true
            freed = freed + 1
        elseif out[k] then
            -- already out from an earlier pass: keep it restricted, since the
            -- restriction has to hold for as long as the tile is a hole waiting
            -- to happen, not just for the pass that let it out
            restrict(pos)
            freed = freed + 1
        else
            hold(pos); held = held + 1
        end
    end

    -- a tile we were holding that is no longer designated must not keep an
    -- entry, or the marker bit is stranded
    for k in pairs(s.marks) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        local pos = x and {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
        if pos and not is_channel(pos) then
            set_marked(pos, false)
            s.marks[k] = nil
        end
    end
    for k in pairs(s.traffic) do
        local x, y, z = k:match('^(-?%d+),(-?%d+),(-?%d+)$')
        local pos = x and {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
        -- dug, or the designation was cancelled: hand the setting back
        if pos and not is_channel(pos) and not (s.released and s.released[k]) then
            unrestrict(pos)
        end
    end

    s.allowed = {}
    for k in pairs(s.released) do s.allowed[k] = true end
    last_pass_blocked = (next(picks) == nil and next(out) == nil) and #active or 0

    -- When nothing could be let out, say WHICH refusal it was. "No safe order"
    -- reads as a fault in the shape you drew, and for a barracks floor sitting on
    -- top of the last 32 tiles of an excavation that is simply wrong: the tool is
    -- refusing to cut the floor out from under somebody's bed, which is a decision
    -- you can act on -- move the furniture, or set those tiles to priority 1.
    last_pass_under_building = 0
    if last_pass_blocked > 0 then
        for _, pos in ipairs(active) do
            if has_building(pos)
                or has_building({x = pos.x, y = pos.y, z = pos.z + 1})
                or has_building({x = pos.x, y = pos.y, z = pos.z - 1}) then
                last_pass_under_building = last_pass_under_building + 1
            end
        end
    end

    save_state()
    return held, freed
end

last_pass = last_pass or {held = 0, freed = 0, channels = 0, top = nil}
last_pass_blocked = last_pass_blocked or 0
last_pass_under_building = last_pass_under_building or 0
reclaimed = reclaimed or 0
reclaim_error = reclaim_error or nil

-- one pump step; returns true when a full pass completed
function pump()
    if not step_scan() then return false end
    local found, top, scan_seen = scan.found, scan.top, scan.seen
    scan = nil
    -- the watch list is exactly the blocks this sweep found work in
    get_state().watch = scan_seen or {}
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
-- taking a job back before anybody works it
-- ---------------------------------------------------------------------------
--
-- Sweeping cannot win on its own. DF issues a job for a fresh designation on
-- its own schedule, and the instant it does the tile's dig field is cleared --
-- so a designation drawn and scheduled between two sweeps is gone before it was
-- ever seen. Measured in a live fort: three channel designations, all three
-- already claimed by miners, none of them ever visible to the scan.
--
-- eventful fires onJobInitiated the moment a job is issued, which is the one
-- point where this can be caught. An unjudged channel job is removed and the
-- tile written back as a SUSPENDED designation -- dig = Channel plus the marker
-- bit -- which is the "planned" state the player sees, and the state this tool
-- can then reason about at leisure.
--
-- Nothing is lost by that: removeJob on its own does destroy the plan (the tile
-- comes back with no designation and no job, measured), which is exactly why
-- the designation is written back in the same breath. The dig priority lives on
-- the block, not the job, so it survives untouched.
--
-- A job that already has a worker is left strictly alone. Mutating a job a
-- dwarf is working is the thing this repo has crashed on, and it is not worth
-- it: that tile is accepted as lost and planned around instead.
-- NEVER from inside the callback. Removing the job there destroys it while
-- DFHack's event manager is still holding it, which is a SIGSEGV inside
-- Core::onUpdate -- confirmed the hard way, with a crash log to match. The hook
-- only writes down an id; the work happens a frame later, from a timeout, at a
-- clean point in the update cycle.
local function reclaim_job(job)
    local s = get_state()
    if not s.enabled then return end
    if job.job_type ~= df.job_type.DigChannel then return end
    local pos = {x = job.pos.x, y = job.pos.y, z = job.pos.z}
    if s.allowed[key(pos)] then return end            -- already judged safe
    if priority_of(pos) <= EXEMPT_PRIORITY then return end
    pending_reclaim[#pending_reclaim + 1] = {id = job.id, pos = pos}
end

function process_reclaims()
    local s = get_state()
    local queue = pending_reclaim
    pending_reclaim = {}
    -- Re-found by walking the list, because df.job.find DOES NOT EXIST: jobs
    -- live in a linked list rather than an indexed vector, so there is no
    -- find() for them. Calling it threw, the pcall around this swallowed the
    -- error, and the whole reclaim path silently did nothing at all -- a fort
    -- ran up 21 dig jobs with not one designation suspended before this showed
    -- up. Never wrap a path like this in pcall without a way to see the throw.
    local by_id = {}
    each_job(function(j) by_id[j.id] = j end)
    for _, item in ipairs(queue) do
        local job = by_id[item.id]
        -- everything is re-checked: a frame has passed, and the job may have
        -- been taken, finished or cancelled in the meantime
        if job and job.job_type == df.job_type.DigChannel
                and not dfhack.job.getWorker(job)
                and not s.allowed[key(item.pos)] then
            if pcall(dfhack.job.removeJob, job) then
                local block, bx, by = tile_parts(item.pos)
                if block then
                    block.designation[bx][by].dig = df.tile_dig_designation.Channel
                    block.occupancy[bx][by].dig_marked = true
                    block.flags.designated = true
                    s.marks[key(item.pos)] = true
                    s.watch[block_key(item.pos)] = true
                    reclaimed = (reclaimed or 0) + 1
                end
            end
        end
    end
    save_state()
end

-- Re-checked every tick, not just on enable.
--
-- The hook is a function value held by the eventful plugin. Reloading this
-- script builds a NEW module environment with a new reclaim_job, while eventful
-- keeps calling the old one -- whose state, config and helpers all belong to a
-- dead copy of the script. Worse, after enough reloads it can end up holding
-- nothing at all. Registering once on enable therefore quietly stops working
-- exactly when the script is being worked on, which is how a fort ended up with
-- 21 dig jobs and not one suspended designation.
local function register_hooks()
    local ok, ev = pcall(require, 'plugins.eventful')
    if not ok then return end
    if ev.onJobInitiated.channel_safely == reclaim_job then return end
    ev.onJobInitiated.channel_safely = reclaim_job
    ev.onUnload.channel_safely = function()
        ev.onJobInitiated.channel_safely = nil
    end
end

local function unregister_hooks()
    local ok, ev = pcall(require, 'plugins.eventful')
    if not ok then return end
    ev.onJobInitiated.channel_safely = nil
    ev.onUnload.channel_safely = nil
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

-- Resolved through reqscript on every tick, deliberately. An overlay widget is
-- an object created when overlays were last rescanned, and its methods keep
-- resolving names in the module environment they were BORN in -- so after this
-- file is edited and copied into place, the command line runs the new code
-- while the widget in the running game quietly keeps running the old. That is
-- invisible from the outside: the tool looks live, reports sensible things when
-- asked, and behaves in the fort like the version you replaced.
function ChannelPump:overlay_onupdate()
    local live = reqscript('fort/channel-safely')
    if live ~= _ENV and live.tick then return live.tick() end
    return tick()
end

function tick()
    if not get_state().enabled then return end
    register_hooks()
    -- The queue is drained HERE rather than from a frame timeout. Frame
    -- timeouts do not fire while the game is paused, so a job taken back while
    -- the player was looking at something sat in the queue indefinitely. This
    -- runs from the overlay pump, which ticks even when paused, and is outside
    -- the event callback either way -- which is the part that matters.
    if #pending_reclaim > 0 then
        local ok, err = pcall(process_reclaims)
        if not ok then
            reclaim_error = tostring(err)      -- shown by `status`
            pending_reclaim = {}
        end
    end
    -- A pass is not free -- it sweeps the map's blocks and then weighs
    -- candidates against a rebuilt grid -- and this ticks on EVERY frame, so it
    -- was doing all of that every frame. `next_pass_at` was declared for this
    -- and never wired up; a big channel designation then held the fort at 8 FPS.
    -- A pass already in progress (scan ~= nil) keeps stepping so it finishes
    -- promptly; only STARTING a new one waits for the interval.
    local now = dfhack.getTickCount()
    if scan or now >= next_pass_at then
        pcall(pump)
        if not scan then next_pass_at = dfhack.getTickCount() + PASS_INTERVAL_MS end
    end
end

OVERLAY_WIDGETS = {pump = ChannelPump}

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED or sc == SC_WORLD_UNLOADED then
        state, scan = nil, nil
    elseif sc == SC_MAP_LOADED then
        state, scan = nil, nil
        if get_state().enabled then register_hooks() end
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
    if reclaim_error then
        print('  LAST RECLAIM FAILED: ' .. reclaim_error)
    end
    if (reclaimed or 0) > 0 then
        print(('  %d job%s taken back and re-planned since load')
            :format(reclaimed, reclaimed == 1 and '' or 's'))
    end
    if (last_pass_blocked or 0) > 0 then
        if last_pass_under_building >= last_pass_blocked then
            print(('  %d designation%s sit directly under or over a building and are '
                .. 'never cut; move it, or set them to priority %d')
                :format(last_pass_blocked, last_pass_blocked == 1 and '' or 's',
                        EXEMPT_PRIORITY))
        elseif unreachable_pass then
            print(('  %d designation%s cannot be reached yet -- no miner can stand at '
                .. 'or beside any of them; they stay planned until something is dug '
                .. 'through to them')
                :format(last_pass_blocked, last_pass_blocked == 1 and '' or 's'))
        else
            print(('  %d designation%s cannot be dug in any order without dropping '
                .. 'unsupported floor; they stay planned')
                :format(last_pass_blocked, last_pass_blocked == 1 and '' or 's'))
        end
    end
    if hanging_cache.skipped then
        print(('  support check SKIPPED: the active level spans more than %d tiles')
            :format(MAX_AREA))
        print('  (top-level staging and the building rules still apply)')
    end
end

-- `fort/channel-safely why <x> <y> <z>` -- the verdict for one tile, with the
-- reason. Written because "it caused a cave-in" is impossible to act on without
-- knowing which test cleared the tile that did it.
function why(x, y, z)
    local pos = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
    if not (pos.x and pos.y and pos.z) then
        qerror('usage: fort/channel-safely why <x> <y> <z>')
    end
    local s = get_state()
    local k = key(pos)
    print(('fort/channel-safely: %d,%d,%d'):format(pos.x, pos.y, pos.z))
    print(('  designated: %s   suspended: %s'):format(
        tostring(is_channel(pos)),
        tostring(select(2, designation_of(pos)) and
                 select(2, designation_of(pos)).dig_marked)))
    print(('  priority %d%s'):format(priority_of(pos),
        priority_of(pos) <= EXEMPT_PRIORITY and '  (never touched)' or ''))
    print(('  ours: %s   released by us: %s'):format(
        tostring(s.marks[k] ~= nil), tostring(s.released and s.released[k] ~= nil)))
    print(('  building on it: %s   above: %s   below: %s'):format(
        tostring(has_building(pos)),
        tostring(has_building({x = pos.x, y = pos.y, z = pos.z + 1})),
        tostring(has_building({x = pos.x, y = pos.y, z = pos.z - 1}))))

    local out = outstanding(s)
    local beside = {}
    for _, d in ipairs(NEIGHBOURS) do
        local nk = ('%d,%d,%d'):format(pos.x + d.x, pos.y + d.y, pos.z)
        if out[nk] then beside[#beside + 1] = nk end
    end
    print(('  beside work already out: %s'):format(
        #beside == 0 and 'no' or table.concat(beside, ' ')))

    -- support: what would digging it leave hanging
    local active = {pos}
    local hyp = {}
    for kk in pairs(out) do hyp[kk] = true end
    hyp[k] = true
    local _, base = analyse({pos}, out)
    local _, after = analyse({pos}, hyp)
    if not after then
        print('  support: area over budget, not checked')
    else
        local nb, na = 0, 0
        for _ in pairs(base or {}) do nb = nb + 1 end
        for _ in pairs(after) do na = na + 1 end
        print(('  support: %d hanging before, %d after -> %s'):format(nb, na,
            na <= nb and 'no new drop' or 'WOULD DROP FLOOR'))
        if na > nb then
            local shown = 0
            for kk in pairs(after) do
                if not (base and base[kk]) and shown < 6 then
                    print('     would hang: ' .. kk)
                    shown = shown + 1
                end
            end
        end
    end
    print(('  reachability: %s'):format(
        strands_work({pos}, hyp, fort_group()) and 'WOULD STRAND WORK' or 'fine'))
end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then
    qerror('fort/channel-safely only works in fortress mode')
end

local arg = ({...})[1]
if arg == 'enable' then
    get_state().enabled = true
    save_state()
    register_hooks()
    run_once()
    print(('fort/channel-safely: enabled -- %d held, %d released')
        :format(last_pass.held, last_pass.freed))
elseif arg == 'disable' then
    get_state().enabled = false
    unregister_hooks()
    local n = release_all()
    print(('fort/channel-safely: disabled -- released %d designation%s')
        :format(n, n == 1 and '' or 's'))
elseif arg == 'why' then
    local a = {...}
    why(a[2], a[3], a[4])
elseif arg == 'once' then
    run_once()
    print(('fort/channel-safely: one pass -- %d channel tiles, %d held, %d released')
        :format(last_pass.channels, last_pass.held, last_pass.freed))
else
    status()
end
