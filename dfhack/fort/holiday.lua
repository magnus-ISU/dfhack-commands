-- Call a fort-wide holiday: every work detail off, and back on again afterwards.
--@module = true
--@enable = true
--[[
fort/holiday

Stops the fort working, and starts it again with everything exactly where it was. A
[Holiday] button sits on the work detail screen next to [Change Icon]; the command does
the same thing from the console.

WHY YOU WOULD. A fort that has to be somewhere -- everyone into the burrow before the
siege lands, everyone off the surface before the clouds arrive -- spends the crucial
minute being dragged back to workshops by jobs already queued. Turning the labors off
turns the queue off with it, and the dwarves go where you sent them.

WHAT IT ACTUALLY DOES, AND WHY IT IS SAFE

  It does NOT clear anybody's work detail membership. In this version of DF the work
  details own the labor flags -- writing `unit.status.labors` for a labor a detail governs
  is wiped the next time anything recomputes -- so the honest lever is the detail's MODE.
  Every detail is set to "nobody does this" and the mode it had is written down; ending the
  holiday puts each mode back. Membership, order, icons, the details themselves: untouched
  throughout, so there is nothing to restore wrongly and nothing to lose if the holiday is
  forgotten.

  THAT ONLY STOPS HALF THE FORT. A labor no detail lists is on for everybody by default,
  and this fort's 37 details cover barely half of them: with every detail switched off,
  3,220 labors were still set -- cleaning, milking, pulling levers. Switching the details
  off also left eight dwarves still hauling, because DF does not recompute every citizen
  just because a mode changed. So every labor still standing after that is cleared on the
  dwarf, and WHAT EACH DWARF HAD IS WRITTEN DOWN PER DWARF: that record is what they get
  back, so the fort resumes exactly as it was rather than as DF would guess.

  Order matters and is the fiddly part. `setAutomaticProfessions` -- which has to be called
  because DF only applies a detail when somebody clicks its screen -- REBUILDS the
  uncovered labors from DF's defaults, so it runs BEFORE the direct clears on the way in,
  and BEFORE the direct restores on the way out. Get it the other way round and the
  holiday ends the moment it starts.

  The written-down modes live with the site, so a save and reload in the middle of a
  holiday still ends it correctly. Details are matched back by NAME, and by position when
  a name has changed underneath.

    fort/holiday            say whether the fort is on holiday
    fort/holiday on         stop work
    fort/holiday off        back to work
    fort/holiday toggle     the button's own action
]]

local overlay = require('plugins.overlay')

local GLOBAL_KEY = 'holiday'
local MAX_LABOR = 93          -- df.unit_labor's last entry on this build
local HOLD_FRAMES = 100       -- how often a running holiday re-asserts itself

local function work_details() return df.global.plotinfo.labor_info.work_details end

local state = nil
local function load_state()
    if not state then
        state = dfhack.persistent.getSiteData(GLOBAL_KEY) or {}
        if state.on == nil then state.on = false end
        state.modes = type(state.modes) == 'table' and state.modes or {}
    end
    return state
end
local function save_state() pcall(dfhack.persistent.saveSiteData, GLOBAL_KEY, state) end

function isEnabled() return load_state().on end

local function citizens()
    local out = {}
    for _, unit in ipairs(df.global.world.units.active) do
        if dfhack.units.isCitizen(unit) and not dfhack.units.isDead(unit) then
            out[#out + 1] = unit
        end
    end
    return out
end

-- DF only applies a work detail when its screen is used, so every change here has to be
-- pushed onto the dwarves by hand.
local function apply_to_everyone()
    local n = 0
    for _, unit in ipairs(citizens()) do
        if pcall(dfhack.units.setAutomaticProfessions, unit) then n = n + 1 end
    end
    return n
end

-- ---- the holiday ------------------------------------------------------------

function start()
    local s = load_state()
    if s.on then return 0, 0 end
    local details = work_details()
    s.modes = {}
    local stopped = 0
    for i = 0, #details - 1 do
        local d = details[i]
        -- position AND name: the name is what makes a restore survive somebody reordering
        -- the list, the position is what saves it when a name has been edited since
        s.modes[#s.modes + 1] = {name = d.name, idx = i, mode = d.flags.mode}
        if d.flags.mode ~= df.work_detail_mode.NobodyDoesThis then
            d.flags.mode = df.work_detail_mode.NobodyDoesThis
            stopped = stopped + 1
        end
    end
    -- the details first, THEN the dwarves: setAutomaticProfessions rebuilds the uncovered
    -- labors from DF's defaults, so anything cleared before it would come straight back
    local applied = apply_to_everyone()
    -- and then every labor still standing, dwarf by dwarf. Not only the ones no detail
    -- covers: switching the details off left EIGHT dwarves still hauling here -- DF does not
    -- recompute every citizen on demand -- and a holiday with eight dwarves working is not
    -- one. What each dwarf had is what each dwarf gets back.
    s.units = {}
    for _, unit in ipairs(citizens()) do
        local had = {}
        for l = 0, MAX_LABOR do
            if df.unit_labor[l] and unit.status.labors[l] then
                had[#had + 1] = l
                unit.status.labors[l] = false
            end
        end
        if #had > 0 then s.units[tostring(unit.id)] = had end
    end
    s.on = true
    save_state()
    start_heartbeat()
    return stopped, applied
end

function finish()
    local s = load_state()
    if not s.on then return 0, 0 end
    stop_heartbeat()
    local details = work_details()
    local by_name, restored = {}, 0
    for i = 0, #details - 1 do by_name[details[i].name] = details[i] end
    for _, saved in ipairs(s.modes or {}) do
        local d = by_name[saved.name]
        if not d and saved.idx and saved.idx < #details then d = details[saved.idx] end
        if d then
            d.flags.mode = saved.mode
            restored = restored + 1
        end
    end
    -- details first, then the dwarves, then what was theirs alone -- same order as start,
    -- and for the same reason: setAutomaticProfessions would overwrite the last step
    local applied = apply_to_everyone()
    for id, had in pairs(s.units or {}) do
        local unit = df.unit.find(tonumber(id))
        if unit then
            for _, l in ipairs(had) do unit.status.labors[l] = true end
        end
    end
    s.on, s.modes, s.units = false, {}, {}
    save_state()
    return restored, applied
end

-- While the holiday is on, put back any uncovered labor that has come back -- DF rebuilds
-- them whenever it recomputes a dwarf (opening the work detail screen is enough), and a
-- holiday that quietly ends the first time you look at the labor screen is no holiday.
local function hb_gen(set)
    if set ~= nil then dfhack.internal.holiday_hb_gen = set end
    return dfhack.internal.holiday_hb_gen or 0
end
function start_heartbeat()
    local my = hb_gen() + 1
    hb_gen(my)
    local function hb()
        local s = load_state()
        if not s.on or my ~= hb_gen() then return end
        for id, had in pairs(s.units or {}) do
            local unit = df.unit.find(tonumber(id))
            if unit then
                for _, l in ipairs(had) do
                    if unit.status.labors[l] then unit.status.labors[l] = false end
                end
            end
        end
        dfhack.timeout(HOLD_FRAMES, 'frames', hb)
    end
    hb()
end
function stop_heartbeat() hb_gen(hb_gen() + 1) end

function toggle()
    if isEnabled() then return 'off', finish() end
    return 'on', start()
end

-- ---- the button on the work detail screen -----------------------------------

HolidayOverlay = defclass(HolidayOverlay, overlay.OverlayWidget)
HolidayOverlay.ATTRS{
    desc = 'Adds a [Holiday] button to the work detail screen: all work off, and back on.',
    default_enabled = true,
    viewscreens = 'dwarfmode/Info/LABOR/WORK_DETAILS',
    -- immediately right of choose-labor-icon's [Change Icon] (x=90, 13 wide)
    default_pos = {x = 104, y = 12},
    frame = {w = 13, h = 1},
}

local PEN_OFF = dfhack.pen.parse{fg = COLOR_LIGHTCYAN, bg = COLOR_BLACK}
local PEN_ON = dfhack.pen.parse{fg = COLOR_LIGHTGREEN, bg = COLOR_BLACK}

function HolidayOverlay:onRenderBody(dc)
    if isEnabled() then
        dc:seek(0, 0):pen(PEN_ON):string('[End Holiday]')
    else
        dc:seek(0, 0):pen(PEN_OFF):string('[Holiday]')
    end
end

function HolidayOverlay:onInput(keys)
    if not keys._MOUSE_L then return false end
    if not self:getMousePos() then return false end
    local what, n = toggle()
    dfhack.gui.showAnnouncement(
        what == 'on' and ('Holiday: %d work details stopped. Nobody is working.'):format(n)
            or ('Holiday over: %d work details back the way they were.'):format(n),
        what == 'on' and COLOR_YELLOW or COLOR_LIGHTGREEN)
    return true
end

OVERLAY_WIDGETS = {button = HolidayOverlay}

-- a holiday must not survive as a half-state: re-read the site's own record on load, and
-- pick the holiday back up if the save was made during one
dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_LOADED then
        state = nil
        if dfhack.world.isFortressMode() and isEnabled() then start_heartbeat() end
    elseif sc == SC_MAP_UNLOADED then
        stop_heartbeat(); state = nil
    end
end

-- ---- command ----------------------------------------------------------------

if dfhack_flags and dfhack_flags.module then return end

if not dfhack.world.isFortressMode() then qerror('fort/holiday only works in fortress mode') end

if dfhack_flags and dfhack_flags.enable ~= nil then
    local n
    if dfhack_flags.enable_state then _, n = start() else _, n = finish() end
    print('fort/holiday: ' .. (isEnabled() and 'ON -- nobody is working' or 'over -- back to work'))
    return
end

local arg = ({...})[1]
if arg == 'on' or arg == 'off' or arg == 'toggle' then
    local want = arg == 'toggle' and (isEnabled() and 'off' or 'on') or arg
    local n, applied
    if want == 'on' then n, applied = start() else n, applied = finish() end
    if want == 'on' then
        print(('fort/holiday: ON -- %d work detail%s stopped, %d dwarves told to down tools.')
            :format(n, n == 1 and '' or 's', applied))
        print('  Nothing was unassigned; `fort/holiday off` puts every mode back.')
    else
        print(('fort/holiday: over -- %d work detail%s back the way %s were, %d dwarves back to work.')
            :format(n, n == 1 and '' or 's', n == 1 and 'it' or 'they', applied))
    end
    return
end

local s = load_state()
if s.on then
    print(('fort/holiday: ON -- %d work detail modes held; `fort/holiday off` ends it.')
        :format(#(s.modes or {})))
else
    print('fort/holiday: the fort is working. `fort/holiday on` stops it.')
    print('  Or press [Holiday] on the work detail screen, next to [Change Icon].')
end
