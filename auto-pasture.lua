-- Designate graze/scavenge pastures and auto-pasture new tame animals.
--@module = true
--@enable = true
--[[
Two pieces that work together:

  1. An overlay on the pen/pasture zone screen (below DFHack's "DFHack assign"
     button) with two toggles:
         Graze pasture     -- mark this Pen as the pasture for GRAZERS
         Scavenge pasture  -- mark this Pen as the pasture for NON-grazers
     A zone can be both (e.g. one pen for everything). Setting a pasture turns
     the background service on automatically.

  2. A background service that watches for *new* tame fort animals (born, bought,
     tamed) that aren't assigned to any pasture yet and pens them:
         grazers   -> the graze pasture
         non-grazers -> the scavenge pasture
     Animals you deliberately remove from a pasture are remembered and are NOT
     re-grabbed -- only genuinely new ones get assigned. Babies are left with
     their mothers and only get penned once they grow up (a nursing baby can't
     be hauled to a pasture and grazes nothing anyway).

Usage:
    enable auto-pasture       run the watcher in the background
    disable auto-pasture      stop it
    auto-pasture              one-shot: pen all currently-roaming animals now

The designated zones and the enabled state persist with the fort. Pick the
zones with the overlay buttons; the service does the rest.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local repeatUtil = require('repeat-util')
local utils = require('utils')

local GLOBAL_KEY = 'auto-pasture'
local CYCLE_DAYS = 1

-- ---- shared config (persisted with the fort) ------------------------------
-- state = { enabled, graze_id, scavenge_id }; `known` = unit ids we've already
-- handled this session (so a manually-unpastured animal isn't re-grabbed).
state = state or nil
known = known or nil

local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY,
            {enabled = false, graze_id = -1, scavenge_id = -1})
    end
    if not known then known = {} end
    return state
end

local function save_state()
    dfhack.persistent.saveSiteData(GLOBAL_KEY, state)
end

-- a built, complete Pen civzone, or nil
local function valid_pasture(id)
    if not id or id < 0 then return nil end
    local b = df.building.find(id)
    if b and df.building_civzonest:is_instance(b) and b.type == df.civzone_type.Pen then
        return b
    end
    return nil
end

-- ---- assignment -----------------------------------------------------------

local function get_ref(unit, t)
    return dfhack.units.getGeneralRef(unit, t)
end

-- a live, fort-owned animal we're willing to pasture. Babies are skipped: a
-- nursing baby is carried by its mother and can't be hauled to a pasture on its
-- own (assigning one only spawns pen jobs that cancel), and it grazes nothing
-- while nursing. We don't mark skipped babies as "known", so once a baby grows
-- into a child/adult a later scan pens it like any other new animal.
local function is_pasturable_animal(unit)
    return dfhack.units.isFortControlled(unit)
        and dfhack.units.isAlive(unit)
        and dfhack.units.isAnimal(unit)
        and not dfhack.units.isMerchant(unit)
        and not dfhack.units.isBaby(unit)
end

local function is_unpastured(unit)
    return not get_ref(unit, df.general_ref_type.BUILDING_CIVZONE_ASSIGNED)
        and not get_ref(unit, df.general_ref_type.CONTAINED_IN_ITEM)
        and not get_ref(unit, df.general_ref_type.BUILDING_CHAIN)
end

-- mirrors plugins.zone attach_to_zone (caller guarantees `unit` is unpastured)
local function assign_to_zone(unit, zone)
    local ref = df.new(df.general_ref_building_civzone_assignedst)
    ref.building_id = zone.id
    unit.general_refs:insert('#', ref)
    utils.insert_sorted(zone.assigned_units, unit.id)
end

-- pen every new roaming animal; returns count assigned
local function do_assign()
    load_state()
    local graze = valid_pasture(state.graze_id)
    local scavenge = valid_pasture(state.scavenge_id)
    -- forget zones that no longer exist
    local dirty = false
    if not graze and state.graze_id >= 0 then state.graze_id = -1; dirty = true end
    if not scavenge and state.scavenge_id >= 0 then state.scavenge_id = -1; dirty = true end
    if dirty then save_state() end
    if not graze and not scavenge then return 0 end

    local assigned = 0
    for _, unit in ipairs(df.global.world.units.active) do
        if not is_pasturable_animal(unit) then goto continue end
        if not is_unpastured(unit) then
            -- already placed: remember it so a later manual removal sticks
            known[unit.id] = true
            goto continue
        end
        if known[unit.id] then goto continue end   -- deliberately left roaming
        local zone = dfhack.units.isGrazer(unit) and graze or scavenge
        if zone then
            assign_to_zone(unit, zone)
            known[unit.id] = true
            assigned = assigned + 1
        end
        ::continue::
    end
    return assigned
end

-- ---- enable / background service ------------------------------------------

enabled = enabled or false

function isEnabled()
    return enabled
end

local function do_cycle()
    if not dfhack.world.isFortressMode() then return end
    local n = do_assign()
    if n > 0 then
        print(('auto-pasture: penned %d new animal%s'):format(n, n == 1 and '' or 's'))
    end
end

local function start()
    enabled = true
    repeatUtil.scheduleEvery(GLOBAL_KEY, CYCLE_DAYS, 'days', do_cycle)
    do_cycle()   -- act immediately
end

local function stop()
    enabled = false
    repeatUtil.cancel(GLOBAL_KEY)
end

-- set/clear one of the designated zones; auto-start the service on first set
local function set_zone(which, zone_id)
    load_state()
    local key = which == 'graze' and 'graze_id' or 'scavenge_id'
    if state[key] == zone_id then
        state[key] = -1                    -- toggle off
    else
        state[key] = zone_id
    end
    if (state.graze_id >= 0 or state.scavenge_id >= 0) and not enabled then
        start()
        state.enabled = true
    end
    save_state()
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state, known = nil, nil
        load_state()
        if dfhack.world.isFortressMode() and state.enabled then start() end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, known = nil, nil
    end
end

-- ---- overlay --------------------------------------------------------------

local function cur_pen()
    local civzone = df.global.game.main_interface.civzone
    local bld = civzone and civzone.cur_bld
    if bld and bld.type == df.civzone_type.Pen then return bld end
    return nil
end

-- is the current pen designated as the graze / scavenge pasture?
local function is_designated(which)
    local pen = cur_pen()
    if not pen then return false end
    load_state()
    return state[which == 'graze' and 'graze_id' or 'scavenge_id'] == pen.id
end

-- toggle the current pen as the graze / scavenge pasture
local function toggle(which)
    local pen = cur_pen()
    if pen then set_zone(which, pen.id) end
end

AutoPastureOverlay = defclass(AutoPastureOverlay, overlay.OverlayWidget)
AutoPastureOverlay.ATTRS{
    desc = 'Adds graze/scavenge pasture buttons to the pen assignment screen.',
    -- row 14: directly below zone.pasturepond's "DFHack assign" (its frame is
    -- y=13, h=4, with assign at the top row and autobutcher at the bottom row)
    default_pos = {x = 7, y = 14},
    default_enabled = true,
    viewscreens = 'dwarfmode/Zone/Some/Pen',
    frame = {w = 18, h = 1},
    version = 3,
}

function AutoPastureOverlay:init()
    -- two separate clickable buttons (Label dispatches mouse clicks per widget,
    -- not per token); text_pen is a function so each turns green while this pen
    -- is its designated zone and white otherwise
    self:addviews{
        -- explicit widths so each button's frame is exactly its text: otherwise a
        -- frame with no width fills the overlay and overlaps its neighbour, so
        -- hovering/clicking one would light up (or toggle) both
        widgets.HotkeyLabel{
            frame = {t = 0, l = 0, w = 7},     -- '[Graze]'
            label = '[Graze]',
            text_pen = function() return is_designated('graze') and COLOR_GREEN or COLOR_WHITE end,
            on_activate = function() toggle('graze') end,
        },
        widgets.HotkeyLabel{
            frame = {t = 0, l = 8, w = 10},    -- '[Scavenge]'
            label = '[Scavenge]',
            text_pen = function() return is_designated('scavenge') and COLOR_GREEN or COLOR_WHITE end,
            on_activate = function() toggle('scavenge') end,
        },
    }
end

OVERLAY_WIDGETS = {pasture = AutoPastureOverlay}

if dfhack_flags.module then
    return
end

if dfhack_flags and dfhack_flags.enable ~= nil then
    if not dfhack.world.isFortressMode() then
        qerror('auto-pasture can only be enabled in fortress mode')
    end
    load_state()
    if dfhack_flags.enable_state then start() else stop() end
    state.enabled = enabled
    save_state()
    print('auto-pasture: ' .. (enabled and 'enabled (background)' or 'disabled'))
else
    -- one-shot
    if not dfhack.world.isFortressMode() then
        qerror('auto-pasture only works in fortress mode')
    end
    load_state()
    local graze = valid_pasture(state.graze_id)
    local scavenge = valid_pasture(state.scavenge_id)
    if not graze and not scavenge then
        print('auto-pasture: no graze/scavenge pasture designated yet.')
        print('  Open a pen zone and use the overlay toggles to pick one.')
    else
        local n = do_assign()
        print(('auto-pasture: penned %d roaming animal%s'):format(n, n == 1 and '' or 's'))
        if graze then print('  grazers   -> #' .. state.graze_id) end
        if scavenge then print('  non-grazers -> #' .. state.scavenge_id) end
    end
end
