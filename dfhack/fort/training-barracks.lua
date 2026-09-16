-- Designate one barracks zone as "basic training": every squad with no barracks of its own trains there.
--@module = true
--@enable = true
--[[
A [Basic training] toggle on the Barracks zone screen (like auto-pasture's
[Graze]/[Scavenge] buttons on the pen screen) marks THIS barracks as the fort's
basic-training barracks:

  * every fort squad WITHOUT A TRAINING GROUND OF ITS OWN -- current AND created
    later -- is assigned to TRAIN there (the same thing as ticking "train" for
    that squad in the zone's squad list);
  * a squad that already trains at another barracks is passed over, since that
    squad has been placed deliberately and a second training room would only
    split its drill; only the "train" use counts, so a squad that merely sleeps
    or keeps its gear elsewhere is still a basic-training squad;
  * a background service keeps new squads covered;
  * nothing is ever designated automatically -- the button is the only way a
    barracks gets this role. Toggling it off stops future assignment but leaves
    the existing squad assignments alone (manage those in the zone UI).

Only the "train" use is touched: sleep / individual equipment / squad equipment
flags, and any other barracks the squads use, are left exactly as they are.

Usage:
    enable training-barracks     run the watcher in the background
    disable training-barracks    stop it
    training-barracks            one-shot: assign the squads with no training
                                 ground of their own now

The designated zone and the enabled state persist with the fort.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local GLOBAL_KEY = 'training-barracks'
local CYCLE_TICKS = 300   -- re-scan for new squads ~4x a game day

-- ---- shared config (persisted with the fort) ------------------------------
state = state or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY,
            {enabled = false, barracks_id = -1})
    end
    return state
end

local function save_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

-- a Barracks civzone, or nil
local function valid_barracks(id)
    if not id or id < 0 then return nil end
    local b = df.building.find(id)
    if b and df.building_civzonest:is_instance(b) and b.type == df.civzone_type.Barracks then
        return b
    end
    return nil
end

-- ---- assignment -----------------------------------------------------------

-- assign one squad to train at the zone. Mirrors what the zone UI's squad list
-- writes: an entry on BOTH sides -- squad.rooms (squad_barracks_infost) and
-- zone.squad_room_info (building_squad_infost) -- with mode.train set. Existing
-- entries just get train switched on; other mode flags are never touched.
-- Returns true if anything changed.
local function assign_squad(squad, zone)
    local changed = false

    local room
    for _, r in ipairs(squad.rooms) do
        if r.building_id == zone.id then room = r; break end
    end
    if not room then
        squad.rooms:insert('#', {new = df.squad_barracks_infost, building_id = zone.id})
        room = squad.rooms[#squad.rooms - 1]
        changed = true
    end
    if not room.mode.train then room.mode.train = true; changed = true end

    local info
    for _, e in ipairs(zone.squad_room_info) do
        if e.squad_id == squad.id then info = e; break end
    end
    if not info then
        zone.squad_room_info:insert('#', {new = df.building_squad_infost, squad_id = squad.id})
        info = zone.squad_room_info[#zone.squad_room_info - 1]
        changed = true
    end
    if not info.mode.train then info.mode.train = true; changed = true end

    return changed
end

-- Take the basic-training assignment back off a squad. Only the `train` flag is cleared,
-- on both sides, and the entries themselves stay: an entry with every mode flag off is what
-- the zone UI leaves behind when you untick a squad by hand, and erasing it would mean
-- resizing two vectors the zone screen may be holding pointers into. Sleep and equipment
-- uses of this same barracks survive untouched.
local function retract_squad(squad, zone)
    local changed = false
    for _, r in ipairs(squad.rooms) do
        if r.building_id == zone.id and r.mode.train then r.mode.train = false; changed = true end
    end
    for _, e in ipairs(zone.squad_room_info) do
        if e.squad_id == squad.id and e.mode.train then e.mode.train = false; changed = true end
    end
    return changed
end

-- A squad that already trains somewhere else is left alone. "Basic training" is for the
-- squads nobody has given a barracks of their own: a squad with its own training ground has
-- been placed deliberately, and adding a second training room to it splits its drill between
-- two rooms rather than reinforcing either. Only the `train` use counts -- a squad that
-- merely SLEEPS or keeps its gear in another barracks still has no training ground, so it is
-- still a basic-training squad. A squad that picks up its own barracks later is RELEASED
-- from this one on the next pass -- otherwise the assignment this tool made outlives the
-- reason for it, and unticking it in the zone UI is undone by the next cycle.
local function trains_elsewhere(squad, zone)
    for _, r in ipairs(squad.rooms) do
        if r.building_id ~= zone.id and r.mode.train then return true end
    end
    return false
end

-- assign every fort squad without a training ground of its own to the designated barracks,
-- and release the ones that have since found one. Returns the number assigned and the
-- number released.
local function do_assign()
    load_state()
    local zone = valid_barracks(state.barracks_id)
    if not zone then
        -- forget a zone that no longer exists
        if state.barracks_id >= 0 then state.barracks_id = -1; save_state() end
        return 0, 0
    end
    local n, released = 0, 0
    for _, squad in ipairs(df.global.world.squads.all) do
        if squad.entity_id == df.global.plotinfo.group_id then
            if trains_elsewhere(squad, zone) then
                if retract_squad(squad, zone) then released = released + 1 end
            elseif assign_squad(squad, zone) then
                n = n + 1
            end
        end
    end
    return n, released
end

-- ---- enable / background service ------------------------------------------

enabled = enabled or false

function isEnabled()
    return enabled
end

local function do_cycle()
    if not dfhack.world.isFortressMode() then return end
    local n, released = do_assign()
    if n > 0 then
        print(('training-barracks: assigned %d squad%s to basic training')
            :format(n, n == 1 and '' or 's'))
    end
    if released > 0 then
        print(('training-barracks: released %d squad%s -- training at their own barracks now')
            :format(released, released == 1 and '' or 's'))
    end
end

-- per-frame heartbeat gated on the game calendar (same rationale as
-- auto-pasture: repeat-util day timeouts are frame-counted on this build)
local last_run = nil
local hb_gen = 0

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= CYCLE_TICKS then
            last_run = now
            do_cycle()
        end
        dfhack.timeout(1, 'frames', heartbeat)
    end
    heartbeat()
end

local function stop()
    enabled = false
    hb_gen = hb_gen + 1
end

-- set/clear the designated barracks; auto-start the service on set
local function set_barracks(zone_id)
    load_state()
    if state.barracks_id == zone_id then
        state.barracks_id = -1             -- toggle off: stop assigning new squads
    else
        state.barracks_id = zone_id
        if not enabled then start() end
        state.enabled = true
        do_assign()
    end
    save_state()
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        load_state()
        if dfhack.world.isFortressMode() and state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state = nil
    end
end

-- ---- overlay --------------------------------------------------------------

local function cur_barracks()
    local civzone = df.global.game.main_interface.civzone
    local bld = civzone and civzone.cur_bld
    if bld and bld.type == df.civzone_type.Barracks then return bld end
    return nil
end

local function is_designated()
    local zone = cur_barracks()
    if not zone then return false end
    load_state()
    return state.barracks_id == zone.id
end

TrainingBarracksOverlay = defclass(TrainingBarracksOverlay, overlay.OverlayWidget)
TrainingBarracksOverlay.ATTRS{
    desc = 'Adds a basic-training toggle to the barracks zone screen.',
    default_pos = {x = 7, y = 14},
    default_enabled = true,
    viewscreens = 'dwarfmode/Zone/Some/Barracks',
    frame = {w = 16, h = 1},
    version = 1,
}

function TrainingBarracksOverlay:init()
    self:addviews{
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 16},    -- '[Basic training]'
            label = '[Basic training]',
            text_pen = function() return is_designated() and COLOR_GREEN or COLOR_WHITE end,
            on_activate = function()
                local zone = cur_barracks()
                if zone then set_barracks(zone.id) end
            end,
        },
    }
end

OVERLAY_WIDGETS = {barracks = TrainingBarracksOverlay}

-- exported so it can be driven via reqscript (the `enable` command goes through
-- run_script, which on this build can serve a stale cached copy)
function set_enabled(on)
    load_state()
    if on then start() else stop() end
    state.enabled = enabled
    save_state()
    return enabled
end

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then
        qerror('training-barracks can only be enabled in fortress mode')
    end
    load_state()
    if dfhack_flags.enable_state then start() else stop() end
    state.enabled = enabled
    save_state()
    print('training-barracks: ' .. (enabled and 'enabled (background)' or 'disabled'))
else
    -- one-shot
    if not dfhack.world.isFortressMode() then
        qerror('training-barracks only works in fortress mode')
    end
    load_state()
    if not valid_barracks(state.barracks_id) then
        print('training-barracks: no basic-training barracks designated yet.')
        print('  Open a Barracks zone and click [Basic training].')
    else
        local n, released = do_assign()
        print(('training-barracks: assigned %d squad%s to train at zone #%d')
            :format(n, n == 1 and '' or 's', state.barracks_id))
        if released > 0 then
            print(('  released %d squad%s -- they train at a barracks of their own')
                :format(released, released == 1 and '' or 's'))
        end
    end
end
