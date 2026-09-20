-- DFHack's autofarm in lua, with the one thing it lacks: plots it is told to leave alone.
--@module = true
--@enable = true
--[[
fort/autofarm

A port of DFHack's `autofarm` plugin -- the same crop assignment, the same thresholds, the
same hourly cycle -- with an exclusion list. The plugin manages EVERY farm plot in the fort
and has no way to say "not this one", so a plot set aside for a crop you actually want (a
dye crop, sun berries for the wine) is rewritten within the day. Here a plot with autofarm
turned off is simply not a plot autofarm knows about: it is never counted, never assigned,
never touched, and what you set on it stays.

An **[autofarm]** button on the farm plot sheet says whether this plot is managed -- green
if it is -- and toggles it (Ctrl-A does too).

WHAT IT DOES, once an hour of game time (every 53 ticks, as the plugin): counts the seeds
you have, works out which of those plants can be planted now and still be harvested within
a season it grows in; counts the plants and plant growths in stock per crop; and for every
crop below its threshold, spreads the managed plots of each biome as evenly as possible over
the crops that biome can grow, changing as few plots as it can. A biome with nothing below
threshold, or no seeds, is left fallow. Only the CURRENT season's crop is set, as the
plugin does. Above-ground plots take the biome of their region, underground plots count as
SUBTERRANEAN_WATER. A plot still under construction is ignored.

RUN THIS OR THE PLUGIN, NOT BOTH: two managers assigning the same plots would overwrite
each other every hour. Enabling this disables the plugin (`disable autofarm`), and the
plugin's thresholds are not readable from lua, so set yours again here if you had any.

    enable fort/autofarm                   manage the farms (persists with the fort)
    disable fort/autofarm                  stop
    fort/autofarm [status]                 what is enabled, the counts, the thresholds,
                                           and the plots turned off
    fort/autofarm runonce                  one cycle now, whether enabled or not
    fort/autofarm default <n>              default threshold (50 to start with)
    fort/autofarm threshold <n> <id...>    thresholds for named plants (`getplants -f`)
    fort/autofarm off                      turn autofarm off for the plot whose sheet is open
    fort/autofarm on                       hand it back
    fort/autofarm on all                   hand every plot back
]]

local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')
local repeatutil = require('repeat-util')

local GLOBAL_KEY = 'fort/autofarm'
local CYCLE_TICKS = 53                   -- one hour-ish, as the plugin
local DEFAULT_THRESHOLD = 50

-- ---- state --------------------------------------------------------------
--
-- {enabled, default = <n>, thresholds = {[plant id string] = n}, off = {<building id>...}}.
-- Thresholds are keyed by the plant's raw id ("MUSHROOM_HELMET_PLUMP"), as the plugin
-- stores them, so a save survives a raw reorder. `off` is a list: the store is JSON and an
-- integer key would come back a string.

state = state or nil
state_site = state_site or nil
enabled = enabled or false
last_counts = last_counts or {}          -- plant index -> stock, from the last cycle

local function fresh_state()
    return {enabled = false, default = DEFAULT_THRESHOLD, thresholds = {}, off = {}}
end

local function load_state()
    local site = dfhack.isSiteLoaded() and df.global.plotinfo.site_id or nil
    if not site then return fresh_state() end
    if state and state_site == site and state.thresholds and state.off then return state end
    local d = dfhack.persistent.getSiteData(GLOBAL_KEY, nil)
    if type(d) ~= 'table' then d = fresh_state() end
    d.default = tonumber(d.default) or DEFAULT_THRESHOLD
    d.thresholds = type(d.thresholds) == 'table' and d.thresholds or {}
    d.off = type(d.off) == 'table' and d.off or {}
    state, state_site = d, site
    enabled = d.enabled == true
    return state
end

local function save_state(st)
    if not dfhack.isSiteLoaded() then return end
    st.enabled = enabled
    dfhack.persistent.saveSiteData(GLOBAL_KEY, st)
end

function isEnabled() return enabled end

-- ---- the exclusion list ------------------------------------------------------

local function is_plot(bld)
    return bld and df.building_farmplotst:is_instance(bld)
end

local function off_index(st, id)
    for i, v in ipairs(st.off) do
        if v == id then return i end
    end
end

function is_off(id)
    return off_index(load_state(), id) ~= nil
end

function set_off(id)
    local st = load_state()
    if off_index(st, id) then return false end
    st.off[#st.off + 1] = id
    save_state(st)
    return true
end

function set_on(id)
    local st = load_state()
    local i = off_index(st, id)
    if not i then return false end
    table.remove(st.off, i)
    save_state(st)
    return true
end

function toggle(id)
    if is_off(id) then set_on(id) else set_off(id) end
end

-- ---- thresholds ------------------------------------------------------------

local function threshold_of(st, plant)
    local t = st.thresholds[plant.id]
    return t ~= nil and tonumber(t) or st.default
end

-- ---- the cycle: a straight port of the plugin ----------------------------------

local SEASONS = {'SPRING', 'SUMMER', 'AUTUMN', 'WINTER'}

-- has seed, is not a tree, and can be planted now and harvested inside seasons it grows in
local function is_plantable(plant)
    local f = plant.flags
    if not f.SEED or f.TREE then return false end
    local season = df.global.cur_season
    local harvest = df.global.cur_season_tick + plant.growdur * 10
    local can = f[SEASONS[season + 1]]
    while can and harvest >= 10080 do
        season = (season + 1) % 4
        harvest = harvest - 10080
        can = can and f[SEASONS[season + 1]]
    end
    return can
end

-- items the plugin will not count: dumped, forbidden, being collected, hostile, burning,
-- rotten, a trader's, part of a building or construction, an artifact
local function item_usable(it)
    local f = it.flags
    return not (f.dump or f.forbid or f.garbage_collect or f.hostile or f.on_fire
                or f.rotten or f.trader or f.in_building or f.construction or f.artifact)
end

-- Every biome_type name is a plant_raw_flags BIOME_<name>; that is the plugin's map.
local BIOMES = {}
for i = 0, 63 do
    local name = df.biome_type[i]
    if name and df.plant_raw_flags['BIOME_' .. name] then BIOMES[#BIOMES + 1] = {i, 'BIOME_' .. name} end
end

-- plant index -> set of biome_type it can be planted in, for every plant we hold seeds of
local function find_plantable_plants()
    local seeds = {}
    for _, it in ipairs(df.global.world.items.other.SEEDS) do
        if df.item_seedsst:is_instance(it) and item_usable(it) then
            seeds[it.mat_index] = (seeds[it.mat_index] or 0) + it.stack_size
        end
    end
    local out = {}
    for idx in pairs(seeds) do
        local plant = df.global.world.raws.plants.all[idx]
        if plant and is_plantable(plant) then
            for _, b in ipairs(BIOMES) do
                if plant.flags[b[2]] then
                    out[idx] = out[idx] or {}
                    out[idx][b[1]] = true
                end
            end
        end
    end
    return out
end

local function plant_name(id)
    local raw = df.plant_raw.find(id)
    return raw and raw.name or 'NONE'
end

local function set_farm(new_id, farm, season)
    local old = farm.plant_id[season]
    if old ~= new_id then
        farm.plant_id[season] = new_id
        print(('autofarm: changing farm #%d from %s to %s'):format(farm.id, plant_name(old),
                                                                     plant_name(new_id)))
    end
end

-- This algorithm changes as few farms as possible while keeping the number of farms
-- planting each eligible plant as equal as possible. `plants` is a sorted list of plant
-- indices, `farms` a list of plots, all of one biome.
local function set_farms(plants, farms, season)
    if #farms == 0 then return end
    if #plants == 0 then
        for _, farm in ipairs(farms) do set_farm(-1, farm, season) end
        return
    end
    local min = #farms // #plants               -- farms per plant, rounded down
    local extra = #farms - min * #plants        -- the remainder that cannot be divided
    local wanted = {}
    for _, p in ipairs(plants) do wanted[p] = true end
    local counters, to_change = {}, {}
    for _, farm in ipairs(farms) do
        local o = farm.plant_id[season]
        local c = counters[o] or 0
        if not wanted[o] or c > min or (c == min and extra == 0) then
            to_change[#to_change + 1] = farm     -- an excess instance of its current plant
        else
            if c == min then extra = extra - 1 end
            counters[o] = c + 1
        end
    end
    local head = 1
    for _, n in ipairs(plants) do
        local c = counters[n] or 0
        while head <= #to_change and (c < min or (c == min and extra > 0)) do
            set_farm(n, to_change[head], season)
            head = head + 1
            if c == min then extra = extra - 1 end
            c = c + 1
        end
    end
end

-- the biome a plot plants for: underground is SUBTERRANEAN_WATER, else the region's
local function plot_biome(farm)
    local pos = xyz2pos(farm.centerx, farm.centery, farm.z)
    local des = dfhack.maps.getTileFlags(pos)
    if des and des.subterranean then return df.biome_type.SUBTERRANEAN_WATER end
    local rx, ry = dfhack.maps.getTileBiomeRgn(pos)
    return dfhack.maps.getBiomeType(rx, ry)
end

function process()
    local st = load_state()
    local plantable = find_plantable_plants()
    last_counts = {}
    local function count(it)
        local mat = it:getMaterialIndex()
        if plantable[mat] and item_usable(it) then
            last_counts[mat] = (last_counts[mat] or 0) + it:getStackSize()
        end
    end
    for _, it in ipairs(df.global.world.items.other.PLANT) do count(it) end
    for _, it in ipairs(df.global.world.items.other.PLANT_GROWTH) do count(it) end

    -- biome -> sorted list of plants below threshold that grow there
    local plants = {}
    for idx, biomes in pairs(plantable) do
        local plant = df.global.world.raws.plants.all[idx]
        if (last_counts[idx] or 0) < threshold_of(st, plant) then
            for b in pairs(biomes) do
                plants[b] = plants[b] or {}
                table.insert(plants[b], idx)
            end
        end
    end
    for _, list in pairs(plants) do table.sort(list) end

    -- biome -> the managed plots in it. A plot turned off is not here, so nothing below
    -- ever sees it -- not even to count it towards how many plots a crop already has.
    local off = {}
    for _, id in ipairs(st.off) do off[id] = true end
    local farms = {}
    for _, bld in ipairs(df.global.world.buildings.other.FARM_PLOT) do
        if is_plot(bld) and bld.flags.exists and not off[bld.id] then
            local b = plot_biome(bld)
            farms[b] = farms[b] or {}
            table.insert(farms[b], bld)
        end
    end
    local season = df.global.cur_season
    for b, list in pairs(farms) do
        set_farms(plants[b] or {}, list, season)
    end
end

-- ---- the service -------------------------------------------------------------

local function start()
    repeatutil.scheduleEvery(GLOBAL_KEY, CYCLE_TICKS, 'ticks', function()
        if not enabled or not dfhack.isMapLoaded() then return end
        local ok, err = pcall(process)
        if not ok then dfhack.printerr('fort/autofarm: ' .. tostring(err)) end
    end)
end

local function stop()
    repeatutil.cancel(GLOBAL_KEY)
end

function set_enabled(on)
    local st = load_state()
    enabled = on
    save_state(st)
    if on then
        -- two managers on the same plots would overwrite each other every hour
        pcall(dfhack.run_command_silent, 'disable', 'autofarm')
        start()
    else
        stop()
    end
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        enabled = false
        state, state_site = nil, nil
        stop()
        return
    end
    if sc ~= SC_MAP_LOADED or df.global.gamemode ~= df.game_mode.DWARF then return end
    load_state()
    if enabled then start() end
end

-- ---- the button ----------------------------------------------------------------
--
-- Fixed to the sheet like `fort/idle-smiths`' toggle: the farm plot sheet is drawn at the
-- right edge of the screen at a fixed offset, so a position measured from that edge holds
-- at any resolution. Three rows above "Leave fallow", in its column: a negative x is the
-- RIGHT edge of the widget measured from the right edge of the screen (x=-1 is the last
-- column), so it is offset by the width. Measured at 192 columns: "Leave fallow" starts
-- at column 103, so a 10-wide button whose right edge is at 112 has 79 columns after it.

local function sheet_plot()
    local bld = dfhack.gui.getSelectedBuilding(true)
    if is_plot(bld) then return bld end
end

ButtonOverlay = defclass(ButtonOverlay, overlay.OverlayWidget)
ButtonOverlay.ATTRS{
    desc = 'Adds an [autofarm] toggle to the farm plot sheet: green when the plot is managed.',
    default_pos = {x = -80, y = 15},
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/BUILDING/FarmPlot',
    frame = {w = 10, h = 1},
    version = 4,
}

function ButtonOverlay:init()
    self:addviews{
        -- a token's on_activate answers its KEY only; a mouse click reaches the Label's own
        -- on_click, so that is where the toggle lives
        widgets.Label{
            frame = {t = 0, l = 0},
            auto_width = true,
            visible = function() return sheet_plot() ~= nil end,
            on_click = function() self:toggle() end,
            text = {{
                text = '[autofarm]',
                pen = function()
                    local bld = sheet_plot()
                    return (bld and not is_off(bld.id)) and COLOR_LIGHTGREEN or COLOR_WHITE
                end,
            }},
        },
    }
end

function ButtonOverlay:toggle()
    local bld = sheet_plot()
    if bld then toggle(bld.id) end
end

function ButtonOverlay:onInput(keys)
    if keys.CUSTOM_CTRL_A and sheet_plot() then self:toggle() return true end
    return ButtonOverlay.super.onInput(self, keys)
end

OVERLAY_WIDGETS = {button = ButtonOverlay}

-- ---- command line ---------------------------------------------------------------

local function status()
    local st = load_state()
    print('fort/autofarm is ' .. (enabled and 'Active.' or 'Stopped.'))
    local shown = {}
    local all = df.global.world.raws.plants.all
    local idxs = {}
    for idx in pairs(last_counts) do idxs[#idxs + 1] = idx end
    table.sort(idxs)
    for _, idx in ipairs(idxs) do
        local plant = all[idx]
        print(('%s limit %d current %d'):format(plant.id, threshold_of(st, plant), last_counts[idx]))
        shown[plant.id] = true
    end
    for id, t in pairs(st.thresholds) do
        if not shown[id] then print(('%s limit %d current 0'):format(id, tonumber(t) or st.default)) end
    end
    print('Default: ' .. st.default)
    if #st.off == 0 then
        print('Every farm plot is managed.')
    else
        print(('Turned off for %d plot%s:'):format(#st.off, #st.off == 1 and '' or 's'))
        for _, id in ipairs(st.off) do
            local bld = df.building.find(id)
            if is_plot(bld) then
                local names = {}
                for s = 0, 3 do names[s + 1] = plant_name(bld.plant_id[s]) end
                print(('  plot %d at (%d,%d,%d): %s'):format(id, bld.centerx, bld.centery, bld.z,
                                                              table.concat(names, ' / ')))
            else
                print(('  plot %d (gone)'):format(id))
            end
        end
    end
end

local function find_seed_plant(id)
    id = id:upper()
    for i, plant in ipairs(df.global.world.raws.plants.all) do
        if plant.flags.SEED and plant.id == id then return plant end
    end
end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.isMapLoaded() or not dfhack.world.isFortressMode() then
    qerror('fort/autofarm needs a loaded fortress')
end

if dfhack_flags.enable then
    set_enabled(dfhack_flags.enable_state)
    print('fort/autofarm ' .. (enabled and 'enabled' or 'disabled'))
    return
end

local args = {...}
local cmd = args[1]

if cmd == nil or cmd == 'status' then
    status()
elseif cmd == 'runonce' then
    process()
elseif cmd == 'default' and args[2] then
    local st = load_state()
    st.default = tonumber(args[2]) or qerror('default takes a number')
    save_state(st)
    print('default threshold set to ' .. st.default)
elseif cmd == 'threshold' and args[3] then
    local n = tonumber(args[2]) or qerror('threshold takes a number, then plant ids')
    local st = load_state()
    for i = 3, #args do
        local plant = find_seed_plant(args[i]) or qerror('Cannot find plant with id ' .. args[i]:upper())
        st.thresholds[plant.id] = n
    end
    save_state(st)
    print(('threshold %d set for %d plant%s'):format(n, #args - 2, #args == 3 and '' or 's'))
elseif cmd == 'off' then
    local bld = sheet_plot() or qerror('open a farm plot\'s sheet first')
    print(set_off(bld.id) and ('autofarm is now off for plot %d'):format(bld.id)
          or ('autofarm was already off for plot %d'):format(bld.id))
elseif cmd == 'on' then
    if args[2] == 'all' then
        local st = load_state()
        local n = #st.off
        st.off = {}
        save_state(st)
        print(('handed back %d plot%s'):format(n, n == 1 and '' or 's'))
    else
        local bld = sheet_plot() or qerror('open a farm plot\'s sheet first')
        print(set_on(bld.id) and ('autofarm is back on for plot %d'):format(bld.id)
              or ('autofarm was already on for plot %d'):format(bld.id))
    end
else
    qerror('usage: fort/autofarm [status | runonce | default <n> | threshold <n> <id...> | off | on [all]]')
end
