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
tile are untouched. A tile a running `fort/quickfort` job is about to cover with a zone of its own
-- a tomb room planned by `fort/builder-burrow`, say -- is left to it: a 1x1 zone dropped on the
coffin first would win the race and make DF refuse the room's zone as an overlap.

It also cleans up after itself: zones it placed (tracked per fort; a pre-existing 1x1 zone found
sitting on matching furniture is adopted into tracking) are REMOVED again when their coffin /
nest box goes away -- deconstructed, or a planned one canceled -- but only while the zone is
still 1x1. A zone you've grown beyond 1x1 is considered yours and is left alone (and untracked).
Zones it didn't create are never removed.

    enable auto-tomb     start watching (persists with the fort)
    disable auto-tomb    stop
    auto-tomb            one pass right now: add missing zones, retire stale ones, report

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

-- the civzone of `ztype` already on the tile, or nil
local function get_zone(pos, ztype)
    local zones = dfhack.buildings.findCivzonesAt(pos)
    if zones then
        for _, z in ipairs(zones) do
            if z.type == ztype then return z end
        end
    end
    return nil
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

-- ---- the scan (needs the state above for zone tracking) ----------------------

-- A running fort/quickfort job (fort/builder-burrow's tomb rooms, say) may be about to put
-- a room-sized zone over this tile. Its coffin can be built before the rest of the room has
-- finished being smoothed, so dropping a 1x1 zone on it the moment it appears would win the
-- race and leave the room without the zone its blueprint asked for -- DF refuses a zone that
-- overlaps one that already exists. Leave those tiles to it. quickfort not being loaded (or
-- being mid-reload) is not an error here: with no answer we just carry on as before.
-- resolved once per scan: reqscript re-checks the file on every call, and a scan asks
-- about every coffin and nest box in the fort
local function quickfort_module()
    local ok, qf = pcall(reqscript, 'fort/quickfort')
    if ok and qf and qf.pending_zone_at then return qf end
end

local function claimed_by_quickfort(qf, pos)
    if not qf then return false end
    local ok, claimed = pcall(qf.pending_zone_at, pos)
    return ok and claimed or false
end

-- One pass over the fort's buildings: drop the matching zone on every coffin / nest box that
-- lacks one, track the zones we place, and retire tracked zones whose furniture is gone.
-- Returns (zones added, zones removed).
local function scan()
    load_state()
    state.zones = state.zones or {}     -- ids of zones we created/adopted (string keys for JSON)
    local made, removed, changed = 0, 0, false
    local qf = quickfort_module()
    for _, b in ipairs(df.global.world.buildings.all) do
        local ztype = AUTO_ZONE[b:getType()]
        if ztype then
            local pos = {x = b.centerx, y = b.centery, z = b.z}
            local z = get_zone(pos, ztype)
            if not z and not claimed_by_quickfort(qf, pos) then
                z = make_zone(pos, ztype)
                if z then made = made + 1 end
            end
            -- track what we just placed -- and adopt a pre-existing 1x1 zone -- so it can be
            -- retired later if its furniture goes away
            if z and z.x1 == z.x2 and z.y1 == z.y2 and not state.zones[tostring(z.id)] then
                state.zones[tostring(z.id)] = true
                changed = true
            end
        end
    end
    -- retire: a tracked zone that is STILL 1x1 but whose coffin / nest box is gone
    -- (deconstructed, or a planned one canceled). A zone the player grew beyond 1x1 is
    -- theirs now: left in place and dropped from tracking. (Clearing keys during pairs()
    -- is legal in Lua; we never add keys in this loop.)
    for id_str in pairs(state.zones) do
        local z = df.building.find(tonumber(id_str))
        local keep = false
        if z and z:getType() == df.building_type.Civzone and z.x1 == z.x2 and z.y1 == z.y2 then
            local furn = dfhack.buildings.findAtTile(xyz2pos(z.x1, z.y1, z.z))
            if furn and AUTO_ZONE[furn:getType()] == z.type then
                keep = true
            else
                dfhack.buildings.deconstruct(z)   -- abstract building: removed instantly
                removed = removed + 1
            end
        end
        if not keep then
            state.zones[id_str] = nil
            changed = true
        end
    end
    if changed then save_state() end
    return made, removed
end

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
local made, removed = scan()
print(('auto-tomb: placed %d new zone%s on coffins / nest boxes missing one, removed %d stale zone%s.')
    :format(made, made == 1 and '' or 's', removed, removed == 1 and '' or 's'))
