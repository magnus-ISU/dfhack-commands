-- Build a temporary stair shaft up to a planned construction nothing can reach, then take it
-- down again, top to bottom, once the construction is up.
--@module = true
--@enable = true
--[[
auto-scaffold

A wall planned two levels up in open air never gets built: no dwarf can stand next to it, so
the job sits suspended forever. This tool builds the scaffold for you. For every planned
construction that no citizen can reach, it looks straight DOWN each of the four orthogonally
adjacent tiles: a column of open air ending on a floor your dwarves can walk to is a place a
stair shaft can go. It picks the shaft that serves the most unreachable constructions at once
(the tile between two wall segments serves both), plans the stairs bottom-up -- an up stair on
the floor, up/down stairs through the air, a down stair at the top, each one planned only once
the one below it is built, so nothing is ever queued that cannot be reached -- and unsuspends
the construction's job once the top is in place. Materials are `buildingplan`'s: the stairs
are planned with its stored up/down/up-down stair filters, so they are built from whatever
placing a stair by hand would build them from.

Once every construction the shaft was built for is finished (or cancelled), the shaft comes
down again: a Remove Construction designation on the top stair, and on each one below it only
after the one above is gone, so a dwarf always has the stair beneath to stand on. The block
from each stair drops down the shaft and is hauled away like any other.

What it will NOT do: bridge more than 10 levels of open air; start a shaft on a tile that is
not natural floor (a constructed floor's own record would be lost when the stair is removed);
scaffold a construction that has been unreachable for less than two scans (about a day), so
one that is merely waiting for a tunnel you are digging is left alone. A shaft the player
cancels (removes a planned stair from) is taken back down and forgotten.

    enable fort/auto-scaffold     watch the fort and scaffold as needed (persists with the fort)
    disable fort/auto-scaffold    stop watching (shafts already up still finish and come down)
    fort/auto-scaffold            one pass right now, no waiting period
    fort/auto-scaffold status     what is being built, held or removed
    fort/auto-scaffold teardown   take every shaft down now, whatever its constructions are doing
    fort/auto-scaffold forget     drop all records (the stairs stay; remove them yourself)
]]

local buildingplan = require('plugins.buildingplan')
local utils = require('utils')

local GLOBAL_KEY = 'auto-scaffold'
-- The state machine runs on FRAMES so a cancelled stair is noticed while paused, the way
-- fort/dig-replace-walls reconciles its plans; the scan for new unreachable constructions is
-- gated on GAME ticks so a paused fort neither scans nor counts toward the waiting period.
local CYCLE_FRAMES = 50
local SCAN_TICKS = 600
local SCAN_HITS = 2          -- consecutive unreachable scans before a shaft is planned
local MAX_SHAFT = 10         -- levels of open air we are willing to bridge

local CT = df.construction_type
local BT = df.building_type
local DV = df.tile_dig_designation
local BASIC = df.tiletype_shape_basic
local ORTHO = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- ---- persisted state ---------------------------------------------------------
--
-- One record per shaft: {x, y, z0 (floor), z1 (top, the construction's level), walls = {ids},
-- stage = 'build' | 'hold' | 'remove', level = the z the stage is currently working on}.

-- NOT `state or nil`: the persisted records are the truth, and a reload must re-read them --
-- a stale in-memory copy from before the reload would be saved back over whatever changed
state = nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false, shafts = {}})
        state.shafts = state.shafts or {}
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
function isEnabled() return load_state().enabled end

-- ---- tiles -------------------------------------------------------------------

local function pos(x, y, z) return xyz2pos(x, y, z) end

local function shape_at(x, y, z)
    local tt = dfhack.maps.getTileType(x, y, z)
    if not tt then return nil end
    return df.tiletype.attrs[tt].shape
end
local function basic_at(x, y, z)
    local s = shape_at(x, y, z)
    return s and df.tiletype_shape.attrs[s].basic_shape
end
local function hidden_at(x, y, z)
    local f = dfhack.maps.getTileFlags(pos(x, y, z))
    return not f or f.hidden
end
local function is_stair(x, y, z)
    local b = basic_at(x, y, z)
    return b == BASIC.Stair
end
-- A designation written into the tile is not enough on its own: DF only looks for new dig
-- jobs in blocks whose `designated` flag is up (quickfort and fort/channel-safely raise it
-- for the same reason). Without it the stair sits marked, drawn, and never worked -- which
-- is exactly how 43 shafts sat with 4 jobs between them.
local function set_dig(x, y, z, val)
    local blk = dfhack.maps.getTileBlock(x, y, z)
    if not blk then return end
    blk.designation[x % 16][y % 16].dig = val
    if val ~= DV.No then blk.flags.designated = true end
end
local function get_dig(x, y, z)
    local blk = dfhack.maps.getTileBlock(x, y, z)
    return blk and blk.designation[x % 16][y % 16].dig or DV.No
end

-- ---- who can walk where ------------------------------------------------------
--
-- "Reachable" means a working citizen can walk to it. Walkable-group ids are volatile (they
-- are renumbered as the map changes), so the set is rebuilt for every pass and never stored.
local function citizen_groups()
    local set, n = {}, 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
        if not dfhack.units.isBaby(u) and not dfhack.units.isChild(u) then
            local g = dfhack.maps.getWalkableGroup(u.pos)
            if g > 0 then set[g] = true; n = n + 1 end
        end
    end
    return set, n
end

local function walkable_by(groups, x, y, z)
    local g = dfhack.maps.getWalkableGroup(pos(x, y, z))
    return g > 0 and groups[g] or false
end

-- A construction is buildable from any of the eight tiles around it (or the tile itself) --
-- and a stair is also built from the walkable stair directly below or above it, which is how
-- every shaft of ours goes up: without that clause the scanner sees its own half-built shaft
-- as one more unreachable construction and scaffolds the scaffold.
local function reachable(groups, x, y, z)
    for dx = -1, 1 do for dy = -1, 1 do
        if walkable_by(groups, x + dx, y + dy, z) then return true end
    end end
    if is_stair(x, y, z - 1) and walkable_by(groups, x, y, z - 1) then return true end
    if is_stair(x, y, z + 1) and walkable_by(groups, x, y, z + 1) then return true end
    return false
end

-- ---- finding a shaft ---------------------------------------------------------
--
-- Straight down from the neighbouring tile: every tile must be revealed open air with nothing
-- planned on it, and the column must end (within MAX_SHAFT levels) on a natural floor tile a
-- citizen can walk to. Returns {x, y, z0, z1} or nil.
local function shaft_down(groups, sx, sy, z)
    local zz = z
    while z - zz <= MAX_SHAFT do
        if hidden_at(sx, sy, zz) then return nil end
        if zz < z and walkable_by(groups, sx, sy, zz) then
            if basic_at(sx, sy, zz) ~= BASIC.Floor then return nil end
            if dfhack.buildings.findAtTile(pos(sx, sy, zz)) then return nil end
            if dfhack.constructions.findAtTile(pos(sx, sy, zz)) then return nil end
            if get_dig(sx, sy, zz) ~= DV.No then return nil end
            return {x = sx, y = sy, z0 = zz, z1 = z}
        end
        if basic_at(sx, sy, zz) ~= BASIC.Open then return nil end
        if dfhack.buildings.findAtTile(pos(sx, sy, zz)) then return nil end
        zz = zz - 1
    end
    return nil
end

local function contains(t, v)
    for _, x in ipairs(t) do if x == v then return true end end
    return false
end

local function shaft_key(s) return ('%d,%d,%d,%d'):format(s.x, s.y, s.z0, s.z1) end

local function adjacent8(s, b)
    return b.z == s.z1 and math.abs(b.centerx - s.x) <= 1 and math.abs(b.centery - s.y) <= 1
end

-- ---- planning a stair --------------------------------------------------------

local function stair_subtype(rec, z)
    if z == rec.z0 then return CT.UpStair end
    if z == rec.z1 then return CT.DownStair end
    return CT.UpDownStair
end

-- plan one stair with buildingplan's OWN stored filter for that stair type, the same way
-- fort/dig-replace-walls hands off a wall: constructBuilding + addPlannedBuilding is exactly
-- what buildingplan's placement overlay does
local function plan_stair(x, y, z, subtype)
    local filters = dfhack.buildings.getFiltersByType({}, BT.Construction, subtype, -1)
    local bld, err = dfhack.buildings.constructBuilding{
        pos = pos(x, y, z), type = BT.Construction, subtype = subtype, filters = filters,
    }
    if not bld then return nil, 'constructBuilding failed: ' .. tostring(err) end
    local ok, res = pcall(buildingplan.addPlannedBuilding, bld)
    if ok and res ~= false then pcall(buildingplan.scheduleCycle) end
    return bld
end

local function unsuspend(id)
    local b = df.building.find(id)
    if not b then return end
    for _, j in ipairs(b.jobs) do
        if j.job_type == df.job_type.ConstructBuilding then j.flags.suspend = false end
    end
end

-- every RemoveConstruction job posted, as a position-key set: DF clears the designation the
-- moment it posts the job, so the job is the only record the tile is still queued
local function removal_jobs()
    local set = {}
    for _, j in utils.listpairs(df.global.world.jobs.list) do
        if j.job_type == df.job_type.RemoveConstruction then
            set[('%d,%d,%d'):format(j.pos.x, j.pos.y, j.pos.z)] = true
        end
    end
    return set
end

-- ---- is the shaft holding something up? ----------------------------------------
--
-- A wall built from the top stair, over open air, with gaps to its neighbours, is supported
-- by exactly one thing: that stair. Pull the stair and the wall drops -- and a batch of them
-- dropping at once sent DF's collapse check into a loop that never ended (the fort had to be
-- killed). So a shaft whose top stair is the ONLY support of a construction beside it is kept
-- and said so in `status`; it comes down when the player gives the wall something else to
-- stand on. Support here is DF's: any non-air tile in the eight around it or directly below.
local function supported_without(x, y, z, sx, sy)
    if basic_at(x, y, z - 1) ~= BASIC.Open and basic_at(x, y, z - 1) ~= nil then return true end
    for dx = -1, 1 do for dy = -1, 1 do
        local nx, ny = x + dx, y + dy
        if (dx ~= 0 or dy ~= 0) and not (nx == sx and ny == sy) then
            local b = basic_at(nx, ny, z)
            if b ~= nil and b ~= BASIC.Open then return true end
        end
    end end
    return false
end

-- a finished construction next to the shaft's top that nothing but the top stair holds up
local function sole_support_of(rec)
    for dx = -1, 1 do for dy = -1, 1 do
        if dx ~= 0 or dy ~= 0 then
            local x, y = rec.x + dx, rec.y + dy
            if dfhack.constructions.findAtTile(pos(x, y, rec.z1))
                    and not supported_without(x, y, rec.z1, rec.x, rec.y) then
                return x, y
            end
        end
    end end
    return nil
end

-- the RemoveConstruction job posted on this tile, if any
local function removal_job_at(x, y, z)
    for _, j in utils.listpairs(df.global.world.jobs.list) do
        if j.job_type == df.job_type.RemoveConstruction
                and j.pos.x == x and j.pos.y == y and j.pos.z == z then return j end
    end
end

-- ---- the state machine -------------------------------------------------------

local function begin_removal(rec, from_z)
    rec.stage, rec.level = 'remove', from_z
end

-- returns true when the record is finished with and should be dropped
local function step(rec, jobs)
    local x, y = rec.x, rec.y
    if rec.stage == 'build' then
        local z = rec.level
        if is_stair(x, y, z) and dfhack.constructions.findAtTile(pos(x, y, z)) then
            if z >= rec.z1 then
                for _, id in ipairs(rec.walls) do unsuspend(id) end
                rec.stage = 'hold'
            else
                rec.level = z + 1
                local _, err = plan_stair(x, y, rec.level, stair_subtype(rec, rec.level))
                if err then dfhack.printerr(('auto-scaffold (%d,%d,%d): %s'):format(x, y, rec.level, err)) end
            end
        elseif dfhack.buildings.findAtTile(pos(x, y, z)) then
            return false                                   -- still planned; wait
        else
            -- the planned stair is gone and nothing was built: the player cancelled it
            if z <= rec.z0 then return true end
            begin_removal(rec, z - 1)
        end
    elseif rec.stage == 'hold' then
        for _, id in ipairs(rec.walls) do
            if df.building.find(id) then return false end   -- still a planned building
        end
        local hx, hy = sole_support_of(rec)
        if hx then rec.holding = ('%d,%d'):format(hx, hy) return false end
        rec.holding = nil
        begin_removal(rec, rec.z1)
    elseif rec.stage == 'remove' then
        local z = rec.level
        -- the top stair is still up and something beside it has nothing else: take the
        -- removal back (the designation, and the job while no dwarf holds it) and hold
        if z == rec.z1 and is_stair(x, y, z) then
            local hx, hy = sole_support_of(rec)
            if hx then
                set_dig(x, y, z, DV.No)
                local j = removal_job_at(x, y, z)
                if j and not dfhack.job.getWorker(j) then pcall(dfhack.job.removeJob, j) end
                rec.stage, rec.holding = 'hold', ('%d,%d'):format(hx, hy)
                return false
            end
        end
        while z >= rec.z0 and not is_stair(x, y, z) do
            -- a stair of ours still only PLANNED here is cancelled, never left behind -- but
            -- never out from under a dwarf who has already taken the job (freeing a job DF
            -- is still pointing at is a crash this fort has seen). Suspend it instead, as the
            -- UI would: the worker drops it on their own, and the next cycle cancels it.
            local b = dfhack.buildings.findAtTile(pos(x, y, z))
            if b and df.building_constructionst:is_instance(b) then
                if #b.jobs > 0 and dfhack.job.getWorker(b.jobs[0]) then
                    b.jobs[0].flags.suspend = true
                    rec.level = z
                    return false
                end
                pcall(dfhack.buildings.deconstruct, b)
            end
            z = z - 1
        end
        if z < rec.z0 then return true end
        rec.level = z
        if get_dig(x, y, z) == DV.No and not jobs[('%d,%d,%d'):format(x, y, z)] then
            set_dig(x, y, z, DV.Default)
        end
    end
    return false
end

-- ---- finding work ------------------------------------------------------------

seen = {}   -- construction id -> consecutive unreachable scans (memory only)

-- every planned construction no citizen can reach, plus the walkable-group set used
local function unreachable_constructions()
    local groups, n = citizen_groups()
    if n == 0 then return {}, groups end
    local ours = {}   -- our own shaft tiles: never candidates, whatever the walk groups say
    for _, rec in ipairs(load_state().shafts) do
        for z = rec.z0, rec.z1 do ours[('%d,%d,%d'):format(rec.x, rec.y, z)] = true end
    end
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_constructionst:is_instance(b) and #b.jobs > 0
                and b.jobs[0].job_type == df.job_type.ConstructBuilding
                and not ours[('%d,%d,%d'):format(b.centerx, b.centery, b.z)]
                and not reachable(groups, b.centerx, b.centery, b.z) then
            out[#out + 1] = b
        end
    end
    return out, groups
end

-- Plan shafts for the unreachable constructions that have waited long enough (`hits`
-- consecutive scans; 1 for a one-off pass). Returns shafts planned, constructions served.
function scan(hits)
    local st = load_state()
    local cands, groups = unreachable_constructions()
    local due, now = {}, {}
    for _, b in ipairs(cands) do
        now[b.id] = (seen[b.id] or 0) + 1
        if now[b.id] >= hits then due[#due + 1] = b end
    end
    seen = now
    -- a construction next to a shaft already going up needs nothing more
    local served = {}
    for _, rec in ipairs(st.shafts) do
        if rec.stage ~= 'remove' then
            for _, b in ipairs(due) do
                if adjacent8(rec, b) then
                    served[b.id] = true
                    if not contains(rec.walls, b.id) then rec.walls[#rec.walls + 1] = b.id end
                end
            end
        end
    end
    -- candidate shafts, keyed, with the constructions each would serve
    local shafts = {}
    for _, b in ipairs(due) do
        if not served[b.id] then
            for _, d in ipairs(ORTHO) do
                local s = shaft_down(groups, b.centerx + d[1], b.centery + d[2], b.z)
                if s then
                    local k = shaft_key(s)
                    shafts[k] = shafts[k] or s
                end
            end
        end
    end
    -- greedy: the shaft serving the most still-unserved constructions goes first
    local planned, covered = 0, 0
    while true do
        local best, best_walls = nil, {}
        for _, s in pairs(shafts) do
            local walls = {}
            for _, b in ipairs(due) do
                if not served[b.id] and adjacent8(s, b) then walls[#walls + 1] = b.id end
            end
            if #walls > #best_walls then best, best_walls = s, walls end
        end
        if not best then break end
        shafts[shaft_key(best)] = nil
        local rec = {x = best.x, y = best.y, z0 = best.z0, z1 = best.z1,
                     walls = best_walls, stage = 'build', level = best.z0}
        local bld, err = plan_stair(rec.x, rec.y, rec.z0, stair_subtype(rec, rec.z0))
        if bld then
            st.shafts[#st.shafts + 1] = rec
            planned, covered = planned + 1, covered + #best_walls
            for _, id in ipairs(best_walls) do served[id] = true end
        else
            dfhack.printerr(('auto-scaffold (%d,%d,%d): %s'):format(rec.x, rec.y, rec.z0, err))
        end
    end
    if planned > 0 then save_state() end
    return planned, covered, #due
end

-- one reconciliation pass over the shaft records
function cycle()
    local st = load_state()
    if #st.shafts == 0 then return end
    local jobs = removal_jobs()
    local keep, changed = {}, false
    for _, rec in ipairs(st.shafts) do
        local before = rec.stage .. rec.level
        local done = step(rec, jobs)
        if done then changed = true else keep[#keep + 1] = rec end
        if rec.stage .. rec.level ~= before then changed = true end
    end
    if changed then st.shafts = keep; save_state() end
end

function teardown()
    local st = load_state()
    local n = 0
    for _, rec in ipairs(st.shafts) do
        if rec.stage ~= 'remove' then
            -- cancel whatever stair is still only planned; the built ones come down in order
            local b = dfhack.buildings.findAtTile(pos(rec.x, rec.y, rec.level))
            if b and rec.stage == 'build' and not dfhack.job.getWorker(b.jobs[0]) then
                pcall(dfhack.buildings.deconstruct, b)
            end
            begin_removal(rec, rec.stage == 'build' and rec.level or rec.z1)
            n = n + 1
        end
    end
    save_state()
    return n
end

function status()
    local st = load_state()
    print(('auto-scaffold: %s, %d shaft%s'):format(st.enabled and 'ENABLED' or 'disabled',
        #st.shafts, #st.shafts == 1 and '' or 's'))
    for _, rec in ipairs(st.shafts) do
        local what = ({build = 'building stair at z%d', hold = 'holding for %d construction(s)',
                       remove = 'removing stair at z%d'})[rec.stage]
        local arg = rec.stage == 'hold' and #rec.walls or rec.level
        if rec.holding then what = 'KEPT: sole support of the wall at (' .. rec.holding .. ')' end
        print(('  (%d,%d) z%d..z%d: %s'):format(rec.x, rec.y, rec.z0, rec.z1, what:format(arg)))
    end
end

-- ---- heartbeat (survives reloads via dfhack.internal) -----------------------
local function hb_gen(set)
    if set ~= nil then dfhack.internal.auto_scaffold_hb_gen = set end
    return dfhack.internal.auto_scaffold_hb_gen or 0
end
local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local last_scan = -SCAN_TICKS
    local function hb()
        if my ~= hb_gen() or not dfhack.isMapLoaded() then return end
        cycle()
        local fc = df.global.world.frame_counter or 0
        if isEnabled() and fc - last_scan >= SCAN_TICKS then
            last_scan = fc
            local planned, covered = scan(SCAN_HITS)
            if planned > 0 then
                print(('auto-scaffold: planned %d shaft%s for %d unreachable construction%s.')
                    :format(planned, planned == 1 and '' or 's', covered, covered == 1 and '' or 's'))
            end
        end
        dfhack.timeout(CYCLE_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

-- the heartbeat runs whenever there are shafts to see through, enabled or not: disabling only
-- stops NEW shafts being planned, it never leaves stairs standing
local function ensure_heartbeat()
    if dfhack.isMapLoaded() and (isEnabled() or #load_state().shafts > 0) then start_heartbeat() end
end

local function set_enabled(v)
    load_state()
    state.enabled = v
    save_state()
    seen = {}
    stop_heartbeat()
    ensure_heartbeat()
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, seen = nil, {}
        if dfhack.world.isFortressMode() then ensure_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state, seen = nil, {}
    end
end

-- a reload does not re-emit SC_MAP_LOADED for a map that is already open
if dfhack.isMapLoaded() and dfhack.world.isFortressMode() then stop_heartbeat(); ensure_heartbeat() end

-- ---- entry point -------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then qerror('auto-scaffold only works in fortress mode') end

if dfhack_flags and dfhack_flags.enable ~= nil then
    set_enabled(dfhack_flags.enable_state)
    print('auto-scaffold: ' .. (isEnabled() and 'ENABLED (watching for unreachable constructions)' or 'disabled'))
    return
end

local cmd = ({...})[1]
if not cmd then
    local planned, covered, due = scan(1)
    ensure_heartbeat()
    print(('auto-scaffold: %d unreachable construction%s; planned %d shaft%s serving %d.')
        :format(due, due == 1 and '' or 's', planned, planned == 1 and '' or 's', covered))
    if due > covered then
        print(('  %d could not be scaffolded: no open-air column beside them ends on natural floor within %d levels.')
            :format(due - covered, MAX_SHAFT))
    end
elseif cmd == 'status' then
    status()
elseif cmd == 'teardown' then
    print(('auto-scaffold: taking down %d shaft(s).'):format(teardown()))
    ensure_heartbeat()
elseif cmd == 'forget' then
    load_state().shafts = {}
    save_state()
    stop_heartbeat(); ensure_heartbeat()
    print('auto-scaffold: forgot every shaft.')
else
    qerror('unknown auto-scaffold command: ' .. tostring(cmd))
end
