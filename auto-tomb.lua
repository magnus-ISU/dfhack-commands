-- Auto-place a 1x1 zone over furniture that needs one: a Tomb zone on every coffin, and a
-- Pen/Pasture zone on every nest box.
--@module = true
--@enable = true
--[[
auto-tomb

Watches your fort and drops a 1x1 activity zone onto furniture that needs one, so it becomes
immediately assignable with no manual zone-painting:
  * a coffin (built or just placed) that isn't already under a Tomb zone -> a 1x1 Tomb zone,
    so it's ready to assign to a dwarf;
  * a nest box that isn't already under a Pen/Pasture zone -> a 1x1 Pen zone, so you can pasture
    a female egg-layer onto it to lay.
Furniture that already has the matching zone is left alone (idempotent), and other zones on the
tile are untouched.

    enable auto-tomb     start watching (persists with the fort)
    disable auto-tomb    stop
    auto-tomb            zone any coffins / nest boxes missing one right now, and report

Add `enable auto-tomb` to magnus-scripts / dfhack.init to run it every session.
]]

local GLOBAL_KEY = 'auto-tomb'
local SCAN_FRAMES = 10       -- heartbeat cadence: an O(1) building-count check, so it's cheap
local BACKSTOP_FRAMES = 500  -- also do a full walk this often (in GAME frames -> never while
                             -- paused) to cover the rare cases a bare count check can miss

-- ---- the work ---------------------------------------------------------------

-- furniture building type -> the 1x1 civzone subtype to drop on it
local AUTO_ZONE = {
    [df.building_type.Coffin]  = df.civzone_type.Tomb,
    [df.building_type.NestBox] = df.civzone_type.Pen,   -- Pen == Pen/Pasture
}

-- is the tile already under a civzone of `ztype`?
local function has_zone(pos, ztype)
    local zones = dfhack.buildings.findCivzonesAt(pos)
    if zones then
        for _, z in ipairs(zones) do
            if z.type == ztype then return true end
        end
    end
    return false
end

-- create a 1x1 civzone of `subtype` at pos (a civzone needs an extents bitmap; ours is one tile)
local function make_zone(pos, subtype)
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', 1))
    extents[0] = 1
    local bld = dfhack.buildings.constructBuilding{
        type = df.building_type.Civzone, subtype = subtype, abstract = true,
        pos = pos, width = 1, height = 1,
        fields = {assigned_unit_id = -1,
                  room = {x = pos.x, y = pos.y, width = 1, height = 1, extents = extents}},
    }
    if bld then
        -- a civzone must be ACTIVE to actually function; constructBuilding leaves it off, so
        -- without this the zone exists but can't be assigned/used (looks "broken").
        bld.spec_sub_flag.active = true
        -- match how the game/quickfort make a tomb: keep pets from being buried in it.
        if subtype == df.civzone_type.Tomb then bld.zone_settings.tomb.flags.no_pets = true end
    end
    return bld
end

-- drop the matching zone on every coffin / nest box that lacks one; returns how many were added
local function scan()
    local made = 0
    for _, b in ipairs(df.global.world.buildings.all) do
        local ztype = AUTO_ZONE[b:getType()]
        if ztype then
            local pos = {x = b.centerx, y = b.centery, z = b.z}
            if not has_zone(pos, ztype) and make_zone(pos, ztype) then made = made + 1 end
        end
    end
    return made
end

-- ---- enable state (persisted per fort) --------------------------------------

state = state or nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.enabled == nil then state.enabled = false end
    end
    return state
end
local function save_state() dfhack.persistent.saveSiteData(GLOBAL_KEY, state) end
function isEnabled() return load_state().enabled end

-- ---- heartbeat (every SCAN_FRAMES; survives reloads via dfhack.internal) -----
local function hb_gen(set)
    if set ~= nil then dfhack.internal.auto_tomb_hb_gen = set end
    return dfhack.internal.auto_tomb_hb_gen or 0
end
local function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local last_count, last_full = -1, -1
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        local n = #df.global.world.buildings.all
        local fc = df.global.world.frame_counter or 0
        -- A coffin / nest box can only appear as a NEW building, so the common "nothing changed"
        -- tick is just an O(1) length compare and skips. Walk the list only when the building set
        -- changed (something added/removed -- catches placements even while paused), or when the
        -- periodic backstop is due. The backstop is measured in GAME frames, which don't advance
        -- while paused, so a paused fort does no full walks. Placing a zone adds a civzone
        -- building, so re-read the count afterward to settle instead of rescanning next tick.
        if n ~= last_count or (fc - last_full) >= BACKSTOP_FRAMES then
            scan()
            last_count = #df.global.world.buildings.all
            last_full = fc
        end
        dfhack.timeout(SCAN_FRAMES, 'frames', hb)
    end
    hb()
end
local function stop_heartbeat() hb_gen(hb_gen() + 1) end

local function set_enabled(v)
    load_state()
    state.enabled = v
    save_state()
    if v then start_heartbeat(); scan() else stop_heartbeat() end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- entry point ------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then qerror('auto-tomb only works in fortress mode') end
    set_enabled(dfhack_flags.enable_state)
    print('auto-tomb: ' .. (isEnabled() and 'ENABLED (watching coffins + nest boxes)' or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then qerror('auto-tomb only works in fortress mode') end
local n = scan()
print(('auto-tomb: placed %d new zone%s on coffins / nest boxes missing one.'):format(n, n == 1 and '' or 's'))
