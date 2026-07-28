-- Seed the self-expanding "inside+" burrow on the first tile a miner digs out.
--@module = true
--@enable = true
--[[
inside-burrow
=============
Watches for the FIRST tile a miner digs out and, if the fort has no burrows yet,
creates a single-tile burrow named `inside+` there. Because the name ends in `+`,
DFHack's `burrow` plugin then auto-expands it: every wall dug out along the edge
of the burrow gets absorbed, so the burrow grows to cover your whole dug-out fort
with no further babysitting.

Meant to be armed right at embark (before anything is mined) -- see
magnus-scripts. It is a one-time seeder: once it creates the burrow (or once any
burrow already exists), it stands down and disables itself.

    enable inside-burrow     arm the watcher (persists with the fort)
    disable inside-burrow    disarm
    inside-burrow            toggle
    inside-burrow status     report whether it is armed / already seeded

Notes:
  * "if no burrow exists" -- if the fort already has ANY burrow when armed (or one
    appears before the first dig), it assumes you have things handled and does
    nothing.
  * ANY dig-out seeds it -- the very first tile a miner opens up, interior or not.
  * Seeding turns on `enable burrow` so the `+` auto-expansion is actually live.
]]

local utils = require('utils')

local GLOBAL_KEY = 'inside-burrow'
local BURROW_NAME = 'inside+'

local burrows = df.global.plotinfo.burrows

-- dig jobs that turn a wall into a passable tile (the ones that "open up" the
-- fort). Channeling/fortification/smoothing are intentionally excluded.
local DIG_JOBS = {}
for _, n in ipairs({'Dig', 'CarveUpwardStaircase', 'CarveDownwardStaircase',
                    'CarveUpDownStaircase', 'CarveRamp'}) do
    local jt = df.job_type[n]
    if jt then DIG_JOBS[jt] = true end
end

-- ---------------------------------------------------------------------------
-- burrow helpers
-- ---------------------------------------------------------------------------

local function any_burrow_exists()
    return #burrows.list > 0
end

-- mirrors quickfort's create_burrow: a fresh burrow with a random symbol/colour
local function create_burrow(name)
    local b = df.burrow:new()
    b.id = burrows.next_id
    burrows.next_id = burrows.next_id + 1
    b.name = name
    b.symbol_index = math.random(0, 22)
    b.texture_r = math.random(0, 255)
    b.texture_g = math.random(0, 255)
    b.texture_b = math.random(0, 255)
    b.texture_br = 255 - b.texture_r
    b.texture_bg = 255 - b.texture_g
    b.texture_bb = 255 - b.texture_b
    burrows.list:insert('#', b)
    return b
end

-- ---------------------------------------------------------------------------
-- tile helpers
-- ---------------------------------------------------------------------------

local function tile_shape(pos)
    local tt = dfhack.maps.getTileType(pos)
    if not tt then return nil end
    return df.tiletype.attrs[tt].shape
end

local function is_wall(pos)
    return tile_shape(pos) == df.tiletype_shape.WALL
end

-- a wall we were watching that is now dug out (anything passable, inside or not)
local function is_mined(pos)
    local shape = tile_shape(pos)
    return shape ~= nil and shape ~= df.tiletype_shape.WALL
        and shape ~= df.tiletype_shape.NONE
end

-- ---------------------------------------------------------------------------
-- watcher (per-frame heartbeat, matching this pack's house style)
-- ---------------------------------------------------------------------------

enabled = enabled or false
generation = generation or 0
seeded = seeded or false

function isEnabled()
    return enabled
end

-- walls we've seen a miner take a dig job on, keyed by position
local watched = {}

local function poskey(p) return ('%d,%d,%d'):format(p.x, p.y, p.z) end

local function persist()
    pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, {enabled = enabled})
end

local function stop()
    enabled = false
    generation = generation + 1   -- invalidate any running heartbeat
    watched = {}
end

local function seed(pos)
    local b = create_burrow(BURROW_NAME)
    dfhack.burrows.setAssignedTile(b, pos, true)
    -- make the `+` auto-expansion live so the burrow grows as digging continues
    pcall(dfhack.run_command, 'enable', 'burrow')
    seeded = true
    stop()
    persist()
    print(('inside-burrow: created burrow "%s" on first mined tile (%d, %d, %d); '
        .. 'it will auto-expand as you dig.'):format(BURROW_NAME, pos.x, pos.y, pos.z))
end

local function tick(gen)
    if not enabled or gen ~= generation then return end
    if dfhack.world.isFortressMode() then
        if any_burrow_exists() then
            -- a burrow exists (player made one, or some appeared): stand down quietly
            stop()
            persist()
            return
        end
        -- 1) remember any new wall a miner has a dig job on
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if DIG_JOBS[job.job_type] then
                local p = job.pos
                if p and is_wall(p) then
                    watched[poskey(p)] = copyall(p)
                end
            end
        end
        -- 2) has any watched wall been dug out?
        for _, p in pairs(watched) do
            if is_mined(p) then
                seed(p)
                return
            end
        end
    end
    dfhack.timeout(1, 'frames', function() tick(gen) end)
end

local function start()
    if enabled then return end
    enabled = true
    seeded = false
    generation = generation + 1
    watched = {}
    tick(generation)
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        if dfhack.world.isFortressMode()
            and dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false}).enabled
        then
            start()
        end
    elseif sc == SC_MAP_UNLOADED then
        stop()
    end
end

-- exported so it can be driven via reqscript if needed
function set_enabled(on)
    if on then start() else stop() end
    persist()
    return enabled
end

-- ---------------------------------------------------------------------------
-- command-line entry
-- ---------------------------------------------------------------------------

if dfhack_flags.module then
    return
end

if not dfhack.world.isFortressMode() then
    qerror('inside-burrow only works in fortress mode')
end

local cmd = ({...})[1]

if cmd == 'status' then
    local existing = any_burrow_exists()
    print(('inside-burrow: %s'):format(
        enabled and 'ARMED -- waiting for the first dig-out'
        or (existing and 'idle (a burrow already exists)'
            or 'idle (not armed)')))
    return
end

-- figure out whether this invocation wants us armed or disarmed
local want_on
if dfhack_flags and dfhack_flags.enable ~= nil then
    want_on = dfhack_flags.enable_state
else
    want_on = not enabled   -- bare invocation toggles
end

if not want_on then
    stop()
    persist()
    print('inside-burrow: disarmed.')
    return
end

-- arming only makes sense when there's nothing to seed onto yet
if any_burrow_exists() then
    stop()
    persist()
    print('inside-burrow: a burrow already exists; nothing to do.')
    return
end

start()
persist()
print('inside-burrow: armed -- will create "' .. BURROW_NAME
    .. '" on the first tile a miner digs.')
