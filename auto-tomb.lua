-- Auto-place a 1x1 Tomb zone over every coffin, so each becomes an assignable tomb.
--@module = true
--@enable = true
--[[
auto-tomb

Watches your fort and drops a 1x1 Tomb activity zone onto any coffin (built or just placed)
that doesn't already sit under one. A coffin inside a Tomb zone becomes an assignable tomb
-- so every coffin you place is immediately ready to assign to a dwarf, with no manual
zone-painting. Coffins that already have a tomb zone are left alone (idempotent), and other
zones on the tile are untouched.

    enable auto-tomb     start watching (persists with the fort)
    disable auto-tomb    stop
    auto-tomb            place tombs on any coffins missing one right now, and report

Add `enable auto-tomb` to magnus-scripts / dfhack.init to run it every session.
]]

local GLOBAL_KEY = 'auto-tomb'
local SCAN_FRAMES = 10   -- re-check this often (responsive, but coffins aren't placed every tick)

-- ---- the work ---------------------------------------------------------------

-- is the tile already under a Tomb zone?
local function has_tomb(pos)
    local zones = dfhack.buildings.findCivzonesAt(pos)
    if zones then
        for _, z in ipairs(zones) do
            if z.type == df.civzone_type.Tomb then return true end
        end
    end
    return false
end

-- create a 1x1 Tomb zone at pos (a civzone needs an extents bitmap; ours is one tile = 1)
local function make_tomb(pos)
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', 1))
    extents[0] = 1
    local bld = dfhack.buildings.constructBuilding{
        type = df.building_type.Civzone, subtype = df.civzone_type.Tomb, abstract = true,
        pos = pos, width = 1, height = 1,
        fields = {assigned_unit_id = -1,
                  room = {x = pos.x, y = pos.y, width = 1, height = 1, extents = extents}},
    }
    -- a Tomb zone is only a real, assignable tomb when its `whole` flag is set (it applies
    -- to the whole zone, i.e. the coffin in it). Without this the zone is non-functional.
    if bld then bld.zone_settings.tomb.flags.whole = 1 end
    return bld
end

-- place a tomb on every coffin that lacks one; returns how many were added
local function scan()
    local made = 0
    for _, b in ipairs(df.global.world.buildings.all) do
        if b:getType() == df.building_type.Coffin then
            local pos = {x = b.centerx, y = b.centery, z = b.z}
            if not has_tomb(pos) and make_tomb(pos) then made = made + 1 end
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
    local function hb()
        if not isEnabled() or my ~= hb_gen() then return end
        scan()
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
    print('auto-tomb: ' .. (isEnabled() and 'ENABLED (watching coffins)' or 'disabled'))
    return
end

if not dfhack.world.isFortressMode() then qerror('auto-tomb only works in fortress mode') end
local n = scan()
print(('auto-tomb: placed %d new tomb zone%s on coffins missing one.'):format(n, n == 1 and '' or 's'))
