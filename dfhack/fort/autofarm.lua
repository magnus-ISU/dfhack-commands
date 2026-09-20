-- Keep the autofarm plugin's hands off the farm plots you choose, from a button on the plot.
--@module = true
--[[
fort/autofarm

DFHack's `autofarm` plugin manages EVERY farm plot in the fort: each cycle it looks at the
plant stocks and rewrites every plot's four seasonal crops, and there is no way to tell it
"not this one". So a plot you set aside for a crop you actually want -- a dye crop, a plot of
sun berries for the wine, the sweet pods nobody is short of -- is overwritten within the
day, with nothing on screen to say why.

This adds an **[autofarm]** button to the farm plot sheet, three rows above "Leave fallow",
showing whether autofarm may touch this plot. Click it (or Ctrl-A) to turn it off for the
plot: the crops as they stand are remembered, and whenever autofarm rewrites them they are
put straight back -- within half a second, long before a planter reads them. Change the crops
yourself while the sheet is open and the new choice becomes the one that is kept. Click again
and the plot is autofarm's once more.

The plugin itself is untouched: it still runs, still counts the stocks, still manages every
plot you have not turned it off for. All this does is undo it on the plots you have.

    fort/autofarm                 list the plots autofarm is off for, and their crops
    fort/autofarm off             turn autofarm off for the plot whose sheet is open
    fort/autofarm on              hand it back
    fort/autofarm on all          hand every plot back

Auto-discovered by `overlay rescan`; the button is `fort/autofarm.button` and the watcher
that restores the crops is `fort/autofarm.guard` in `gui/overlay`. Both are needed.
]]

local gui = require('gui')
local widgets = require('gui.widgets')
local overlay = require('plugins.overlay')

local GLOBAL_KEY = 'fort/autofarm'
local LABEL = 'Leave fallow'
local ROWS_ABOVE = 3

-- ---- state --------------------------------------------------------------
--
-- {plots = {{id = <building id>, plant = {s0, s1, s2, s3}}, ...}} -- one entry per plot
-- autofarm is turned OFF for, with the crops to keep on it. A list, not a map keyed by id:
-- the persistent store is JSON and an integer key would come back a string.

state = state or nil
state_site = state_site or nil

local function load_state()
    local site = dfhack.isSiteLoaded() and df.global.plotinfo.site_id or nil
    if not site then return {plots = {}} end
    if state and state_site == site then return state end
    local d = dfhack.persistent.getSiteData(GLOBAL_KEY, nil)
    if type(d) ~= 'table' or type(d.plots) ~= 'table' then d = {plots = {}} end
    state, state_site = d, site
    return state
end

local function save_state(st)
    if not dfhack.isSiteLoaded() then return end
    dfhack.persistent.saveSiteData(GLOBAL_KEY, st)
end

local function entry_for(st, id)
    for i, e in ipairs(st.plots) do
        if e.id == id then return e, i end
    end
end

local function crops_of(bld)
    return {bld.plant_id[0], bld.plant_id[1], bld.plant_id[2], bld.plant_id[3]}
end

local function same_crops(a, bld)
    for s = 0, 3 do
        if a[s + 1] ~= bld.plant_id[s] then return false end
    end
    return true
end

local function is_plot(bld)
    return bld and df.building_farmplotst:is_instance(bld)
end

function is_off(id)
    return entry_for(load_state(), id) ~= nil
end

-- turn autofarm off for a plot: its crops as they stand are what is kept
function set_off(bld)
    local st = load_state()
    if entry_for(st, bld.id) then return false end
    st.plots[#st.plots + 1] = {id = bld.id, plant = crops_of(bld)}
    save_state(st)
    return true
end

function set_on(id)
    local st = load_state()
    local _, i = entry_for(st, id)
    if not i then return false end
    table.remove(st.plots, i)
    save_state(st)
    return true
end

function toggle(bld)
    if is_off(bld.id) then set_on(bld.id) else set_off(bld) end
end

-- ---- the guard ------------------------------------------------------------
--
-- Runs a few times a second over the plots autofarm is off for -- a handful, never the
-- fort. The rule that separates the player's change from the plugin's: the player edits a
-- plot with its sheet OPEN, the plugin never does. So while a plot's sheet is up, whatever
-- its crops read is the new wish and is remembered; any other time, crops that differ from
-- the remembered ones are the plugin's doing and are put back.
local function open_plot_id()
    local vs = df.global.game.main_interface.view_sheets
    if vs.open and vs.viewing_bldid >= 0 then return vs.viewing_bldid end
    return -1
end

function guard_pass()
    local st = load_state()
    if #st.plots == 0 then return end
    local open_id = open_plot_id()
    local dirty, keep = false, {}
    for _, e in ipairs(st.plots) do
        local bld = df.building.find(e.id)
        if is_plot(bld) then
            keep[#keep + 1] = e
            if e.id == open_id then
                if not same_crops(e.plant, bld) then
                    e.plant = crops_of(bld)
                    dirty = true
                end
            elseif not same_crops(e.plant, bld) then
                for s = 0, 3 do bld.plant_id[s] = e.plant[s + 1] end
            end
        else
            dirty = true          -- the plot is gone; so is its entry
        end
    end
    if dirty then
        st.plots = keep
        save_state(st)
    end
end

GuardOverlay = defclass(GuardOverlay, overlay.OverlayWidget)
GuardOverlay.ATTRS{
    desc = 'Restores the crops on farm plots fort/autofarm has turned autofarm off for.',
    default_pos = {x = 1, y = 1},
    default_enabled = true,
    viewscreens = 'dwarfmode',
    frame = {w = 1, h = 1},                  -- logic only; nothing is drawn
    overlay_onupdate_max_freq_seconds = 0.5,
    version = 1,
}

function GuardOverlay:overlay_onupdate()
    if not dfhack.isMapLoaded() then return end
    guard_pass()
end

function GuardOverlay:render() end

-- ---- the button -----------------------------------------------------------
--
-- Snapped to the sheet's own text: three rows above "Leave fallow", in its column. The
-- sheet sits at the right of the screen, so the sweep covers that half only, and runs only
-- when the cheap probe of the last known spot fails.

local function label_at(x, y)
    for i = 0, #LABEL - 1 do
        local ok, pen = pcall(dfhack.screen.readTile, x + i, y)
        local ch = (ok and pen and pen.ch) or 0
        if ch ~= LABEL:byte(i + 1) then return false end
    end
    return true
end

local function find_label()
    local gps = df.global.gps
    local x0 = math.floor(gps.dimx / 2)
    for y = 3, gps.dimy - 4 do
        for x = x0, gps.dimx - #LABEL do
            local ok, pen = pcall(dfhack.screen.readTile, x, y)
            if ok and pen and pen.ch == LABEL:byte(1) and label_at(x, y) then
                return x, y
            end
        end
    end
end

local function sheet_plot()
    local bld = dfhack.gui.getSelectedBuilding(true)
    if is_plot(bld) then return bld end
end

ButtonOverlay = defclass(ButtonOverlay, overlay.OverlayWidget)
ButtonOverlay.ATTRS{
    desc = 'Adds an [autofarm] on/off button to the farm plot sheet.',
    default_pos = {x = -60, y = 14},         -- fallback until it snaps above "Leave fallow"
    default_enabled = true,
    viewscreens = 'dwarfmode/ViewSheets/BUILDING/FarmPlot',
    frame = {w = 16, h = 1},
    overlay_onupdate_max_freq_seconds = 0,   -- probed every frame; swept only when the probe fails
    version = 1,
}

function ButtonOverlay:init()
    self.placed = false
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            visible = function() return self.placed end,
            text = {
                {text = '[autofarm]', pen = COLOR_WHITE, on_activate = function() self:toggle() end},
                ' ',
                {text = function()
                    local bld = sheet_plot()
                    return bld and (is_off(bld.id) and 'off' or 'on') or ''
                end,
                 pen = function()
                    local bld = sheet_plot()
                    return (bld and is_off(bld.id)) and COLOR_LIGHTRED or COLOR_LIGHTGREEN
                 end},
            },
        },
    }
end

function ButtonOverlay:toggle()
    local bld = sheet_plot()
    if bld then toggle(bld) end
end

function ButtonOverlay:reposition()
    local x, y = find_label()
    if not x then return false end
    self.label_x, self.label_y = x, y
    local ir = gui.get_interface_rect()
    self.frame = {w = self.frame.w, h = self.frame.h, l = x - ir.x1, t = y - ROWS_ABOVE - ir.y1}
    self:updateLayout(gui.ViewRect{rect = ir})
    return true
end

function ButtonOverlay:overlay_onupdate()
    if not sheet_plot() then self.placed = false return end
    if self.placed and label_at(self.label_x, self.label_y) then return end
    self.placed = false
    local now = dfhack.getTickCount()
    if not self.scan_ms or now < self.scan_ms or now - self.scan_ms >= 200 then
        self.scan_ms = now
        self.placed = self:reposition()
    end
end

function ButtonOverlay:onInput(keys)
    if self.placed and keys.CUSTOM_CTRL_A then self:toggle() return true end
    return ButtonOverlay.super.onInput(self, keys)
end

OVERLAY_WIDGETS = {button = ButtonOverlay, guard = GuardOverlay}

-- ---- command line ---------------------------------------------------------

local function crop_name(id)
    if id < 0 then return 'fallow' end
    local p = df.plant_raw.find(id)
    return p and p.name or ('plant ' .. id)
end

local function describe(e)
    local names = {}
    for s = 1, 4 do names[s] = crop_name(e.plant[s]) end
    return ('plot %d: %s'):format(e.id, table.concat(names, ' / '))
end

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then qerror('fort/autofarm only works in fortress mode') end

local args = {...}
local cmd = args[1]

if cmd == 'off' then
    local bld = sheet_plot()
    if not bld then qerror('open a farm plot\'s sheet first') end
    print(set_off(bld) and ('autofarm is now off for plot %d'):format(bld.id)
          or ('autofarm was already off for plot %d'):format(bld.id))
elseif cmd == 'on' then
    if args[2] == 'all' then
        local st = load_state()
        local n = #st.plots
        st.plots = {}
        save_state(st)
        print(('autofarm handed back %d plot%s'):format(n, n == 1 and '' or 's'))
    else
        local bld = sheet_plot()
        if not bld then qerror('open a farm plot\'s sheet first') end
        print(set_on(bld.id) and ('autofarm is back on for plot %d'):format(bld.id)
              or ('autofarm was already on for plot %d'):format(bld.id))
    end
elseif cmd == nil then
    local st = load_state()
    if #st.plots == 0 then
        print('autofarm manages every farm plot; none turned off.')
    else
        print(('autofarm is off for %d plot%s (spring / summer / autumn / winter):')
            :format(#st.plots, #st.plots == 1 and '' or 's'))
        for _, e in ipairs(st.plots) do print('  ' .. describe(e)) end
    end
else
    qerror('usage: fort/autofarm [off | on [all]]')
end
