-- Designate graze/scavenge pastures and auto-pasture new tame animals.
--@module = true
--@enable = true
--[[
Pieces that work together so you usually never think about pasturing:

  1. [Graze] / [Scavenge] buttons on the pen zone screen (below "DFHack assign")
     mark this Pen as the pasture for GRAZERS / NON-grazers. A pen can be both.

  2. Auto-designation when you BUILD a pen:
         * no graze set + pen over grass  -> becomes the graze pasture
         * no scavenge set (pen anywhere) -> becomes the scavenge pasture
         * a combined graze+scavenge pen, then a new non-grass pen -> the new pen
           takes over scavenge, leaving the grass pen for grazers only
     Animals already in a pasture are never moved by this.

  3. A background service that pens any unassigned tame fort animal (any age,
     including ones sitting in cages): grazers -> graze pasture, non-grazers ->
     scavenge pasture. Animals you deliberately remove are remembered and not
     re-grabbed. Chained/restrained animals are left alone.

  4. A notify-panel warning when a pasture is overcrowded: more than ~1 animal
     per 4 grass tiles (graze) or per 4 tiles (scavenge).

Usage:
    enable auto-pasture       run the watcher in the background
    disable auto-pasture      stop it
    auto-pasture              one-shot: pen all currently-roaming animals now

The designated zones and the enabled state persist with the fort.
]]

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')
local utils = require('utils')

local GLOBAL_KEY = 'auto-pasture'
local CYCLE_DAYS = 1

-- ---- shared config (persisted with the fort) ------------------------------
-- state = { enabled, graze_id, scavenge_id }; `known` = unit ids we've already
-- handled this session (so a manually-unpastured animal isn't re-grabbed).
state = state or nil
known = known or nil
known_pens = known_pens or nil   -- pen ids we've already seen (for new-pen detection)
pens_seeded = pens_seeded or false
pen_cache = pen_cache or nil      -- pen id -> {grass=, tiles=}; refreshed each cycle

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

-- ---- pen geometry: grass (grazeable) + total tiles, cached per pen ---------

local GRASS_MATS = {
    [df.tiletype_material.GRASS_LIGHT] = true,
    [df.tiletype_material.GRASS_DARK]  = true,
    [df.tiletype_material.GRASS_DRY]   = true,
    [df.tiletype_material.GRASS_DEAD]  = true,
}

-- {grass = grazeable tiles, tiles = total tiles}; computed once, cached until the
-- next cycle clears pen_cache (grass cover shifts slowly, so this is plenty fresh)
local function pen_metrics(zone)
    if not pen_cache then pen_cache = {} end
    local m = pen_cache[zone.id]
    if not m then
        local g, t = 0, 0
        for x = zone.x1, zone.x2 do
            for y = zone.y1, zone.y2 do
                if dfhack.buildings.containsTile(zone, x, y) then
                    t = t + 1
                    local tt = dfhack.maps.getTileType(x, y, zone.z)
                    if tt and GRASS_MATS[df.tiletype.attrs[tt].material] then g = g + 1 end
                end
            end
        end
        m = {grass = g, tiles = t}
        pen_cache[zone.id] = m
    end
    return m
end

-- does this pen sit on grass (i.e. grazers can feed there)?
local function pen_has_grass(zone)
    return pen_metrics(zone).grass > 0
end

-- ---- assignment -----------------------------------------------------------

local function get_ref(unit, t)
    return dfhack.units.getGeneralRef(unit, t)
end

-- a live, tame, fort-owned animal we're willing to pasture (any age).
-- isFortControlled is the tameness gate: caged *wild* captives (arena beasts)
-- read false here, while caged tame livestock/pets read true.
local function is_pasturable_animal(unit)
    return dfhack.units.isFortControlled(unit)
        and dfhack.units.isAlive(unit)
        and dfhack.units.isAnimal(unit)
        and not dfhack.units.isMerchant(unit)
end

-- already assigned to a pasture/pit civzone?
local function is_pastured(unit)
    return get_ref(unit, df.general_ref_type.BUILDING_CIVZONE_ASSIGNED) ~= nil
end

-- on a chain/restraint -- deliberately placed, so leave it alone
local function is_chained(unit)
    return get_ref(unit, df.general_ref_type.BUILDING_CHAIN) ~= nil
end

-- the built Cage building holding this cage item, if any
local function get_built_cage(item_cage)
    if not item_cage then return nil end
    local ref = dfhack.items.getGeneralRef(item_cage, df.general_ref_type.BUILDING_HOLDER)
    local b = ref and df.building.find(ref.building_id)
    if b and b:getType() == df.building_type.Cage then return b end
    return nil
end

-- release a caged unit from its built cage so it can be hauled to the pasture.
-- (The contained-in-item ref is cleared by the game when it is actually let out;
-- a loose/stockpiled cage has no building assignment to clear.)
local function detach_from_cage(unit)
    local cage_ref = get_ref(unit, df.general_ref_type.CONTAINED_IN_ITEM)
    if not cage_ref then return end
    local built = get_built_cage(df.item.find(cage_ref.item_id))
    if not built then return end
    for i = #built.assigned_units - 1, 0, -1 do
        if built.assigned_units[i] == unit.id then built.assigned_units:erase(i) end
    end
end

-- mirrors plugins.zone attach_to_zone, plus cage release for caged animals
local function assign_to_zone(unit, zone)
    detach_from_cage(unit)   -- no-op unless the unit is caged
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
        if is_pastured(unit) then
            -- already in a pasture: remember it so a later manual removal sticks
            known[unit.id] = true
            goto continue
        end
        if is_chained(unit) then goto continue end  -- restrained on purpose
        if known[unit.id] then goto continue end    -- deliberately left roaming
        -- candidates include caged tame animals; assign_to_zone frees them
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
    pen_cache = {}        -- recompute pen grass/size this cycle
    scan_new_pens()       -- auto-designate any newly-built pens (global, defined below)
    local n = do_assign()
    if n > 0 then
        print(('auto-pasture: penned %d new animal%s'):format(n, n == 1 and '' or 's'))
    end
end

-- Daily cycle driven off a per-frame heartbeat gated on the game calendar, NOT
-- repeat-util: on this build repeat-util's tick/day timeouts count rendered
-- frames (many calendar ticks each) and fire only every ~3 game-days. A 'frames'
-- timeout fires every frame, so a calendar-delta check gives an accurate daily run.
local DAY_TICKS = 1200 * CYCLE_DAYS
local last_run = nil
local hb_gen = 0   -- generation guard so only the newest heartbeat loop survives

local function start()
    enabled = true
    last_run = nil
    hb_gen = hb_gen + 1
    local my_gen = hb_gen
    local function heartbeat()
        if not enabled or my_gen ~= hb_gen then return end
        local now = df.global.cur_year * 403200 + df.global.cur_year_tick
        if not last_run or now - last_run >= DAY_TICKS then
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

-- ---- auto-designation of newly-built pens ---------------------------------

-- Apply the designation rules to a freshly-built pen P, so you usually never
-- have to pick graze/scavenge by hand:
--   * no graze set and P is over grass   -> P becomes the graze pasture
--   * no scavenge set (P anywhere)        -> P becomes the scavenge pasture
--   * one pen is both graze+scavenge and  -> P takes over scavenge, leaving the
--     P is on non-grass                      grass pen for grazers only
-- When a role is (re)assigned, the matching unassigned animals are penned;
-- animals already in a pasture are never moved.
function auto_designate(pen)
    load_state()
    if not valid_pasture(state.graze_id) then state.graze_id = -1 end
    if not valid_pasture(state.scavenge_id) then state.scavenge_id = -1 end
    local over_grass = pen_has_grass(pen)
    local changed = false
    if state.graze_id < 0 and over_grass then
        state.graze_id = pen.id
        changed = true
    end
    if state.scavenge_id < 0 then
        state.scavenge_id = pen.id
        changed = true
    elseif state.scavenge_id == state.graze_id and not over_grass then
        state.scavenge_id = pen.id   -- split scavenge onto the new non-grass pen
        changed = true
    end
    if changed then
        if not enabled then start() end
        state.enabled = true
        save_state()
        do_assign()
    end
    return changed
end

-- Detect newly-built pens and auto-designate them. The first pass after a
-- load/enable just records the pens that already exist (so they aren't grabbed
-- retroactively); only pens built afterward are auto-designated.
function scan_new_pens()
    if not known_pens then known_pens = {} end
    local seeding = not pens_seeded
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_civzonest:is_instance(b) and b.type == df.civzone_type.Pen
            and not known_pens[b.id]
        then
            known_pens[b.id] = true
            if not seeding then auto_designate(b) end
        end
    end
    pens_seeded = true
end

-- ---- overcrowding notification --------------------------------------------

-- a designated pasture is overcrowded past ~1 animal per 4 grass tiles (graze)
-- or per 4 tiles (scavenge)
local function pasture_overcrowd_msg()
    if not dfhack.world.isFortressMode() then return end
    load_state()
    local warns = {}
    local graze = valid_pasture(state.graze_id)
    if graze then
        local cap = math.floor(pen_metrics(graze).grass / 4)
        local n = #graze.assigned_units
        if n > cap then warns[#warns + 1] = ('graze %d/%d'):format(n, cap) end
    end
    local scav = valid_pasture(state.scavenge_id)
    if scav and state.scavenge_id ~= state.graze_id then
        local cap = math.floor(pen_metrics(scav).tiles / 4)
        local n = #scav.assigned_units
        if n > cap then warns[#warns + 1] = ('scavenge %d/%d'):format(n, cap) end
    end
    if #warns == 0 then return end
    return {{text = 'Pasture overcrowded (' .. table.concat(warns, ', ') .. ')',
             pen = COLOR_LIGHTRED}}
end

local function register_notification()
    local ok, n = pcall(reqscript, 'internal/notify/notifications')
    if not ok or not n then return end
    local NAME = 'pasture_overcrowd'
    local entry = n.NOTIFICATIONS_BY_NAME[NAME]
    if not entry then
        entry = {name = NAME, version = 1, default = true}
        table.insert(n.NOTIFICATIONS_BY_IDX, entry)
        n.NOTIFICATIONS_BY_NAME[NAME] = entry
    end
    entry.desc = 'Warns when a designated graze/scavenge pasture is overcrowded.'
    entry.dwarf_fn = pasture_overcrowd_msg
    if n.config and n.config.data and not n.config.data[NAME] then
        n.config.data[NAME] = {enabled = true, version = 1}
    end
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
        state, known, known_pens, pens_seeded, pen_cache = nil, nil, nil, false, nil
        load_state()
        if dfhack.world.isFortressMode() then
            scan_new_pens()          -- seed existing pens (no retroactive designation)
            register_notification()  -- overcrowding warning
            if state.enabled then start() end
        end
    elseif sc == SC_MAP_UNLOADED then
        stop()
        state, known, known_pens, pens_seeded, pen_cache = nil, nil, nil, false, nil
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

-- auto-designate a newly-built pen the moment it's viewed (snappier than waiting
-- for the daily cycle); guarded by known_pens so each pen is handled once
function AutoPastureOverlay:render(dc)
    local pen = cur_pen()
    if pen and pens_seeded and known_pens and not known_pens[pen.id] then
        known_pens[pen.id] = true
        auto_designate(pen)
    end
    AutoPastureOverlay.super.render(self, dc)
end

OVERLAY_WIDGETS = {pasture = AutoPastureOverlay}

-- exported so it can be driven via reqscript (the `enable` command goes through
-- run_script, which on this build can serve a stale cached copy)
function set_enabled(on)
    load_state()
    if on then
        scan_new_pens()          -- seed existing pens (no retroactive designation)
        register_notification()
        start()
    else
        stop()
    end
    state.enabled = enabled
    save_state()
    return enabled
end

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
    register_notification()
    print('auto-pasture: ' .. (enabled and 'enabled (background)' or 'disabled'))
else
    -- one-shot
    if not dfhack.world.isFortressMode() then
        qerror('auto-pasture only works in fortress mode')
    end
    load_state()
    local graze = valid_pasture(state.graze_id)
    local scavenge = valid_pasture(state.scavenge_id)
    register_notification()
    if not graze and not scavenge then
        print('auto-pasture: no graze/scavenge pasture designated yet.')
        print('  Make a pasture (it auto-designates), or use the [Graze]/[Scavenge] buttons.')
    else
        local n = do_assign()
        print(('auto-pasture: penned %d roaming animal%s'):format(n, n == 1 and '' or 's'))
        if graze then print('  grazers   -> #' .. state.graze_id) end
        if scavenge then print('  non-grazers -> #' .. state.scavenge_id) end
    end
end
